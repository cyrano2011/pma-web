#!/usr/bin/env bash
# 3 단계 — 각 클라이언트 전용 스코프에 User Attribute 매퍼 추가
#   CLIENTS="itgrims-client other-api" ./03-mapper.sh --apply
source "$(dirname "$0")/lib.sh"

MAPPER_NAME=${MAPPER_NAME:-business-claim}
hdr "3 단계 — User Attribute 매퍼 '$MAPPER_NAME' (clients: $CLIENTS)"

body=$(jq -nc --arg n "$MAPPER_NAME" --arg a "$ATTR" '{
  name:$n, protocol:"openid-connect", protocolMapper:"oidc-usermodel-attribute-mapper",
  config:{ "user.attribute":$a, "claim.name":$a, "jsonType.label":"String",
           "id.token.claim":"true", "access.token.claim":"true", "userinfo.token.claim":"true",
           "multivalued":"false" }}')

for c in $CLIENTS; do
  cid=$(client_uuid "$c")
  [ -n "$cid" ] || { warn "클라이언트 '$c' 없음 — 건너뜀"; continue; }
  existing=$(api_get "/$REALM/clients/$cid/protocol-mappers/models" | jq -c --arg a "$ATTR" '[.[]|select(.config."claim.name"==$a)]')

  # Group Membership 매퍼가 같은 클레임을 쓰고 있으면 배열이 나가 전원 403 이 된다
  if echo "$existing" | jq -e 'any(.[]; .protocolMapper=="oidc-group-membership-mapper")' >/dev/null; then
    warn "[$c] Group Membership 매퍼가 '$ATTR' 클레임을 쓰고 있습니다. 배열로 나가므로 제거해야 합니다."
  fi

  if echo "$existing" | jq -e --arg n "$MAPPER_NAME" 'any(.[]; .name==$n and .protocolMapper=="oidc-usermodel-attribute-mapper")' >/dev/null; then
    cur=$(echo "$existing" | jq -c --arg n "$MAPPER_NAME" '.[]|select(.name==$n)|{mv:.config.multivalued,json:.config."jsonType.label",at:.config."access.token.claim"}')
    skip "[$c] 매퍼 이미 있음 $cur"
    echo "$cur" | jq -e '.mv=="false"' >/dev/null || warn "[$c] Multivalued 가 On 입니다. 배열로 나가므로 Off 로 바꾸세요."
    continue
  fi

  dry "[$c] POST /clients/$cid/protocol-mappers/models"
  code=$(api_send POST "/$REALM/clients/$cid/protocol-mappers/models" "$body")
  sent_ok "$code" || die "[$c] 매퍼 생성 실패 ($code) $(api_err)"
  [ "$APPLY" = 1 ] && ok "[$c] 매퍼 추가"
done

hdr "참고"
log "토큰을 발급받는 클라이언트가 더 있으면 CLIENTS 에 모두 넣어 다시 실행하세요."
builtin='["account","account-console","broker","realm-management","security-admin-console"]'
log "이 realm 의 운영 클라이언트 후보: $(api_get "/$REALM/clients?briefRepresentation=true&max=200" | jq -r --argjson b "$builtin" '[.[]|select(.clientId as $c | ($b|index($c))|not)|.clientId]|join(", ")')"
