#!/usr/bin/env python3
# ============================================================
# analyzer/trend.py - 이동평균(MA) 기반 통계적 추세 분석
# Python 3.4+ 하위호환 (.format() 사용)
# ============================================================
from __future__ import print_function
import os
import json
import sys


def _load_history(history_dir, limit=5):
    """최근 limit개의 이력 JSON 파일을 시간 역순으로 읽어 반환."""
    if not os.path.isdir(history_dir):
        return []

    files = []
    try:
        for f in os.listdir(history_dir):
            if f.endswith('.json'):
                full_path = os.path.join(history_dir, f)
                files.append((os.path.getmtime(full_path), full_path))
    except OSError:
        return []

    # 최신 파일 순 정렬 후 limit 개수만 가져옴
    files.sort(reverse=True)
    recent = files[:limit]

    records = []
    for _, path in recent:
        try:
            with open(path, 'r') as fp:
                data = json.load(fp)
                records.append(data)
        except (ValueError, OSError) as e:
            sys.stderr.write("[TREND] 이력 파일 읽기 실패 (삭제): {} - {}\n".format(path, e))
            # 깨진 파일 자동 삭제
            try:
                os.remove(path)
            except OSError:
                pass
    return records


def _extract_metric(records, metric_name):
    """이력 레코드들에서 특정 지표 값 리스트를 추출한다."""
    values = []
    for rec in records:
        for item in rec.get('items', []):
            if item.get('name') == metric_name:
                val = item.get('value')
                try:
                    values.append(float(val))
                except (TypeError, ValueError):
                    pass
    return values


def _moving_average(values):
    """단순 이동평균 계산."""
    if not values:
        return 0.0
    return sum(values) / float(len(values))


def _std_dev(values, mean):
    """표준편차 계산 (통계 라이브러리 없이 직접 구현)."""
    if len(values) < 2:
        return 0.0
    variance = sum((v - mean) ** 2 for v in values) / float(len(values) - 1)
    return variance ** 0.5


def analyze_trend(history_dir, current_payload):
    """
    최근 5회 이력 기반 통계 추세 분석.
    - SPIKE: 직전 이동평균 대비 +20% 이상 급상승
    - TREND_UP: 5회 이동평균이 연속 증가 추세
    - STABLE: 정상 범위
    - N/A: 이력 없음 (최초 실행)
    """
    records = _load_history(history_dir, limit=5)

    if not records:
        return {
            'status': 'N/A',
            'message': '이력 없음 - 추세 분석 불가 (최초 실행)',
            'samples': 0
        }

    trend_results = {}
    key_metrics = ['cpu_usage', 'memory_usage', 'disk_usage']

    for metric in key_metrics:
        hist_values = _extract_metric(records, metric)

        if not hist_values:
            trend_results[metric] = 'N/A'
            continue

        ma = _moving_average(hist_values)
        sd = _std_dev(hist_values, ma)

        # 현재 값 가져오기 (resource dict에서 직접 추출)
        resource = current_payload.get('resource', {})
        current_val_raw = resource.get(metric)
        try:
            current_val = float(current_val_raw) if current_val_raw is not None else None
        except (TypeError, ValueError):
            current_val = None

        if current_val is None:
            trend_results[metric] = 'UNKNOWN'
            continue

        # SPIKE 감지: 이동평균 대비 20% 이상 급상승 또는 2 표준편차 초과
        if ma > 0 and (current_val - ma) / ma > 0.20:
            trend_results[metric] = 'SPIKE'
        elif sd > 0 and (current_val - ma) > (2 * sd):
            trend_results[metric] = 'SPIKE'
        # TREND_UP: 이력값들이 지속 상승 추세
        # hist_values[0] = 가장 최신, hist_values[-1] = 가장 오래된 값 (역순 정렬)
        # 시간 흐름상 증가 = 오래된→최신 방향으로 증가 = 인덱스 감소 방향으로 증가
        # 따라서 hist_values[i] >= hist_values[i+1] 이어야 TREND_UP
        elif len(hist_values) >= 3:
            ascending = all(
                hist_values[i] >= hist_values[i + 1]
                for i in range(len(hist_values) - 1)
            )
            if ascending and current_val >= hist_values[0]:
                trend_results[metric] = 'TREND_UP'
            else:
                trend_results[metric] = 'STABLE'
        else:
            trend_results[metric] = 'STABLE'

    # 전체 트렌드 요약
    has_spike = any(v == 'SPIKE' for v in trend_results.values())
    has_trend_up = any(v == 'TREND_UP' for v in trend_results.values())

    overall = 'STABLE'
    if has_spike:
        overall = 'SPIKE'
    elif has_trend_up:
        overall = 'TREND_UP'

    return {
        'status': overall,
        'samples': len(records),
        'metrics': trend_results,
        'message': _trend_message(overall)
    }


def _trend_message(status):
    messages = {
        'SPIKE': '급격한 리소스 상승 감지 - 즉각 원인 조사 필요',
        'TREND_UP': '지속적인 리소스 증가 추세 - 용량 검토 권장',
        'STABLE': '안정적인 추세 유지 중',
        'N/A': '이력 데이터 없음',
    }
    return messages.get(status, '알 수 없는 추세')
