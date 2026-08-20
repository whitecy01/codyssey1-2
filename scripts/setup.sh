#!/bin/bash
# setup.sh - agent-leak-app 부트 조건 구성 (컨테이너 ENTRYPOINT)
#
# problem.md "1. 사전 준비 사항" 표의 조건을 그대로 충족시킨다.
# 앱 실행 자체는 여기서 하지 않는다. 장애 시나리오마다 환경변수가 달라야 하므로
# 실행은 run-case.sh 가 담당하고, 이 스크립트는 환경만 만든 뒤 컨테이너를 유지한다.
set -e

APP_USER="agent-admin"
AGENT_HOME="/home/${APP_USER}/agent-app"
AGENT_LOG_DIR="/var/log/agent-app"
EVIDENCE_DIR="/evidence"

# 아키텍처에 맞는 바이너리 선택 (에뮬레이션 없이 네이티브 실행)
case "$(uname -m)" in
    aarch64|arm64) APP_SRC="/opt/dist/agent-leak-app-arm64" ;;
    *)             APP_SRC="/opt/dist/agent-leak-app-x86"   ;;
esac
APP_NAME="agent-leak-app"

echo "============================================"
echo "  agent-leak-app 부트 조건 구성 (arch: $(uname -m))"
echo "============================================"

# ------------------------------------------------
# [1] 실행 계정: root 가 아닌 일반 사용자
# ------------------------------------------------
groupadd -f agent-core
useradd -m -s /bin/bash -G agent-core "${APP_USER}" 2>/dev/null || true

# ------------------------------------------------
# [2] 디렉터리: upload_files / api_keys / 로그 디렉터리
#     로그 디렉터리는 "존재 + 쓰기 권한" 이 조건이므로 소유자를 앱 계정으로 맞춘다.
# ------------------------------------------------
mkdir -p "${AGENT_HOME}/upload_files" \
         "${AGENT_HOME}/api_keys" \
         "${AGENT_HOME}/bin" \
         "${AGENT_LOG_DIR}" \
         "${EVIDENCE_DIR}"

# ------------------------------------------------
# [3] secret.key: 내용이 정확히 agent_api_key_test 여야 한다
# ------------------------------------------------
printf 'agent_api_key_test' > "${AGENT_HOME}/api_keys/secret.key"

# ------------------------------------------------
# [4] 바이너리 / 관제 스크립트 배포
# ------------------------------------------------
cp "${APP_SRC}" "${AGENT_HOME}/${APP_NAME}"
cp /opt/scripts/monitor.sh "${AGENT_HOME}/bin/monitor.sh"
chmod +x "${AGENT_HOME}/${APP_NAME}" "${AGENT_HOME}/bin/monitor.sh"

chown -R "${APP_USER}:agent-core" "${AGENT_HOME}" "${AGENT_LOG_DIR}" "${EVIDENCE_DIR}"
chmod 750 "${AGENT_HOME}"
chmod 700 "${AGENT_HOME}/api_keys"
chmod 600 "${AGENT_HOME}/api_keys/secret.key"
chmod 775 "${AGENT_LOG_DIR}" "${EVIDENCE_DIR}"

# ------------------------------------------------
# [5] 환경변수: 로그인 셸(.bashrc)과 시스템 전역(/etc/environment) 양쪽에 기록
#     MEMORY_LIMIT / CPU_MAX_OCCUPY / MULTI_THREAD_ENABLE 은 시나리오별로
#     run-case.sh 가 덮어쓰므로 여기서는 기준값(Before)만 설정한다.
# ------------------------------------------------
ENV_BLOCK=$(cat <<ENVEOF
export AGENT_HOME=${AGENT_HOME}
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=${AGENT_HOME}/upload_files
export AGENT_KEY_PATH=${AGENT_HOME}/api_keys
export AGENT_LOG_DIR=${AGENT_LOG_DIR}
export MEMORY_LIMIT=50
export CPU_MAX_OCCUPY=10
export MULTI_THREAD_ENABLE=true
ENVEOF
)

if ! grep -q "AGENT_HOME" "/home/${APP_USER}/.bashrc" 2>/dev/null; then
    printf '\n# agent-leak-app environment\n%s\n' "${ENV_BLOCK}" \
        >> "/home/${APP_USER}/.bashrc"
fi
# /etc/environment 는 export 키워드를 파싱하지 못하므로 KEY=VALUE 형태로 넣는다.
if ! grep -q "AGENT_HOME" /etc/environment 2>/dev/null; then
    printf '%s\n' "${ENV_BLOCK}" | sed 's/^export //' >> /etc/environment
fi

echo ""
echo "  실행 계정      : ${APP_USER} (uid=$(id -u ${APP_USER}), non-root)"
echo "  AGENT_HOME     : ${AGENT_HOME}"
echo "  AGENT_PORT     : 15034"
echo "  AGENT_UPLOAD_DIR : ${AGENT_HOME}/upload_files"
echo "  AGENT_KEY_PATH : ${AGENT_HOME}/api_keys"
echo "  AGENT_LOG_DIR  : ${AGENT_LOG_DIR}"
echo "  secret.key     : $(cat ${AGENT_HOME}/api_keys/secret.key)"
echo ""
ls -la "${AGENT_HOME}"
echo ""
echo "============================================"
echo "  준비 완료. 시나리오 실행 명령:"
echo "    docker exec agent-leak /opt/scripts/run-case.sh oom-before"
echo "    docker exec agent-leak /opt/scripts/run-case.sh cpu-before"
echo "    docker exec agent-leak /opt/scripts/run-case.sh deadlock-before"
echo "============================================"

# 컨테이너 유지
tail -f /dev/null
