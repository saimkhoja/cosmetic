import { expect, test, type Browser, type Page } from '@playwright/test';
import path from 'node:path';
import fs from 'node:fs';

// One full working day, on a fresh install: setup, logins, catalogue, deliveries, an offline
// sale, an invoice correction and the day end report.
const PW = { admin: 'AdminPass2026', op: 'OperatorPass2026', shop: 'ShopAdmin2026', till: 'TillPass2026x' };
const firstPw: Record<string, string> = {};

async function open(browser: Browser) {
  const ctx = await browser.newContext({ acceptDownloads: true });
  await ctx.addInitScript(() => { (window as unknown as { __prints: string[] }).__prints = []; window.print = () => { (window as unknown as { __prints: string[] }).__prints.push(document.getElementById('print-area')!.innerText); }; });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => { throw e; });
  return { ctx, page };
}
async function signIn(page: Page, user: string, pw: string) {
  await page.goto('/');
  await page.fill('#lu', user); await page.fill('#lp', pw); await page.click('#lbtn');
}
async function firstSignIn(page: Page, user: string, newPw: string) {
  await signIn(page, user, firstPw[user]);
  await expect(page.getByText('Choose your own password')).toBeVisible();
  const f = page.locator('input[type=password]');
  await f.nth(0).fill(newPw); await f.nth(1).fill(newPw);
  await page.getByRole('button', { name: 'Save password' }).click();
  await expect(page.locator('header.top')).toBeVisible();
}
const prints = (page: Page) => page.evaluate(() => (window as unknown as { __prints: string[] }).__prints);

test('a full day in SIM', async ({ browser }) => {
  const { page: admin } = await open(browser);
  // ---- first-run setup creates the Admin
  await admin.goto('/');
  await expect(admin.getByText('Set up SIM')).toBeVisible();
  const setupField = (label: string) => admin.locator('.field', { hasText: label }).locator('input').first();
  await setupField('Your full name').fill('Mireille Tshibanda');
  await setupField('Password (10+').fill(PW.admin); await setupField('Password again').fill(PW.admin);
  await setupField('Company name').fill('SIM Beauté Distribution SARL');
  await setupField('Phone').fill('+243 81 000 0000');
  await admin.locator('.frow.three').nth(0).locator('input').nth(0).fill('SIM Beauté Gombe');
  await admin.locator('.frow.three').nth(0).locator('input').nth(1).fill('GOM');
  await admin.getByRole('button', { name: 'Add another shop' }).click();
  await admin.locator('.frow.three').nth(1).locator('input').nth(0).fill('SIM Beauté Limete');
  await admin.locator('.frow.three').nth(1).locator('input').nth(1).fill('LIM');
  await admin.getByRole('button', { name: /Create Admin/ }).click();
  await expect(admin.getByRole('heading', { name: 'Admin dashboard' })).toBeVisible();

  // ---- logins for the other roles; each gets a one-time password
  await admin.getByRole('link', { name: 'Users' }).click();
  for (const [name, user, role, shop] of [['Joseph Mbala', 'operator', 'whop', ''], ['Patrick Kabongo', 'admin.gombe', 'shopadmin', 'SIM Beauté Gombe'], ['Grace Mbuyi', 'till.gombe', 'till', 'SIM Beauté Gombe']]) {
    await admin.getByRole('button', { name: 'Create login' }).click();
    await admin.fill('#un', name); await admin.fill('#uu', user);
    await admin.selectOption('#ur', role);
    if (shop) await admin.selectOption('#us', { label: shop });
    firstPw[user] = await admin.inputValue('#up');
    await admin.locator('.modal footer').getByRole('button', { name: 'Create login' }).click();
    await expect(admin.getByText('Give these details to')).toBeVisible();
    await admin.getByRole('button', { name: 'Done' }).click();
  }
  await expect(admin.locator('table.t tbody tr')).toHaveCount(4);

  // ---- a carton item through the form
  await admin.getByRole('link', { name: 'Inventory' }).click();
  await admin.getByRole('button', { name: 'Add new item' }).click();
  await admin.fill('#in', 'Shea body lotion 400 ml'); await admin.fill('#ic', 'Skin care');
  await admin.fill('#icc', '76'); await admin.fill('#ipc', '24'); await admin.fill('#isell', '5'); await admin.fill('#idz', '57'); await admin.fill('#ictn', '108');
  await admin.fill('#iqc', '8');
  await expect(admin.locator('#iprev')).toContainText('14 250 FC');
  await admin.getByRole('button', { name: 'Save item' }).click();
  await expect(admin.getByText('Item added')).toBeVisible();
  await expect(admin.locator('tr', { hasText: 'Shea body lotion' })).toContainText('192 pcs');

  // ---- Excel import: the app's own template plus the user's CSV
  await admin.getByRole('button', { name: 'Import from Excel' }).click();
  const [dl] = await Promise.all([admin.waitForEvent('download'), admin.getByRole('button', { name: 'Download Excel template' }).click()]);
  const tpl = path.join(test.info().outputDir, 'template.xlsx'); await dl.saveAs(tpl);
  await admin.setInputFiles('.modal input[type=file]', tpl);
  await expect(admin.getByText('3 ready')).toBeVisible();
  await admin.click('#impBtn');
  await expect(admin.getByText('3 items imported')).toBeVisible();
  const csv = path.join(test.info().outputDir, 'items.csv');
  fs.writeFileSync(csv, 'Nom;Catégorie;Carton cost USD;Pcs per carton;Price per pc USD;Price per dozen USD;Price per carton USD;Opening cartons\nMatte lipstick;Make-up;76;48;3;33;130;5\nAloe vera gel 300 ml;Skin care;60;24;4;45;90;1\n');
  await admin.getByRole('button', { name: 'Import from Excel' }).click();
  await admin.setInputFiles('.modal input[type=file]', csv);
  await expect(admin.getByText('1 ready')).toBeVisible();
  await expect(admin.getByText('1 skipped')).toBeVisible();
  await admin.click('#impBtn');
  await expect(admin.getByText('5 items').first()).toBeVisible();

  // ---- the warehouse operator: no costs, sends to both shops, corrects one delivery
  const { page: op } = await open(browser);
  await firstSignIn(op, 'operator', PW.op);
  await expect(op.getByRole('heading', { name: 'Inventory' })).toBeVisible();
  await expect(op.getByText('Cost prices hidden for your role')).toBeVisible();
  await op.getByRole('link', { name: 'Deliveries' }).click();
  await op.getByRole('button', { name: 'New delivery' }).click();
  await op.locator('.modal label.chip', { hasText: 'Gombe' }).click();
  await op.locator('.modal label.chip', { hasText: 'Limete' }).click();
  await op.getByLabel('Send Shea body lotion 400 ml').fill('2');
  await op.getByLabel('Send Matte lipstick').fill('1');
  await expect(op.locator('.modal')).toContainText('to each of 2 outlets');
  await op.getByRole('button', { name: 'Send stock' }).click();
  await expect(op.getByText('2 deliveries sent: DEL-0001, DEL-0002')).toBeVisible();
  await op.locator('.card', { hasText: 'DEL-0002' }).getByRole('button', { name: 'Edit' }).click();
  await op.locator('.modal label.chip', { hasText: 'Gombe' }).click();
  await op.fill('#dreason', 'Loaded on the Gombe truck');
  await op.getByRole('button', { name: 'Save changes' }).click();
  await expect(op.getByText('Delivery updated')).toBeVisible();
  await op.getByRole('link', { name: 'Shop stock' }).click();
  await expect(op.locator('tr', { hasText: 'Shea body lotion' })).toContainText('96 pcs'); // Gombe: 2 deliveries x 2 cartons
  await expect(op.locator('tr', { hasText: 'Shea body lotion' })).toContainText('96 pcs'); // store: 192 - 96

  // ---- the till: sells online, then offline, and the offline sale is sent when back online
  const { ctx: tillCtx, page: till } = await open(browser);
  await firstSignIn(till, 'till.gombe', PW.till);
  await expect(till.locator('nav a')).toHaveCount(1);
  await expect(till.locator('.ptile', { hasText: 'Shea body lotion' })).toContainText('96 in shop');
  await till.locator('.ptile', { hasText: 'Shea body lotion' }).click();
  await till.locator('.ubtn', { hasText: 'pcs' }).first().click();
  await till.locator('.ptile', { hasText: 'Matte lipstick' }).click();
  await till.locator('.ubtn', { hasText: 'dzn' }).click();
  await till.getByRole('button', { name: 'Take cash and print' }).click();
  await expect(till.getByText(/Sale GOM-T1-000001 done/)).toBeVisible();
  expect((await prints(till)).at(-1)).toContain('Copie magasin');
  await expect(till.locator('.modal')).toHaveCount(0);
  await expect(till.locator('#sync, .pill').first()).toContainText('all synced', { timeout: 30000 });

  await tillCtx.setOffline(true);
  await till.reload();                                        // the app itself opens offline (service worker)
  await expect(till.locator('.offline-bar')).toBeVisible();
  await till.locator('.ptile', { hasText: 'Shea body lotion' }).click();
  await till.locator('.ubtn', { hasText: 'carton' }).click();
  await till.getByRole('button', { name: 'Take cash and print' }).click();
  await expect(till.getByText(/Sale GOM-T1-000002 done/)).toBeVisible();
  await expect(till.locator('.pill')).toContainText('1 sale saved on device');
  await expect(till.locator('.ptile', { hasText: 'Shea body lotion' })).toContainText('71 in shop'); // 96 - 1 - 24
  await till.goto('/invoices');
  await expect(till).toHaveURL(/\/till$/);                     // no invoices screen for the till
  await tillCtx.setOffline(false);
  await till.evaluate(() => window.dispatchEvent(new Event('online')));
  await expect(till.locator('.pill')).toContainText('all synced', { timeout: 40000 });

  // ---- the shop admin: sees both sales, corrects one, prints the day end report
  const { page: shop } = await open(browser);
  await firstSignIn(shop, 'admin.gombe', PW.shop);
  await shop.getByRole('link', { name: 'Invoices' }).click();
  await expect(shop.locator('tbody tr')).toHaveCount(2);
  await shop.locator('tr', { hasText: 'GOM-T1-000001' }).getByTitle('Edit invoice').click();
  await shop.locator('.modal tr', { hasText: 'Matte lipstick' }).locator('input').fill('0');   // customer gave the dozen back
  await expect(shop.locator('.modal')).toContainText('Give back to the customer: 94 050 FC');
  await shop.fill('#ereason', 'Customer returned the lipsticks');
  await shop.getByRole('button', { name: 'Save changes' }).click();
  await expect(shop.getByText('Invoice updated')).toBeVisible();
  await shop.getByRole('link', { name: 'Reports' }).click();
  await shop.getByRole('button', { name: 'Today' }).click();
  await shop.getByRole('button', { name: 'Print day end report' }).click();
  const slip = shop.locator('#slips');
  await expect(slip).toContainText('Shift End Report');
  await expect(slip).toContainText('Total Invoice');
  await expect(slip).toContainText('SIM Beauté Gombe');
  const txt = await slip.innerText();
  const n = (k: string) => Number(new RegExp(k + '\\s*:\\s*([\\d.]+)').exec(txt)![1]);
  expect(n('Total Invoice')).toBe(2);
  expect(n('Return FC')).toBe(94050);                          // the returned dozen
  expect(n('Balance FC')).toBe(n('Invoice Value FC'));
  expect(txt).not.toContain('Shea body lotion');               // no item lines on the slip

  // ---- the Admin sees the activity; disabling the till ends its access
  await admin.getByRole('link', { name: 'Activity' }).click();
  await expect(admin.getByText(/Invoice GOM-T1-000001 edited/)).toBeVisible();
  await admin.getByRole('link', { name: 'Users' }).click();
  await admin.locator('tr', { hasText: 'till.gombe' }).getByTitle('Disable account').click();
  await expect(admin.getByText('Account disabled')).toBeVisible();
  const { page: again } = await open(browser);
  await signIn(again, 'till.gombe', PW.till);
  await expect(again.getByText('This account is disabled')).toBeVisible();
});
