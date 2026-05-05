# Linux System Health Checker (LSHC)

Bash의 기동성과 Python의 분석력을 결합한 운영 서버용 지능형 상태 점검 도구입니다. 단순한 임계치 판단을 넘어, 통계적 추세 분석을 통해 잠재적 장애 요소를 사전에 탐지하고 운영 자동화(CI/CD)를 지원합니다.

---

## 🛠 Architecture & Pipeline

본 시스템은 **데이터 수집(Collector)**과 **지능형 분석(Analyzer)** 레이어가 분리된 하이브리드 아키텍처를 채택하고 있습니다.

1.  **Collector Layer (Bash)**: 외부 패키지 의존성 없이 표준 리눅스 명령어와 `procfs`를 직접 조회하여 로우 데이터를 수집합니다. (기동성 및 범용성 확보)
2.  **Analyzer Layer (Python)**: 수집된 JSON 페이로드를 통계 모델(이동평균, 표준편차)에 대입하여 점수화 및 추세 분석을 수행합니다. (정밀 분석 및 유지보수성 확보)
3.  **Communication**: 두 레이어는 표준 입력(stdin) 파이프라인을 통해 JSON 데이터를 교환하며, 최종 결과는 OS Exit Code를 통해 시스템에 전달됩니다.

---

## 🚀 Key Features (Detailed)

### 1. 지능형 추세 분석 (Trend Analysis)
단발적인 수치가 아닌 최근 5회 실행 이력을 통계적으로 분석합니다.
- **SPIKE 탐지**: 이동평균(MA) 대비 20% 이상 급상승하거나 2 표준편차(σ)를 초과하는 이상값(Outlier)을 감지합니다.
- **TREND_UP 탐지**: 지표가 지속적으로 상승하는 선형적 증가 추세를 감지하여 용량 고갈 리스크를 사전에 경고합니다.

### 2. 환경 적응형 리소스 수집
- **Container Awareness**: 컨테이너 환경(`cgroup v1/v2`)과 베어메탈 환경을 자동 감지하여 정확한 메모리 점유율을 계산합니다.
- **Load Calibration**: 단순 Load Average 값이 아닌 CPU 코어 수 대비 비율을 계산하여 서버 사양에 상관없는 객관적 지표를 산출합니다.

### 3. 감사 로그 및 추적성 (Audit Logging)
모든 시스템 점검 행위와 자동 복구(`--fix`) 시도는 감사 로그로 기록됩니다.
- **로그 위치**: `logs/audit.log`
- **기록 데이터**: `[Timestamp] [Action] | user=[User] | role=[Role] | status=[Success/Fail]`
- **운영적 가치**: 누가 언제 어떤 점검을 수행했는지, 자동 복구로 인해 어떤 설정이 변경되었는지에 대한 투명한 이력을 제공합니다.

---

## 📂 Project Structure

```
health-check/
├── health-check.sh          # 메인 진입점 (CLI 라우터)
├── modules/                 # [Bash] 수집 모듈 (Resource, Network, Security)
├── lib/                     # [Bash] 공통 라이브러리 (Bootstrap, Utils)
├── analyzer/                # [Python] 분석 엔진 (Score, Trend, Reporter)
├── config/                  # 설정 파일 (default.conf, services.txt)
├── reports/history/         # 실행 이력 JSON 데이터 (최근 5회)
└── logs/                    # 실행 및 변경 이력 감사 로그
```

---

## 🚦 CI/CD Integration (Exit Codes)

LSHC는 자동화된 파이프라인의 **Quality Gate** 역할을 수행할 수 있도록 표준 Exit Code를 반환합니다.

| Exit Code | Status | Pipeline Meaning |
| :--- | :--- | :--- |
| **0** | **OK** | 모든 지표 정상. 배포/작업 진행 가능. |
| **1** | **WARNING** | 잠재적 리스크 존재. 알림 발송 권장. |
| **2** | **CRITICAL** | **장애 상태. 파이프라인 중단 및 롤백 트리거.** |
| **3** | **EMERGENCY** | 시스템 치명적 오류 또는 자동 복구 실패. |

---

## 💻 Installation & Usage

### 1. Requirements
- **OS**: Linux (Ubuntu, Debian, Rocky, RHEL, CentOS 등)
- **Runtime**: Bash 4.0+, Python 3.4+ (표준 라이브러리만 사용)

### 2. Usage
```bash
chmod +x health-check.sh

# 기본 점검 실행
./health-check.sh run

# 특정 역할(DB) 기반 점검 및 자동 복구 시뮬레이션
sudo ./health-check.sh run --role db --fix --dry-run

# 외부 모니터링 시스템 연동용 JSON 출력
./health-check.sh run --json
```

---

## 🧪 장애 시뮬레이션 테스트 (Verification)

`stress-ng`를 사용하여 시스템 장애 상황에서의 탐지 능력을 검증할 수 있습니다.

```bash
# CPU 과부하 상황 (SPIKE 탐지 테스트)
stress-ng --cpu $(nproc) --timeout 60s &
sleep 3 && ./health-check.sh run

# I/O Wait 상황 (Load Average 누적 탐지 테스트)
stress-ng --io 4 --hdd 1 --timeout 60s &
sleep 3 && ./health-check.sh run
```
