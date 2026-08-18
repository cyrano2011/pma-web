// kcconsoleguide-revised.md 를 "적힌 그대로" admin console 에서 클릭해 수행하고 결과를 검증한다.
// 빈 Keycloak → setup-baseline.sh → 이 스크립트 순서로 실행.
//   npm i playwright
//   CHROME=/opt/pw-browsers/chromium node console-run.mjs
import { chromium } from 'playwright';

const KC = process.env.KC || 'http://localhost:8080';
const ADMIN = process.env.ADMIN || 'admin';
const ADMIN_PW = process.env.ADMIN_PW || 'admin';
const CHROME = process.env.CHROME || undefined;
const REALM = 'itgrims';
const CLIENT = 'itgrims-client';
const CLIENT_SECRET = 'itgrims-secret';
const USER_PW = 'Passw0rd!';

let pass = 0, fail = 0;
const chk = (label, actual, expected) => {
  const okv = JSON.stringify(actual) === JSON.stringify(expected);
  console.log(`  ${okv ? '\x1b[32mPASS\x1b[0m' : '\x1b[31mFAIL\x1b[0m'} ${label}` +
    (okv ? ` (= ${JSON.stringify(actual)})` : ` — 기대 ${JSON.stringify(expected)}, 실제 ${JSON.stringify(actual)}`));
  okv ? pass++ : fail++;
};
const hdr = (s) => console.log(`\n\x1b[1m${s}\x1b[0m`);

// ---------------------------------------------------------------- Admin REST (검증용)
const adminToken = async () => (await (await fetch(`${KC}/realms/master/protocol/openid-connect/token`, {
  method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({ client_id: 'admin-cli', username: ADMIN, password: ADMIN_PW, grant_type: 'password' }),
})).json()).access_token;
const rest = async (path) => (await fetch(`${KC}/admin/realms${path}`,
  { headers: { Authorization: `Bearer ${await adminToken()}` } })).json();
const decode = (jwt) => JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString());
const loginClaim = async (username) => {
  const r = await (await fetch(`${KC}/realms/${REALM}/protocol/openid-connect/token`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: CLIENT, client_secret: CLIENT_SECRET, grant_type: 'password', username, password: USER_PW }),
  })).json();
  return r.access_token ? (decode(r.access_token).business ?? '‹absent›') : `‹login-failed: ${r.error_description}›`;
};

// ---------------------------------------------------------------- 브라우저
const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] });
const page = await (await browser.newContext({ viewport: { width: 1500, height: 1200 } })).newPage();
const text = () => page.locator('body').innerText();
const realmBadge = async () => (await page.locator('nav').first().innerText()).split('\n')[0].trim();
const go = async (hash) => {
  await page.goto(`${KC}/admin/master/console/${hash}`);
  await page.reload({ waitUntil: 'networkidle' });   // 0단계: 붙여넣은 뒤 반드시 새로고침
  await page.waitForTimeout(2500);
};
const clickText = async (t) => { await page.locator(`a:has-text("${t}"), button:has-text("${t}")`).first().click(); await page.waitForTimeout(1500); };

await page.goto(`${KC}/admin/master/console/`);
await page.fill('#username', ADMIN); await page.fill('#password', ADMIN_PW); await page.click('#kc-login');
await page.waitForTimeout(4000);

// ================================================================ 0 단계
hdr('0 단계 — realm 확인 (URL 붙여넣기 → F5 → Current realm 배지)');
await page.evaluate((r) => { location.hash = `#/${r}/groups`; }, REALM);
await page.waitForTimeout(5000);
chk('해시만 바꾼 직후에는 아직 이전 realm 이다 (가이드 경고 재현)', await realmBadge(), 'Keycloak');
await go(`#/${REALM}/groups`);
chk('새로고침 후 Current realm 배지', await realmBadge(), REALM);

// ================================================================ 1 단계
hdr('1 단계 — 사업 그룹 만들기');
await page.getByRole('button', { name: 'Create group' }).first().click(); await page.waitForTimeout(1200);
await page.locator('.pf-v5-c-modal-box input[name="name"]').fill('business');
await page.locator('.pf-v5-c-modal-box').getByRole('button', { name: 'Create' }).click();
await page.waitForTimeout(2500);
await page.locator('a:has-text("business")').first().click(); await page.waitForTimeout(2500);
for (const child of ['ITGRIMS', 'CHEONAN']) {
  await page.locator('button:has-text("Create child group"), button:has-text("Create group")').first().click();
  await page.waitForTimeout(1200);
  await page.locator('.pf-v5-c-modal-box input[name="name"]').fill(child);
  await page.locator('.pf-v5-c-modal-box').getByRole('button', { name: 'Create' }).click();
  await page.waitForTimeout(2500);
}
const parent = (await rest(`/${REALM}/groups?search=business`))[0];
chk('그룹 경로', (await rest(`/${REALM}/groups/${parent.id}/children`)).map(g => g.path).sort(),
  ['/business/CHEONAN', '/business/ITGRIMS']);

// ================================================================ 2 단계
hdr('2 단계 — User Profile 에 business 선언');
await go(`#/${REALM}/realm-settings/user-profile`);
await clickText('Create attribute');
await page.locator('input[name="name"]').fill('business');
await page.locator('#kc-attribute-displayName').fill('사업 구분');
// Multivalued Off / Required field Off 는 기본값 그대로 둔다
chk('Multivalued 기본값 Off', await page.locator('[name="multivalued"]').isChecked(), false);
chk('Required field 기본값 Off', await page.locator('#kc-required').isChecked(), false);
// Who can edit / view — Admin 만
for (const [id, want] of [['user-edit', false], ['admin-edit', true], ['user-view', false], ['admin-view', true]]) {
  const box = page.locator(`#${id}`);
  if (await box.isChecked() !== want) await box.click();
}
// Validations → options 추가 (ITGRIMS, CHEONAN)
await page.getByRole('button', { name: 'Add validator' }).click(); await page.waitForTimeout(1200);
await page.locator('.pf-v5-c-modal-box').getByText('Select an option').first().click(); await page.waitForTimeout(1000);
await page.locator('[role="option"]:has-text("options"), .pf-v5-c-menu__list-item:has-text("options")').first().click();
await page.waitForTimeout(1200);
await page.locator('input[name="config.options.0.value"]').fill('ITGRIMS');
await page.locator('.pf-v5-c-modal-box button:has-text("Add options")').click(); await page.waitForTimeout(600);
await page.locator('input[name="config.options.1.value"]').fill('CHEONAN');
await page.locator('.pf-v5-c-modal-box').getByRole('button', { name: 'Save' }).click(); await page.waitForTimeout(1500);
await page.getByRole('button', { name: 'Create' }).first().click(); await page.waitForTimeout(3000);
const declared = (await rest(`/${REALM}/users/profile`)).attributes.find(a => a.name === 'business');
chk('선언된 속성', {
  displayName: declared?.displayName, multivalued: declared?.multivalued,
  required: declared?.required ?? 'off', permissions: declared?.permissions,
  options: declared?.validations?.options?.options,
}, {
  displayName: '사업 구분', multivalued: false, required: 'off',
  permissions: { view: ['admin'], edit: ['admin'] }, options: ['ITGRIMS', 'CHEONAN'],
});
chk('선언 직후 기존 계정 로그인 정상 (가이드: 즉시 확인)', await loginClaim('hq1'), '‹absent›');
chk('Unmanaged attributes 는 건드리지 않았다',
  (await rest(`/${REALM}/users/profile`)).unmanagedAttributePolicy ?? 'disabled', 'disabled');

// ================================================================ 3 단계
hdr('3 단계 — itgrims-client 에 User Attribute 매퍼');
const clientId = (await rest(`/${REALM}/clients?clientId=${CLIENT}`))[0].id;
await go(`#/${REALM}/clients/${clientId}/clientScopes/setup`);
await page.locator(`a:has-text("${CLIENT}-dedicated")`).click(); await page.waitForTimeout(2500);
// 매퍼가 하나도 없는 전용 스코프는 "Add mapper" 드롭다운이 아니라 빈 화면 버튼을 준다
const emptyState = page.locator('button:has-text("Configure a new mapper")');
chk('빈 전용 스코프의 진입 버튼은 "Configure a new mapper"', await emptyState.count() > 0, true);
if (await emptyState.count()) {
  await emptyState.first().click(); await page.waitForTimeout(1500);
} else {
  await page.locator('button:has-text("Add mapper")').first().click(); await page.waitForTimeout(1000);
  await page.locator('.pf-v5-c-menu__list-item:has-text("By configuration")').first().click(); await page.waitForTimeout(1500);
}
await page.getByText('User Attribute', { exact: true }).first().click();
await page.waitForTimeout(2500);
const group = (label) => page.locator(`label:has-text("${label}")`).first()
  .locator("xpath=ancestor::div[contains(concat(' ', normalize-space(@class), ' '), ' pf-v5-c-form__group ')][1]");
await page.locator('#name').fill('business-claim');
// User Attribute 는 자유 입력이 아니라 "선언된 속성" 드롭다운이다
await group('User Attribute').locator('button.pf-v5-c-menu-toggle').click(); await page.waitForTimeout(900);
const attrOptions = [...new Set(await page.locator('.pf-v5-c-menu__list-item, [role="option"]').allInnerTexts())];
chk('User Attribute 는 드롭다운이며 business 가 선택지에 있다', attrOptions.includes('business'), true);
await page.locator('.pf-v5-c-menu__list-item:has-text("business"), [role="option"]:has-text("business")').first().click();
await page.waitForTimeout(700);
await page.locator('[data-testid="claim.name"]').fill('business');
chk('Claim JSON Type 기본값이 String', (await group('Claim JSON Type').locator('button.pf-v5-c-menu-toggle').innerText()).trim(), 'String');
for (const t of ['Add to ID token', 'Add to access token', 'Add to userinfo']) {
  const sw = group(t).locator('input[type="checkbox"]').first();
  if (await sw.count() && !(await sw.isChecked())) await sw.click();
}
await page.getByRole('button', { name: 'Save' }).first().click(); await page.waitForTimeout(3000);
const mapper = (await rest(`/${REALM}/clients/${clientId}/protocol-mappers/models`)).find(m => m.name === 'business-claim');
chk('매퍼 종류/설정', {
  type: mapper?.protocolMapper, attr: mapper?.config['user.attribute'], claim: mapper?.config['claim.name'],
  json: mapper?.config['jsonType.label'], mv: mapper?.config.multivalued ?? 'false',
  id: mapper?.config['id.token.claim'], at: mapper?.config['access.token.claim'], ui: mapper?.config['userinfo.token.claim'],
}, {
  type: 'oidc-usermodel-attribute-mapper', attr: 'business', claim: 'business',
  json: 'String', mv: 'false', id: 'true', at: 'true', ui: 'true',
});

// ================================================================ 4 단계
hdr('4 단계 — Details 탭 "사업 구분" + Groups 탭 Join Group');
const userId = async (u) => (await rest(`/${REALM}/users?username=${u}&exact=true`))[0].id;
const setBusiness = async (uid, value) => {
  await go(`#/${REALM}/users/${uid}/settings`);
  const tabs = [...new Set(await page.locator('[role="tab"]').allInnerTexts())];
  if (tabs.includes('Attributes')) throw new Error('Attributes 탭이 있으면 안 된다 (Unmanaged attributes 가 켜짐)');
  // options validator 를 콘솔로 넣으면 inputType=select 주석이 자동으로 붙어 드롭다운으로 렌더된다
  await page.locator('#business').click(); await page.waitForTimeout(700);
  const opts = [...new Set(await page.locator('.pf-v5-c-menu__list-item, [role="option"]').allInnerTexts())];
  if (opts.sort().join() !== 'CHEONAN,ITGRIMS') throw new Error(`예상치 못한 선택지: ${opts}`);
  await page.locator(`.pf-v5-c-menu__list-item:has-text("${value}"), [role="option"]:has-text("${value}")`).first().click();
  await page.waitForTimeout(500);
  await page.getByRole('button', { name: 'Save' }).first().click();
  await page.waitForTimeout(2000);
  return opts;
};
const joinGroup = async (uid, groupName) => {
  await go(`#/${REALM}/users/${uid}/groups`);
  await page.getByRole('button', { name: 'Join Group' }).first().click(); await page.waitForTimeout(1500);
  const modal = page.locator('.pf-v5-c-modal-box');
  await modal.locator('button[aria-label="Select"]').first().click();   // business 하위로 진입
  await page.waitForTimeout(1500);
  await modal.locator(`input[type="checkbox"][aria-label="${groupName}"]`).check();
  await modal.locator('[data-testid="join-button"]').click();
  await page.waitForTimeout(2000);
};
// 가이드 순서: 천안 계정 먼저 CHEONAN, 그다음 나머지를 ITGRIMS
const cheonan1 = await userId('cheonan1');
await setBusiness(cheonan1, 'CHEONAN'); await joinGroup(cheonan1, 'CHEONAN');
for (const u of ['hq1', 'hq2']) { const id = await userId(u); await setBusiness(id, 'ITGRIMS'); await joinGroup(id, 'ITGRIMS'); }
chk('일반 계정 3명 속성/그룹', await Promise.all(['cheonan1', 'hq1', 'hq2'].map(async u => {
  const uo = await rest(`/${REALM}/users/${await userId(u)}`);
  const gs = await rest(`/${REALM}/users/${uo.id}/groups`);
  return `${u}:${uo.attributes?.business?.[0]}:${gs.map(g => g.path).join()}`;
})), ['cheonan1:CHEONAN:/business/CHEONAN', 'hq1:ITGRIMS:/business/ITGRIMS', 'hq2:ITGRIMS:/business/ITGRIMS']);

// 4-2. 서비스 계정 — Clients → Service accounts roles 탭 경유
await go(`#/${REALM}/clients/${clientId}/serviceAccount`);
chk('서비스 계정 탭에서 계정 링크가 보인다', /service-account-itgrims-client/.test(await text()), true);
await page.locator(`a:has-text("service-account-${CLIENT}")`).first().click(); await page.waitForTimeout(3000);
await page.locator('#business').click(); await page.waitForTimeout(700);
await page.locator('.pf-v5-c-menu__list-item:has-text("ITGRIMS"), [role="option"]:has-text("ITGRIMS")').first().click();
await page.waitForTimeout(500);
await page.getByRole('button', { name: 'Save' }).first().click(); await page.waitForTimeout(2500);
const sa = await rest(`/${REALM}/clients/${clientId}/service-account-user`);
chk('서비스 계정 속성', sa.attributes?.business?.[0], 'ITGRIMS');
const SERVICE_ACCOUNTS = 1;   // 4-2 에서 값을 넣은 서비스 계정 수 (6단계 판정식에 사용)

// 오타 방어: 콘솔에서는 선택지가 둘뿐이라 오타 입력 자체가 불가능하다
await go(`#/${REALM}/users/${await userId('hq2')}/settings`);
await page.locator('#business').click(); await page.waitForTimeout(700);
chk('사업 구분 드롭다운 선택지는 허용값 2개뿐 (오타 입력 불가)',
  [...new Set(await page.locator('.pf-v5-c-menu__list-item, [role="option"]').allInnerTexts())].sort(),
  ['CHEONAN', 'ITGRIMS']);
await page.keyboard.press('Escape');
chk('REST 경로로 오타를 밀어 넣으면 validator 가 400 으로 막는다', await (async () => {
  const r = await fetch(`${KC}/admin/realms/${REALM}/users/${await userId('hq2')}`, {
    method: 'PUT', headers: { Authorization: `Bearer ${await adminToken()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...(await rest(`/${REALM}/users/${await userId('hq2')}`)), attributes: { business: ['CHEONAM'] } }),
  });
  return r.status;
})(), 400);

// ================================================================ 5 단계
hdr('5 단계 — Evaluate 로 토큰 확인');
const evaluated = {};
page.on('response', async (r) => {
  if (r.url().includes('generate-example-access-token')) {
    const j = await r.json().catch(() => null);
    if (j?.preferred_username) evaluated[j.preferred_username] = j;
  }
});
for (const [user, expect] of [['hq1', 'ITGRIMS'], ['cheonan1', 'CHEONAN']]) {
  await go(`#/${REALM}/clients/${clientId}/clientScopes/evaluate`);
  await page.locator('[data-testid="user"] input[role="combobox"]').first().click();
  await page.keyboard.type(user, { delay: 60 }); await page.waitForTimeout(2000);
  await page.keyboard.press('ArrowDown'); await page.keyboard.press('Enter'); await page.waitForTimeout(1500);
  await page.getByRole('tab', { name: /Generated access token/ }).click()
    .catch(() => page.locator('li:has-text("Generated access token")').first().click({ force: true }));
  await page.waitForTimeout(3000);
  chk(`Evaluate(${user}) 의 business`, evaluated[user]?.business, expect);
  chk(`  → 배열이 아니라 문자열`, typeof evaluated[user]?.business, 'string');
}
chk('실제 로그인 토큰(hq1)', await loginClaim('hq1'), 'ITGRIMS');
chk('실제 로그인 토큰(cheonan1)', await loginClaim('cheonan1'), 'CHEONAN');
chk('실제 로그인 토큰(hq2) — 오타 저장 거부 후에도 값 유지', await loginClaim('hq2'), 'ITGRIMS');
const cc = await (await fetch(`${KC}/realms/${REALM}/protocol/openid-connect/token`, {
  method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({ client_id: CLIENT, client_secret: CLIENT_SECRET, grant_type: 'client_credentials' }),
})).json();
chk('client_credentials 토큰(서비스 계정)', decode(cc.access_token).business, 'ITGRIMS');

// ================================================================ 6 단계
hdr('6 단계 — Attribute search 전수 확인');
const rowCount = async () => (await page.locator('table tbody tr').count());
const attrSearch = async (value) => {
  await go(`#/${REALM}/users`);
  await page.getByText('Default search', { exact: true }).click(); await page.waitForTimeout(700);
  await page.getByText('Attribute search', { exact: true }).click(); await page.waitForTimeout(900);
  await page.getByText('Select attributes', { exact: true }).click(); await page.waitForTimeout(1000);
  await page.locator('input[placeholder="Select attribute"]').first().click(); await page.waitForTimeout(800);
  const keys = [...new Set(await page.locator('.pf-v5-c-menu__list-item, [role="option"]').allInnerTexts())];
  await page.locator('.pf-v5-c-menu__list-item:has-text("사업 구분"), [role="option"]:has-text("사업 구분")').first().click();
  await page.waitForTimeout(600);
  const valueInput = page.locator('input[placeholder="Type a value"]').first();
  await valueInput.fill(value);
  await valueInput.locator('xpath=following::button[1]').click();   // ✓ 로 확정
  await page.waitForTimeout(700);
  await page.getByRole('button', { name: 'Search', exact: true }).first().click({ force: true });
  await page.waitForTimeout(3000);
  return { count: await rowCount(), keys, body: await text() };
};
const itg = await attrSearch('ITGRIMS');
chk('Key 드롭다운은 Display name 으로 표시된다', itg.keys.includes('사업 구분') && !itg.keys.includes('business'), true);
const che = await attrSearch('CHEONAN');
await go(`#/${REALM}/users`);
const listTotal = await rowCount();
console.log(`  ITGRIMS=${itg.count}, CHEONAN=${che.count}, Users 목록 총계=${listTotal}, 서비스 계정=${SERVICE_ACCOUNTS}`);
chk('Attribute search 결과에 서비스 계정 포함', /service-account-itgrims-client/.test(itg.body), true);
chk('Users 목록에는 서비스 계정 미포함', /service-account-itgrims-client/.test(await text()), false);
chk('수정본 판정식: ITGRIMS + CHEONAN == 목록 총계 + 서비스 계정 수',
  itg.count + che.count, listTotal + SERVICE_ACCOUNTS);
chk('참고: 원본 판정식(합 == 목록 총계) 은 성립하지 않는다',
  itg.count + che.count === listTotal, false);

console.log(`\n\x1b[1m결과: PASS ${pass} / FAIL ${fail}\x1b[0m`);
await browser.close();
process.exit(fail === 0 ? 0 : 1);
