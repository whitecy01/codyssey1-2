#!/bin/bash
# monitor.sh - agent-leak-app 관제 스크립트 (프로세스 지표 + 시스템 전체 지표)
#
# 사용법: monitor.sh [-i 간격초] [-d 최대초] [-o 로그파일] [-p 프로세스명] [-P PID]
#
# 무엇을 재는가
#   과제 요구사항은 두 방향을 동시에 요구한다.
#     - "시스템 전체 부하가 아닌 특정 프로세스의 CPU 사용률을 식별" (요구사항 3장)
#     - "메모리 누수가 시스템 전체에 미치는 영향을 설명"           (미션 목표)
#   그래서 한 줄에 두 그룹을 나란히 남기되 '|' 로 구분하고 시스템 쪽은 SYS_ 접두어를 붙인다.
#   왼쪽(PROCESS~THREADS) = 대상 프로세스 / 오른쪽(SYS_*~DISK) = 호스트 전체.
#   이렇게 해야 "프로세스는 1%인데 시스템은 12%" 같은 대비를 한 줄에서 읽을 수 있다.
#
# CPU 사용률은 ps 의 %CPU 를 쓰지 않는다. ps %CPU 는 프로세스 생애 전체의 평균이라
# "급상승 구간"이 평균에 묻혀 보이지 않기 때문이다. 대신 /proc/<pid>/stat 의
# utime+stime 을 간격마다 차분해 구간 사용률을 계산한다. 시스템 CPU 도 같은 방식으로
# /proc/stat 을 차분한다.

INTERVAL=2
DURATION=0                       # 0 = 프로세스가 사라질 때까지
PROC_NAME="agent-leak-app"
TARGET_PID=""                    # 비우면 이름으로 직접 찾는다
LOG_FILE="${AGENT_LOG_DIR:-/var/log/agent-app}/monitor.log"

while getopts "i:d:o:p:P:" opt; do
    case "$opt" in
        i) INTERVAL="$OPTARG" ;;
        d) DURATION="$OPTARG" ;;
        o) LOG_FILE="$OPTARG" ;;
        p) PROC_NAME="$OPTARG" ;;
        P) TARGET_PID="$OPTARG" ;;
        *) echo "usage: $0 [-i sec] [-d sec] [-o logfile] [-p procname] [-P pid]"; exit 1 ;;
    esac
done

CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)

# 메모리 지표의 분모.
# 컨테이너 안에서도 /proc/meminfo 는 호스트 전체 메모리를 보여준다. cgroup 제한이
# 걸려 있는데 이를 무시하면 512MB 점유가 "6%" 로 찍혀 실제 압박도가 통째로 묻힌다.
# cgroup v2 가 있으면 memory.max/memory.current 를, 없으면 /proc/meminfo 를 쓴다.
CG_MAX_RAW=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
if [ "$CG_MAX_RAW" != "max" ] && [ -n "$CG_MAX_RAW" ]; then
    USE_CGROUP=1
    MEM_TOTAL_KB=$((CG_MAX_RAW / 1024))
    MEM_SCOPE="cgroup"
else
    USE_CGROUP=0
    MEM_TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    MEM_SCOPE="host"
fi

mkdir -p "$(dirname "$LOG_FILE")"

# /proc/<pid>/stat 의 utime(14)+stime(15). comm 필드에 공백/괄호가 들어갈 수 있으므로
# 마지막 ')' 뒤부터 필드를 센다.
cpu_ticks() {
    awk '{ s=substr($0, index($0,")")+2); split(s,f," "); print f[12]+f[13] }' \
        "/proc/$1/stat" 2>/dev/null
}

# /proc/stat 의 첫 cpu 행 → "총 tick, idle tick" 두 값을 뱉는다.
# idle 은 4번째 필드(idle) + 5번째(iowait) 를 합쳐야 실제 놀고 있던 시간이 된다.
sys_cpu_ticks() {
    awk '/^cpu /{ total=0; for(i=2;i<=NF;i++) total+=$i; print total, $5+$6; exit }' /proc/stat
}

# PID 탐색은 pgrep -f 가 아니라 -x(실행 파일 이름 완전 일치)를 쓴다.
# -f 는 명령줄 전체를 훑기 때문에 앱을 띄운 su/script 래퍼까지 잡혀버린다.
# 또한 이 앱은 PyInstaller 형태라 부모/자식 두 프로세스로 뜨고, 워커 스레드와
# 힙이 올라가는 쪽은 나중에 뜨는 자식이므로 마지막 PID 를 대상으로 삼는다.
find_pid() {
    pgrep -x "$PROC_NAME" 2>/dev/null | tail -1
}

if [ -n "$TARGET_PID" ]; then
    PID="$TARGET_PID"
else
    PID=""
    for _ in $(seq 1 30); do      # 앱 부트 시퀀스를 최대 30초 기다린다
        PID=$(find_pid)
        [ -n "$PID" ] && break
        sleep 1
    done
fi

if [ -z "$PID" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROCESS:${PROC_NAME} STATUS:NOT_FOUND" | tee -a "$LOG_FILE"
    exit 1
fi

NPROC=$(nproc 2>/dev/null || echo 1)
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR START PROCESS:${PROC_NAME} PID:${PID} INTERVAL:${INTERVAL}s"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SCOPE cpu_cores=${NPROC} mem_scope=${MEM_SCOPE} mem_total=$((MEM_TOTAL_KB / 1024))MB"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] LEGEND 좌측(PROCESS~THREADS)=대상 프로세스 / 우측(SYS_*~DISK)=시스템 전체"
} | tee -a "$LOG_FILE"

PREV_TICKS=$(cpu_ticks "$PID")
read -r PREV_SYS_TOTAL PREV_SYS_IDLE <<< "$(sys_cpu_ticks)"
ELAPSED=0

while true; do
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))

    if [ ! -d "/proc/$PID" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROCESS:${PROC_NAME} PID:${PID} STATUS:TERMINATED (after ${ELAPSED}s)" \
            | tee -a "$LOG_FILE"
        exit 0
    fi

    # ---------- 대상 프로세스 지표 ----------
    CUR_TICKS=$(cpu_ticks "$PID")
    [ -z "$CUR_TICKS" ] && CUR_TICKS="$PREV_TICKS"
    DELTA=$((CUR_TICKS - PREV_TICKS))
    PREV_TICKS="$CUR_TICKS"
    # (소비 tick / tick/초) / 경과초 * 100  → 코어 1개 기준 점유율(%)
    CPU=$(echo "scale=1; ${DELTA} * 100 / ${CLK_TCK} / ${INTERVAL}" | bc | sed 's/^\./0./')

    RSS_KB=$(awk '/^VmRSS:/{print $2}' "/proc/$PID/status" 2>/dev/null)
    RSS_KB="${RSS_KB:-0}"
    RSS_MB=$((RSS_KB / 1024))
    MEM=$(echo "scale=1; ${RSS_KB} * 100 / ${MEM_TOTAL_KB}" | bc | sed 's/^\./0./')

    THREADS=$(awk '/^Threads:/{print $2}' "/proc/$PID/status" 2>/dev/null)
    STATE=$(awk '/^State:/{print $2}' "/proc/$PID/status" 2>/dev/null)

    # 위의 /proc 존재 검사를 통과한 뒤에도 status 를 읽는 사이에 프로세스가 죽을 수 있다.
    # (이 앱은 임계 도달 시 즉시 SIGKILL 되므로 실제로 이 창에 걸린다.)
    # 그대로 두면 STATE 가 비고 RSS 가 0 인 가짜 줄이 증거에 남으므로, 종료로 처리한다.
    if [ -z "$STATE" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROCESS:${PROC_NAME} PID:${PID} STATUS:TERMINATED (after ${ELAPSED}s)" \
            | tee -a "$LOG_FILE"
        exit 0
    fi

    # ---------- 시스템 전체 지표 ----------
    read -r CUR_SYS_TOTAL CUR_SYS_IDLE <<< "$(sys_cpu_ticks)"
    SYS_TOTAL_D=$((CUR_SYS_TOTAL - PREV_SYS_TOTAL))
    SYS_IDLE_D=$((CUR_SYS_IDLE - PREV_SYS_IDLE))
    PREV_SYS_TOTAL="$CUR_SYS_TOTAL"; PREV_SYS_IDLE="$CUR_SYS_IDLE"
    if [ "$SYS_TOTAL_D" -gt 0 ]; then
        SYS_CPU=$(echo "scale=1; (${SYS_TOTAL_D} - ${SYS_IDLE_D}) * 100 / ${SYS_TOTAL_D}" | bc | sed 's/^\./0./')
    else
        SYS_CPU="0.0"
    fi

    if [ "$USE_CGROUP" = "1" ]; then
        SYS_USED_KB=$(( $(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0) / 1024 ))
    else
        SYS_AVAIL_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
        SYS_USED_KB=$((MEM_TOTAL_KB - SYS_AVAIL_KB))
    fi
    SYS_MEM=$(echo "scale=1; ${SYS_USED_KB} * 100 / ${MEM_TOTAL_KB}" | bc | sed 's/^\./0./')
    SYS_AVAIL_MB=$(( (MEM_TOTAL_KB - SYS_USED_KB) / 1024 ))

    SYS_LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    DISK=$(df / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')

    LINE="[$(date '+%Y-%m-%d %H:%M:%S')] PROCESS:${PROC_NAME} PID:${PID} STATE:${STATE}"
    LINE="${LINE} CPU:${CPU}% MEM:${MEM}% RSS:${RSS_MB}MB THREADS:${THREADS}"
    LINE="${LINE} | SYS_CPU:${SYS_CPU}% SYS_MEM:${SYS_MEM}% SYS_AVAIL:${SYS_AVAIL_MB}MB SYS_LOAD:${SYS_LOAD} DISK:${DISK}%"
    echo "$LINE" | tee -a "$LOG_FILE"

    if [ "$DURATION" -gt 0 ] && [ "$ELAPSED" -ge "$DURATION" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR END (duration ${DURATION}s reached, process ALIVE)" \
            | tee -a "$LOG_FILE"
        exit 0
    fi
done
