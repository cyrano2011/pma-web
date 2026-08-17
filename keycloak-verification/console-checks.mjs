// 가이드가 "콘솔 화면"에 대해 주장하는 부분을 실제 admin console 에서 확인한다.
// verify.sh 로 realm 구성을 끝낸 뒤 실행할 것.
//   npm i playwright && node console-checks.mjs
// 환경변수: KC(기본 http://localhost:8080), ADMIN, ADMIN_PW, CHROME(브라우저 실행 경로)
import { chromium } from 'playwright';

const KC = process.env.KC || 'http://localhost:8080';
const ADMIN = process.env.ADMIN || 'admin';
const ADMIN_PW = process.env.ADMIN_PW || 'admin';
const CHROME = process.env.CHROME || undefined;
const REALM = 'itgrims';

let pass = 0, fail = 0;
const chk = (label, actual, expected) => {
  const okv = JSON.stringify(actual) === JSON.stringify(expected);
  console.log(`  ${okv ? '\x1b[32mPASS\x1b[0m' : '\x1b[31mFAIL\x1b[0m'} ${label}` +
    (okv ? ` (= ${JSON.stringify(actual)})` : ` — 기대 ${JSON.stringify(expected)}, 실제 ${JSON.stringify(actual)}`));
  okv ? pass++ : fail++;
};
const hdr = (s) => console.log(`\n\x1b[1m${s}\x1b[0m`);

const b = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] });
const p = await (await b.newContext({ viewport: { width: 1500, height: 1100 } })).newPage();
const text = () => p.locator('body').innerText();
const realmLabel = async () => (await p.locator('nav').first().innerText()).split('\n')[0].trim();
const go = async (hash) => { await p.goto(`${KC}/admin/master/console/${hash}`); await p.reload({ waitUntil: 'networkidle' }); await p.waitForTimeout(3000); };

await p.goto(`${KC}/admin/master/console/`);
await p.fill('#username', ADMIN); await p.fill('#password', ADMIN_PW); await p.click('#kc-login');
await p.waitForTimeout(4000);

hdr('0 단계 — realm 확인 방법');
chk('로그인 직후 콘솔은 master(=Keycloak) realm', await realmLabel(), 'Keycloak');
await p.evaluate((r) => { location.hash = `#/${r}/groups`; }, REALM);
await p.waitForTimeout(6000);
chk('URL 해시만 바꾸면(열려 있는 탭에 URL 붙여넣기) realm 이 따라가지 않는다', await realmLabel(), 'Keycloak');
chk('  → 이때 URL 은 이미 itgrims 를 가리킨다 (해시는 신뢰할 수 없음)', p.url().endsWith(`#/${REALM}/groups`), true);
await p.reload({ waitUntil: 'networkidle' }); await p.waitForTimeout(3000);
chk('새로고침(F5) 후에야 realm 이 전환된다', await realmLabel(), REALM);

hdr('1 단계 — Groups');
chk('Create group 버튼 존재', /Create group/i.test(await text()), true);
chk('business 그룹 노출', /business/.test(await text()), true);

hdr('2 단계 — Realm settings → User profile');
await go(`#/${REALM}/realm-settings/user-profile`);
const t2 = await text();
chk('Create attribute 버튼 존재', /Create attribute/i.test(t2), true);
chk('business 속성이 목록에 있다', /business/.test(t2), true);
await p.click('a:has-text("business")').catch(() => {});
await p.waitForTimeout(2500);
const t2b = await text();
for (const label of ['Display name', 'Multivalued', 'Required field', 'Who can edit', 'Who can view'])
  chk(`속성 편집 화면 필드 "${label}"`, new RegExp(label, 'i').test(t2b), true);

hdr('3 단계 — Clients → 전용 스코프 매퍼');
const cid = await (await fetch(`${KC}/admin/realms/${REALM}/clients?clientId=itgrims-client`, {
  headers: { Authorization: `Bearer ${await adminToken()}` },
}).then(r => r.json()))[0].id;
await go(`#/${REALM}/clients/${cid}/clientScopes/setup`);
const t3 = await text();
chk('itgrims-client-dedicated 링크', /itgrims-client-dedicated/.test(t3), true);
chk('Evaluate 하위 탭', /Evaluate/.test(t3), true);
await p.click('a:has-text("itgrims-client-dedicated")'); await p.waitForTimeout(3000);
chk('Add mapper 존재', /Add mapper/i.test(await text()), true);
await p.click('a:has-text("business-claim")').catch(() => {}); await p.waitForTimeout(2500);
const t3b = await text();
for (const label of ['User Attribute', 'Token Claim Name', 'Claim JSON Type', 'Add to ID token', 'Add to access token', 'Add to userinfo', 'Multivalued'])
  chk(`매퍼 필드 "${label}"`, new RegExp(label, 'i').test(t3b), true);

hdr('4 단계 — 사용자 화면');
const uid = (await fetch(`${KC}/admin/realms/${REALM}/users?username=hq1&exact=true`, {
  headers: { Authorization: `Bearer ${await adminToken()}` },
}).then(r => r.json()))[0].id;
await go(`#/${REALM}/users/${uid}/settings`);
const tabs = [...new Set(await p.locator('[role="tab"]').allInnerTexts())];
chk('사용자 상세 탭 목록에 Attributes 탭이 없다 (Unmanaged attributes = Disabled 기본값)', tabs.includes('Attributes'), false);
chk('  → 대신 Details 탭에 Display name("사업 구분") 필드로 노출', /사업 구분/.test(await text()), true);
chk('탭 구성', tabs.slice(0, 4), ['Details', 'Credentials', 'Role mapping', 'Groups']);
await go(`#/${REALM}/users/${uid}/groups`);
chk('Groups 탭의 Join Group 버튼', /Join Group/i.test(await text()), true);

hdr('5 단계 — Evaluate');
let evaluatedToken = null;
p.on('response', async (r) => {
  if (r.url().includes('generate-example-access-token')) {
    evaluatedToken = await r.json().catch(() => null);
  }
});
await go(`#/${REALM}/clients/${cid}/clientScopes/evaluate`);
await p.locator('[data-testid="user"] input[role="combobox"]').first().click();
await p.keyboard.type('cheonan1', { delay: 60 }); await p.waitForTimeout(2000);
await p.keyboard.press('ArrowDown'); await p.keyboard.press('Enter'); await p.waitForTimeout(1500);
await p.getByRole('tab', { name: /Generated access token/ }).click()
  .catch(() => p.locator('li:has-text("Generated access token")').first().click({ force: true }));
await p.waitForTimeout(3000);
// 화면의 코드 뷰어는 가상 스크롤이라 innerText 로 다 안 잡힌다. 콘솔이 실제로 렌더한
// generate-example-access-token 응답을 가로채서 확인한다.
chk('Evaluate → Generated access token 의 business (콘솔이 받은 응답)',
  evaluatedToken?.business, 'CHEONAN');
chk('  → 배열이 아니라 문자열', typeof evaluatedToken?.business, 'string');

hdr('6 단계 — Users → Attribute search');
await go(`#/${REALM}/users`);
const listRows = (await text()).match(/service-account/g)?.length ?? 0;
chk('기본 Users 목록에는 서비스 계정이 나오지 않는다', listRows, 0);
await p.getByText('Default search', { exact: true }).click(); await p.waitForTimeout(700);
chk('Attribute search 옵션 존재', /Attribute search/i.test(await text()), true);
await p.getByText('Attribute search', { exact: true }).click(); await p.waitForTimeout(900);
await p.getByText('Select attributes', { exact: true }).click(); await p.waitForTimeout(1000);
await p.locator('input[placeholder="Select attribute"]').first().click(); await p.waitForTimeout(800);
const keyOptions = [...new Set(await p.locator('.pf-v5-c-menu__list-item, [role="option"]').allInnerTexts())];
chk('Key 드롭다운은 속성명(business)이 아니라 Display name 으로 보여준다',
  keyOptions.includes('사업 구분') && !keyOptions.includes('business'), true);
await p.locator('.pf-v5-c-menu__list-item:has-text("사업 구분"), [role="option"]:has-text("사업 구분")').first().click();
await p.waitForTimeout(600);
await p.locator('input[placeholder="Type a value"]').first().fill('ITGRIMS');
await p.locator('input[placeholder="Type a value"]').first().locator('xpath=following::button[1]').click();
await p.waitForTimeout(700);
await p.getByRole('button', { name: 'Search', exact: true }).first().click({ force: true });
await p.waitForTimeout(3000);
chk('Attribute search 결과에는 서비스 계정이 포함된다 (목록 총계와 합이 안 맞는 원인)',
  /service-account-itgrims-client/.test(await text()), true);

console.log(`\n\x1b[1m결과: PASS ${pass} / FAIL ${fail}\x1b[0m`);
await b.close();
process.exit(fail === 0 ? 0 : 1);

async function adminToken() {
  const r = await fetch(`${KC}/realms/master/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: 'admin-cli', username: ADMIN, password: ADMIN_PW, grant_type: 'password' }),
  }).then(r => r.json());
  return r.access_token;
}
