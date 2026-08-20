# 베이스 이미지: Ubuntu 22.04 LTS
# 멀티아키텍처 태그이므로 docker build --platform 값에 따라
# amd64(Intel) / arm64(Apple Silicon) 중 하나가 자동으로 선택된다.
FROM ubuntu:22.04

# 빌드 중 apt 가 대화형 질문을 띄우지 않게 한다.
ENV DEBIAN_FRONTEND=noninteractive
# 컨테이너 기본 시간대는 UTC 라 로그 타임스탬프가 한국 시각과 9시간 어긋난다.
ENV TZ=Asia/Seoul

# 장애 관측에 필요한 도구
#   procps    : ps/pgrep/free  — 프로세스 존재·RSS·스레드 확인
#   psmisc    : pstree         — 스레드 트리 확인
#   iproute2  : ss             — 15034 LISTEN 확인
#   bc        : 소수점 연산    — bash 는 정수만 다루므로 사용률 계산에 필요
#   gawk      : GNU awk        — 기본 mawk 와 printf/소수점 동작이 달라 명시 고정
#   procps 의 top 은 -H(스레드 모드) 를 지원하므로 데드락 진단에 그대로 쓴다.
RUN apt-get update && apt-get install -y \
    procps \
    psmisc \
    iproute2 \
    bc \
    gawk \
    ca-certificates \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

# 제공된 앱 바이너리를 아키텍처별로 모두 넣어둔다.
# 실제로 어느 것을 쓸지는 컨테이너 실행 시 setup.sh 가 `uname -m` 으로 판단한다.
COPY agent-app-leak/agent-leak-app-arm64 /opt/dist/agent-leak-app-arm64
COPY agent-app-leak/agent-leak-app-x86   /opt/dist/agent-leak-app-x86
COPY scripts/ /opt/scripts/

RUN chmod +x /opt/dist/agent-leak-app-arm64 /opt/dist/agent-leak-app-x86 \
    && chmod +x /opt/scripts/*.sh

# 앱이 바인딩하는 포트 (실제 호스트 연결은 docker run -p 가 담당)
EXPOSE 15034

# 부트 조건(계정·디렉터리·키파일·환경변수)을 구성하고 컨테이너를 유지한다.
# 장애 시나리오는 컨테이너 기동 후 run-case.sh 로 개별 실행한다.
ENTRYPOINT ["/opt/scripts/setup.sh"]
