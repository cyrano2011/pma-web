#!/usr/bin/env bash
# 수정본 가이드를 콘솔에서 수행하기 직전의 "작업 전 prod 유사" 상태를 빈 Keycloak 에 만든다.
# (realm + 클라이언트 + 사용자. business 속성/그룹/매퍼는 만들지 않는다 — 그건 가이드가 할 일.)
#
#   ./setup-baseline.sh              # 컨테이너까지 새로 띄운다
#   SKIP_DOCKER=1 ./setup-baseline.sh
set -euo pipefail

KC=${KC:-http://localhost:8080}
ADMIN=${ADMIN:-admin}
ADMIN_PW=${ADMIN_PW:-admin}
IMAGE=${IMAGE:-quay.io/keycloak/keycloak:26.4}
CONTAINER=${CONTAINER:-kc-verify}
REALM=itgrims
USER_PW='Passw0rd!'

if [ -z "${SKIP_DOCKER:-}" ]; then
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" -p 8080:8080 \
    -e KC_BOOTSTRAP_ADMIN_USERNAME="$ADMIN" -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PW" \
    "$IMAGE" start-dev >/dev/null
  for _ in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$KC/realms/master/.well-known/openid-configuration")" = 200 ] && break
    sleep 3
  done
fi

T=$(curl -s -d client_id=admin-cli -d "username=$ADMIN" -d "password=$ADMIN_PW" -d grant_type=password \
      "$KC/realms/master/protocol/openid-connect/token" | jq -r .access_token)
post() { curl -s -o /dev/null -w '%{http_code}\n' -X POST "$KC/admin/realms$1" \
  -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "$2"; }

post "" "{\"realm\":\"$REALM\",\"enabled\":true}" >/dev/null
post "/$REALM/clients" "{\"clientId\":\"itgrims-client\",\"enabled\":true,\"publicClient\":false,\"secret\":\"itgrims-secret\",\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":true,\"serviceAccountsEnabled\":true,\"redirectUris\":[\"*\"]}" >/dev/null
for u in hq1 hq2 cheonan1; do
  post "/$REALM/users" "{\"username\":\"$u\",\"enabled\":true,\"email\":\"$u@example.com\",\"firstName\":\"F$u\",\"lastName\":\"L$u\",\"emailVerified\":true,\"credentials\":[{\"type\":\"password\",\"value\":\"$USER_PW\",\"temporary\":false}]}" >/dev/null
done

echo "baseline 준비 완료: realm=$REALM, client=itgrims-client(+서비스 계정), users=hq1,hq2,cheonan1"
