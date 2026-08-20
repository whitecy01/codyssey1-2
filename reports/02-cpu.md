# [Bug] CPU_MAX_OCCUPY=100 설정 시 CpuWorker 부하가 50% 임계를 넘어 Watchdog이 SIGTERM으로 프로세스를 강제 종료

| 항목 | 값 |
| --- | --- |
| 장애 유형 | CPU Latency (과점유 방지 정책에 의한 종료) |
| 대상 | `agent-leak-app` (Ubuntu 22.04 / aarch64 컨테이너, 8 vCPU) |
| 관측 일시 | 2026-08-20 19:53 ~ 19:56 (KST) |
| 재현율 | 2/2 (`CPU_MAX_OCCUPY=100` 인 모든 실행에서 재현) |
| 증거 | [`evidence/cpu-before/`](../evidence/cpu-before) · [`evidence/cpu-after/`](../evidence/cpu-after) |

---

## 1. Description (현상 설명)

`CPU_MAX_OCCUPY=100` 으로 기동하면 부트 시퀀스는 정상 통과하지만, 리소스 점검 배너에서
경고가 뜬다.

```text
 [ MEMORY ] Limit: 512MB 		[ OK ]
 [ CPU    ] Limit: 100%  		[ WARNING: Recommend Under 50% ]
 [ THREAD ] Concurrency: False 		[ OK ]
```

이후 `CpuWorker`가 보고하는 부하가 5% → 50%로 계단식 상승하고, **50%를 넘는 순간**
아래 배너와 함께 프로세스가 종료된다. 기동부터 종료까지 **35초**였다.

```text
>>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<
```

OOM 케이스와 달리 이것은 **오류(crash)가 아니라 정책에 의한 계획된 종료**다.
근거는 4장과 3-2에서 시그널 종류로 정리한다.

---

## 2. Evidence & Logs (증거 자료)

### 2-1. 프로그램 실행 로그 — 부하 상승 구간과 임계 위반

`evidence/cpu-before/agent_app.log`

```text
[CpuWorker] Current Load: 5.00%
[CpuWorker] Current Load: 14.60%
[CpuWorker] Current Load: 14.85%
[CpuWorker] Current Load: 23.34%
[CpuWorker] Current Load: 29.47%
[CpuWorker] Current Load: 35.84%
[CpuWorker] Current Load: 40.58%
[CpuWorker] Current Load: 45.95%
[CpuWorker] Current Load: 52.48%
[CRITICAL] [CpuWorker] CPU Threshold Violated! (52.48%).
```

약 3초 간격으로 5% → 52.48% 까지 30초에 걸쳐 상승했고, **45.95%에서는 살아 있다가
50%를 넘어선 52.48%에서 위반 판정**이 났다. 임계선이 50%임을 보여주는 구간이며,
부트 배너의 `Recommend Under 50%` 와 일치한다.
(직전 실행에서는 50.05%에서 위반 판정이 났다 — 램프 속도에 따라 임계를 넘는 첫 샘플값만
달라질 뿐 판정 기준은 동일하다.)

### 2-2. 종료 신호 — SIGTERM 확인

`evidence/cpu-before/app-stdout.log` 끝부분

```text
[CRITICAL] [CpuWorker] CPU Threshold Violated! (52.48%).

>>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<

Script done on 2026-08-20 19:53:40+09:00 [COMMAND_EXIT_CODE="143"]
```

**종료 코드 143 = 128 + 15 = SIGTERM.**
메모리 케이스의 137(SIGKILL)과 대비되는 지점이며, "오류가 아닌 시스템 보호 조치"라는
판정의 직접 증거다. SIGTERM은 프로세스가 받아서 정리 후 종료할 수 있는 **정중한 종료 요청**이고,
Watchdog이 이 신호를 골랐다는 것은 강제 파기가 아니라 계획된 회수를 의도했다는 뜻이다.

### 2-3. 시스템 도구 관점 — ps / top 은 이 부하를 보지 못한다

같은 프로세스를 `ps`와 `top -H`로 찍은 t+22초 시점 스냅샷이다.
(`evidence/cpu-before/snapshots.txt`)

```text
$ ps -o pid,ppid,stat,%cpu,%mem,rss,nlwp,etime,comm -p 19522
  PID  PPID STAT %CPU %MEM   RSS NLWP     ELAPSED COMMAND
19522 19521 SN+   0.7  0.2 17036    1       00:22 agent-leak-app

$ top -H -b -n1 -p 19522
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
19522 agent-a+  30  10   23168  17036   8460 S   0.0   0.2   0:00.17 agent-lea+
```

`monitor.sh`의 관제 로그도 같은 이야기를 한다. 임계 위반 직전 10초 구간이다.
(`evidence/cpu-before/monitor.log`, `|` 오른쪽이 시스템 전체)

```text
[2026-08-20 19:53:30] PROCESS:...PID:19522 STATE:S CPU:2.0% MEM:1.6% RSS:16MB THREADS:1 | SYS_CPU:1.2% SYS_MEM:5.2% SYS_AVAIL:970MB SYS_LOAD:0.12 DISK:4%
[2026-08-20 19:53:33] PROCESS:...PID:19522 STATE:S CPU:0%   MEM:1.6% RSS:16MB THREADS:1 | SYS_CPU:0.9% SYS_MEM:5.2% SYS_AVAIL:970MB SYS_LOAD:0.11 DISK:4%
[2026-08-20 19:53:35] PROCESS:...PID:19522 STATE:S CPU:2.5% MEM:1.6% RSS:16MB THREADS:1 | SYS_CPU:0.6% SYS_MEM:5.2% SYS_AVAIL:970MB SYS_LOAD:0.11 DISK:4%
[2026-08-20 19:53:37] PROCESS:...PID:19522 STATE:S CPU:2.5% MEM:1.6% RSS:16MB THREADS:1 | SYS_CPU:0.5% SYS_MEM:5.2% SYS_AVAIL:969MB SYS_LOAD:0.11 DISK:4%
[2026-08-20 19:53:39] PROCESS:...PID:19522 STATE:S CPU:0%   MEM:1.6% RSS:16MB THREADS:1 | SYS_CPU:0.4% SYS_MEM:5.2% SYS_AVAIL:970MB SYS_LOAD:0.10 DISK:4%
```

**앱이 "Load 52%"라고 말하는 그 순간, OS가 본 이 프로세스의 CPU 소비는 0~2.5%다.**
가장 결정적인 수치는 `top`의 `TIME+ 0:00.17` 다 — 22초 동안 누적 CPU 시간이
**0.17초**밖에 안 된다(약 0.8%). 프로세스 상태도 내내 `S`(sleeping)이고 `R`(running)이 아니다.

**시스템 전체를 봐도 마찬가지다.** 이것이 진단의 결정타다.

- `SYS_CPU`는 관측 내내 **0.4~1.2%** 였다(8코어 기준). 최댓값조차 1.2%다.
- `SYS_LOAD`(1분 부하 평균)는 0.10~0.17 구간이며, 임계 위반 직전에는 오히려 **0.12 → 0.10으로 하락**했다.
- 즉 이 프로세스가 CPU를 다른 곳에 숨겨 쓴 것이 아니라, **호스트 어디에서도 CPU 급증이 일어나지 않았다.**
  프로세스 지표만 봤다면 "측정을 잘못한 것 아닌가"라고 의심할 수 있지만,
  시스템 지표까지 조용하다는 사실이 그 가능성을 닫는다.

이 불일치는 이 리포트에서 가장 중요한 관측이며, 3-2에서 해석한다.

### 2-4. 대조군 — CPU_MAX_OCCUPY=30 에서의 부하 곡선

`evidence/cpu-after/agent_app.log`

```text
[CpuWorker] Peak reached (30.00%). Starting cooldown...
[CpuWorker] Cooldown complete (5.00%). Resuming load increase...
[CpuWorker] Peak reached (30.00%). Starting cooldown...
[CpuWorker] Cooldown complete (5.00%). Resuming load increase...
[CpuWorker] Peak reached (30.00%). Starting cooldown...
```

120초 관측 동안 관측된 최대 부하는 **정확히 30.00%** 였고, 임계 위반은 한 번도 없었다.
쿨다운 사이클은 3회 관측되었다. 같은 구간 OS 지표는 프로세스 CPU 최대 3.5%,
`SYS_CPU` 최대 2.3% — Before와 사실상 같은 수준이다.

---

## 3. Root Cause Analysis (원인 분석)

### 3-1. 직접 원인 — 목표 부하와 보호 임계가 서로 모순된 설정

`CpuWorker`는 **`CPU_MAX_OCCUPY`를 목표 상한으로 삼아 부하를 그 값까지 끌어올린다.**
반면 Watchdog의 종료 임계는 **50% 고정**이다(부트 배너 `Recommend Under 50%`).

- `CPU_MAX_OCCUPY=100` → 워커가 100%를 향해 올라가다 **50%를 지나가면서 반드시 위반**한다. 종료는 시간 문제일 뿐 확정적이다.
- `CPU_MAX_OCCUPY=30` → 워커가 30%에서 `Peak reached` 로 꺾고 5%까지 쿨다운한 뒤 다시 오른다. 50%에 **구조적으로 도달할 수 없다.**

즉 이 장애는 부하 급증이라는 우발적 사건이 아니라, **워커의 목표치(100)가 보호 임계(50)보다
높게 설정된 구성 오류**다. `CPU_MAX_OCCUPY`가 50을 넘는 순간 종료는 예정된 결과다.

### 3-2. 핵심 발견 — Watchdog이 보는 부하는 OS의 CPU 사용률이 아니다

2-3에서 본 대로, 앱이 `Load: 52.48%` 를 보고하는 동안 실제 CPU 소비는 22초에 0.17초(≈0.8%)이고
시스템 전체 CPU도 1.2%를 넘지 않았다.
따라서 `Current Load` 는 **애플리케이션이 내부적으로 계산·시뮬레이션하는 자체 지표**이고,
Watchdog은 그 내부 지표를 보고 종료를 결정한다.

이 사실이 운영에 주는 함의는 크다.

- **`top`/`ps`/CPU 기반 관제 알람으로는 이 장애를 절대 예측할 수 없다.**
  임계 위반 직전까지도 OS 관점의 프로세스는 "거의 놀고 있는 프로세스"로 보인다.
- 사후에 "CPU가 튀었나?" 하고 `top` 히스토리를 뒤지면 **아무 것도 안 나온다.**
  실제로 이번 조사에서도 관제 로그만 봤다면 원인을 놓쳤을 것이다.
- 이 장애의 유일한 조기 신호는 **애플리케이션 로그의 `[CpuWorker] Current Load` 계열**이다.
  관제 대상에 프로세스 지표뿐 아니라 **앱 자체 로그 파싱**이 반드시 포함되어야 한다.

> 이 관측은 요구사항의 "특정 프로세스의 CPU 사용률이 급격히 상승하는 구간을 식별한다"에 대해
> 실측이 준 답이기도 하다. 상승 구간은 **존재하지만 앱 계층에만 존재**했고,
> OS 계층(ps/top/관제)에서는 관측되지 않았다. 두 계층을 함께 붙여야만 사건이 설명된다.

### 3-3. 관측 방법에 대한 메모 — 왜 `ps %CPU`를 쓰지 않았나

`ps`의 `%CPU`는 **프로세스 생애 전체 평균**(누적 CPU 시간 ÷ 총 경과 시간)이다.
"급상승 구간"을 찾는 목적에는 부적합하다. 30초 살다 죽는 프로세스가 마지막 3초 동안
CPU를 100% 썼어도 평균은 10%로 희석된다.

그래서 `monitor.sh`는 `/proc/<pid>/stat`의 `utime + stime`을 2초 간격으로 **차분**해
구간 사용률을 계산한다. 이번 케이스는 그렇게 재도 0~2.5%였으므로, 낮은 수치가
측정 방식의 한계 때문이 아니라 **실제로 CPU를 쓰지 않았기 때문**임이 확인된다.

### 3-4. 관련 OS 동작 원리

- **SIGTERM(15) vs SIGKILL(9)**: SIGTERM은 프로세스가 핸들러로 받아 정리 후 종료할 수 있다.
  SIGKILL은 커널이 즉시 회수하며 가로챌 수 없다. 이번 CPU 케이스는 143(SIGTERM),
  메모리 케이스는 137(SIGKILL)이었다. **같은 "강제 종료"라도 설계 의도가 다르다** —
  전자는 "질서 있게 물러나라", 후자는 "지금 당장 사라져라"다.
- **nice 값**: 부트 로그의 `[SafetyGuard] Process priority lowered (nice=10)` 대로
  이 프로세스는 nice=10으로 동작한다(`top`의 `NI 10`, `PR 30`). 우선순위를 낮춰
  같은 호스트의 다른 프로세스가 CPU를 먼저 가져가게 한 것이다. 실제 CPU 소비가
  낮았던 데에는 이 설정도 일부 기여한다.
- **프로세스 상태 `S`**: 스냅샷 내내 `S`(interruptible sleep)였다. 진짜로 CPU를 태우는
  프로세스는 `R`(running)로 자주 잡힌다. 상태 컬럼 하나만 봐도 "이 프로세스는 지금
  CPU를 쓰고 있지 않다"를 판정할 수 있다.

---

## 4. Workaround & Verification (조치 및 검증)

### 조치

`CPU_MAX_OCCUPY` 환경변수를 **100 → 30** 으로 하향했다.
Watchdog 임계(50%)보다 확실히 낮은 값으로 잡아, 워커의 목표 부하가
구조적으로 임계에 닿지 못하게 만드는 것이 의도다.

```bash
export CPU_MAX_OCCUPY=30     # Watchdog 임계 50% 아래. 부트 배너가 [ OK ] 로 바뀐다
```

### Before & After

| 구분 | Before | After |
| --- | --- | --- |
| `CPU_MAX_OCCUPY` | 100 | 30 |
| 부트 판정 | `WARNING: Recommend Under 50%` | `OK` |
| 관측된 최대 부하 (앱 보고) | **52.48%** | **30.00%** |
| 부하 패턴 | 단조 상승 (5% → 52%) | 상승 → `Peak reached` → 쿨다운(5%) 반복, 3사이클 |
| 임계 위반 | **1회 → 종료** | **0회** |
| 생존 시간 | **35초** | **120초 관측 종료까지 생존** |
| 종료 사유 | Watchdog SIGTERM (exit 143) | 종료 없음 |
| OS 관점 CPU (프로세스) | 0~2.5% (`TIME+ 0:00.17` / 22초) | 0~3.5% (동일 수준) |
| OS 관점 CPU (시스템) | 0.4~1.2%, `SYS_LOAD` 0.10~0.17 | 최대 2.3% (동일 수준) |
| 증거 | `evidence/cpu-before/` | `evidence/cpu-after/` |

생존 시간이 **35초 → 120초 이상**으로 늘었고, 임계 위반이 완전히 사라졌다.
OS 관점의 CPU 소비는 Before/After가 사실상 동일하다 — 3-2에서 설명한 대로
**이 조치가 바꾼 것은 실제 CPU 부하가 아니라 앱 내부 지표가 임계를 넘느냐**이기 때문이다.

### 이 조치의 한계

- **처리량을 깎아 장애를 회피한 것**이다. 워커가 30%를 상한으로 일하므로,
  이 값이 실제 처리 용량과 연동된다면 성능이 그만큼 떨어진다.
  운영에서는 "몇 %까지 낮춰도 SLA를 지키는가"를 별도로 측정해야 한다.
- 120초 관측 동안 RSS는 여전히 톱니 모양으로 516MB까지 올랐다.
  **CPU 장애는 막았지만 메모리 누수는 그대로**다([01-oom.md](01-oom.md) 참조).

### 근본 해결 제안

1. `CpuWorker`의 목표 부하와 Watchdog 임계를 **하나의 설정값에서 파생**시킨다.
   지금처럼 목표치(`CPU_MAX_OCCUPY`)와 임계(50% 고정)가 독립적이면,
   목표치를 임계보다 높게 잡는 자살적 구성이 언제든 다시 만들어질 수 있다.
2. 부트 시퀀스에서 `CPU_MAX_OCCUPY >= 50` 을 **경고가 아니라 기동 실패로 처리**한다.
   현재는 `WARNING`만 띄우고 `All Boot Checks Passed!` 로 통과시키기 때문에,
   운영자가 "경고는 떴지만 떴으니 괜찮겠지"라고 판단하기 쉽다.
3. 관제에 **애플리케이션 로그 기반 지표**를 추가한다.
   `[CpuWorker] Current Load` 값을 파싱해 40% 초과 시 경보하면
   Watchdog이 종료를 결정하기 전에(이번 사례 기준 약 6초 전) 개입할 수 있다.
   OS CPU 사용률만 보는 관제로는 이 장애를 영원히 못 잡는다.
