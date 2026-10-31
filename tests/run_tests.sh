#!/bin/sh
# reconcile.sh의 동작을 실제 노드 없이 검증한다.
# ip 명령은 tests/fake-ip 스텁으로 대체하고, 라우팅 테이블은 임시 파일을 사용한다.
#
# 실행: sh tests/run_tests.sh

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/conf" "$WORK/state"
cp "$ROOT/tests/fake-ip" "$WORK/bin/ip"
chmod +x "$WORK/bin/ip"

export PATH="$WORK/bin:$PATH"
export CONF_DIR="$WORK/conf"
export STATE_DIR="$WORK/state"
export FAKE_IP_TABLE="$WORK/table"
export FAKE_IP_IFACES="eth1 eth2"
export RECONCILE_LIB_ONLY=1

PASS=0
FAIL=0

# shellcheck source=src/reconcile.sh
. "$ROOT/src/reconcile.sh"
mkdir -p "$STATE"

ok() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
ng() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

expect_rc() {   # $1=설명 $2=기대 rc
  reconcile_once >"$WORK/out.log" 2>&1
  rc=$?
  if [ "$rc" -eq "$2" ]; then ok "$1 (rc=$rc)"; else ng "$1 (rc=$rc, expected $2)"; cat "$WORK/out.log"; fi
}

expect_table() {   # $1=설명 $2=찾을 줄
  if grep -Fxq "$2" "$FAKE_IP_TABLE"; then ok "$1"; else ng "$1"; cat "$FAKE_IP_TABLE"; fi
}

expect_absent() {  # $1=설명 $2=없어야 할 목적지
  if grep -q "^$2 " "$FAKE_IP_TABLE"; then ng "$1"; cat "$FAKE_IP_TABLE"; else ok "$1"; fi
}

expect_log() {     # $1=설명 $2=로그에 있어야 할 문자열
  if grep -Fq "$2" "$WORK/out.log"; then ok "$1"; else ng "$1"; cat "$WORK/out.log"; fi
}

write_conf() { printf '%s\n' "$@" > "$CONF_DIR/routes.conf"; }

echo "[1] 최초 적용과 이전 관리 라우트 정리"
: > "$FAKE_IP_TABLE"
echo "10.99.0.0/24 via 10.20.1.1 dev eth1 proto 210" >> "$FAKE_IP_TABLE"
echo "10.50.0.0/24 via 10.20.1.1 dev eth1 proto static" >> "$FAKE_IP_TABLE"
write_conf "10.10.1.0/24 eth1 10.20.1.1" "10.10.2.0/24 eth2 10.20.2.1"
expect_rc "선언된 라우트 적용" 0
expect_table "eth1 경로 생성" "10.10.1.0/24 via 10.20.1.1 dev eth1 proto 210"
expect_table "eth2 경로 생성" "10.10.2.0/24 via 10.20.2.1 dev eth2 proto 210"
expect_absent "선언에서 빠진 관리 라우트 제거" "10.99.0.0/24"
expect_table "관리 대상이 아닌 라우트는 유지" "10.50.0.0/24 via 10.20.1.1 dev eth1 proto static"

echo "[2] 멱등성"
expect_rc "변경 없이 재실행" 0
if grep -q "APPLY" "$WORK/out.log"; then ng "불필요한 재적용 없음"; else ok "불필요한 재적용 없음"; fi

echo "[3] 드리프트 복구"
sed -i 's|10.10.1.0/24 via 10.20.1.1|10.10.1.0/24 via 10.20.9.9|' "$FAKE_IP_TABLE"
expect_rc "게이트웨이가 바뀐 라우트 복구" 0
expect_table "원래 게이트웨이로 복구" "10.10.1.0/24 via 10.20.1.1 dev eth1 proto 210"

echo "[4] 관리 대상이 아닌 라우트와 충돌"
write_conf "10.10.1.0/24 eth1 10.20.1.1" "10.50.0.0/24 eth1 10.20.1.1"
expect_rc "충돌 시 실패 처리" 1
expect_log "충돌 로그 출력" "unmanaged route exists: 10.50.0.0/24"
expect_table "기존 라우트를 덮어쓰지 않음" "10.50.0.0/24 via 10.20.1.1 dev eth1 proto static"

echo "[5] 일부 실패 시 정리 보류"
write_conf "10.10.1.0/24 eth9 10.20.1.1"
expect_rc "없는 인터페이스" 1
expect_table "실패 상태에서는 기존 관리 라우트를 지우지 않음" "10.10.2.0/24 via 10.20.2.1 dev eth2 proto 210"

echo "[6] 잘못된 설정"
write_conf "10.10.1.0/24 eth1"
expect_rc "필드 누락" 1
write_conf "10.10.1.0/24 eth1 10.20.1.1" "10.10.1.0/24 eth2 10.20.2.1"
expect_rc "중복 목적지" 1
write_conf "# comment only"
expect_rc "빈 설정" 1

echo "[7] 주기 설정 범위 검사"
expect_interval() {  # $1=설명 $2=설정값 $3=기대값
  echo "$2" > "$CONF_DIR/RECONCILE_INTERVAL"
  if [ "$(read_interval)" -eq "$3" ]; then ok "$1"; else ng "$1"; fi
}
expect_interval "하한 미만은 기본값" 1 30
expect_interval "숫자가 아니면 기본값" abc 30
expect_interval "정상 값 사용" 60 60

echo
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
