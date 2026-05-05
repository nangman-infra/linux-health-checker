# Linux System Health Checker

`./health-check.sh run` 한 줄로 서버 상태를 점검하는 Bash + Python 도구입니다.

CPU, 메모리, 디스크, 포트, 보안 설정 5개 영역을 순서대로 수집하고, 100점 기준 Health Score와 과거 5회 이력 기반 추세(SPIKE / TREND_UP / STABLE)를 같이 출력합니다.

---

## 왜 만들었나

`df -h`, `top`, `ss -tnlp` 를 각각 실행하면 수치는 볼 수 있지만 "이게 지금 위험한 건지 아닌지"는 바로 알기 어렵습니다.

이 도구는 수치만 보여주는 게 아니라 가중치 기반 점수로 상태를 판정하고, 과거 이력과 비교해서 갑자기 나빠진 건지 원래 이런 서버인지를 구분합니다.

---

## 어떻게 동작하는가

```
./health-check.sh run
          │
          ▼
[Bash] 데이터 수집 (modules/*.sh)
  - CPU, 메모리, 디스크, Load Average
  - 포트 상태, 외부 Ping
  - SSH 설정, 패스워드 정책, 세션 타임아웃 등
          │
          │  JSON으로 묶어서 stdin으로 전달
          ▼
[Python] 분석 (analyzer/)
  - 가중치 × 페널티로 100점에서 차감
  - 최근 5회 이력과 비교해 추세 계산
  - CLI 출력 및 JSON 리포트 저장 (reports/history/)
          │
          ▼
Exit Code (0 / 1 / 2 / 3)
```

**Bash와 Python을 나눈 이유:**

- Bash는 외부 패키지 없이 어느 Linux 서버에서나 `top`, `df`, `ss` 같은 명령을 바로 실행할 수 있습니다.
- Python은 소수점 계산, 표준편차, JSON 직렬화 같은 작업을 Bash보다 훨씬 깔끔하게 처리합니다.
- 두 언어를 stdin 파이프(`|`)로 연결해서 각자 잘하는 역할만 맡겼습니다.

---

## 프로젝트 구조

```
health-check/
├── health-check.sh          # 진입점. CLI 옵션 파싱 후 모듈 호출
│
├── modules/                 # Bash 수집 모듈 (3개)
│   ├── resource.sh          # CPU, 메모리, 디스크, Inode, Load Average
│   ├── network.sh           # 포트(22/80/443), Ping, 외부 API 응답코드
│   └── security.sh          # SSH 설정, 패스워드 정책, TMOUT, faillock, SUID 파일 수
│
├── lib/
│   ├── bootstrap.sh         # 권한 확인, 중복 실행 Lock, 종료 신호(trap) 처리
│   └── utils.sh             # 색상 로그 출력, JSON 이스케이프, 이력 파일 로테이션
│
├── analyzer/                # Python 분석 엔진 (4개)
│   ├── main.py              # stdin 수신 → 각 모듈 호출 → Exit Code 반환
│   ├── score.py             # 항목별 가중치 × 페널티 계산, 최종 상태 판정
│   ├── trend.py             # 이동평균(MA) + 표준편차(SD)로 추세 계산
│   └── reporter.py          # 컬러 CLI 출력, JSON 리포트 파일 저장
│
├── config/
│   └── default.conf         # 임계치, 포트 목록, 타임아웃 설정
│
├── reports/history/         # 실행할 때마다 저장되는 JSON 결과 (최근 5개 자동 유지)
└── logs/
    └── audit.log            # 모든 실행 기록과 --fix 복구 내역
```

---

## 설치 및 실행

**필수 환경**

| 항목 | 요구 사항 |
|------|----------|
| OS | Linux (Ubuntu 20.04+, Debian 11+, Rocky 8+, CentOS 7+) |
| Bash | 4.0 이상 |
| Python | 3.4 이상 (표준 라이브러리만 사용, 별도 설치 없음) |

**선택적 도구** (`nc`, `vmstat`, `curl`, `ping`): 없으면 Fallback 방식으로 동작하거나 해당 항목이 UNKNOWN 처리됩니다.

```bash
# 레포지토리 클론
git clone https://github.com/nangman-infra/linux-health-checker.git
cd linux-health-checker

# 실행 권한 부여 (최초 1회)
chmod +x health-check.sh
```

---

## 사용 방법

```bash
# 기본 점검
./health-check.sh run

# sudo 포함 실행 (SUID 파일 검사, faillock 등 보안 항목 완전 점검)
sudo ./health-check.sh run

# JSON 출력 (Grafana, 모니터링 시스템 연동용)
./health-check.sh run --json | jq '.health_score'

# DB 서버 기준으로 점검 (임계치가 달라짐)
./health-check.sh run --role db

# 6. 자동 복구 시뮬레이션 (실제 변경 없음)
sudo ./health-check.sh run --fix --dry-run
```

---

## 💡 운영 팁 및 FAQ

### 1. `sudo`로 실행하면 왜 느려지나요?
`sudo` 권한으로 실행 시 **전체 파일 시스템에 대한 SUID/SGID 보안 스캔**을 수행합니다. 이는 시스템 깊숙이 숨겨진 보안 취약점을 찾기 위해 모든 파일을 전수 조사하는 과정으로, 디스크 크기와 파일 수에 따라 **최대 30초~1분 정도 소요**될 수 있습니다. 멈춘 것이 아니니 잠시만 기다려 주세요.

### 2. 특정 포트(예: 443)가 계속 WARNING으로 뜹니다.
본 도구는 22(SSH), 80(HTTP), 443(HTTPS) 등 주요 포트가 열려 있는지 확인합니다. 만약 해당 서버에서 HTTPS를 사용하지 않는다면 이는 의도된 결과이므로 무시하셔도 됩니다. 특정 서비스에 맞게 점검 포트를 바꾸려면 `config/default.conf`의 `check_ports` 설정을 변경하세요.

### 3. 추세(Trend)가 `N/A`로 나옵니다.
추세 분석은 과거의 데이터와 비교하는 기능입니다. **최소 2회 이상** 실행되어 `reports/history/`에 이력 파일이 생성된 시점부터 분석 결과가 표시됩니다.

### 4. 실행 방식(Flag)에 따른 차이점은 무엇인가요?
- **일반 실행**: 현재 자원 상태와 기본적인 설정 점검 (가장 많이 사용)
- **sudo 실행**: 시스템 전체 파일 스캔 및 보안 설정 상세 점검 포함
- **--role [역할]**: 웹/DB 등 서버 성격에 맞는 임계치 적용
- **--json**: 사람이 아닌 '프로그램'이 읽을 수 있는 데이터로 출력 (모니터링 연동용)
- **--fix --dry-run**: "만약 고친다면 무엇이 바뀔지" 미리 보기 (안전한 점검)

---

## 출력 예시

```
============================================================
  System Health Check Report
============================================================
  호스트 : web-server-01  (2026-04-22T20:30:01)
  역할   : default
  점수   :  88  [████████████████░░░░]  / 100
  상태   : [WARNING]
  추세   : ➡ STABLE  ─  안정적인 추세 유지 중
           CPU STABLE  /  메모리 STABLE  /  디스크 STABLE (이력 5회 기반)
  ----------------------------------------------------------
  WARNING 2개(각 -10점) → 88점

  [ RESOURCE  시스템 자원 ]
  ----------------------------------------------------------
  ✅ CPU 사용률             2%
  ✅ 메모리 사용률          24%
  ✅ 디스크 사용률          12%
  ✅ Inode 사용률            4%
  ✅ Load Average          0.06

  [ NETWORK   네트워크 상태 ]
  ----------------------------------------------------------
  ✅ SSH (22)             열림
  ✅ HTTP (80)            열림
  ⚠  HTTPS (443)          닫힘
  ✅ 외부 통신 (Ping)      OK

  [ SECURITY  보안 설정 ]
  ----------------------------------------------------------
  ✅ Root SSH 로그인       비활성화 확인
  ⚠  패스워드 만료 정책    PASS_MAX_DAYS=99999 (권장: 90일 이하)
  ⚠  세션 타임아웃         미설정 (권장: 600초 이하)
  ✅ 계정 잠금 (faillock)  설정 확인됨

============================================================
  ⚠   주의 (WARNING)  예방 점검이 필요한 항목이 있습니다.
============================================================

  [ 조치 권고 ]
  ----------------------------------------------------------
  1. 패스워드 만료 정책
     $ sudo chage -M 90 <username>
  2. 세션 타임아웃 (TMOUT)
     $ echo "TMOUT=600" | sudo tee /etc/profile.d/timeout.sh
```

---

## Health Score 계산 방식

100점에서 시작해서 문제 항목마다 `(페널티 × 가중치)`를 차감합니다.

```
Health Score = 100 - Σ(penalty × weight) / Σ(max_penalty × weight) × 100
```

| 지표 | 가중치 | WARNING | CRITICAL |
|------|--------|---------|----------|
| 디스크 사용률 | 5 | -10점 | -30점 |
| 메모리 사용률 | 4 | -10점 | -30점 |
| 보안 설정 | 4 | -10점 | -30점 |
| CPU 사용률 | 3 | -10점 | -30점 |
| 네트워크 | 3 | -10점 | — |
| Load Average | 2 | -10점 | — |
| Inode 사용률 | 2 | — | -30점 |

**가중치는 "이 항목이 문제일 때 서비스에 얼마나 빠르게 영향을 주는가"를 기준으로 설계했습니다.**

- 디스크(5): 100% 차면 프로세스가 파일을 못 쓰고 즉시 죽습니다.
- 메모리(4): OOM-Killer가 아무 프로세스나 랜덤하게 종료합니다.
- CPU(3): 느려지지만 서비스가 즉시 멈추지는 않습니다.

**최종 상태 판정:**

```
CRITICAL 항목이 하나라도 있으면  → CRITICAL (Exit 2)
Score < 50                      → CRITICAL (Exit 2)
Score < 80 또는 WARNING 2개 이상 → WARNING  (Exit 1)
나머지                           → OK       (Exit 0)
```

---

## Trend 분석

매 실행 결과는 `reports/history/`에 JSON 파일로 저장됩니다. 이력이 2개 이상 쌓이면 CPU, 메모리, 디스크의 추세를 계산합니다.

- **SPIKE**: 이동평균(MA) 대비 20% 이상 급상승하거나, 2 표준편차(SD)를 초과한 경우
- **TREND_UP**: 최근 이력이 꾸준히 상승 중인 경우 (용량 문제 사전 감지)
- **STABLE**: 위 어느 것도 해당하지 않는 경우
- **N/A**: 이력 파일이 없는 경우 (최초 실행 시)

이력 파일은 최근 5개만 유지되고 나머지는 자동 삭제됩니다.

---

## Audit Log (감사 로그)

`logs/audit.log`에 모든 실행 기록이 남습니다.

```
[2026-04-22 20:30:01] run executed | role=default | fix=false | dry_run=false
[2026-04-22 20:31:15] [FIX] TMOUT 설정 완료 → /etc/profile.d/timeout.sh
[2026-04-22 20:31:16] [FIX] TMOUT 원본 백업 → /tmp/sshd_config.bak.1234
```

`--fix` 옵션으로 설정이 변경될 경우, 변경 전 원본 파일을 백업해두고 무슨 파일을 어떻게 바꿨는지 기록합니다. 비정상 종료 시에는 자동으로 백업 파일을 원복합니다.

---

## CI/CD 연동

이 도구는 Jenkins, GitHub Actions 등의 파이프라인에서 배포 전 점검 단계로 쓸 수 있습니다.

```bash
./health-check.sh run
EXIT_CODE=$?

# Exit Code 기준으로 파이프라인 제어
# 0 = OK     → 배포 계속
# 1 = WARNING → 알림 발송 후 계속
# 2 = CRITICAL → 배포 중단
# 3 = EMERGENCY → 즉각 수동 개입
```

```bash
# JSON 출력으로 특정 값만 추출
./health-check.sh run --json | jq '.health_score'
# → 88
```

---

## 검증: stress-ng로 직접 테스트

```bash
# stress-ng 설치 (Ubuntu/Debian)
sudo apt install -y stress-ng

# CPU 100% 부하 → CRITICAL + SPIKE 탐지 확인
stress-ng --cpu $(nproc) --timeout 60s &
sleep 3 && ./health-check.sh run

# I/O 부하 → CPU는 낮은데 Load Average만 올라가는 케이스
stress-ng --io 4 --hdd 1 --timeout 60s &
sleep 3 && ./health-check.sh run

# 중복 실행 방지 동작 확인
./health-check.sh run &
./health-check.sh run   # "이미 실행 중" 에러 후 종료되어야 함
```

---

## OS 호환성

| 기능 | Ubuntu 20.04+ | Debian 11+ | Rocky 8+ | Alpine |
|------|:---:|:---:|:---:|:---:|
| 리소스 수집 | ✅ | ✅ | ✅ | ⚠ |
| 포트 체크 | ✅ | ✅ | ✅ | ✅ |
| 메모리 (cgroup v1/v2) | ✅ | ✅ | ✅ | ✅ |
| faillock 점검 | ✅ | ✅ | ✅ | ❌ |
| Lock Fallback (/tmp) | ✅ | ✅ | ✅ | ✅ |

Alpine은 PAM 구조가 달라 faillock 항목이 UNKNOWN 처리됩니다. 스크립트 자체는 정상 동작합니다.

---

## 설계 결정 메모

**왜 `grep -oE`를 쓰는가 (`grep -P` 대신)**  
`grep -P` (Perl 정규식)는 Alpine, 최소 설치 RHEL에서 동작하지 않습니다. POSIX 표준인 `-oE`를 쓰면 모든 주요 배포판에서 동작합니다.

**왜 이력을 5개로 제한하는가**  
추세 계산에 필요한 최소 샘플 수(3개)와 통계적 신뢰도를 고려했을 때 5개로 충분합니다. 그 이상은 디스크만 차지합니다.

**왜 Python 외부 패키지를 쓰지 않는가**  
폐쇄망, 레거시 서버, 컨테이너 환경에서 `pip install` 없이 바로 실행 가능해야 합니다. `json`, `os`, `sys`, `datetime` 표준 라이브러리만 사용합니다.
