#!/usr/bin/env bash
# ============================================================
# health-check.sh — 시스템 헬스체크 진입점 (CLI 라우터)
#
# 역할:
#   이 스크립트는 전체 헬스체크 시스템의 게이트웨이입니다.
#   1) CLI 인자를 파싱해서 실행 모드를 결정하고
#   2) Bash 수집 모듈을 불러 서버 상태를 JSON으로 만들고
#   3) 그 JSON을 Python 분석 엔진에 파이프로 넘깁니다.
#   4) Python의 결과(점수/상태)를 OS Exit Code로 반환합니다.
#
# 왜 Bash + Python 하이브리드인가?
#   - Bash: 외부 패키지 없이 어느 Linux에서나 `top`, `df`, `ss` 같은
#           시스템 명령어를 바로 실행할 수 있는 유일한 선택지입니다.
#   - Python: 가중치 계산, 통계 기반 Trend 분석, JSON 리포트 생성 같은
#             복잡한 로직을 Bash 로 짜면 유지보수가 불가능해집니다.
#
# 실행 예시:
#   ./health-check.sh run                          # 기본 점검
#   ./health-check.sh run --json                   # JSON 출력 (파이프라인 연동)
#   ./health-check.sh run --role db                # DB 서버 역할 기반 점검
#   ./health-check.sh run --fix --dry-run          # 자동 복구 시뮬레이션만
#   sudo ./health-check.sh run                     # 전체 보안 항목 포함 점검
#
# Exit Code 의미 (CI/CD 연동 중요):
#   0 = OK       (모든 지표 정상)
#   1 = WARNING  (경고 항목 존재, 예방 점검 필요)
#   2 = CRITICAL (즉각 조치 필요)
#   3 = EMERGENCY (자동 복구 실패, 수동 개입 필요)
# ============================================================
set -euo pipefail

# ── 스크립트 절대 경로 설정 ─────────────────────────────────
# 어디서 실행하든 모듈 경로가 고정되도록 합니다.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 공통 라이브러리 로드 ────────────────────────────────────
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"
# shellcheck source=lib/bootstrap.sh
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ── 기본값 초기화 ───────────────────────────────────────────
# 모든 플래그는 여기서 초기화합니다. 나중에 --config 오버라이드도 허용합니다.
CONFIG_FILE="${SCRIPT_DIR}/config/default.conf"
ROLE="default"       # 서버 역할: default | web | db | batch
FIX_MODE=false       # --fix: 안전한 항목에 한해 자동 조치
JSON_MODE=false      # --json: stdout으로 JSON 출력 (CI/CD, 모니터링 시스템 연동)
DRY_RUN=false        # --dry-run: Fix 시뮬레이션만, 실제 변경 없음
TARGET_FILE=""       # --targets <file>: 다중 서버 대상 파일


# ────────────────────────────────────────────────────────────
# _load_config: 설정 파일(default.conf)을 현재 shell 환경에 로드
# ────────────────────────────────────────────────────────────
_load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=config/default.conf
        source "$CONFIG_FILE"
    else
        log_err "설정 파일을 찾을 수 없습니다: $CONFIG_FILE"
        exit 1
    fi
}


# ────────────────────────────────────────────────────────────
# _parse_args: CLI 인자 파싱
# 지원 옵션: run, --fix, --json, --dry-run, --role, --targets, --config
# ────────────────────────────────────────────────────────────
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            run)           shift ;;                            # 서브커맨드 (현재 단일)
            --fix)         FIX_MODE=true; shift ;;
            --json)        JSON_MODE=true; shift ;;
            --dry-run)     DRY_RUN=true; shift ;;
            --role)        ROLE="$2"; shift 2 ;;
            --targets)     TARGET_FILE="$2"; shift 2 ;;
            --config)      CONFIG_FILE="$2"; _load_config; shift 2 ;;  # 즉시 재로드
            -h|--help)     _usage; exit 0 ;;
            *)
                log_err "알 수 없는 옵션: $1"
                _usage
                exit 1
                ;;
        esac
    done
}


# ────────────────────────────────────────────────────────────
# _usage: 도움말 출력
# ────────────────────────────────────────────────────────────
_usage() {
    cat <<EOF
사용법: $(basename "$0") run [OPTIONS]

시스템 자원(CPU, 메모리, 디스크), 네트워크 포트, 보안 설정을 종합 점검하여
Health Score와 상태(OK / WARNING / CRITICAL)를 출력합니다.

옵션:
  --fix              안전하고 가역적인 보안 설정 오류에 한해 자동 복구
  --json             결과를 JSON 형식으로 stdout 출력 (파이프라인/모니터링 연동)
  --dry-run          --fix와 함께 사용: 실제 변경 없이 복구 시뮬레이션만
  --role <role>      서버 역할 지정 (web | db | batch) — 역할별 임계치 적용
  --targets <file>   다중 서버 대상 파일 (서버 목록 순차 점검)
  --config <file>    기본 설정 파일(config/default.conf) 대신 사용할 파일 지정
  -h, --help         이 도움말 출력

Exit Code:
  0 = OK        모든 지표 정상
  1 = WARNING   경고 항목 존재 (예방 점검 권장)
  2 = CRITICAL  즉각 조치 필요
  3 = EMERGENCY 자동 복구 실패 — 수동 개입 필요

예시:
  ./health-check.sh run
  ./health-check.sh run --json | jq '.health_score'
  sudo ./health-check.sh run --fix
  sudo ./health-check.sh run --fix --dry-run
EOF
}


# ────────────────────────────────────────────────────────────
# _run_single: 단일 서버 점검 실행
#
# 흐름:
#   1. Bash 모듈 3개가 각각 JSON 변수(RESOURCE_JSON, NETWORK_JSON, SECURITY_JSON)를 채움
#   2. 세 JSON을 하나의 payload로 합침
#   3. payload를 Python 분석 엔진에 stdin 파이프로 전달
#   4. Python이 점수 계산, Trend 분석, 화면 출력을 담당
# ────────────────────────────────────────────────────────────
_run_single() {
    log_info "=== System Health Check 시작 (Role: ${ROLE}) ==="
    audit_log "run executed | role=${ROLE} | fix=${FIX_MODE} | dry_run=${DRY_RUN}"

    # ── Bash 수집 모듈 로드 및 실행 ────────────────────────
    # 각 모듈은 전역 변수(RESOURCE_JSON, NETWORK_JSON, SECURITY_JSON)를 채웁니다.
    source "${SCRIPT_DIR}/modules/resource.sh"
    source "${SCRIPT_DIR}/modules/network.sh"
    source "${SCRIPT_DIR}/modules/security.sh"

    collect_resource
    collect_network
    collect_security

    # ── 수집 결과를 단일 JSON payload로 병합 ───────────────
    # 이 payload가 Python 분석 엔진의 stdin으로 들어갑니다.
    local payload
    payload=$(printf '{
  "hostname": "%s",
  "role": "%s",
  "fix_mode": %s,
  "dry_run": %s,
  "partial_mode": %s,
  "resource": %s,
  "network": %s,
  "security": %s
}' \
        "$(json_escape "$(hostname)")" \
        "$(json_escape "$ROLE")" \
        "$( [[ "$FIX_MODE" == true ]] && echo "true" || echo "false" )" \
        "$( [[ "$DRY_RUN" == true ]] && echo "true" || echo "false" )" \
        "$( [[ "$PARTIAL_MODE" == true ]] && echo "true" || echo "false" )" \
        "$RESOURCE_JSON" \
        "$NETWORK_JSON" \
        "$SECURITY_JSON")

    # ── Python 분석 엔진 실행 ───────────────────────────────
    # Python이 점수 계산, 추세 분석, 리포트 저장, 화면 출력을 모두 담당합니다.
    # Python의 sys.exit() 코드를 그대로 exit_code에 받아 OS로 전달합니다.
    local exit_code=0
    if [[ "$JSON_MODE" == true ]]; then
        echo "$payload" | python3 "${SCRIPT_DIR}/analyzer/main.py" \
            --history-dir "${SCRIPT_DIR}/reports/history" \
            --json \
            || exit_code=$?
    else
        echo "$payload" | python3 "${SCRIPT_DIR}/analyzer/main.py" \
            --history-dir "${SCRIPT_DIR}/reports/history" \
            || exit_code=$?
    fi

    # ── 이력 파일 자동 로테이션 (최근 5개 유지) ─────────────
    history_rotate

    return "$exit_code"
}


# ────────────────────────────────────────────────────────────
# _run_targets: 다중 서버 순차 점검 (--targets 옵션)
#
# targets.txt에 서버 목록을 줄 단위로 기입하면 순차 실행합니다.
# 결과는 Worst-case 우선: 가장 심각한 Exit Code를 최종 반환합니다.
#
# TODO: SSH 기반 원격 실행으로 확장 예정
#       현재는 단일 서버에서 로컬 점검만 반복합니다.
# ────────────────────────────────────────────────────────────
_run_targets() {
    local worst_exit=0
    while IFS= read -r target || [[ -n "$target" ]]; do
        # 빈 줄 및 주석(#으로 시작) 건너뜀
        [[ -z "$target" || "$target" =~ ^# ]] && continue
        log_info "--- 점검 대상: $target ---"
        _run_single
        local code=$?
        # Worst-case 집계: 더 심각한 코드가 있으면 교체
        [[ $code -gt $worst_exit ]] && worst_exit=$code
    done < "$TARGET_FILE"
    return "$worst_exit"
}


# ════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════
main() {
    _parse_args "$@"
    _load_config
    bootstrap    # 권한 체크 → Lock 획득 → trap 등록 (lib/bootstrap.sh)

    local final_exit=0

    if [[ -n "$TARGET_FILE" ]]; then
        _run_targets || final_exit=$?
    else
        _run_single || final_exit=$?
    fi

    # Exit Code를 OS로 반환합니다 (CI/CD와 외부 모니터링 시스템 연동의 핵심)
    exit "$final_exit"
}

main "$@"
