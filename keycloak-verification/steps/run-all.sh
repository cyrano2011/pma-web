#!/usr/bin/env bash
# 0~6 단계를 순서대로 실행한다. 인자는 그대로 각 스텝에 전달된다(--apply 등).
#   ./run-all.sh                                   # 전체 dry-run
#   ./run-all.sh --apply --csv accounts.csv
set -uo pipefail
cd "$(dirname "$0")"

CSV=""; APPLY=""; rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --csv) CSV=$2; shift 2;;
    --apply) APPLY=--apply; shift;;
    *) rest+=("$1"); shift;;
  esac
done
FILL=${FILL:-ITGRIMS}
SA=${SA:-ITGRIMS}

step() {  # step <설명> <명령...>
  local desc=$1; shift
  "$@" || { printf '\n\033[31m중단: %s 실패 (종료코드 %s)\033[0m\n' "$desc" "$?"; exit 1; }
}

step "0 단계" ./00-check-realm.sh
step "1 단계" ./01-groups.sh       $APPLY
step "2 단계" ./02-user-profile.sh $APPLY
step "3 단계" ./03-mapper.sh       $APPLY
if [ -n "$CSV" ]; then
  step "4 단계" ./04-assign.sh --csv "$CSV" --service-accounts "$SA" --fill-remaining "$FILL" $APPLY
else
  step "4 단계" ./04-assign.sh --service-accounts "$SA" --fill-remaining "$FILL" $APPLY
fi
if [ -n "$APPLY" ]; then
  step "5 단계" ./05-verify-token.sh
  step "6 단계" ./06-audit.sh
  printf '\n\033[1m0~6 단계 완료. 마무리 체크리스트의 나머지 항목(백업·리허설·실제 로그인)을 확인한 뒤 enforce 하세요.\033[0m\n'
else
  printf '\n  [dry-run] 05/06 은 실제 반영 후에 의미가 있습니다. --apply 로 다시 실행하세요.\n'
fi
