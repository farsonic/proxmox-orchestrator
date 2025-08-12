#!/bin/bash

# Proxmox SDN Orchestrators Uninstaller
# Repository: https://github.com/farsonic/proxmox-orchestrator
# Usage: curl -fsSL https://raw.githubusercontent.com/farsonic/proxmox-orchestrator/main/uninstall-orchestrators.sh | bash

set -e

DAEMON_DIR="/tmp/proxmox-sync-daemon"  # Match your existing setup
BACKUP_DIR="/root/orchestrators-backup-$(date +%Y%m%d-%H%M%S)"

# Helper Functions
function print_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
function print_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
function print_warning() { echo -e "\e[33m[WARNING]\e[0m $1"; }
function print_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

echo "🗑️  Uninstalling Proxmox SDN Orchestrators..."
echo "📦 Repository: https://github.com/farsonic/proxmox-orchestrator"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root. Please run: sudo $0"
    exit 1
fi

# Create backup directory for current configs
mkdir -p "$BACKUP_DIR"
print_success "Created backup directory: $BACKUP_DIR"

# Function to backup file before removing
backup_and_remove() {
    local file="$1"
    local description="$2"
    
    if [ -f "$file" ]; then
        print_info "Backing up and removing $description..."
        cp "$file" "$BACKUP_DIR/" 2>/dev/null || print_warning "Could not backup $file"
        rm -f "$file"
        print_success "Removed $file"
    else
        print_info "$description not found at $file"
    fi
}

# Function to restore SDN.pm from backup if available
restore_sdn_registration() {
    local sdn_file="/usr/share/perl5/PVE/API2/Network/SDN.pm"
    
    print_info "Removing SDN API registration..."
    
    if [ ! -f "$sdn_file" ]; then
        print_warning "SDN.pm not found"
        return
    fi
    
    # Backup current file
    cp "$sdn_file" "$BACKUP_DIR/"
    
    # Remove our import line
    if sed -i '/^use PVE::API2::Network::SDN::Orchestrators;$/d' "$sdn_file"; then
        print_success "Removed import statement"
    else
        print_warning "Could not remove import statement"
    fi
    
    # Remove our registration block (multi-line)
    if sed -i '/^__PACKAGE__->register_method({$/,/^});$/{ /subclass.*Orchestrators/d; /path.*orchestrators/d; /^__PACKAGE__->register_method({$/d; /^});$/d; }' "$sdn_file"; then
        print_success "Removed API registration"
    else
        print_warning "Could not remove API registration"
    fi
}

# Function to remove JavaScript from pvemanagerlib.js
remove_javascript() {
    local js_file="/usr/share/pve-manager/js/pvemanagerlib.js"
    
    print_info "Removing JavaScript from pvemanagerlib.js..."
    
    if [ ! -f "$js_file" ]; then
        print_warning "pvemanagerlib.js not found"
        return
    fi
    
    # Backup current file
    cp "$js_file" "$BACKUP_DIR/"
    
    # Remove our JavaScript block (from our comment marker to end of file, then restore original end)
    if grep -q "SDN Orchestrators.*Auto-installed" "$js_file"; then
        # Create temp file with everything before our installation
        sed '/\/\/ SDN Orchestrators.*Auto-installed/,$d' "$js_file" > "${js_file}.tmp"
        
        # Replace original file
        mv "${js_file}.tmp" "$js_file"
        print_success "Removed JavaScript code"
    else
        print_info "JavaScript code not found or not marked as auto-installed"
    fi
}

# Prompt for confirmation
echo "⚠️  This will remove all Proxmox SDN Orchestrator components."
echo "   The following will be removed:"
echo "   • API backend modules"
echo "   • Configuration modules" 
echo "   • Frontend JavaScript"
echo "   • Sync daemons and systemd services (including path monitors)"
echo "   • SDN API registration"
echo "   • API user and token"
echo ""
echo "   Configuration files in /etc/pve/sdn/ will be preserved."
echo "   Backups will be saved to: $BACKUP_DIR"
echo ""
read -p "Continue with uninstallation? (y/N): " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_error "Uninstallation cancelled"
    exit 0
fi

print_info "Starting uninstallation..."

# Stop and disable systemd services (including path monitors)
print_info "Stopping and disabling services..."

for service in "proxmox-psm-sync" "proxmox-afc-sync"; do
    # Stop and disable main service
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        print_info "Stopping $service..."
        systemctl stop "$service"
    fi
    
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        print_info "Disabling $service..."
        systemctl disable "$service"
    fi
    
    # Stop and disable path monitor
    if systemctl is-active --quiet "${service}.path" 2>/dev/null; then
        print_info "Stopping ${service}.path..."
        systemctl stop "${service}.path"
    fi
    
    if systemctl is-enabled --quiet "${service}.path" 2>/dev/null; then
        print_info "Disabling ${service}.path..."
        systemctl disable "${service}.path"
    fi
    
    # Remove service files
    backup_and_remove "/etc/systemd/system/${service}.service" "$service systemd service"
    backup_and_remove "/etc/systemd/system/${service}.path" "$service path monitor"
done

# Reload systemd
systemctl daemon-reload
print_success "Systemd reloaded"

# Remove API user and token
print_info "Removing API user and token..."
PVE_USER="sync-daemon@pve"
PVE_TOKEN_NAME="daemon-token"

if pveum user token list "$PVE_USER" 2>/dev/null | grep -q "$PVE_TOKEN_NAME"; then
    pveum user token delete "$PVE_USER" "$PVE_TOKEN_NAME" &>/dev/null || print_warning "Could not delete token"
    print_success "Removed API token"
fi

if pveum user list | grep -q "^$PVE_USER"; then
    pveum user delete "$PVE_USER" &>/dev/null || print_warning "Could not delete user"
    print_success "Removed API user"
fi

echo ""
print_info "Removing backend files..."

# Remove API backend
backup_and_remove "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" "API Backend"

# Remove configuration module  
backup_and_remove "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" "Configuration Module"

echo ""
print_info "Removing frontend files..."

# Remove JavaScript
remove_javascript

echo ""
print_info "Removing sync daemons..."

# Remove daemon directory
if [ -d "$DAEMON_DIR" ]; then
    print_info "Backing up daemon directory..."
    cp -r "$DAEMON_DIR" "$BACKUP_DIR/"
    print_info "Removing daemon directory..."
    rm -rf "$DAEMON_DIR"
    print_success "Removed $DAEMON_DIR"
else
    print_info "Daemon directory not found"
fi

echo ""
print_info "Removing API registration..."

# Remove SDN registration
restore_sdn_registration

echo ""
print_info "Restarting Proxmox services..."

# Restart Proxmox services
systemctl restart pveproxy
systemctl restart pvedaemon

# Wait a moment for services to start
sleep 3

echo ""
print_info "Verifying removal..."

# Check that files are removed
removed_count=0
total_count=4

if [ ! -f "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" ]; then
    print_success "API backend removed"
    ((removed_count++))
else
    print_error "API backend still present"
fi

if [ ! -f "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" ]; then
    print_success "Configuration module removed"
    ((removed_count++))
else
    print_error "Configuration module still present"
fi

if ! grep -q "sdnOrchestratorSchema" "/usr/share/pve-manager/js/pvemanagerlib.js" 2>/dev/null; then
    print_success "Frontend code removed"
    ((removed_count++))
else
    print_error "Frontend code still present"
fi

if [ ! -d "$DAEMON_DIR" ]; then
    print_success "Sync daemons removed"
    ((removed_count++))
else
    print_error "Sync daemons still present"
fi

if ! systemctl is-enabled proxmox-psm-sync >/dev/null 2>&1 && \
   ! systemctl is-enabled proxmox-afc-sync >/dev/null 2>&1 && \
   ! systemctl is-enabled proxmox-psm-sync.path >/dev/null 2>&1 && \
   ! systemctl is-enabled proxmox-afc-sync.path >/dev/null 2>&1; then
    print_success "Systemd services and path monitors removed"
else
    print_error "Some systemd services still enabled"
fi

echo ""
if [ "$removed_count" -eq "$total_count" ]; then
    print_success "Uninstallation completed successfully!"
else
    print_warning "Uninstallation partially completed ($removed_count/$total_count components removed)"
fi

echo ""
echo "📋 Summary:"
echo "   • Removed API backend and configuration modules"
echo "   • Removed frontend JavaScript integration"
echo "   • Removed sync daemons and systemd services"
echo "   • Removed systemd path monitors"
echo "   • Removed API user and token"
echo "   • Removed SDN API registration"
echo "   • Restarted Proxmox services"
echo ""
echo "📁 Backup files saved to: $BACKUP_DIR"
echo ""
echo "ℹ️  Configuration files preserved:"
echo "   • /etc/pve/sdn/orchestrators.cfg (if exists)"
echo "   • Any orchestrator configurations you created"
echo ""
echo "🔄 Manual cleanup (if needed):"
echo "   • Clear browser cache"
echo "   • Remove /etc/pve/sdn/orchestrators.cfg if no longer needed"
echo "   • Remove backup directory: rm -rf $BACKUP_DIR"
echo ""
echo "📖 For issues: https://github.com/farsonic/proxmox-orchestrator/issues"

# Check if any orchestrator configs exist
if [ -f "/etc/pve/sdn/orchestrators.cfg" ]; then
    echo ""
    print_warning "Orchestrator configuration file still exists:"
    echo "   /etc/pve/sdn/orchestrators.cfg"
    echo ""
    echo "   This file contains your orchestrator settings and was preserved."
    echo "   Remove it manually if you no longer need the configurations:"
    echo "   rm /etc/pve/sdn/orchestrators.cfg"
fi
