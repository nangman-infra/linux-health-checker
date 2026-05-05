# System Health Checker

> **"Status is not a Boolean."**  
> 시스템 상태는 단순히 켜짐/꺼짐이 아닙니다.  
> 이 도구는 현재 상태뿐 아니라 **변화 추세**, **서버 역할**, **점수**까지 종합 판단합니다.

## 개요

운영 중인 Linux 서버를 단 하나의 명령어로 종합 점검합니다.

```bash
./health-check.sh run
```

**점검 범위:**
- **Resource**: CPU 사용률, 메모리 압박, 디스크/Inode 사용률, Load Average
- **Network**: 포트 가용성(22/80/443), 외부 통신 확인
- **Security**: Root SSH 로그인, 패스워드 만료 정책, 세션 타임아웃, 계정 잠금

**주요 기능:**
- 가중치 기반 Health Score 산출 (0~100점)
- 최근 5회 이력 기반 통계 Trend 분석 (SPIKE / TREND_UP / STABLE)
- 구조화된 JSON 출력 (CI/CD, 모니터링 시스템 연동)
- 감사(Audit) 로그 자동 기록

---

## 아키텍처: 왜 Bash + Python인가? (식당 비유)

이 시스템은 **Bash(몸통)**와 **Python(두뇌)**의 하이브리드 구조입니다.

1.  **주문 접수 및 재료 수집 (Bash: `modules/*.sh`)**: 웨이터가 주방을 돌아다니며 현재 재료 상태(`top`, `df`, `free` 등 리눅스 원시 명령어)를 바구니에 담습니다. 리눅스의 날것 그대로를 만지는 데는 Bash가 가장 빠르고 확실합니다.
2.  **주방장에게 전달 (`|` 파이프라인)**: 수집된 재료(JSON 데이터)를 파이썬이라는 스마트한 주방장에게 넘겨줍니다.
3.  **요리 및 분석 (Python: `analyzer/*.py`)**: 주방장은 복잡한 레시피(통계 수식, 가중치 계산, 과거 이력 비교)를 사용해 "현재 시스템의 맛(Score)"을 판정합니다.

| 역할 | 언어 | 이유 |
|------|------|------|
| 시스템 명령어 실행 | **Bash** | 외부 패키지 없이 어느 Linux에서나 즉시 실행 가능 |
| 점수 계산 / Trend 분석 | **Python** | 복잡한 수식과 통계 처리, 유지보수성 확보 |
| Exit Code 반환 | **Bash** | Python 결과를 OS로 전달하는 게이트웨이 역할 |

---

## Design Philosophy (설계 철학)

본 도구는 단순한 수치 측정이 아닌, **계층적 가용성 모델**을 기반으로 판단합니다.

1.  **가장 약한 고리의 법칙 (The Weakest Link)**: 인프라의 가용성은 가장 취약한 지표에 의해 결정됩니다. 디스크 100% 같은 치명적 상태는 단독으로 시스템 전체 상태를 결정합니다.
2.  **누적적 취약성 (Weighted Resonance)**: 당장 장애는 아닐지라도 여러 경고(WARNING)가 누적되면 시스템은 취약(Fragile)해집니다. 가중치 기반 점수는 이 "잠재적 리스크"를 수치화합니다.
3.  **해법 중심 (Solution-Oriented)**: 상태 진단과 동시에 즉시 실행 가능한 조치 권고(Action Guide)를 제공하여 리스크를 실질적으로 감소시키는 것을 목적으로 합니다.

---

## 스코어링의 객관적 근거 (Rationale)

본 시스템의 임계치와 가중치는 글로벌 기술 표준과 보안 가이드를 기반으로 합니다.

### 1. 보안 항목: KISA 가이드 기반
- **근거**: [KISA 기술적 점검 가이드](https://www.kisa.or.kr)
- **내용**: 패스워드 만료 정책, Root 원격 로그인 차단 등은 국가 주요정보통신기반시설의 보안 점검 항목을 준수합니다.

### 2. 가중치 설계: SRE Golden Signals
- **근거**: Google SRE Book (Saturation 지표)
- **설계**: '서비스 즉시 중단 여부'를 기준으로 가중치를 배정했습니다.
    - **Disk (5)**: 즉각적인 시스템 패닉 및 데이터 유실 유발
    - **Memory (4)**: OOM-Killer에 의한 예측 불가능한 프로세스 중단
    - **CPU (3)**: 성능 저하는 발생하나 서비스는 유지됨

### 3. 부하 분석: 리눅스 성능 분석 모델
- **근거**: [Brendan Gregg's Performance Tuning](https://www.brendangregg.com)
- **내용**: Load Average를 단순히 숫자만 보는 것이 아니라 `core_count` 대비 비율로 계산하여 객관성을 확보했습니다.

---

## 프로젝트 구조

```
health-check/
├── health-check.sh          # 진입점 (CLI 라우터)
│
├── modules/                 # [Bash] 수집 레이어
│   ├── resource.sh          # CPU, 메모리, 디스크, Inode, Load Average
│   ├── network.sh           # 포트 체크, 외부 Ping, API Endpoint
│   └── security.sh          # KISA 기반 보안 항목 점검
│
├── lib/                     # [Bash] 공통 유틸리티
│   ├── bootstrap.sh         # 권한 체크, Lock, trap 신호 처리
│   └── utils.sh             # 색상 로그, JSON 이스케이프, 이력 로테이션
│
├── analyzer/                # [Python] 분석 레이어
│   ├── main.py              # Python 진입점
│   ├── score.py             # 가중치 기반 Health Score 계산
│   ├── trend.py             # 통계 기반 추세 분석
│   └── reporter.py          # CLI 출력 및 JSON 리포트 저장
│
├── config/
│   ├── default.conf         # 임계치, 타임아웃, 포트 목록 설정
│   └── services.txt         # 외부 API Endpoint 목록
│
├── reports/
│   └── history/             # 실행 이력 JSON (최근 5개 자동 유지)
│
└── logs/
    └── audit.log            # 실행 및 자동 복구 감사 로그
```

---

## 설치 및 실행

### 필수 환경

| 항목 | 요구 사항 |
|------|----------|
| OS | Linux (Ubuntu 20.04+, Debian, Rocky 8+, CentOS 7+) |
| Bash | 4.0 이상 |
| Python | 3.4 이상 (외부 패키지 없음 — 표준 라이브러리만 사용) |
| 필수 도구 | `df`, `free`, `ping`, `/proc/*` |
| 선택 도구 | `nc` (없으면 `/dev/tcp` 자동 Fallback), `vmstat`, `curl` |

### 실행

```bash
# 1. 실행 권한 부여 (최초 1회)
chmod +x health-check.sh

# 2. 기본 점검
./health-check.sh run

# 3. 전체 보안 항목 포함 (SUID/SGID, faillock 등)
sudo ./health-check.sh run

# 4. JSON 출력 (CI/CD 파이프라인, 모니터링 시스템 연동)
./health-check.sh run --json | python3 -m json.tool

# 5. DB 서버 역할 지정 (역할별 임계치 적용)
./health-check.sh run --role db

# 6. 자동 복구 시뮬레이션 (실제 변경 없음)
sudo ./health-check.sh run --fix --dry-run
```

---

## 출력 예시

```
============================================================
  System Health Check Report
============================================================
  호스트 : web-server-01  (2026-04-22T20:30:01)
  역할   : default
  점수   : 88  / 100
  상태   : [WARNING]
  추세   : STABLE (안정적인 추세 유지 중)
  점수 = 100 ─ CRITICAL×0(×30점) WARNING×4(×10점) UNKNOWN×1(×5점) → 88점

  [ RESOURCE  시스템 자원 ]
  --------------------------------------------------------
  ✅ CPU 사용률               2%
  ✅ 메모리 사용률            24%
  ✅ 디스크 사용률            12%
  ✅ Inode 사용률              4%
  ✅ Load Average           0.06

  [ NETWORK   네트워크 상태 ]
  --------------------------------------------------------
  ✅ SSH (22)                열림
  ✅ HTTP (80)               열림
  ⚠  HTTPS (443)             닫힘
  ✅ 외부 통신 (Ping)         OK

  [ SECURITY  보안 설정 ]
  --------------------------------------------------------
  ✅ Root SSH 로그인          비활성화 확인
  ⚠  패스워드 만료 정책       PASS_MAX_DAYS=99999 (권장: 90일 이하)
  ⚠  세션 타임아웃 (TMOUT)    미설정 (권장: 600초 이하)
  ⚠  계정 잠금 (faillock)     미설정 (계정 잠금 미작동)
  ❓ SUID/SGID 파일 검사      Root 권한 필요  (※ 신뢰도 낮음)

============================================================
  ⚠   주의 (WARNING)  예방 점검이 필요한 항목이 있습니다.
============================================================

  [ 조치 권고 ]
  --------------------------------------------------------
  1. 패스워드 만료 정책
     $ sudo chage -M 90 <username>  (모든 계정에 적용)
  2. 세션 타임아웃 (TMOUT)
     $ echo "TMOUT=600" | sudo tee /etc/profile.d/timeout.sh
  3. 계정 잠금 정책 (faillock)
     $ sudo pam-auth-update  →  faillock 활성화
```

---

## Health Score 계산 방식

초기 100점에서 문제 항목마다 **가중치 × 페널티**를 차감합니다.

```
Health Score = 100 - Σ(penalty × weight) / Σ(max_penalty × weight) × 100
```

| 지표 | 가중치(weight) | WARNING 페널티 | CRITICAL 페널티 |
|------|--------------|--------------|---------------|
| 디스크 사용률 | 5 | -10점 | -30점 |
| 메모리 사용률 | 4 | -10점 | -30점 |
| 보안 설정 | 4 | -10점 | -30점 |
| CPU 사용률 | 3 | -10점 | -30점 |
| 네트워크 포트 | 3 | -10점 | -30점 |
| Load Average | 2 | -10점 | — |
| Inode 사용률 | 2 | — | -30점 |

**최종 상태 판정 우선순위:**
1. `CRITICAL` 항목이 하나라도 있으면 → **CRITICAL**
2. Score < 50 → **CRITICAL**
3. Score < 80 또는 WARNING 2개 이상 → **WARNING**
4. 나머지 → **OK**

---

## Exit Code (CI/CD 연동)

```bash
./health-check.sh run
echo "Exit Code: $?"  # → 0, 1, 2, 3
```

| Code | 상태 | 의미 |
|------|------|------|
| 0 | OK | 모든 지표 정상 |
| 1 | WARNING | 예방 점검 권장 |
| 2 | CRITICAL | 즉각 조치 필요 |
| 3 | EMERGENCY | 자동 복구 실패, 수동 개입 |

---

## 검증: 장애 시뮬레이션 (stress-ng)

```bash
# 1. 설치 (Ubuntu/Debian)
sudo apt install -y stress-ng

# 2. [시나리오 A] CPU 과부하
stress-ng --cpu $(nproc) --timeout 60s &
sleep 3 && ./health-check.sh run

# 3. [시나리오 B] 메모리 압박
stress-ng --vm 1 --vm-bytes 1G --timeout 60s &
sleep 3 && ./health-check.sh run

# 4. [시나리오 C] I/O Wait (CPU는 낮은데 Load Average만 치솟는 현대적 장애)
stress-ng --io 4 --hdd 1 --timeout 60s &
sleep 3 && ./health-check.sh run

# 5. 중복 실행 방지 테스트
./health-check.sh run &
./health-check.sh run   # → "이미 실행 중" 에러 후 종료하는지 확인
```

---

## OS 호환성

| 기능 | Ubuntu 20.04+ | Debian 11+ | Rocky 8+ / CentOS 7+ | Alpine |
|------|:---:|:---:|:---:|:---:|
| 리소스 수집 | ✅ | ✅ | ✅ | ⚠ |
| 포트 체크 (nc → /dev/tcp) | ✅ | ✅ | ✅ | ✅ |
| 메모리 (cgroup v1/v2) | ✅ | ✅ | ✅ | ✅ |
| faillock 점검 | ✅ | ✅ | ✅ | ❌ |
| Lock Fallback (/tmp) | ✅ | ✅ | ✅ | ✅ |

> Alpine은 PAM 구조가 달라 faillock 항목이 UNKNOWN으로 처리되지만, 스크립트가 중단되지는 않습니다.

---

## 설계 결정 (Design Decisions)

### 1. 왜 `grep -oE`를 사용하는가? (`grep -P` 대신)
`grep -P` (Perl 정규식)는 Alpine Linux나 최소 설치 RHEL 환경에서 동작하지 않습니다.
POSIX 표준인 `grep -oE`를 사용하면 모든 주요 Linux 배포판에서 동작합니다.

### 2. 왜 이력을 5개로 제한하는가?
Trend 분석에 필요한 통계적 의미는 5개 샘플로 충분합니다.
그 이상은 디스크 점유만 늘리고 분석 정확도는 크게 향상되지 않습니다.

### 3. 왜 Python 외부 패키지를 쓰지 않는가?
폐쇄망, 레거시 서버, 컨테이너 환경에서도 추가 설치 없이 바로 실행 가능해야 합니다.
`python3`만 있으면 작동하도록 표준 라이브러리(`json`, `os`, `sys`, `datetime`, `statistics`)만 사용합니다.
