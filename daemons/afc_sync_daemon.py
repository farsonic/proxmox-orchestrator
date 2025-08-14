#!/usr/bin/env python3

import requests
import json
import time
import sys
import os
import urllib3
import threading

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
        print(f"[ERROR] Configuration file not found at {path}. Aborting.")
        sys.exit(1)
    except Exception as e:
        print(f"[ERROR] Failed to parse config file {path}: {e}")
        sys.exit(1)
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
        proxmox_zones = {z['zone']: {} for z in zones_response.json().get('data', []) if z.get('zone')}

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

def lookup_fabric_uuids(session, afc_config, token, fabric_names, timeout):
    host = afc_config['host']
    verify_ssl = afc_config.get("verify_ssl", False)
    fabrics_url = f"https://{host}/api/v1/fabrics"
    headers = {'Authorization': f'Bearer {token}'}
    print("--> Looking up AFC Fabric UUIDs...")
    try:
        response = session.get(fabrics_url, headers=headers, verify=verify_ssl, timeout=timeout)
        response.raise_for_status()
        all_fabrics = response.json().get('result', [])
        name_to_uuid = {fabric['name']: fabric['uuid'] for fabric in all_fabrics}
        found_uuids = {}
        for name in fabric_names:
            if name in name_to_uuid:
                found_uuids[name] = name_to_uuid[name]
                print(f"    Found '{name}' -> {name_to_uuid[name][:8]}...")
            else:
                print(f"    [ERROR] Fabric with name '{name}' not found in AFC.")
        return found_uuids
    except requests.exceptions.RequestException as e:
        print(f"[ERROR] Could not look up AFC Fabrics: {e}")
        return {}

def get_afc_state(session, afc_config, token, fabric_uuid, timeout):
    host = afc_config['host']
    verify_ssl = afc_config.get("verify_ssl", False)
    headers = {'Authorization': f'Bearer {token}'}
    
    try:
        print(f"--> Getting VRFs from AFC Fabric UUID '{fabric_uuid[:8]}...'...")
        vrfs_url = f"https://{host}/api/v1/vrfs"
        params = {'fabrics': fabric_uuid, 'fields': 'uuid,name'}
        vrfs_response = session.get(vrfs_url, headers=headers, params=params, verify=verify_ssl, timeout=timeout)
        vrfs_response.raise_for_status()
        afc_vrfs = {v['name']: {'uuid': v['uuid']} for v in vrfs_response.json().get('result', [])}

        print(f"--> Getting VLANs from AFC Fabric UUID '{fabric_uuid[:8]}...'...")
        # FIX: Use the correct '/vlans' endpoint, not '/networks'
        vlans_url = f"https://{host}/api/v1/fabrics/{fabric_uuid}/vlans"
        vlans_response = session.get(vlans_url, headers=headers, verify=verify_ssl, timeout=timeout)
        vlans_response.raise_for_status()
        afc_vlans = {
            int(n['vlan_id']): {'vrf': n.get('vrf'), 'name': n.get('vlan_name'), 'uuid': n.get('uuid')}
            for n in vlans_response.json().get('result', []) if n.get('vlan_id')
        }
        return afc_vrfs, afc_vlans
    except (requests.exceptions.RequestException, KeyError, TypeError) as e:
        print(f"    [ERROR] Could not get AFC state for fabric UUID '{fabric_uuid[:8]}': {e}")
        return None, None

def create_afc_vrf(session, afc_config, token, fabric_uuid, fabric_name, vrf_name, dry_run=False):
    host = afc_config['host']
    verify_ssl = afc_config.get("verify_ssl", False)
    timeout = afc_config.get("request_timeout", 10)
    headers = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
    url = f"https://{host}/api/v1/vrfs"
    payload = {"name": vrf_name, "fabric_uuid": fabric_uuid}
    
    print(f"    -> CREATE VRF '{vrf_name}' in Fabric '{fabric_name}'")
    if dry_run: return True
    
    try:
        response = session.post(url, headers=headers, json=payload, verify=verify_ssl, timeout=timeout)
        response.raise_for_status()
        return True
    except requests.exceptions.RequestException as e:
        print(f"        [ERROR] CREATE failed: {e}")
        if hasattr(e, 'response') and e.response is not None:
             print(f"        [DEBUG] API Response: {e.response.text}")
        return False

def delete_afc_vrf(session, afc_config, token, vrf_name, vrf_uuid, dry_run=False):
    host = afc_config['host']
    verify_ssl = afc_config.get("verify_ssl", False)
    timeout = afc_config.get("request_timeout", 10)
    headers = {'Authorization': f'Bearer {token}'}
    url = f"https://{host}/api/v1/vrfs/{vrf_uuid}"
    
    print(f"    -> DELETE VRF '{vrf_name}'")
    if dry_run: return True
    
    try:
        response = session.delete(url, headers=headers, verify=verify_ssl, timeout=timeout)
        response.raise_for_status()
        return True
    except requests.exceptions.RequestException as e:
        print(f"        [ERROR] DELETE failed: {e}")
        if hasattr(e, 'response') and e.response is not None:
             print(f"        [DEBUG] API Response: {e.response.text}")
        return False

def create_afc_vlan(session, afc_config, token, fabric_uuid, fabric_name, vlan_id, vlan_name, vrf_name, dry_run=False):
    host = afc_config['host']
    verify_ssl = afc_config.get("verify_ssl", False)
    timeout = afc_config.get("request_timeout", 10)
    headers = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
    # FIX: Use the correct known-good endpoint and payload structure
    url = f"https://{host}/api/v1/fabrics/{fabric_uuid}/vlans"
    payload = {
        "vlans": [{"vlan_id": str(vlan_id), "vlan_name": vlan_name, "strict_firewall_bypass_enabled": False}],
        "vlan_scope": {"fabric_scope": "exclude_spine"}
    }
    
    print(f"    -> CREATE VLAN {vlan_id} ('{vlan_name}') in Fabric '{fabric_name}'")
    if dry_run: return True
    
    try:
        response = session.post(url, headers=headers, json=payload, verify=verify_ssl, timeout=timeout)
        response.raise_for_status()
        # The two-step process of assigning to a VRF would go here if needed, but for now we create at fabric level.
        return True
    except requests.exceptions.RequestException as e:
        print(f"        [ERROR] CREATE failed: {e}")
        if hasattr(e, 'response') and e.response is not None:
             print(f"        [DEBUG] API Response: {e.response.text}")
        return False

def delete_afc_vlan(session, afc_config, token, fabric_uuid, fabric_name, vlan_name, vlan_uuid, dry_run=False):
    host = afc_config['host']
    verify_ssl = afc_config.get("verify_ssl", False)
    timeout = afc_config.get("request_timeout", 10)
    headers = {'Authorization': f'Bearer {token}'}
    # FIX: Use the correct known-good endpoint with UUID
    url = f"https://{host}/api/v1/fabrics/{fabric_uuid}/vlans/{vlan_uuid}"
    
    print(f"    -> DELETE VLAN '{vlan_name}' from Fabric '{fabric_name}'")
    if dry_run: return True
    
    try:
        response = session.delete(url, headers=headers, verify=verify_ssl, timeout=timeout)
        response.raise_for_status()
        return True
    except requests.exceptions.RequestException as e:
        print(f"        [ERROR] DELETE failed: {e}")
        if hasattr(e, 'response') and e.response is not None:
             print(f"        [DEBUG] API Response: {e.response.text}")
        return False

def sync_afc_target(afc_id, config_path, stop_event):
    http_session = requests.Session()
    http_session.headers.update({'Connection': 'close'})

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
        
        fabric_map = lookup_fabric_uuids(http_session, afc_config, token, fabric_list, timeout)
        if not fabric_map:
            print("[ERROR] No valid Fabric UUIDs could be found. Skipping cycle.")
            stop_event.wait(poll_interval)
            continue

        for fabric_name, fabric_uuid in fabric_map.items():
            print(f"\n--- Processing Fabric: {fabric_name} ---")

            current_vrfs, current_vlans = get_afc_state(http_session, afc_config, token, fabric_uuid, timeout)
            if current_vrfs is None: continue

            print(f"--> Comparing states for Fabric '{fabric_name}'...")

            zones_to_create = desired_zones.keys() - current_vrfs.keys() - reserved_zones
            zones_to_delete = current_vrfs.keys() - desired_zones.keys() - reserved_zones
            
            desired_vlan_ids = {t for t, v in desired_vnets.items() if t not in reserved_vlans and v.get('zone') not in reserved_zones}
            vlans_to_create = desired_vlan_ids - current_vlans.keys()
            vlans_to_delete = current_vlans.keys() - desired_vlan_ids
            
            # Deletions (VLANs then VRFs)
            for tag in vlans_to_delete:
                vlan = current_vlans[tag]
                delete_afc_vlan(http_session, afc_config, token, fabric_uuid, fabric_name, vlan['name'], vlan['uuid'], dry_run)
            for name in zones_to_delete:
                vrf = current_vrfs[name]
                delete_afc_vrf(http_session, afc_config, token, name, vrf['uuid'], dry_run)
            
            # Creations (VRFs then VLANs)
            for name in zones_to_create:
                create_afc_vrf(http_session, afc_config, token, fabric_uuid, fabric_name, name, dry_run)

            # Re-fetch VRFs if we created new ones
            if zones_to_create and not dry_run:
                print("--> Re-fetching AFC VRFs after creation...")
                current_vrfs, _ = get_afc_state(http_session, afc_config, token, fabric_uuid, timeout)
                if current_vrfs is None: continue

            for tag in vlans_to_create:
                vnet = desired_vnets[tag]
                zone = vnet['zone']
                if zone in current_vrfs: # Ensure VRF exists
                    create_afc_vlan(http_session, afc_config, token, fabric_uuid, fabric_name, tag, vnet['vnet'], zone, dry_run)
            
            if not any([zones_to_create, zones_to_delete, vlans_to_create, vlans_to_delete]):
                print(f"--> No changes needed for Fabric '{fabric_name}'.")

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
