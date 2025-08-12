#!/bin/bash

# Proxmox SDN Orchestrators Uninstaller
# Repository: https://github.com/farsonic/proxmox-orchestrator
# Usage: curl -fsSL https://raw.githubusercontent.com/farsonic/proxmox-orchestrator/main/uninstall-orchestrators.sh | bash

set -e

DAEMON_DIR="/opt/proxmox-sdn-orchestrators"
BACKUP_DIR="/root/orchestrators-backup-$(date +%Y%m%d-%H%M%S)"

echo "🗑️  Uninstalling Proxmox SDN Orchestrators..."
echo "📦 Repository: https://github.com/farsonic/proxmox-orchestrator"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root"
    echo "   Please run: sudo $0"
    exit 1
fi

# Create backup directory for current configs
mkdir -p "$BACKUP_DIR"
echo "📁 Created backup directory: $BACKUP_DIR"

# Function to backup file before removing
backup_and_remove() {
    local file="$1"
    local description="$2"
    
    if [ -f "$file" ]; then
        echo "💾 Backing up and removing $description..."
        cp "$file" "$BACKUP_DIR/" 2>/dev/null || echo "   ⚠️  Could not backup $file"
        rm -f "$file"
        echo "   ✅ Removed $file"
    else
        echo "   ℹ️  $description not found at $file"
    fi
}

# Function to restore SDN.pm from backup if available
restore_sdn_registration() {
    local sdn_file="/usr/share/perl5/PVE/API2/Network/SDN.pm"
    
    echo "📝 Removing SDN API registration..."
    
    if [ ! -f "$sdn_file" ]; then
        echo "   ⚠️  SDN.pm not found"
        return
    fi
    
    # Backup current file
    cp "$sdn_file" "$BACKUP_DIR/"
    
    # Remove our import line
    if sed -i '/^use PVE::API2::Network::SDN::Orchestrators;$/d' "$sdn_file"; then
        echo "   ✅ Removed import statement"
    else
        echo "   ⚠️  Could not remove import statement"
    fi
    
    # Remove our registration block (multi-line)
    if sed -i '/^__PACKAGE__->register_method({$/,/^});$/{ /subclass.*Orchestrators/d; /path.*orchestrators/d; /^__PACKAGE__->register_method({$/d; /^});$/d; }' "$sdn_file"; then
        echo "   ✅ Removed API registration"
    else
        echo "   ⚠️  Could not remove API registration"
    fi
}

# Function to remove JavaScript from pvemanagerlib.js
remove_javascript() {
    local js_file="/usr/share/pve-manager/js/pvemanagerlib.js"
    
    echo "📝 Removing JavaScript from pvemanagerlib.js..."
    
    if [ ! -f "$js_file" ]; then
        echo "   ⚠️  pvemanagerlib.js not found"
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
        echo "   ✅ Removed JavaScript code"
    else
        echo "   ℹ️  JavaScript code not found or not marked as auto-installed"
    fi
}

# Prompt for confirmation
echo "⚠️  This will remove all Proxmox SDN Orchestrator components."
echo "   The following will be removed:"
echo "   • API backend modules"
echo "   • Configuration modules" 
echo "   • Frontend JavaScript"
echo "   • Sync daemons"
echo "   • Systemd services"
echo "   • SDN API registration"
echo ""
echo "   Configuration files in /etc/pve/sdn/ will be preserved."
echo "   Backups will be saved to: $BACKUP_DIR"
echo ""
read -p "Continue with uninstallation? (y/N): " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "❌ Uninstallation cancelled"
    exit 0
fi

echo ""
echo "🛑 Stopping and disabling services..."

# Stop and disable systemd services
for service in "proxmox-psm-sync" "proxmox-afc-sync"; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "⏹️  Stopping $service..."
        systemctl stop "$service"
    fi
    
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo "❌ Disabling $service..."
        systemctl disable "$service"
    fi
    
    service_file="/etc/systemd/system/${service}.service"
    backup_and_remove "$service_file" "$service systemd service"
done

# Reload systemd
systemctl daemon-reload
echo "✅ Systemd reloaded"

echo ""
echo "🗂️  Removing backend files..."

# Remove API backend
backup_and_remove "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" "API Backend"

# Remove configuration module  
backup_and_remove "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" "Configuration Module"

echo ""
echo "🌐 Removing frontend files..."

# Remove JavaScript
remove_javascript

echo ""
echo "🤖 Removing sync daemons..."

# Remove daemon directory
if [ -d "$DAEMON_DIR" ]; then
    echo "💾 Backing up daemon directory..."
    cp -r "$DAEMON_DIR" "$BACKUP_DIR/"
    echo "🗑️  Removing daemon directory..."
    rm -rf "$DAEMON_DIR"
    echo "   ✅ Removed $DAEMON_DIR"
else
    echo "   ℹ️  Daemon directory not found"
fi

echo ""
echo "📝 Removing API registration..."

# Remove SDN registration
restore_sdn_registration

echo ""
echo "🔄 Restarting Proxmox services..."

# Restart Proxmox services
systemctl restart pveproxy
systemctl restart pvedaemon

# Wait a moment for services to start
sleep 3

echo ""
echo "🔍 Verifying removal..."

# Check that files are removed
removed_count=0
total_count=4

if [ ! -f "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" ]; then
    echo "✅ API backend removed"
    ((removed_count++))
else
    echo "❌ API backend still present"
fi

if [ ! -f "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" ]; then
    echo "✅ Configuration module removed"
    ((removed_count++))
else
    echo "❌ Configuration module still present"
fi

if ! grep -q "sdnOrchestratorSchema" "/usr/share/pve-manager/js/pvemanagerlib.js" 2>/dev/null; then
    echo "✅ Frontend code removed"
    ((removed_count++))
else
    echo "❌ Frontend code still present"
fi

if [ ! -d "$DAEMON_DIR" ]; then
    echo "✅ Sync daemons removed"
    ((removed_count++))
else
    echo "❌ Sync daemons still present"
fi

if ! systemctl is-enabled proxmox-psm-sync >/dev/null 2>&1 && ! systemctl is-enabled proxmox-afc-sync >/dev/null 2>&1; then
    echo "✅ Systemd services removed"
else
    echo "❌ Some systemd services still enabled"
fi

echo ""
if [ "$removed_count" -eq "$total_count" ]; then
    echo "🎉 Uninstallation completed successfully!"
else
    echo "⚠️  Uninstallation partially completed ($removed_count/$total_count components removed)"
fi

echo ""
echo "📋 Summary:"
echo "   • Removed API backend and configuration modules"
echo "   • Removed frontend JavaScript integration"
echo "   • Removed sync daemons and systemd services"
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
    echo "⚠️  Orchestrator configuration file still exists:"
    echo "   /etc/pve/sdn/orchestrators.cfg"
    echo ""
    echo "   This file contains your orchestrator settings and was preserved."
    echo "   Remove it manually if you no longer need the configurations:"
    echo "   rm /etc/pve/sdn/orchestrators.cfg"
fi
