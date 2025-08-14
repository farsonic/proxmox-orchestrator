#!/bin/bash
# Enhanced SDN Orchestrator Uninstaller
# Rolls back all changes made by the orchestrator install script
# by restoring original files from backups and deleting new files.
set -e

# --- Configuration ---
BACKUP_DIR="/root/backups"

# Core Proxmox files that were modified
JS_TARGET_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
SDN_API_FILE="/usr/share/perl5/PVE/API2/Network/SDN.pm"
VNET_PLUGIN_FILE="/usr/share/perl5/PVE/Network/SDN/VnetPlugin.pm"

# New custom files/dirs that were added
CUSTOM_PERL_API="/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm"
CUSTOM_PERL_LOGIC="/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm"
CUSTOM_PERL_DIR="/usr/share/perl5/PVE/Network/SDN/Orchestrators/"

# Configuration files
CONFIG_FILE="/etc/pve/sdn/orchestrators.cfg"

# Daemon-related files (if they exist)
DAEMON_DIR="/tmp/proxmox-sync-daemon"
SYSTEMD_SERVICES=(
    "/etc/systemd/system/psm-sync-daemon.service"
    "/etc/systemd/system/afc-sync-daemon.service"
    "/etc/systemd/system/orchestrators-config.path"
)

# --- Helper Functions ---
function print_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
function print_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
function print_warning() { echo -e "\e[33m[WARNING]\e[0m $1"; }
function print_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

# Function to find latest backup
find_latest_backup() {
    local pattern="$1"
    local latest=$(ls -t "$BACKUP_DIR"/$pattern 2>/dev/null | head -n1)
    echo "$latest"
}

# Function to restore file from backup
restore_file() {
    local target_file="$1"
    local backup_pattern="$2"
    local description="$3"
    
    local latest_backup=$(find_latest_backup "$backup_pattern")
    
    if [ -f "$latest_backup" ]; then
        print_info "  -> Restoring '$target_file' from '$latest_backup'..."
        cp "$latest_backup" "$target_file"
        print_success "     Done."
        return 0
    else
        print_warning "  -> No backup found for $description. Skipping."
        return 1
    fi
}

# Function to remove file safely
remove_file() {
    local file="$1"
    local description="$2"
    
    if [ -f "$file" ]; then
        rm -f "$file"
        print_success "  -> Removed $description"
    else
        print_info "  -> $description not found (already removed)"
    fi
}

# Function to remove directory safely
remove_directory() {
    local dir="$1"
    local description="$2"
    
    if [ -d "$dir" ]; then
        rm -rf "$dir"
        print_success "  -> Removed $description"
    else
        print_info "  -> $description not found (already removed)"
    fi
}

# --- Main Script ---
if [[ "$EUID" -ne 0 ]]; then
   print_error "This script must be run as root."
   exit 1
fi

echo "🗑️  Enhanced SDN Orchestrator Uninstaller"
echo "========================================="
print_info "Starting rollback of SDN Orchestrator modifications..."

# 1. Stop any running daemons
print_info "Stopping orchestrator daemons..."
for service in psm-sync-daemon afc-sync-daemon orchestrators-config.path; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        systemctl stop "$service"
        print_success "  -> Stopped $service"
    fi
    
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        systemctl disable "$service"
        print_success "  -> Disabled $service"
    fi
done

# 2. Remove systemd service files
print_info "Removing systemd service files..."
for service_file in "${SYSTEMD_SERVICES[@]}"; do
    remove_file "$service_file" "$(basename "$service_file")"
done

# Reload systemd after removing services
if systemctl daemon-reload 2>/dev/null; then
    print_success "  -> Reloaded systemd daemon"
fi

# 3. Remove daemon directory
print_info "Removing daemon directories..."
remove_directory "$DAEMON_DIR" "daemon directory"
remove_directory "/opt/proxmox-sdn-orchestrators" "alternative daemon directory"

# 4. Remove API user (if it exists)
print_info "Removing API user..."
if pveum user list 2>/dev/null | grep -q "orchestrator@pve"; then
    pveum user delete "orchestrator@pve" 2>/dev/null || true
    print_success "  -> Removed orchestrator API user"
else
    print_info "  -> No orchestrator API user found"
fi

# 5. Restore original files from the latest backups
print_info "Restoring original Proxmox files..."

# Restore pvemanagerlib.js
restore_file "$JS_TARGET_FILE" "pvemanagerlib.js.bak-*" "pvemanagerlib.js"

# Restore SDN.pm
restore_file "$SDN_API_FILE" "SDN.pm.bak-*" "SDN.pm"

# Restore VnetPlugin.pm
restore_file "$VNET_PLUGIN_FILE" "VnetPlugin.pm.bak-*" "VnetPlugin.pm"

# 6. Remove newly added custom files
print_info "Removing custom orchestrator files..."
remove_file "$CUSTOM_PERL_API" "API orchestrator module"
remove_file "$CUSTOM_PERL_LOGIC" "orchestrator logic module"
remove_directory "$CUSTOM_PERL_DIR" "orchestrator plugins directory"

# 7. Handle configuration file
print_info "Handling configuration file..."
if [ -f "$CONFIG_FILE" ]; then
    read -p "Remove orchestrator configuration file ($CONFIG_FILE)? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Backup config before removing
        if [ ! -d "$BACKUP_DIR" ]; then
            mkdir -p "$BACKUP_DIR"
        fi
        cp "$CONFIG_FILE" "$BACKUP_DIR/orchestrators.cfg.removed-$(date +%Y%m%d-%H%M%S)"
        rm "$CONFIG_FILE"
        print_success "  -> Removed configuration file (backed up)"
    else
        print_info "  -> Configuration file preserved"
    fi
else
    print_info "  -> No configuration file found"
fi

# 8. Validate removal
print_info "Validating removal..."

# Check for remaining orchestrator files
REMAINING_FILES=()
CHECK_LOCATIONS=(
    "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm"
    "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm"
    "/usr/share/perl5/PVE/Network/SDN/Orchestrators/"
    "/tmp/proxmox-sync-daemon"
    "/opt/proxmox-sdn-orchestrators"
)

for location in "${CHECK_LOCATIONS[@]}"; do
    if [ -e "$location" ]; then
        REMAINING_FILES+=("$location")
    fi
done

if [ ${#REMAINING_FILES[@]} -gt 0 ]; then
    print_warning "Some orchestrator files still exist:"
    for file in "${REMAINING_FILES[@]}"; do
        print_warning "  - $file"
    done
else
    print_success "  -> All orchestrator files removed"
fi

# Check for remaining processes
if pgrep -f "sync_daemon\|orchestrator" > /dev/null 2>&1; then
    print_warning "Some orchestrator processes still running:"
    pgrep -af "sync_daemon\|orchestrator" || true
    print_info "  -> Kill manually if needed: pkill -f sync_daemon"
else
    print_success "  -> No orchestrator processes running"
fi

# Check for orchestrator content in JavaScript
if [ -f "$JS_TARGET_FILE" ] && grep -q "orchestrator\|Orchestrator" "$JS_TARGET_FILE"; then
    ORCH_REFS=$(grep -c "orchestrator\|Orchestrator" "$JS_TARGET_FILE" 2>/dev/null || echo "0")
    if [ "$ORCH_REFS" -gt 5 ]; then  # More than a few normal references
        print_warning "JavaScript file may still contain orchestrator code ($ORCH_REFS references)"
        print_info "  -> Check if restore was successful"
    else
        print_success "  -> JavaScript file appears clean"
    fi
else
    print_success "  -> No orchestrator references in JavaScript"
fi

# 9. Restart Proxmox Service
print_info "Restarting Proxmox API service to apply rollback..."
if systemctl restart pveproxy; then
    print_success "  -> pveproxy service restarted"
else
    print_warning "  -> Failed to restart pveproxy service"
fi

# 10. Final summary
echo ""
print_success "🎉 Rollback completed!"
echo ""
print_info "Summary:"
echo "  🔄 Services: Stopped and removed"
echo "  📁 Files: Restored from backups"
echo "  🗑️  Custom code: Removed"
echo "  ⚙️  Service: Restarted"
echo ""
print_info "System state:"
echo "  ✅ Restored to original Proxmox configuration"
echo "  ✅ All orchestrator components removed"
echo "  ✅ Ready for clean installation"
echo ""
print_info "Available backups in $BACKUP_DIR:"
ls -la "$BACKUP_DIR"/ 2>/dev/null | grep -E "\.(bak|removed)-" || echo "  (no backup files found)"
echo ""
print_info "Next steps:"
echo "  1. Clear browser cache completely"
echo "  2. Verify Proxmox UI works normally"
echo "  3. Run install script for clean test: ./install.sh"
echo ""
print_success "System is ready for a fresh orchestrator installation! 🚀"
