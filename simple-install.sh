#!/bin/bash

# Complete Simple Install Script for Proxmox SDN Orchestrators
# Run from /var/tmp/proxmox-orchestrator directory

echo "🚀 Complete Proxmox SDN Orchestrators Install"
echo ""

# Check we're root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Must run as root"
    exit 1
fi

# Check we're in the right directory
if [ ! -f "README.md" ] || [ ! -d "PVE" ] || [ ! -d "js" ]; then
    echo "❌ Must run from proxmox-orchestrator repository directory"
    echo "Expected files: README.md, PVE/, js/"
    exit 1
fi

# Create backup
BACKUP="/root/orchestrators-install-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
echo "📁 Backup dir: $BACKUP"

# Function to backup and install file
backup_and_install() {
    local src="$1"
    local dest="$2"
    local description="$3"
    
    echo "📦 Installing $description..."
    
    # Backup existing file
    if [ -f "$dest" ]; then
        cp "$dest" "$BACKUP/$(basename "$dest")"
        echo "   💾 Backed up existing file"
    fi
    
    # Create destination directory
    mkdir -p "$(dirname "$dest")"
    
    # Copy file
    cp "$src" "$dest"
    echo "   ✅ $description installed"
    
    # Check Perl syntax if it's a .pm file
    if [[ "$dest" == *.pm ]]; then
        if perl -c "$dest" >/dev/null 2>&1; then
            echo "   ✅ Perl syntax OK"
        else
            echo "   ❌ Perl syntax error!"
            return 1
        fi
    fi
    
    return 0
}

echo "💾 Creating backups..."
# Backup critical files we'll modify
[ -f "/usr/share/perl5/PVE/API2/Network/SDN.pm" ] && cp "/usr/share/perl5/PVE/API2/Network/SDN.pm" "$BACKUP/"
[ -f "/usr/share/pve-manager/js/pvemanagerlib.js" ] && cp "/usr/share/pve-manager/js/pvemanagerlib.js" "$BACKUP/"
[ -f "/usr/share/perl5/PVE/Cluster.pm" ] && cp "/usr/share/perl5/PVE/Cluster.pm" "$BACKUP/"

echo ""
echo "📦 Installing Perl modules..."

# Install API Backend
backup_and_install \
    "PVE/API2/Network/SDN/Orchestrators.pm" \
    "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" \
    "API Backend"

# Install Config Module
backup_and_install \
    "PVE/Network/SDN/Orchestrators.pm" \
    "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" \
    "Configuration Module"

# Install Plugin files
backup_and_install \
    "PVE/Network/SDN/Orchestrators/Plugin.pm" \
    "/usr/share/perl5/PVE/Network/SDN/Orchestrators/Plugin.pm" \
    "Plugin Base Class"

backup_and_install \
    "PVE/Network/SDN/Orchestrators/PsmPlugin.pm" \
    "/usr/share/perl5/PVE/Network/SDN/Orchestrators/PsmPlugin.pm" \
    "PSM Plugin"

backup_and_install \
    "PVE/Network/SDN/Orchestrators/AfcPlugin.pm" \
    "/usr/share/perl5/PVE/Network/SDN/Orchestrators/AfcPlugin.pm" \
    "AFC Plugin"

echo ""
echo "⚙️  Registering with cluster filesystem..."

# Register orchestrators.cfg in cluster filesystem
CLUSTER_FILE="/usr/share/perl5/PVE/Cluster.pm"
if ! grep -q "'sdn/orchestrators.cfg'" "$CLUSTER_FILE"; then
    # Find ipams.cfg line and add ours after it
    LINE_NUM=$(grep -n "'sdn/ipams.cfg' => 1," "$CLUSTER_FILE" | cut -d: -f1)
    if [ -n "$LINE_NUM" ]; then
        sed -i "${LINE_NUM}a\\    'sdn/orchestrators.cfg' => 1," "$CLUSTER_FILE"
        echo "✅ Added orchestrators.cfg to cluster filesystem"
    else
        echo "❌ Could not find cluster filesystem registration point"
        exit 1
    fi
else
    echo "⚠️  orchestrators.cfg already registered"
fi

echo ""
echo "⚙️  Registering with SDN API..."

# Add import and API registration to SDN.pm
SDN_FILE="/usr/share/perl5/PVE/API2/Network/SDN.pm"

# Add import
if ! grep -q "use PVE::API2::Network::SDN::Orchestrators;" "$SDN_FILE"; then
    sed -i '/^use PVE::API2::Network::SDN::Fabrics;$/a use PVE::API2::Network::SDN::Orchestrators;' "$SDN_FILE"
    echo "✅ Added import statement"
else
    echo "⚠️  Import already exists"
fi

# Add API registration
if ! grep -q "subclass.*Orchestrators" "$SDN_FILE"; then
    sed -i '/subclass => "PVE::API2::Network::SDN::Fabrics",/,/});/{
        /});/a\\n__PACKAGE__->register_method({\
    subclass => "PVE::API2::Network::SDN::Orchestrators",\
    path => '\''orchestrators'\'',\
});
    }' "$SDN_FILE"
    echo "✅ Added API registration"
else
    echo "⚠️  API registration already exists"
fi

echo ""
echo "🌐 Installing JavaScript frontend..."

JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"

# Check if already patched
if grep -q "SDN Orchestrators - Complete Implementation" "$JS_FILE"; then
    echo "⚠️  JavaScript already installed"
else
    # 1. First patch the Options panel to include orchestrators view
    echo "   📝 Patching Options panel..."
    if grep -A 20 "PVE.sdn.Options" "$JS_FILE" | grep -q "pveSdnOrchestratorView"; then
        echo "   ⚠️  Options panel already includes orchestrators"
    else
        # Add orchestrators to Options panel after DNS
        sed -i '/xtype: .pveSDNDnsView./,/border: 0,/a\        },\
        {\
            xtype: '"'"'pveSdnOrchestratorView'"'"',\
            title: gettext('"'"'Orchestrators'"'"'),\
            flex: 1,\
            border: 0,' "$JS_FILE"
        echo "   ✅ Added orchestrators to Options panel"
    fi
    
    # 2. Then append the complete JavaScript implementation
    echo "   📝 Adding JavaScript implementation..."
    echo "" >> "$JS_FILE"
    echo "// SDN Orchestrators - Complete Implementation $(date)" >> "$JS_FILE"
    cat "js/orchestrators.js" >> "$JS_FILE"
    echo "   ✅ JavaScript implementation added"
fi

echo ""
echo "📁 Setting up configuration..."

# Create config directory and file
mkdir -p /etc/pve/sdn
touch /etc/pve/sdn/orchestrators.cfg
echo "✅ Created orchestrators.cfg"

echo ""
echo "🔍 Verifying installation..."

# Final syntax checks
ERRORS=0

if perl -c "$CLUSTER_FILE" >/dev/null 2>&1; then
    echo "✅ Cluster.pm syntax OK"
else
    echo "❌ Cluster.pm syntax error"
    ((ERRORS++))
fi

if perl -c "$SDN_FILE" >/dev/null 2>&1; then
    echo "✅ SDN.pm syntax OK"
else
    echo "❌ SDN.pm syntax error"
    ((ERRORS++))
fi

if perl -c "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" >/dev/null 2>&1; then
    echo "✅ Orchestrators API syntax OK"
else
    echo "❌ Orchestrators API syntax error"
    ((ERRORS++))
fi

if perl -c "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" >/dev/null 2>&1; then
    echo "✅ Orchestrators Config syntax OK"
else
    echo "❌ Orchestrators Config syntax error"
    ((ERRORS++))
fi

# Check required files exist
REQUIRED_FILES=(
    "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm"
    "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm"
    "/usr/share/perl5/PVE/Network/SDN/Orchestrators/Plugin.pm"
    "/usr/share/perl5/PVE/Network/SDN/Orchestrators/PsmPlugin.pm"
    "/usr/share/perl5/PVE/Network/SDN/Orchestrators/AfcPlugin.pm"
    "/etc/pve/sdn/orchestrators.cfg"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "✅ $(basename "$file") present"
    else
        echo "❌ $(basename "$file") missing"
        ((ERRORS++))
    fi
done

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "🎉 Installation completed successfully!"
    echo ""
    echo "🔄 Restarting Proxmox services..."
    systemctl restart pveproxy pvedaemon
    
    echo ""
    echo "📋 Next steps:"
    echo "1. ✅ Services restarted"
    echo "2. 🌐 Open web interface: Datacenter → SDN → Options"
    echo "3. 👀 Look for 'Orchestrators' section at the bottom"
    echo "4. ➕ Click 'Add' to create PSM or AFC orchestrators"
    echo ""
    echo "📁 Backup saved to: $BACKUP"
    echo ""
    echo "🧪 Test the installation:"
    echo "   - Check web interface"
    echo "   - Create a test orchestrator"
    echo "   - Verify API endpoints work"
    
else
    echo "❌ Installation completed with $ERRORS errors"
    echo "📁 Backup available at: $BACKUP"
    echo "🔄 You may need to restore from backup and fix issues"
    exit 1
fi
