#!/usr/bin/env python3
# ============================================================
# analyzer/main.py - Python 분석 엔진 진입점
# Python 3.4+ 하위호환 (.format() 사용, f-string 미사용)
# ============================================================
from __future__ import print_function
import sys
import os
import json
import argparse
import datetime

# 같은 디렉토리의 모듈 임포트
_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _DIR)

from score import calculate_score, classify_status
from trend import analyze_trend
from reporter import write_report, print_cli_report


def load_config(config_path):
    """config/default.conf를 파싱하여 dict로 반환."""
    config = {}
    if not os.path.isfile(config_path):
        return config
    with open(config_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' in line:
                key, _, val = line.partition('=')
                config[key.strip()] = val.strip().strip('"').strip("'")
    return config


def main():
    parser = argparse.ArgumentParser(description='Health Check Analyzer')
    parser.add_argument('--history-dir', default='./reports/history',
                        help='이력 JSON 디렉토리 경로')
    parser.add_argument('--json', action='store_true',
                        help='JSON 형식으로 stdout 출력')
    parser.add_argument('--config', default='',
                        help='설정 파일 경로 (선택)')
    args = parser.parse_args()

    # --- 1. stdin에서 Bash 수집 JSON 수신 ---
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw)
    except ValueError as e:
        sys.stderr.write("[ANALYZER ERROR] JSON 파싱 실패: {}\n".format(e))
        sys.stderr.write("수신 데이터 앞 200자: {}\n".format(raw[:200] if raw else "(비어 있음)"))
        sys.exit(2)

    # --- 2. 설정 로드 ---
    config_path = args.config or os.path.join(
        os.path.dirname(_DIR), 'config', 'default.conf')
    config = load_config(config_path)

    # --- 3. 점수 계산 및 상태 판정 ---
    score_result = calculate_score(payload, config)
    final_status, exit_code = classify_status(score_result)

    # --- 4. Trend 분석 (이력 기반 통계) ---
    trend_result = analyze_trend(args.history_dir, payload)

    # --- 5. 최종 리포트 조립 ---
    report = {
        'timestamp': datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S'),
        'hostname': payload.get('hostname', 'unknown'),
        'role': payload.get('role', 'default'),
        'health_score': score_result['score'],
        'final_status': final_status,
        'exit_code': exit_code,
        'partial_mode': payload.get('partial_mode', False),
        'trend': trend_result,
        'items': score_result['items'],
    }

    # --- 6. 리포트 저장 (Atomic Write) 및 출력 ---
    history_dir = args.history_dir
    os.makedirs(history_dir, exist_ok=True)
    write_report(report, history_dir)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print_cli_report(report)

    sys.exit(exit_code)


if __name__ == '__main__':
    main()
