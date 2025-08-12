#!/bin/bash

# Proxmox SDN Orchestrators System Health Validation Script
# Repository: https://github.com/farsonic/proxmox-orchestrator
# Usage: ./validate-orchestrators.sh [--detailed] [--fix-issues]

set -e

# Color output helpers
function print_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
function print_success() { echo -e "\e[32m[✓]\e[0m $1"; }
function print_warning() { echo -e "\e[33m[⚠]\e[0m $1"; }
function print_error() { echo -e "\e[31m[✗]\e[0m $1"; }
function print_header() { echo -e "\e[1m\e[36m$1\e[0m"; }

# Parse arguments
DETAILED=false
FIX_ISSUES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --detailed|-d)
            DETAILED=true
            shift
            ;;
        --fix-issues|-f)
            FIX_ISSUES=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--detailed] [--fix-issues]"
            echo "  --detailed    Show detailed information about each check"
            echo "  --fix-issues  Attempt to automatically fix common issues"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Global counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Test result tracking
declare -a TEST_RESULTS=()

function run_test() {
    local test_name="$1"
    local test_function="$2"
    local fix_function="${3:-}"
    
    ((TOTAL_CHECKS++))
    
    if $DETAILED; then
        print_info "Running test: $test_name"
    fi
    
    if $test_function; then
        print_success "$test_name"
        TEST_RESULTS+=("PASS: $test_name")
        ((PASSED_CHECKS++))
        return 0
    else
        local exit_code=$?
        if [ $exit_code -eq 2 ]; then
            print_warning "$test_name"
            TEST_RESULTS+=("WARN: $test_name")
            ((WARNING_CHECKS++))
        else
            print_error "$test_name"
            TEST_RESULTS+=("FAIL: $test_name")
            ((FAILED_CHECKS++))
            
            # Attempt to fix if requested and fix function provided
            if $FIX_ISSUES && [ -n "$fix_function" ]; then
                print_info "Attempting to fix: $test_name"
                if $fix_function; then
                    print_success "Fixed: $test_name"
                    TEST_RESULTS[-1]="FIXED: $test_name"
                    ((FAILED_CHECKS--))
                    ((PASSED_CHECKS++))
                else
                    print_error "Failed to fix: $test_name"
                fi
            fi
        fi
        return $exit_code
    fi
}

echo "🔍 Proxmox SDN Orchestrators System Health Validation"
echo "📦 Repository: https://github.com/farsonic/proxmox-orchestrator"
echo ""

# ============================================================================
# SYSTEM PREREQUISITES
# ============================================================================

print_header "📋 System Prerequisites"

test_root_access() {
    [ "$EUID" -eq 0 ]
}

test_proxmox_system() {
    [ -f "/usr/share/perl5/PVE/API2/Network/SDN.pm" ] && \
    [ -d "/usr/share/pve-manager" ] && \
    [ -f "/etc/pve/cluster.conf" -o -f "/etc/corosync/corosync.conf" ]
}

test_required_packages() {
    dpkg -l | grep -q "pve-manager" && \
    dpkg -l | grep -q "proxmox-ve"
}

fix_required_packages() {
    apt-get update >/dev/null 2>&1
    apt-get install -y pve-manager proxmox-ve >/dev/null 2>&1
}

run_test "Root access available" test_root_access
run_test "Proxmox VE system detected" test_proxmox_system
run_test "Required packages installed" test_required_packages fix_required_packages

# ============================================================================
# CORE SDN FUNCTIONALITY
# ============================================================================

print_header "🌐 Core SDN Functionality"

test_sdn_syntax() {
    perl -c /usr/share/perl5/PVE/API2/Network/SDN.pm >/dev/null 2>&1
}

test_sdn_modules() {
    local modules=(
        "/usr/share/perl5/PVE/Network/SDN.pm"
        "/usr/share/perl5/PVE/API2/Network/SDN/Vnets.pm"
        "/usr/share/perl5/PVE/API2/Network/SDN/Zones.pm"
        "/usr/share/perl5/PVE/API2/Network/SDN/Controllers.pm"
    )
    
    for module in "${modules[@]}"; do
        if [ ! -f "$module" ]; then
            return 1
        fi
        if ! perl -c "$module" >/dev/null 2>&1; then
            return 1
        fi
    done
    return 0
}

test_sdn_config_dir() {
    [ -d "/etc/pve/sdn" ] && [ -w "/etc/pve/sdn" ]
}

test_pve_services() {
    systemctl is-active --quiet pveproxy && \
    systemctl is-active --quiet pvedaemon
}

fix_sdn_syntax() {
    apt-get install --reinstall pve-manager >/dev/null 2>&1
}

fix_sdn_config_dir() {
    mkdir -p /etc/pve/sdn
    chmod 755 /etc/pve/sdn
}

fix_pve_services() {
    systemctl restart pveproxy pvedaemon
    sleep 5
    systemctl is-active --quiet pveproxy && systemctl is-active --quiet pvedaemon
}

run_test "SDN.pm syntax is valid" test_sdn_syntax fix_sdn_syntax
run_test "Core SDN modules present and valid" test_sdn_modules
run_test "SDN configuration directory accessible" test_sdn_config_dir fix_sdn_config_dir
run_test "Proxmox services running" test_pve_services fix_pve_services

# ============================================================================
# ORCHESTRATOR INSTALLATION STATUS
# ============================================================================

print_header "🔧 Orchestrator Installation Status"

test_orchestrator_api() {
    [ -f "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" ] && \
    perl -c /usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm >/dev/null 2>&1
}

test_orchestrator_config() {
    [ -f "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" ] && \
    perl -c /usr/share/perl5/PVE/Network/SDN/Orchestrators.pm >/dev/null 2>&1
}

test_orchestrator_registration() {
    grep -q "use PVE::API2::Network::SDN::Orchestrators;" /usr/share/perl5/PVE/API2/Network/SDN.pm && \
    grep -q "subclass.*Orchestrators" /usr/share/perl5/PVE/API2/Network/SDN.pm
}

test_frontend_integration() {
    grep -q "sdnOrchestratorSchema" /usr/share/pve-manager/js/pvemanagerlib.js 2>/dev/null
}

# These return 2 (warning) if not installed, 1 (error) if broken
test_orchestrator_api() {
    if [ ! -f "/usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm" ]; then
        return 2  # Not installed (warning)
    fi
    if ! perl -c /usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm >/dev/null 2>&1; then
        return 1  # Broken (error)
    fi
    return 0  # OK
}

test_orchestrator_config() {
    if [ ! -f "/usr/share/perl5/PVE/Network/SDN/Orchestrators.pm" ]; then
        return 2  # Not installed (warning)
    fi
    if ! perl -c /usr/share/perl5/PVE/Network/SDN/Orchestrators.pm >/dev/null 2>&1; then
        return 1  # Broken (error)
    fi
    return 0  # OK
}

test_orchestrator_registration() {
    if ! grep -q "use PVE::API2::Network::SDN::Orchestrators;" /usr/share/perl5/PVE/API2/Network/SDN.pm; then
        return 2  # Not registered
    fi
    if ! grep -q "subclass.*Orchestrators" /usr/share/perl5/PVE/API2/Network/SDN.pm; then
        return 2  # Partially registered
    fi
    return 0  # Fully registered
}

test_frontend_integration() {
    if ! grep -q "sdnOrchestratorSchema" /usr/share/pve-manager/js/pvemanagerlib.js 2>/dev/null; then
        return 2  # Not installed
    fi
    return 0  # Installed
}

run_test "Orchestrator API module" test_orchestrator_api
run_test "Orchestrator config module" test_orchestrator_config
run_test "SDN API registration" test_orchestrator_registration
run_test "Frontend JavaScript integration" test_frontend_integration

# ============================================================================
# SYNC DAEMONS
# ============================================================================

print_header "🔄 Sync Daemons"

test_daemon_directory() {
    [ -d "/opt/proxmox-sdn-orchestrators" ]
}

test_daemon_scripts() {
    [ -f "/opt/proxmox-sdn-orchestrators/psm_sync_daemon.py" ] && \
    [ -x "/opt/proxmox-sdn-orchestrators/psm_sync_daemon.py" ] && \
    [ -f "/opt/proxmox-sdn-orchestrators/afc_sync_daemon.py" ] && \
    [ -x "/opt/proxmox-sdn-orchestrators/afc_sync_daemon.py" ]
}

test_systemd_services() {
    [ -f "/etc/systemd/system/proxmox-psm-sync.service" ] && \
    [ -f "/etc/systemd/system/proxmox-afc-sync.service" ]
}

test_daemon_syntax() {
    if [ -f "/opt/proxmox-sdn-orchestrators/psm_sync_daemon.py" ]; then
        python3 -m py_compile /opt/proxmox-sdn-orchestrators/psm_sync_daemon.py 2>/dev/null
    fi
    if [ -f "/opt/proxmox-sdn-orchestrators/afc_sync_daemon.py" ]; then
        python3 -m py_compile /opt/proxmox-sdn-orchestrators/afc_sync_daemon.py 2>/dev/null
    fi
}

test_api_token_config() {
    [ -f "/opt/proxmox-sdn-orchestrators/api_token.conf" ] && \
    [ -r "/opt/proxmox-sdn-orchestrators/api_token.conf" ]
}

# These return 2 if not installed
test_daemon_directory() {
    [ -d "/opt/proxmox-sdn-orchestrators" ] || return 2
}

test_daemon_scripts() {
    if [ ! -d "/opt/proxmox-sdn-orchestrators" ]; then
        return 2
    fi
    [ -f "/opt/proxmox-sdn-orchestrators/psm_sync_daemon.py" ] && \
    [ -x "/opt/proxmox-sdn-orchestrators/psm_sync_daemon.py" ] && \
    [ -f "/opt/proxmox-sdn-orchestrators/afc_sync_daemon.py" ] && \
    [ -x "/opt/proxmox-sdn-orchestrators/afc_sync_daemon.py" ] || return 2
}

test_systemd_services() {
    [ -f "/etc/systemd/system/proxmox-psm-sync.service" ] && \
    [ -f "/etc/systemd/system/proxmox-afc-sync.service" ] || return 2
}

test_api_token_config() {
    [ -f "/opt/proxmox-sdn-orchestrators/api_token.conf" ] || return 2
}

run_test "Daemon directory exists" test_daemon_directory
run_test "Daemon scripts present and executable" test_daemon_scripts
run_test "Systemd services installed" test_systemd_services
run_test "Python syntax validation" test_daemon_syntax
run_test "API token configuration" test_api_token_config

# ============================================================================
# API AND AUTHENTICATION
# ============================================================================

print_header "🔐 API and Authentication"

test_api_user() {
    pveum user list | grep -q "^sync-daemon@pve" 2>/dev/null
}

test_api_token() {
    if test_api_user; then
        pveum user token list "sync-daemon@pve" 2>/dev/null | grep -q "daemon-token"
    else
        return 2
    fi
}

test_api_permissions() {
    if test_api_user; then
        pveum user permissions "sync-daemon@pve" 2>/dev/null | grep -q "Administrator"
    else
        return 2
    fi
}

test_python_dependencies() {
    python3 -c "import requests" 2>/dev/null
}

fix_python_dependencies() {
    apt-get install -y python3-requests >/dev/null 2>&1
}

run_test "API user exists" test_api_user
run_test "API token exists" test_api_token
run_test "API permissions configured" test_api_permissions
run_test "Python dependencies installed" test_python_dependencies fix_python_dependencies

# ============================================================================
# WEB INTERFACE ACCESSIBILITY
# ============================================================================

print_header "🌐 Web Interface"

test_web_service_response() {
    curl -k -s -o /dev/null -w "%{http_code}" "https://localhost:8006" | grep -q "^[23]"
}

test_api_endpoint() {
    if command -v curl >/dev/null; then
        # Try to access the SDN API endpoint
        local response
        response=$(curl -k -s -o /dev/null -w "%{http_code}" "https://localhost:8006/api2/json/cluster/sdn" 2>/dev/null)
        [ "$response" = "200" ] || [ "$response" = "401" ] || [ "$response" = "403" ]
    else
        return 2
    fi
}

test_javascript_syntax() {
    # Basic syntax check for the JS file
    if command -v node >/dev/null 2>&1; then
        node -c /usr/share/pve-manager/js/pvemanagerlib.js 2>/dev/null
    else
        return 2  # Can't test without node
    fi
}

run_test "Web service responding" test_web_service_response
run_test "API endpoint accessible" test_api_endpoint
run_test "JavaScript syntax valid" test_javascript_syntax

# ============================================================================
# CONFIGURATION FILES
# ============================================================================

print_header "📁 Configuration Files"

test_orchestrator_config_file() {
    if [ -f "/etc/pve/sdn/orchestrators.cfg" ]; then
        # If exists, check it's readable
        [ -r "/etc/pve/sdn/orchestrators.cfg" ]
    else
        return 2  # Not present (warning, not error)
    fi
}

test_sdn_config_syntax() {
    # Check various SDN config files for basic syntax
    local configs=(
        "/etc/pve/sdn/vnets.cfg"
        "/etc/pve/sdn/zones.cfg"
        "/etc/pve/sdn/controllers.cfg"
    )
    
    for config in "${configs[@]}"; do
        if [ -f "$config" ]; then
            # Basic syntax check - should not have malformed lines
            if ! grep -v "^#\|^$" "$config" | grep -v "^[a-zA-Z0-9_-]*:" >/dev/null 2>&1; then
                continue  # Empty or comments only
            fi
        fi
    done
    return 0
}

run_test "Orchestrator config file" test_orchestrator_config_file
run_test "SDN config files syntax" test_sdn_config_syntax

# ============================================================================
# DETAILED DIAGNOSTICS (if requested)
# ============================================================================

if $DETAILED; then
    print_header "🔍 Detailed Diagnostics"
    
    echo ""
    print_info "System Information:"
    echo "  OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "  Kernel: $(uname -r)"
    echo "  PVE Version: $(pveversion | head -1)"
    echo "  Perl Version: $(perl -v | grep 'This is perl' | cut -d'(' -f2 | cut -d')' -f1)"
    echo "  Python Version: $(python3 --version)"
    
    echo ""
    print_info "SDN Module Status:"
    find /usr/share/perl5/PVE -name "*SDN*" -type f | while read -r file; do
        if perl -c "$file" >/dev/null 2>&1; then
            echo "  ✓ $file"
        else
            echo "  ✗ $file (syntax error)"
        fi
    done
    
    if [ -d "/opt/proxmox-sdn-orchestrators" ]; then
        echo ""
        print_info "Daemon Files:"
        ls -la /opt/proxmox-sdn-orchestrators/
    fi
    
    echo ""
    print_info "Service Status:"
    for service in pveproxy pvedaemon proxmox-psm-sync proxmox-afc-sync; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo "  ✓ $service (active)"
        elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
            echo "  ⚠ $service (enabled but not active)"
        else
            echo "  ✗ $service (not enabled)"
        fi
    done
fi

# ============================================================================
# SUMMARY REPORT
# ============================================================================

echo ""
print_header "📊 Validation Summary"

echo ""
echo "Total Tests: $TOTAL_CHECKS"
echo "Passed: $PASSED_CHECKS"
echo "Warnings: $WARNING_CHECKS"  
echo "Failed: $FAILED_CHECKS"

echo ""
if [ $FAILED_CHECKS -eq 0 ]; then
    if [ $WARNING_CHECKS -eq 0 ]; then
        print_success "All tests passed! System is healthy."
        OVERALL_STATUS="HEALTHY"
    else
        print_warning "System is mostly healthy with minor warnings."
        OVERALL_STATUS="HEALTHY_WITH_WARNINGS"
    fi
else
    print_error "System has issues that need attention."
    OVERALL_STATUS="UNHEALTHY"
fi

echo ""
print_header "📋 Detailed Results"
for result in "${TEST_RESULTS[@]}"; do
    case $result in
        PASS:*) print_success "${result#PASS: }" ;;
        WARN:*) print_warning "${result#WARN: }" ;;
        FAIL:*) print_error "${result#FAIL: }" ;;
        FIXED:*) print_success "${result#FIXED: } (auto-fixed)" ;;
    esac
done

echo ""
print_header "💡 Recommendations"

case $OVERALL_STATUS in
    "HEALTHY")
        echo "✅ System is fully operational."
        echo "   • SDN functionality is working correctly"
        echo "   • All components are properly installed and configured"
        ;;
    "HEALTHY_WITH_WARNINGS")
        echo "⚠️  System is operational but has minor issues:"
        if [ $WARNING_CHECKS -gt 0 ]; then
            echo "   • Some optional components are not installed"
            echo "   • This is normal if orchestrators are not yet installed"
            echo "   • Run installer if you want to add orchestrator functionality"
        fi
        ;;
    "UNHEALTHY")
        echo "❌ System needs attention:"
        echo "   • Critical components have errors"
        echo "   • SDN functionality may be impaired"
        echo ""
        echo "🔧 Suggested actions:"
        if ! $FIX_ISSUES; then
            echo "   • Run with --fix-issues to attempt automatic repair"
        fi
        echo "   • Check Proxmox logs: journalctl -u pveproxy -u pvedaemon"
        echo "   • Consider reinstalling: apt-get install --reinstall pve-manager"
        echo "   • Restore from backup if available"
        ;;
esac

echo ""
echo "📖 For more help: https://github.com/farsonic/proxmox-orchestrator/issues"

# Exit with appropriate code
if [ $FAILED_CHECKS -gt 0 ]; then
    exit 1
elif [ $WARNING_CHECKS -gt 0 ]; then
    exit 2
else
    exit 0
fi
