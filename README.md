# Proxmox SDN Orchestrators

This repository contains a complete SDN orchestrator management system for Proxmox VE, supporting both Pensando PSM and Aruba Fabric Composer (AFC) orchestrators.

## Features

- **Web UI Integration**: Full ExtJS-based management interface in Proxmox VE
- **REST API**: Complete CRUD operations for orchestrator management
- **Sync Daemons**: Background services that sync network state between Proxmox and orchestrators
- **Multi-orchestrator Support**: PSM and AFC with different authentication methods
- **Production Ready**: Systemd services, logging, and error handling

## Quick Installation

```bash
curl -fsSL https://raw.githubusercontent.com/farsonic/proxmox-orchestrator/main/install-orchestrators.sh | bash
```

## Post-Installation Setup

1. Create API token in Proxmox:
   - Go to Datacenter → Permissions → API Tokens
   - Create user: `sync-daemon@pve`
   - Create token: `daemon-token`
   - Grant appropriate permissions

2. Configure the token:
```bash
curl -fsSL https://raw.githubusercontent.com/farsonic/proxmox-orchestrator/main/setup-api-token.sh -o setup-api-token.sh
chmod +x setup-api-token.sh
./setup-api-token.sh your-token-secret-here
```

## Usage

1. Navigate to Datacenter → SDN → Orchestrators
2. Click "Add" to create PSM or AFC orchestrators
3. Configure connection settings and sync options
4. Monitor sync daemons: `journalctl -u proxmox-psm-sync -f`

## Components

- **API Backend**: `/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm`
- **Frontend**: JavaScript integration with Proxmox VE web interface
- **PSM Daemon**: `psm_sync_daemon.py` - Syncs with Pensando PSM
- **AFC Daemon**: `afc_sync_daemon.py` - Syncs with Aruba Fabric Composer

## Requirements

- Proxmox VE 7.0+
- Python 3.6+
- Network access to orchestrator devices

## License

[Your License Here]

## Support

For issues and questions, please open an issue in this repository.
