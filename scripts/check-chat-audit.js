// Runs the shipped chat UI in headless Chromium with an intercepted loopback gateway.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright-core');

async function check() {
  const root = path.resolve(__dirname, '../Sources/SetbeamApp/Resources');
  const browser = await chromium.launch({
    executablePath: process.env.SETBEAM_TEST_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true
  });
  try {
    const page = await browser.newPage({viewport: {width: 1280, height: 800}});
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const line = (id, ownMessage = false) => ({
      id, name: ownMessage ? 'Me' : 'DigiTech', color: 'teal', authorNumber: ownMessage ? 1 : 0,
      operatorMessage: !ownMessage, ownMessage, text: 'Message ' + id, reactions: [], sentAt: id
    });
    let history = [line(1), line(3, true), {...line(8), hasFrame: false, hadFrame: true, sampleFrame: true}];
    let failPoll = false, loseAcknowledgment = false, dropBeforeAccept = false;
    const posts = [], receipts = new Map(), reactions = [];
    let releaseReaction;
    await page.route('http://127.0.0.1:49152/**', async route => {
      const request = route.request(), name = new URL(request.url()).pathname.split('/').at(-1);
      const json = (value, status = 200) => route.fulfill({status, json: value});
      if (name === '') return route.fulfill({path: path.join(root, 'viewer.html')});
      if (name === 'chat.js' || name === 'viewer.css') return route.fulfill({path: path.join(root, name)});
      if (name === 'viewer.js') return route.fulfill({contentType: 'text/javascript', body: `
        const chat = SetbeamChat.attach({pass: () => 'chat-fixture', live: () => true});
        window.updateChat = (revision, displayedRevision, suspended = false) =>
          chat.update({admitted:true, active:true, live:true, revision, displayedRevision, suspended});
        window.chatActivity = id => chat.activity(id);
        const video = document.querySelector('#video');
        Object.defineProperties(video, {readyState:{value:4},videoWidth:{value:640},videoHeight:{value:480}});
        HTMLCanvasElement.prototype.getContext = () => ({drawImage() {}});
        HTMLCanvasElement.prototype.toDataURL = () => 'data:image/jpeg;base64,AA==';
        updateChat(7, 7);
      `});
      if (name !== 'chat') return route.fulfill({body: ''});
      if (request.method() === 'GET') return failPoll ? json({error: 'Test outage'}, 503) : json(history);
      const body = request.postDataJSON();
      if (body.action === 'receipt') return json({ok: true, messageID: receipts.get(body.requestID) ?? null});
      if (body.action === 'post') {
        posts.push(body);
        if (dropBeforeAccept) {
          dropBeforeAccept = false;
          return route.abort('failed');
        }
        const id = 1000 + posts.length;
        receipts.set(body.requestID, id);
        if (loseAcknowledgment) return route.abort('failed');
        history.push({...line(id, true), text: body.text});
        return json({ok: true, messageID: id});
      }
      if (body.action === 'react') {
        reactions.push(body.reaction);
        if (reactions.length === 1) await new Promise(resolve => { releaseReaction = resolve; });
        const message = history.find(message => message.id === body.id);
        message.reactions = body.reaction ? [{reaction: body.reaction, count: 1, selected: true}] : [];
        return json({ok: true});
      }
      return json({error: 'Unexpected action'}, 400);
    });
    const el = id => page.locator('#' + id);
    const wait = (expression, argument) => page.waitForFunction(expression, argument, {timeout: 8000});
    await page.goto('http://127.0.0.1:49152/s/fixture/');
    await wait(() => document.querySelector('#chat-unread').textContent === '2');
    await el('chat-toggle').click();
    await wait(() => document.querySelectorAll('.chat-message').length === 3);
    assert.equal(await el('chat-unread').isHidden(), true, 'Unread excludes own messages and ID gaps');
    assert.match(await page.locator('.chat-message[data-id="8"]').innerText(), /Sample image no longer available/);

    await page.locator('.chat-message[data-id="1"] .chat-bubble').click({button: 'right'});
    await el('chat-menu-reply').click();
    await el('chat-input').fill('Keep the reply draft');
    history = history.filter(message => message.id !== 1);
    await wait(() => document.querySelector('#chat-reply-label').textContent === 'Original message unavailable');
    assert.equal(await el('chat-send').isDisabled(), true);
    assert.equal(await el('chat-input').inputValue(), 'Keep the reply draft');
    await el('chat-input').press('Control+Enter');
    assert.equal(posts.length, 0);
    await el('chat-cancel-reply').click();
    await page.evaluate(() => updateChat(7, 7, true));
    assert.equal(await el('chat-send').isDisabled(), true);
    assert.equal(await el('chat-input').inputValue(), 'Keep the reply draft');
    await page.evaluate(() => updateChat(7, 7));

    await el('chat-capture').click();
    assert.equal(await el('chat-preview').isVisible(), true);
    await page.evaluate(() => updateChat(8, 7));
    assert.equal(await el('chat-capture').isDisabled(), true);
    assert.equal(await el('chat-send').isDisabled(), true);
    await page.evaluate(() => updateChat(8, 8));
    assert.equal(await el('chat-capture').isEnabled(), true);
    assert.equal(await el('chat-send').isDisabled(), true, 'The old capture stays invalid after playback recovers');
    await el('chat-remove-frame').click();

    loseAcknowledgment = true;
    await el('chat-send').click();
    await wait(() => document.querySelector('#chat-input').value === '');
    assert.equal(posts.length, 1, 'A lost POST response reconciles without a visible history row or duplicate post');
    assert.equal(posts[0].text, 'Keep the reply draft');

    loseAcknowledgment = false;
    dropBeforeAccept = true;
    await el('chat-input').fill('Retry the same payload');
    await el('chat-send').click();
    await wait(() => {
      const button = document.querySelector('#chat-send');
      return button.getAttribute('aria-label') === 'Retry same message' && !button.disabled;
    });
    assert.equal(await el('chat-input').getAttribute('readonly'), '');
    await el('chat-send').click();
    await wait(() => document.querySelector('#chat-input').value === '');
    assert.deepEqual(posts[1], posts[2]);

    failPoll = true;
    await wait(() => document.querySelector('#chat-status').textContent.includes('Reconnecting'));
    failPoll = false;
    await wait(() => document.querySelector('#chat-status').textContent === '');
    await el('chat-close').click();
    history = [line(3, true), line(8), line(1040, true), line(1042)];
    await page.evaluate(() => chatActivity(1042));
    await wait(() => document.querySelector('#chat-unread').textContent === '1');
    await el('chat-toggle').click();
    const newest = page.locator('.chat-message[data-id="1042"] .chat-bubble');
    await newest.click({button: 'right'});
    await page.locator('[data-reaction=thumbsUp]').click();
    await newest.click({button: 'right'});
    await page.locator('[data-reaction=laugh]').click();
    assert.deepEqual(reactions, ['thumbsUp'], 'The next reaction waits for the first write');
    releaseReaction();
    await wait(() => document.querySelector('.chat-message[data-id="1042"] .chat-reaction.selected')?.textContent.includes('😂'));
    assert.deepEqual(reactions, ['thumbsUp', 'laugh']);

    history = Array.from({length: 60}, (_, index) => line(1100 + index));
    await wait(() => document.querySelectorAll('.chat-message').length === 60);
    const middle = page.locator('.chat-message[data-id="1130"]');
    await middle.evaluate(element => { element.scrollIntoView({block: 'center'}); element.focus({preventScroll: true}); });
    const before = await middle.evaluate(element => element.getBoundingClientRect().top);
    history = [...history.slice(1), line(1160)];
    await page.locator('.chat-message[data-id="1160"]').waitFor({state: 'attached'});
    assert.equal(await middle.evaluate(element => document.activeElement === element), true);
    assert.ok(Math.abs(await middle.evaluate(element => element.getBoundingClientRect().top) - before) < 2);
    history = history.filter(message => message.id !== 1130);
    await wait(() => document.activeElement.dataset.id === '1131');
    assert.deepEqual(errors, []);
    console.log('PASS: browser chat draft decisions, revision capture, uncertain send, poll recovery, unread counts, reaction order, scroll and focus');
  } finally {
    await browser.close();
  }
}

check().catch(error => { console.error(error); process.exitCode = 1; });
