#!/usr/bin/env bash
# 공통 함수. 각 스텝 스크립트가 source 한다.
#
# 환경변수
#   KC        Keycloak 베이스 URL          (기본 http://localhost:8080)
#   REALM     대상 realm                   (기본 itgrims)   ※ master 아님
#   ADMIN     admin 계정                   (기본 admin)
#   ADMIN_PW  admin 비밀번호               (기본 admin)
#   CLIENTS   토큰 발급 클라이언트 목록    (기본 itgrims-client, 공백 구분)
#
# 모든 쓰기 스크립트는 기본이 dry-run 이다. 실제 반영은 --apply 를 붙인다.
set -uo pipefail

KC=${KC:-http://localhost:8080}
REALM=${REALM:-itgrims}
ADMIN=${ADMIN:-admin}
ADMIN_PW=${ADMIN_PW:-admin}
CLIENTS=${CLIENTS:-itgrims-client}
ATTR=business
DISPLAY_NAME=${DISPLAY_NAME:-"사업 구분"}
VALUES=${VALUES:-"ITGRIMS CHEONAN"}
PARENT_GROUP=business

APPLY=0
for a in "$@"; do [ "$a" = "--apply" ] && APPLY=1; done

c_ok=$'\033[32m'; c_no=$'\033[31m'; c_warn=$'\033[33m'; c_b=$'\033[1m'; c_0=$'\033[0m'
log()  { printf '  %s\n' "$*"; }
ok()   { printf '  %sOK%s   %s\n'   "$c_ok"   "$c_0" "$*"; }
skip() { printf '  --   %s\n' "$*"; }
warn() { printf '  %sWARN%s %s\n'   "$c_warn" "$c_0" "$*"; }
die()  { printf '  %sERROR%s %s\n'  "$c_no"   "$c_0" "$*" >&2; exit 1; }
hdr()  { printf '\n%s%s%s\n' "$c_b" "$*" "$c_0"; }
dry()  { [ "$APPLY" = 1 ] || printf '  %s[dry-run]%s %s\n' "$c_warn" "$c_0" "$*"; }

command -v jq   >/dev/null || die "jq 가 필요합니다"
command -v curl >/dev/null || die "curl 이 필요합니다"

TOKEN=$(curl -s -d client_id=admin-cli -d "username=$ADMIN" -d "password=$ADMIN_PW" \
  -d grant_type=password "$KC/realms/master/protocol/openid-connect/token" | jq -r '.access_token // empty')
[ -n "$TOKEN" ] || die "admin 토큰 발급 실패 ($KC, 계정 $ADMIN)"

# api_get <realm-relative-path>
api_get() { curl -s -X GET "$KC/admin/realms$1" -H "Authorization: Bearer $TOKEN"; }

# api_send <METHOD> <path> [json]  -> HTTP 상태코드. --apply 없으면 실제로 보내지 않고 000 반환
api_send() {
  local m=$1 p=$2 b=${3:-}
  if [ "$APPLY" != 1 ]; then echo "000"; return 0; fi
  if [ -n "$b" ]; then
    curl -s -o /tmp/kcstep-resp.json -w '%{http_code}' -X "$m" "$KC/admin/realms$p" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$b"
  else
    curl -s -o /tmp/kcstep-resp.json -w '%{http_code}' -X "$m" "$KC/admin/realms$p" \
      -H "Authorization: Bearer $TOKEN"
  fi
}
api_err() { [ -s /tmp/kcstep-resp.json ] && jq -c . /tmp/kcstep-resp.json 2>/dev/null || cat /tmp/kcstep-resp.json 2>/dev/null; }

# 성공(2xx) 또는 dry-run(000) 인지
sent_ok() { case "$1" in 2*|000) return 0;; *) return 1;; esac; }

user_id()      { api_get "/$REALM/users?username=$1&exact=true" | jq -r '.[0].id // empty'; }
client_uuid()  { api_get "/$REALM/clients?clientId=$1" | jq -r '.[0].id // empty'; }
sa_user_id()   { api_get "/$REALM/clients/$1/service-account-user" | jq -r '.id // empty'; }
parent_gid()   { api_get "/$REALM/groups?search=$PARENT_GROUP" | jq -r --arg n "$PARENT_GROUP" '.[]|select(.name==$n)|.id' | head -1; }
child_gid()    { api_get "/$REALM/groups/$(parent_gid)/children" | jq -r --arg n "$1" '.[]|select(.name==$n)|.id' | head -1; }
