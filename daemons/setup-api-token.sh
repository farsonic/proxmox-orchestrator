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

# ALWAYS DELETE FIRST - no checking, just delete everything
print_info "Deleting existing token daemon-token..."
pveum user token delete sync-daemon@pve daemon-token 2>/dev/null || true

print_info "Deleting existing user sync-daemon@pve..."
pveum user delete sync-daemon@pve 2>/dev/null || true

print_success "Cleanup completed"

# Create fresh user
print_info "Creating fresh user sync-daemon@pve..."
pveum user add sync-daemon@pve --comment "SDN Orchestrator Sync Daemon"
print_success "Created user sync-daemon@pve"

# Create the token
print_info "Creating API token..."
TOKEN_OUTPUT=$(pveum user token add sync-daemon@pve daemon-token --privsep 0)

# Extract the full token ID from output
FULL_TOKEN=$(echo "$TOKEN_OUTPUT" | grep "full-tokenid" | cut -d'=' -f2 | tr -d ' ')
if [ -z "$FULL_TOKEN" ]; then
    print_error "Failed to extract token ID from pveum output"
    exit 1
fi

# Extract the actual token secret that Proxmox generated (clean UUID only)
ACTUAL_TOKEN_SECRET=$(echo "$TOKEN_OUTPUT" | grep -E "value.*[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" | grep -oE "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
if [ -z "$ACTUAL_TOKEN_SECRET" ]; then
    print_error "Failed to extract token secret from pveum output"
    print_error "Token output was: $TOKEN_OUTPUT"
    exit 1
fi

print_success "Created API token: $FULL_TOKEN"
print_info "Token secret: $ACTUAL_TOKEN_SECRET"

# Set permissions for the user
print_info "Setting permissions..."
pveum acl modify / --users sync-daemon@pve --roles Administrator
print_success "Granted Administrator role to sync-daemon@pve"

# Create daemon directory if it doesn't exist
mkdir -p "$DAEMON_DIR"

# Create token file for daemons
TOKEN_FILE="$DAEMON_DIR/api_token.conf"
print_info "Saving token configuration to $TOKEN_FILE..."
cat > "$TOKEN_FILE" << EOF
# Proxmox API Token Configuration
# Generated: $(date)
PVE_HOST=localhost
PVE_USER=sync-daemon@pve
PVE_TOKEN_ID=$FULL_TOKEN
PVE_TOKEN_SECRET=$ACTUAL_TOKEN_SECRET
PVE_VERIFY_SSL=false
EOF

# Set proper permissions
chmod 600 "$TOKEN_FILE"
chown root:root "$TOKEN_FILE"
print_success "Token configuration saved to $TOKEN_FILE"

# Update the .env file that your daemons are looking for
ENV_FILE="$DAEMON_DIR/.env"
print_info "Updating .env file at $ENV_FILE..."
cat > "$ENV_FILE" << EOF
# Proxmox API Token Environment Variables
# Generated: $(date)
PVE_TOKEN_SECRET_READ=$ACTUAL_TOKEN_SECRET
PVE_HOST=localhost
PVE_PORT=8006
PVE_API_USER=sync-daemon@pve
PVE_TOKEN_NAME=daemon-token
PVE_VERIFY_SSL=false
EOF

# Set proper permissions
chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE"
print_success "Updated .env file with real token secret"

echo ""
print_success "API Token setup completed!"
echo ""
echo "📋 Token Details:"
echo "   User: sync-daemon@pve"
echo "   Token ID: $FULL_TOKEN"
echo "   Token Secret: $ACTUAL_TOKEN_SECRET"
echo "   Config File: $TOKEN_FILE"
echo "   Environment File: $ENV_FILE"
echo ""
echo "🔒 Security Notes:"
echo "   • Token has Administrator privileges"
echo "   • Config file has restricted permissions (600)"
echo "   • SSL verification disabled for localhost"
echo ""
echo "🚀 Next Steps:"
echo "   1. Start the sync daemons:"
echo "      systemctl start psm-sync-daemon"
echo "      systemctl start afc-sync-daemon"
echo ""
echo "   2. Check daemon status:"
echo "      systemctl status psm-sync-daemon"
echo "      systemctl status afc-sync-daemon"
echo ""
echo "   3. Monitor logs:"
echo "      journalctl -u psm-sync-daemon -f"
echo "      journalctl -u afc-sync-daemon -f"
