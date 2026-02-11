#!/bin/bash

# ============================================
# API Key Lifecycle Script
# ============================================

set -e

# ========== Default Configuration ==========
default_server_url="http://192.168.1.100"
default_count=10
cycle_interval=3

# ========== Color Output ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========== Parse Arguments ==========
BASE_KEY=""
COUNT=$default_count
SERVER_URL=$default_server_url
DEBUG=false

show_help() {
    cat << EOF
Usage: $0 -k <base-api-key> [-n <count>] [-s <server-url>] [-d] [-h]

Options:
  -k    Base API Key (required)
  -n    Number of API Keys to create per cycle (default: $default_count)
  -s    Server URL (default: $default_server_url)
  -d    Enable debug mode
  -h    Show help

Example for GPUStack:
  $0 -k "your-admin-key" -s "http://192.168.13.2:9092" -n 5
EOF
    exit 1
}

while getopts "k:n:s:dh" opt; do
    case $opt in
        k) BASE_KEY="$OPTARG" ;;
        n) COUNT="$OPTARG" ;;
        s) SERVER_URL="$OPTARG" ;;
        d) DEBUG=true ;;
        h) show_help ;;
        *) show_help ;;
    esac
done

if [ -z "$BASE_KEY" ]; then
    echo -e "${RED}Error: Base API Key is required (-k)${NC}" >&2
    show_help
fi

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
    echo -e "${RED}Error: Count must be a positive integer${NC}" >&2
    exit 1
fi

if ! [[ "$SERVER_URL" =~ ^https?:// ]]; then
    echo -e "${RED}Error: Server URL must start with http:// or https://${NC}" >&2
    exit 1
fi
SERVER_URL="${SERVER_URL%/}"

# ========== Dependency Check ==========
for cmd in curl jq awk; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo -e "${RED}Error: $cmd command not found${NC}" >&2
        exit 1
    }
done

# ========== Network Check ==========
echo -e "${BLUE}🔍 Checking connectivity to $SERVER_URL${NC}" >&2
if ! curl -s --max-time 3 "$SERVER_URL/v2/health" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Warning: Health check failed (endpoint may not exist)${NC}" >&2
    if ! curl -s --max-time 3 "$SERVER_URL" >/dev/null 2>&1; then
        echo -e "${RED}❌ Server unreachable: $SERVER_URL${NC}" >&2
        exit 1
    fi
else
    echo -e "${GREEN}✓ Server is reachable${NC}" >&2
fi
echo "" >&2

# ========== Core Function ==========
run_cycle() {
    local timestamp_suffix=$(date +%Y%m%d%H%M%S%3N)
    local created=0
    local queried=0
    local deleted=0
    
    echo -e "${BLUE}── Creating $COUNT API Keys ─────────────────────────────${NC}" >&2
    
    declare -a key_ids
    declare -a key_values
    declare -a key_names
    
    # Create keys
    for ((i=1; i<=COUNT; i++)); do
        local key_name="cycle-${timestamp_suffix}-$i"
        
        # ALWAYS use -s to avoid progress pollution (critical fix!)
        local resp=$(curl -sf -w "\nHTTP_CODE:%{http_code}" \
            -X POST "$SERVER_URL/v2/api-keys" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $BASE_KEY" \
            -d "{\"name\":\"$key_name\",\"expires_in\":2419200,\"allowed_model_names\":[]}" 2>&1 || echo "HTTP_CODE:0")
        
        local http_code=$(echo "$resp" | grep -oP 'HTTP_CODE:\K\d+' || echo "0")
        local body=$(echo "$resp" | sed '/HTTP_CODE:/d' | tr -d '\r')
        
        # Handle curl failures
        if [ "$http_code" = "0" ]; then
            echo -e "${RED}  ✗ $key_name: Curl failed (network/connection error)${NC}" >&2
            if $DEBUG; then
                echo "    Raw output: ${body:0:300}" >&2
            fi
            continue
        fi
        
        # Handle HTTP errors
        if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
            echo -e "${RED}  ✗ $key_name: HTTP $http_code${NC}" >&2
            
            # Special error handling
            case "$http_code" in
                401) echo -e "${RED}    → Invalid or expired base API key${NC}" >&2 ;;
                403) echo -e "${RED}    → Base key lacks 'create api keys' permission${NC}" >&2 ;;
                409) echo -e "${YELLOW}    → Key name already exists (should not happen with unique names)${NC}" >&2 ;;
            esac
            
            # Show error response (truncated)
            if echo "$body" | jq . >/dev/null 2>&1; then
                echo -e "${YELLOW}    Error details: $(echo "$body" | jq -r '.message // .reason // .error // tostring' | head -c 200)${NC}" >&2
            elif [ -n "$body" ]; then
                echo -e "${YELLOW}    Response: ${body:0:200}${NC}" >&2
            fi
            continue
        fi
        
        # CRITICAL FIX: Handle numeric IDs and extract value robustly
        # GPUStack response: {"id":183, "value":"gpustack_xxx", ...}
        local key_id=$(echo "$body" | jq -r '.id | tostring' 2>/dev/null || echo "")
        local key_value=$(echo "$body" | jq -r '.value // empty' 2>/dev/null || echo "")
        
        # Validation with explicit empty checks
        if [ -z "$key_id" ] || [ "$key_id" = "null" ] || [ "$key_id" = "0" ]; then
            echo -e "${RED}  ✗ $key_name: Missing or invalid 'id' field${NC}" >&2
            echo -e "${YELLOW}    Response sample: $(echo "$body" | jq -r '{id,value,name}' 2>/dev/null || echo "${body:0:150}")${NC}" >&2
            continue
        fi
        
        if [ -z "$key_value" ] || [ "$key_value" = "null" ]; then
            echo -e "${RED}  ✗ $key_name: Missing 'value' field${NC}" >&2
            echo -e "${YELLOW}    Response sample: $(echo "$body" | jq -r '{id,value,name}' 2>/dev/null || echo "${body:0:150}")${NC}" >&2
            continue
        fi
        
        key_ids+=("$key_id")
        key_values+=("$key_value")
        key_names+=("$key_name")
        ((created++))
        echo -e "${GREEN}  ✓ $key_name (id: $key_id)${NC}" >&2
        sleep 0.05
    done
    
    if [ $created -eq 0 ]; then
        echo -e "${RED}── FAILED: No keys created ──────────────────────────────${NC}" >&2
        echo -e "${YELLOW}💡 Common causes:${NC}" >&2
        echo -e "${YELLOW}   • Base key lacks 'create api keys' permission (check admin role)${NC}" >&2
        echo -e "${YELLOW}   • Server requires specific scopes/permissions${NC}" >&2
        echo -e "${YELLOW}   • Try manual test:${NC}" >&2
        echo -e "${YELLOW}     curl -X POST $SERVER_URL/v2/api-keys \\\n       -H 'Authorization: Bearer $BASE_KEY' \\\n       -d '{\"name\":\"test-manual\",\"expires_in\":2419200,\"allowed_model_names\":[]}'${NC}" >&2
        return 1
    fi
    
    # Query workers
    echo -e "${BLUE}── Querying /v2/workers with $created keys ─────────────${NC}" >&2
    for ((i=0; i<created; i++)); do
        local resp=$(curl -sf -w "\nHTTP_CODE:%{http_code}" \
            "$SERVER_URL/v2/workers" \
            -H "Authorization: Bearer ${key_values[$i]}" 2>&1 || echo "HTTP_CODE:0")
        
        local http_code=$(echo "$resp" | grep -oP 'HTTP_CODE:\K\d+' || echo "0")
        
        if [ "$http_code" = "200" ]; then
            ((queried++))
        else
            echo -e "${RED}  ✗ ${key_names[$i]}: HTTP $http_code${NC}" >&2
        fi
    done
    echo -e "${CYAN}  → Successful queries: $queried/$created${NC}" >&2
    
    # Delete keys (GPUStack uses numeric IDs in URL)
    echo -e "${BLUE}── Deleting $created keys ───────────────────────────────${NC}" >&2
    for ((i=0; i<created; i++)); do
        # CRITICAL: GPUStack DELETE endpoint uses numeric ID directly
        local resp=$(curl -sf -w "\nHTTP_CODE:%{http_code}" \
            -X DELETE "$SERVER_URL/v2/api-keys/${key_ids[$i]}" \
            -H "Authorization: Bearer $BASE_KEY" 2>&1 || echo "HTTP_CODE:0")
        
        local http_code=$(echo "$resp" | grep -oP 'HTTP_CODE:\K\d+' || echo "0")
        
        if [[ "$http_code" = "200" || "$http_code" = "204" ]]; then
            ((deleted++))
            echo -e "${GREEN}  ✓ ${key_names[$i]} (id: ${key_ids[$i]})${NC}" >&2
        else
            echo -e "${RED}  ✗ ${key_names[$i]}: HTTP $http_code${NC}" >&2
            if $DEBUG && [ -n "$resp" ]; then
                local body=$(echo "$resp" | sed '/HTTP_CODE:/d')
                echo -e "${YELLOW}    Response: ${body:0:150}${NC}" >&2
            fi
        fi
        sleep 0.03
    done
    echo -e "${CYAN}  → Successfully deleted: $deleted/$created${NC}" >&2
    
    echo -e "${GREEN}── Cycle completed: $created keys created/used/deleted ──${NC}" >&2
    return 0
}

# ========== Main Loop ==========
echo -e "${YELLOW}🚀 GPUStack API Key Lifecycle Manager${NC}" >&2
echo -e "${YELLOW}   Server:    $SERVER_URL${NC}" >&2
echo -e "${YELLOW}   Keys/cycle: $COUNT${NC}" >&2
echo -e "${YELLOW}   Interval:  ${cycle_interval}s${NC}" >&2
[ "$DEBUG" = true ] && echo -e "${YELLOW}   Debug:     ENABLED${NC}" >&2
echo -e "${YELLOW}   Press Ctrl+C to stop${NC}" >&2
echo "" >&2

trap 'echo -e "\n${YELLOW}⏹️  Stopped by user${NC}" >&2; exit 0' INT

cycle=1
while true; do
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[${YELLOW}$ts${NC}] ${BLUE}🔄 Cycle #$cycle${NC}" >&2
    
    if run_cycle; then
        echo -e "${GREEN}✓ Cycle #$cycle completed successfully${NC}" >&2
    else
        echo -e "${RED}✗ Cycle #$cycle failed${NC}" >&2
    fi
    
    sleep $cycle_interval
    ((cycle++))
    echo "" >&2
done
