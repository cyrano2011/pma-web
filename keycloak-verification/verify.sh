#!/usr/bin/env bash
# kcconsoleguide.pdf (WMS-136 · 천안분리 A-1) 절차를 빈 Keycloak 에서 재현/검증한다.
#
# 사용법:
#   ./verify.sh            # Keycloak 컨테이너를 새로 띄우고 전체 검증
#   KC=http://host:8080 ADMIN=admin ADMIN_PW=admin SKIP_DOCKER=1 ./verify.sh
#
# 가이드의 각 단계를 콘솔이 호출하는 것과 동일한 Admin REST 엔드포인트로 수행하고,
# 가이드가 주장하는 내용을 하나씩 assert 한다. 실패한 항목은 FAIL 로 출력된다.
set -uo pipefail

KC=${KC:-http://localhost:8080}
ADMIN=${ADMIN:-admin}
ADMIN_PW=${ADMIN_PW:-admin}
IMAGE=${IMAGE:-quay.io/keycloak/keycloak:26.4}
REALM=itgrims
CLIENT=itgrims-client
CLIENT_SECRET=itgrims-secret
USER_PW='Passw0rd!'

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk()  { # chk <설명> <실제> <기대>
  if [ "$2" = "$3" ]; then ok "$1 (= $2)"; else no "$1 — 기대 '$3', 실제 '$2'"; fi; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 컨테이너 기동
if [ -z "${SKIP_DOCKER:-}" ]; then
  docker rm -f kc-verify >/dev/null 2>&1
  docker run -d --name kc-verify -p 8080:8080 \
    -e KC_BOOTSTRAP_ADMIN_USERNAME="$ADMIN" -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PW" \
    "$IMAGE" start-dev >/dev/null
  for _ in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$KC/realms/master/.well-known/openid-configuration")" = 200 ] && break
    sleep 3
  done
fi

T=$(curl -s -d client_id=admin-cli -d "username=$ADMIN" -d "password=$ADMIN_PW" -d grant_type=password \
      "$KC/realms/master/protocol/openid-connect/token" | jq -r .access_token)
[ "$T" = null ] && { echo "admin 토큰 발급 실패"; exit 1; }

g()   { curl -s -X GET "$KC/admin/realms$1" -H "Authorization: Bearer $T"; }
api() { local m=$1 p=$2 b=${3:-}
  if [ -n "$b" ]; then curl -s -o /dev/null -w '%{http_code}' -X "$m" "$KC/admin/realms$p" \
      -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "$b"
  else curl -s -o /dev/null -w '%{http_code}' -X "$m" "$KC/admin/realms$p" -H "Authorization: Bearer $T"; fi; }
uid() { g "/$REALM/users?username=$1&exact=true" | jq -r '.[0].id'; }
payload() { # payload <jwt> -> 디코딩된 페이로드 JSON
  printf '%s==' "$(printf '%s' "$1" | cut -d. -f2)" | base64 -d 2>/dev/null; }
claim() { # claim <user> -> 실제 로그인 토큰의 business 클레임 (JSON)
  local at
  at=$(curl -s -d "client_id=$CLIENT" -d "client_secret=$CLIENT_SECRET" -d grant_type=password \
        -d "username=$1" -d "password=$USER_PW" "$KC/realms/$REALM/protocol/openid-connect/token" \
        | jq -r '.access_token // empty')
  if [ -z "$at" ]; then echo '"‹login-failed›"'; else payload "$at" | jq -c '.business // "‹absent›"'; fi; }
login_err() {
  curl -s -d "client_id=$CLIENT" -d "client_secret=$CLIENT_SECRET" -d grant_type=password \
    -d "username=$1" -d "password=$USER_PW" "$KC/realms/$REALM/protocol/openid-connect/token" \
    | jq -r '.error_description // "ok"'; }

# ---------------------------------------------------------------- 기준 상태 구성
hdr "0. 빈 Keycloak 에 prod 유사 기준 상태 구성"
api POST "" "{\"realm\":\"$REALM\",\"enabled\":true}" >/dev/null
api POST "/$REALM/clients" "{\"clientId\":\"$CLIENT\",\"enabled\":true,\"publicClient\":false,\"secret\":\"$CLIENT_SECRET\",\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":true,\"serviceAccountsEnabled\":true,\"redirectUris\":[\"*\"]}" >/dev/null
for u in hq1 hq2 cheonan1; do
  api POST "/$REALM/users" "{\"username\":\"$u\",\"enabled\":true,\"email\":\"$u@example.com\",\"firstName\":\"F$u\",\"lastName\":\"L$u\",\"emailVerified\":true,\"credentials\":[{\"type\":\"password\",\"value\":\"$USER_PW\",\"temporary\":false}]}" >/dev/null
done
echo "  realm/client/사용자 3명 + 서비스 계정 1개 생성"

hdr "왜 콘솔인가 — 스크립트식 PUT(attributes 만) 이 정말 파괴적인가"
h=$(uid hq2)
api PUT "/$REALM/users/$h" '{"attributes":{"business":["ITGRIMS"]}}' >/dev/null
left=$(g "/$REALM/users/$h" | jq -c '[.email,.firstName,.lastName]')
chk "attributes 만 PUT 하면 email/firstName/lastName 이 지워진다" "$left" '[null,null,null]'
chk "그 계정은 로그인이 깨진다" "$(login_err hq2)" "Account is not fully set up"
api PUT "/$REALM/users/$h" "{\"username\":\"hq2\",\"enabled\":true,\"email\":\"hq2@example.com\",\"firstName\":\"Fhq2\",\"lastName\":\"Lhq2\",\"emailVerified\":true}" >/dev/null

# ---------------------------------------------------------------- 1 단계
hdr "1 단계 — 사업 그룹"
api POST "/$REALM/groups" '{"name":"business"}' >/dev/null
P=$(g "/$REALM/groups?search=business" | jq -r '.[0].id')
api POST "/$REALM/groups/$P/children" '{"name":"ITGRIMS"}'  >/dev/null
api POST "/$REALM/groups/$P/children" '{"name":"CHEONAN"}' >/dev/null
chk "/business/ITGRIMS, /business/CHEONAN 생성" \
    "$(g "/$REALM/groups/$P/children" | jq -c '[.[].path]|sort')" '["/business/CHEONAN","/business/ITGRIMS"]'

# ---------------------------------------------------------------- 2 단계
hdr "2 단계 — User Profile 에 business 선언"
g "/$REALM/users/profile" > /tmp/kcv-profile.json
jq '.attributes += [{"name":"business","displayName":"사업 구분","multivalued":false,
    "permissions":{"view":["admin"],"edit":["admin"]},
    "validations":{"options":{"options":["ITGRIMS","CHEONAN"]}}}]' /tmp/kcv-profile.json > /tmp/kcv-profile-new.json
chk "User Profile 저장" "$(api PUT "/$REALM/users/profile" "$(cat /tmp/kcv-profile-new.json)")" "200"
chk "저장 직후 기존 계정 로그인 정상" "$(login_err hq1)" "ok"

# 가이드의 경고: Required field = On 이면 기존 계정 로그인 실패?
jq '(.attributes[]|select(.name=="business")) += {"required":{"roles":["user"]}}' /tmp/kcv-profile-new.json > /tmp/kcv-req.json
api PUT "/$REALM/users/profile" "$(cat /tmp/kcv-req.json)" >/dev/null
r_adminonly=$(login_err hq1)
jq '(.attributes[]|select(.name=="business")) += {"required":{"roles":["user"]},"permissions":{"view":["admin","user"],"edit":["admin","user"]}}' /tmp/kcv-profile-new.json > /tmp/kcv-req2.json
api PUT "/$REALM/users/profile" "$(cat /tmp/kcv-req2.json)" >/dev/null
r_useredit=$(login_err hq1)
api PUT "/$REALM/users/profile" "$(cat /tmp/kcv-profile-new.json)" >/dev/null
chk "Required=On + 권한 Admin 전용 → 로그인 안 깨짐 (가이드 경고와 다름)" "$r_adminonly" "ok"
chk "Required=On + user 편집 허용 → 로그인 깨짐 (경고가 성립하는 조건)" "$r_useredit" "Account is not fully set up"

# ---------------------------------------------------------------- 3 단계
hdr "3 단계 — 클라이언트 전용 스코프에 User Attribute 매퍼"
C=$(g "/$REALM/clients?clientId=$CLIENT" | jq -r '.[0].id')
chk "business-claim 매퍼 추가" "$(api POST "/$REALM/clients/$C/protocol-mappers/models" '{"name":"business-claim","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","config":{"user.attribute":"business","claim.name":"business","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true","multivalued":"false"}}')" "201"

# ---------------------------------------------------------------- 4 단계
hdr "4 단계 — 계정별 속성/그룹"
GI=$(g "/$REALM/groups/$P/children" | jq -r '.[]|select(.name=="ITGRIMS")|.id')
GC=$(g "/$REALM/groups/$P/children" | jq -r '.[]|select(.name=="CHEONAN")|.id')
setbiz() { local id; id=$(uid "$1"); g "/$REALM/users/$id" | jq --arg v "$2" '.attributes=((.attributes//{})+{"business":[$v]})' > /tmp/kcv-u.json
           api PUT "/$REALM/users/$id" "$(cat /tmp/kcv-u.json)" >/dev/null; }
setbiz cheonan1 CHEONAN; setbiz hq1 ITGRIMS; setbiz hq2 ITGRIMS
curl -s -o /dev/null -X PUT -H "Authorization: Bearer $T" "$KC/admin/realms/$REALM/users/$(uid cheonan1)/groups/$GC"
for u in hq1 hq2; do curl -s -o /dev/null -X PUT -H "Authorization: Bearer $T" "$KC/admin/realms/$REALM/users/$(uid "$u")/groups/$GI"; done
SA=$(g "/$REALM/clients/$C/service-account-user" | jq -r .id)
g "/$REALM/users/$SA" | jq '.attributes=((.attributes//{})+{"business":["ITGRIMS"]})' > /tmp/kcv-sa.json
api PUT "/$REALM/users/$SA" "$(cat /tmp/kcv-sa.json)" >/dev/null
i=$(uid hq2); g "/$REALM/users/$i" | jq '.attributes.business=["CHEONAM"]' > /tmp/kcv-bad.json
chk "Validator 가 오타(CHEONAM) 를 거부" "$(api PUT "/$REALM/users/$i" "$(cat /tmp/kcv-bad.json)")" "400"
g "/$REALM/users/$i" | jq '.attributes.business=["/business/ITGRIMS"]' > /tmp/kcv-slash.json
chk "Validator 가 슬래시 형태(/business/ITGRIMS) 도 거부" "$(api PUT "/$REALM/users/$i" "$(cat /tmp/kcv-slash.json)")" "400"
chk "서비스 계정은 Users 목록/검색에 노출되지 않음" \
    "$(g "/$REALM/users?search=service-account&max=200" | jq 'length')" "0"

# ---------------------------------------------------------------- 5 단계
hdr "5 단계 — 토큰 클레임 검증"
for u in hq1:ITGRIMS cheonan1:CHEONAN; do
  n=${u%%:*}; v=${u##*:}; id=$(uid "$n")
  chk "Evaluate($n) 의 access token business" \
      "$(g "/$REALM/clients/$C/evaluate-scopes/generate-example-access-token?scope=&userId=$id" | jq -c .business)" "\"$v\""
  chk "실제 로그인 토큰($n) business" "$(claim "$n")" "\"$v\""
done
chk "client_credentials(서비스 계정) 토큰에도 실림" \
  "$(payload "$(curl -s -d "client_id=$CLIENT" -d "client_secret=$CLIENT_SECRET" -d grant_type=client_credentials \
     "$KC/realms/$REALM/protocol/openid-connect/token" | jq -r .access_token)" | jq -c .business)" '"ITGRIMS"'

# 반례: Group Membership 매퍼 / Multivalued On / 다른 클라이언트
api POST "/$REALM/clients" '{"clientId":"tmp-gm","enabled":true,"publicClient":false,"secret":"s","directAccessGrantsEnabled":true}' >/dev/null
G=$(g "/$REALM/clients?clientId=tmp-gm" | jq -r '.[0].id')
api POST "/$REALM/clients/$G/protocol-mappers/models" '{"name":"gm","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"claim.name":"business","full.path":"true","access.token.claim":"true","id.token.claim":"true"}}' >/dev/null
chk "Group Membership 매퍼는 배열로 나간다 (가이드 경고대로)" \
  "$(payload "$(curl -s -d client_id=tmp-gm -d client_secret=s -d grant_type=password -d username=cheonan1 \
     -d "password=$USER_PW" "$KC/realms/$REALM/protocol/openid-connect/token" | jq -r .access_token)" | jq -c .business)" '["/business/CHEONAN"]'
api DELETE "/$REALM/clients/$G" >/dev/null
M=$(g "/$REALM/clients/$C/protocol-mappers/models" | jq -r '.[]|select(.name=="business-claim")|.id')
g "/$REALM/clients/$C/protocol-mappers/models/$M" | jq '.config.multivalued="true"' > /tmp/kcv-m.json
api PUT "/$REALM/clients/$C/protocol-mappers/models/$M" "$(cat /tmp/kcv-m.json)" >/dev/null
chk "User Attribute 매퍼도 Multivalued=On 이면 배열이 된다" "$(claim cheonan1)" '["CHEONAN"]'
g "/$REALM/clients/$C/protocol-mappers/models/$M" | jq '.config.multivalued="false"' > /tmp/kcv-m2.json
api PUT "/$REALM/clients/$C/protocol-mappers/models/$M" "$(cat /tmp/kcv-m2.json)" >/dev/null

# ---------------------------------------------------------------- 6 단계
hdr "6 단계 — 누락 계정 전수 확인"
A=$(g "/$REALM/users/count?q=business%3AITGRIMS"); B=$(g "/$REALM/users/count?q=business%3ACHEONAN")
TOT=$(g "/$REALM/users/count")
echo "  Attribute search: ITGRIMS=$A, CHEONAN=$B, 합=$((A+B)) / Users 목록 총계=$TOT"
if [ $((A+B)) -eq "$TOT" ]; then
  no "가이드의 '두 건수의 합 = 전체 사용자 수' 규칙 — 이번 환경에서는 성립 (서비스 계정 없음?)"
else
  ok "가이드의 '합 = 전체' 규칙은 성립하지 않는다: 차이 $((A+B-TOT)) = 서비스 계정 수 (목록에는 안 보이지만 속성 검색에는 잡힘)"
fi
chk "속성 검색 값은 대소문자를 구분하지 않는다" \
    "$(g "/$REALM/users/count?q=business%3Aitgrims")" "$A"

# ---------------------------------------------------------------- 백업 관련
hdr "시작 전에 — 백업 경로"
chk "Admin REST get users 에 비밀번호 해시 없음" \
    "$(g "/$REALM/users?username=hq1&exact=true" | jq -c '.[0]|has("credentials")')" "false"
curl -s -X POST "$KC/admin/realms/$REALM/partial-export?exportClients=true&exportGroupsAndRoles=true" \
  -H "Authorization: Bearer $T" -H 'Content-Type: application/json' > /tmp/kcv-pexport.json
chk "Partial export 에 일반 사용자 없음" \
    "$(jq -c '[.users[]?|select(.serviceAccountClientId==null)]|length' /tmp/kcv-pexport.json)" "0"
chk "Partial export 에 credential 없음 (백업용으로 부적합)" \
    "$(jq -c '[.users[]?|.credentials//empty]|length' /tmp/kcv-pexport.json)" "0"
echo "  ※ kc.sh export --users different_files 는 credential 해시를 포함한다 (README 참조, 별도 확인)"

printf '\n\033[1m결과: PASS %d / FAIL %d\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
