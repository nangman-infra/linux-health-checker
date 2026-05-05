# Linux System Health Checker (LSHC)

Bash의 기동성과 Python의 분석력을 결합한 운영 서버용 지능형 상태 점검 도구입니다. 단순한 임계치 판단을 넘어, 통계적 추세 분석을 통해 잠재적 장애 요소를 사전에 탐지합니다.

## 🚀 Key Features

### 1. Hybrid Multi-Layer Detection (Bash)
- **Zero-Dependency**: 외부 패키지 설치 없이 표준 리눅스 명령어(`top`, `df`, `ss`, `procfs`)만으로 로우 데이터를 수집합니다.
- **Modular Architecture**: 자원(Resource), 네트워크(Network), 보안(Security) 수집 로직이 분리되어 있어 확장이 용이합니다.
- **Container Awareness**: cgroup v1/v2를 직접 조회하여 컨테이너 환경 내에서도 정확한 메모리 점유율을 계산합니다.

### 2. Intelligent Data Analysis (Python)
- **Statistical Trend Analysis**: 최근 5회 실행 이력을 기반으로 이동평균(MA) 및 표준편차(SD)를 계산하여 `SPIKE`(급변) 및 `TREND_UP`(지속 상승) 패턴을 탐지합니다.
- **Weighted Health Scoring**: 각 지표의 중요도(Weight)에 따른 페널티 차감 방식을 사용하여 시스템의 종합적인 건전성을 0-100 점수로 산출합니다.
- **Actionable Reports**: 장애 탐지 시 즉시 조치 가능한 명령어를 제안하여 운영자의 MTTR(Mean Time To Repair)을 단축시킵니다.

### 3. Comprehensive Audit Logging
모든 실행 이력과 시스템 변경 시도는 감사 로그(Audit Log)로 기록되어 추적성을 보장합니다.
- **위치**: `logs/audit.log`
- **기록 내용**: 실행 시각, 실행 유저, 적용된 서버 역할(`--role`), 자동 복구(`--fix`) 실행 여부 및 결과.
- **활용**: 인프라 변경 이력 관리 및 장애 발생 시의 사후 분석(Post-mortem) 자료로 활용됩니다.

---

## 🛠 Architecture & Pipeline

LSHC는 **수집(Collection) -> 분석(Analysis) -> 대응(Response)**의 3단계 파이프라인으로 동작합니다.

1.  **Collection (Bash Shell)**: 
    - `modules/*.sh` 모듈들이 병렬적으로 데이터를 수집합니다.
    - 수집된 데이터는 JSON Payload로 조립되어 Python 엔진의 표준 입력(stdin)으로 전달됩니다.
2.  **Analysis (Python 3)**:
    - 수집된 원시 데이터를 가중치 모델과 통계 모델에 대입합니다.
    - `reports/history/` 디렉토리의 과거 데이터를 참조하여 현재 상태의 이상 여부를 판별합니다.
3.  **Response (CLI/JSON)**:
    - 표준 출력(stdout)을 통해 컬러화된 리포트를 출력합니다.
    - 자동화 도구 연동을 위해 표준화된 JSON 리포트를 생성하며, 상태에 따른 Exit Code를 반환합니다.

---

## 🚦 CI/CD Integration (Exit Codes)

이 도구는 자동화된 파이프라인 내에서 의사결정 도구로 활용할 수 있도록 표준 Exit Code를 엄격히 준수합니다.

| Code | Status | Pipeline Action |
| :--- | :--- | :--- |
| **0** | **OK** | 배포 계속 진행 (Normal) |
| **1** | **WARNING** | 알림 발송 후 진행 (Potential Risk) |
| **2** | **CRITICAL** | **배포 중단 및 롤백 트리거 (Failure)** |
| **3** | **EMERGENCY** | 즉각적인 수동 개입 필요 (Action Failed) |

---

## 💻 Quick Start

```bash
# 레포지토리 클론 및 실행 권한 부여
git clone https://github.com/nangman-infra/linux-health-checker.git
cd linux-health-checker
chmod +x health-check.sh

# 기본 점검 실행
./health-check.sh run

# JSON 리포트 출력 (모니터링 시스템 연동 시)
./health-check.sh run --json
```
