#!/bin/bash
# Clean SDN Orchestrator installation for fresh Proxmox systems
set -e
echo "Starting clean SDN Orchestrator installation..."

# Stop any existing services first
echo "Stopping any existing services..."
systemctl stop psm-sync-daemon 2>/dev/null || true
systemctl stop afc-sync-daemon 2>/dev/null || true
systemctl stop orchestrators-config.path 2>/dev/null || true

# Create backup directory
BACKUP_DIR="/root/backups/"
mkdir -p "$BACKUP_DIR"

# 1. Copy Perl modules
echo "Installing Perl modules..."
mkdir -p /usr/share/perl5/PVE/Network/SDN/Orchestrators/
cp PVE/API2/Network/SDN/Orchestrators.pm /usr/share/perl5/PVE/API2/Network/SDN/
cp PVE/Network/SDN/Orchestrators.pm /usr/share/perl5/PVE/Network/SDN/
cp PVE/Network/SDN/Orchestrators/Plugin.pm /usr/share/perl5/PVE/Network/SDN/Orchestrators/
cp PVE/Network/SDN/Orchestrators/PsmPlugin.pm /usr/share/perl5/PVE/Network/SDN/Orchestrators/
cp PVE/Network/SDN/Orchestrators/AfcPlugin.pm /usr/share/perl5/PVE/Network/SDN/Orchestrators/

# 2. Backup original files
echo "Backing up original files to /root/backups/"
cp /usr/share/perl5/PVE/API2/Network/SDN.pm "$BACKUP_DIR/"
cp /usr/share/perl5/PVE/Network/SDN/VnetPlugin.pm "$BACKUP_DIR/"
cp /usr/share/pve-manager/js/pvemanagerlib.js "$BACKUP_DIR/"
cp /usr/share/perl5/PVE/Network/SDN/Orchestrators.pm "$BACKUP_DIR/"

# 3. Replace Javascript code with new code including orchestrator
echo "Overwriting existing GUI code with changes for orchestrator"
cp patchedfiles/pvemanagerlib.js /usr/share/pve-manager/js/pvemanagerlib.js
cp patchedfiles/VnetPlugin.pm /usr/share/perl5/PVE/Network/SDN/VnetPlugin.pm
cp patchedfiles/SDN.pm /usr/share/perl5/PVE/API2/Network/SDN.pm
cp patchedfiles/Orchestrators.pm /usr/share/perl5/PVE/Network/SDN/Orchestrators.pm

# 4. Install daemon components
echo "Installing sync daemons..."

# Install Python dependencies
echo "Installing Python dependencies..."
apt-get update -qq 2>/dev/null || echo "Repository update warning (continuing...)"
apt-get install -y python3-requests python3-urllib3 2>/dev/null || echo "Python packages already installed"

# Create daemon directory
DAEMON_DIR="/opt/proxmox-sdn-orchestrators"
mkdir -p "$DAEMON_DIR"

# Copy daemon files
if [ -f "daemons/psm_sync_daemon.py" ]; then
    cp daemons/psm_sync_daemon.py "$DAEMON_DIR/"
    chmod +x "$DAEMON_DIR/psm_sync_daemon.py"
    echo "Installed PSM sync daemon"
fi

if [ -f "daemons/afc_sync_daemon.py" ]; then
    cp daemons/afc_sync_daemon.py "$DAEMON_DIR/"
    chmod +x "$DAEMON_DIR/afc_sync_daemon.py"
    echo "Installed AFC sync daemon"
fi

# Create systemd service files (FIXED PATHS)
echo "Creating systemd services..."

# PSM sync daemon service
cat > /etc/systemd/system/psm-sync-daemon.service << 'EOF'
[Unit]
Description=PSM Sync Daemon for Proxmox SDN
After=pve-cluster.service
Wants=pve-cluster.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/proxmox-sdn-orchestrators
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=/opt/proxmox-sdn-orchestrators/.env
ExecStart=/usr/bin/python3 -u /opt/proxmox-sdn-orchestrators/psm_sync_daemon.py --config /etc/pve/sdn/orchestrators.cfg
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# AFC sync daemon service
cat > /etc/systemd/system/afc-sync-daemon.service << 'EOF'
[Unit]
Description=AFC Sync Daemon for Proxmox SDN
After=pve-cluster.service
Wants=pve-cluster.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/proxmox-sdn-orchestrators
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=/opt/proxmox-sdn-orchestrators/.env
ExecStart=/usr/bin/python3 -u /opt/proxmox-sdn-orchestrators/afc_sync_daemon.py --config /etc/pve/sdn/orchestrators.cfg
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Config file path monitoring service
cat > /etc/systemd/system/orchestrators-config.path << 'EOF'
[Unit]
Description=Monitor orchestrators config file for changes

[Path]
PathModified=/etc/pve/sdn/orchestrators.cfg
Unit=psm-sync-daemon.service
Unit=afc-sync-daemon.service

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable services
systemctl daemon-reload
systemctl enable psm-sync-daemon.service
systemctl enable afc-sync-daemon.service
systemctl enable orchestrators-config.path

echo "Enabled systemd services"

# Set up API token (FIXED PATH AND LOGIC)
echo "Setting up API token..."

# Clean up any existing installations first
if pveum user list | grep -q "sync-daemon@pve"; then
    echo "Cleaning up existing sync-daemon user and tokens..."
    pveum user delete "sync-daemon@pve" 2>/dev/null || true
fi

# Remove any existing .env file to start fresh
rm -f "$DAEMON_DIR/.env"

if [ -f "daemons/setup-api-token.sh" ]; then
    if bash daemons/setup-api-token.sh; then
        echo "API token setup completed successfully"
    else
        echo "API token setup failed - creating placeholder .env file"
        echo "PROXMOX_TOKEN_SECRET=CHANGE_ME_TO_REAL_TOKEN" > "$DAEMON_DIR/.env"
        chmod 600 "$DAEMON_DIR/.env"
    fi
else
    echo "setup-api-token.sh not found - creating placeholder .env file"
    echo "PROXMOX_TOKEN_SECRET=CHANGE_ME_TO_REAL_TOKEN" > "$DAEMON_DIR/.env"
    chmod 600 "$DAEMON_DIR/.env"
fi

# Start path monitoring (services will start when config file is created/modified)
systemctl start orchestrators-config.path
echo "Started config file monitoring"

# 7. Restart services
echo "Restarting Proxmox services..."
systemctl restart pveproxy

echo ""
echo "Installation complete!"
echo "Backup directory: $BACKUP_DIR"
echo "Daemon directory: $DAEMON_DIR"
echo ""
echo "Daemon Management:"
echo "  systemctl status psm-sync-daemon"
echo "  systemctl status afc-sync-daemon"
echo "  journalctl -u psm-sync-daemon -f"
echo "  journalctl -u afc-sync-daemon -f"
echo ""
echo "Clear your browser cache before testing."
echo ""
echo "To start the daemons manually:"
echo "  systemctl start psm-sync-daemon"
echo "  systemctl start afc-sync-daemon"
