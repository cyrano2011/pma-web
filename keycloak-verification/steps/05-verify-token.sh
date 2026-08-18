#!/usr/bin/env bash
# 5 단계 — 토큰에 클레임이 문자열로 실리는지 확인 (비밀번호 불필요)
#   ./05-verify-token.sh hq1 cheonan1
#   ./05-verify-token.sh                 # 값이 있는 계정에서 값별로 1명씩 자동 선택
#   CLIENT_SECRET=... ./05-verify-token.sh --service-accounts
source "$(dirname "$0")/lib.sh"

SA_CHECK=0; declare -a USERS=()
for a in "$@"; do case "$a" in --service-accounts) SA_CHECK=1;; --apply) ;; *) USERS+=("$a");; esac; done

if [ ${#USERS[@]} -eq 0 ]; then
  for v in $VALUES; do
    u=$(api_get "/$REALM/users?q=$ATTR:$v&max=1" | jq -r '.[0].username // empty')
    [ -n "$u" ] && USERS+=("$u")
  done
fi
[ ${#USERS[@]} -gt 0 ] || die "검증할 계정이 없습니다. 계정명을 인자로 주세요."

fail=0
for c in $CLIENTS; do
  cid=$(client_uuid "$c"); [ -n "$cid" ] || { warn "클라이언트 '$c' 없음"; continue; }
  hdr "5 단계 — [$c] Evaluate (콘솔 Client scopes → Evaluate 와 동일)"
  for u in "${USERS[@]}"; do
    uid=$(user_id "$u"); [ -n "$uid" ] || { warn "사용자 '$u' 없음"; fail=1; continue; }
    tok=$(api_get "/$REALM/clients/$cid/evaluate-scopes/generate-example-access-token?scope=&userId=$uid")
    val=$(echo "$tok" | jq -c --arg a "$ATTR" '.[$a] // null')
    typ=$(echo "$tok" | jq -r --arg a "$ATTR" '.[$a] | type')
    case "$typ" in
      string) ok "$u → $val" ;;
      array)  printf '  %sFAIL%s %s → %s  (배열. Group Membership 매퍼이거나 Multivalued=On)\n' "$c_no" "$c_0" "$u" "$val"; fail=1 ;;
      *)      printf '  %sFAIL%s %s → 클레임 없음 (매퍼 미적용 또는 값 미배정)\n' "$c_no" "$c_0" "$u"; fail=1 ;;
    esac
  done
done

if [ "$SA_CHECK" = 1 ]; then
  hdr "서비스 계정 (client_credentials)"
  [ -n "${CLIENT_SECRET:-}" ] || die "CLIENT_SECRET 환경변수가 필요합니다 (Clients → Credentials 탭)"
  for c in $CLIENTS; do
    at=$(curl -s -d "client_id=$c" -d "client_secret=$CLIENT_SECRET" -d grant_type=client_credentials \
      "$KC/realms/$REALM/protocol/openid-connect/token" | jq -r '.access_token // empty')
    [ -n "$at" ] || { warn "[$c] client_credentials 실패 (secret 확인)"; continue; }
    pl=$(printf '%s==' "$(echo "$at" | cut -d. -f2)" | base64 -d 2>/dev/null)
    v=$(echo "$pl" | jq -c --arg a "$ATTR" '.[$a] // "‹absent›"')
    [ "$(echo "$pl" | jq -r --arg a "$ATTR" '.[$a]|type')" = string ] \
      && ok "[$c] service account → $v" \
      || { printf '  %sFAIL%s [%s] service account → %s\n' "$c_no" "$c_0" "$c" "$v"; fail=1; }
  done
fi

hdr "판정"
[ "$fail" = 0 ] && ok "모두 문자열로 실림" || die "위 FAIL 을 해결하기 전에는 enforce 로 넘어가지 마세요"
