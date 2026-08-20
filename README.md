# Codyssey Mission 1-2 — 시스템 장애 분석 및 이슈 리포트

`agent-leak-app`을 운영 환경(Ubuntu 22.04 컨테이너)에서 실행하며 발생하는 세 가지 시스템 장애를
관제 데이터와 로그로 재현·계측하고, GitHub Issue 형태의 기술 리포트로 정리한 결과물이다.

세 장애 모두 **실제로 실행해 얻은 로그와 명령어 출력**을 근거로 한다.
리포트에 인용된 모든 수치와 로그 줄은 [`evidence/`](evidence) 아래 원본 파일에서 그대로 가져온 것이다.

---

## 1. 리포트 (최종 결과물)

| Issue | 장애 유형 | 리포트 | 조정한 환경변수 | Before → After |
| --- | --- | --- | --- | --- |
| [**#1**](https://github.com/whitecy01/codyssey1-2/issues/1) | OOM Crash | [01-oom.md](reports/01-oom.md) | `MEMORY_LIMIT` | 50MB → 512MB · 생존 **6초 → 300초+** |
| [**#2**](https://github.com/whitecy01/codyssey1-2/issues/2) | CPU Latency | [02-cpu.md](reports/02-cpu.md) | `CPU_MAX_OCCUPY` | 100 → 30 · 생존 **35초 → 120초+** |
| [**#3**](https://github.com/whitecy01/codyssey1-2/issues/3) | Deadlock | [03-deadlock.md](reports/03-deadlock.md) | `MULTI_THREAD_ENABLE` | true → false · 로그 정체 **108초 → 0초** |

각 리포트는 저장소에 **GitHub Issue로도 등록**되어 있다([#1](https://github.com/whitecy01/codyssey1-2/issues/1) · [#2](https://github.com/whitecy01/codyssey1-2/issues/2) · [#3](https://github.com/whitecy01/codyssey1-2/issues/3)).
Issue 본문은 `reports/` 의 마크다운과 같은 내용이며, 증거로 가는 링크만 절대 URL로 바뀌어 있다.

### 조사에서 나온 핵심 발견 3가지

1. **`MEMORY_LIMIT`은 누수를 막는 값이 아니라 "언제 죽을지"를 정하는 값이다.**
   힙이 8.3MB/s로 일정하게 증가하므로 사망 시각이 `MEMORY_LIMIT / 8.3` 으로 계산된다.
   다만 512MB(권장치 초과)에서는 종료 대신 **회수 경로(`Memory Cache Flushed`)가 열려**
   RSS가 16MB↔516MB 톱니로 순환하며 살아남는다. → [01-oom.md §3-3](reports/01-oom.md)

2. **CPU 장애는 `top`/`ps`로도, 시스템 전체 지표로도 관측되지 않는다.**
   앱이 `Current Load: 52.48%` 를 보고하고 Watchdog이 종료를 결정하는 그 순간,
   OS가 측정한 이 프로세스의 누적 CPU 시간은 **22초 동안 0.17초(≈0.8%)**,
   **시스템 전체 CPU도 최대 1.2%**(8코어), 부하 평균은 오히려 하락 중이었다.
   Watchdog은 앱 내부 지표를 보고 판단하므로, CPU 기반 관제로는 이 장애를 영원히 못 잡는다.
   → [02-cpu.md §3-2](reports/02-cpu.md)

3. **교착상태는 모든 표준 헬스체크를 통과한다.**
   PID 생존 ✅ · 포트 15034 LISTEN ✅ · CPU/메모리 임계 정상 ✅ — 그런데 108초간 아무 일도 하지 않았다.
   관제 범위를 시스템 전체로 넓혀도 소용없다. 교착은 자원을 **안 쓰는** 장애라
   `SYS_LOAD`가 0.25 → 0.06으로 내려가 오히려 "안정화 중"으로 읽힌다.
   잡아낸 유일한 신호는 **"수치가 변하지 않는다"** 와 **"로그가 늘지 않는다"** 였다.
   → [03-deadlock.md §3-4](reports/03-deadlock.md)

조사 과정에서 **재현 대상인 장애와 별개로 앱 자체의 설계 모순**도 관측되었다.
별도 문서로 정리했다 → [**DESIGN-ISSUES.md**](DESIGN-ISSUES.md)

세 장애의 종료 방식이 서로 다르다는 점도 진단의 핵심 단서였다.

| 장애 | 종료 코드 | 시그널 | 의미 |
| --- | --- | --- | --- |
| OOM | 137 | SIGKILL (9) | 가로챌 수 없는 즉시 회수. 정리 코드도, stdout 버퍼도 남지 않는다 |
| CPU | 143 | SIGTERM (15) | 정리 기회를 주는 계획된 종료 = 오류가 아닌 보호 조치 |
| Deadlock | — | 없음 | **종료되지 않는다.** 이것이 가장 위험한 형태다 |

---

## 2. 디렉터리 구조

```
codyssey1-2/
├── DESIGN-ISSUES.md        앱 자체의 설계 모순 분석 (재현 대상 장애와 별개)
├── Dockerfile              Ubuntu 22.04 + 관측 도구(procps/psmisc/iproute2/bc)
├── run.sh                  이미지 빌드 + 컨테이너 기동 (+ --all 로 전체 시나리오 실행)
├── scripts/
│   ├── setup.sh            부트 조건 구성 (계정·디렉터리·secret.key·환경변수)
│   ├── monitor.sh          관제 — 프로세스 지표 + 시스템 전체 지표를 2초 간격 기록
│   └── run-case.sh         시나리오 1건 실행 + 증거 수집 (앱 로그·관제·ps/top 스냅샷)
├── reports/                제출물 — 장애 분석 리포트 3건
│   ├── 01-oom.md
│   ├── 02-cpu.md
│   └── 03-deadlock.md
├── evidence/               실행으로 수집한 원본 증거 (7개 시나리오)
│   └── <case>/
│       ├── app-stdout.log    터미널 출력 (부트 시퀀스 + 종료 배너 + 종료 코드)
│       ├── agent_app.log     앱이 직접 남긴 로그 파일
│       ├── monitor.log       관제 로그
│       ├── snapshots.txt     ps / ps -L / top -H / ss 스냅샷
│       └── summary.txt       생존 시간·종료 사유·로그 정체 시간 요약
└── agent-app-leak/         제공된 바이너리 (.gitignore 대상, 저장소에 포함되지 않음)
```

> `problem.md`(과제 원문)와 `agent-app-leak/`(제공 바이너리)는 `.gitignore`로 제외했다.
> 클론 직후에는 바이너리가 없으므로, `agent-app-leak/` 에 `agent-leak-app-arm64` 와
> `agent-leak-app-x86` 두 개를 넣어야 실행할 수 있다(`run.sh`가 존재 여부를 먼저 검사한다).

---

## 3. 실행 방법

```bash
# 이미지 빌드 + 컨테이너 기동
./run.sh

# 전체 시나리오(7건) 실행 후 evidence/ 로 증거 회수 — 약 20분 소요
./run.sh --all
```

개별 시나리오만 돌리려면:

```bash
docker exec agent-leak /opt/scripts/run-case.sh oom-before
docker exec agent-leak /opt/scripts/run-case.sh cpu-before
docker exec agent-leak /opt/scripts/run-case.sh deadlock-before
docker cp agent-leak:/evidence ./evidence
```

호스트 아키텍처(`uname -m`)에 맞춰 `linux/arm64` 또는 `linux/amd64`로 빌드하고,
컨테이너 안에서 `setup.sh`가 다시 `uname -m`으로 바이너리를 고르므로 Apple Silicon과
Intel 양쪽에서 에뮬레이션 없이 동작한다.

---

## 4. 부트 조건 구성

`agent-leak-app`은 아래 조건이 모두 충족되어야 기동한다. `scripts/setup.sh`가 이를 구성한다.

| 항목 | 요구 조건 | 구성 내용 |
| --- | --- | --- |
| 실행 계정 | root가 아닌 일반 사용자 | `agent-admin` (uid=1000) 생성 후 `su`로 실행 |
| `AGENT_HOME` | 필수 환경변수 | `/home/agent-admin/agent-app` |
| `AGENT_PORT` | 15034 고정 | `15034` |
| `AGENT_UPLOAD_DIR` | 디렉터리 존재 | `$AGENT_HOME/upload_files` |
| `AGENT_KEY_PATH` | 경로 존재 | `$AGENT_HOME/api_keys` (0700) |
| `AGENT_LOG_DIR` | 존재 + 쓰기 권한 | `/var/log/agent-app` (소유자 `agent-admin`) |
| `MEMORY_LIMIT` | 정수 50~512 | 시나리오별 지정 |
| `CPU_MAX_OCCUPY` | 정수 10~100 | 시나리오별 지정 |
| `MULTI_THREAD_ENABLE` | true/false | 시나리오별 지정 |
| `secret.key` | 내용 `agent_api_key_test` | `$AGENT_HOME/api_keys/secret.key` (0600) |
| 네트워크 | `0.0.0.0:15034` 바인딩 | `docker run -p 15034:15034`, `ss -tulnp`로 LISTEN 확인 |

기동에 성공하면 `[1/6]`~`[6/6]` 점검을 거쳐 `All Boot Checks Passed! / Agent READY` 가 출력된다.

---

## 5. 실험 설계

이 앱은 **권장 범위를 벗어난 환경변수를 하나 골라 그에 맞는 워크로드를 실행**한다.
실측으로 확인한 선택 규칙은 다음과 같다.

| 조건 | 실행되는 워커 | 결과 |
| --- | --- | --- |
| `MEMORY_LIMIT <= 256` | `MemoryWorker` 단독 | 힙 누수 → MemoryGuard SIGKILL |
| `CPU_MAX_OCCUPY > 50` | `CpuWorker` 단독 | 부하 상승 → Watchdog SIGTERM |
| `MULTI_THREAD_ENABLE=true` | `AgentWorker` (Worker-Thread-1/2) | 락 교차 점유 → 교착상태 |
| 셋 다 권장 범위 | `MemoryWorker` + `CpuWorker` | 정상 워크로드 (회수 사이클 동작) |

따라서 **한 장애만 격리해서 재현하려면 나머지 두 변수를 반드시 권장 범위에 고정**해야 한다.
이 원칙에 따라 시나리오 매트릭스를 짰다(`scripts/run-case.sh`).

| 시나리오 | `MEMORY_LIMIT` | `CPU_MAX_OCCUPY` | `MULTI_THREAD_ENABLE` | 결과 |
| --- | --- | --- | --- | --- |
| `oom-before` | **50** | 30 | false | 6초 후 SIGKILL |
| `oom-mid` | **256** | 30 | false | 33초 후 SIGKILL (경계값 검증) |
| `oom-after` | **512** | 30 | false | 300초 생존, 회수 4회 |
| `cpu-before` | 512 | **100** | false | 35초 후 SIGTERM |
| `cpu-after` | 512 | **30** | false | 120초 생존, 임계 위반 0회 |
| `deadlock-before` | 512 | 30 | **true** | 무응답 108초, 프로세스 생존 |
| `deadlock-after` | 512 | 30 | **false** | 정상 진행, 정체 0초 |

`oom-mid`(256MB)는 부트 배너의 `Recommend Over 256MB` 가 **"256 이상"이 아니라 "256 초과"**임을
확인하기 위한 경계값 검증이다. 256MB에서도 `WARNING` 판정이 유지되고 여전히 종료된다.

---

## 6. 관제 범위 — 프로세스인가 시스템 전체인가

과제는 두 방향을 **동시에** 요구한다.

| 근거 | 요구하는 범위 |
| --- | --- |
| "monitor.sh를 활용하여, **대상 프로세스**의 물리 메모리 사용량을 관측" (요구사항 2장) | 프로세스 |
| "**시스템 전체 부하가 아닌** 특정 프로세스의 CPU 사용률이 급격히 상승하는 구간을 식별" (요구사항 3장) | 프로세스 |
| "메모리 누수가 **시스템 전체에 미치는 영향**을 설명할 수 있다" (미션 목표) | 시스템 |
| "CPU 과점유가 **시스템 지연**을 유발하는 원리를 설명할 수 있다" (미션 목표) | 시스템 |

과제의 예시 로그 자체가 이미 섞여 있다 —
`PROCESS:agent-leak-app CPU:1.2% MEM:5.1%` 는 프로세스,
`DISK:954G FIREWALL:active` 는 시스템 전체다.

그래서 `monitor.sh`는 **원인 규명의 주(主) 지표는 프로세스, 영향 판단의 보조 지표는 시스템**으로
잡고 한 줄에 `|` 로 구분해 나란히 남긴다. 시스템 쪽에는 `SYS_` 접두어를 붙여
어느 쪽 수치인지 헷갈리지 않게 했다.

```text
[ts] PROCESS:agent-leak-app PID:571 STATE:S CPU:1.5% MEM:26.0% RSS:266MB THREADS:1 | SYS_CPU:12.3% SYS_MEM:31.2% SYS_AVAIL:704MB SYS_LOAD:0.42 DISK:4%
     └──────────────── 대상 프로세스 ─────────────────────────────────────────────┘   └──────────────────── 시스템 전체 ────────────────────────────┘
```

이 구조라야 두 종류의 문장을 **같은 한 줄에서** 근거로 댈 수 있다.

- 원인 규명: "이 프로세스의 RSS가 8.7MB/s로 오른다" ← 좌측
- 영향 판단: "그동안 가용 메모리가 얼마나 줄었다" ← 우측
- 그리고 CPU 리포트의 핵심 논지인 "앱은 Load 50%를 말하는데 프로세스도 시스템도 조용하다"는
  **좌우를 나란히 놓아야만** 성립한다.

로그 첫 세 줄에 `SCOPE`(코어 수·메모리 분모)와 `LEGEND`(좌우 구분)를 남겨,
증거 파일만 따로 봐도 각 숫자의 범위를 알 수 있게 했다.

---

## 7. 관측 방법에서 다루어야 했던 문제

증거 수집 자체에 몇 가지 함정이 있었고, 해결 방식을 스크립트 주석에도 남겨 두었다.

1. **종료 배너 유실** — 앱은 `>>> [SYSTEM] SELF-TERMINATED ... <<<` 를 출력한 직후 SIGKILL 된다.
   stdout을 파이프로 받으면 블록 버퍼링에 걸려 이 마지막 줄이 통째로 사라진다
   (`PYTHONUNBUFFERED=1` 로도 해결되지 않았다).
   `script -qfec` 로 **의사 터미널(pty)을 붙여** 줄 단위로 흘려보내 확보했다.
   덤으로 `COMMAND_EXIT_CODE`까지 기록되어 SIGKILL(137)/SIGTERM(143) 구분이 가능해졌다.

2. **PID를 잘못 무는 문제** — 이 앱은 부모(런처) + 자식(실제 워크로드) 두 프로세스로 뜬다.
   `pgrep -f` 는 명령줄 전체를 훑어 `su`/`script` 래퍼까지 잡고, `pgrep -x` 만으로도
   런처(RSS 1.4MB)를 물기 쉽다. **두 프로세스가 다 뜰 때까지 기다린 뒤 VmRSS가 큰 쪽**을
   대상으로 고르고, 그 PID를 관제에 명시적으로 넘기도록 했다.

3. **`ps %CPU`의 함정** — `ps`의 `%CPU`는 프로세스 생애 전체 평균이라 "급상승 구간"이 희석된다.
   `monitor.sh`는 `/proc/<pid>/stat`의 `utime + stime`을 2초 간격으로 **차분**해 구간 사용률을 계산한다.

4. **컨테이너에서의 MEM% 분모** — 컨테이너 안에서도 `/proc/meminfo`는 호스트 전체 메모리를
   보여준다. cgroup v2 `memory.max`가 설정되어 있으면 그 값을 분모로 쓰도록 해서,
   512MB 점유가 `6%`가 아니라 `50%`로 제대로 보이게 했다(`run.sh`가 `--memory=1g`로 기동).
   시스템 전체 사용량도 같은 이유로 `memory.current`를 읽는다.

5. **로그 권한** — `run-case.sh`는 root로 돌지만 앱은 일반 사용자로 뜬다.
   케이스마다 앱 로그를 truncate 하면 파일이 root 소유로 재생성되어 앱이 자기 로그를
   못 쓰게 된다(실제로 첫 실행에서 로그가 비었다). truncate 후 소유자를 되돌려 준다.

---

## 8. 미션 목표 대응

| 미션 목표 | 대응 내용 |
| --- | --- |
| 메모리 구조와 누수의 영향을 설명 | [01-oom.md §3](reports/01-oom.md) — RSS 단조 증가, 참조 미해제와 GC, 앱 자체 종료가 커널 OOM Killer보다 나은 이유 |
| CPU 과점유가 지연을 유발하는 원리 | [02-cpu.md §3](reports/02-cpu.md) — 목표 부하와 보호 임계의 모순, nice/프로세스 상태, `ps %CPU`의 평균 함정 |
| 교착상태 진단 | [03-deadlock.md §3-2](reports/03-deadlock.md) — Coffman 4대 조건을 증거와 1:1 대조, `ps -L`/`top -H`로 스레드 단위 정체 확인 |
| 증거 기반 커뮤니케이션 | 리포트 3건 모두 관제 로그·앱 로그·시스템 도구 출력·종료 코드를 인용하고, 조치의 **한계까지 함께** 기록 |
