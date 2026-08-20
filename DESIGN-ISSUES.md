# agent-leak-app 설계 모순 분석

장애 재현 실험([reports/](reports))을 진행하면서, **재현 대상인 장애와는 별개로**
애플리케이션 자체의 설계가 앞뒤가 맞지 않는 지점들이 관측되었다. 이 문서는 그 기록이다.

## 이 문서가 다루지 않는 것

메모리 누수, 락 순서 뒤집기, CPU 부하 램프업은 **논리적 오류가 아니다.**
이 앱은 장애 재현을 목적으로 만들어진 교보재이고, 그 셋은 실습 과제로 일부러 심어둔 결함이다.
앱 스스로 기동 시점에 예고까지 한다.

```text
 [ MEMORY ] Limit: 50MB 		[ WARNING: Recommend Over 256MB ]
 >>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.
```

이 문서가 다루는 것은 **그 의도된 결함을 걷어내고 봐도 여전히 모순인 부분**이다.

## 분석 방법의 한계

과제 제약("바이너리 디컴파일 및 리버스 엔지니어링 시도 금지")에 따라 바이너리는 열어보지 않았다.
따라서 아래 내용은 **실행 로그·시스템 도구 출력으로 관측한 동작에서 역추론한 것**이며,
소스 코드를 확인한 결과가 아니다. 관측된 사실과 그로부터의 추론을 구분해 서술한다.

---

## 오류 1. 메모리가 빠듯할수록 회수를 하지 않는다

### 관측 사실

`MEMORY_LIMIT` 값만 다르고 나머지 조건이 동일한 두 실행에서,
**"힙이 한도에 도달했다"는 같은 상황에 대해 앱이 전혀 다른 행동을 했다.**

`MEMORY_LIMIT=512` — [`evidence/oom-after/agent_app.log`](evidence/oom-after/agent_app.log)

```text
2026-08-20 19:48:23 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-08-20 19:48:23 [INFO]    [System] Memory Cache Flushed. Process Stabilized.
2026-08-20 19:48:25 [INFO]    [CpuWorker] Current Load: 13.25%      ← 계속 동작
```

`MEMORY_LIMIT=256` — [`evidence/oom-mid/agent_app.log`](evidence/oom-mid/agent_app.log)

```text
2026-08-20 19:53:05 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
2026-08-20 19:53:05 [CRITICAL] [MemoryGuard] Self-terminating process 18863 to prevent system instability.
```

한쪽은 **캐시를 비우고 계속 살고**, 한쪽은 **그대로 죽는다.**

### 회수는 실제로 동작한다 (앱 내부 카운터 리셋이 아니다)

`Memory Cache Flushed` 가 단순한 로그 문구가 아니라 실제 물리 메모리 반환임을,
외부 관제가 독립적으로 확인해 준다. [`evidence/oom-after/monitor.log`](evidence/oom-after/monitor.log)

```text
[19:48:22] PROCESS:agent-leak-app PID:12479 ... RSS:516MB ... | ... SYS_AVAIL:468MB ...
[19:48:24] PROCESS:agent-leak-app PID:12479 ... RSS:16MB  ... | ... SYS_AVAIL:970MB ...
```

**한 틱(2초) 만에** 프로세스 RSS가 516MB → 16MB로, 시스템 가용 메모리가 468MB → 970MB로
되돌아온다. 프로세스 지표와 시스템 지표가 같은 시점에 같은 폭으로 움직였으므로,
회수된 500MB는 커널에 실제로 반환되어 다른 프로세스가 쓸 수 있는 상태가 되었다.

즉 **이 앱은 자기 힙을 회수할 능력을 온전히 갖추고 있다.**
300초 관측 동안 이 사이클이 **4회** 반복되었고 프로세스는 끝까지 생존했다.

### 무엇이 모순인가

| `MEMORY_LIMIT` | 부트 판정 | 메모리 여유 | 한도 도달 시 행동 |
| --- | --- | --- | --- |
| 50 | `WARNING` | **가장 빠듯함** | 자체 종료 |
| 256 | `WARNING` | 빠듯함 | 자체 종료 |
| 512 | `OK` | 여유 있음 | **회수 후 계속 실행** |

메모리 여유가 **적을수록 회수가 더 절실하다.** 그런데 앱은 정확히 반대로,
여유가 적을 때 회수 경로를 봉인하고 자체 종료를 선택한다.

회수 능력이 아예 없다면 "구현되지 않은 기능"이라 부를 수 있다.
그러나 능력을 갖추고 있으면서 **더 필요한 조건에서 쓰지 않는 것**은 설계의 역전이다.

### 추론

`MEMORY_LIMIT` 값이 부트 시퀀스의 판정(`WARNING` / `OK`)을 가르고,
그 판정이 다시 한도 도달 시의 분기를 결정하는 것으로 보인다.

```
MEMORY_LIMIT ≤ 256  →  [ WARNING ]  →  MemoryGuard : 자체 종료
MEMORY_LIMIT > 256  →  [ OK ]       →  MemoryWorker: 캐시 회수
```

즉 **"설정이 권장 범위 밖이면 회수를 시도조차 하지 않는다"** 는 규칙으로 읽힌다.
설정값 검증 결과를 런타임 자원 관리 정책에 그대로 연결한 것이 원인으로 추정된다.

### 운영상의 영향

이 동작 때문에 **조치의 방향이 직관과 어긋난다.**

메모리 부족으로 프로세스가 죽었을 때 운영자의 자연스러운 대응은
"한도를 낮춰 메모리를 아껴 쓰게 하자"이다. 그런데 이 앱에서는 그 조치가
**회수 경로를 봉인해 상황을 악화시킨다.** 실제로 한도를 낮출수록 생존 시간이 짧아졌다.

| `MEMORY_LIMIT` | 생존 시간 |
| --- | --- |
| 50 | 6초 |
| 256 | 33초 |
| 512 | 300초 관측 종료까지 생존 |

또한 `MEMORY_LIMIT`의 허용 상한이 512이므로, **회수가 동작하는 구간은 257~512뿐**이다.
부트 검사가 허용하는 50~512 중 **50~256(약 45%)이 "반드시 죽는 설정"** 인데도 통과한다.

### 제안

1. **회수 경로를 판정과 분리한다.** 한도 도달 시에는 `MEMORY_LIMIT` 값과 무관하게
   항상 회수를 먼저 시도하고, 회수 후에도 한도를 넘으면 그때 종료를 검토한다.
2. 굳이 낮은 한도에서 종료를 선택해야 한다면, **그 이유를 로그로 남긴다.**
   현재 로그는 `Memory limit exceeded` 만 출력해, 회수를 건너뛴 사실 자체가 드러나지 않는다.
   두 케이스를 나란히 비교하기 전에는 알아챌 수 없었다.
3. 부트 시퀀스에서 `MEMORY_LIMIT ≤ 256` 을 **경고가 아니라 기동 실패로 처리한다.**
   현재는 `All Boot Checks Passed!` 로 통과시키기 때문에, 운영자가 "죽도록 설정된 상태"임을
   인지하지 못한 채 배포할 수 있다.

### 관련 증거

- [`evidence/oom-before/`](evidence/oom-before) — `MEMORY_LIMIT=50`, 6초 후 자체 종료
- [`evidence/oom-mid/`](evidence/oom-mid) — `MEMORY_LIMIT=256`, 33초 후 자체 종료
- [`evidence/oom-after/`](evidence/oom-after) — `MEMORY_LIMIT=512`, 회수 4회, 300초 생존
- 리포트: [Issue #1](https://github.com/whitecy01/codyssey1-2/issues/1) / [reports/01-oom.md](reports/01-oom.md)

---

## 오류 2. 부트 검사가 허용하는 값의 절반이 "반드시 죽는 설정"이다

### 관측 사실

`CPU_MAX_OCCUPY` 는 **워커가 부하를 끌어올릴 목표치**로 동작한다.
설정한 숫자를 향해 부하가 상승하며, 그 값에 도달하면 꺾어서 내려온다.

`CPU_MAX_OCCUPY=30` — [`evidence/cpu-after/agent_app.log`](evidence/cpu-after/agent_app.log)

```text
[CpuWorker] Peak reached (30.00%). Starting cooldown...
[CpuWorker] Cooldown complete (5.00%). Resuming load increase...
[CpuWorker] Peak reached (30.00%). Starting cooldown...
```

120초 관측 동안 최대 부하는 **정확히 30.00%** 였고, 이 상승–쿨다운 사이클이 3회 반복되었다.

`CPU_MAX_OCCUPY=100` — [`evidence/cpu-before/agent_app.log`](evidence/cpu-before/agent_app.log)

```text
[CpuWorker] Current Load: 5.00%
[CpuWorker] Current Load: 23.34%
[CpuWorker] Current Load: 40.58%
[CpuWorker] Current Load: 45.95%
[CpuWorker] Current Load: 52.48%
[CRITICAL] [CpuWorker] CPU Threshold Violated! (52.48%).
```

100을 향해 올라가던 중 **52.48%에서 종료**되었다.
([`evidence/cpu-before/app-stdout.log`](evidence/cpu-before/app-stdout.log))

```text
>>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<
Script done on 2026-08-20 19:53:40+09:00 [COMMAND_EXIT_CODE="143"]
```

### 무엇이 모순인가

Watchdog 의 종료 기준은 `CPU_MAX_OCCUPY` 가 아니라 **50% 고정**이다.
부트 배너의 `Recommend Under 50%` 와 일치하며, 별도 실행에서 50.05% 에 위반 판정이 난 것으로
보아 램프 속도와 무관하게 임계선 자체는 50% 로 고정되어 있다.

그런데 부트 검사가 허용하는 `CPU_MAX_OCCUPY` 범위는 **10~100** 이다.

| 설정값 | 워커가 도달하는 부하 | 50% 임계 | 결과 |
| --- | --- | --- | --- |
| 10 ~ 50 | 설정값에서 꺾임 | 못 닿음 | 생존 |
| **51 ~ 100** | 설정값을 향해 상승 | **반드시 통과** | **반드시 종료** |

경계값은 별도 실행으로 확인했다. `CPU_MAX_OCCUPY=50` 은 부트 판정이 `[ OK ]` 이고,
부하가 **정확히 50.00% 에서 꺾여** 쿨다운으로 들어가며 위반이 발생하지 않는다.

```text
 [ CPU    ] Limit: 50%  		[ OK ]
[CpuWorker] Current Load: 43.06%
[CpuWorker] Peak reached (50.00%). Starting cooldown...
[CpuWorker] Current Load: 50.00%
[CpuWorker] Current Load: 40.26%      ← 위반 없이 하강
```

즉 종료 조건은 `부하 > 50` 이며, 50 자체는 안전하다.
(위반이 관측된 값은 50.05% 와 52.48% 로 모두 50 초과였다.)

**허용 범위의 절반이 "설정하는 순간 종료가 확정되는 값"인데도 부트 검사를 통과한다.**
우발적 부하 급증이 아니라, 목표치를 안전 임계보다 높게 잡을 수 있도록 허용한 **구성 오류**다.

### 곁가지 — 두 배너의 경계 해석이 서로 다르다

위 경계 실험에서 드러난 부수적 문제다. 두 변수의 권장 문구가 같은 형식인데
**포함/제외가 반대**다.

| 배너 문구 | 경계값 판정 | 해석 |
| --- | --- | --- |
| `Recommend Over 256MB` | `MEMORY_LIMIT=256` → **`WARNING`** | 256 **제외** (초과만 OK) |
| `Recommend Under 50%` | `CPU_MAX_OCCUPY=50` → **`OK`** | 50 **포함** (이하면 OK) |

`Over` 는 경계를 빼고 `Under` 는 경계를 넣는다. 문구만 보고는 어느 쪽인지 알 수 없어,
두 변수 모두 경계값을 직접 실행해 본 뒤에야 확정할 수 있었다.
`Recommend >= 257MB`, `Recommend <= 50%` 처럼 부등호로 적으면 사라질 모호함이다.

### 추론

두 숫자가 서로를 참조하지 않는 것으로 보인다.

```
CPU_MAX_OCCUPY  = 사용자 지정 (부트 검사 통과 범위 10~100)
Watchdog 임계   = 코드에 고정 (50)
```

임계를 `CPU_MAX_OCCUPY` 에서 파생시켰다면(예: 설정값의 일정 배수) 목표치가 임계를 넘는
조합 자체가 성립할 수 없다. 설정값 검증 범위와 런타임 안전장치가 각각 독립적으로
정해진 것이 원인으로 추정된다.

### 운영상의 영향

**조치 방향이 메모리와 정반대**라는 점이 실무적으로 혼란을 만든다.

| 변수 | 장애를 막으려면 |
| --- | --- |
| `MEMORY_LIMIT` | **올린다** (50 → 512) |
| `CPU_MAX_OCCUPY` | **내린다** (100 → 30) |

이름이 둘 다 "한도(LIMIT/MAX)"처럼 읽히지만, `MEMORY_LIMIT` 은 넘으면 안 되는 **상한**이고
`CPU_MAX_OCCUPY` 는 도달하려 애쓰는 **목표치**다. 성격이 반대인 두 값에 비슷한 이름이
붙어 있어, "한도니까 넉넉히 잡자"는 판단이 CPU 쪽에서는 곧바로 종료로 이어진다.

또한 이 조치는 **처리량을 깎아 장애를 회피한 것**이다. 워커가 30% 를 상한으로 일하므로,
이 값이 실제 처리 용량과 연동된다면 성능이 그만큼 떨어진다.

### 제안

1. **Watchdog 임계를 `CPU_MAX_OCCUPY` 에서 파생시킨다.** 두 값이 독립적인 한,
   목표치를 임계보다 높게 잡는 조합은 언제든 다시 만들어질 수 있다.
2. 임계를 고정으로 유지해야 한다면, **부트 검사의 허용 범위를 임계에 맞춘다.**
   현재는 검증 범위(10~100)와 안전 임계(50)가 어긋나 있다.
   범위를 10~50 으로 좁히면 "죽는 설정"을 애초에 입력할 수 없다.
3. `CPU_MAX_OCCUPY >= 50` 을 **경고가 아니라 기동 실패로 처리한다.**
   현재는 `WARNING` 만 띄우고 `All Boot Checks Passed!` 로 통과시킨다.
4. 변수 이름을 성격에 맞게 바꾼다. `CPU_MAX_OCCUPY` 는 상한이 아니라 목표치이므로
   `CPU_TARGET_LOAD` 에 가깝다.
5. 권장 범위를 `Over`/`Under` 대신 **부등호로 표기**해 경계 포함 여부를 명확히 한다.

### 관련 증거

- [`evidence/cpu-before/`](evidence/cpu-before) — `CPU_MAX_OCCUPY=100`, 52.48% 에서 Watchdog SIGTERM, 35초 생존
- [`evidence/cpu-after/`](evidence/cpu-after) — `CPU_MAX_OCCUPY=30`, 최대 30.00%, 임계 위반 0회, 120초 생존
- 리포트: [Issue #2](https://github.com/whitecy01/codyssey1-2/issues/2) / [reports/02-cpu.md](reports/02-cpu.md)

---

*이 문서는 작성 중이다. 관측된 다른 모순들(경고를 띄우고도 부트를 통과시키는 문제,
자체 종료에 SIGKILL 을 사용하는 문제)은 이어서 정리한다.*
