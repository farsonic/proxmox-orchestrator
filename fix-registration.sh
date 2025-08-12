#!/bin/bash

# Fix orchestrator registration script

echo "🔧 Fixing Orchestrator Registration"
echo ""

# Step 1: Add orchestrators.cfg to cluster filesystem registration
echo "📝 Adding orchestrators.cfg to cluster filesystem..."
CLUSTER_FILE="/usr/share/perl5/PVE/Cluster.pm"

# Find the exact line number where SDN configs are registered
LINE_NUM=$(grep -n "'sdn/ipams.cfg' => 1," "$CLUSTER_FILE" | cut -d: -f1)

if [ -n "$LINE_NUM" ]; then
    echo "📍 Found SDN config section at line $LINE_NUM"
    
    # Add our config after ipams.cfg
    sed -i "${LINE_NUM}a\\    'sdn/orchestrators.cfg' => 1," "$CLUSTER_FILE"
    echo "✅ Added orchestrators.cfg to cluster filesystem"
else
    echo "❌ Could not find SDN config section"
    exit 1
fi

# Step 2: Add import to SDN.pm
echo ""
echo "📝 Adding import to SDN.pm..."
SDN_FILE="/usr/share/perl5/PVE/API2/Network/SDN.pm"

# Add import after Fabrics import
if ! grep -q "use PVE::API2::Network::SDN::Orchestrators;" "$SDN_FILE"; then
    sed -i '/^use PVE::API2::Network::SDN::Fabrics;$/a use PVE::API2::Network::SDN::Orchestrators;' "$SDN_FILE"
    echo "✅ Added import statement"
else
    echo "⚠️  Import already exists"
fi

# Step 3: Add API registration after Fabrics registration
echo ""
echo "📝 Adding API registration to SDN.pm..."

if ! grep -q "subclass.*Orchestrators" "$SDN_FILE"; then
    # Find the Fabrics registration block and add ours after it
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

# Step 4: Verify syntax
echo ""
echo "🔍 Verifying syntax..."

# Check Cluster.pm syntax
if perl -c "$CLUSTER_FILE" >/dev/null 2>&1; then
    echo "✅ Cluster.pm syntax OK"
else
    echo "❌ Cluster.pm syntax error!"
    perl -c "$CLUSTER_FILE"
    exit 1
fi

# Check SDN.pm syntax
if perl -c "$SDN_FILE" >/dev/null 2>&1; then
    echo "✅ SDN.pm syntax OK"
else
    echo "❌ SDN.pm syntax error!"
    perl -c "$SDN_FILE"
    exit 1
fi

# Check orchestrator modules
if perl -c /usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm >/dev/null 2>&1; then
    echo "✅ Orchestrators API syntax OK"
else
    echo "❌ Orchestrators API syntax error!"
    perl -c /usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm
    exit 1
fi

echo ""
echo "🎉 Registration complete!"
echo ""
echo "🔄 Next steps:"
echo "1. systemctl restart pveproxy pvedaemon"
echo "2. Check web interface: Datacenter → SDN → Orchestrators"
echo ""
echo "📋 Verification commands:"
echo "grep 'orchestrators.cfg' /usr/share/perl5/PVE/Cluster.pm"
echo "grep 'Orchestrators' /usr/share/perl5/PVE/API2/Network/SDN.pm"
