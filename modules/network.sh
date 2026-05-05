#!/usr/bin/env bash
# ============================================================
# modules/network.sh - 네트워크 점검 (포트, Ping, 외부 API)
# ============================================================

# 포트 체크 헬퍼: nc 없으면 /dev/tcp Fallback
_check_port() {
    local host="$1" port="$2" timeout="${network_timeout:-3}"
    if command -v nc &>/dev/null; then
        nc -w "$timeout" -z "$host" "$port" &>/dev/null
    else
        # nc 없을 때 Bash /dev/tcp 소켓 사용
        timeout "$timeout" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null
    fi
}

collect_network() {
    local port_results="[]"
    local failed_count=0
    local total_count=0

    # --- 포트 체크 ---
    for port in ${check_ports:-"22 80 443"}; do
        total_count=$((total_count + 1))
        local status="OK"
        if ! _check_port "localhost" "$port"; then
            status="WARNING"
            failed_count=$((failed_count + 1))
        fi
        port_results="${port_results%]}, {\"port\": $port, \"status\": \"$status\"}]"
        # 첫 원소: [] -> [{...}]
        if [[ "$total_count" -eq 1 ]]; then
            port_results="[{\"port\": $port, \"status\": \"$status\"}]"
        fi
    done

    # --- 외부 Ping 체크 ---
    local ping_status="UNKNOWN"
    if command -v ping &>/dev/null; then
        if ping -c 1 -W "${ping_timeout:-2}" "${ping_target:-8.8.8.8}" &>/dev/null; then
            ping_status="OK"
        else
            ping_status="WARNING"
        fi
    else
        ping_status="UNKNOWN"
    fi

    # --- 외부 API Endpoint 체크 (services.txt 참조) ---
    local api_results="[]"
    local services_file="${SCRIPT_DIR}/config/services.txt"
    if [[ -f "$services_file" ]]; then
        local first_api=true
        while IFS= read -r endpoint || [[ -n "$endpoint" ]]; do
            [[ -z "$endpoint" || "$endpoint" =~ ^# ]] && continue
            local http_code="000"
            if command -v curl &>/dev/null; then
                http_code=$(curl --max-time "${api_timeout:-5}" \
                    --silent --output /dev/null \
                    --write-out '%{http_code}' \
                    "$endpoint" 2>/dev/null || echo "000")
            fi
            local api_status="OK"
            [[ "$http_code" == "000" || "$http_code" -ge 500 ]] && api_status="WARNING"
            local escaped_endpoint
            escaped_endpoint=$(json_escape "$endpoint")
            if [[ "$first_api" == true ]]; then
                api_results="[{\"endpoint\": \"${escaped_endpoint}\", \"http_code\": \"${http_code}\", \"status\": \"${api_status}\"}]"
                first_api=false
            else
                api_results="${api_results%]}, {\"endpoint\": \"${escaped_endpoint}\", \"http_code\": \"${http_code}\", \"status\": \"${api_status}\"}]"
            fi
        done < "$services_file"
    fi

    NETWORK_JSON=$(printf '{
  "ports": %s,
  "port_failed_count": %d,
  "ping_target": "%s",
  "ping_status": "%s",
  "api_endpoints": %s
}' \
        "$port_results" \
        "$failed_count" \
        "$(json_escape "${ping_target:-8.8.8.8}")" \
        "$ping_status" \
        "$api_results")

    export NETWORK_JSON
}
