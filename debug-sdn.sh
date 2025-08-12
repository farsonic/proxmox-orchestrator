#!/bin/bash

# Debug SDN Registration Script

echo "🔍 Debugging SDN Registration"
echo ""

# Check service status
echo "📊 Service Status:"
systemctl is-active pveproxy && echo "✅ pveproxy active" || echo "❌ pveproxy inactive"
systemctl is-active pvedaemon && echo "✅ pvedaemon active" || echo "❌ pvedaemon inactive"
echo ""

# Check for errors in logs
echo "🚨 Recent Service Errors:"
echo "--- pveproxy errors ---"
journalctl -u pveproxy --since "5 minutes ago" --no-pager | grep -i error || echo "No pveproxy errors"
echo ""
echo "--- pvedaemon errors ---"
journalctl -u pvedaemon --since "5 minutes ago" --no-pager | grep -i error || echo "No pvedaemon errors"
echo ""

# Check if our changes are actually in the files
echo "🔍 Verifying File Contents:"
echo ""
echo "📋 SDN.pm imports:"
grep "^use.*SDN" /usr/share/perl5/PVE/API2/Network/SDN.pm
echo ""
echo "📋 SDN.pm registrations:"
grep -A 2 "subclass.*Orchestrators" /usr/share/perl5/PVE/API2/Network/SDN.pm
echo ""
echo "📋 Cluster.pm orchestrators entry:"
grep "orchestrators.cfg" /usr/share/perl5/PVE/Cluster.pm
echo ""

# Test direct Perl loading
echo "🧪 Testing Perl Module Loading:"
echo ""
echo "Testing SDN.pm..."
if perl -c /usr/share/perl5/PVE/API2/Network/SDN.pm 2>&1; then
    echo "✅ SDN.pm syntax OK"
else
    echo "❌ SDN.pm has errors"
fi
echo ""

echo "Testing Orchestrators.pm..."
if perl -c /usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm 2>&1; then
    echo "✅ Orchestrators.pm syntax OK"
else
    echo "❌ Orchestrators.pm has errors"
fi
echo ""

# Test if module can be loaded in Perl
echo "🧪 Testing Module Import:"
perl -e "
use lib '/usr/share/perl5';
eval {
    require PVE::API2::Network::SDN::Orchestrators;
    print 'Orchestrators module loaded successfully\n';
    1;
} or do {
    print 'Error loading Orchestrators module: ' . \$@ . '\n';
};
" 2>&1
echo ""

# Check if the API registration is working
echo "🔍 Testing API Structure:"
echo "Looking for SDN API registrations..."

# Find the registration section in SDN.pm
echo "📋 All __PACKAGE__->register_method calls in SDN.pm:"
grep -n "__PACKAGE__->register_method" /usr/share/perl5/PVE/API2/Network/SDN.pm
echo ""

# Check the exact format around our registration
echo "📋 Context around our registration:"
grep -A 5 -B 5 "Orchestrators" /usr/share/perl5/PVE/API2/Network/SDN.pm
echo ""

# Test a simple API call to see what's available
echo "🌐 Testing SDN API Response:"
echo "Available endpoints in /cluster/sdn:"
curl -k -s "https://localhost:8006/api2/json/cluster/sdn" 2>/dev/null || echo "API call failed"
echo ""

# Check JavaScript integration
echo "📝 Checking JavaScript Integration:"
if grep -q "sdnOrchestratorSchema" /usr/share/pve-manager/js/pvemanagerlib.js; then
    echo "✅ JavaScript code found in pvemanagerlib.js"
else
    echo "❌ JavaScript code not found in pvemanagerlib.js"
fi
echo ""

# Check config file
echo "📁 Checking Config File:"
if [ -f "/etc/pve/sdn/orchestrators.cfg" ]; then
    echo "✅ orchestrators.cfg exists"
    ls -la /etc/pve/sdn/orchestrators.cfg
else
    echo "❌ orchestrators.cfg missing"
fi
echo ""

echo "🔍 Diagnosis complete. Check the output above for issues."
