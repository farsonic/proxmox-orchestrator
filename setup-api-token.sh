#!/bin/bash

# Proxmox API Token Setup for SDN Orchestrator Sync Daemons
# Usage: ./setup-api-token.sh [TOKEN_SECRET]

set -e

# Configuration
PVE_USER="sync-daemon@pve"
PVE_TOKEN_NAME="daemon-token"
DAEMON_DIR="/opt/proxmox-sdn-orchestrators"

# Helper Functions
function print_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
function print_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
function print_warning() { echo -e "\e[33m[WARNING]\e[0m $1"; }
function print_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

echo "🔑 Setting up Proxmox API Token for SDN Orchestrator Sync Daemons"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
fi

# Get token secret from argument or generate one
if [ -n "$1" ]; then
    TOKEN_SECRET="$1"
    print_info "Using provided token secret"
else
    TOKEN_SECRET=$(openssl rand -hex 32)
    print_info "Generated new token secret"
fi

# Check if user already exists
if pveum user list | grep -q "^$PVE_USER"; then
    print_warning "User $PVE_USER already exists"
else
    print_info "Creating user $PVE_USER..."
    pveum user add "$PVE_USER" --comment "SDN Orchestrator Sync Daemon"
    print_success "Created user $PVE_USER"
fi

# Check if token already exists
if pveum user token list "$PVE_USER" 2>/dev/null | grep -q "$PVE_TOKEN_NAME"; then
    print_warning "Token $PVE_TOKEN_NAME already exists for user $PVE_USER"
    print_info "Deleting existing token..."
    pveum user token delete "$PVE_USER" "$PVE_TOKEN_NAME"
fi

# Create the token
print_info "Creating API token..."
TOKEN_OUTPUT=$(pveum user token add "$PVE_USER" "$PVE_TOKEN_NAME" --privsep 0)

# Extract the full token from output
FULL_TOKEN=$(echo "$TOKEN_OUTPUT" | grep "full-tokenid" | cut -d'=' -f2 | tr -d ' ')
if [ -z "$FULL_TOKEN" ]; then
    print_error "Failed to extract token from pveum output"
    exit 1
fi

print_success "Created API token: $FULL_TOKEN"

# Set permissions for the user
print_info "Setting permissions..."
pveum acl modify / --users "$PVE_USER" --roles Administrator
print_success "Granted Administrator role to $PVE_USER"

# Create daemon directory if it doesn't exist
mkdir -p "$DAEMON_DIR"

# Create token file for daemons
TOKEN_FILE="$DAEMON_DIR/api_token.conf"
print_info "Saving token configuration to $TOKEN_FILE..."

cat > "$TOKEN_FILE" << EOF
# Proxmox API Token Configuration
# Generated: $(date)
PVE_HOST=localhost
PVE_USER=$PVE_USER
PVE_TOKEN_ID=$FULL_TOKEN
PVE_TOKEN_SECRET=$TOKEN_SECRET
PVE_VERIFY_SSL=false
EOF

# Set proper permissions
chmod 600 "$TOKEN_FILE"
chown root:root "$TOKEN_FILE"

print_success "Token configuration saved to $TOKEN_FILE"

echo ""
print_success "API Token setup completed!"
echo ""
echo "📋 Token Details:"
echo "   User: $PVE_USER"
echo "   Token ID: $FULL_TOKEN"
echo "   Token Secret: $TOKEN_SECRET"
echo "   Config File: $TOKEN_FILE"
echo ""
echo "🔒 Security Notes:"
echo "   • Token has Administrator privileges"
echo "   • Config file has restricted permissions (600)"
echo "   • SSL verification disabled for localhost"
echo ""
echo "🚀 Next Steps:"
echo "   1. Start the sync daemons:"
echo "      systemctl start proxmox-psm-sync"
echo "      systemctl start proxmox-afc-sync"
echo ""
echo "   2. Check daemon status:"
echo "      systemctl status proxmox-psm-sync"
echo "      systemctl status proxmox-afc-sync"
echo ""
echo "   3. Monitor logs:"
echo "      journalctl -u proxmox-psm-sync -f"
echo "      journalctl -u proxmox-afc-sync -f"#!/bin/bash

# Proxmox API Token Setup for SDN Orchestrator Sync Daemons
# Usage: ./setup-api-token.sh [TOKEN_SECRET]

# PASTE THE COMPLETE TOKEN SETUP SCRIPT HERE

