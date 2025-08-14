#!/usr/bin/env python3

import requests
import json
import time
import sys
import os
import urllib3
import threading
from datetime import datetime, timezone
from pathlib import Path

# Suppress InsecureRequestWarning for self-signed certs
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

CONFIG_LOCK = threading.Lock()

def load_environment():
    """Load environment variables from .env file if it exists"""
    env_file = Path(__file__).parent / '.env'
    env_vars = {}
    
    # Try to load from .env file first
    if env_file.exists():
        try:
            with open(env_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        key, value = line.split('=', 1)
                        env_vars[key.strip()] = value.strip()
            print(f"[INFO] Loaded environment from {env_file}")
        except Exception as e:
            print(f"[WARNING] Could not load .env file: {e}")
    
    # Override with actual environment variables
    for key in ['PVE_TOKEN_SECRET_READ', 'PROXMOX_TOKEN_SECRET', 'PVE_TOKEN_SECRET', 
                'PVE_API_USER', 'PVE_TOKEN_ID', 'PVE_HOST', 'PVE_PORT']:
        if key in os.environ:
            env_vars[key] = os.environ[key]
    
    return env_vars

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
                        if key in ['port', 'poll_interval_seconds', 'request_timeout']:
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
    # Load environment variables flexibly
    env_vars = load_environment()
    
    # Try multiple environment variable names for token secret
    pve_token_secret = (
        env_vars.get('PVE_TOKEN_SECRET_READ') or 
        env_vars.get('PROXMOX_TOKEN_SECRET') or
        env_vars.get('PVE_TOKEN_SECRET')
    )
    
    if not pve_token_secret:
        print("[ERROR] Token secret not found. Checked: PVE_TOKEN_SECRET_READ, PROXMOX_TOKEN_SECRET, PVE_TOKEN_SECRET")
        return None, None

    # Allow configuration of these values via environment
    prox_host = env_vars.get('PVE_HOST', '127.0.0.1')
    prox_port = env_vars.get('PVE_PORT', '8006')
    api_user = env_vars.get('PVE_API_USER', 'sync-daemon@pve')
    token_name = env_vars.get('PVE_TOKEN_NAME', 'daemon-token')
    
    headers = {'Authorization': f"PVEAPIToken={api_user}!{token_name}={pve_token_secret}"}

    zones_url = f"https://{prox_host}:{prox_port}/api2/json/cluster/sdn/zones"
    vnets_url = f"https://{prox_host}:{prox_port}/api2/json/cluster/sdn/vnets"

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

def login_to_psm(session, psm_id, psm_config, timeout):
    """Logs into a specific PSM instance using session cookies."""
    psm_password = psm_config.get('password')
    psm_user = psm_config.get('user')
    if not all([psm_password, psm_user]):
        print(f"[ERROR] PSM ('{psm_id}'): 'user' and/or 'password' not found.")
        return False

    url = f"https://{psm_config['host']}/v1/login"
    credentials = {"username": psm_user, "password": psm_password, "tenant": psm_config.get("tenant", "default")}
    try:
        response = session.post(url, json=credentials, verify=psm_config.get("verify_ssl", False), timeout=timeout)
        response.raise_for_status()
        return 'Set-Cookie' in response.headers
    except requests.exceptions.RequestException as e:
        print(f"    [ERROR] PSM ('{psm_id}') Login failed: {e}")
        return False

def get_psm_state(session, psm_config, timeout):
    """Gets current Virtual Routers and Networks from a PSM instance."""
    host = psm_config['host']
    tenant = psm_config.get("tenant", "default")
    verify_ssl = psm_config.get("verify_ssl", False)

    vrfs_url = f"https://{host}/configs/network/v1/tenant/{tenant}/virtualrouters"
    networks_url = f"https://{host}/configs/network/v1/networks"

    try:
        print("--> Getting Virtual Routers from PSM...")
        vrfs_response = session.get(vrfs_url, verify=verify_ssl, timeout=timeout)
        vrfs_response.raise_for_status()
        vrfs_data = vrfs_response.json().get('items') or []
        psm_vrfs = {vrf.get('meta', {}).get('name') for vrf in vrfs_data if vrf.get('meta', {}).get('name')}

        print("--> Getting Networks from PSM...")
        networks_response = session.get(networks_url, verify=verify_ssl, timeout=timeout)
        networks_response.raise_for_status()
        networks_data = networks_response.json().get('items') or []
        psm_networks = {
            n.get('spec', {}).get('vlan-id'): {'vrf': n.get('spec', {}).get('virtual-router'), 'name': n.get('meta', {}).get('name')}
            for n in networks_data if n.get('spec', {}).get('vlan-id')
        }

        return psm_vrfs, psm_networks
    except (requests.exceptions.RequestException, KeyError, TypeError) as e:
        print(f"    [ERROR] Could not get PSM state: {e}")
        return None, None

def manage_psm_resource(session, psm_config, method, resource_path, payload=None, timeout=10, dry_run=False, item_name=""):
    """Helper function to create or delete a PSM resource."""
    host = psm_config['host']
    verify_ssl = psm_config.get("verify_ssl", False)
    headers = {"Content-Type": "application/json"}
    url = f"https://{host}{resource_path}"

    action = "CREATE" if method.upper() == "POST" else "DELETE"
    print(f"    -> {action} {resource_path.split('?')[0]} '{item_name}'")

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

def sync_psm_target(psm_id, config_path, stop_event):
    """Worker function to sync a single PSM target in a loop."""
    proxmox_session = requests.Session()
    psm_session = requests.Session()

    poll_interval = 60

    while not stop_event.is_set():

        full_config = parse_pve_config(config_path)
        psm_config = full_config.get('ids', {}).get(psm_id)

        if not psm_config:
            print(f"[INFO] Target '{psm_id}' removed from config. Stopping worker thread.")
            break

        poll_interval = psm_config.get('poll_interval_seconds', 60)
        timeout = psm_config.get('request_timeout', 15)
        tenant = psm_config.get("tenant", "default")

        is_enabled = psm_config.get('enabled', False)
        dry_run = not is_enabled

        reserved_zones = set(psm_config.get('reserved_zone_names', []))
        reserved_vlans = set(psm_config.get('reserved_vlans', []))

        print(f"\n{'='*20} [PSM: {psm_id}] Sync Cycle {'='*20}")
        if dry_run:
            print(f"--- [PSM: {psm_id}] RUNNING IN DRY-RUN MODE (enabled=0) ---")
        else:
            print(f"--- [PSM: {psm_id}] RUNNING IN LIVE MODE (enabled=1) ---")

        print("--> Getting Proxmox state...")
        desired_zones, desired_vnets = get_proxmox_state(proxmox_session, timeout)
        if desired_zones is None:
            stop_event.wait(poll_interval)
            continue

        print(f"--> Authenticating to PSM at {psm_config.get('host')}...")
        if not login_to_psm(psm_session, psm_id, psm_config, timeout):
            stop_event.wait(poll_interval)
            continue

        print("--> Getting current state from PSM...")
        current_vrfs, current_networks = get_psm_state(psm_session, psm_config, timeout)
        if current_vrfs is None:
            stop_event.wait(poll_interval)
            continue

        print("--> Comparing states and planning actions...")

        zones_to_create = desired_zones - current_vrfs - reserved_zones
        zones_to_delete = current_vrfs - desired_zones - reserved_zones

        for zone in zones_to_create:
            path = f"/configs/network/v1/tenant/{tenant}/virtualrouters"
            payload = {"meta": {"name": zone, "tenant": tenant}, "spec": {"type": "unknown"}}
            manage_psm_resource(psm_session, psm_config, "POST", path, payload, timeout, dry_run, zone)

        for zone in zones_to_delete:
            path = f"/configs/network/v1/tenant/{tenant}/virtualrouters/{zone}"
            manage_psm_resource(psm_session, psm_config, "DELETE", path, None, timeout, dry_run, zone)

        desired_vnets_filtered = {t: v for t, v in desired_vnets.items() if t not in reserved_vlans and v.get('zone') not in reserved_zones}
        vnets_to_create = {t: v for t, v in desired_vnets_filtered.items() if t not in current_networks}

        # --- CORRECTED LINE ---
        vnets_to_delete = {t: v_info for t, v_info in current_networks.items() if t not in desired_vnets_filtered}

        for tag, vnet in vnets_to_create.items():
            zone = vnet['zone']
            if zone in current_vrfs or zone in zones_to_create:
                vlan_name = f"vlan{tag}"
                path = f"/configs/network/v1/networks"
                payload = {"kind": "Network", "meta": {"name": vlan_name}, "spec": {"type": "bridged", "vlan-id": tag, "virtual-router": zone}}
                manage_psm_resource(psm_session, psm_config, "POST", path, payload, timeout, dry_run, vlan_name)

        for tag, vnet_info in vnets_to_delete.items():
            net_name = vnet_info['name']
            path = f"/configs/network/v1/networks/{net_name}"
            manage_psm_resource(psm_session, psm_config, "DELETE", path, None, timeout, dry_run, net_name)

        if not any([zones_to_create, zones_to_delete, vnets_to_create, vnets_to_delete]):
            print("--> No changes needed.")

        print(f"--- [PSM: {psm_id}] Sync cycle finished. Waiting {poll_interval}s. ---")
        stop_event.wait(poll_interval)

    proxmox_session.close()
    psm_session.close()
    print(f"--- [PSM: {psm_id}] Worker thread stopped. ---")

def main(config_path):
    print("--- Starting PSM Sync Daemon ---")
    
    # Load and display environment info at startup
    env_vars = load_environment()
    token_found = any(env_vars.get(key) for key in ['PVE_TOKEN_SECRET_READ', 'PROXMOX_TOKEN_SECRET', 'PVE_TOKEN_SECRET'])
    
    if token_found:
        print(f"[INFO] Token secret loaded successfully")
        print(f"[INFO] PVE Host: {env_vars.get('PVE_HOST', '127.0.0.1')}")
        print(f"[INFO] PVE Port: {env_vars.get('PVE_PORT', '8006')}")
        print(f"[INFO] API User: {env_vars.get('PVE_API_USER', 'sync-daemon@pve')}")
    else:
        print("[WARNING] No token secret found in environment")
    
    stop_event = threading.Event()
    threads = {}

    try:
        while not stop_event.is_set():
            full_config = parse_pve_config(config_path)

            current_targets = {
                orch_id: details for orch_id, details in full_config.get('ids', {}).items()
                if details.get('type', '').upper() == 'PSM'
            }

            # Start threads for new targets that aren't already running
            for psm_id in current_targets:
                if psm_id not in threads or not threads[psm_id].is_alive():
                    print(f"[INFO] Starting worker thread for target: '{psm_id}'.")
                    thread = threading.Thread(target=sync_psm_target, args=(psm_id, config_path, stop_event))
                    thread.daemon = True
                    thread.start()
                    threads[psm_id] = thread

            time.sleep(60)

    except KeyboardInterrupt:
        print("\n--- Interruption received. Stopping all worker threads... ---")
        stop_event.set()
        for thread in threads.values():
            if thread.is_alive():
                thread.join()

    print("--- All PSM sync threads have been stopped. Exiting. ---")

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == '--config':
        config_file_path = sys.argv[2]
    else:
        config_file_path = '/etc/pve/sdn/orchestrators.cfg'
    main(config_file_path)
