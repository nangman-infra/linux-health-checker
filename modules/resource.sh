#!/usr/bin/env bash
# ============================================================
# modules/resource.sh - 리소스 수집 (CPU, Memory, Disk, Inode, Load)
# ============================================================

collect_resource() {
    # --- CPU 사용률 ---
    local cpu_usage=0
    if command -v vmstat &>/dev/null; then
        # vmstat: idle 컬럼을 2회 샘플링 후 사용률 환산
        local idle
        idle=$(vmstat 1 2 | tail -1 | awk '{print $15}')
        cpu_usage=$((100 - idle))
    elif command -v top &>/dev/null; then
        # top 1회 실행 후 idle 파싱 (범용)
        local idle
        idle=$(top -bn1 | grep -i "cpu" | head -1 | awk '{for(i=1;i<=NF;i++) if($i~/id,/) print $(i-1)}' | tr -d '%,')
        [[ -z "$idle" ]] && idle=0
        cpu_usage=$((100 - ${idle%.*}))
    else
        cpu_usage=-1  # 수집 불가 표시
    fi

    # --- Memory 사용률 (cgroup v2 → v1 → free 순서로 Fallback) ---
    local mem_total=0 mem_used_pct=0 mem_source="free"

    if [[ -f /sys/fs/cgroup/memory.max ]]; then
        # cgroup v2: 컨테이너 환경 감지
        local limit avail
        limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
        avail=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)
        if [[ "$limit" != "max" && "$limit" -gt 0 ]]; then
            mem_used_pct=$(( avail * 100 / limit ))
            mem_source="cgroup_v2"
        fi
    elif [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        # cgroup v1
        local limit avail
        limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        avail=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
        # 2^63 은 "제한 없음" 의미
        if [[ "$limit" -lt 9223372036854775807 && "$limit" -gt 0 ]]; then
            mem_used_pct=$(( avail * 100 / limit ))
            mem_source="cgroup_v1"
        fi
    fi

    # cgroup 미탐지 시 free 명령 사용
    if [[ "$mem_source" == "free" ]]; then
        local mem_total_kb mem_avail_kb
        mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        mem_avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
        if [[ "$mem_total_kb" -gt 0 ]]; then
            local mem_used_kb=$(( mem_total_kb - mem_avail_kb ))
            mem_used_pct=$(( mem_used_kb * 100 / mem_total_kb ))
        fi
    fi

    # --- Disk 사용률 (루트 파티션 /) ---
    local disk_usage=0
    disk_usage=$(df / | tail -1 | awk '{gsub(/%/,"",$5); print $5}')

    # --- Inode 사용률 ---
    local inode_usage=0
    inode_usage=$(df -i / | tail -1 | awk '{gsub(/%/,"",$5); print $5}')
    [[ "$inode_usage" == "-" ]] && inode_usage=0

    # --- Load Average (1분 평균) ---
    local load_avg core_count load_pct=0
    load_avg=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || uptime | awk -F'load average:' '{print $2}' | cut -d',' -f1 | tr -d ' ')
    core_count=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    # 소수점 제거 후 비교 (bash는 정수 연산만 가능)
    local load_int=${load_avg%.*}
    local load_threshold
    load_threshold=$(echo "$core_count $load_multiplier" | awk '{printf "%d", $1 * $2}')

    # --- 결과를 JSON 이스케이프 후 global 변수에 적재 ---
    RESOURCE_JSON=$(printf '{
  "cpu_usage": %d,
  "memory_usage": %d,
  "memory_source": "%s",
  "disk_usage": %d,
  "inode_usage": %d,
  "load_avg": "%s",
  "load_threshold": %d,
  "core_count": %d
}' \
        "$cpu_usage" \
        "$mem_used_pct" \
        "$(json_escape "$mem_source")" \
        "$disk_usage" \
        "$inode_usage" \
        "$(json_escape "$load_avg")" \
        "$load_threshold" \
        "$core_count")

    export RESOURCE_JSON
}
