import { expect, test, type Browser, type Page } from '@playwright/test';
import path from 'node:path';
import fs from 'node:fs';

// One full working day, on a fresh install: setup, logins, categories and catalogue, a supplier,
// goods in and the bill paid, deliveries received by the shop, orders prepared at the till (pcs,
// dozen, half dozen; one offline) and approved, edited or rejected by the shop admin, printed at the
// till, an offline sale, an invoice correction, the day end report, price tickets, a return to the
// store, statements and the trial balance.
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

  // ---- categories are made by the Admin; one is seasonal
  await admin.getByRole('link', { name: 'Inventory' }).click();
  await admin.getByRole('button', { name: 'Categories' }).click();
  for (const c of ['Skin care', 'Make-up']) { await admin.fill('#catname', c); await admin.getByRole('button', { name: 'Add category' }).click(); await expect(admin.locator('.modal tr', { hasText: c })).toBeVisible(); }
  await admin.fill('#catname', 'School'); await admin.locator('.modal label.switch').click(); await admin.locator('.modal .mchips label', { hasText: 'Sep' }).click();
  await admin.getByRole('button', { name: 'Add category' }).click();
  await expect(admin.locator('.modal tr', { hasText: 'School' })).toContainText('Sep');
  await admin.locator('.modal footer').getByRole('button', { name: 'Close' }).click();

  // ---- a carton item through the form, with a half dozen price
  await admin.getByRole('button', { name: 'Add new item' }).click();
  await admin.fill('#in', 'Shea body lotion 400 ml'); await admin.selectOption('#ic', 'Skin care');
  await admin.fill('#icc', '76'); await admin.fill('#ipc', '24'); await admin.fill('#isell', '5'); await admin.fill('#ihz', '29'); await admin.fill('#idz', '57'); await admin.fill('#ictn', '108');
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
  await expect(admin.getByText('3 items imported, 2 new categories made')).toBeVisible();   // Hair care, Fragrance
  const csv = path.join(test.info().outputDir, 'items.csv');
  fs.writeFileSync(csv, 'Nom;Catégorie;Carton cost USD;Pcs per carton;Price per pc USD;Price per dozen USD;Price per carton USD;Opening cartons\nMatte lipstick;Make-up;76;48;3;33;130;5\nAloe vera gel 300 ml;Skin care;60;24;4;45;90;1\n');
  await admin.getByRole('button', { name: 'Import from Excel' }).click();
  await admin.setInputFiles('.modal input[type=file]', csv);
  await expect(admin.getByText('1 ready')).toBeVisible();
  await expect(admin.getByText('1 skipped')).toBeVisible();
  await admin.click('#impBtn');
  await expect(admin.getByText('5 items').first()).toBeVisible();

  // ---- a supplier with credit terms
  await admin.getByRole('link', { name: 'Accounts' }).click();
  await admin.getByRole('button', { name: 'Add supplier' }).click();
  await admin.fill('#sname', 'Beauté Import SARL'); await admin.fill('#sdays', '30');
  await admin.locator('.modal .search input').fill('Shea'); await admin.locator('.modal .mchips label', { hasText: 'Shea body lotion' }).click();
  await admin.getByRole('button', { name: 'Save supplier' }).click();
  await expect(admin.getByText('Supplier added')).toBeVisible();
  // a supplier added by mistake is deleted
  await admin.getByRole('button', { name: 'Add supplier' }).click();
  await admin.fill('#sname', 'Wrong Supplier'); await admin.getByRole('button', { name: 'Save supplier' }).click();
  await expect(admin.locator('tr', { hasText: 'Wrong Supplier' })).toBeVisible();
  admin.once('dialog', (d) => void d.accept());
  await admin.locator('tr', { hasText: 'Wrong Supplier' }).getByTitle('Delete supplier').click();
  await expect(admin.getByText('Wrong Supplier deleted')).toBeVisible();
  await expect(admin.locator('main tbody tr')).toHaveCount(1);

  // ---- the warehouse operator: no costs, sends to both shops, corrects one delivery
  const { page: op } = await open(browser);
  await firstSignIn(op, 'operator', PW.op);
  await expect(op.getByRole('heading', { name: 'Inventory' })).toBeVisible();
  await expect(op.getByText('Cost prices hidden for your role')).toBeVisible();
  // goods from the supplier: the supplier must be chosen; quantities only
  await op.getByRole('link', { name: 'Goods in' }).click();
  await op.getByRole('button', { name: 'Receive from supplier' }).click();
  await op.getByLabel('Quantity Shea body lotion 400 ml').fill('2');
  await op.getByRole('button', { name: 'Add to store stock' }).click();
  await expect(op.locator('.modal .lerr')).toContainText('Choose the supplier');
  await op.selectOption('#gsup', { label: 'Beauté Import SARL' });
  await op.fill('#gref', 'BL 4471');
  await op.getByRole('button', { name: 'Add to store stock' }).click();
  await expect(op.getByText('GRN-0001 saved: 48 units added')).toBeVisible();
  await expect(op.locator('tr', { hasText: 'GRN-0001' })).toContainText('Waiting for the bill');
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
  await expect(sheaRow).toContainText('240 pcs');                      // 192 + 48 from the supplier; nothing has left the store yet
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
  await expect(till.getByText(/Order #\w{6} for Mama Nzuzi sent to the shop admin/)).toBeVisible();
  const orderSlip = (await prints(till)).at(-1)!;                       // the till prints an order slip, not an invoice
  expect(orderSlip).toContain('BON DE COMMANDE'); expect(orderSlip).toContain('Mama Nzuzi'); expect(orderSlip).not.toContain('FACTURE');
  await expect(till.locator('.myorders')).toContainText('Waiting for approval', { timeout: 30000 });
  // a second order while offline is kept and sent later
  await tillCtx.setOffline(true);
  await till.reload();
  await expect(till.locator('.offline-bar')).toBeVisible();
  await till.fill('#cust', 'Papa Lokwa'); await till.press('#cust', 'Enter');
  await till.locator('.ptile', { hasText: 'Shea body lotion' }).click();
  await till.locator('.ubtn', { hasText: 'half dzn' }).click();
  await till.getByRole('button', { name: 'Send to shop admin for approval' }).click();
  await expect(till.locator('.pill')).toContainText('1 saved on device');
  await expect(till.locator('.myorders')).toContainText('Not sent yet');
  await tillCtx.setOffline(false);
  await till.evaluate(() => window.dispatchEvent(new Event('online')));
  await expect(till.locator('.pill')).toContainText('all synced', { timeout: 40000 });
  await till.fill('#cust', 'Tata Mbo'); await till.press('#cust', 'Enter');
  await till.locator('.ptile', { hasText: 'Shea body lotion' }).click();
  await till.locator('.ubtn', { hasText: 'pcs' }).first().click();
  await till.getByRole('button', { name: 'Send to shop admin for approval' }).click();

  // ---- the shop admin reviews from the panel without touching the sale being made:
  //      edits one order and approves it, approves one as it is, rejects one
  await shop.getByRole('link', { name: 'Till' }).click();
  const review = shop.locator('.review');
  await expect(review.locator('.rcard', { hasText: 'Tata Mbo' })).toBeVisible({ timeout: 30000 });
  await shop.fill('#cust', 'Counter customer'); await shop.press('#cust', 'Enter');
  await shop.locator('.ptile', { hasText: 'Matte lipstick' }).click(); await shop.locator('.ubtn', { hasText: 'pcs' }).first().click();
  await review.locator('.rcard', { hasText: 'Mama Nzuzi' }).getByRole('button', { name: 'Edit order for Mama Nzuzi' }).click();
  await expect(shop.locator('.modal tbody tr')).toHaveCount(2);
  await shop.locator('.modal tr', { hasText: 'Shea body lotion' }).getByLabel('One more').click();
  await shop.click('#oapprove');
  await expect(shop.getByText(/Order #\w{6} for Mama Nzuzi approved as GOM-T1-000001/)).toBeVisible();
  const inv1 = (await prints(shop)).at(-1)!;                            // the shop admin prints the invoice on approval
  expect(inv1).toContain('Mama Nzuzi'); expect(inv1).toContain('Grace Mbuyi'); expect(inv1).toContain('Copie magasin');
  await review.locator('.rcard', { hasText: 'Papa Lokwa' }).getByRole('button', { name: 'Approve order for Papa Lokwa' }).click();
  await expect(shop.getByText(/Order #\w{6} for Papa Lokwa approved as GOM-T1-000002/)).toBeVisible();
  expect((await prints(shop)).at(-1)!).toContain('1 x half dzn @ 82 650 FC');
  await expect(shop.locator('#custname')).toHaveText('Counter customer');   // the sale being made is untouched
  await expect(shop.locator('#cart .line')).toHaveCount(1);
  await shop.locator('#cart').getByLabel('Clear sale').click();
  await review.locator('.rcard', { hasText: 'Tata Mbo' }).getByRole('button', { name: 'Reject order for Tata Mbo' }).click();
  await shop.fill('#rreason', 'Customer left');
  await shop.locator('.modal footer').getByRole('button', { name: 'Reject order' }).click();
  await expect(review.locator('.rcard')).toHaveCount(0);
  await expect(shop.locator('.pill')).toContainText('all synced', { timeout: 40000 });
  // the till operator sees what was decided
  await till.reload();
  await expect(till.locator('.myorders')).toContainText('Rejected: Customer left', { timeout: 30000 });
  await expect(till.locator('.morow', { hasText: 'Mama Nzuzi' })).toContainText('Approved');
  // price tickets at the till, with the units chosen
  await till.getByRole('button', { name: 'Tickets' }).click();
  await till.locator('#tunits label', { hasText: 'Half dozen' }).click();
  await till.locator('#tunits label', { hasText: 'Carton' }).click();
  await till.getByLabel('Tickets for Shea body lotion 400 ml').fill('3');
  await till.click('#tprint');
  const tk = (await prints(till)).at(-1)!;
  expect(tk).toContain('SHEA BODY LOTION 400 ML'); expect(tk).toContain('14 250 FC'); expect(tk).toContain('HALF DOZEN (6)'); expect(tk).not.toContain('CARTON');
  await till.locator('.modal footer').getByRole('button', { name: 'Close' }).click();

  // ---- the shop admin sells directly while offline; it is sent when back online
  const shopCtx = shop.context();
  await shopCtx.setOffline(true);
  await shop.reload();
  await expect(shop.locator('.offline-bar')).toBeVisible();
  await shop.fill('#cust', 'Walk-in customer'); await shop.press('#cust', 'Enter');
  await shop.locator('.ptile', { hasText: 'Shea body lotion' }).click();
  await shop.locator('.ubtn', { hasText: 'carton' }).click();
  await shop.getByRole('button', { name: 'Take cash and print' }).click();
  await expect(shop.getByText(/Sale GOM-T1-000003 for Walk-in customer done/)).toBeVisible();
  await expect(shop.locator('.pill')).toContainText('1 saved on device');
  await expect(shop.locator('.ptile', { hasText: 'Shea body lotion' })).toContainText('40 in shop'); // 72 - 2 - 6 - 24
  await shopCtx.setOffline(false);
  await shop.evaluate(() => window.dispatchEvent(new Event('online')));
  await expect(shop.locator('.pill')).toContainText('all synced', { timeout: 40000 });

  // ---- correct the approved invoice, then the day end report
  await shop.getByRole('link', { name: 'Invoices' }).click();
  await expect(shop.locator('main table.t tbody tr')).toHaveCount(3);
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
  expect(n('Total Invoice')).toBe(3);
  expect(n('Return FC')).toBe(94050);                          // the returned dozen
  expect(n('Balance FC')).toBe(n('Invoice Value FC'));
  expect(txt).not.toContain('Shea body lotion');               // no item lines on the slip
  await shop.locator('.modal footer').getByRole('button', { name: 'Close' }).click();

  // ---- the shop sends 2 pcs back; the warehouse receives them
  await shop.getByRole('link', { name: 'Returns' }).click();
  await shop.getByRole('button', { name: 'New return' }).click();
  await shop.fill('#retr', 'Damaged packaging');
  await shop.getByLabel('Quantity Shea body lotion 400 ml').fill('2');
  await shop.locator('.modal tr', { hasText: 'Shea body lotion' }).locator('select').selectOption('pcs');
  await shop.getByRole('button', { name: 'Send back' }).click();
  await expect(shop.getByText('RET-0001 sent to the central store')).toBeVisible();
  await op.getByRole('link', { name: 'Returns' }).click();
  await op.locator('.card', { hasText: 'RET-0001' }).getByRole('button', { name: 'Receive' }).click();
  await op.getByRole('button', { name: 'Receive into the store' }).click();
  await expect(op.getByText('RET-0001 received: 2 of 2 units')).toBeVisible();
  // the warehouse reads the Gombe stock account; the shop reads its cash account
  await op.getByRole('link', { name: 'Statements' }).click();
  await op.selectOption('#stacc', { label: 'Stock – SIM Beauté Gombe' });
  await expect(op.locator('#sttable')).toContainText('DEL-0001');
  await expect(op.locator('#sttable')).toContainText('RET-0001');
  await shop.getByRole('link', { name: 'Statements' }).click();
  await shop.selectOption('#stacc', { label: 'Cash – SIM Beauté Gombe (FC)' });
  await expect(shop.locator('#sttable')).toContainText('GOM-T1-000003');
  await expect(shop.locator('#stclose')).toContainText('Dr');

  // ---- the shop admin changes a line's unit, deletes an invoice and prints a stock count sheet
  await shop.getByRole('link', { name: 'Invoices' }).click();
  await shop.locator('tr', { hasText: 'GOM-T1-000003' }).getByTitle('Edit invoice').click();
  await shop.locator('.modal select[data-eu="0"]').selectOption({ label: 'dzn (12)' });
  await shop.locator('.modal input[data-eq="0"]').fill('2');
  await expect(shop.locator('.modal')).toContainText('New total 324 900 FC');      // 2 dozen at 162 450 FC instead of 1 carton
  await shop.fill('#ereason', 'Customer took 2 dozen');
  await shop.getByRole('button', { name: 'Save changes' }).click();
  await expect(shop.getByText('Invoice updated')).toBeVisible();
  await expect(shop.locator('tr', { hasText: 'GOM-T1-000003' })).toContainText('324 900 FC');
  await shop.locator('tr', { hasText: 'GOM-T1-000002' }).getByTitle('Delete invoice').click();
  await shop.fill('#dreason', 'Customer cancelled');
  await shop.click('#delbtn');
  await expect(shop.getByText('Invoice GOM-T1-000002 deleted')).toBeVisible();
  await expect(shop.locator('main table.t tbody tr')).toHaveCount(2);
  await shop.getByRole('link', { name: 'Stock' }).click();
  await expect(shop.locator('tr', { hasText: 'Shea body lotion' })).toContainText('44');     // 38 + the 6 pcs of the deleted invoice
  await shop.getByRole('button', { name: 'Print stock count sheet' }).click();
  const sheet = (await prints(shop)).at(-1)!;
  expect(sheet).toContain('Stock count sheet'); expect(sheet).toContain('Shea body lotion'); expect(sheet).toContain('Counted');

  // ---- the Admin enters the supplier's bill, pays it, and the trial balance agrees
  await admin.getByRole('link', { name: 'Goods in' }).click();
  await admin.locator('tr', { hasText: 'GRN-0001' }).getByRole('button', { name: 'Enter bill' }).click();
  await admin.fill('#bno', 'F-1001'); await admin.fill('#bamt', '160');
  await admin.getByRole('button', { name: 'Save bill' }).click();
  await expect(admin.getByText(/Bill F-1001 entered/)).toBeVisible();
  await admin.getByRole('link', { name: 'Accounts' }).click();
  await admin.getByRole('button', { name: 'Bills & payables' }).click();
  await expect(admin.locator('tr', { hasText: 'F-1001' })).toContainText('$160.00');
  await admin.locator('tr', { hasText: 'Beauté Import SARL' }).getByRole('button', { name: 'Pay' }).click();
  await admin.locator('.modal .vamt').nth(0).fill('100'); await admin.locator('.modal .vamt').nth(1).fill('100');
  await admin.getByRole('button', { name: 'Oldest bills first' }).click();
  await admin.getByRole('button', { name: 'Save voucher' }).click();
  await expect(admin.getByText(/Payment PAY-00001 saved/)).toBeVisible();
  await expect(admin.locator('tr', { hasText: 'F-1001' })).toContainText('$60.00');
  await admin.getByRole('button', { name: 'Trial balance' }).click();
  const last = admin.locator('#tb tr').last().locator('td');
  await expect(last.nth(1)).toHaveText(/\$[\d,.]+/);                 // Total | Dr | Cr
  expect(await last.nth(1).innerText()).toBe(await last.nth(2).innerText());

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
