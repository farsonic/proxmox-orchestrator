#!/bin/bash

# Universal Proxmox SDN Orchestrators Installer
# Installs: Backend API, Frontend UI, and Sync Daemons
# Run from /var/tmp/proxmox-orchestrator directory

set -e

echo "🚀 Universal Proxmox SDN Orchestrators Installer"
echo "📦 Installing: Backend API + Frontend UI + Sync Daemons"
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

# --- Create Backup ---
print_info "Creating comprehensive backup..."
mkdir -p "$BACKUP_DIR"

# Backup all files we'll modify
BACKUP_FILES=(
    "/usr/share/perl5/PVE/API2/Network/SDN.pm"
    "/usr/share/pve-manager/js/pvemanagerlib.js"
    "/usr/share/perl5/PVE/Cluster.pm"
)

for file in "${BACKUP_FILES[@]}"; do
    if [ -f "$file" ]; then
        cp "$file" "$BACKUP_DIR/"
        print_info "Backed up $(basename "$file")"
    fi
done

print_success "Backup created: $BACKUP_DIR"

# --- Function: Install Backend Components ---
install_backend() {
    print_info "Installing backend components..."
    
    # Install API Backend
    mkdir -p "/usr/share/perl5/PVE/API2/Network/SDN"
    cp "PVE/API2/Network/SDN/Orchestrators.pm" "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm"
    print_success "API Backend installed"
    
    # Install Config Module
    mkdir -p "/usr/share/perl5/PVE/Network/SDN"
    cp "PVE/Network/SDN/Orchestrators.pm" "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm"
    print_success "Config Module installed"
    
    # Install Plugin files
    mkdir -p "/usr/share/perl5/PVE/Network/SDN/Orchestrators"
    cp "PVE/Network/SDN/Orchestrators/Plugin.pm" "/usr/share/perl5/PVE/Network/SDN/Orchestrators/Plugin.pm"
    cp "PVE/Network/SDN/Orchestrators/PsmPlugin.pm" "/usr/share/perl5/PVE/Network/SDN/Orchestrators/PsmPlugin.pm"
    cp "PVE/Network/SDN/Orchestrators/AfcPlugin.pm" "/usr/share/perl5/PVE/Network/SDN/Orchestrators/AfcPlugin.pm"
    print_success "Plugin modules installed"
    
    # Verify Perl syntax
    perl -c "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" >/dev/null 2>&1 || { print_error "API Backend syntax error"; return 1; }
    perl -c "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" >/dev/null 2>&1 || { print_error "Config Module syntax error"; return 1; }
    perl -c "/usr/share/perl5/PVE/Network/SDN/Orchestrators/Plugin.pm" >/dev/null 2>&1 || { print_error "Plugin Base syntax error"; return 1; }
    print_success "Backend syntax validation passed"
}

# --- Function: Register with Proxmox ---
register_with_proxmox() {
    print_info "Registering with Proxmox systems..."
    
    # Register with cluster filesystem
    CLUSTER_FILE="/usr/share/perl5/PVE/Cluster.pm"
    if ! grep -q "'sdn/orchestrators.cfg'" "$CLUSTER_FILE"; then
        LINE_NUM=$(grep -n "'sdn/ipams.cfg' => 1," "$CLUSTER_FILE" | cut -d: -f1)
        if [ -n "$LINE_NUM" ]; then
            sed -i "${LINE_NUM}a\\    'sdn/orchestrators.cfg' => 1," "$CLUSTER_FILE"
            print_success "Registered with cluster filesystem"
        else
            print_error "Could not find cluster filesystem registration point"
            return 1
        fi
    else
        print_warning "Already registered with cluster filesystem"
    fi
    
    # Register with SDN API
    SDN_FILE="/usr/share/perl5/PVE/API2/Network/SDN.pm"
    
    # Add import
    if ! grep -q "use PVE::API2::Network::SDN::Orchestrators;" "$SDN_FILE"; then
        sed -i '/^use PVE::API2::Network::SDN::Fabrics;$/a use PVE::API2::Network::SDN::Orchestrators;' "$SDN_FILE"
        print_success "Added SDN import"
    else
        print_warning "SDN import already exists"
    fi
    
    # Add API registration
    if ! grep -q "subclass.*Orchestrators" "$SDN_FILE"; then
        sed -i '/subclass => "PVE::API2::Network::SDN::Fabrics",/,/});/{
            /});/a\\n__PACKAGE__->register_method({\
    subclass => "PVE::API2::Network::SDN::Orchestrators",\
    path => '\''orchestrators'\'',\
});
        }' "$SDN_FILE"
        print_success "Added SDN API registration"
    else
        print_warning "SDN API already registered"
    fi
    
    # Verify SDN syntax
    perl -c "$SDN_FILE" >/dev/null 2>&1 || { print_error "SDN.pm syntax error after registration"; return 1; }
    print_success "SDN registration completed"
}

# --- Function: Install Frontend ---
install_frontend() {
    print_info "Installing frontend components..."
    
    JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
    
    # Check if already installed
    if grep -q "SDN Orchestrators - Complete Implementation" "$JS_FILE"; then
        print_warning "Frontend already installed"
        return 0
    fi
    
    # Patch Options panel to include orchestrators
    if ! grep -A 20 "PVE.sdn.Options" "$JS_FILE" | grep -q "pveSdnOrchestratorView"; then
        sed -i '/xtype: .pveSDNDnsView./,/border: 0,/a\        },\
        {\
            xtype: '"'"'pveSdnOrchestratorView'"'"',\
            title: gettext('"'"'Orchestrators'"'"'),\
            flex: 1,\
            border: 0,' "$JS_FILE"
        print_success "Patched Options panel"
    else
        print_warning "Options panel already includes orchestrators"
    fi
    
    # Add complete JavaScript implementation
    echo "" >> "$JS_FILE"
    echo "// SDN Orchestrators - Complete Implementation $(date)" >> "$JS_FILE"
    cat "js/orchestrators.js" >> "$JS_FILE"
    print_success "JavaScript implementation added"
}

# --- Function: Install Sync Daemons ---
install_sync_daemons() {
    print_info "Installing sync daemons..."
    
    # Install dependencies
    apt-get update >/dev/null
    apt-get install -y python3-requests >/dev/null || { print_error "Failed to install dependencies"; return 1; }
    
    # Create daemon directory
    mkdir -p "$INSTALL_DIR"
    print_success "Created daemon directory: $INSTALL_DIR"
    
    # Set up Proxmox API credentials
    print_info "Setting up Proxmox API credentials..."
    PVE_USER="sync-daemon@pve"
    PVE_TOKEN_NAME="daemon-token"
    
    # Create user if doesn't exist
    if ! pveum user add "$PVE_USER" --password "$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)" &>/dev/null; then
        print_warning "User '${PVE_USER}' may already exist"
    fi
    
    # Set permissions
    pveum acl modify / -user "$PVE_USER" -role "PVEAuditor"
    
    # Remove existing token
    pveum user token delete "$PVE_USER" "$PVE_TOKEN_NAME" &>/dev/null || true
    
    # Create new token
    TMP_TOKEN_FILE=$(mktemp)
    pveum user token add "$PVE_USER" "$PVE_TOKEN_NAME" --privsep 0 -o json > "$TMP_TOKEN_FILE"
    TOKEN_OUTPUT=$(cat "$TMP_TOKEN_FILE")
    rm -f "$TMP_TOKEN_FILE"
    
    PVE_TOKEN_SECRET_READ=$(echo "$TOKEN_OUTPUT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('value'))")
    if [ -z "$PVE_TOKEN_SECRET_READ" ] || [ "$PVE_TOKEN_SECRET_READ" == "None" ]; then
        print_error "Could not extract token secret from PVE API"
        return 1
    fi
    print_success "API token created successfully"
    
    # Create secure environment file
    ENV_FILE="${INSTALL_DIR}/.env"
    cat > "${ENV_FILE}" << EOF
PVE_TOKEN_SECRET_READ=${PVE_TOKEN_SECRET_READ}
EOF
    chmod 600 "${ENV_FILE}"
    print_success "Environment file created"
    
    # Copy daemon scripts
    cp "daemons/afc_sync_daemon.py" "${INSTALL_DIR}/afc_sync_daemon.py"
    cp "daemons/psm_sync_daemon.py" "${INSTALL_DIR}/psm_sync_daemon.py"
    chmod 755 "${INSTALL_DIR}/afc_sync_daemon.py"
    chmod 755 "${INSTALL_DIR}/psm_sync_daemon.py"
    print_success "Daemon scripts installed"
    
    # Create systemd services
    print_info "Creating systemd services..."
    
    # AFC Service
    cat > "/etc/systemd/system/proxmox-afc-sync.service" << EOF
[Unit]
Description=Proxmox to AFC Sync Daemon
Wants=proxmox-afc-sync.path
After=network-online.target pve-cluster.service

[Service]
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/python3 -u ${INSTALL_DIR}/afc_sync_daemon.py --config ${CONFIG_FILE}
WorkingDirectory=${INSTALL_DIR}
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
    
    # AFC Path Monitor
    cat > "/etc/systemd/system/proxmox-afc-sync.path" << EOF
[Unit]
Description=Watch ${CONFIG_FILE} for changes

[Path]
PathModified=${CONFIG_FILE}

[Install]
WantedBy=multi-user.target
EOF
    
    # PSM Service
    cat > "/etc/systemd/system/proxmox-psm-sync.service" << EOF
[Unit]
Description=Proxmox to PSM Sync Daemon
Wants=proxmox-psm-sync.path
After=network-online.target pve-cluster.service

[Service]
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/python3 -u ${INSTALL_DIR}/psm_sync_daemon.py --config ${CONFIG_FILE}
WorkingDirectory=${INSTALL_DIR}
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
    
    # PSM Path Monitor
    cat > "/etc/systemd/system/proxmox-psm-sync.path" << EOF
[Unit]
Description=Watch ${CONFIG_FILE} for changes

[Path]
PathModified=${CONFIG_FILE}

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable and start services
    systemctl daemon-reload
    systemctl enable proxmox-afc-sync.service proxmox-afc-sync.path
    systemctl enable proxmox-psm-sync.service proxmox-psm-sync.path
    systemctl start proxmox-afc-sync.service proxmox-afc-sync.path
    systemctl start proxmox-psm-sync.service proxmox-psm-sync.path
    
    print_success "Sync daemons installed and started"
}

# --- Function: Final Setup ---
final_setup() {
    print_info "Final setup and verification..."
    
    # Create config file
    mkdir -p /etc/pve/sdn
    touch "$CONFIG_FILE"
    print_success "Configuration file created"
    
    # Restart Proxmox services
    systemctl restart pveproxy pvedaemon
    sleep 5
    
    # Verify services
    if systemctl is-active --quiet pveproxy && systemctl is-active --quiet pvedaemon; then
        print_success "Proxmox services restarted successfully"
    else
        print_error "Proxmox services failed to start"
        return 1
    fi
    
    # Verify daemon services
    DAEMON_SERVICES=("proxmox-afc-sync" "proxmox-psm-sync")
    for service in "${DAEMON_SERVICES[@]}"; do
        if systemctl is-active --quiet "$service"; then
            print_success "$service is running"
        else
            print_warning "$service is not running (will start when orchestrators are configured)"
        fi
    done
}

# --- Main Installation Flow ---
print_info "Starting universal installation..."

# Install components
install_backend || { print_error "Backend installation failed"; exit 1; }
register_with_proxmox || { print_error "Proxmox registration failed"; exit 1; }
install_frontend || { print_error "Frontend installation failed"; exit 1; }
install_sync_daemons || { print_error "Sync daemon installation failed"; exit 1; }
final_setup || { print_error "Final setup failed"; exit 1; }

echo ""
print_success "🎉 Universal installation completed successfully!"
echo ""
echo "📋 What was installed:"
echo "   ✅ Backend API modules (Perl)"
echo "   ✅ Frontend UI integration (JavaScript)"
echo "   ✅ Sync daemons (Python services)"
echo "   ✅ API authentication and permissions"
echo "   ✅ Systemd services and path monitors"
echo ""
echo "🚀 Next steps:"
echo "   1. Open web interface: Datacenter → SDN → Options"
echo "   2. Scroll to 'Orchestrators' section"
echo "   3. Click 'Add' to create PSM or AFC orchestrators"
echo "   4. Daemons will automatically sync when orchestrators are configured"
echo ""
echo "📊 Monitor daemon status:"
echo "   systemctl status proxmox-psm-sync"
echo "   systemctl status proxmox-afc-sync"
echo "   journalctl -u proxmox-psm-sync -f"
echo "   journalctl -u proxmox-afc-sync -f"
echo ""
echo "📁 Backup saved to: $BACKUP_DIR"
echo "📖 Documentation: https://github.com/farsonic/proxmox-orchestrator"
