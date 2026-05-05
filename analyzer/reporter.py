#!/usr/bin/env python3
# ============================================================
# analyzer/reporter.py - JSON 리포트 저장 및 CLI 출력
# Python 3.4+ 하위호환 (.format() 사용)
# ============================================================
from __future__ import print_function
import os
import json
import datetime
import sys

# ANSI 색상 (터미널 지원 여부 자동 감지)
_USE_COLOR = sys.stdout.isatty()

COLORS = {
    'RED':    '\033[0;31m' if _USE_COLOR else '',
    'YELLOW': '\033[1;33m' if _USE_COLOR else '',
    'GREEN':  '\033[0;32m' if _USE_COLOR else '',
    'CYAN':   '\033[0;36m' if _USE_COLOR else '',
    'BOLD':   '\033[1m'    if _USE_COLOR else '',
    'DIM':    '\033[2m'    if _USE_COLOR else '',
    'NC':     '\033[0m'    if _USE_COLOR else '',
}

# 항목 이름 → 한글 레이블 매핑
_LABEL_MAP = {
    'cpu_usage':        'CPU 사용률',
    'memory_usage':     '메모리 사용률',
    'disk_usage':       '디스크 사용률',
    'inode_usage':      'Inode 사용률',
    'load_average':     'Load Average',
    'port_22':          'SSH (22)',
    'port_80':          'HTTP (80)',
    'port_443':         'HTTPS (443)',
    'port_3306':        'MySQL (3306)',
    'port_5432':        'PostgreSQL (5432)',
    'ping':             '외부 통신 (Ping)',
    'root_ssh_login':   'Root SSH 로그인',
    'password_max_days':'패스워드 만료 정책',
    'tmout':            '세션 타임아웃 (TMOUT)',
    'faillock':         '계정 잠금 정책 (faillock)',
    'suid_sgid':        'SUID/SGID 파일 검사',
}

# 항목별 조치 권고 (WARNING/CRITICAL/UNKNOWN 시 표시)
_ACTION_MAP = {
    'password_max_days': 'sudo chage -M 90 <username>  (모든 계정에 적용)',
    'tmout':             'echo "TMOUT=600" | sudo tee /etc/profile.d/timeout.sh',
    'faillock':          'sudo pam-auth-update  →  faillock 활성화',
    'suid_sgid':         'sudo find / -perm /6000 -type f 2>/dev/null  (루트로 재실행)',
    'port_443':          'HTTPS 서비스가 필요하면 Nginx/Apache 설정을 확인하세요',
    'cpu_usage':         'top -bn1 | head -20  (고부하 프로세스 확인)',
    'memory_usage':      'free -h && ps aux --sort=-%mem | head -10',
    'disk_usage':        'df -h && du -sh /* 2>/dev/null | sort -rh | head -10',
    'load_average':      'uptime && iostat -x 1 3  (I/O Wait 여부 확인)',
}

# 섹션 구분을 위한 항목 그룹
_RESOURCE_NAMES = {'cpu_usage', 'memory_usage', 'disk_usage', 'inode_usage', 'load_average'}
_NETWORK_NAMES  = {'ping'}  # port_* 는 동적으로 판별
_SECURITY_NAMES = {'root_ssh_login', 'password_max_days', 'tmout', 'faillock', 'suid_sgid'}


def _colorize(text, color):
    return '{}{}{}'.format(COLORS.get(color, ''), text, COLORS['NC'])


def _status_icon(status):
    return {'OK': '✅', 'WARNING': '⚠ ', 'CRITICAL': '🚨', 'UNKNOWN': '❓'}.get(status, '  ')


def _status_color(status):
    return {'OK': 'GREEN', 'WARNING': 'YELLOW', 'CRITICAL': 'RED', 'UNKNOWN': 'CYAN'}.get(status, 'NC')


def _label(name):
    return _LABEL_MAP.get(name, name)


def _is_port(name):
    return name.startswith('port_')


def _score_bar(score, width=20):
    """점수를 시각적 블록 바로 표현. 예: [████████████░░░░░░░░] 60"""
    filled = int(score / 100.0 * width)
    empty  = width - filled
    return '[{}{}]'.format('\u2588' * filled, '\u2591' * empty)


def _trend_icon(status):
    """추세 상태별 아이콘 반환."""
    return {
        'SPIKE':    '\U0001f53a',   # 🔺
        'TREND_UP': '\U0001f4c8',   # 📈
        'STABLE':   '\u27a1 ',      # ➡
        'N/A':      '\u2753 ',      # ❓
        'UNKNOWN':  '\u2753 ',
    }.get(status, '   ')


def _trend_color(status):
    return {
        'SPIKE':    'RED',
        'TREND_UP': 'YELLOW',
        'STABLE':   'GREEN',
    }.get(status, 'NC')


def write_report(report, history_dir):
    """
    Atomic Write: tmp 파일에 먼저 쓴 후 os.replace()로 교체.
    디스크 도중 뻗어도 report 파일이 깨지지 않도록 보장.
    """
    timestamp = report.get('timestamp', datetime.datetime.now().strftime('%Y%m%d_%H%M%S'))
    safe_ts = timestamp.replace(':', '').replace('-', '').replace('T', '_')
    filename = 'report_{}.json'.format(safe_ts)
    final_path = os.path.join(history_dir, filename)
    tmp_path = final_path + '.tmp'

    try:
        with open(tmp_path, 'w') as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
        os.replace(tmp_path, final_path)
    except OSError as e:
        sys.stderr.write('[REPORTER] 리포트 저장 실패 (디스크 Full?): {}\n'.format(e))
        try:
            os.remove(tmp_path)
        except OSError:
            pass


def _print_section(title, items, actions):
    """섹션 헤더와 항목 목록을 출력한다."""
    print('')
    print(_colorize('  [ {} ]'.format(title), 'BOLD'))
    print('  ' + '-' * 56)
    for item in items:
        name    = item.get('name', '')
        status  = item.get('status', 'UNKNOWN')
        value   = item.get('value', '')
        unit    = item.get('unit', '')
        conf    = item.get('confidence', '')
        icon    = _status_icon(status)
        color   = _status_color(status)

        label   = _label(name)
        val_str = '{}{}'.format(value, unit)

        # 값이 너무 길면 줄 바꿈 처리
        line = '  {} {:<20s}  {}'.format(
            icon,
            label,
            _colorize(val_str, color)
        )

        # 신뢰도 낮으면 메모 추가
        if conf == 'LOW':
            line += _colorize('  (※ 신뢰도 낮음)', 'DIM')

        print(line)

        # WARNING/CRITICAL/UNKNOWN 항목에 조치 권고 추가
        if status in ('WARNING', 'CRITICAL', 'UNKNOWN') and name in _ACTION_MAP:
            actions.append((label, _ACTION_MAP[name]))


def print_cli_report(report):
    """섹션 구분된 컬러 CLI 출력."""
    status   = report.get('final_status', 'UNKNOWN')
    score    = report.get('health_score', 0)
    hostname = report.get('hostname', 'unknown')
    role     = report.get('role', 'default')
    trend    = report.get('trend', {})
    items    = report.get('items', [])
    ts       = report.get('timestamp', '')
    exit_code = report.get('exit_code', 0)

    color = _status_color(status)

    # ── 헤더 ─────────────────────────────────────────────────
    print('')
    print(_colorize('=' * 60, 'BOLD'))
    print(_colorize('  System Health Check Report', 'BOLD'))
    print(_colorize('=' * 60, 'BOLD'))
    print('  호스트 : {}  ({})'.format(hostname, ts))
    print('  역할   : {}'.format(role))

    # 점수 바 시각화
    bar = _score_bar(score)
    print('  점수   : {}  {}  / 100'.format(
        _colorize('{:3d}'.format(score), color), _colorize(bar, color)))
    print('  상태   : {}'.format(_colorize('[{}]'.format(status), color)))

    # 추세: 전체 상태 + 지표별 세부 상태
    trend_status  = trend.get('status', 'N/A')
    trend_samples = trend.get('samples', 0)
    trend_metrics = trend.get('metrics', {})
    print('  추세   : {} {}  ─  {}'.format(
        _trend_icon(trend_status),
        _colorize(trend_status, _trend_color(trend_status)),
        trend.get('message', '-')))
    if trend_metrics:
        _METRIC_KR = {'cpu_usage': 'CPU', 'memory_usage': '메모리', 'disk_usage': '디스크'}
        parts = []
        for k, v in trend_metrics.items():
            lbl  = _METRIC_KR.get(k, k)
            icon = _trend_icon(v)
            clr  = _trend_color(v)
            parts.append('{} {}'.format(lbl, _colorize(v, clr)))
        print('           {} (이력 {}회 기반)'.format('  /  '.join(parts), trend_samples))

    if report.get('partial_mode'):
        print('  모드   : {}  (sudo 없이 실행 - 보안 일부 점검 제한)'.format(
            _colorize('⚠  PARTIAL MODE', 'YELLOW')))

    # ── 점수 산출 근거 요약 ───────────────────────────────────
    warn_cnt = sum(1 for i in items if i.get('status') == 'WARNING')
    crit_cnt = sum(1 for i in items if i.get('status') == 'CRITICAL')
    unk_cnt  = sum(1 for i in items if i.get('status') == 'UNKNOWN')
    print(_colorize('  ' + '-' * 58, 'DIM'))
    penalty_parts = []
    if crit_cnt: penalty_parts.append('CRITICAL {}개(각 -30점)'.format(crit_cnt))
    if warn_cnt: penalty_parts.append('WARNING {}개(각 -10점)'.format(warn_cnt))
    if unk_cnt:  penalty_parts.append('UNKNOWN {}개(각 -5점)'.format(unk_cnt))
    penalty_str = '  '.join(penalty_parts) if penalty_parts else '페널티 없음'
    print(_colorize('  {} → {}점'.format(penalty_str, score), 'DIM'))

    # ── 항목별 섹션 출력 ─────────────────────────────────────
    resource_items = [i for i in items if i['name'] in _RESOURCE_NAMES]
    network_items  = [i for i in items if _is_port(i['name']) or i['name'] in _NETWORK_NAMES]
    security_items = [i for i in items if i['name'] in _SECURITY_NAMES]

    action_list = []
    _print_section('RESOURCE  시스템 자원',  resource_items, action_list)
    _print_section('NETWORK   네트워크 상태', network_items,  action_list)
    _print_section('SECURITY  보안 설정',    security_items, action_list)

    # ── 최종 판정 ────────────────────────────────────────────
    print('')
    print(_colorize('=' * 60, 'BOLD'))
    exit_messages = {
        0: _colorize('  ✅  정상 (OK)       모든 지표 안정. 추가 조치 불필요.', 'GREEN'),
        1: _colorize('  ⚠   주의 (WARNING)  예방 점검이 필요한 항목이 있습니다.', 'YELLOW'),
        2: _colorize('  🚨  장애 (CRITICAL)  즉각 조치가 필요합니다!', 'RED'),
        3: _colorize('  💀  비상 (EMERGENCY) 복구 실패 - 수동 개입 필요!', 'RED'),
    }
    print(exit_messages.get(exit_code, '  상태 불명'))
    print(_colorize('=' * 60, 'BOLD'))

    # ── 조치 권고 ────────────────────────────────────────────
    if action_list:
        print('')
        print(_colorize('  [ 조치 권고 ]', 'BOLD'))
        print('  ' + '-' * 56)
        for idx, (lbl, cmd) in enumerate(action_list, 1):
            print('  {}. {}'.format(idx, _colorize(lbl, 'YELLOW')))
            print('     $ {}'.format(_colorize(cmd, 'CYAN')))
        print('')
