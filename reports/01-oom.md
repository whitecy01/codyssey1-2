# [Bug] MEMORY_LIMIT 미달 설정에서 힙 누수가 회수되지 않고 MemoryGuard가 프로세스를 SIGKILL로 자체 종료

| 항목 | 값 |
| --- | --- |
| 장애 유형 | OOM Crash (Memory Leak) |
| 대상 | `agent-leak-app` (Ubuntu 22.04 / aarch64 컨테이너, 메모리 상한 1GB) |
| 관측 일시 | 2026-08-20 19:45 ~ 19:53 (KST) |
| 재현율 | 3/3 (MEMORY_LIMIT ≤ 256 인 모든 실행에서 재현) |
| 증거 | [`evidence/oom-before/`](../evidence/oom-before) · [`evidence/oom-mid/`](../evidence/oom-mid) · [`evidence/oom-after/`](../evidence/oom-after) |

---

## 1. Description (현상 설명)

`agent-leak-app`을 기동하면 **예고 없이 프로세스가 사라진다.** 종료 시점은 실행할 때마다 다르지만
`MEMORY_LIMIT` 값에 따라 결정적으로 달라졌다.

| MEMORY_LIMIT | 부트 시퀀스 판정 | 생존 시간 | 종료 사유 |
| --- | --- | --- | --- |
| 50MB | `[ WARNING: Recommend Over 256MB ]` | **6초** | MemoryGuard 자체 종료 (SIGKILL) |
| 256MB | `[ WARNING: Recommend Over 256MB ]` | **33초** | MemoryGuard 자체 종료 (SIGKILL) |
| 512MB | `[ OK ]` | **300초 관측 종료까지 생존** | 종료되지 않음 |

부트 시퀀스([1/6]~[6/6])는 세 경우 모두 `All Boot Checks Passed!` 로 통과했다.
즉 **기동 실패가 아니라, 정상 기동한 뒤 워크로드 도중에 죽는** 유형이다.

종료 직전 터미널에는 아래 배너가 출력된다.

```
>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<
```

---

## 2. Evidence & Logs (증거 자료)

### 2-1. 관제 로그 — 메모리 점유율이 선형으로 상승

`monitor.sh`가 2초 간격으로 수집한 `MEMORY_LIMIT=256` 실행 구간이다.
(`evidence/oom-mid/monitor.log` 전문)

`|` 왼쪽이 대상 프로세스, 오른쪽이 시스템 전체 지표다.

```text
[2026-08-20 19:52:35] MONITOR START PROCESS:agent-leak-app PID:18863 INTERVAL:2s
[2026-08-20 19:52:35] SCOPE cpu_cores=8 mem_scope=cgroup mem_total=1024MB
[2026-08-20 19:52:37] PROCESS:...PID:18863 STATE:S CPU:0%   MEM:4.0%  RSS:41MB  THREADS:1 | SYS_CPU:0.3% SYS_MEM:7.5%  SYS_AVAIL:946MB SYS_LOAD:0.31 DISK:4%
[2026-08-20 19:52:43] PROCESS:...PID:18863 STATE:S CPU:1.0% MEM:8.9%  RSS:91MB  THREADS:1 | SYS_CPU:0.8% SYS_MEM:12.5% SYS_AVAIL:895MB SYS_LOAD:0.26 DISK:4%
[2026-08-20 19:52:49] PROCESS:...PID:18863 STATE:S CPU:0.5% MEM:13.7% RSS:141MB THREADS:1 | SYS_CPU:0.4% SYS_MEM:17.4% SYS_AVAIL:845MB SYS_LOAD:0.24 DISK:4%
[2026-08-20 19:52:55] PROCESS:...PID:18863 STATE:S CPU:0.5% MEM:18.6% RSS:191MB THREADS:1 | SYS_CPU:0.4% SYS_MEM:22.2% SYS_AVAIL:795MB SYS_LOAD:0.22 DISK:4%
[2026-08-20 19:52:59] PROCESS:...PID:18863 STATE:S CPU:2.0% MEM:23.5% RSS:241MB THREADS:1 | SYS_CPU:0.5% SYS_MEM:27.1% SYS_AVAIL:746MB SYS_LOAD:0.20 DISK:4%
[2026-08-20 19:53:03] PROCESS:...PID:18863 STATE:S CPU:1.0% MEM:26.0% RSS:266MB THREADS:1 | SYS_CPU:1.4% SYS_MEM:29.6% SYS_AVAIL:720MB SYS_LOAD:0.18 DISK:4%
[2026-08-20 19:53:05] PROCESS:agent-leak-app PID:18863 STATUS:TERMINATED (after 30s)
```

**프로세스 관점**에서 읽어야 할 지점은 세 가지다.

- **RSS가 41MB → 266MB로 단조 증가**한다. 26초 동안 225MB, 약 **8.7MB/s**. 감소 구간이 한 번도 없다.
  (2-2에서 볼 앱 자체 보고 기준으로는 25MB/3.03초 ≈ **8.3MB/s** — 두 측정이 일치한다.)
- **CPU는 0~2.0%로 평탄하다.** 즉 계산량 폭증이 아니라 순수한 메모리 축적이다.
- **THREADS는 1로 고정**이다. 스레드 누수(스레드가 계속 늘어나는 유형)가 아니다.

**시스템 관점**은 이 누수가 실제로 호스트를 압박했음을 보여준다.

- **가용 메모리가 946MB → 720MB로 226MB 줄었다.** 같은 구간 프로세스 RSS 증가분(225MB)과
  **거의 정확히 일치**한다 — 이 감소분이 전부 이 프로세스 하나 때문이라는 뜻이다.
  다른 프로세스가 범인일 가능성이 수치로 배제된다.
- `SYS_MEM`이 7.5% → 29.6%로 올랐다. 30초 만에 시스템 메모리의 **1/5 이상을 이 프로세스가 잠식**했다.
- 반면 `SYS_CPU`는 0.3~1.4%, `SYS_LOAD`는 오히려 0.31 → 0.18로 **떨어졌다.**
  시스템 전체가 한가한데 메모리만 빨려 들어가는, 전형적인 누수 패턴이다.

> `MEM%`/`SYS_MEM`의 분모는 호스트 전체 메모리가 아니라 컨테이너에 걸린 cgroup 상한(1GB)이다.
> 컨테이너 안에서도 `/proc/meminfo` 는 호스트 전체 메모리를 보여주기 때문에,
> 상한을 무시하고 계산하면 실제 압박도가 실제보다 훨씬 낮게 찍힌다.
> 관제 로그 두 번째 줄의 `SCOPE` 가 이 분모를 명시한다.

### 2-2. 프로그램 실행 로그 — 25MB 단위 증가와 MemoryGuard 발동

`evidence/oom-mid/agent_app.log`

```text
2026-08-20 19:52:53,3xx [INFO] [MemoryWorker] Current Heap: 175MB
2026-08-20 19:52:59,4xx [INFO] [MemoryWorker] Current Heap: 225MB
2026-08-20 19:53:02,421 [INFO] [MemoryWorker] Current Heap: 250MB
2026-08-20 19:53:05,460 [INFO] [MemoryWorker] Current Heap: 275MB
2026-08-20 19:53:05,461 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
2026-08-20 19:53:05,461 [CRITICAL] [MemoryGuard] Self-terminating process 18863 to prevent system instability.
```

**약 3초마다 정확히 25MB씩** 늘어난다. 앱이 보고하는 `Current Heap` 값과
관제가 외부에서 측정한 `RSS` 값이 거의 일치한다(275MB vs 266MB) — 앱의 자기보고가
실제 물리 메모리 점유와 어긋나지 않음을 교차 검증한 것이다.

### 2-3. 종료 신호 — SIGKILL 확인

앱을 의사 터미널(pty)에 붙여 실행했기 때문에 종료 배너와 종료 코드까지 남았다.
(`evidence/oom-mid/app-stdout.log` 끝부분)

```text
>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<

Script done on 2026-08-20 19:53:05+09:00 [COMMAND_EXIT_CODE="137"]
```

**종료 코드 137 = 128 + 9 = SIGKILL.** 프로세스가 시그널 9로 죽었다는 뜻이다.
`MemoryGuard` 로그의 "Self-terminating process 18863" 과 합치면,
**외부(커널 OOM Killer)가 아니라 애플리케이션이 스스로 자기 PID에 SIGKILL을 보냈다**는 결론이 나온다.

> 참고: 앱은 종료 배너를 출력한 직후 SIGKILL 되기 때문에, stdout을 파이프로 연결하면
> 블록 버퍼링에 걸려 이 마지막 줄이 통째로 유실된다. 실제로 첫 시도에서 배너를 놓쳤고,
> `script -qfec` 로 pty를 붙여서야 증거로 확보할 수 있었다.

---

## 3. Root Cause Analysis (원인 분석)

### 3-1. 결함: MemoryWorker가 할당한 힙을 반환하지 않는다

`[MemoryWorker] Current Heap` 이 3초 주기로 25MB씩 단조 증가하고 한 번도 줄지 않는다.
파이썬 기준으로는 **워커가 만든 객체에 대한 참조가 어딘가(리스트·캐시·전역 컬렉션)에
계속 남아 GC 대상이 되지 못하는 상태**다. 참조가 살아 있으면 GC는 회수하지 않으므로,
프로세스 RSS는 할당 속도만큼 그대로 올라간다.

### 3-2. 왜 죽는 시점이 MEMORY_LIMIT에 비례하는가

MemoryGuard는 `힙 사용량 >= MEMORY_LIMIT` 을 매 사이클 검사한다.
증가 속도가 8.3MB/s로 일정하므로 사망 시점은 `MEMORY_LIMIT / 8.3MB/s` 로 결정된다.

- 50MB → 약 6초 (실측 6초)
- 256MB → 약 31초 (실측 33초)

**MEMORY_LIMIT은 누수를 막는 값이 아니라 "언제 죽을지"를 정하는 값**이다.

### 3-3. 핵심 발견 — 512MB에서는 죽지 않는다 (회수 경로가 열린다)

`MEMORY_LIMIT=512` 에서는 부트 판정이 `[ OK ]` 로 바뀌고, 한계에 도달했을 때
**종료가 아니라 정리(cleanup)** 가 수행된다. (`evidence/oom-after/agent_app.log`)

```text
2026-08-20 19:48:23,715 [INFO]    [MemoryWorker] Current Heap: 525MB
2026-08-20 19:48:23,715 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-08-20 19:48:23,727 [INFO]    [System] Memory Cache Flushed. Process Stabilized.
```

이 회수가 관제 로그에서도 그대로 관측된다. **한 틱(2초) 만에** 프로세스 RSS가 516MB → 16MB로,
시스템 가용 메모리가 468MB → 970MB로 되돌아온다.

```text
[2026-08-20 19:48:22] PROCESS:...PID:12479 STATE:S CPU:1.5% MEM:50.4% RSS:516MB THREADS:3 | SYS_CPU:2.9% SYS_MEM:54.2% SYS_AVAIL:468MB SYS_LOAD:0.32
[2026-08-20 19:48:24] PROCESS:...PID:12479 STATE:S CPU:1.5% MEM:1.5%  RSS:16MB  THREADS:3 | SYS_CPU:0.5% SYS_MEM:5.2%  SYS_AVAIL:970MB SYS_LOAD:0.32
```

시스템 지표가 프로세스 지표와 **같은 틱에 같은 폭으로** 움직인다는 점이 중요하다.
회수된 500MB가 커널에 실제로 반환되어 다른 프로세스가 쓸 수 있는 상태가 되었다는
직접 증거다(단순히 앱 내부 카운터만 리셋된 것이 아니다).

300초 관측 동안 이 **톱니(sawtooth) 사이클이 4회** 반복되었고 프로세스는 끝까지 살아남았다.
사이클 주기는 약 66초다.

정리하면, 부트 시퀀스가 `[ WARNING: Recommend Over 256MB ]` 를 띄운 구성에서는
메모리 회수 경로가 동작하지 않고 보호 정책이 **자체 종료**를 선택한다.
`MEMORY_LIMIT`을 권장치(256MB 초과)로 올려야 비로소 `Memory Cache Flushed` 경로가 살아난다.

### 3-4. 관련 OS 동작 원리

- **RSS(Resident Set Size)** 는 프로세스가 실제로 물리 메모리에 올려둔 크기다.
  힙에 할당만 하고 반환하지 않으면 RSS는 단조 증가하고, 프로세스가 죽어야만 반환된다.
- **SIGKILL(9)은 핸들링·차단·무시가 불가능**하다. 그래서 정리 코드가 돌 틈이 없고,
  stdout 버퍼에 남아 있던 출력도 함께 사라진다(2-3의 배너 유실이 이 현상이다).
- 애플리케이션이 **커널 OOM Killer보다 먼저** 자기를 죽이는 설계인 이유는,
  커널 OOM Killer가 개입하면 희생자 선정이 `oom_score` 기준이라 **엉뚱한 프로세스가
  죽을 수 있기 때문**이다. 자기 자신을 먼저 죽이면 피해 범위를 자기 프로세스로 가둘 수 있다.
- 이번 실행에서 커널 OOM Killer는 개입하지 않았다. 컨테이너 상한이 1GB인데
  MemoryGuard가 512MB 선에서 먼저 동작했기 때문이다.

---

## 4. Workaround & Verification (조치 및 검증)

### 조치

`MEMORY_LIMIT` 환경변수를 **50MB → 512MB** 로 상향했다.
나머지 두 변수는 장애 원인을 하나로 고정하기 위해 권장 범위 안에 두었다
(`CPU_MAX_OCCUPY=30`, `MULTI_THREAD_ENABLE=false`).

```bash
export MEMORY_LIMIT=512      # 부트 판정이 [ WARNING ] → [ OK ] 로 바뀌는 경계는 256MB 초과
```

### Before & After

| 구분 | Before | 중간 검증 | After |
| --- | --- | --- | --- |
| `MEMORY_LIMIT` | 50MB | 256MB | 512MB |
| 부트 판정 | `WARNING: Recommend Over 256MB` | `WARNING: Recommend Over 256MB` | `OK` |
| 생존 시간 | **6초** | **33초** | **300초 관측 종료까지 생존** |
| 최대 RSS (프로세스) | 41MB | 266MB | 516MB (회수 후 16MB로 복귀) |
| 최소 가용 메모리 (시스템) | 946MB | 720MB | **468MB** (회수 후 970MB로 복귀) |
| 종료 사유 | MemoryGuard SIGKILL (exit 137) | MemoryGuard SIGKILL (exit 137) | 종료 없음 |
| 메모리 회수 | 없음 | 없음 | **4회 (`Memory Cache Flushed`)** |
| 증거 | `evidence/oom-before/` | `evidence/oom-mid/` | `evidence/oom-after/` |

생존 시간이 **6초 → 300초 이상, 50배 이상 개선**되었고, 관측 창 안에서 종료가 사라졌다.

### 이 조치의 한계 (반드시 함께 기록)

**누수 자체는 고쳐지지 않았다.** 512MB 구성에서도 RSS는 여전히 8.3MB/s로 오르고,
단지 한계에 닿을 때마다 캐시를 비워 톱니 모양으로 되돌아올 뿐이다. 즉 이 조치는
"장애 주기를 66초 사이클로 바꾸고 그 사이클 안에서 살아남게 만든 것"이지 원인 제거가 아니다.
운영 관점에서 남는 위험은 다음과 같다.

- 66초마다 RSS가 컨테이너 상한(1GB)의 **50%까지 차오른다.** 같은 호스트의 다른 프로세스와
  경쟁하면 이 피크 구간에 스왑/지연이 발생할 수 있다.
- 부하가 지금보다 커져 증가 속도가 빨라지면, 회수 주기보다 증가가 빨라져 다시 종료될 수 있다.
- `MEMORY_LIMIT`의 허용 상한이 512MB이므로 **더 올릴 여지가 없다.** 다음 번엔 회피할 카드가 없다.

### 근본 해결 제안

1. `MemoryWorker`가 사이클마다 만든 객체의 참조를 명시적으로 끊는다
   (컬렉션 `clear()`/`del`, 또는 `collections.deque(maxlen=N)` 같은 유한 버퍼로 교체).
2. 누적 캐시가 의도된 동작이라면 **LRU 등 상한이 있는 캐시**로 바꿔 상한을 코드가 강제하게 한다.
3. 관제 측에서는 RSS 절대값이 아니라 **"연속 N회 단조 증가"** 를 경보 조건으로 삼는다.
   이번 사례처럼 8.3MB/s로 꾸준히 오르는 패턴은 임계값을 넘기 한참 전에 잡아낼 수 있다.
4. 배포 파이프라인에서 `MEMORY_LIMIT <= 256` 구성을 **기동 전에 거부**한다.
   이 값은 부트 시퀀스를 통과시켜 버리기 때문에(`All Boot Checks Passed!`)
   운영자가 잘못된 설정을 인지하지 못한 채 배포할 수 있다.
