#!/usr/bin/env bash
# 1 단계 — 사업 그룹 만들기 (/business, /business/ITGRIMS, /business/CHEONAN)
#   ./01-groups.sh            # dry-run
#   ./01-groups.sh --apply
source "$(dirname "$0")/lib.sh"

hdr "1 단계 — 사업 그룹 만들기 (realm=$REALM)"

pid=$(parent_gid)
if [ -n "$pid" ]; then
  skip "/$PARENT_GROUP 이미 있음"
else
  dry "POST /groups {\"name\":\"$PARENT_GROUP\"}"
  code=$(api_send POST "/$REALM/groups" "{\"name\":\"$PARENT_GROUP\"}")
  sent_ok "$code" || die "부모 그룹 생성 실패 ($code) $(api_err)"
  [ "$APPLY" = 1 ] && { pid=$(parent_gid); ok "/$PARENT_GROUP 생성"; }
fi

for v in $VALUES; do
  if [ -z "$pid" ]; then dry "POST /groups/<business>/children {\"name\":\"$v\"}"; continue; fi
  if [ -n "$(child_gid "$v")" ]; then skip "/$PARENT_GROUP/$v 이미 있음"; continue; fi
  dry "POST /groups/$pid/children {\"name\":\"$v\"}"
  code=$(api_send POST "/$REALM/groups/$pid/children" "{\"name\":\"$v\"}")
  sent_ok "$code" || die "자식 그룹 $v 생성 실패 ($code) $(api_err)"
  [ "$APPLY" = 1 ] && ok "/$PARENT_GROUP/$v 생성"
done

if [ "$APPLY" = 1 ]; then
  hdr "결과"
  api_get "/$REALM/groups/$(parent_gid)/children" | jq -r '.[].path' | sed 's/^/  /'
fi
