#!/bin/bash
# run-case.sh - 장애 시나리오 1건을 실행하고 증거를 수집한다.
#
# 사용법: run-case.sh <case> [최대관측초]
#   oom-before / oom-mid / oom-after
#   cpu-before / cpu-after
#   deadlock-before / deadlock-after
#
# 하는 일
#   1) 시나리오별 환경변수(MEMORY_LIMIT / CPU_MAX_OCCUPY / MULTI_THREAD_ENABLE) 설정
#   2) 일반 사용자(agent-admin) 로 앱 실행 → 실행 로그를 파일로 캡처
#   3) monitor.sh 를 붙여 프로세스 자원 추이 기록
#   4) ps / ps -L / top -H / ss 스냅샷 수집
#   5) 종료 사유(자체 종료 / 시그널 / 생존)를 요약 파일에 기록
set -u

APP_USER="agent-admin"
AGENT_HOME="/home/${APP_USER}/agent-app"
APP_NAME="agent-leak-app"
EVIDENCE_DIR="/evidence"

CASE="${1:-}"

# 시나리오 매트릭스.
# 이 앱은 "권장 범위를 벗어난 환경변수" 하나를 골라 그에 맞는 워크로드를 돌린다.
#   MEMORY_LIMIT < 256      → MemoryWorker (힙 누수 → MemoryGuard 자체 종료)
#   CPU_MAX_OCCUPY > 50     → CpuWorker    (부하 상승 → Watchdog SIGTERM)
#   MULTI_THREAD_ENABLE=true→ AgentWorker  (교차 락 → 교착상태)
# 따라서 한 장애만 재현하려면 나머지 두 변수는 권장 범위 안에 고정해 두어야 한다.
case "$CASE" in
    oom-before)      MEMORY_LIMIT=50;  CPU_MAX_OCCUPY=30;  MULTI_THREAD_ENABLE=false; DEF_SEC=120 ;;
    oom-mid)         MEMORY_LIMIT=256; CPU_MAX_OCCUPY=30;  MULTI_THREAD_ENABLE=false; DEF_SEC=180 ;;
    oom-after)       MEMORY_LIMIT=512; CPU_MAX_OCCUPY=30;  MULTI_THREAD_ENABLE=false; DEF_SEC=180 ;;
    cpu-before)      MEMORY_LIMIT=512; CPU_MAX_OCCUPY=100; MULTI_THREAD_ENABLE=false; DEF_SEC=120 ;;
    cpu-after)       MEMORY_LIMIT=512; CPU_MAX_OCCUPY=30;  MULTI_THREAD_ENABLE=false; DEF_SEC=120 ;;
    deadlock-before) MEMORY_LIMIT=512; CPU_MAX_OCCUPY=30;  MULTI_THREAD_ENABLE=true;  DEF_SEC=120 ;;
    deadlock-after)  MEMORY_LIMIT=512; CPU_MAX_OCCUPY=30;  MULTI_THREAD_ENABLE=false; DEF_SEC=120 ;;
    *) echo "usage: $0 <oom-before|oom-mid|oom-after|cpu-before|cpu-after|deadlock-before|deadlock-after> [maxsec]"; exit 1 ;;
esac
MAX_SEC="${2:-$DEF_SEC}"

OUT_DIR="${EVIDENCE_DIR}/${CASE}"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
# 앱은 일반 사용자로 뜨는데 이 스크립트는 root 로 돈다.
# 증거 디렉터리 소유자를 앱 계정으로 넘겨야 pty 로그를 앱이 직접 쓸 수 있다.
chown "${APP_USER}" "$OUT_DIR"
APP_LOG="${OUT_DIR}/app-stdout.log"       # 터미널 출력 (부트 시퀀스 + 종료 배너)
AGENT_LOG="${OUT_DIR}/agent_app.log"      # 앱이 직접 남기는 로그 파일
MON_LOG="${OUT_DIR}/monitor.log"
SNAP="${OUT_DIR}/snapshots.txt"
SUMMARY="${OUT_DIR}/summary.txt"

# 이전 시나리오의 잔여 프로세스 정리
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1
# 앱 로그 파일을 케이스마다 새로 시작시킨다 (이전 실행분 섞임 방지).
# 이 스크립트는 root 로 도는데, 그냥 truncate 하면 파일이 root 소유로 다시 생겨
# 일반 사용자로 뜬 앱이 자기 로그를 못 쓰게 된다. 소유자를 반드시 되돌려 준다.
APP_RUNTIME_LOG="/var/log/agent-app/agent_app.log"
: > "$APP_RUNTIME_LOG" 2>/dev/null || true
chown "${APP_USER}" "$APP_RUNTIME_LOG" 2>/dev/null || true

echo "============================================"
echo "  CASE: ${CASE}"
echo "  MEMORY_LIMIT=${MEMORY_LIMIT}  CPU_MAX_OCCUPY=${CPU_MAX_OCCUPY}  MULTI_THREAD_ENABLE=${MULTI_THREAD_ENABLE}"
echo "  최대 관측 시간: ${MAX_SEC}s"
echo "============================================"

{
    echo "=== CASE: ${CASE} ==="
    echo "시작       : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "실행 계정  : ${APP_USER} (uid=$(id -u ${APP_USER}), non-root)"
    echo "MEMORY_LIMIT        = ${MEMORY_LIMIT}"
    echo "CPU_MAX_OCCUPY      = ${CPU_MAX_OCCUPY}"
    echo "MULTI_THREAD_ENABLE = ${MULTI_THREAD_ENABLE}"
    echo ""
} > "$SUMMARY"

START_EPOCH=$(date +%s)

# 앱 실행.
# script -qfec 로 의사 터미널(pty) 을 붙인다. 파이프로 연결하면 stdout 이
# 블록 버퍼링으로 바뀌는데, 이 앱은 종료 배너("SELF-TERMINATED" 등)를 출력한 직후
# 스스로 SIGKILL 되므로 버퍼에 남은 마지막 줄이 통째로 유실된다. pty 를 붙이면
# 줄 단위로 흘러나와 종료 배너까지 증거로 남는다. (-f = 매 줄 flush)
su "${APP_USER}" -c "
export AGENT_HOME=${AGENT_HOME}
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=${AGENT_HOME}/upload_files
export AGENT_KEY_PATH=${AGENT_HOME}/api_keys
export AGENT_LOG_DIR=/var/log/agent-app
export MEMORY_LIMIT=${MEMORY_LIMIT}
export CPU_MAX_OCCUPY=${CPU_MAX_OCCUPY}
export MULTI_THREAD_ENABLE=${MULTI_THREAD_ENABLE}
cd ${AGENT_HOME}
exec script -qfec ./${APP_NAME} ${APP_LOG}
" > /dev/null 2>&1 &

# 실제 관측 대상 PID 확보.
# 이 앱은 PyInstaller 형태라 부모(런처) + 자식(실제 워크로드) 두 프로세스로 뜬다.
# 힙이 자라고 스레드가 생기는 쪽은 자식이므로, 두 프로세스가 모두 뜰 때까지 기다린 뒤
# VmRSS 가 가장 큰 프로세스를 대상으로 고른다. (이름만 보고 고르면 런처를 물기 쉽다)
resolve_app_pid() {
    local pids best best_rss rss p
    for _ in $(seq 1 30); do
        pids=$(pgrep -x "$APP_NAME" 2>/dev/null)
        if [ -n "$pids" ]; then
            sleep 1                       # 자식이 뜨는 시간을 한 틱 더 준다
            pids=$(pgrep -x "$APP_NAME" 2>/dev/null)
            best=""; best_rss=-1
            for p in $pids; do
                rss=$(awk '/^VmRSS:/{print $2}' "/proc/$p/status" 2>/dev/null)
                rss="${rss:-0}"
                if [ "$rss" -gt "$best_rss" ]; then best_rss="$rss"; best="$p"; fi
            done
            echo "$best"
            return 0
        fi
        sleep 1
    done
    echo ""
}

APP_PID=$(resolve_app_pid)

if [ -z "$APP_PID" ]; then
    echo "[ERROR] 앱이 기동하지 않았습니다. 부트 시퀀스 로그를 확인하세요." | tee -a "$SUMMARY"
    cat "$APP_LOG" 2>/dev/null
    exit 1
fi

echo "APP PID    : ${APP_PID}" | tee -a "$SUMMARY"

# 관제 시작. 대상 PID 를 명시적으로 넘긴다 — monitor.sh 가 스스로 이름으로 찾게 두면
# 런처/워커 중 어느 쪽을 물지 실행마다 달라져 관제 로그와 스냅샷의 PID 가 어긋난다.
/opt/scripts/monitor.sh -i 2 -d "$MAX_SEC" -o "$MON_LOG" -p "$APP_NAME" -P "$APP_PID" > /dev/null 2>&1 &
MON_PID=$!

# ------------------------------------------------
# 관측 루프: 프로세스/스레드 스냅샷을 주기적으로 남긴다
# ------------------------------------------------
SNAP_INTERVAL=20
NEXT_SNAP=0
LAST_LOG_SIZE=-1
STALL_SEC=0

take_snapshot() {
    {
        echo "----- snapshot t+${1}s ($(date '+%Y-%m-%d %H:%M:%S')) -----"
        echo "\$ ps -ef | grep agent-leak-app"
        ps -ef | grep "[a]gent-leak-app" || echo "(없음)"
        echo ""
        echo "\$ ps -o pid,ppid,stat,%cpu,%mem,rss,nlwp,etime,comm -p ${APP_PID}"
        ps -o pid,ppid,stat,%cpu,%mem,rss,nlwp,etime,comm -p "${APP_PID}" 2>/dev/null
        echo ""
        echo "\$ ps -L -o pid,tid,stat,%cpu,wchan:20,comm -p ${APP_PID}"
        ps -L -o pid,tid,stat,%cpu,wchan:20,comm -p "${APP_PID}" 2>/dev/null
        echo ""
        echo "\$ top -H -b -n1 -p ${APP_PID}"
        top -H -b -n1 -p "${APP_PID}" 2>/dev/null | tail -n +5
        echo ""
        echo "\$ ss -tulnp | grep 15034"
        ss -tulnp 2>/dev/null | grep 15034 || echo "(LISTEN 없음)"
        echo ""
    } >> "$SNAP"
}

while true; do
    ELAPSED=$(( $(date +%s) - START_EPOCH ))

    if [ ! -d "/proc/${APP_PID}" ]; then
        echo "[$(date '+%H:%M:%S')] 프로세스 종료 감지 (경과 ${ELAPSED}s)"
        break
    fi

    if [ "$ELAPSED" -ge "$NEXT_SNAP" ]; then
        take_snapshot "$ELAPSED"
        NEXT_SNAP=$((ELAPSED + SNAP_INTERVAL))
    fi

    # 앱 로그 파일이 자라지 않는 시간 = 무응답(정체) 시간. 데드락 판정 근거가 된다.
    CUR_LOG_SIZE=$(stat -c%s /var/log/agent-app/agent_app.log 2>/dev/null || echo 0)
    if [ "$CUR_LOG_SIZE" = "$LAST_LOG_SIZE" ]; then
        STALL_SEC=$((STALL_SEC + 2))
    else
        STALL_SEC=0
        LAST_LOG_SIZE="$CUR_LOG_SIZE"
    fi

    if [ "$ELAPSED" -ge "$MAX_SEC" ]; then
        echo "[$(date '+%H:%M:%S')] 최대 관측 시간 도달 (${MAX_SEC}s) - 프로세스 생존 중"
        break
    fi
    sleep 2
done

END_EPOCH=$(date +%s)
TOTAL=$((END_EPOCH - START_EPOCH))

if [ -d "/proc/${APP_PID}" ]; then
    ALIVE="yes (관측 종료 시점까지 생존)"
    take_snapshot "$TOTAL"
    {
        echo "----- FINAL (무응답/생존 판정) -----"
        echo "\$ cat /proc/${APP_PID}/status | egrep 'State|Threads|VmRSS'"
        egrep 'State|Threads|VmRSS' "/proc/${APP_PID}/status" 2>/dev/null
        echo ""
        echo "앱 로그 정체 시간: ${STALL_SEC}s (마지막 기록 이후 갱신 없음)"
    } >> "$SNAP"
    pkill -x "$APP_NAME" 2>/dev/null || true
else
    ALIVE="no (종료됨)"
fi

kill "$MON_PID" 2>/dev/null || true
cp /var/log/agent-app/agent_app.log "$AGENT_LOG" 2>/dev/null || true

{
    echo ""
    echo "종료       : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "관측 시간  : ${TOTAL}s"
    echo "프로세스   : ${ALIVE}"
    echo "로그 정체  : ${STALL_SEC}s (마지막 기록 이후)"
    echo ""
    echo "=== 터미널 출력 마지막 15줄 ==="
    tail -15 "$APP_LOG" 2>/dev/null
    echo ""
    echo "=== 앱 로그(agent_app.log) 마지막 10줄 ==="
    tail -10 "$AGENT_LOG" 2>/dev/null
    echo ""
    echo "=== 관제 로그(monitor.log) 마지막 10줄 ==="
    tail -10 "$MON_LOG" 2>/dev/null
} >> "$SUMMARY"

echo ""
cat "$SUMMARY"
echo ""
echo "증거 파일: ${OUT_DIR}/{app-stdout.log,agent_app.log,monitor.log,snapshots.txt,summary.txt}"
