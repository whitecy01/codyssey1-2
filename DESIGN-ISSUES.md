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

*이 문서는 작성 중이다. 관측된 다른 모순들(설정 허용 범위와 안전장치 임계의 불일치,
경고를 띄우고도 부트를 통과시키는 문제, 자체 종료에 SIGKILL을 사용하는 문제)은 이어서 정리한다.*
