#!/usr/bin/env bash
# ============================================================
# lib/fix.sh - Safe & Reversible 자동 복구 엔진
# Auto-remediation is limited to safe and reversible configurations only.
# ============================================================

# 전역: Fix 중 원복을 위한 경로 추적 (bootstrap.sh cleanup에서 참조)
BACKUP_FILE=""
ORIGINAL_FILE=""

# 안전한 파일 백업
_backup_file() {
    local target="$1"
    if [[ ! -f "$target" ]]; then
        log_err "백업 대상 파일 없음: $target"
        return 1
    fi
    local backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$target" "$backup"
    BACKUP_FILE="$backup"
    ORIGINAL_FILE="$target"
    export BACKUP_FILE ORIGINAL_FILE
    log_info "백업 완료: $backup"
}

# Fix 후 1차 검증
_verify() {
    local check_fn="$1"
    $check_fn
}

# 롤백 후 재검증 (Final Verify)
_rollback_and_final_verify() {
    local verify_fn="$1"
    log_warn "Fix 검증 실패. 롤백(Auto-Rollback) 실행 중..."

    if [[ -z "$BACKUP_FILE" || ! -f "$BACKUP_FILE" ]]; then
        log_err "[CRITICAL_EMERGENCY] 백업 파일이 없어 롤백 불가능!"
        audit_log "[CRITICAL_EMERGENCY] 백업 파일 없음 - 수동 복구 필요"
        exit 3
    fi

    cp -a "$BACKUP_FILE" "$ORIGINAL_FILE" || {
        log_err "[CRITICAL_EMERGENCY] 롤백 자체 실패! 파일: $ORIGINAL_FILE"
        audit_log "[CRITICAL_EMERGENCY] 롤백 실패 - 수동 복구 필요: $ORIGINAL_FILE"
        exit 3
    }

    log_info "롤백 완료. Final Verify 수행 중..."
    if ! _verify "$verify_fn"; then
        log_err "[CRITICAL_EMERGENCY] 롤백 후에도 검증 실패! 시스템 상태 불안정."
        audit_log "[CRITICAL_EMERGENCY] Final Verify 실패 - 즉각 수동 점검 필요"
        exit 3
    fi

    log_warn "롤백 성공. 시스템이 원 상태로 복구됨."
    audit_log "[ROLLBACK] 자동 롤백 성공: $ORIGINAL_FILE"
}

# ============================================================
# Fix 항목별 구현 (Safe & Reversible 설정만 대상)
# ============================================================

# [FIX-01] PermitRootLogin → prohibit-password 로 완화 설정
fix_root_login() {
    local sshd_conf="/etc/ssh/sshd_config"
    [[ "$DRY_RUN" == "true" ]] && { log_info "[DRY-RUN] root 로그인 비활성화 시뮬레이션"; return 0; }
    [[ $EUID -ne 0 ]] && { log_warn "root 권한 없음 - root login fix 스킵"; return 1; }

    _backup_file "$sshd_conf" || return 1

    sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' "$sshd_conf"
    log_info "[ACTION] PermitRootLogin → prohibit-password 적용"
    audit_log "[FIX] root login 설정 변경: $sshd_conf"

    # 1차 Verify
    if ! grep -q "PermitRootLogin prohibit-password" "$sshd_conf"; then
        _rollback_and_final_verify "_verify_root_login"
        return 1
    fi
    log_ok "[VERIFY] root login 설정 검증 성공"
    return 0
}

_verify_root_login() {
    ! grep -qw "PermitRootLogin yes" /etc/ssh/sshd_config 2>/dev/null
}

# [FIX-02] PASS_MAX_DAYS 를 90일로 설정
fix_password_policy() {
    local login_defs="/etc/login.defs"
    [[ "$DRY_RUN" == "true" ]] && { log_info "[DRY-RUN] 패스워드 정책 수정 시뮬레이션"; return 0; }
    [[ $EUID -ne 0 ]] && { log_warn "root 권한 없음 - password policy fix 스킵"; return 1; }

    _backup_file "$login_defs" || return 1

    if grep -q "^PASS_MAX_DAYS" "$login_defs"; then
        sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' "$login_defs"
    else
        echo "PASS_MAX_DAYS   90" >> "$login_defs"
    fi
    log_info "[ACTION] PASS_MAX_DAYS → 90일 설정"
    audit_log "[FIX] 패스워드 최대 사용 기간 설정: $login_defs"

    if ! grep -q "^PASS_MAX_DAYS.*90" "$login_defs"; then
        _rollback_and_final_verify "_verify_password_policy"
        return 1
    fi
    log_ok "[VERIFY] 패스워드 정책 검증 성공"
    return 0
}

_verify_password_policy() {
    local days
    days=$(grep "^PASS_MAX_DAYS" /etc/login.defs 2>/dev/null | awk '{print $2}')
    [[ -n "$days" && "$days" -le 90 ]]
}

# ============================================================
# Fix 디스패처: Python 분석 결과를 받아 해당 Fix 함수 실행
# ============================================================
run_fixes() {
    local fix_targets="$1"  # 공백 구분 항목명 리스트 (e.g. "root_ssh_login password_max_days")

    [[ "$FIX_MODE" != "true" ]] && return 0

    log_info "=== Auto-Remediation 시작 (Safe & Reversible 대상만) ==="

    for target in $fix_targets; do
        case "$target" in
            root_ssh_login)    fix_root_login ;;
            password_max_days) fix_password_policy ;;
            *)
                log_warn "자동 복구 지원 없는 항목: $target (수동 조치 필요)"
                ;;
        esac
    done

    # Fix 완료 후 백업 파일 정리
    BACKUP_FILE=""
    ORIGINAL_FILE=""
}
