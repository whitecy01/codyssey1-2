# [Bug] MULTI_THREAD_ENABLE=true 에서 Worker 스레드 2개가 락을 교차 점유하여 교착상태로 무한 대기

| 항목 | 값 |
| --- | --- |
| 장애 유형 | Deadlock (프로세스 무응답, PID 생존) |
| 대상 | `agent-leak-app` (Ubuntu 22.04 / aarch64 컨테이너) |
| 관측 일시 | 2026-08-20 18:48 ~ 18:53 (KST) |
| 재현율 | 2/2 (`MULTI_THREAD_ENABLE=true` 인 모든 실행에서 동일 지점에서 정지) |
| 증거 | [`evidence/deadlock-before/`](../evidence/deadlock-before) · [`evidence/deadlock-after/`](../evidence/deadlock-after) |

---

## 1. Description (현상 설명)

`MULTI_THREAD_ENABLE=true` 로 기동하면 부트 시퀀스를 정상 통과하고 워크로드가 시작되지만,
**약 10초 뒤 모든 활동이 멈춘다.** 앞선 두 장애(OOM/CPU)와 결정적으로 다른 점은
**프로세스가 죽지 않는다**는 것이다.

- `ps -ef` 에 PID가 그대로 살아 있다 (관측 종료 시점 경과 시간 `01:59`).
- 포트 15034는 여전히 `LISTEN` 상태다.
- 그런데 로그가 **108초 동안 단 한 줄도 늘지 않았다.**
- CPU·메모리 수치도 완전히 정지했다.

운영 관점에서 가장 위험한 형태다. **PID 존재 + 포트 LISTEN만 확인하는 헬스체크는
이 프로세스를 "정상"으로 판정한다.** 실제로는 아무 일도 처리하지 못하는 상태다.

부트 시퀀스의 리소스 점검 배너는 이 구성이 위험하다는 것을 **명시적으로 예고**했다.

```text
 [ MEMORY ] Limit: 512MB 		[ OK ]
 [ CPU    ] Limit: 30%  		[ OK ]
 [ THREAD ] Concurrency: True 		[ WARNING ]
--------------------------------------------------
 >>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.

[WARNING] [AgentWorker] Initializing concurrent transaction processors...
[WARNING] [System] CAUTION: Strict resource locking is enabled.
```

메모리·CPU 조건은 모두 `[ OK ]` 이므로, 이 실행에서 관측된 정지는
다른 두 장애와 무관하게 **동시성 설정 단독으로 발생한 것**임이 구성상 보장된다.
그럼에도 부트 시퀀스는 이 경고를 띄운 뒤 **기동을 그대로 진행**한다 —
경고가 곧 차단은 아니라는 점이 4장의 제안으로 이어진다.

---

## 2. Evidence & Logs (증거 자료)

### 2-1. 마지막 로그 지점 — 두 스레드가 서로의 자원을 요구하고 멈춘다

`evidence/deadlock-before/agent_app.log` 의 마지막 8줄이자, 이후 108초 동안 추가된 줄이 없는 지점이다.

```text
18:49:03,992 [INFO] [Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
18:49:03,992 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
18:49:03,993 [INFO] [AgentWorker][Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
18:49:03,993 [INFO] [AgentWorker] Waiting for worker threads to complete transactions...
18:49:03,994 [INFO] [AgentWorker][Worker-Thread-1] Processing critical data in Memory A...
18:49:03,995 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
18:49:03,995 [INFO] [AgentWorker][Worker-Thread-2] Establishing network connections in Pool B...
18:49:06,012 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
18:49:06,012 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
18:49:06,013 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
18:49:06,013 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
```

이 11줄만으로 교착 구조가 완전히 드러난다. 두 스레드가 **같은 밀리초에** 각자 첫 락을 잡고(`18:49:03,992` / `18:49:03,995`),
2초 뒤 동시에 두 번째 락을 요구하며 함께 멈춘다.

| 스레드 | 점유 중인 락 | 대기 중인 락 |
| --- | --- | --- |
| Worker-Thread-1 | `Shared_Memory_A` | `Socket_Pool_B` |
| Worker-Thread-2 | `Socket_Pool_B` | `Shared_Memory_A` |

```
   Worker-Thread-1 ──── holds ───→ [Shared_Memory_A]
          ▲                                │
          │                             wanted by
       wanted by                            │
          │                                 ▼
   [Socket_Pool_B] ←──── holds ──── Worker-Thread-2
```

서로가 상대방이 쥔 것을 기다린다. 어느 쪽도 먼저 놓지 않으므로 영원히 풀리지 않는다.
`AgentWorker` 본체는 `Waiting for worker threads to complete transactions...` 에서
두 스레드를 join 하고 있으므로 함께 멈춘다 — 그래서 프로세스 전체가 무응답이 된다.

### 2-2. PID 존재 증거 — 프로세스는 살아 있다

`evidence/deadlock-before/snapshots.txt` (t+120초 시점)

```text
$ ps -ef | grep agent-leak-app
agent-a+  7642  7641  0 18:48 pts/0    00:00:00 ./agent-leak-app
agent-a+  7643  7642  0 18:48 pts/0    00:00:00 ./agent-leak-app

$ ps -o pid,ppid,stat,%cpu,%mem,rss,nlwp,etime,comm -p 7643
  PID  PPID STAT %CPU %MEM   RSS NLWP     ELAPSED COMMAND
 7643  7642 SNl+  0.0  0.2 16524    3       01:59 agent-leak-app
```

`ELAPSED 01:59` — 2분째 살아 있다. `NLWP 3` — 스레드 3개(메인 + 워커 2개)가 그대로 있다.

포트도 계속 열려 있다.

```text
$ ss -tulnp | grep 15034
tcp   LISTEN 0      1            0.0.0.0:15034      0.0.0.0:*
```

### 2-3. 스레드 단위 정체 증거 — 세 스레드 모두 CPU 시간이 0

```text
$ ps -L -o pid,tid,stat,%cpu,wchan:20,comm -p 7643
  PID   TID STAT %CPU WCHAN                COMMAND
 7643  7643 SNl+  0.0 -                    agent-leak-app
 7643  7766 SNl+  0.0 -                    agent-leak-app
 7643  7767 SNl+  0.0 -                    agent-leak-app

$ top -H -b -n1 -p 7643
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
 7643 agent-a+  30  10  169728  16524   8460 S   0.0   0.2   0:00.02 agent-lea+
 7766 agent-a+  30  10  169728  16524   8460 S   0.0   0.2   0:00.00 agent-lea+
 7767 agent-a+  30  10  169728  16524   8460 S   0.0   0.2   0:00.00 agent-lea+
```

핵심 수치는 **워커 스레드 두 개(TID 7766, 7767)의 `TIME+`가 `0:00.00`** 이라는 점이다.
2분 동안 누적 CPU 시간이 0이다. 메인 스레드조차 `0:00.02`다. 세 스레드 모두 상태가 `S`(sleeping)이고,
**무한 루프로 도는 것이 아니라 잠들어 있다.** 이것이 "바쁜 대기(busy wait)"가 아니라
"락 대기(blocked on lock)"라는 결정적 근거다.

### 2-4. 자원 변화 정체 증거 — 관제 로그가 완전히 평평하다

`evidence/deadlock-before/monitor.log`. 왼쪽이 대상 프로세스, `|` 오른쪽이 시스템 전체다.

```text
[2026-08-20 18:50:46] PROCESS:agent-leak-app PID:7643 STATE:S CPU:0% MEM:1.5% RSS:16MB THREADS:3 | SYS_CPU:0.3% SYS_MEM:5.1% SYS_AVAIL:971MB SYS_LOAD:0.07 DISK:4%
[2026-08-20 18:50:48] PROCESS:agent-leak-app PID:7643 STATE:S CPU:0% MEM:1.5% RSS:16MB THREADS:3 | SYS_CPU:0.3% SYS_MEM:5.2% SYS_AVAIL:970MB SYS_LOAD:0.07 DISK:4%
[2026-08-20 18:50:50] PROCESS:agent-leak-app PID:7643 STATE:S CPU:0% MEM:1.5% RSS:16MB THREADS:3 | SYS_CPU:0.9% SYS_MEM:5.1% SYS_AVAIL:970MB SYS_LOAD:0.07 DISK:4%
[2026-08-20 18:50:52] PROCESS:agent-leak-app PID:7643 STATE:S CPU:0% MEM:1.5% RSS:16MB THREADS:3 | SYS_CPU:0.4% SYS_MEM:5.1% SYS_AVAIL:970MB SYS_LOAD:0.06 DISK:4%
[2026-08-20 18:50:54] PROCESS:agent-leak-app PID:7643 STATE:S CPU:0% MEM:1.5% RSS:16MB THREADS:3 | SYS_CPU:0.2% SYS_MEM:5.1% SYS_AVAIL:971MB SYS_LOAD:0.06 DISK:4%
```

`CPU:0% / RSS:16MB / THREADS:3` 이 **한 자리도 변하지 않고** 108초간 반복된다.
`/proc/7643/status` 최종 확인도 같다.

```text
State:   S (sleeping)
VmRSS:   16524 kB
Threads: 3
```

**시스템 쪽도 조용하다.** `SYS_CPU` 0.2~0.9%, `SYS_MEM` 5.1% 고정, `SYS_AVAIL` 970MB 유지.
게다가 `SYS_LOAD`(1분 부하 평균)는 교착이 시작된 직후 0.25에서 관측 종료 시점 0.06까지
**전반적으로 내려간다.** 교착된 프로세스는 실행 큐에 아무것도 올리지 않으므로
부하 평균이 시간이 갈수록 0에 수렴한다 — 관제 대시보드만 보면
"장애가 끝나고 시스템이 안정화되는 중"으로 읽히는 그림이다. 실제로는 그 반대다.

대조를 위해 같은 앱의 정상 동작 구간(`evidence/deadlock-after/monitor.log`)을 보면
프로세스 RSS는 41MB → 441MB로, 시스템 가용 메모리는 946MB → 545MB로 계속 움직인다.
**"수치가 변하지 않는 것" 자체가 이상 신호**임을 같은 프로세스의 두 실행으로 확인할 수 있다.

### 2-5. 로그 정체 시간 계측

관측 스크립트가 앱 로그 파일 크기를 2초마다 확인해 정체 시간을 계측했다.
(`evidence/deadlock-before/summary.txt`)

```text
관측 시간  : 120s
프로세스   : yes (관측 종료 시점까지 생존)
로그 정체  : 108s (마지막 기록 이후)
```

**전체 관측 시간 120초 중 108초(90%)가 무응답 구간**이었다.
같은 항목이 `deadlock-after` 에서는 **0초**다.

---

## 3. Root Cause Analysis (원인 분석)

### 3-1. 결함: 두 스레드가 락을 서로 반대 순서로 획득한다

교착의 원인은 **락 획득 순서의 불일치**다.

- Worker-Thread-1: `Shared_Memory_A` → `Socket_Pool_B` 순서로 요구
- Worker-Thread-2: `Socket_Pool_B` → `Shared_Memory_A` 순서로 요구

두 스레드가 각자 첫 락을 잡는 데 성공한 뒤(로그상 3ms 차로 둘 다 `LOCK ACQUIRED`)
두 번째 락을 요구하는 순간, 상대가 이미 쥐고 있어 둘 다 대기 상태로 들어간다.
**타이밍 문제가 아니라 순서 설계 자체의 결함**이므로 재현율이 100%다.

### 3-2. 교착상태 4대 조건 대조

Coffman의 네 조건이 모두 성립한다. 증거와 함께 대조한다.

| 조건 | 이번 사례에서의 성립 근거 |
| --- | --- |
| **상호 배제**(Mutual Exclusion) | `LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)` — 한 스레드가 쥐면 다른 스레드는 못 쓴다. 부트 로그의 `CAUTION: Strict resource locking is enabled` 도 배타 락임을 명시한다 |
| **점유 대기**(Hold and Wait) | Thread-1이 `Shared_Memory_A`를 **놓지 않은 채** `Socket_Pool_B`를 요구한다 (`Need resource [Socket_Pool_B] to finish job` → `WAITING`) |
| **비선점**(No Preemption) | 108초가 지나도 어느 락도 회수되지 않았다. 타임아웃이나 강제 해제 로그가 전혀 없다 |
| **순환 대기**(Circular Wait) | T1 → `Socket_Pool_B`(T2 보유) → T2 → `Shared_Memory_A`(T1 보유) → T1. 2-1의 다이어그램대로 고리가 닫힌다 |

네 조건 중 **하나만 깨도** 교착은 발생하지 않는다. 4장의 조치는 그중
"동시성 자체를 없애 상호 배제 경쟁을 제거"하는 방식이고, 근본 해결안은
"순환 대기를 깨는" 방식이다.

### 3-3. 관련 OS 동작 원리

- **커널은 교착상태를 감지하거나 해결해 주지 않는다.** 리눅스는 이른바 타조 알고리즘
  (ostrich algorithm) 접근을 취한다 — 사용자 공간 뮤텍스의 교착은 OS의 관심사가 아니다.
  그래서 프로세스는 **영원히** 그대로 있고, 운영자가 개입(`kill`)하기 전엔 회복되지 않는다.
- **`S`(interruptible sleep) 상태의 의미**: 락 대기 스레드는 futex 등에서 잠들어 있고
  스케줄러의 실행 큐에 올라가지 않는다. 그래서 CPU 시간이 0으로 고정된다.
  **교착은 자원을 태우지 않기 때문에 자원 기반 알람에 절대 걸리지 않는다.**
  이번 케이스의 CPU 0%·RSS 고정은 "장애가 없다"가 아니라 "장애의 지문"이다.
- **PID·포트 생존의 함정**: 리스닝 소켓은 커널이 유지하므로 애플리케이션 스레드가
  전부 멈춰도 `LISTEN` 상태는 유지된다. TCP 연결 수립까지도 커널의 accept 큐가
  받아줄 수 있다. **포트가 열려 있다는 사실은 애플리케이션이 살아 있다는 증거가 아니다.**

### 3-4. 관제 관점의 교훈 — 이 장애를 잡는 유일한 신호

세 장애를 통틀어 관제 설계에 주는 교훈이 가장 큰 케이스다.

| 헬스체크 방식 | 이 장애를 잡는가 | 근거 |
| --- | --- | --- |
| PID 존재 확인 | **못 잡는다** | 2-2, PID 7643 계속 생존 |
| 포트 LISTEN 확인 | **못 잡는다** | 2-2, 15034 계속 LISTEN |
| 프로세스 CPU/메모리 임계 알람 | **못 잡는다** | 2-4, CPU 0% / RSS 16MB 고정 |
| 시스템 전체 부하 알람 | **못 잡는다 (오히려 역효과)** | 2-4, `SYS_CPU` 0.2~0.9% · `SYS_LOAD`가 0.25→0.06으로 **하락**해 "안정화"로 오독된다 |
| **로그 진행 여부(정체 시간)** | **잡는다** | 2-5, 108초 정체 |
| **자원 수치의 변화량(Δ)** | **잡는다** | 2-4, 108초간 프로세스·시스템 양쪽 모두 Δ=0 |

즉 **"수치가 얼마인가"가 아니라 "수치가 변하고 있는가"** 를 봐야 한다.
관제 범위를 시스템 전체로 넓혀도 소용없다는 점이 중요하다 — 교착은 **자원을 안 쓰는 장애**라
범위를 넓힐수록 오히려 더 조용해 보인다.
그래서 이번 미션의 `monitor.sh`는 절대값과 함께 `STATE`·`THREADS`를 남기고,
관측 스크립트는 로그 파일 크기의 정체 시간을 별도로 계측하도록 만들었다.

---

## 4. Workaround & Verification (조치 및 검증)

### 조치

`MULTI_THREAD_ENABLE` 환경변수를 **true → false** 로 변경했다.
동시 트랜잭션 처리기를 띄우지 않으면 두 워커 스레드가 생성되지 않고,
락 경쟁 자체가 사라진다.

```bash
export MULTI_THREAD_ENABLE=false    # 1/0, yes/no 도 허용되나 명시적으로 false 사용
```

### Before & After

| 구분 | Before | After |
| --- | --- | --- |
| `MULTI_THREAD_ENABLE` | `true` | `false` |
| 부트 판정 | `Concurrency: True [ WARNING ]` + `SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.` | `Concurrency: False [ OK ]` + `SYSTEM STATUS: STABLE.` |
| 실행되는 워커 | `AgentWorker` (Worker-Thread-1/2) | `MemoryWorker` + `CpuWorker` |
| 마지막 로그 | `WAITING for [...]... (Status: BLOCKED)` 에서 정지 | 관측 종료까지 계속 기록 |
| **로그 정체 시간** | **108초 / 120초 (90%)** | **0초** |
| CPU (관제, 프로세스) | **교착 이후 0% 고정** | 0~2.5% 변동 |
| CPU (관제, 시스템) | 0.2~0.9% + `SYS_LOAD` 0.25→0.06 **하락** | 0.4~0.8% |
| RSS (관제, 프로세스) | **16MB 고정** | 41MB → 441MB (회수 1회 포함) |
| 가용 메모리 (시스템) | **971MB 고정** | 946MB → 545MB (프로세스 증가분과 일치) |
| 스레드 CPU 시간 | 워커 2개 모두 `TIME+ 0:00.00` | 해당 스레드 없음 |
| 프로세스 상태 | 살아 있으나 **무응답** | 살아 있고 **정상 처리 중** |
| 증거 | `evidence/deadlock-before/` | `evidence/deadlock-after/` |

`deadlock-after`의 로그는 관측 120초 내내 진행된다.

```text
2026-08-20 18:52:50,074 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
2026-08-20 18:52:51,082 [INFO] [CpuWorker] Current Load: 5.00%
2026-08-20 18:52:52,746 [INFO] [MemoryWorker] Current Heap: 400MB
2026-08-20 18:52:54,216 [INFO] [CpuWorker] Current Load: 5.68%
2026-08-20 18:52:55,787 [INFO] [MemoryWorker] Current Heap: 425MB
2026-08-20 18:52:57,350 [INFO] [CpuWorker] Current Load: 10.86%
```

**교착은 완전히 재현되지 않았다(0/1).** 정체 시간 108초 → 0초가 가장 명확한 지표다.

### 이 조치의 한계

- **동시성을 포기해 교착을 피한 것**이다. 트랜잭션 처리기가 단일화되므로
  처리량은 스레드 수만큼 떨어진다. 부하가 큰 운영 환경에는 그대로 적용하기 어렵다.
- 락 순서 결함은 코드에 그대로 남아 있다. 누군가 `MULTI_THREAD_ENABLE=true`로
  되돌리는 순간 **100% 재현**된다.
- `deadlock-after` 구성은 [01-oom.md](01-oom.md)의 메모리 누수를 그대로 갖고 있다.
  실제로 RSS가 466MB까지 올라 있다. **교착을 없앤 대신 다른 장애의 사정권에 들어간다.**

### 근본 해결 제안

1. **락 순서 전역 통일 (Lock Ordering)** — 순환 대기 조건을 깬다.
   모든 스레드가 `Shared_Memory_A` → `Socket_Pool_B` 순으로만 획득하도록 강제하면
   고리가 닫히지 않아 교착이 원천적으로 불가능해진다. 가장 표준적이고 비용이 낮은 해법이다.
2. **타임아웃 도입 (비선점 조건 완화)** — `lock.acquire(timeout=N)` 으로 바꾸고,
   실패 시 쥐고 있던 락을 모두 반납한 뒤 백오프 후 재시도한다.
   교착을 막지는 못하지만 **영구 정지를 일시 지연으로 바꿔** 자동 회복이 가능해진다.
3. **점유 대기 제거** — 필요한 자원을 한 번에 모두 확보하거나, 못 얻으면 아무것도 쥐지 않는다.
4. **헬스체크 교체** — 3-4의 표대로, PID·포트 기반 헬스체크를 **애플리케이션 응답성 기반**으로
   바꾼다. 구체적으로는 (a) 15034 포트에 실제 요청을 보내 응답을 확인하거나,
   (b) 앱 로그의 마지막 기록 시각을 감시해 N초 이상 정체 시 경보한다.
   현재 구성으로는 교착 상태의 프로세스가 모든 헬스체크를 통과한다.
