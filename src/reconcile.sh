#!/bin/sh
# multi-nic-route-reconciler
#
# ConfigMap(routes.conf)에 선언된 라우트를 노드의 main 라우팅 테이블에 맞춰 유지한다.
# - 이 프로세스가 만든 라우트는 proto 태그로 구분하고, 그 외 라우트는 건드리지 않는다.
# - 선언과 실제 상태가 다르면 다시 적용하고, 선언에서 빠진 라우트는 제거한다.
# - 모든 라우트가 적용·검증된 경우에만 ready 파일을 만들어 readinessProbe를 통과시킨다.

set -u

CONF_DIR="${CONF_DIR:-/etc/multi-nic-routing}"
CONF="$CONF_DIR/routes.conf"
STATE="${STATE_DIR:-/run/multi-nic-routing}"
READY="$STATE/ready"
ROUTES="$STATE/routes.list"
PROTO="${ROUTE_PROTO:-210}"

DEFAULT_INTERVAL=30
MIN_INTERVAL=5
MAX_INTERVAL=3600

log() {
  echo "[$(date '+%F %T')] $*"
}

# routes.conf를 검증하고 "DST IFACE GW" 목록을 $ROUTES에 쓴다.
# 형식 오류, 중복 목적지, 빈 설정이면 실패를 반환한다.
load_routes() {
  if [ ! -r "$CONF" ]; then
    log "ERROR: config not found: $CONF"
    return 1
  fi

  if ! awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      if (NF != 3) { bad = 1; next }
      if ($1 !~ /^[0-9.]+\/[0-9]+$/ ||
          $2 !~ /^[a-zA-Z0-9_.-]+$/ ||
          $3 !~ /^[0-9.]+$/) { bad = 1; next }
      if (seen[$1]++) bad = 1
      print $1, $2, $3
      count++
    }
    END { if (bad || count == 0) exit 1 }
  ' "$CONF" > "$ROUTES"; then
    log "ERROR: invalid routes.conf"
    return 1
  fi
}

# 목적지 라우트가 "via GW dev IFACE proto PROTO" 한 줄로만 존재하는지 확인한다.
# $1=DST $2=IFACE $3=GW
route_matches() {
  current=$(ip -4 route show table main exact "$1")
  [ "$(printf '%s\n' "$current" | grep -c .)" -eq 1 ] &&
    printf '%s\n' "$current" | grep -Fq "via $3 dev $2 proto $PROTO"
}

# 선언된 라우트를 적용한다. 하나라도 실패하면 1을 반환한다.
apply_routes() {
  rc=0
  while read -r DST IFACE GW; do
    if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
      log "ERROR: interface $IFACE not found"
      rc=1
      continue
    fi

    if ! ip -o link show dev "$IFACE" | grep -Eq '[<,]UP[,>]'; then
      log "ERROR: interface $IFACE is DOWN"
      rc=1
      continue
    fi

    current=$(ip -4 route show table main exact "$DST")

    # 다른 주체(OS, CNI, 운영자)가 만든 라우트는 덮어쓰지 않는다.
    if [ -n "$current" ] &&
       ! printf '%s\n' "$current" |
         grep -Eq "(^|[[:space:]])proto $PROTO([[:space:]]|$)"; then
      log "ERROR: unmanaged route exists: $DST"
      rc=1
      continue
    fi

    if route_matches "$DST" "$IFACE" "$GW"; then
      continue
    fi

    if ip -4 route replace "$DST" via "$GW" dev "$IFACE" proto "$PROTO"; then
      log "APPLY: $DST via $GW dev $IFACE"
    else
      log "ERROR: failed to apply $DST"
      rc=1
    fi
  done < "$ROUTES"
  return "$rc"
}

# 이 프로세스가 관리하던 라우트 중 선언에서 빠진 것을 제거한다.
prune_routes() {
  ip -4 route show table main proto "$PROTO" |
  while read -r DST _; do
    if ! awk -v d="$DST" '$1 == d { f = 1 } END { exit !f }' "$ROUTES"; then
      if ip -4 route del "$DST" proto "$PROTO" table main; then
        log "REMOVE: $DST (removed from ConfigMap)"
      fi
    fi
  done
}

# 적용 후 모든 라우트가 기대한 상태인지 다시 확인한다.
verify_routes() {
  rc=0
  while read -r DST IFACE GW; do
    if ! route_matches "$DST" "$IFACE" "$GW"; then
      log "ERROR: route verification failed: $DST"
      rc=1
    fi
  done < "$ROUTES"
  return "$rc"
}

read_interval() {
  interval=$(cat "$CONF_DIR/RECONCILE_INTERVAL" 2>/dev/null)
  case "$interval" in
    ""|*[!0-9]*) interval=$DEFAULT_INTERVAL ;;
  esac
  if [ "$interval" -lt "$MIN_INTERVAL" ] || [ "$interval" -gt "$MAX_INTERVAL" ]; then
    interval=$DEFAULT_INTERVAL
  fi
  echo "$interval"
}

reconcile_once() {
  load_routes || return 1
  apply_routes || return 1
  # 적용이 모두 성공했을 때만 정리한다.
  # 일부가 실패한 상태에서 지우면 아직 유효한 경로를 잃을 수 있다.
  prune_routes
  verify_routes
}

main() {
  trap 'rm -f "$READY"; exit 0' TERM INT

  mkdir -p "$STATE"
  rm -f "$READY"
  log "multi-nic-route-reconciler started (proto=$PROTO)"

  while true; do
    if reconcile_once; then
      if [ ! -f "$READY" ]; then
        log "READY: all routes configured"
      fi
      touch "$READY"
    else
      rm -f "$READY"
    fi

    # sleep을 백그라운드로 실행해 SIGTERM에 바로 반응하게 한다.
    sleep "$(read_interval)" &
    wait $!
  done
}

# 테스트에서 함수만 불러올 수 있도록 RECONCILE_LIB_ONLY=1이면 main을 실행하지 않는다.
[ "${RECONCILE_LIB_ONLY:-0}" = 1 ] || main "$@"
