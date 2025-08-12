#!/bin/bash

# Patch the SDN Options panel to include orchestrators

JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"

echo "🔧 Patching SDN Options panel to include orchestrators..."

# First, let's find the Options panel definition
if ! grep -q "PVE.sdn.Options" "$JS_FILE"; then
    echo "❌ Could not find PVE.sdn.Options panel"
    exit 1
fi

# Check if orchestrators is already in the Options panel
if grep -A 20 "PVE.sdn.Options" "$JS_FILE" | grep -q "pveSdnOrchestratorView"; then
    echo "⚠️  Orchestrators already in Options panel"
    exit 0
fi

# Create a backup
cp "$JS_FILE" "$JS_FILE.backup-options-$(date +%Y%m%d-%H%M%S)"

# Find the DNS section in the Options panel and add orchestrators after it
sed -i '/xtype: .pveSDNDnsView./,/border: 0,/a\        },\
        {\
            xtype: '"'"'pveSdnOrchestratorView'"'"',\
            title: gettext('"'"'Orchestrators'"'"'),\
            flex: 1,\
            border: 0,' "$JS_FILE"

echo "✅ Added orchestrators to Options panel"
