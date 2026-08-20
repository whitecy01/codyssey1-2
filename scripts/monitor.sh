#!/bin/bash
# monitor.sh - agent-leak-app 프로세스 단위 관제 스크립트
#
# 사용법: monitor.sh [-i 간격초] [-d 최대초] [-o 로그파일] [-p 프로세스명] [-P PID]
#
# 시스템 전체 부하가 아니라 "대상 프로세스"의 자원 추이를 남기는 것이 목적이다.
# (problem.md 3장: 시스템 전체 부하가 아닌 특정 프로세스의 사용률 구간을 식별)
#
# CPU 사용률은 ps 의 %CPU 를 쓰지 않는다. ps %CPU 는 프로세스 생애 전체의 평균이라
# "급상승 구간"이 평균에 묻혀 보이지 않기 때문이다. 대신 /proc/<pid>/stat 의
# utime+stime 을 간격마다 차분해 구간 사용률을 계산한다.

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

# MEM% 의 분모: 컨테이너에 메모리 제한(cgroup v2 memory.max)이 걸려 있으면 그 값을,
# 없으면 /proc/meminfo 의 MemTotal 을 쓴다. 컨테이너 안에서도 /proc/meminfo 는
# 호스트 전체 메모리를 보여주기 때문에, 제한을 무시하면 점유율이 실제보다 낮게 나온다.
CG_MAX=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
if [ "$CG_MAX" != "max" ] && [ -n "$CG_MAX" ]; then
    MEM_TOTAL_KB=$((CG_MAX / 1024))
else
    MEM_TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
fi

mkdir -p "$(dirname "$LOG_FILE")"

# /proc/<pid>/stat 의 utime(14)+stime(15). comm 필드에 공백/괄호가 들어갈 수 있으므로
# 마지막 ')' 뒤부터 필드를 센다.
cpu_ticks() {
    awk '{ s=substr($0, index($0,")")+2); split(s,f," "); print f[12]+f[13] }' \
        "/proc/$1/stat" 2>/dev/null
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR START PROCESS:${PROC_NAME} PID:${PID} INTERVAL:${INTERVAL}s" \
    | tee -a "$LOG_FILE"

PREV_TICKS=$(cpu_ticks "$PID")
ELAPSED=0

while true; do
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))

    if [ ! -d "/proc/$PID" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROCESS:${PROC_NAME} PID:${PID} STATUS:TERMINATED (after ${ELAPSED}s)" \
            | tee -a "$LOG_FILE"
        exit 0
    fi

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
    DISK=$(df / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')

    LINE="[$(date '+%Y-%m-%d %H:%M:%S')] PROCESS:${PROC_NAME} PID:${PID} STATE:${STATE}"
    LINE="${LINE} CPU:${CPU}% MEM:${MEM}% RSS:${RSS_MB}MB THREADS:${THREADS} DISK:${DISK}%"
    echo "$LINE" | tee -a "$LOG_FILE"

    if [ "$DURATION" -gt 0 ] && [ "$ELAPSED" -ge "$DURATION" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR END (duration ${DURATION}s reached, process ALIVE)" \
            | tee -a "$LOG_FILE"
        exit 0
    fi
done
