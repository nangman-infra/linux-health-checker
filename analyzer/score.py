#!/usr/bin/env python3
# ============================================================
# analyzer/score.py - 가중치 기반 Health Score 계산 및 판정
# Python 3.4+ 하위호환 (.format() 사용)
# ============================================================
from __future__ import print_function

# --- Impact Weight 정의 (높을수록 장애 직결) ---
DEFAULT_WEIGHTS = {
    'disk':     5,
    'memory':   4,
    'security': 4,
    'cpu':      3,
    'network':  3,
    'load':     2,
    'inode':    2,
}

# --- Aggregation Rule (우선순위 순서) ---
# 1. [Fatal Rule]  복구 실패        → EMERGENCY (exit 3)
# 2. [Hard Rule]   단일 CRITICAL    → CRITICAL  (exit 2)
# 3. [Score Rule]  Score < 50       → CRITICAL  (exit 2)
# 4. [Score Rule]  Score 50~79      → WARNING   (exit 1)
# 5. 나머지                          → OK        (exit 0)

STATUS_RANK = {'OK': 0, 'WARNING': 1, 'CRITICAL': 2, 'EMERGENCY': 3}
EXIT_MAP = {'OK': 0, 'WARNING': 1, 'CRITICAL': 2, 'EMERGENCY': 3}


def _get_int(config, key, default):
    try:
        return int(config.get(key, default))
    except (ValueError, TypeError):
        return default


def _evaluate_resource(resource, config):
    """리소스 지표별 상태와 페널티를 계산한다."""
    items = []

    cpu = resource.get('cpu_usage', -1)
    if cpu >= 0:
        cpu_warn = _get_int(config, 'cpu_warning', 80)
        cpu_crit = _get_int(config, 'cpu_critical', 95)
        if cpu >= cpu_crit:
            items.append({'name': 'cpu_usage', 'value': cpu, 'unit': '%',
                          'status': 'CRITICAL', 'weight': DEFAULT_WEIGHTS['cpu'],
                          'confidence': 'HIGH', 'penalty': 30})
        elif cpu >= cpu_warn:
            items.append({'name': 'cpu_usage', 'value': cpu, 'unit': '%',
                          'status': 'WARNING', 'weight': DEFAULT_WEIGHTS['cpu'],
                          'confidence': 'HIGH', 'penalty': 10})
        else:
            items.append({'name': 'cpu_usage', 'value': cpu, 'unit': '%',
                          'status': 'OK', 'weight': DEFAULT_WEIGHTS['cpu'],
                          'confidence': 'HIGH', 'penalty': 0})
    else:
        items.append({'name': 'cpu_usage', 'value': -1, 'unit': '%',
                      'status': 'UNKNOWN', 'weight': DEFAULT_WEIGHTS['cpu'],
                      'confidence': 'LOW', 'penalty': 5})

    mem = resource.get('memory_usage', 0)
    mem_warn = _get_int(config, 'memory_warning', 80)
    mem_crit = _get_int(config, 'memory_critical', 95)
    mem_src = resource.get('memory_source', 'free')
    confidence = 'HIGH' if mem_src in ('cgroup_v1', 'cgroup_v2') else 'MEDIUM'
    if mem >= mem_crit:
        items.append({'name': 'memory_usage', 'value': mem, 'unit': '%',
                      'status': 'CRITICAL', 'weight': DEFAULT_WEIGHTS['memory'],
                      'confidence': confidence, 'penalty': 30})
    elif mem >= mem_warn:
        items.append({'name': 'memory_usage', 'value': mem, 'unit': '%',
                      'status': 'WARNING', 'weight': DEFAULT_WEIGHTS['memory'],
                      'confidence': confidence, 'penalty': 10})
    else:
        items.append({'name': 'memory_usage', 'value': mem, 'unit': '%',
                      'status': 'OK', 'weight': DEFAULT_WEIGHTS['memory'],
                      'confidence': confidence, 'penalty': 0})

    disk = resource.get('disk_usage', 0)
    disk_warn = _get_int(config, 'disk_warning', 80)
    disk_crit = _get_int(config, 'disk_critical', 90)
    if disk >= disk_crit:
        items.append({'name': 'disk_usage', 'value': disk, 'unit': '%',
                      'status': 'CRITICAL', 'weight': DEFAULT_WEIGHTS['disk'],
                      'confidence': 'HIGH', 'penalty': 30})
    elif disk >= disk_warn:
        items.append({'name': 'disk_usage', 'value': disk, 'unit': '%',
                      'status': 'WARNING', 'weight': DEFAULT_WEIGHTS['disk'],
                      'confidence': 'HIGH', 'penalty': 10})
    else:
        items.append({'name': 'disk_usage', 'value': disk, 'unit': '%',
                      'status': 'OK', 'weight': DEFAULT_WEIGHTS['disk'],
                      'confidence': 'HIGH', 'penalty': 0})

    inode = resource.get('inode_usage', 0)
    inode_crit = _get_int(config, 'inode_critical', 90)
    if inode >= inode_crit:
        items.append({'name': 'inode_usage', 'value': inode, 'unit': '%',
                      'status': 'CRITICAL', 'weight': DEFAULT_WEIGHTS['inode'],
                      'confidence': 'HIGH', 'penalty': 30})
    else:
        items.append({'name': 'inode_usage', 'value': inode, 'unit': '%',
                      'status': 'OK', 'weight': DEFAULT_WEIGHTS['inode'],
                      'confidence': 'HIGH', 'penalty': 0})

    load_avg_str = resource.get('load_avg', '0')
    load_threshold = resource.get('load_threshold', 0)
    try:
        load_val = float(load_avg_str)
    except ValueError:
        load_val = 0.0
    if load_threshold > 0 and load_val > load_threshold:
        items.append({'name': 'load_average', 'value': load_val, 'unit': '',
                      'status': 'WARNING', 'weight': DEFAULT_WEIGHTS['load'],
                      'confidence': 'MEDIUM', 'penalty': 10})
    else:
        items.append({'name': 'load_average', 'value': load_val, 'unit': '',
                      'status': 'OK', 'weight': DEFAULT_WEIGHTS['load'],
                      'confidence': 'MEDIUM', 'penalty': 0})

    return items


def _evaluate_network(network):
    items = []
    ports = network.get('ports', [])
    for p in ports:
        st = p.get('status', 'UNKNOWN')
        items.append({'name': 'port_{}'.format(p.get('port', 0)),
                      'value': p.get('port', 0), 'unit': '',
                      'status': st, 'weight': DEFAULT_WEIGHTS['network'],
                      'confidence': 'HIGH',
                      'penalty': 10 if st == 'WARNING' else 0})

    ping_st = network.get('ping_status', 'UNKNOWN')
    items.append({'name': 'ping', 'value': ping_st, 'unit': '',
                  'status': ping_st if ping_st in ('OK', 'WARNING') else 'UNKNOWN',
                  'weight': DEFAULT_WEIGHTS['network'],
                  'confidence': 'HIGH' if ping_st != 'UNKNOWN' else 'LOW',
                  'penalty': 10 if ping_st == 'WARNING' else (5 if ping_st == 'UNKNOWN' else 0)})
    return items


def _evaluate_security(security):
    items = []
    for check in security.get('checks', []):
        st = check.get('status', 'UNKNOWN')
        penalty = 0
        if st == 'CRITICAL':
            penalty = 30
        elif st == 'WARNING':
            penalty = 10
        elif st == 'UNKNOWN':
            penalty = 5
        items.append({'name': check.get('name', ''), 'value': check.get('detail', ''),
                      'unit': '', 'status': st,
                      'weight': DEFAULT_WEIGHTS['security'],
                      'confidence': check.get('confidence', 'MEDIUM'),
                      'penalty': penalty})
    return items


def calculate_score(payload, config):
    """
    Health Score = 100 - sum(penalty * weight) / sum(max_weight) * 100
    실제 구현: 초기 100점에서 (penalty * weight_ratio) 차감 방식
    """
    all_items = []
    all_items.extend(_evaluate_resource(payload.get('resource', {}), config))
    all_items.extend(_evaluate_network(payload.get('network', {})))
    all_items.extend(_evaluate_security(payload.get('security', {})))

    # 가중치 기반 점수 계산
    total_weighted_penalty = 0
    total_max_penalty = 0
    for item in all_items:
        w = item.get('weight', 1)
        p = item.get('penalty', 0)
        total_weighted_penalty += p * w
        total_max_penalty += 30 * w  # 최대 페널티 기준: CRITICAL = 30

    if total_max_penalty > 0:
        score = max(0, int(100 - (total_weighted_penalty * 100.0 / total_max_penalty)))
    else:
        score = 100

    return {'score': score, 'items': all_items}


def classify_status(score_result):
    """
    최종 판정 우선순위:
    1. [Hard Rule] 단일 CRITICAL → CRITICAL
    2. [Score Rule] score < 50   → CRITICAL
    3. [Score Rule] score < 80   → WARNING
    4. 나머지                     → OK
    """
    items = score_result['items']
    score = score_result['score']

    has_critical = any(i.get('status') == 'CRITICAL' for i in items)
    warning_count = sum(1 for i in items if i.get('status') == 'WARNING')

    if has_critical:
        return 'CRITICAL', 2
    if score < 50:
        return 'CRITICAL', 2
    if score < 80 or warning_count >= 2:
        return 'WARNING', 1
    return 'OK', 0
