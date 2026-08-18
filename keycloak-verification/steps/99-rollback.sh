#!/usr/bin/env bash
# 되돌리기 — 4단계 값/그룹 → 3단계 매퍼 → 1단계 그룹 → 2단계 선언 순으로 제거
#   ./99-rollback.sh --apply
# 주의: 값만 지우면 토큰 클레임은 사라지지만, 콘솔 입력 필드와 값 검증을 원상복구하려면
#       2단계 선언까지 지워야 한다.
source "$(dirname "$0")/lib.sh"

hdr "되돌리기 (realm=$REALM)"
[ "$APPLY" = 1 ] || warn "dry-run 입니다. 실제 삭제는 --apply"

hdr "4 단계 — 사용자 속성/그룹"
for uid in $(api_get "/$REALM/users?max=10000" | jq -r '.[].id'); do
  rep=$(api_get "/$REALM/users/$uid"); u=$(echo "$rep" | jq -r .username)
  if echo "$rep" | jq -e --arg a "$ATTR" '.attributes[$a] // empty' >/dev/null; then
    dry "PUT /users/$uid ($u 의 $ATTR 제거)"
    code=$(api_send PUT "/$REALM/users/$uid" "$(echo "$rep" | jq --arg a "$ATTR" 'del(.attributes[$a])')")
    sent_ok "$code" && [ "$APPLY" = 1 ] && ok "$u 속성 제거"
  fi
  for p in $(api_get "/$REALM/users/$uid/groups" | jq -r --arg g "/$PARENT_GROUP/" '.[]|select(.path|startswith($g))|.id'); do
    dry "DELETE /users/$uid/groups/$p ($u)"
    code=$(api_send DELETE "/$REALM/users/$uid/groups/$p"); sent_ok "$code" && [ "$APPLY" = 1 ] && ok "$u 그룹 탈퇴"
  done
done
for c in $CLIENTS; do
  cid=$(client_uuid "$c"); [ -n "$cid" ] || continue
  said=$(sa_user_id "$cid"); [ -n "$said" ] || continue
  rep=$(api_get "/$REALM/users/$said")
  if echo "$rep" | jq -e --arg a "$ATTR" '.attributes[$a] // empty' >/dev/null; then
    dry "PUT /users/$said (service-account-$c)"
    code=$(api_send PUT "/$REALM/users/$said" "$(echo "$rep" | jq --arg a "$ATTR" 'del(.attributes[$a])')")
    sent_ok "$code" && [ "$APPLY" = 1 ] && ok "service-account-$c 속성 제거"
  fi
done

hdr "3 단계 — 매퍼"
for c in $CLIENTS; do
  cid=$(client_uuid "$c"); [ -n "$cid" ] || continue
  for mid in $(api_get "/$REALM/clients/$cid/protocol-mappers/models" | jq -r --arg a "$ATTR" '.[]|select(.config."claim.name"==$a)|.id'); do
    dry "DELETE /clients/$cid/protocol-mappers/models/$mid ($c)"
    code=$(api_send DELETE "/$REALM/clients/$cid/protocol-mappers/models/$mid"); sent_ok "$code" && [ "$APPLY" = 1 ] && ok "[$c] 매퍼 제거"
  done
done

hdr "1 단계 — 그룹"
pid=$(parent_gid)
if [ -n "$pid" ]; then
  dry "DELETE /groups/$pid (/$PARENT_GROUP 이하 전체)"
  code=$(api_send DELETE "/$REALM/groups/$pid"); sent_ok "$code" && [ "$APPLY" = 1 ] && ok "/$PARENT_GROUP 삭제"
fi

hdr "2 단계 — User Profile 선언"
prof=$(api_get "/$REALM/users/profile")
if echo "$prof" | jq -e --arg a "$ATTR" 'any(.attributes[]; .name==$a)' >/dev/null; then
  dry "PUT /users/profile ($ATTR 선언 제거)"
  code=$(api_send PUT "/$REALM/users/profile" "$(echo "$prof" | jq --arg a "$ATTR" '.attributes |= map(select(.name != $a))')")
  sent_ok "$code" && [ "$APPLY" = 1 ] && ok "$ATTR 선언 제거"
fi
rm -f "$(dirname "$0")/.service-account-count"
