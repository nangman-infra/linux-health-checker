#!/usr/bin/env bash
# ============================================================
# modules/security.sh - 보안 점검 (KISA 기반 서브셋)
# ============================================================

collect_security() {
    local partial="${PARTIAL_MODE:-false}"
    local results="[]"
    local issue_count=0
    local first_item=true

    # 결과 JSON 배열에 항목 추가 헬퍼
    _add_result() {
        local name="$1" status="$2" detail="$3" confidence="${4:-HIGH}"
        local escaped_detail
        escaped_detail=$(json_escape "$detail")
        local item
        item=$(printf '{"name": "%s", "status": "%s", "detail": "%s", "confidence": "%s"}' \
            "$name" "$status" "$escaped_detail" "$confidence")
        if [[ "$first_item" == true ]]; then
            results="[$item]"
            first_item=false
        else
            results="${results%]}, $item]"
        fi
        [[ "$status" != "OK" ]] && issue_count=$((issue_count + 1))
    }

    # --- U-01: root 원격 로그인 설정 ---
    local root_login_status="OK"
    local sshd_conf="/etc/ssh/sshd_config"
    if [[ -f "$sshd_conf" ]]; then
        local permit
        permit=$(grep -i "^PermitRootLogin" "$sshd_conf" 2>/dev/null | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
        if [[ "$permit" == "yes" ]]; then
            root_login_status="CRITICAL"
        fi
        _add_result "root_ssh_login" "$root_login_status" "PermitRootLogin=${permit:-not_set}"
    else
        _add_result "root_ssh_login" "UNKNOWN" "sshd_config 파일 없음" "LOW"
    fi

    # --- U-02: 패스워드 만료(최대 사용 일수) 정책 ---
    local pass_max_days
    pass_max_days=$(grep "^PASS_MAX_DAYS" /etc/login.defs 2>/dev/null | awk '{print $2}')
    if [[ -z "$pass_max_days" || "$pass_max_days" -gt 90 ]]; then
        _add_result "password_max_days" "WARNING" "PASS_MAX_DAYS=${pass_max_days:-미설정} (권장: 90일 이하)"
    else
        _add_result "password_max_days" "OK" "PASS_MAX_DAYS=${pass_max_days}"
    fi

    # --- U-03: TMOUT 설정 (세션 자동 종료) ---
    local tmout_val="${TMOUT:-}"
    if [[ -z "$tmout_val" ]]; then
        # /etc/profile.d/ 에서 탐색
        tmout_val=$(grep -rh "TMOUT" /etc/profile.d/ 2>/dev/null | grep -v "^#" | head -1 | grep -oE '[0-9]+' || true)
    fi
    if [[ -z "$tmout_val" || "$tmout_val" -gt 600 ]]; then
        _add_result "tmout" "WARNING" "TMOUT=${tmout_val:-미설정} (권장: 600초 이하)"
    else
        _add_result "tmout" "OK" "TMOUT=${tmout_val}초"
    fi

    # --- U-04: faillock 계정 잠금 정책 ---
    if grep -q "pam_faillock" /etc/pam.d/system-auth 2>/dev/null || \
       grep -q "pam_faillock" /etc/pam.d/common-auth 2>/dev/null; then
        _add_result "faillock" "OK" "pam_faillock 설정 확인됨"
    else
        _add_result "faillock" "WARNING" "faillock 정책 미설정 (계정 잠금 미작동)"
    fi

    # --- U-05: SUID/SGID 파밍 (root 권한 필요) ---
    if [[ "$partial" == "true" ]]; then
        _add_result "suid_sgid" "UNKNOWN" "Root 권한 없음 - 검사 제한" "LOW"
    else
        # find 실행 시간 30초로 제한
        local suid_count=0
        suid_count=$(timeout 30 find / -type f \( -perm -4000 -o -perm -2000 \) \
            ! -path "/proc/*" ! -path "/sys/*" 2>/dev/null | wc -l || echo 0)
        if [[ "$suid_count" -gt 20 ]]; then
            _add_result "suid_sgid" "WARNING" "의심 SUID/SGID 파일 ${suid_count}개 발견" "MEDIUM"
        else
            _add_result "suid_sgid" "OK" "SUID/SGID 파일 ${suid_count}개 (정상 범위)"
        fi
    fi

    SECURITY_JSON=$(printf '{
  "partial_mode": %s,
  "issue_count": %d,
  "checks": %s
}' \
        "$( [[ "$partial" == "true" ]] && echo "true" || echo "false" )" \
        "$issue_count" \
        "$results")

    export SECURITY_JSON
}
