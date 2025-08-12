#!/bin/bash

# Bulletproof Proxmox SDN Orchestrators Installer
# Repository: https://github.com/farsonic/proxmox-orchestrator
# Usage: curl -fsSL https://raw.githubusercontent.com/farsonic/proxmox-orchestrator/main/install-orchestrators.sh | bash

set -e

REPO_BASE="https://raw.githubusercontent.com/farsonic/proxmox-orchestrator/main"
BACKUP_DIR="/root/orchestrators-backup-$(date +%Y%m%d-%H%M%S)"
DAEMON_DIR="/opt/proxmox-sdn-orchestrators"

# Helper Functions
function print_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
function print_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
function print_warning() { echo -e "\e[33m[WARNING]\e[0m $1"; }
function print_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

echo "🚀 Installing Proxmox SDN Orchestrators..."
echo "📦 Repository: https://github.com/farsonic/proxmox-orchestrator"
echo ""

# Pre-flight checks
function preflight_checks() {
    print_info "Running pre-flight checks..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root. Please run: sudo $0"
        exit 1
    fi
    
    # Check if this is a Proxmox system
    if [ ! -f "/usr/share/perl5/PVE/API2/Network/SDN.pm" ]; then
        print_error "This doesn't appear to be a Proxmox VE system. SDN.pm not found."
        exit 1
    fi
    
    # Check that core SDN.pm has valid syntax
    if ! perl -c /usr/share/perl5/PVE/API2/Network/SDN.pm >/dev/null 2>&1; then
        print_error "Core SDN.pm has syntax errors. Please repair Proxmox installation first."
        exit 1
    fi
    
    # Check internet connectivity
    if ! curl -fsSL --connect-timeout 10 "$REPO_BASE/README.md" >/dev/null 2>&1; then
        print_error "Cannot connect to GitHub repository. Check internet connection."
        exit 1
    fi
    
    print_success "Pre-flight checks passed"
}

# Create backup of existing files
function create_backups() {
    print_info "Creating backup directory..."
    mkdir -p "$BACKUP_DIR"
    
    # Backup files that we'll modify
    local files_to_backup=(
        "/usr/share/perl5/PVE/API2/Network/SDN.pm"
        "/usr/share/pve-manager/js/pvemanagerlib.js"
        "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm"
        "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm"
    )
    
    for file in "${files_to_backup[@]}"; do
        if [ -f "$file" ]; then
            print_info "Backing up $file"
            cp "$file" "$BACKUP_DIR/" 2>/dev/null || print_warning "Could not backup $file"
        fi
    done
    
    print_success "Created backup directory: $BACKUP_DIR"
}

# Download and validate file before installing
function install_file() {
    local url="$1"
    local dest="$2"
    local description="$3"
    local permissions="${4:-644}"
    local validate_perl="${5:-false}"
    
    print_info "Installing $description..."
    
    # Create directory if needed
    mkdir -p "$(dirname "$dest")"
    
    # Download to temporary file first
    local temp_file="/tmp/$(basename "$dest").tmp"
    
    if ! curl -fsSL "$url" -o "$temp_file"; then
        print_error "Failed to download $description from $url"
        return 1
    fi
    
    # Validate Perl syntax if requested
    if [ "$validate_perl" = "true" ]; then
        if ! perl -c "$temp_file" >/dev/null 2>&1; then
            print_error "Downloaded $description has syntax errors"
            rm -f "$temp_file"
            return 1
        fi
    fi
    
    # Move to final location
    mv "$temp_file" "$dest"
    chmod "$permissions" "$dest"
    
    print_success "Installed $description to $dest"
    return 0
}

# Update SDN.pm to register our orchestrators API
function update_sdn_registration() {
    local sdn_file="/usr/share/perl5/PVE/API2/Network/SDN.pm"
    
    print_info "Registering orchestrators API with SDN..."
    
    # Check if already registered
    if grep -q "use PVE::API2::Network::SDN::Orchestrators;" "$sdn_file"; then
        print_warning "Orchestrators API already registered"
        return 0
    fi
    
    # Create a backup before modifying
    cp "$sdn_file" "${sdn_file}.pre-orchestrators"
    
    # Add import after other imports
    sed -i '/^use PVE::API2::Network::SDN::Fabrics;$/a use PVE::API2::Network::SDN::Orchestrators;' "$sdn_file"
    
    # Add API registration after fabrics registration
    sed -i '/path => "fabrics",/a\    },\
{\
    subclass => "PVE::API2::Network::SDN::Orchestrators",\
    path => "orchestrators",' "$sdn_file"
    
    # Validate syntax after modification
    if ! perl -c "$sdn_file" >/dev/null 2>&1; then
        print_error "SDN.pm syntax error after modification. Restoring backup."
        mv "${sdn_file}.pre-orchestrators" "$sdn_file"
        return 1
    fi
    
    print_success "Orchestrators API registered with SDN"
    return 0
}

# Add JavaScript to pvemanagerlib.js
function install_javascript() {
    local js_url="$1"
    local js_file="/usr/share/pve-manager/js/pvemanagerlib.js"
    
    print_info "Installing frontend JavaScript..."
    
    # Check if already installed
    if grep -q "sdnOrchestratorSchema" "$js_file"; then
        print_warning "JavaScript already installed"
        return 0
    fi
    
    # Download JavaScript code
    local js_code
    if ! js_code=$(curl -fsSL "$js_url"); then
        print_error "Failed to download JavaScript code"
        return 1
    fi
    
    # Create backup
    cp "$js_file" "${js_file}.pre-orchestrators"
    
    # Append our JavaScript with clear markers
    {
        echo ""
        echo "// SDN Orchestrators - Auto-installed $(date)"
        echo "$js_code"
    } >> "$js_file"
    
    print_success "JavaScript installed successfully"
    return 0
}

# Set up API token for sync daemons
function setup_api_token() {
    print_info "Setting up API authentication..."
    
    local pve_user="sync-daemon@pve"
    local pve_token_name="daemon-token"
    local token_secret
    token_secret=$(openssl rand -hex 32)
    
    # Create user if it doesn't exist
    if ! pveum user list | grep -q "^$pve_user"; then
        pveum user add "$pve_user" --comment "SDN Orchestrator Sync Daemon"
        print_success "Created user $pve_user"
    fi
    
    # Remove existing token if it exists
    if pveum user token list "$pve_user" 2>/dev/null | grep -q "$pve_token_name"; then
        pveum user token delete "$pve_user" "$pve_token_name"
    fi
    
    # Create new token
    local token_output
    token_output=$(pveum user token add "$pve_user" "$pve_token_name" --privsep 0)
    
    local full_token
    full_token=$(echo "$token_output" | grep "full-tokenid" | cut -d'=' -f2 | tr -d ' ')
    
    if [ -z "$full_token" ]; then
        print_error "Failed to create API token"
        return 1
    fi
    
    # Set permissions
    pveum acl modify / --users "$pve_user" --roles Administrator
    
    # Create token configuration file
    mkdir -p "$DAEMON_DIR"
    cat > "$DAEMON_DIR/api_token.conf" << EOF
# Proxmox API Token Configuration
PVE_HOST=localhost
PVE_USER=$pve_user
PVE_TOKEN_ID=$full_token
PVE_TOKEN_SECRET=$token_secret
PVE_VERIFY_SSL=false
EOF
    
    chmod 600 "$DAEMON_DIR/api_token.conf"
    print_success "API authentication configured"
    return 0
}

# Create systemd services
function create_systemd_services() {
    print_info "Creating systemd services..."
    
    # PSM sync service
    cat > /etc/systemd/system/proxmox-psm-sync.service << 'EOF'
[Unit]
Description=Proxmox PSM Sync Daemon
After=network.target
Requires=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/proxmox-sdn-orchestrators/psm_sync_daemon.py
Restart=always
RestartSec=30
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

    # AFC sync service
    cat > /etc/systemd/system/proxmox-afc-sync.service << 'EOF'
[Unit]
Description=Proxmox AFC Sync Daemon
After=network.target
Requires=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/proxmox-sdn-orchestrators/afc_sync_daemon.py
Restart=always
RestartSec=30
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable proxmox-psm-sync proxmox-afc-sync
    
    print_success "Systemd services created and enabled"
}

# Verify installation
function verify_installation() {
    print_info "Verifying installation..."
    
    local errors=0
    
    # Check Perl modules syntax
    if ! perl -c /usr/share/perl5/PVE/API2/Network/SDN.pm >/dev/null 2>&1; then
        print_error "SDN.pm syntax error"
        ((errors++))
    else
        print_success "SDN.pm syntax OK"
    fi
    
    if [ -f "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" ]; then
        if ! perl -c /usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm >/dev/null 2>&1; then
            print_error "Orchestrators API syntax error"
            ((errors++))
        else
            print_success "Orchestrators API syntax OK"
        fi
    fi
    
    if [ -f "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" ]; then
        if ! perl -c /usr/share/perl5/PVE/Network/SDN/Orchestrators.pm >/dev/null 2>&1; then
            print_error "Orchestrators Config syntax error"
            ((errors++))
        else
            print_success "Orchestrators Config syntax OK"
        fi
    fi
    
    # Check files exist
    local required_files=(
        "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm"
        "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm"
        "/opt/proxmox-sdn-orchestrators/psm_sync_daemon.py"
        "/opt/proxmox-sdn-orchestrators/afc_sync_daemon.py"
        "/etc/systemd/system/proxmox-psm-sync.service"
        "/etc/systemd/system/proxmox-afc-sync.service"
    )
    
    for file in "${required_files[@]}"; do
        if [ -f "$file" ]; then
            print_success "$(basename "$file") installed"
        else
            print_error "$(basename "$file") missing"
            ((errors++))
        fi
    done
    
    return $errors
}

# Rollback function in case of failure
function rollback_installation() {
    print_error "Installation failed. Rolling back changes..."
    
    # Restore backed up files
    if [ -f "${BACKUP_DIR}/SDN.pm" ]; then
        cp "${BACKUP_DIR}/SDN.pm" /usr/share/perl5/PVE/API2/Network/SDN.pm
        print_info "Restored SDN.pm"
    fi
    
    if [ -f "${BACKUP_DIR}/pvemanagerlib.js" ]; then
        cp "${BACKUP_DIR}/pvemanagerlib.js" /usr/share/pve-manager/js/pvemanagerlib.js
        print_info "Restored pvemanagerlib.js"
    fi
    
    # Remove any files we created
    rm -f /usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm
    rm -f /usr/share/perl5/PVE/Network/SDN/Orchestrators.pm
    rm -rf /opt/proxmox-sdn-orchestrators
    rm -f /etc/systemd/system/proxmox-psm-sync.service
    rm -f /etc/systemd/system/proxmox-afc-sync.service
    
    systemctl daemon-reload
    systemctl restart pveproxy pvedaemon
    
    print_info "Rollback completed. System restored to previous state."
}

# Main installation flow
function main() {
    # Set up error handling
    trap 'rollback_installation; exit 1' ERR
    
    preflight_checks
    create_backups
    
    # Install dependencies
    print_info "Installing dependencies..."
    apt-get update >/dev/null
    apt-get install -y python3-requests curl >/dev/null
    
    # Install backend files
    print_info "Installing backend API module..."
    install_file "$REPO_BASE/PVE/API2/Network/SDN/Orchestrators.pm" \
        "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" \
        "API Backend" \
        "644" \
        "true"
    
    print_info "Installing backend config module..."
    install_file "$REPO_BASE/PVE/Network/SDN/Orchestrators.pm" \
        "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" \
        "Configuration Module" \
        "644" \
        "true"
    
    # Install plugin modules
    print_info "Installing plugin base class..."
    install_file "$REPO_BASE/PVE/Network/SDN/Orchestrators/Plugin.pm" \
        "/usr/share/perl5/PVE/Network/SDN/Orchestrators/Plugin.pm" \
        "Plugin Base Class" \
        "644" \
        "true"
    
    print_info "Installing PSM plugin..."
    install_file "$REPO_BASE/PVE/Network/SDN/Orchestrators/PsmPlugin.pm" \
        "/usr/share/perl5/PVE/Network/SDN/Orchestrators/PsmPlugin.pm" \
        "PSM Plugin" \
        "644" \
        "true"
    
    print_info "Installing AFC plugin..."
    install_file "$REPO_BASE/PVE/Network/SDN/Orchestrators/AfcPlugin.pm" \
        "/usr/share/perl5/PVE/Network/SDN/Orchestrators/AfcPlugin.pm" \
        "AFC Plugin" \
        "644" \
        "true"
    
    # Update SDN registration
    update_sdn_registration
    
    # Install frontend
    install_javascript "$REPO_BASE/js/orchestrators.js"
    
    # Install sync daemons
    print_info "Installing sync daemons..."
    install_file "$REPO_BASE/daemons/psm_sync_daemon.py" \
        "$DAEMON_DIR/psm_sync_daemon.py" \
        "PSM Sync Daemon" \
        "755"
    
    install_file "$REPO_BASE/daemons/afc_sync_daemon.py" \
        "$DAEMON_DIR/afc_sync_daemon.py" \
        "AFC Sync Daemon" \
        "755"
    
    # Set up API authentication
    setup_api_token
    
    # Create systemd services
    create_systemd_services
    
    # Verify everything before restarting services
    if ! verify_installation; then
        print_error "Installation verification failed"
        exit 1
    fi
    
    # Restart Proxmox services
    print_info "Restarting Proxmox services..."
    systemctl restart pveproxy pvedaemon
    
    # Wait for services to start
    sleep 5
    
    # Final verification
    if systemctl is-active --quiet pveproxy && systemctl is-active --quiet pvedaemon; then
        print_success "Proxmox services restarted successfully"
    else
        print_error "Proxmox services failed to start properly"
        exit 1
    fi
    
    # Disable error trap - we succeeded
    trap - ERR
    
    echo ""
    print_success "Installation completed successfully!"
    echo ""
    echo "📋 What was installed:"
    echo "   • API backend modules"
    echo "   • Frontend JavaScript interface"
    echo "   • PSM and AFC sync daemons"
    echo "   • Systemd services and API authentication"
    echo ""
    echo "🚀 Next steps:"
    echo "   1. Access web interface: Datacenter → SDN → Orchestrators"
    echo "   2. Start sync daemons: systemctl start proxmox-psm-sync proxmox-afc-sync"
    echo "   3. Monitor logs: journalctl -u proxmox-psm-sync -f"
    echo ""
    echo "📁 Backup saved to: $BACKUP_DIR"
    echo "📖 Documentation: https://github.com/farsonic/proxmox-orchestrator"
}

# Run the installer
main "$@"
