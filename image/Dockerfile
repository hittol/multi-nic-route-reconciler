# 저장소 루트에서 빌드한다.
#   docker build -f image/Dockerfile -t <registry>.azurecr.io/multi-nic-route-reconciler:1.0.0 .
#
# 폐쇄망 클러스터에서는 외부 레지스트리에 접근할 수 없으므로,
# 빌드한 이미지를 내부 레지스트리(ACR 등)에 올려 사용한다.

FROM alpine:3.20

# BusyBox ip는 proto 지정 등 일부 옵션이 제한적이므로 iproute2를 설치한다.
RUN apk add --no-cache iproute2

COPY src/reconcile.sh /usr/local/bin/reconcile.sh
RUN chmod 0555 /usr/local/bin/reconcile.sh

ENTRYPOINT ["/usr/local/bin/reconcile.sh"]
