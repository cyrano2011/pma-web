#!/usr/bin/env bash
# 6 단계 — 누락 계정 전수 확인
#   판정식:  Σ(값별 건수) == (Users 목록 총계) + (값을 넣은 서비스 계정 수)
#   ./06-audit.sh                 # 서비스 계정 수는 04 단계가 남긴 기록을 사용
#   SERVICE_ACCOUNTS=2 ./06-audit.sh
source "$(dirname "$0")/lib.sh"

hdr "6 단계 — 전수 확인 (realm=$REALM)"

sum=0
for v in $VALUES; do
  n=$(api_get "/$REALM/users/count?q=$ATTR:$v")
  printf '  %-10s %s 건 (Attribute search, 서비스 계정 포함)\n' "$v" "$n"
  sum=$((sum + n))
done
total=$(api_get "/$REALM/users/count")
cnt_file="$(dirname "$0")/.service-account-count"
SERVICE_ACCOUNTS=${SERVICE_ACCOUNTS:-$( [ -f "$cnt_file" ] && cat "$cnt_file" || echo 0 )}

echo
printf '  합계 %s  vs  Users 목록 총계 %s + 서비스 계정 %s = %s\n' \
  "$sum" "$total" "$SERVICE_ACCOUNTS" "$((total + SERVICE_ACCOUNTS))"

hdr "값이 없는 일반 계정"
missing=$(api_get "/$REALM/users?max=10000" | jq -r --arg a "$ATTR" '.[]|select((.attributes[$a][0] // "")=="")|.username')
if [ -n "$missing" ]; then
  echo "$missing" | sed 's/^/  /'
  warn "$(echo "$missing" | wc -l) 명 누락 — enforce 하면 이 계정들이 403 BUSINESS_CLAIM_MISSING 이 됩니다"
else
  ok "누락 없음"
fi

hdr "서비스 계정 상태 (Users 목록에는 안 나옴)"
for c in $CLIENTS; do
  cid=$(client_uuid "$c"); [ -n "$cid" ] || continue
  said=$(sa_user_id "$cid"); [ -n "$said" ] || { log "[$c] 서비스 계정 없음"; continue; }
  v=$(api_get "/$REALM/users/$said" | jq -r --arg a "$ATTR" '.attributes[$a][0] // "‹없음›"')
  [ "$v" = "‹없음›" ] && warn "[$c] service account: 값 없음" || ok "[$c] service account: $v"
done

hdr "판정"
if [ "$sum" -eq "$((total + SERVICE_ACCOUNTS))" ] && [ -z "$missing" ]; then
  ok "판정식 성립 · 누락 0 — 체크리스트의 나머지 항목까지 끝나면 enforce 가능"
else
  die "판정식 불일치 또는 누락 있음. 원본 가이드의 '합 == 전체 사용자 수' 는 서비스 계정 때문에 성립하지 않습니다."
fi
