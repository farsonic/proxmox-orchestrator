# Proxmox SDN Orchestrators

A complete SDN orchestrator management system for Proxmox VE, supporting both Pensando PSM and Aruba Fabric Composer (AFC) orchestrators with automatic synchronization.

## Features

- **Backend API**: Complete Perl modules for orchestrator management
- **Frontend UI**: Integrated web interface in Proxmox SDN Options panel
- **VNet Orchestration**: Selective orchestration control per VNet
- **Sync Daemons**: Automatic background synchronization services
- **Multi-orchestrator**: Support for PSM and AFC with different authentication methods
- **Production Ready**: Systemd services, logging, and error handling

## Quick Install

```bash
# Clone and install
git clone https://github.com/farsonic/proxmox-orchestrator.git
cd proxmox-orchestrator
sudo ./universal-install.sh
Quick Uninstall
bashsudo ./universal-uninstall.sh
Usage

Install: Run the universal installer
Configure: Datacenter → SDN → Options → Orchestrators
Create: Add PSM or AFC orchestrators with credentials
Enable: Create VNets with "Orchestration" checkbox enabled
Automatic: Sync daemons manage orchestrated VNets automatically

Components
Backend (Perl)

PVE/API2/Network/SDN/Orchestrators.pm - REST API implementation
PVE/Network/SDN/Orchestrators.pm - Configuration management
PVE/Network/SDN/Orchestrators/Plugin.pm - Base plugin class
PVE/Network/SDN/Orchestrators/PsmPlugin.pm - Pensando PSM plugin
PVE/Network/SDN/Orchestrators/AfcPlugin.pm - Aruba AFC plugin

Frontend (JavaScript)

js/orchestrators.js - Complete UI implementation with forms and grids

Sync Daemons (Python)

daemons/psm_sync_daemon.py - PSM synchronization service
daemons/afc_sync_daemon.py - AFC synchronization service

Tools

universal-install.sh - Complete installation script
universal-uninstall.sh - Safe removal script
health-check.sh - System validation and diagnostics
setup-api-token.sh - Manual API token configuration

Architecture
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Proxmox UI    │    │   Sync Daemons   │    │  Orchestrators  │
│                 │    │                  │    │                 │
│ ┌─────────────┐ │    │ ┌──────────────┐ │    │ ┌─────────────┐ │
│ │Orchestrators│ │    │ │ PSM Daemon   │ │    │ │ Pensando    │ │
│ │   Panel     │ │    │ │              │ │    │ │    PSM      │ │
│ └─────────────┘ │    │ └──────────────┘ │    │ └─────────────┘ │
│                 │    │                  │    │                 │
│ ┌─────────────┐ │    │ ┌──────────────┐ │    │ ┌─────────────┐ │
│ │    VNets    │ │    │ │ AFC Daemon   │ │    │ │   Aruba     │ │
│ │(Orchestrated│ │    │ │              │ │    │ │    AFC      │ │
│ │             │ │    │ └──────────────┘ │    │ └─────────────┘ │
│ └─────────────┘ │    └──────────────────┘    └─────────────────┘
└─────────────────┘            │                        │
         │                     │                        │
         └─────────────────────┼────────────────────────┘
                              │
                    ┌──────────────────┐
                    │ orchestrators.cfg │
                    │  Configuration   │
                    └──────────────────┘
Requirements

Proxmox VE 7.0+
Root access
Internet connectivity for installation
Python 3 with requests module

Troubleshooting
Run the health check to diagnose issues:
bashsudo ./health-check.sh --detailed
Common issues:

Permission errors: Run as root
Service failures: Check journalctl -u proxmox-psm-sync
UI not showing: Clear browser cache
Syntax errors: Run health check for validation

Development
Testing
bash# Install
sudo ./universal-install.sh

# Validate
sudo ./health-check.sh --detailed

# Test functionality
# 1. Check UI: Datacenter → SDN → Options → Orchestrators
# 2. Create test orchestrator
# 3. Create VNet with orchestration enabled
# 4. Monitor daemon logs

# Uninstall
sudo ./universal-uninstall.sh
Contributing

Fork the repository
Create feature branch
Test thoroughly with health-check.sh
Submit pull request

License
[Your License Here]
Support

GitHub Issues: https://github.com/farsonic/proxmox-orchestrator/issues
Documentation: See docs/ directory
Health Check: ./health-check.sh --detailed
