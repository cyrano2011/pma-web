# 스텝별 수행 스크립트

`../kcconsoleguide-revised.md` 의 각 단계를 하나씩 실행하는 스크립트다.
콘솔이 호출하는 것과 **동일한 Admin REST 엔드포인트**만 쓰고, 사용자 레코드는
GET 한 표현에 `attributes` 만 병합해 PUT 한다(콘솔과 같은 방식).
가이드가 경고한 `{"attributes": ...}` 단독 PUT — `email`/`firstName`/`lastName` 이 지워져
로그인이 깨지는 그 경로 — 는 타지 않는다.

> 콘솔로 직접 하는 것이 원칙이다. 이 스크립트는 **계정 수가 많아 콘솔 클릭이 비현실적일 때**,
> 그리고 **작업 전후 상태 확인(00)·전수 감사(06)** 용도로 쓴다.

## 안전장치

- **모든 쓰기 스크립트는 기본이 dry-run.** 실제 반영은 `--apply` 를 붙일 때만.
- **멱등하다.** 이미 만들어진 그룹·속성·매퍼·값은 건너뛴다.
- **덮어쓰기 방지.** `--fill-remaining` 은 값이 이미 있는 계정을 건드리지 않는다
  (천안 계정이 본사로 덮이는 사고 방지). 덮어쓰려면 `--set` / `--csv` 로 명시해야 한다.
- **Required=Off 강제.** 02 는 `required` 가 붙으려 하면 중단한다.
- 06 은 누락이 있으면 **종료코드 1** 을 낸다. CI 에서 게이트로 쓸 수 있다.

## 사용법

```bash
export KC=https://auth.returnit.co.kr        # 기본 http://localhost:8080
export REALM=itgrims                          # master 아님
export ADMIN=admin ADMIN_PW='***'
export CLIENTS="itgrims-client"               # 토큰 발급 클라이언트 전부, 공백 구분

./00-check-realm.sh                           # 읽기 전용: realm·진행 상태·master 오작업 흔적
./01-groups.sh          --apply               # /business, /business/{ITGRIMS,CHEONAN}
./02-user-profile.sh    --apply               # business 선언 (Required Off, Admin 전용, options)
./03-mapper.sh          --apply               # 각 클라이언트에 User Attribute 매퍼

./04-assign.sh --csv accounts.csv \
               --service-accounts ITGRIMS \
               --fill-remaining  ITGRIMS --apply

CLIENT_SECRET=*** ./05-verify-token.sh --service-accounts
./06-audit.sh                                 # 판정식 + 누락 목록

./99-rollback.sh --apply                      # 되돌리기 (값→매퍼→그룹→선언 순)
```

한 번에:

```bash
./run-all.sh --csv accounts.csv               # 전체 dry-run (계획만 출력)
./run-all.sh --csv accounts.csv --apply       # 0~6 단계 순차 실행
```

`accounts.csv` 는 `username,VALUE` 형식이다 (`accounts.example.csv` 참고).
CSV 에 없는 계정은 `--fill-remaining` 값으로 채워진다.

```csv
cheonan1,CHEONAN
hq1,ITGRIMS
```

## 스크립트

| 파일 | 하는 일 | 쓰기 |
|---|---|---|
| `lib.sh` | 공통 함수(토큰, API, dry-run) | – |
| `00-check-realm.sh` | realm 확인, 진행 상태, master 오작업 흔적 | 없음 |
| `01-groups.sh` | 사업 그룹 3개 생성 | `--apply` |
| `02-user-profile.sh` | `business` 속성 선언(+`inputType=select`) | `--apply` |
| `03-mapper.sh` | 클라이언트별 User Attribute 매퍼, Group Membership/Multivalued 경고 | `--apply` |
| `04-assign.sh` | 계정별 값·그룹, 서비스 계정, 나머지 채우기 | `--apply` |
| `05-verify-token.sh` | Evaluate 토큰 + client_credentials 검증 | 없음 |
| `06-audit.sh` | 전수 확인, 누락 목록, 판정식 | 없음 |
| `99-rollback.sh` | 되돌리기 | `--apply` |
| `run-all.sh` | 0~6 순차 실행 | `--apply` 전달 |

## 기존 계정 정보가 지워지지 않는지 (데이터 안전성)

`../data-safety-test.sh` 가 빈 Keycloak 에 **기존 운영 데이터를 갖춘 계정**(이메일·이름·emailVerified·
비밀번호·필수 액션·realm 역할·기존 그룹 소속·User Profile 에 선언되지 않은 legacy 속성)을 만들고,
`01~04` 를 돌린 뒤 전후를 필드 단위로 비교한다. **PASS 50 / FAIL 0.**

| 검사 | 결과 |
|---|---|
| email / firstName / lastName / emailVerified / enabled / createdTimestamp | 전부 그대로 |
| requiredActions (`CONFIGURE_TOTP`) | 그대로 |
| credential(비밀번호) — id 까지 동일 | 그대로, 같은 비밀번호로 로그인 성공 |
| realm 역할 (`wms-operator`) | 그대로 |
| 기존 그룹 (`/legacy-team`) | 그대로 + `/business/...` 만 추가 |
| 미선언 legacy 속성 (`dept`, `employeeNo`) | **삭제되지 않음.** Unmanaged 정책이 Disabled 라 화면에서 숨겨질 뿐이고, 정책을 Enabled 로 되돌리면 값이 그대로 나온다 |
| Unmanaged 정책이 Enabled 인 realm 에서 04 재실행 | 다른 속성(`nickname`, `dept`) 유지, `business` 만 변경 |
| 대조군: `{"attributes":...}` 단독 PUT | email/이름이 `null` 이 되고 로그인 불가 — steps/ 는 이 경로를 쓰지 않음 |

```bash
./data-safety-test.sh          # 컨테이너 새로 띄우고 전체 검사
```

## 검증 기록

빈 Keycloak 26.4.7 (`../setup-baseline.sh`) 에서 확인:

- `run-all.sh --apply` 전 과정 통과 — 5단계 토큰 문자열 확인, 6단계 판정식 성립(합 4 = 총계 3 + 서비스 계정 1)
- `run-all.sh` (dry-run) 실행 후 realm 무변경 확인
- 01/02/03/04 재실행 시 모두 "이미 있음" 으로 건너뜀 (멱등)
- `--fill-remaining ITGRIMS` 재실행이 `cheonan1` 의 `CHEONAN` 을 덮지 않음
- 04 실행 후 `email`/`firstName`/`lastName` 보존 확인
- 값 없는 계정을 만들면 06 이 누락으로 잡아내고 종료코드 1
- `99-rollback.sh --apply` 후 00 이 "1·2단계 미수행" 상태로 복귀 확인
