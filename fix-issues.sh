#!/bin/bash

# Fix orchestrator issues script

echo "🔧 Fixing Orchestrator Issues"
echo ""

# Issue 1: Register orchestrators.cfg in cluster filesystem
echo "📝 Registering orchestrators.cfg in cluster filesystem..."

# Find the cluster filesystem registration file
CLUSTER_FILE="/usr/share/perl5/PVE/Cluster.pm"

# Backup cluster file
cp "$CLUSTER_FILE" "/root/Cluster.pm.backup"

# Check if orchestrators.cfg is already registered
if grep -q "sdn/orchestrators.cfg" "$CLUSTER_FILE"; then
    echo "⚠️  orchestrators.cfg already registered"
else
    # Find the SDN section and add our config file
    # Look for other sdn config files to see the pattern
    echo "📍 Looking for SDN config pattern..."
    grep -n "sdn.*\.cfg" "$CLUSTER_FILE" | head -5
    
    # Add our config file registration (we'll do this manually for now)
    echo "ℹ️  Need to add orchestrators.cfg registration manually"
fi

# Issue 2: Create the orchestrators.cfg file
echo ""
echo "📝 Creating orchestrators.cfg file..."
mkdir -p /etc/pve/sdn
touch /etc/pve/sdn/orchestrators.cfg
echo "✅ Created /etc/pve/sdn/orchestrators.cfg"

# Issue 3: Fix SDN registration with correct syntax
echo ""
echo "📝 Fixing SDN registration..."
SDN_FILE="/usr/share/perl5/PVE/API2/Network/SDN.pm"

# Restore from backup first
cp "/root/backup-20250812-183825/SDN.pm" "$SDN_FILE" 2>/dev/null || echo "No backup found"

# Check current SDN.pm structure around fabrics
echo "📍 Current SDN.pm structure around fabrics:"
grep -A 10 -B 5 "fabrics" "$SDN_FILE" | grep -E "(subclass|path)"

echo ""
echo "🔍 Manual steps needed:"
echo ""
echo "1. Check cluster filesystem registration:"
echo "   grep -n 'sdn.*\.cfg' /usr/share/perl5/PVE/Cluster.pm"
echo ""
echo "2. Add orchestrators.cfg to cluster registration (look for pattern of other sdn files)"
echo ""
echo "3. Check SDN.pm structure:"
echo "   grep -A 20 -B 5 'subclass.*Fabrics' /usr/share/perl5/PVE/API2/Network/SDN.pm"
echo ""
echo "4. Add orchestrators registration in correct format"
echo ""
echo "Let's examine the current state..."

# Show current SDN structure
echo ""
echo "📋 Current SDN API registrations:"
grep -A 3 -B 1 "subclass.*SDN" "$SDN_FILE" || echo "No SDN subclass registrations found"

echo ""
echo "📋 Current imports:"
grep "^use.*SDN" "$SDN_FILE" || echo "No SDN imports found"
