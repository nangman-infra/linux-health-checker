#!/usr/bin/env bash
# ============================================================
# lib/bootstrap.sh — 실행 환경 초기화
#
# 역할:
#   health-check.sh가 실제 점검을 시작하기 전에 반드시 완료되어야 하는
#   사전 조건들을 처리합니다:
#
#   1. 권한 체크: root 없이도 동작하되, 보안 항목 일부는 PARTIAL 모드
#   2. 중복 실행 방지: flock 기반 Lock (없으면 PID 파일 방식으로 자동 전환)
#   3. 비정상 종료 처리: Ctrl+C, kill, 세션 끊김 모두 cleanup 실행
#   4. Python 가용성 체크: 분석 엔진 실행 불가 시 즉시 에러
# ============================================================

# ── 전역 변수 초기화 ────────────────────────────────────────
# --fix 액션에서만 채워지는 변수들입니다.
# set -u 환경(선언되지 않은 변수 참조 시 에러)에서 안전하도록 빈 문자열로 초기화합니다.
BACKUP_FILE=""
ORIGINAL_FILE=""


# ────────────────────────────────────────────────────────────
# _setup_lock: Lock 파일 경로 결정
#
# /var/lock은 root 권한이 필요한 경우가 많습니다.
# 일반 유저 실행 시 /tmp/health-check_${UID}.lock으로 자동 Fallback하여
# 권한 오류 없이 중복 실행 방지 기능이 동작합니다.
# ────────────────────────────────────────────────────────────
_setup_lock() {
    local preferred="/var/lock/health-check.lock"
    local fallback="/tmp/health-check_${UID}.lock"

    if touch "$preferred" 2>/dev/null; then
        LOCK_FILE="$preferred"
    else
        log_warn "/var/lock 쓰기 권한 없음 → Fallback 경로 사용: $fallback"
        LOCK_FILE="$fallback"
    fi
    export LOCK_FILE
}


# ────────────────────────────────────────────────────────────
# acquire_lock: 중복 실행 방지 Lock 획득
#
# 두 가지 방식 지원:
#   - flock (권장): 프로세스 종료 시 OS가 자동으로 Lock 해제
#   - PID 파일 (Fallback): flock 없는 환경에서 직접 PID를 기록
# ────────────────────────────────────────────────────────────
acquire_lock() {
    _setup_lock

    if command -v flock &>/dev/null; then
        # flock: 파일 디스크립터 9번에 Lock 설정
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            log_err "이미 실행 중인 health-check 프로세스가 있습니다. (Lock: $LOCK_FILE)"
            exit 1
        fi
        log_info "Lock 획득 (flock): $LOCK_FILE"
    else
        log_warn "flock 없음 → PID 파일 방식으로 Lock 처리"
        if [[ -f "$LOCK_FILE" ]]; then
            local old_pid
            old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
            # 이전 PID가 아직 살아있으면 중복 실행으로 판단
            if kill -0 "$old_pid" 2>/dev/null; then
                log_err "이미 실행 중인 프로세스가 있습니다: PID $old_pid"
                exit 1
            fi
        fi
        echo $$ > "$LOCK_FILE"
    fi
}


# ────────────────────────────────────────────────────────────
# cleanup: 스크립트 종료 시 항상 실행되는 정리 함수
#
# EXIT, INT(Ctrl+C), TERM(kill) 신호 모두에 연결됩니다.
# 역할:
#   1. --fix 도중 비정상 종료 시 백업 파일로 원복 (데이터 손상 방지)
#   2. Lock 파일 삭제 (다음 실행 시 Lock 충돌 방지)
# ────────────────────────────────────────────────────────────
cleanup() {
    log_info "정리(Cleanup) 수행 중..."

    # --fix가 진행 중이었다면 백업에서 원복
    if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" && -n "$ORIGINAL_FILE" ]]; then
        log_warn "비정상 종료 감지: 백업 파일을 원복합니다. ($ORIGINAL_FILE)"
        cp -a "$BACKUP_FILE" "$ORIGINAL_FILE" 2>/dev/null || true
    fi

    # Lock 파일 삭제
    if [[ -n "${LOCK_FILE:-}" ]]; then
        rm -f "$LOCK_FILE"
        log_info "Lock 해제: $LOCK_FILE"
    fi
}


# ────────────────────────────────────────────────────────────
# setup_trap: 종료 신호 핸들러 등록
#
# 어떤 상황에서 종료되더라도 cleanup이 반드시 실행되도록 보장합니다.
# ────────────────────────────────────────────────────────────
setup_trap() {
    trap 'cleanup; exit 130' INT    # Ctrl+C
    trap 'cleanup; exit 143' TERM   # kill 시그널
    trap 'cleanup' EXIT             # 정상/비정상 종료 모두
}


# ────────────────────────────────────────────────────────────
# check_privilege: 실행 권한 확인
#
# root가 아니어도 실행 가능합니다.
# 단, SUID/SGID 파일 검사, faillock 등 일부 보안 항목은
# root 없이는 결과가 제한됩니다 (PARTIAL_MODE=true).
# ────────────────────────────────────────────────────────────
check_privilege() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "Root 권한이 없습니다. 일부 보안 항목(SUID, faillock 등) 검사가 제한됩니다."
        PARTIAL_MODE=true
    else
        PARTIAL_MODE=false
    fi
    export PARTIAL_MODE
}


# ────────────────────────────────────────────────────────────
# check_python: Python3 가용성 확인
#
# 분석 엔진(analyzer/)이 Python3에 의존합니다.
# Python3가 없으면 Bash 수집까지는 가능하지만 점수 계산과 리포트가 불가능하므로
# 조기 종료합니다.
# ────────────────────────────────────────────────────────────
check_python() {
    if ! command -v python3 &>/dev/null; then
        log_err "python3를 찾을 수 없습니다. 분석 엔진 실행 불가."
        exit 1
    fi
    local py_ver
    py_ver=$(python3 -c "import sys; print('{0}.{1}'.format(sys.version_info.major, sys.version_info.minor))")
    log_info "Python 버전: $py_ver (3.4+ 필요)"
}


# ────────────────────────────────────────────────────────────
# check_dependencies: 선택적 의존성 확인
#
# 없어도 동작은 하지만, Fallback 경로로 전환되거나
# 해당 체크가 UNKNOWN 처리됩니다.
# ────────────────────────────────────────────────────────────
check_dependencies() {
    command -v nc     &>/dev/null || log_warn "nc(netcat) 없음 → /dev/tcp Bash Fallback으로 포트 체크"
    command -v curl   &>/dev/null || log_warn "curl 없음 → 외부 API Endpoint 체크 불가"
    command -v ping   &>/dev/null || log_warn "ping 없음 → 외부 도달성 체크 UNKNOWN 처리"
    command -v vmstat &>/dev/null || log_warn "vmstat 없음 → top Fallback으로 CPU 수집"
}


# ────────────────────────────────────────────────────────────
# bootstrap: 모든 초기화 단계를 순서대로 실행
#
# health-check.sh의 main()에서 단 한 번 호출합니다.
# ────────────────────────────────────────────────────────────
bootstrap() {
    check_privilege     # 1. 권한 확인 (PARTIAL_MODE 설정)
    check_python        # 2. Python3 존재 여부
    check_dependencies  # 3. 선택적 도구 확인
    acquire_lock        # 4. 중복 실행 방지 Lock
    setup_trap          # 5. 종료 신호 핸들러 등록
}
