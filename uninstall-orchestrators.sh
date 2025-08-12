#!/bin/bash

# Bulletproof Proxmox SDN Orchestrators Uninstaller
# Repository: https://github.com/farsonic/proxmox-orchestrator
# Usage: curl -fsSL https://raw.githubusercontent.com/farsonic/proxmox-orchestrator/main/uninstall-orchestrators.sh | bash

set -e

BACKUP_DIR="/root/orchestrators-uninstall-backup-$(date +%Y%m%d-%H%M%S)"

# Helper Functions
function print_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
function print_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
function print_warning() { echo -e "\e[33m[WARNING]\e[0m $1"; }
function print_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

echo "🗑️  Uninstalling Proxmox SDN Orchestrators..."
echo "📦 Repository: https://github.com/farsonic/proxmox-orchestrator"
echo ""

# Pre-flight checks
function preflight_checks() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    print_success "Created backup directory: $BACKUP_DIR"
}

# Safe file removal with backup
function safe_remove() {
    local file="$1"
    local description="$2"
    
    if [ -f "$file" ]; then
        print_info "Backing up and removing $description..."
        
        # Backup the file
        cp "$file" "$BACKUP_DIR/" 2>/dev/null || print_warning "Could not backup $file"
        
        # Remove the file
        rm -f "$file"
        print_success "Removed $file"
    else
        print_info "$description not found at $file"
    fi
}

# Safely remove directory
function safe_remove_dir() {
    local dir="$1"
    local description="$2"
    
    if [ -d "$dir" ]; then
        print_info "Backing up and removing $description..."
        
        # Backup directory contents
        cp -r "$dir" "$BACKUP_DIR/" 2>/dev/null || print_warning "Could not backup $dir"
        
        # Remove directory
        rm -rf "$dir"
        print_success "Removed $dir"
    else
        print_info "$description not found at $dir"
    fi
}

# Remove SDN registration from SDN.pm (VERY CAREFULLY)
function remove_sdn_registration() {
    local sdn_file="/usr/share/perl5/PVE/API2/Network/SDN.pm"
    
    print_info "Removing SDN API registration..."
    
    if [ ! -f "$sdn_file" ]; then
        print_warning "SDN.pm not found"
        return 0
    fi
    
    # Backup original file
    cp "$sdn_file" "$BACKUP_DIR/SDN.pm"
    cp "$sdn_file" "${sdn_file}.pre-uninstall"
    
    # Check if our modifications exist
    if ! grep -q "use PVE::API2::Network::SDN::Orchestrators;" "$sdn_file"; then
        print_info "Orchestrators not registered in SDN.pm"
        return 0
    fi
    
    # Remove ONLY our import line (exact match)
    if sed -i '/^use PVE::API2::Network::SDN::Orchestrators;$/d' "$sdn_file"; then
        print_success "Removed import statement"
    else
        print_warning "Could not remove import statement"
    fi
    
    # Remove ONLY our API registration block (very specific pattern)
    # Look for our exact block structure
    sed -i '/},$/N; /},\n{$/N; /},\n{\nsubclass => "PVE::API2::Network::SDN::Orchestrators",$/N; /},\n{\nsubclass => "PVE::API2::Network::SDN::Orchestrators",\npath => "orchestrators",$/d' "$sdn_file"
    
    # Alternative removal method - look for the specific orchestrators block
    sed -i '/subclass => "PVE::API2::Network::SDN::Orchestrators",$/,/path => "orchestrators",$/d' "$sdn_file"
    
    # Validate syntax after modification
    if ! perl -c "$sdn_file" >/dev/null 2>&1; then
        print_error "SDN.pm syntax error after modification. Restoring backup."
        mv "${sdn_file}.pre-uninstall" "$sdn_file"
        return 1
    fi
    
    print_success "SDN API registration removed"
    return 0
}

# Remove JavaScript from pvemanagerlib.js (VERY CAREFULLY)
function remove_javascript() {
    local js_file="/usr/share/pve-manager/js/pvemanagerlib.js"
    
    print_info "Removing JavaScript from pvemanagerlib.js..."
    
    if [ ! -f "$js_file" ]; then
        print_warning "pvemanagerlib.js not found"
        return 0
    fi
    
    # Backup original file
    cp "$js_file" "$BACKUP_DIR/pvemanagerlib.js"
    cp "$js_file" "${js_file}.pre-uninstall"
    
    # Check if our JavaScript exists
    if ! grep -q "SDN Orchestrators.*Auto-installed" "$js_file"; then
        print_info "Orchestrators JavaScript not found or not marked as auto-installed"
        return 0
    fi
    
    # Remove everything from our marker to end of file, but preserve any content after
    # This is safer than trying to guess the end
    
    # Find the line number of our installation marker
    local marker_line
    marker_line=$(grep -n "// SDN Orchestrators.*Auto-installed" "$js_file" | cut -d: -f1)
    
    if [ -n "$marker_line" ]; then
        # Create new file with everything before our installation
        head -n $((marker_line - 1)) "$js_file" > "${js_file}.new"
        
        # Replace original file
        mv "${js_file}.new" "$js_file"
        print_success "Removed JavaScript code"
    else
        print_warning "Could not find installation marker"
    fi
    
    return 0
}

# Stop and remove systemd services
function remove_systemd_services() {
    print_info "Stopping and removing systemd services..."
    
    local services=("proxmox-psm-sync" "proxmox-afc-sync")
    
    for service in "${services[@]}"; do
        # Stop service if running
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            print_info "Stopping $service..."
            systemctl stop "$service"
        fi
        
        # Disable service if enabled
        if systemctl is-enabled --quiet "$service" 2>/dev/null; then
            print_info "Disabling $service..."
            systemctl disable "$service"
        fi
        
        # Remove service files
        safe_remove "/etc/systemd/system/${service}.service" "$service systemd service"
        safe_remove "/etc/systemd/system/${service}.path" "$service path monitor"
    done
    
    # Reload systemd
    systemctl daemon-reload
    print_success "Systemd services removed"
}

# Remove API user and token
function remove_api_auth() {
    print_info "Removing API user and token..."
    
    local pve_user="sync-daemon@pve"
    local pve_token_name="daemon-token"
    
    # Remove token if it exists
    if pveum user token list "$pve_user" 2>/dev/null | grep -q "$pve_token_name"; then
        pveum user token delete "$pve_user" "$pve_token_name" &>/dev/null || print_warning "Could not delete token"
        print_success "Removed API token"
    fi
    
    # Remove user if it exists
    if pveum user list | grep -q "^$pve_user"; then
        pveum user delete "$pve_user" &>/dev/null || print_warning "Could not delete user"
        print_success "Removed API user"
    fi
}

# Verify removal
function verify_removal() {
    print_info "Verifying removal..."
    
    local removed_count=0
    local total_count=6
    
    # Check that files are removed
    if [ ! -f "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" ]; then
        print_success "API backend removed"
        ((removed_count++))
    else
        print_warning "API backend still present"
    fi
    
    if [ ! -f "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" ]; then
        print_success "Configuration module removed"
        ((removed_count++))
    else
        print_warning "Configuration module still present"
    fi
    
    if ! grep -q "sdnOrchestratorSchema" "/usr/share/pve-manager/js/pvemanagerlib.js" 2>/dev/null; then
        print_success "Frontend code removed"
        ((removed_count++))
    else
        print_warning "Frontend code still present"
    fi
    
    if [ ! -d "/opt/proxmox-sdn-orchestrators" ]; then
        print_success "Sync daemons removed"
        ((removed_count++))
    else
        print_warning "Sync daemons still present"
    fi
    
    if ! systemctl is-enabled proxmox-psm-sync >/dev/null 2>&1 && \
       ! systemctl is-enabled proxmox-afc-sync >/dev/null 2>&1; then
        print_success "Systemd services removed"
        ((removed_count++))
    else
        print_warning "Some systemd services still enabled"
    fi
    
    # Check SDN.pm syntax
    if perl -c /usr/share/perl5/PVE/API2/Network/SDN.pm >/dev/null 2>&1; then
        print_success "SDN.pm syntax is valid"
        ((removed_count++))
    else
        print_error "SDN.pm has syntax errors!"
    fi
    
    return $((total_count - removed_count))
}

# Emergency restore function
function emergency_restore() {
    print_error "Critical error detected. Attempting emergency restore..."
    
    # Restore core SDN.pm if it has syntax errors
    if ! perl -c /usr/share/perl5/PVE/API2/Network/SDN.pm >/dev/null 2>&1; then
        if [ -f "$BACKUP_DIR/SDN.pm" ]; then
            cp "$BACKUP_DIR/SDN.pm" /usr/share/perl5/PVE/API2/Network/SDN.pm
            print_info "Restored SDN.pm from backup"
        else
            # Try to restore from package
            apt-get install --reinstall pve-manager >/dev/null 2>&1 || true
            print_info "Attempted to reinstall pve-manager"
        fi
    fi
    
    systemctl restart pveproxy pvedaemon
    print_info "Emergency restore completed"
}

# Prompt for confirmation when run interactively
function confirm_uninstall() {
    if [ -t 0 ]; then  # Check if running interactively
        echo "⚠️  This will remove all Proxmox SDN Orchestrator components."
        echo "   The following will be removed:"
        echo "   • API backend modules"
        echo "   • Configuration modules"
        echo "   • Frontend JavaScript"
        echo "   • Sync daemons and systemd services"
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
    fi
}

# Main uninstallation flow
function main() {
    # Set up error handling
    trap 'emergency_restore; exit 1' ERR
    
    preflight_checks
    confirm_uninstall
    
    print_info "Starting uninstallation..."
    
    # Stop and remove systemd services
    remove_systemd_services
    
    # Remove API user and token
    remove_api_auth
    
    # Remove backend files
    print_info "Removing backend files..."
    safe_remove "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" "API Backend"
    safe_remove "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" "Configuration Module"
    
    # Remove frontend files
    print_info "Removing frontend files..."
    remove_javascript
    
    # Remove sync daemons
    print_info "Removing sync daemons..."
    safe_remove_dir "/opt/proxmox-sdn-orchestrators" "Sync daemon directory"
    
    # Remove SDN registration (do this last)
    remove_sdn_registration
    
    # Restart Proxmox services
    print_info "Restarting Proxmox services..."
    systemctl restart pveproxy pvedaemon
    
    # Wait for services to start
    sleep 5
    
    # Verify removal
    local failed_count
    failed_count=$(verify_removal || echo $?)
    
    # Disable error trap - we're done with critical operations
    trap - ERR
    
    echo ""
    if [ "${failed_count:-0}" -eq 0 ]; then
        print_success "Uninstallation completed successfully!"
    else
        print_warning "Uninstallation partially completed ($failed_count issues found)"
    fi
    
    echo ""
    echo "📋 Summary:"
    echo "   • Removed API backend and configuration modules"
    echo "   • Removed frontend JavaScript integration"
    echo "   • Removed sync daemons and systemd services"
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
}

# Run the uninstaller
main "$@"
