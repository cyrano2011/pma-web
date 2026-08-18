#!/usr/bin/env bash
# 0 단계 — 대상 realm 과 현재 상태 확인 (읽기 전용)
#   ./00-check-realm.sh
source "$(dirname "$0")/lib.sh"

hdr "0 단계 — 대상 realm 확인: $REALM  ($KC)"
[ "$REALM" = master ] && die "REALM 이 master 다. 작업 대상 realm 을 지정하세요."
api_get "/$REALM" | jq -e .realm >/dev/null 2>&1 || die "realm '$REALM' 이 없습니다"
ok "realm '$REALM' 존재 (콘솔 URL: $KC/admin/master/console/#/$REALM/groups)"
log "콘솔에서는 좌측 상단 'Current realm' 배지가 $REALM 인지 확인할 것 (URL 해시만 믿지 말고 F5)"

hdr "master realm 오작업 흔적"
if api_get "/master/groups?search=$PARENT_GROUP" | jq -e --arg n "$PARENT_GROUP" 'any(.name==$n)' >/dev/null 2>&1; then
  warn "master realm 에 '$PARENT_GROUP' 그룹이 있습니다. 실수로 만든 것이면 정리하세요."
else
  ok "master realm 에 '$PARENT_GROUP' 그룹 없음"
fi

hdr "현재 진행 상태"
kids=$(api_get "/$REALM/groups?search=$PARENT_GROUP" | jq -r '.[0].id // empty')
if [ -n "$kids" ]; then
  api_get "/$REALM/groups/$kids/children" | jq -r '.[].path' | sed 's/^/  그룹: /'
else
  log "그룹: 없음 (1 단계 미수행)"
fi

prof=$(api_get "/$REALM/users/profile")
if echo "$prof" | jq -e --arg a "$ATTR" 'any(.attributes[]; .name==$a)' >/dev/null; then
  echo "$prof" | jq -c --arg a "$ATTR" '.attributes[]|select(.name==$a)|{displayName,required:(.required//"off"),permissions,options:(.validations.options.options),annotations}' | sed 's/^/  속성: /'
else
  log "속성: $ATTR 미선언 (2 단계 미수행)"
fi
log "Unmanaged attributes: $(echo "$prof" | jq -r '.unmanagedAttributePolicy // "DISABLED(기본값)"')  ← 기본값 그대로 두세요"

for c in $CLIENTS; do
  cid=$(client_uuid "$c")
  if [ -z "$cid" ]; then warn "클라이언트 '$c' 없음"; continue; fi
  m=$(api_get "/$REALM/clients/$cid/protocol-mappers/models" | jq -c --arg a "$ATTR" '[.[]|select(.config."claim.name"==$a)|{name,protocolMapper,mv:.config.multivalued}]')
  log "클라이언트 $c: 매퍼 $m"
done

total=$(api_get "/$REALM/users/count")
filled=$(api_get "/$REALM/users?max=10000" | jq --arg a "$ATTR" '[.[]|select(.attributes[$a][0] // "" != "")]|length')
log "일반 사용자 $total 명 중 $ATTR 값 보유 $filled 명 (서비스 계정은 이 목록에 없음)"
