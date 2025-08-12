#!/bin/bash

# Universal Proxmox SDN Orchestrators Uninstaller
# Removes: Backend API, Frontend UI, and Sync Daemons
# Usage: ./universal-uninstall.sh

set -e

echo "🗑️  Universal Proxmox SDN Orchestrators Uninstaller"
echo "📦 Removing: Backend API + Frontend UI + Sync Daemons"
echo ""

# --- Configuration ---
INSTALL_DIR="/tmp/proxmox-sync-daemon"
CONFIG_FILE="/etc/pve/sdn/orchestrators.cfg"
BACKUP_DIR="/root/orchestrators-uninstall-$(date +%Y%m%d-%H%M%S)"
PVE_USER="sync-daemon@pve"

# --- Helper Functions ---
function print_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
function print_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
function print_warning() { echo -e "\e[33m[WARNING]\e[0m $1"; }
function print_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

# --- Pre-flight Checks ---
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"
print_success "Created backup directory: $BACKUP_DIR"

# Prompt for confirmation when run interactively
if [ -t 0 ]; then  # Check if running interactively
    echo "⚠️  This will remove all Proxmox SDN Orchestrator components:"
    echo "   • Backend API modules (Perl)"
    echo "   • Frontend UI integration (JavaScript)"
    echo "   • Sync daemons and systemd services"
    echo "   • API user and token"
    echo "   • SDN API registration"
    echo ""
    echo "   Configuration files will be preserved."
    echo "   Backups will be saved to: $BACKUP_DIR"
    echo ""
    read -p "Continue with uninstallation? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_error "Uninstallation cancelled"
        exit 0
    fi
fi

print_info "Starting universal uninstallation..."

# --- Function: Remove Sync Daemons ---
remove_sync_daemons() {
    print_info "Removing sync daemons..."
    
    # Stop and disable services
    SERVICES=("proxmox-afc-sync.service" "proxmox-afc-sync.path" "proxmox-psm-sync.service" "proxmox-psm-sync.path")
    
    for service in "${SERVICES[@]}"; do
        if systemctl list-unit-files | grep -q "$service"; then
            if systemctl is-active --quiet "$service"; then
                systemctl stop "$service" || true
                print_success "Stopped $service"
            fi
            if systemctl is-enabled --quiet "$service"; then
                systemctl disable "$service" || true
                print_success "Disabled $service"
            fi
        fi
    done
    
    # Remove systemd files
    for service in "${SERVICES[@]}"; do
        FILE="/etc/systemd/system/${service}"
        if [ -f "$FILE" ]; then
            cp "$FILE" "$BACKUP_DIR/" 2>/dev/null || true
            rm -f "$FILE"
            print_success "Removed $service"
        fi
    done
    
    systemctl daemon-reload
    print_success "Systemd reloaded"
    
    # Remove daemon directory
    if [ -d "$INSTALL_DIR" ]; then
        cp -r "$INSTALL_DIR" "$BACKUP_DIR/" 2>/dev/null || true
        rm -rf "$INSTALL_DIR"
        print_success "Removed daemon directory"
    fi
    
    print_success "Sync daemons removed"
}

# --- Function: Remove API User ---
remove_api_user() {
    print_info "Removing API user and token..."
    
    # Ask for confirmation
    if [ -t 0 ]; then  # Interactive
        read -p "Remove Proxmox user '${PVE_USER}' and API token? [y/N]: " confirm_user
        if [[ ! "$confirm_user" =~ ^[Yy]$ ]]; then
            print_warning "Skipped removing Proxmox user"
            return 0
        fi
    fi
    
    # Remove user (this also removes associated tokens)
    if pveum user list | grep -q "^$PVE_USER"; then
        pveum user delete "$PVE_USER" 2>/dev/null || print_warning "Could not delete user $PVE_USER"
        print_success "Removed API user"
    else
        print_info "API user not found"
    fi
}

# --- Function: Remove Frontend ---
remove_frontend() {
    print_info "Removing frontend components..."
    
    JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
    
    if [ ! -f "$JS_FILE" ]; then
        print_warning "pvemanagerlib.js not found"
        return 0
    fi
    
    # Backup original file
    cp "$JS_FILE" "$BACKUP_DIR/pvemanagerlib.js"
    cp "$JS_FILE" "${JS_FILE}.pre-uninstall"
    
    # Remove our complete implementation
    if grep -q "SDN Orchestrators - Complete Implementation" "$JS_FILE"; then
        # Find the line number of our installation marker
        local marker_line
        marker_line=$(grep -n "// SDN Orchestrators - Complete Implementation" "$JS_FILE" | cut -d: -f1)
        
        if [ -n "$marker_line" ]; then
            # Create new file with everything before our installation
            head -n $((marker_line - 1)) "$JS_FILE" > "${JS_FILE}.new"
            mv "${JS_FILE}.new" "$JS_FILE"
            print_success "Removed JavaScript implementation"
        else
            print_warning "Could not find implementation marker"
        fi
    else
        print_info "JavaScript implementation not found"
    fi
    
    # Remove orchestrators from Options panel
    if grep -A 20 "PVE.sdn.Options" "$JS_FILE" | grep -q "pveSdnOrchestratorView"; then
        print_info "Removing orchestrators from Options panel..."
        # Remove the orchestrators block from Options panel - be very specific
        sed -i '/^\s*},\s*$/N; /^\s*},\s*\n\s*{\s*$/N; /^\s*},\s*\n\s*{\s*\n\s*xtype:.*pveSdnOrchestratorView/,/border: 0,/d' "$JS_FILE"
        print_success "Removed orchestrators from Options panel"
    fi
    
    print_success "Frontend components removed"
}

# --- Function: Unregister from Proxmox ---
unregister_from_proxmox() {
    print_info "Unregistering from Proxmox systems..."
    
    # Remove SDN API registration
    SDN_FILE="/usr/share/perl5/PVE/API2/Network/SDN.pm"
    
    if [ -f "$SDN_FILE" ]; then
        cp "$SDN_FILE" "$BACKUP_DIR/SDN.pm"
        cp "$SDN_FILE" "${SDN_FILE}.pre-uninstall"
        
        # Remove import
        if grep -q "use PVE::API2::Network::SDN::Orchestrators;" "$SDN_FILE"; then
            sed -i '/^use PVE::API2::Network::SDN::Orchestrators;$/d' "$SDN_FILE"
            print_success "Removed SDN import"
        fi
        
        # Remove API registration - be very specific
        if grep -q "subclass.*Orchestrators" "$SDN_FILE"; then
            sed -i '/^\s*__PACKAGE__->register_method({\s*$/N; /^\s*__PACKAGE__->register_method({\s*\n\s*subclass => "PVE::API2::Network::SDN::Orchestrators",/,/^});$/d' "$SDN_FILE"
            print_success "Removed SDN API registration"
        fi
        
        # Verify syntax after modification
        if ! perl -c "$SDN_FILE" >/dev/null 2>&1; then
            print_error "SDN.pm syntax error after modification. Restoring backup."
            mv "${SDN_FILE}.pre-uninstall" "$SDN_FILE"
            return 1
        fi
    fi
    
    # Remove cluster filesystem registration
    CLUSTER_FILE="/usr/share/perl5/PVE/Cluster.pm"
    
    if [ -f "$CLUSTER_FILE" ] && grep -q "'sdn/orchestrators.cfg'" "$CLUSTER_FILE"; then
        cp "$CLUSTER_FILE" "$BACKUP_DIR/Cluster.pm"
        sed -i "/\s*'sdn\/orchestrators\.cfg' => 1,/d" "$CLUSTER_FILE"
        
        # Verify syntax
        if perl -c "$CLUSTER_FILE" >/dev/null 2>&1; then
            print_success "Removed cluster filesystem registration"
        else
            print_error "Cluster.pm syntax error. Restoring backup."
            cp "$BACKUP_DIR/Cluster.pm" "$CLUSTER_FILE"
            return 1
        fi
    fi
    
    print_success "Unregistered from Proxmox systems"
}

# --- Function: Remove Backend ---
remove_backend() {
    print_info "Removing backend components..."
    
    # List of files to remove
    BACKEND_FILES=(
        "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm"
        "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm"
        "/usr/share/perl5/PVE/Network/SDN/Orchestrators/Plugin.pm"
        "/usr/share/perl5/PVE/Network/SDN/Orchestrators/PsmPlugin.pm"
        "/usr/share/perl5/PVE/Network/SDN/Orchestrators/AfcPlugin.pm"
    )
    
    for file in "${BACKEND_FILES[@]}"; do
        if [ -f "$file" ]; then
            cp "$file" "$BACKUP_DIR/" 2>/dev/null || true
            rm -f "$file"
            print_success "Removed $(basename "$file")"
        fi
    done
    
    # Remove empty plugin directory
    if [ -d "/usr/share/perl5/PVE/Network/SDN/Orchestrators" ]; then
        if [ -z "$(ls -A /usr/share/perl5/PVE/Network/SDN/Orchestrators)" ]; then
            rmdir "/usr/share/perl5/PVE/Network/SDN/Orchestrators"
            print_success "Removed empty plugin directory"
        fi
    fi
    
    print_success "Backend components removed"
}

# --- Function: Verify Removal ---
verify_removal() {
    print_info "Verifying removal..."
    
    local removed_count=0
    local total_count=8
    
    # Check backend files
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
    
    if [ ! -d "/usr/share/perl5/PVE/Network/SDN/Orchestrators" ]; then
        print_success "Plugin directory removed"
        ((removed_count++))
    else
        print_warning "Plugin directory still present"
    fi
    
    # Check JavaScript
    if ! grep -q "SDN Orchestrators.*Implementation" "/usr/share/pve-manager/js/pvemanagerlib.js" 2>/dev/null; then
        print_success "Frontend code removed"
        ((removed_count++))
    else
        print_warning "Frontend code still present"
    fi
    
    if ! grep -A 20 "PVE.sdn.Options" "/usr/share/pve-manager/js/pvemanagerlib.js" 2>/dev/null | grep -q "pveSdnOrchestratorView"; then
        print_success "Options panel integration removed"
        ((removed_count++))
    else
        print_warning "Options panel integration still present"
    fi
    
    # Check daemons
    if [ ! -d "/tmp/proxmox-sync-daemon" ]; then
        print_success "Sync daemons removed"
        ((removed_count++))
    else
        print_warning "Sync daemons still present"
    fi
    
    # Check services
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

# --- Main Uninstallation Flow ---
remove_sync_daemons || print_warning "Issues removing sync daemons"
remove_api_user || print_warning "Issues removing API user"
remove_frontend || print_warning "Issues removing frontend"
unregister_from_proxmox || print_warning "Issues unregistering from Proxmox"
remove_backend || print_warning "Issues removing backend"

# Restart Proxmox services
print_info "Restarting Proxmox services..."
systemctl restart pveproxy pvedaemon
sleep 5

# Verify removal
failed_count=$(verify_removal || echo $?)

echo ""
if [ "${failed_count:-0}" -eq 0 ]; then
    print_success "🎉 Universal uninstallation completed successfully!"
else
    print_warning "Uninstallation completed with $failed_count issues"
fi

echo ""
echo "📋 Summary:"
echo "   • Removed sync daemons and systemd services"
echo "   • Removed API user and token"
echo "   • Removed frontend JavaScript integration"
echo "   • Removed SDN API registration"
echo "   • Removed backend modules"
echo "   • Restarted Proxmox services"
echo ""
echo "📁 Backup files saved to: $BACKUP_DIR"
echo ""
echo "ℹ️  Configuration files preserved:"
echo "   • $CONFIG_FILE (if exists)"
echo "   • Any orchestrator configurations you created"
echo ""
echo "🔄 Manual cleanup (if needed):"
echo "   • Clear browser cache"
echo "   • Remove $CONFIG_FILE if no longer needed"
echo "   • Remove backup directory: rm -rf $BACKUP_DIR"
echo ""
echo "📖 For issues: https://github.com/farsonic/proxmox-orchestrator/issues"

# Show config file status
if [ -f "$CONFIG_FILE" ]; then
    echo ""
    print_warning "Configuration file still exists: $CONFIG_FILE"
    echo "   Remove manually if no longer needed: rm $CONFIG_FILE"
fi
