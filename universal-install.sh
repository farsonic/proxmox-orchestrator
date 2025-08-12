#!/bin/bash

# Universal Proxmox SDN Orchestrators Installer
# Installs: Backend API, Frontend UI, VNet Patches, and Sync Daemons
# Run from /var/tmp/proxmox-orchestrator directory

set -e

echo "🚀 Universal Proxmox SDN Orchestrators Installer"
echo "📦 Installing: Backend API + Frontend UI + VNet Patches + Sync Daemons"
echo ""

# --- Configuration ---
INSTALL_DIR="/tmp/proxmox-sync-daemon"
CONFIG_FILE="/etc/pve/sdn/orchestrators.cfg"
BACKUP_DIR="/root/orchestrators-universal-$(date +%Y%m%d-%H%M%S)"

# --- Helper Functions ---
function print_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
function print_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
function print_warning() { echo -e "\e[33m[WARNING]\e[0m $1"; }
function print_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

# --- Pre-flight Checks ---
print_info "Running pre-flight checks..."

if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
fi

if [ ! -f "README.md" ] || [ ! -d "PVE" ] || [ ! -d "js" ] || [ ! -d "daemons" ]; then
    print_error "Must run from proxmox-orchestrator repository directory"
    echo "Expected: README.md, PVE/, js/, daemons/"
    exit 1
fi

if [ ! -f "/usr/share/perl5/PVE/API2/Network/SDN.pm" ]; then
    print_error "This doesn't appear to be a Proxmox VE system"
    exit 1
fi

print_success "Pre-flight checks passed"

# Create backup and include all the functions from our previous universal installer...
# [Include all the functions: install_backend, register_with_proxmox, install_frontend, apply_vnet_patches, install_sync_daemons, final_setup]

# Main installation flow with VNet patches
install_backend || { print_error "Backend installation failed"; exit 1; }
register_with_proxmox || { print_error "Proxmox registration failed"; exit 1; }
install_frontend || { print_error "Frontend installation failed"; exit 1; }
apply_vnet_patches || { print_error "VNet orchestration patches failed"; exit 1; }
install_sync_daemons || { print_error "Sync daemon installation failed"; exit 1; }
final_setup || { print_error "Final setup failed"; exit 1; }

print_success "🎉 Universal installation completed successfully!"
# [Include success message with VNet patch info]
