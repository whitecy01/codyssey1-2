#!/bin/bash
# run.sh - 이미지 빌드 + 컨테이너 기동 (+ 선택적으로 전체 시나리오 실행)
#
# 사용법
#   ./run.sh          이미지 빌드 후 컨테이너를 백그라운드로 띄운다
#   ./run.sh --all    위 작업 후 6개 장애 시나리오를 순차 실행하고 evidence/ 로 회수한다

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="codyssey-leak"
CONTAINER_NAME="agent-leak"

RUN_ALL=0
case "${1:-}" in
    --all) RUN_ALL=1 ;;
    "")    ;;
    *)     echo "사용법: $0 [--all]"; exit 1 ;;
esac

# 호스트 아키텍처에 맞춰 빌드 플랫폼 결정 (에뮬레이션 회피)
case "$(uname -m)" in
    arm64|aarch64) PLATFORM="linux/arm64" ;;
    *)             PLATFORM="linux/amd64" ;;
esac

echo "============================================"
echo "  Codyssey Mission 1-2: 시스템 장애 분석"
echo "  빌드 플랫폼: ${PLATFORM} (host: $(uname -m))"
echo "============================================"

# 제공된 앱 바이너리 존재 확인 (.gitignore 대상이라 클론 직후에는 없음)
for f in agent-app-leak/agent-leak-app-arm64 agent-app-leak/agent-leak-app-x86; do
    if [ ! -f "${PROJECT_DIR}/${f}" ]; then
        echo "ERROR: ${f} 가 없습니다."
        echo "       과제에서 제공된 바이너리 2개를 ${PROJECT_DIR}/agent-app-leak/ 에 넣어주세요."
        exit 1
    fi
done

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

echo ""
echo "Docker 이미지 빌드 중..."
docker build --platform "${PLATFORM}" -t "${IMAGE_NAME}" "${PROJECT_DIR}"

# --memory=1g : 컨테이너 메모리 상한. MEMORY_LIMIT 최대값(512MB)의 2배로 잡아
#               앱의 MemoryGuard 가 먼저 동작하도록 하면서도, 관제 로그의 MEM%
#               분모가 호스트 전체 메모리(수십 GB)가 되어 점유율이 묻히는 것을 막는다.
echo ""
echo "컨테이너 기동..."
docker run -d \
    --name "${CONTAINER_NAME}" \
    --platform "${PLATFORM}" \
    --memory=1g \
    -p 15034:15034 \
    "${IMAGE_NAME}" >/dev/null

sleep 3
docker logs "${CONTAINER_NAME}"

if [ "$RUN_ALL" -eq 1 ]; then
    echo ""
    echo "============================================"
    echo "  전체 시나리오 실행 (약 12~15분 소요)"
    echo "============================================"
    for c in oom-before oom-mid oom-after cpu-before cpu-after deadlock-before deadlock-after; do
        echo ""
        echo ">>> ${c}"
        docker exec "${CONTAINER_NAME}" /opt/scripts/run-case.sh "${c}"
    done

    echo ""
    echo "증거 회수: ${PROJECT_DIR}/evidence/"
    rm -rf "${PROJECT_DIR}/evidence"
    docker cp "${CONTAINER_NAME}:/evidence" "${PROJECT_DIR}/evidence"
    ls -R "${PROJECT_DIR}/evidence"
else
    echo ""
    echo "  개별 시나리오 실행:"
    echo "    docker exec ${CONTAINER_NAME} /opt/scripts/run-case.sh oom-before"
    echo "    docker exec ${CONTAINER_NAME} /opt/scripts/run-case.sh cpu-before"
    echo "    docker exec ${CONTAINER_NAME} /opt/scripts/run-case.sh deadlock-before"
    echo "  증거 회수:"
    echo "    docker cp ${CONTAINER_NAME}:/evidence ./evidence"
fi
