#!/usr/bin/env bash
# 2 단계 — User Profile 에 business 속성 선언
#   Required=Off, 권한 Admin 전용, options validator(ITGRIMS/CHEONAN), inputType=select
#   ./02-user-profile.sh --apply
source "$(dirname "$0")/lib.sh"

hdr "2 단계 — User Profile 에 '$ATTR' 선언 (realm=$REALM)"
prof=$(api_get "/$REALM/users/profile")

opts=$(printf '%s\n' $VALUES | jq -R . | jq -sc .)
desired=$(jq -nc --arg n "$ATTR" --arg d "$DISPLAY_NAME" --argjson o "$opts" '{
  name:$n, displayName:$d, multivalued:false,
  permissions:{view:["admin"],edit:["admin"]},
  validations:{options:{options:$o}},
  annotations:{inputType:"select"}
}')

if echo "$prof" | jq -e --arg a "$ATTR" 'any(.attributes[]; .name==$a)' >/dev/null; then
  cur=$(echo "$prof" | jq -c --arg a "$ATTR" '.attributes[]|select(.name==$a)')
  if [ "$(echo "$cur" | jq -Sc .)" = "$(echo "$desired" | jq -Sc .)" ]; then
    skip "이미 동일하게 선언되어 있음"; exit 0
  fi
  warn "이미 선언되어 있으나 설정이 다릅니다."
  log "현재: $cur"
  log "적용: $desired"
  new=$(echo "$prof" | jq --arg a "$ATTR" --argjson d "$desired" '.attributes = [.attributes[] | if .name==$a then $d else . end]')
else
  log "적용: $desired"
  new=$(echo "$prof" | jq --argjson d "$desired" '.attributes += [$d]')
fi

# required 는 절대 켜지 않는다 (값 없는 기존 계정 보호)
echo "$new" | jq -e --arg a "$ATTR" '(.attributes[]|select(.name==$a)|has("required")) | not' >/dev/null \
  || die "required 가 설정되려 합니다. 2 단계에서는 Required=Off 여야 합니다."

dry "PUT /users/profile"
code=$(api_send PUT "/$REALM/users/profile" "$new")
sent_ok "$code" || die "User Profile 저장 실패 ($code) $(api_err)"

if [ "$APPLY" = 1 ]; then
  ok "선언 완료: $(api_get "/$REALM/users/profile" | jq -c --arg a "$ATTR" '.attributes[]|select(.name==$a)')"
  hdr "저장 직후 확인 (가이드 요구사항)"
  log "테스트 계정으로 지금 바로 로그인해 보세요. 깨지면 여기서 중단하고 05 스크립트로 원인을 확인합니다."
fi
