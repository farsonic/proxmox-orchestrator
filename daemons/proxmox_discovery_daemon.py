#!/usr/bin/env python3

import requests
import json
import time
import sys
import os
import urllib3
import threading
import re
from pathlib import Path

# Suppress InsecureRequestWarning for self-signed certs
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def load_environment():
    """Load environment variables from a hardcoded .env file path."""
    env_file = Path("/opt/proxmox-sdn-orchestrators/.env")

    env_vars = {}
    if not env_file.exists():
        print(f"[ERROR] Environment file not found at the hardcoded path: {env_file}")
        return None

    try:
        with open(env_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    env_vars[key.strip()] = value.strip()
        print(f"[INFO] Loaded environment from {env_file}")
        return env_vars
    except Exception as e:
        print(f"[ERROR] Could not load .env file: {e}")
        return None

def format_mac_cisco(mac_address):
    """Converts a standard MAC address to Cisco format."""
    if not mac_address or mac_address == "N/A":
        return "N/A"
    cleaned_mac = re.sub(r'[^a-fA-F0-9]', '', mac_address).upper()
    if len(cleaned_mac) != 12:
        return mac_address
    return f"{cleaned_mac[0:4]}.{cleaned_mac[4:8]}.{cleaned_mac[8:12]}"

def get_proxmox_state(session, env_vars, timeout):
    """Gets a detailed state of all VMs and LXC containers."""
    pve_token_secret = env_vars.get('PVE_TOKEN_SECRET_READ')
    if not pve_token_secret:
        print("[ERROR] PVE_TOKEN_SECRET_READ not found in environment file.")
        return None

    host = env_vars.get('PVE_HOST', '127.0.0.1')
    port = env_vars.get('PVE_PORT', '8006')
    api_user = env_vars.get('PVE_API_USER', 'sync-daemon@pve')
    token_name = env_vars.get('PVE_TOKEN_NAME', 'daemon-token')

    headers = {'Authorization': f"PVEAPIToken={api_user}!{token_name}={pve_token_secret}"}
    proxmox_workloads = {}

    try:
        nodes_url = f"https://{host}:{port}/api2/json/nodes"
        nodes_response = session.get(nodes_url, headers=headers, verify=False, timeout=timeout)
        nodes_response.raise_for_status()
        nodes = nodes_response.json().get('data', [])

        for node in nodes:
            node_name = node.get('node')
            if not node_name or node.get('status') != 'online':
                continue

            # --- Process QEMU VMs ---
            vms_url = f"https://{host}:{port}/api2/json/nodes/{node_name}/qemu"
            vms_response = session.get(vms_url, headers=headers, verify=False, timeout=timeout)
            vms_response.raise_for_status()
            vms_on_node = vms_response.json().get('data', [])

            for vm_summary in vms_on_node:
                vmid = vm_summary.get('vmid')
                vm_name = vm_summary.get('name')
                if not vmid or not vm_name: continue

                workload_details = {"vmid": vmid, "name": vm_name, "host-name": node_name, "status": vm_summary.get('status'), "interfaces": []}

                config_url = f"https://{host}:{port}/api2/json/nodes/{node_name}/qemu/{vmid}/config"
                config_response = session.get(config_url, headers=headers, verify=False, timeout=timeout)
                vm_config = config_response.json().get('data', {}) if config_response.ok else {}

                agent_ips_by_mac = {}
                if workload_details['status'] == 'running':
                    agent_url = f"https://{host}:{port}/api2/json/nodes/{node_name}/qemu/{vmid}/agent/network-get-interfaces"
                    try:
                        agent_response = session.get(agent_url, headers=headers, verify=False, timeout=5)
                        if agent_response.ok:
                            agent_data = agent_response.json().get('data', {}).get('result', [])
                            for interface in agent_data:
                                if interface.get('name') == 'lo': continue
                                mac = interface.get('hardware-address')
                                if mac:
                                    agent_ips_by_mac[mac.upper()] = [
                                        ip_info.get('ip-address') for ip_info in interface.get('ip-addresses', [])
                                        if ip_info.get('ip-address-type') == 'ipv4'
                                    ]
                    except requests.exceptions.RequestException:
                        pass

                for i in range(32):
                    net_key = f'net{i}'
                    if net_key in vm_config:
                        net_info_str = vm_config[net_key]
                        parts = net_info_str.split(',')
                        mac = next((p.split('=')[1] for p in parts if '=' in p and p.split('=')[0] in ['virtio', 'e1000', 'vmxnet3', 'rtl8139']), None)
                        if not mac: continue

                        bridge = next((p.split('=')[1] for p in parts if p.startswith('bridge=')), "N/A")
                        tag = "-1"

                        try:
                            if not bridge.startswith('vmbr'):
                                vnet_name = bridge
                                vnets_url = f"https://{host}:{port}/api2/json/cluster/sdn/vnets/{vnet_name}"
                                vnet_resp = session.get(vnets_url, headers=headers, verify=False)
                                if vnet_resp.ok:
                                    vnet_data = vnet_resp.json().get('data', {})
                                    tag = vnet_data.get('tag', '-1')
                            else:
                                tag = next((p.split('=')[1] for p in parts if p.startswith('tag=')), "-1")
                        except requests.exceptions.RequestException:
                            pass

                        if int(tag) > 0:
                            interface_data = {
                                "mac-address": format_mac_cisco(mac),
                                "external-vlan": int(tag),
                                "ip-addresses": agent_ips_by_mac.get(mac.upper(), [])
                            }
                            workload_details["interfaces"].append(interface_data)

                # --- THIS IS THE FIX ---
                # Only add the workload if it has interfaces AND is running.
                if workload_details["interfaces"] and workload_details['status'] == 'running':
                    proxmox_workloads[vm_name] = workload_details

            # --- Process LXC Containers ---
            lxcs_url = f"https://{host}:{port}/api2/json/nodes/{node_name}/lxc"
            lxcs_response = session.get(lxcs_url, headers=headers, verify=False, timeout=timeout)
            lxcs_response.raise_for_status()
            lxcs_on_node = lxcs_response.json().get('data', [])

            for lxc_summary in lxcs_on_node:
                vmid = lxc_summary.get('vmid')
                lxc_name = lxc_summary.get('name')
                if not vmid or not lxc_name: continue

                workload_details = {"vmid": vmid, "name": lxc_name, "host-name": node_name, "status": lxc_summary.get('status'), "interfaces": []}

                config_url = f"https://{host}:{port}/api2/json/nodes/{node_name}/lxc/{vmid}/config"
                config_response = session.get(config_url, headers=headers, verify=False, timeout=timeout)
                lxc_config = config_response.json().get('data', {}) if config_response.ok else {}

                for i in range(32):
                    net_key = f'net{i}'
                    if net_key in lxc_config:
                        net_info = lxc_config[net_key]
                        parts = {p.split('=')[0]: p.split('=')[1] for p in net_info.split(',') if '=' in p}

                        mac = parts.get('hwaddr')
                        bridge = parts.get('bridge')
                        tag = "-1"

                        if not mac or not bridge: continue

                        try:
                            if not bridge.startswith('vmbr'):
                                vnet_name = bridge
                                vnets_url = f"https://{host}:{port}/api2/json/cluster/sdn/vnets/{vnet_name}"
                                vnet_resp = session.get(vnets_url, headers=headers, verify=False)
                                if vnet_resp.ok:
                                    vnet_data = vnet_resp.json().get('data', {})
                                    tag = vnet_data.get('tag', '-1')
                            else:
                                tag = parts.get('tag', '-1')
                        except requests.exceptions.RequestException:
                            pass

                        if int(tag) > 0:
                            ips = [ip.split('/')[0] for ip in [parts.get('ip'), parts.get('ip6')] if ip and ip.lower() != 'dhcp']
                            interface_data = {
                                "mac-address": format_mac_cisco(mac),
                                "external-vlan": int(tag),
                                "ip-addresses": ips
                            }
                            workload_details["interfaces"].append(interface_data)

                # --- THIS IS THE FIX ---
                # Only add the workload if it has interfaces AND is running.
                if workload_details["interfaces"] and workload_details['status'] == 'running':
                    proxmox_workloads[lxc_name] = workload_details

        return proxmox_workloads
    except requests.exceptions.RequestException as e:
        print(f"[ERROR] Could not get Proxmox state: {e}")
        return None

def main():
    print("--- Starting Proxmox Guest Discovery Daemon (VMs & LXC) ---")

    poll_interval = 10
    output_file = "/var/run/proxmox_state.json"
    timeout = 15

    env_vars = load_environment()
    if not env_vars or 'PVE_TOKEN_SECRET_READ' not in env_vars:
        print("[FATAL ERROR] PVE_TOKEN_SECRET_READ not found in .env file or file is unreadable. Exiting.")
        sys.exit(1)
    print("[INFO] Proxmox token secret loaded successfully.")

    http_session = requests.Session()
    http_session.headers.update({'Connection': 'close'})

    try:
        while True:
            print(f"\n{'='*20} Discovery Cycle Started {'='*20}")

            print("--> Getting Proxmox guest state...")
            desired_workloads = get_proxmox_state(http_session, env_vars, timeout)

            if desired_workloads is not None:
                print(f"    Found {len(desired_workloads)} running workloads with tagged interfaces to report.")
                temp_file_path = f"{output_file}.tmp"
                try:
                    with open(temp_file_path, 'w') as f:
                        json.dump(desired_workloads, f, indent=2)
                    os.rename(temp_file_path, output_file)
                    print(f"    Successfully wrote state to {output_file}")
                except Exception as e:
                    print(f"    [ERROR] Failed to write state file: {e}")
            else:
                print("    Failed to retrieve Proxmox state. Will retry.")

            print(f"--- Discovery cycle finished. Waiting {poll_interval}s. ---")
            time.sleep(poll_interval)

    except KeyboardInterrupt:
        print("\n--- Interruption received. Stopping daemon. ---")

    finally:
        http_session.close()
        print("--- Proxmox Discovery Daemon stopped. ---")

if __name__ == "__main__":
    main()
