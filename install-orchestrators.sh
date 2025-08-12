#!/bin/bash

# Proxmox SDN Orchestrators Installer
# Repository: https://github.com/farsonic/proxmox-orchestrator
# Usage: curl -fsSL https://raw.githubusercontent.com/farsonic/proxmox-orchestrator/main/install-orchestrators.sh | bash

set -e

REPO_BASE="https://raw.githubusercontent.com/farsonic/proxmox-orchestrator/main"
BACKUP_DIR="/root/orchestrators-backup-$(date +%Y%m%d-%H%M%S)"
DAEMON_DIR="/opt/proxmox-sdn-orchestrators"

echo "🚀 Installing Proxmox SDN Orchestrators with Sync Daemons..."
echo "📦 Repository: https://github.com/farsonic/proxmox-orchestrator"
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"
echo "📁 Created backup directory: $BACKUP_DIR"

# Create daemon directory
mkdir -p "$DAEMON_DIR"
echo "📁 Created daemon directory: $DAEMON_DIR"

# Function to backup file if it exists
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        echo "💾 Backing up $file"
        cp "$file" "$BACKUP_DIR/"
    fi
}

# Function to download and install file
install_file() {
    local url="$1"
    local dest="$2"
    local description="$3"
    local permissions="$4"
    
    echo "📥 Installing $description..."
    backup_file "$dest"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$dest")"
    
    # Download and install
    if curl -fsSL "$url" -o "$dest"; then
        chmod "${permissions:-644}" "$dest"
        echo "✅ Installed $description to $dest"
    else
        echo "❌ Failed to download $description from $url"
        return 1
    fi
}

# Function to append JavaScript to existing file
append_javascript() {
    local js_url="$1"
    local dest_file="$2"
    
    echo "📥 Appending JavaScript to $dest_file..."
    backup_file "$dest_file"
    
    # Check if our code is already present
    if grep -q "SDN Orchestrators" "$dest_file" 2>/dev/null; then
        echo "⚠️  JavaScript already present in $dest_file, skipping..."
        return
    fi
    
    # Download and append JavaScript
    echo "" >> "$dest_file"
    echo "// =======================================================================" >> "$dest_file"
    echo "// SDN Orchestrators - Auto-installed $(date)" >> "$dest_file"
    echo "// Repository: https://github.com/farsonic/proxmox-orchestrator" >> "$dest_file"
    echo "// =======================================================================" >> "$dest_file"
    
    if curl -fsSL "$js_url" >> "$dest_file"; then
        echo "✅ Appended JavaScript to $dest_file"
    else
        echo "❌ Failed to download JavaScript from $js_url"
        return 1
    fi
}

# Function to update SDN.pm registration
update_sdn_registration() {
    local sdn_file="/usr/share/perl5/PVE/API2/Network/SDN.pm"
    
    echo "📝 Updating SDN API registration..."
    backup_file "$sdn_file"
    
    # Check if already registered
    if grep -q "PVE::API2::Network::SDN::Orchestrators" "$sdn_file" 2>/dev/null; then
        echo "⚠️  Orchestrators already registered in SDN.pm, skipping..."
        return
    fi
    
    # Add the import line after other use statements
    if sed -i '/^use PVE::API2::Network::SDN::/a use PVE::API2::Network::SDN::Orchestrators;' "$sdn_file"; then
        echo "✅ Added import statement"
    else
        echo "❌ Failed to add import statement"
        return 1
    fi
    
    # Add the registration before the final "1;"
    if sed -i '/^1;$/i \\n__PACKAGE__->register_method({\n    subclass => "PVE::API2::Network::SDN::Orchestrators",\n    path => "orchestrators",\n});' "$sdn_file"; then
        echo "✅ Added API registration"
    else
        echo "❌ Failed to add API registration"
        return 1
    fi
}

# Function to create systemd service
create_systemd_service() {
    local service_name="$1"
    local daemon_script="$2"
    local description="$3"
    
    local service_file="/etc/systemd/system/${service_name}.service"
    
    echo "📝 Creating systemd service: $service_name"
    backup_file "$service_file"
    
    cat > "$service_file" << EOF
[Unit]
Description=$description
After=network.target pveproxy.service
Wants=pveproxy.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$DAEMON_DIR
ExecStart=/usr/bin/python3 $daemon_script --config /etc/pve/sdn/orchestrators.cfg
Restart=always
RestartSec=10
EnvironmentFile=$DAEMON_DIR/.env

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$service_name

[Install]
WantedBy=multi-user.target
EOF

    echo "✅ Created systemd service: $service_file"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root"
    echo "   Please run: sudo $0"
    exit 1
fi

# Check if this is a Proxmox system
if [ ! -f "/usr/share/perl5/PVE/API2/Network/SDN.pm" ]; then
    echo "❌ This doesn't appear to be a Proxmox VE system"
    echo "   SDN.pm not found. Please ensure this is a Proxmox VE server."
    exit 1
fi

echo "✅ Running as root on Proxmox VE system"

# Install backend files
echo ""
echo "📦 Installing backend files..."

install_file "$REPO_BASE/PVE/API2/Network/SDN/Orchestrators.pm" \
    "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" \
    "API Backend"

install_file "$REPO_BASE/PVE/Network/SDN/Orchestrators.pm" \
    "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" \
    "Configuration Module"

# Update SDN registration
echo ""
echo "📝 Registering with Proxmox SDN API..."
update_sdn_registration

# Install frontend
echo ""
echo "📦 Installing frontend files..."
append_javascript "$REPO_BASE/js/orchestrators.js" \
    "/usr/share/pve-manager/js/pvemanagerlib.js"

# Install sync daemons
echo ""
echo "📦 Installing sync daemons..."

install_file "$REPO_BASE/daemons/psm_sync_daemon.py" \
    "$DAEMON_DIR/psm_sync_daemon.py" \
    "PSM Sync Daemon" \
    "755"

install_file "$REPO_BASE/daemons/afc_sync_daemon.py" \
    "$DAEMON_DIR/afc_sync_daemon.py" \
    "AFC Sync Daemon" \
    "755"

# Create systemd services
echo ""
echo "📦 Creating systemd services..."

create_systemd_service "proxmox-psm-sync" \
    "$DAEMON_DIR/psm_sync_daemon.py" \
    "Proxmox PSM Orchestrator Sync Daemon"

create_systemd_service "proxmox-afc-sync" \
    "$DAEMON_DIR/afc_sync_daemon.py" \
    "Proxmox AFC Orchestrator Sync Daemon"

# Set up API user and token automatically
echo ""
echo "🔑 Setting up API authentication..."
if setup_api_token; then
    echo "✅ API authentication configured automatically"
    auto_token_setup=true
else
    echo "⚠️  Automatic token setup failed, manual setup required"
    auto_token_setup=false
fi

# Set proper permissions
echo ""
echo "🔒 Setting permissions..."
chown root:root /usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm
chmod 644 /usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm
chown root:root /usr/share/perl5/PVE/Network/SDN/Orchestrators.pm
chmod 644 /usr/share/perl5/PVE/Network/SDN/Orchestrators.pm
chown -R root:root "$DAEMON_DIR"
chmod 755 "$DAEMON_DIR"/*.py

# Create config directory if it doesn't exist
mkdir -p /etc/pve/sdn
echo "📁 Ensured config directory exists"

# Reload systemd and enable services
echo ""
echo "🔄 Setting up systemd services..."
systemctl daemon-reload
systemctl enable proxmox-psm-sync.service
systemctl enable proxmox-afc-sync.service

# Check Perl syntax
echo ""
echo "🔍 Verifying Perl modules..."
if perl -c /usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm >/dev/null 2>&1; then
    echo "✅ API Backend syntax OK"
else
    echo "❌ API Backend syntax error"
fi

if perl -c /usr/share/perl5/PVE/Network/SDN/Orchestrators.pm >/dev/null 2>&1; then
    echo "✅ Configuration Module syntax OK"
else
    echo "❌ Configuration Module syntax error"
fi

# Restart Proxmox services
echo ""
echo "🔄 Restarting Proxmox services..."
systemctl restart pveproxy
systemctl restart pvedaemon

# Wait a moment for services to start
sleep 3

# Verify installation
echo ""
echo "🔍 Verifying installation..."

# Check if API endpoint responds (basic check)
if systemctl is-active --quiet pveproxy; then
    echo "✅ Proxmox web service is running"
else
    echo "❌ Proxmox web service is not running"
fi

# Check if files exist and have content
if [ -f "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" ] && [ -s "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" ]; then
    echo "✅ API backend file installed"
else
    echo "❌ API backend file missing or empty"
fi

if [ -f "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" ] && [ -s "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" ]; then
    echo "✅ Configuration module installed"
else
    echo "❌ Configuration module missing or empty"
fi

if grep -q "sdnOrchestratorSchema" "/usr/share/pve-manager/js/pvemanagerlib.js" 2>/dev/null; then
    echo "✅ Frontend code installed"
else
    echo "❌ Frontend code missing"
fi

if [ -f "$DAEMON_DIR/psm_sync_daemon.py" ] && [ -f "$DAEMON_DIR/afc_sync_daemon.py" ]; then
    echo "✅ Sync daemons installed"
else
    echo "❌ Sync daemons missing"
fi

if systemctl is-enabled proxmox-psm-sync >/dev/null 2>&1 && systemctl is-enabled proxmox-afc-sync >/dev/null 2>&1; then
    echo "✅ Systemd services enabled"
else
    echo "❌ Systemd services not enabled"
fi

echo ""
echo "🎉 Installation complete!"
echo ""

if [ "$auto_token_setup" = true ]; then
    echo "✅ Fully automated setup completed successfully!"
    echo ""
    echo "📋 What was configured:"
    echo "   • API user: sync-daemon@pve"
    echo "   • API token: daemon-token" 
    echo "   • Environment file: $DAEMON_DIR/.env"
    echo "   • Systemd services configured with authentication"
    echo ""
    echo "🚀 Starting sync daemons automatically..."
    systemctl start proxmox-psm-sync
    systemctl start proxmox-afc-sync
    
    # Wait a moment and check status
    sleep 3
    echo ""
    echo "📊 Service status:"
    for service in "proxmox-psm-sync" "proxmox-afc-sync"; do
        if systemctl is-active --quiet "$service"; then
            echo "   ✅ $service is running"
        else
            echo "   ⚠️  $service is not running - check logs"
        fi
    done
    
    echo ""
    echo "🌐 Ready to use:"
    echo "   • Navigate to Datacenter → SDN → Orchestrators"
    echo "   • Click 'Add' to create PSM or AFC orchestrators"
    echo "   • The sync daemons will automatically sync your configurations"
    
else
    echo "⚠️  Manual token setup required!"
    echo ""
    echo "📋 Next steps:"
    echo ""
    echo "1. 🔑 Set up API token manually:"
    echo "   curl -fsSL https://raw.githubusercontent.com/farsonic/proxmox-orchestrator/main/setup-api-token.sh -o setup-api-token.sh"
    echo "   chmod +x setup-api-token.sh"
    echo "   ./setup-api-token.sh YOUR_TOKEN_SECRET"
    echo ""
    echo "2. 🚀 Start the sync daemons:"
    echo "     sudo systemctl start proxmox-psm-sync"
    echo "     sudo systemctl start proxmox-afc-sync"
    echo ""
    echo "3. 🌐 Access the web interface:"
    echo "   • Navigate to Datacenter → SDN → Orchestrators"
fi
echo ""
echo "📊 Monitor daemon status:"
echo "   sudo systemctl status proxmox-psm-sync"
echo "   sudo systemctl status proxmox-afc-sync"
echo "   sudo journalctl -u proxmox-psm-sync -f"
echo "   sudo journalctl -u proxmox-afc-sync -f"
echo ""
echo "📁 Backup files saved to: $BACKUP_DIR"
echo ""
echo "📖 Documentation: https://github.com/farsonic/proxmox-orchestrator"
echo "🐛 Issues: https://github.com/farsonic/proxmox-orchestrator/issues"
echo ""
echo "🗑️  To uninstall:"
echo "   curl -fsSL https://raw.githubusercontent.com/farsonic/proxmox-orchestrator/main/uninstall-orchestrators.sh | bash"
