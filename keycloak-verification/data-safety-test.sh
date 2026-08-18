#!/usr/bin/env bash
# 빈 Keycloak 에서 steps/ 스크립트를 돌렸을 때 기존 계정 정보가 지워지는지 검사한다.
#
#   ./data-safety-test.sh            # 컨테이너를 새로 띄우고 전체 검사
#   SKIP_DOCKER=1 ./data-safety-test.sh
#
# 검사 항목
#   · email / firstName / lastName / emailVerified / enabled / createdTimestamp
#   · requiredActions, realm 역할, 기존 그룹 소속, credential(비밀번호) 및 실제 로그인
#   · User Profile 에 선언되지 않은 기존 속성(legacy) — Unmanaged 정책 Disabled/Enabled 양쪽
#   · 대조군: 가이드가 경고한 {"attributes":...} 단독 PUT 과의 차이
set -uo pipefail
cd "$(dirname "$0")"

KC=${KC:-http://localhost:8080}
ADMIN=${ADMIN:-admin} ADMIN_PW=${ADMIN_PW:-admin}
IMAGE=${IMAGE:-quay.io/keycloak/keycloak:26.4}
CONTAINER=${CONTAINER:-kc-verify}
REALM=itgrims CLIENT=itgrims-client SECRET=itgrims-secret PW='Passw0rd!'

pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
hdr(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
same(){ if [ "$2" = "$3" ]; then ok "$1 (= $2)"; else no "$1 — 이전 '$3' → 이후 '$2'"; fi; }
eq(){ if [ "$2" = "$3" ]; then ok "$1 (= $2)"; else no "$1 — 기대 '$3', 실제 '$2'"; fi; }

if [ -z "${SKIP_DOCKER:-}" ]; then
  docker rm -f "$CONTAINER" >/dev/null 2>&1
  docker run -d --name "$CONTAINER" -p 8080:8080 \
    -e KC_BOOTSTRAP_ADMIN_USERNAME="$ADMIN" -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PW" "$IMAGE" start-dev >/dev/null
  for _ in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$KC/realms/master/.well-known/openid-configuration")" = 200 ] && break; sleep 3; done
fi
T=$(curl -s -d client_id=admin-cli -d "username=$ADMIN" -d "password=$ADMIN_PW" -d grant_type=password \
     "$KC/realms/master/protocol/openid-connect/token" | jq -r .access_token)
g(){ curl -s -X GET "$KC/admin/realms$1" -H "Authorization: Bearer $T"; }
send(){ curl -s -o /tmp/dst.json -w '%{http_code}' -X "$1" "$KC/admin/realms$2" -H "Authorization: Bearer $T" -H 'Content-Type: application/json' ${3:+-d "$3"}; }
uid(){ g "/$REALM/users?username=$1&exact=true" | jq -r '.[0].id'; }
policy(){ # policy ENABLED|DISABLED
  local prof; prof=$(g "/$REALM/users/profile")
  if [ "$1" = ENABLED ]; then send PUT "/$REALM/users/profile" "$(echo "$prof" | jq '.unmanagedAttributePolicy="ENABLED"')" >/dev/null
  else send PUT "/$REALM/users/profile" "$(echo "$prof" | jq 'del(.unmanagedAttributePolicy)')" >/dev/null; fi; }
login(){ curl -s -d "client_id=$CLIENT" -d "client_secret=$SECRET" -d grant_type=password -d "username=$1" -d "password=$PW" \
         "$KC/realms/$REALM/protocol/openid-connect/token" | jq -r 'if .access_token then "OK" else ("FAIL:"+.error_description) end'; }
snap(){ local id; id=$(uid "$1")
  jq -nc --argjson u "$(g "/$REALM/users/$id")" --argjson gr "$(g "/$REALM/users/$id/groups")" \
        --argjson rr "$(g "/$REALM/users/$id/role-mappings/realm")" --argjson cr "$(g "/$REALM/users/$id/credentials")" '{
    email:$u.email, firstName:$u.firstName, lastName:$u.lastName, emailVerified:$u.emailVerified,
    enabled:$u.enabled, createdTimestamp:$u.createdTimestamp, requiredActions:($u.requiredActions|sort),
    groups:([$gr[].path]|sort), realmRoles:([$rr[].name]|sort), credentials:([$cr[]|{type,id}]|sort_by(.type))}'; }

# ---------------------------------------------------------------- 기준 데이터
hdr "준비 — 빈 Keycloak 에 '기존 운영 데이터' 구성"
send POST "" "{\"realm\":\"$REALM\",\"enabled\":true}" >/dev/null
send POST "/$REALM/clients" "{\"clientId\":\"$CLIENT\",\"enabled\":true,\"publicClient\":false,\"secret\":\"$SECRET\",\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":true,\"serviceAccountsEnabled\":true,\"redirectUris\":[\"*\"]}" >/dev/null
send POST "/$REALM/roles" '{"name":"wms-operator"}' >/dev/null
send POST "/$REALM/groups" '{"name":"legacy-team"}' >/dev/null
policy ENABLED   # KC24 이전부터 임의 속성이 쌓여 있던 realm 을 흉내내기 위해 잠시 허용
for u in hq1 hq2 cheonan1; do
  ra='[]'; [ "$u" = hq1 ] && ra='["CONFIGURE_TOTP"]'   # 필수 액션이 걸린 계정도 한 명 포함
  send POST "/$REALM/users" "{\"username\":\"$u\",\"enabled\":true,\"email\":\"$u@returnit.co.kr\",
    \"firstName\":\"F$u\",\"lastName\":\"L$u\",\"emailVerified\":true,\"requiredActions\":$ra,
    \"attributes\":{\"dept\":[\"물류\"],\"employeeNo\":[\"E-$u\"]},
    \"credentials\":[{\"type\":\"password\",\"value\":\"$PW\",\"temporary\":false}]}" >/dev/null
done
lg=$(g "/$REALM/groups?search=legacy-team" | jq -r '.[0].id'); rr=$(g "/$REALM/roles/wms-operator")
for u in hq1 hq2 cheonan1; do
  curl -s -o /dev/null -X PUT "$KC/admin/realms/$REALM/users/$(uid $u)/groups/$lg" -H "Authorization: Bearer $T"
  curl -s -o /dev/null -X POST "$KC/admin/realms/$REALM/users/$(uid $u)/role-mappings/realm" -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "[$rr]"
done
policy DISABLED  # 여기부터가 가이드가 가정하는 기본 상태 (레거시 속성은 화면에서 숨겨진다)
echo "  hq1/hq2/cheonan1: email·이름·emailVerified·비밀번호·legacy-team 그룹·wms-operator 역할"
echo "  + 미선언 속성 dept=물류, employeeNo=E-<user>  (hq1 은 CONFIGURE_TOTP 필수 액션 보유)"

for u in hq1 hq2 cheonan1; do snap "$u" > "/tmp/before-$u.json"; done
BL_HQ2=$(login hq2); BL_CHE=$(login cheonan1); BL_HQ1=$(login hq1)
echo "  실행 전 로그인: hq2=$BL_HQ2, cheonan1=$BL_CHE, hq1=$BL_HQ1 (필수 액션 때문에 원래 실패)"

# ---------------------------------------------------------------- 스크립트 실행
hdr "steps/ 스크립트 실행 (01 → 02 → 03 → 04)"
( cd steps && rm -f .service-account-count &&
  ./01-groups.sh --apply >/dev/null && ./02-user-profile.sh --apply >/dev/null &&
  ./03-mapper.sh --apply >/dev/null &&
  ./04-assign.sh --set cheonan1=CHEONAN --service-accounts ITGRIMS --fill-remaining ITGRIMS --apply >/dev/null ) \
  && echo "  실행 완료" || { echo "  스크립트 실행 실패"; exit 1; }

hdr "1) 계정 필드·역할·그룹·자격증명 보존"
for u in hq1 hq2 cheonan1; do
  snap "$u" > "/tmp/after-$u.json"
  b(){ jq -r "$1" "/tmp/before-$u.json"; }; a(){ jq -r "$1" "/tmp/after-$u.json"; }
  for f in email firstName lastName emailVerified enabled createdTimestamp; do same "$u.$f" "$(a ".$f")" "$(b ".$f")"; done
  same "$u.requiredActions"   "$(a '.requiredActions|tostring')" "$(b '.requiredActions|tostring')"
  same "$u.credentials"       "$(a '.credentials|tostring')"     "$(b '.credentials|tostring')"
  same "$u.realmRoles"        "$(a '.realmRoles|tostring')"      "$(b '.realmRoles|tostring')"
  same "$u.기존 그룹 유지"     "$(jq -r '[.groups[]|select(startswith("/business")|not)]|tostring' "/tmp/after-$u.json")" "$(b '.groups|tostring')"
  eq   "$u.business 그룹 추가" "$(jq -r '[.groups[]|select(startswith("/business"))]|length' "/tmp/after-$u.json")" "1"
done

hdr "2) 미선언(legacy) 속성 — 정책 Disabled 상태"
for u in hq1 hq2 cheonan1; do
  eq "$u 화면에 보이는 속성은 business 뿐" "$(g "/$REALM/users/$(uid $u)" | jq -c '.attributes|keys')" '["business"]'
done
hdr "   → 정책을 Enabled 로 되돌리면 값이 그대로 살아있는가 (DB 보존 확인)"
policy ENABLED
for u in hq1 hq2 cheonan1; do
  eq "$u.dept"       "$(g "/$REALM/users/$(uid $u)" | jq -r '.attributes.dept[0] // "‹삭제됨›"')" "물류"
  eq "$u.employeeNo" "$(g "/$REALM/users/$(uid $u)" | jq -r '.attributes.employeeNo[0] // "‹삭제됨›"')" "E-$u"
done

hdr "3) Unmanaged 정책이 Enabled 인 realm 에서 04 를 다시 돌려도 안전한가"
send PUT "/$REALM/users/$(uid hq2)" "$(g "/$REALM/users/$(uid hq2)" | jq '.attributes += {"nickname":["둘리"]}')" >/dev/null
( cd steps && ./04-assign.sh --set hq2=CHEONAN --apply >/dev/null )
eq "hq2.nickname 유지"   "$(g "/$REALM/users/$(uid hq2)" | jq -r '.attributes.nickname[0] // "‹삭제됨›"')" "둘리"
eq "hq2.dept 유지"       "$(g "/$REALM/users/$(uid hq2)" | jq -r '.attributes.dept[0] // "‹삭제됨›"')" "물류"
eq "hq2.business 변경됨" "$(g "/$REALM/users/$(uid hq2)" | jq -r '.attributes.business[0]')" "CHEONAN"
policy DISABLED

hdr "4) 로그인 (같은 비밀번호)"
eq "hq2 로그인"      "$(login hq2)"      "$BL_HQ2"
eq "cheonan1 로그인" "$(login cheonan1)" "$BL_CHE"
eq "hq1 로그인 (필수 액션 보유 — 스크립트 전후 동일)" "$(login hq1)" "$BL_HQ1"

hdr "5) 대조군 — 가이드가 경고한 {\"attributes\":...} 단독 PUT"
send POST "/$REALM/users" "{\"username\":\"victim\",\"enabled\":true,\"email\":\"v@returnit.co.kr\",\"firstName\":\"V\",\"lastName\":\"K\",\"emailVerified\":true,\"credentials\":[{\"type\":\"password\",\"value\":\"$PW\",\"temporary\":false}]}" >/dev/null
vid=$(uid victim)
send PUT "/$REALM/users/$vid" '{"attributes":{"business":["ITGRIMS"]}}' >/dev/null
eq "단독 PUT 은 email/이름을 지운다" "$(g "/$REALM/users/$vid" | jq -c '[.email,.firstName,.lastName]')" '[null,null,null]'
eq "그 계정은 로그인 불가"           "$(login victim)" "FAIL:Account is not fully set up"
echo "  ※ steps/04-assign.sh 는 GET 한 표현에 attributes 만 병합해 PUT 하므로 이 경로를 타지 않는다"

printf '\n\033[1m결과: PASS %d / FAIL %d\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
