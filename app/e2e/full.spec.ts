import { expect, test, type Browser, type Page } from '@playwright/test';
import path from 'node:path';
import fs from 'node:fs';

// One full working day, on a fresh install: setup, logins, catalogue, deliveries received by the
// shop, orders prepared at the till and approved by the shop admin (one offline), an offline sale,
// an invoice correction and the day end report.
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
  await expect(op.locator('.card', { hasText: 'DEL-0001' })).toContainText('Waiting for the shop to receive');
  await op.getByRole('link', { name: 'Shop stock' }).click();
  const sheaRow = op.locator('tr', { hasText: 'Shea body lotion' });
  await expect(sheaRow).toContainText('192 pcs');                      // nothing has left the store yet
  await expect(sheaRow).toContainText('+96 on the way');

  // ---- the shop admin receives: one in full, one short with a note
  const { page: shop } = await open(browser);
  await firstSignIn(shop, 'admin.gombe', PW.shop);
  await expect(shop.getByText('2 to receive')).toBeVisible();
  await shop.getByRole('link', { name: 'Deliveries' }).click();
  await shop.locator('.card', { hasText: 'DEL-0001' }).getByRole('button', { name: 'Receive' }).click();
  await shop.getByRole('button', { name: 'Approve and add to shop stock' }).click();
  await expect(shop.getByText('DEL-0001 received: 96 of 96 units')).toBeVisible();
  await shop.locator('.card', { hasText: 'DEL-0002' }).getByRole('button', { name: 'Receive' }).click();
  await shop.getByLabel('Received Shea body lotion 400 ml').fill('24');
  await shop.getByRole('button', { name: 'Approve and add to shop stock' }).click();
  await expect(shop.locator('.modal .lerr')).toContainText('arrived short');
  await shop.fill('#rnote', 'One carton missing from the truck');
  await shop.getByRole('button', { name: 'Approve and add to shop stock' }).click();
  await expect(shop.getByText('DEL-0002 received: 72 of 96 units')).toBeVisible();
  await expect(shop.locator('.card', { hasText: 'DEL-0002' })).toContainText('Received, some short');

  // ---- the till operator: customer name first, then items, then send for approval
  const { ctx: tillCtx, page: till } = await open(browser);
  await firstSignIn(till, 'till.gombe', PW.till);
  await expect(till.locator('nav a')).toHaveCount(1);
  await expect(till.locator('.ptile', { hasText: 'Shea body lotion' })).toContainText('72 in shop');   // 48 + 24 received
  await till.locator('.ptile', { hasText: 'Shea body lotion' }).click();
  await expect(till.getByText('Type the customer name first')).toBeVisible();
  await till.fill('#cust', 'Mama Nzuzi'); await till.press('#cust', 'Enter');
  await expect(till.locator('#custname')).toHaveText('Mama Nzuzi');
  await till.locator('.ptile', { hasText: 'Shea body lotion' }).click();
  await till.locator('.ubtn', { hasText: 'pcs' }).first().click();
  await till.locator('.ptile', { hasText: 'Matte lipstick' }).click();
  await till.locator('.ubtn', { hasText: 'dzn' }).click();
  await till.getByRole('button', { name: 'Send to shop admin for approval' }).click();
  await expect(till.getByText('Order for Mama Nzuzi sent to the shop admin for approval')).toBeVisible();
  expect(await prints(till)).toHaveLength(0);                          // nothing printed at the till
  await expect(till.locator('.myorders')).toContainText('Waiting for approval', { timeout: 30000 });
  // a second order while offline is kept and sent later
  await tillCtx.setOffline(true);
  await till.reload();
  await expect(till.locator('.offline-bar')).toBeVisible();
  await till.fill('#cust', 'Papa Lokwa'); await till.press('#cust', 'Enter');
  await till.locator('.ptile', { hasText: 'Shea body lotion' }).click();
  await till.locator('.ubtn', { hasText: 'pcs' }).first().click();
  await till.getByRole('button', { name: 'Send to shop admin for approval' }).click();
  await expect(till.locator('.pill')).toContainText('1 saved on device');
  await expect(till.locator('.myorders')).toContainText('Not sent yet');
  await tillCtx.setOffline(false);
  await till.evaluate(() => window.dispatchEvent(new Event('online')));
  await expect(till.locator('.pill')).toContainText('all synced', { timeout: 40000 });

  // ---- the shop admin reviews: opens the order, adds one pc, approves; rejects the other
  await shop.getByRole('link', { name: 'Till' }).click();
  const review = shop.locator('.review');
  await expect(review.locator('.rcard', { hasText: 'Papa Lokwa' })).toBeVisible({ timeout: 30000 });
  await review.locator('.rcard', { hasText: 'Mama Nzuzi' }).getByRole('button', { name: 'Open' }).click();
  await expect(shop.locator('#custname')).toHaveText('Mama Nzuzi');
  await expect(shop.locator('#cart .line')).toHaveCount(2);
  await shop.locator('#cart .line', { hasText: 'Shea body lotion' }).getByLabel('One more').click();
  await shop.getByRole('button', { name: 'Approve, take cash and print' }).click();
  await expect(shop.getByText(/Sale GOM-T1-000001 for Mama Nzuzi done/)).toBeVisible();
  const slipPrint = (await prints(shop)).at(-1)!;
  expect(slipPrint).toContain('Mama Nzuzi'); expect(slipPrint).toContain('Grace Mbuyi'); expect(slipPrint).toContain('Copie magasin');
  await expect(review.locator('.rcard', { hasText: 'Mama Nzuzi' })).toHaveCount(0);
  await review.locator('.rcard', { hasText: 'Papa Lokwa' }).getByTitle('Reject this order').click();
  await shop.fill('#rreason', 'Customer left');
  await shop.getByRole('button', { name: 'Reject order' }).click();
  await expect(review.locator('.rcard')).toHaveCount(0);
  await till.reload();
  await expect(till.locator('.myorders')).toContainText('Approved', { timeout: 30000 });
  await expect(till.locator('.myorders')).toContainText('Rejected: Customer left');

  // ---- the shop admin sells directly while offline; it is sent when back online
  const shopCtx = shop.context();
  await shopCtx.setOffline(true);
  await shop.reload();
  await expect(shop.locator('.offline-bar')).toBeVisible();
  await shop.fill('#cust', 'Walk-in customer'); await shop.press('#cust', 'Enter');
  await shop.locator('.ptile', { hasText: 'Shea body lotion' }).click();
  await shop.locator('.ubtn', { hasText: 'carton' }).click();
  await shop.getByRole('button', { name: 'Take cash and print' }).click();
  await expect(shop.getByText(/Sale GOM-T1-000002 for Walk-in customer done/)).toBeVisible();
  await expect(shop.locator('.pill')).toContainText('1 saved on device');
  await expect(shop.locator('.ptile', { hasText: 'Shea body lotion' })).toContainText('46 in shop'); // 72 - 2 - 24
  await shopCtx.setOffline(false);
  await shop.evaluate(() => window.dispatchEvent(new Event('online')));
  await expect(shop.locator('.pill')).toContainText('all synced', { timeout: 40000 });

  // ---- correct the approved invoice, then the day end report
  await shop.getByRole('link', { name: 'Invoices' }).click();
  await expect(shop.locator('main table.t tbody tr')).toHaveCount(2);
  await expect(shop.locator('tr', { hasText: 'GOM-T1-000001' })).toContainText('Mama Nzuzi');
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
  await expect(admin.getByText(/Delivery DEL-0002 received/)).toBeVisible();
  await admin.getByRole('link', { name: 'Users' }).click();
  await admin.locator('tr', { hasText: 'till.gombe' }).getByTitle('Disable account').click();
  await expect(admin.getByText('Account disabled')).toBeVisible();
  const { page: again } = await open(browser);
  await signIn(again, 'till.gombe', PW.till);
  await expect(again.getByText('This account is disabled')).toBeVisible();
});
