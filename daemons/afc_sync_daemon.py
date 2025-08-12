#!/usr/bin/env python3

import requests
import json
import time
import sys
import os
import urllib3
import threading
from datetime import datetime, timezone

# Suppress InsecureRequestWarning for self-signed certs
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def parse_pve_config(path):
    """Parses the Proxmox-style section config file."""
    config = {'ids': {}}
    current_id = None
    current_type = None

    try:
        with open(path, 'r') as f:
            for line in f:
                original_line = line.rstrip('\n')
                stripped_line = original_line.strip()
                if not stripped_line or stripped_line.startswith('#'):
                    continue
                if not original_line.startswith((' ', '\t')):
                    parts = stripped_line.split(':', 1)
                    if len(parts) == 2:
                        current_type = parts[0].strip()
                        current_id = parts[1].strip()
                        if current_id not in config['ids']:
                            config['ids'][current_id] = {'type': current_type}
                elif current_id and original_line.startswith((' ', '\t')):
                    parts = stripped_line.split(None, 1)
                    if len(parts) == 2:
                        key = parts[0].strip()
                        value = parts[1].strip()
                        if key in ['port', 'poll_interval_seconds', 'request_timeout', 'management_vlan']:
                            try: value = int(value)
                            except ValueError: continue
                        elif key in ['enabled', 'verify_ssl']:
                             value = bool(int(value))
                        config['ids'][current_id][key] = value
    except FileNotFoundError:
        print("[INFO] Configuration file not found. No targets to process.")
        return {'ids': {}}
    except Exception as e:
        print(f"[ERROR] Failed to parse config file {path}: {e}")
        return {'ids': {}}
        
    return config

def get_proxmox_state(session, timeout):
    """Gets Proxmox SDN state, filtering for orchestratable VNETs."""
    pve_token_secret = os.environ.get('PVE_TOKEN_SECRET_READ')
    if not pve_token_secret:
        print("[ERROR] PVE_TOKEN_SECRET_READ environment variable not set.")
        return None, None
        
    prox_host = '127.0.0.1'
    api_user = 'sync-daemon@pve'
    token_name = 'daemon-token'
    headers = {'Authorization': f"PVEAPIToken={api_user}!{token_name}={pve_token_secret}"}
    
    zones_url = f"https://{prox_host}:8006/api2/json/cluster/sdn/zones"
    vnets_url = f"https://{prox_host}:8006/api2/json/cluster/sdn/vnets"
    
    try:
        zones_response = session.get(zones_url, headers=headers, verify=False, timeout=timeout)
        zones_response.raise_for_status()
        proxmox_zones = {z['zone'] for z in zones_response.json().get('data', []) if z.get('zone')}

        vnets_response = session.get(vnets_url, headers=headers, verify=False, timeout=timeout)
        vnets_response.raise_for_status()
        vnets_data = vnets_response.json().get('data', [])
        
        proxmox_vnets = {
            int(v['tag']): {'vnet': v.get('vnet'), 'zone': v.get('zone')}
            for v in vnets_data
            if v.get('tag') and v.get('isolate-ports') == 1 and v.get('orchestration') == 1
        }
        
        return proxmox_zones, proxmox_vnets
    except requests.exceptions.RequestException as e:
        print(f"[ERROR] Could not get Proxmox config: {e}")
        return None, None

def get_afc_token(session, afc_id, afc_config, timeout):
    afc_password = afc_config.get('password')
    afc_user = afc_config.get('user')
    if not all([afc_password, afc_user]):
        print(f"[ERROR] AFC ('{afc_id}'): 'user' and/or 'password' not found.")
        return None

    auth_url = f"https://{afc_config['host']}/api/v1/auth/token"
    auth_headers = {'X-Auth-Username': afc_user, 'X-Auth-Password': afc_password}
    try:
        response = session.post(auth_url, headers=auth_headers, verify=afc_config.get("verify_ssl", False), timeout=timeout)
        response.raise_for_status()
        return response.json().get('result')
    except requests.exceptions.RequestException as e:
        print(f"[ERROR] AFC ('{afc_id}') Authentication failed: {e}")
        return None

def get_afc_state(session, afc_config, token, fabric, timeout):
    """Gets current VRFs and Networks from a specific AFC fabric."""
    host = afc_config['host']
    verify_ssl = afc_config.get("verify_ssl", False)
    headers = {'X-Auth-Token': token}
    
    vrfs_url = f"https://{host}/api/v1/fabrics/{fabric}/vrfs"
    networks_url = f"https://{host}/api/v1/fabrics/{fabric}/networks"

    try:
        print(f"--> Getting VRFs from AFC Fabric '{fabric}'...")
        vrfs_response = session.get(vrfs_url, headers=headers, verify=verify_ssl, timeout=timeout)
        vrfs_response.raise_for_status()
        afc_vrfs = {v['name'] for v in vrfs_response.json().get('result', [])}

        print(f"--> Getting Networks from AFC Fabric '{fabric}'...")
        networks_response = session.get(networks_url, headers=headers, verify=verify_ssl, timeout=timeout)
        networks_response.raise_for_status()
        afc_networks = {
            n['vlan']: {'vrf': n.get('vrf'), 'name': n.get('name')}
            for n in networks_response.json().get('result', []) if n.get('vlan')
        }
        
        return afc_vrfs, afc_networks
    except (requests.exceptions.RequestException, KeyError, TypeError) as e:
        print(f"    [ERROR] Could not get AFC state for fabric '{fabric}': {e}")
        return None, None

def manage_afc_resource(session, afc_config, token, fabric, method, resource, item_name, payload=None, timeout=10, dry_run=False):
    """Helper function to create or delete an AFC resource in a specific fabric."""
    host = afc_config['host']
    verify_ssl = afc_config.get("verify_ssl", False)
    headers = {'X-Auth-Token': token, 'Content-Type': 'application/json'}
    
    # resource should be 'vrfs' or 'networks'
    # item_name is the specific vrf name or network name
    path = f"/api/v1/fabrics/{fabric}/{resource}"
    if method.upper() == "DELETE":
        path = f"{path}/{item_name}"
    
    url = f"https://{host}{path}"
    action = "CREATE" if method.upper() == "POST" else "DELETE"
    print(f"    -> {action} {resource} '{item_name}' in Fabric '{fabric}'")

    if dry_run:
        print("       (dry_run) Skipping execution.")
        return True

    try:
        response = session.request(method, url, headers=headers, json=payload, verify=verify_ssl, timeout=timeout)
        response.raise_for_status()
        return True
    except requests.exceptions.RequestException as e:
        print(f"       [ERROR] {action} failed: {e}")
        return False

def sync_afc_target(afc_id, config_path, stop_event):
    """Worker function to sync a single AFC target in a loop."""
    http_session = requests.Session()
    poll_interval = 60

    while not stop_event.is_set():
        full_config = parse_pve_config(config_path)
        afc_config = full_config.get('ids', {}).get(afc_id)
        if not afc_config:
            print(f"[INFO] Target '{afc_id}' removed from config. Stopping worker thread.")
            break

        poll_interval = afc_config.get('poll_interval_seconds', 60)
        timeout = afc_config.get('request_timeout', 15)
        
        is_enabled = afc_config.get('enabled', False)
        dry_run = not is_enabled

        reserved_zones = set(afc_config.get('reserved_zone_names', []))
        reserved_vlans = set(afc_config.get('reserved_vlans', []))

        # Handle both 'fabric_name' and 'fabric_names' for flexibility
        fabric_names_str = afc_config.get('fabric_names') or afc_config.get('fabric_name', '')
        fabric_list = [f.strip() for f in fabric_names_str.split(',') if f.strip()]

        print(f"\n{'='*20} [AFC: {afc_id}] Sync Cycle {'='*20}")
        if dry_run: print(f"--- [AFC: {afc_id}] RUNNING IN DRY-RUN MODE (enabled=0) ---")
        else: print(f"--- [AFC: {afc_id}] RUNNING IN LIVE MODE (enabled=1) ---")
        
        if not fabric_list:
            print("[ERROR] 'fabric_name' or 'fabric_names' not configured. Skipping cycle.")
            stop_event.wait(poll_interval)
            continue

        print("--> Getting Proxmox state...")
        desired_zones, desired_vnets = get_proxmox_state(http_session, timeout)
        if desired_zones is None:
            stop_event.wait(poll_interval)
            continue
        
        print(f"--> Authenticating to AFC at {afc_config.get('host')}...")
        token = get_afc_token(http_session, afc_id, afc_config, timeout)
        if not token:
            stop_event.wait(poll_interval)
            continue

        # --- NEW LOGIC: Loop through each fabric ---
        for fabric in fabric_list:
            print(f"\n--- Processing Fabric: {fabric} ---")

            current_vrfs, current_networks = get_afc_state(http_session, afc_config, token, fabric, timeout)
            if current_vrfs is None:
                continue
            
            print(f"--> Comparing states for Fabric '{fabric}'...")
            
            zones_to_create = desired_zones - current_vrfs - reserved_zones
            zones_to_delete = current_vrfs - desired_zones - reserved_zones

            for zone in zones_to_create:
                manage_afc_resource(http_session, afc_config, token, fabric, "POST", "vrfs", zone, payload={"name": zone}, timeout=timeout, dry_run=dry_run)
            for zone in zones_to_delete:
                manage_afc_resource(http_session, afc_config, token, fabric, "DELETE", "vrfs", zone, timeout=timeout, dry_run=dry_run)

            desired_vnets_filtered = {t: v for t, v in desired_vnets.items() if t not in reserved_vlans and v.get('zone') not in reserved_zones}
            vnets_to_create = {t: v for t, v in desired_vnets_filtered.items() if t not in current_networks}
            vnets_to_delete = {t: v_info for t, v_info in current_networks.items() if t not in desired_vnets_filtered}
            
            for tag, vnet in vnets_to_create.items():
                zone = vnet['zone']
                if zone in current_vrfs or zone in zones_to_create:
                    vlan_name = f"vlan{tag}"
                    payload = {"name": vlan_name, "vrf": zone, "vlan": tag}
                    manage_afc_resource(http_session, afc_config, token, fabric, "POST", "networks", vlan_name, payload, timeout, dry_run)

            for tag, vnet_info in vnets_to_delete.items():
                net_name = vnet_info['name']
                manage_afc_resource(http_session, afc_config, token, fabric, "DELETE", "networks", net_name, timeout=timeout, dry_run=dry_run)
            
            if not any([zones_to_create, zones_to_delete, vnets_to_create, vnets_to_delete]):
                print(f"--> No changes needed for Fabric '{fabric}'.")

        print(f"\n--- [AFC: {afc_id}] Sync cycle finished. Waiting {poll_interval}s. ---")
        stop_event.wait(poll_interval)

    http_session.close()
    print(f"--- [AFC: {afc_id}] Worker thread stopped. ---")

def main(config_path):
    print("--- Starting AFC Sync Daemon ---")
    stop_event = threading.Event()
    threads = {}
    try:
        while not stop_event.is_set():
            full_config = parse_pve_config(config_path)
            current_targets = {
                orch_id: details for orch_id, details in full_config.get('ids', {}).items()
                if details.get('type', '').upper() == 'AFC'
            }
            if not current_targets:
                print("[INFO] No AFC orchestrators found in config. Waiting...")
                time.sleep(60)
                continue
            for afc_id in current_targets:
                if afc_id not in threads or not threads[afc_id].is_alive():
                    print(f"[INFO] Starting worker thread for target: '{afc_id}'.")
                    thread = threading.Thread(target=sync_afc_target, args=(afc_id, config_path, stop_event))
                    thread.daemon = True
                    thread.start()
                    threads[afc_id] = thread
            time.sleep(60)
    except KeyboardInterrupt:
        print("\n--- Interruption received. Stopping all worker threads... ---")
        stop_event.set()
        for thread in threads.values():
            if thread.is_alive():
                thread.join()
    print("--- All AFC sync threads have been stopped. Exiting. ---")

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == '--config':
        config_file_path = sys.argv[2]
    else:
        config_file_path = '/etc/pve/sdn/orchestrators.cfg'
    main(config_file_path)
