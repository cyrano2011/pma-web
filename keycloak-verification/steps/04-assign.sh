#!/usr/bin/env bash
# 4 단계 — 계정별 business 값 + 그룹 배정
#
#   ./04-assign.sh --csv accounts.csv --apply          # username,VALUE 형식 CSV
#   ./04-assign.sh --set cheonan1=CHEONAN --set hq1=ITGRIMS --apply
#   ./04-assign.sh --service-accounts ITGRIMS --apply  # CLIENTS 의 서비스 계정
#   ./04-assign.sh --fill-remaining ITGRIMS --apply    # 값 없는 나머지 전부
#
# 사용자 레코드는 GET 한 표현에 attributes 만 병합해 PUT 한다(콘솔과 동일).
# {"attributes":...} 만 PUT 하는 스크립트는 email/firstName/lastName 을 지워 로그인을 깨뜨린다.
source "$(dirname "$0")/lib.sh"

CSV=""; FILL=""; SA_VALUE=""; declare -a SETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --csv) CSV=$2; shift 2;;
    --set) SETS+=("$2"); shift 2;;
    --fill-remaining) FILL=$2; shift 2;;
    --service-accounts) SA_VALUE=$2; shift 2;;
    --apply) shift;;
    *) die "알 수 없는 인자: $1";;
  esac
done

declare -A ASSIGNED=()      # 이번 실행에서 처리한 계정 (dry-run 에서도 계획이 정확하도록)

valid_value() { case " $VALUES " in *" $1 "*) return 0;; *) return 1;; esac; }

assign_user() {  # assign_user <uid> <label> <value> <join_group:yes|no> <explicit:yes|no>
  local uid=$1 label=$2 value=$3 join=$4 explicit=$5
  ASSIGNED[$label]=$value
  valid_value "$value" || die "허용되지 않는 값: $value (허용: $VALUES)"
  local rep cur
  rep=$(api_get "/$REALM/users/$uid")
  cur=$(echo "$rep" | jq -r --arg a "$ATTR" '.attributes[$a][0] // ""')
  if [ "$cur" = "$value" ]; then
    skip "$label: 이미 $value"
  elif [ -n "$cur" ] && [ "$explicit" != yes ]; then
    warn "$label: 이미 $cur 이므로 건너뜁니다 (덮어쓰려면 --set/--csv 로 명시)"
    return 0
  else
    [ -n "$cur" ] && warn "$label: $cur → $value 로 덮어씁니다"
    local new; new=$(echo "$rep" | jq --arg a "$ATTR" --arg v "$value" '.attributes = ((.attributes // {}) + {($a):[$v]})')
    dry "PUT /users/$uid  ($label ← $value, 다른 필드는 그대로 유지)"
    local code; code=$(api_send PUT "/$REALM/users/$uid" "$new")
    sent_ok "$code" || die "$label 속성 저장 실패 ($code) $(api_err)"
    [ "$APPLY" = 1 ] && ok "$label ← $value"
  fi

  [ "$join" = yes ] || return 0
  local gid; gid=$(child_gid "$value")
  if [ -z "$gid" ]; then warn "$label: /$PARENT_GROUP/$value 그룹이 없습니다 (1 단계 먼저)"; return 0; fi
  if api_get "/$REALM/users/$uid/groups" | jq -e --arg p "/$PARENT_GROUP/$value" 'any(.path==$p)' >/dev/null; then
    skip "$label: 이미 /$PARENT_GROUP/$value 소속"
  else
    dry "PUT /users/$uid/groups/$gid  ($label → /$PARENT_GROUP/$value)"
    local code; code=$(api_send PUT "/$REALM/users/$uid/groups/$gid")
    sent_ok "$code" || die "$label 그룹 가입 실패 ($code) $(api_err)"
    [ "$APPLY" = 1 ] && ok "$label → /$PARENT_GROUP/$value"
  fi
}

# ---- 명시 배정. 가이드 순서대로 CHEONAN(비본사) 을 먼저 처리한다
declare -a PAIRS=()
[ -n "$CSV" ] && { [ -f "$CSV" ] || die "CSV 없음: $CSV"
  while IFS=, read -r u v; do
    u=$(echo "$u" | tr -d ' \r'); v=$(echo "$v" | tr -d ' \r')
    [ -z "$u" ] || [ "${u:0:1}" = "#" ] && continue
    PAIRS+=("$u=$v")
  done < "$CSV"; }
PAIRS+=("${SETS[@]+"${SETS[@]}"}")

if [ ${#PAIRS[@]} -gt 0 ]; then
  hdr "4-1. 명시 배정 (${#PAIRS[@]} 건) — 본사 외 값 먼저"
  first_value=$(printf '%s\n' $VALUES | tail -1)   # VALUES 의 마지막(=CHEONAN) 을 먼저
  for pass in "$first_value" other; do
    for kv in "${PAIRS[@]}"; do
      u=${kv%%=*}; v=${kv#*=}
      if [ "$pass" = "$first_value" ]; then [ "$v" = "$first_value" ] || continue
      else [ "$v" = "$first_value" ] && continue; fi
      uid=$(user_id "$u"); [ -n "$uid" ] || { warn "사용자 '$u' 없음"; continue; }
      assign_user "$uid" "$u" "$v" yes yes
    done
  done
fi

# ---- 서비스 계정 (Users 목록에 안 나오는 계정)
if [ -n "$SA_VALUE" ]; then
  hdr "4-2. 서비스 계정 (clients: $CLIENTS)"
  n=0
  for c in $CLIENTS; do
    cid=$(client_uuid "$c"); [ -n "$cid" ] || { warn "클라이언트 '$c' 없음"; continue; }
    said=$(sa_user_id "$cid")
    if [ -z "$said" ]; then log "[$c] 서비스 계정 없음 (Service accounts roles 비활성)"; continue; fi
    assign_user "$said" "service-account-$c" "$SA_VALUE" no yes
    n=$((n+1))
  done
  echo "$n" > "$(dirname "$0")/.service-account-count"
  log "서비스 계정 $n 개 처리 — 6 단계 판정식에 사용 (.service-account-count 에 기록)"
fi

# ---- 나머지 채우기
if [ -n "$FILL" ]; then
  hdr "4-3. 값 없는 나머지 계정 ← $FILL"
  missing=$(api_get "/$REALM/users?max=10000" | jq -r --arg a "$ATTR" '.[]|select((.attributes[$a][0] // "")=="")|.username')
  [ -z "$missing" ] && { skip "값 없는 계정 없음"; }
  for u in $missing; do
    if [ -n "${ASSIGNED[$u]:-}" ]; then skip "$u: 이번 실행에서 이미 ${ASSIGNED[$u]} 로 처리"; continue; fi
    uid=$(user_id "$u"); assign_user "$uid" "$u" "$FILL" yes no
  done
fi

if [ ${#PAIRS[@]} -eq 0 ] && [ -z "$SA_VALUE" ] && [ -z "$FILL" ]; then
  log "할 일이 없습니다. --csv / --set / --service-accounts / --fill-remaining 중 하나를 주세요."
fi
exit 0
