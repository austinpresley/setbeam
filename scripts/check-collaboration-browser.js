// Local integration check against an isolated packaged --integration-demo session.
// PLAYWRIGHT_MODULE names an installed playwright-core module; no hosted service is used.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const viewerLayoutEvidence = require('./viewer-layout-evidence');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright-core');
(async () => {
  const session = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const output = process.argv[3] || 'build/collaboration-evidence'; fs.mkdirSync(output, {recursive:true});
  const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless:true});
  const context = await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:2,isMobile:true,hasTouch:true});
  const page = await context.newPage(), errors=[];
  page.on('pageerror', error=>errors.push(error.message));
  try {
    await page.goto(session.viewerURL); console.log('viewer loaded');
    await page.locator('#join-name').fill('Sam, client');
    await page.locator('#join-colors input[value="teal"]').check();
    await page.locator('#join-submit').click(); console.log('join submitted');
    await page.waitForFunction(()=>document.getElementById('state').textContent==='Live feed' && document.getElementById('video').getVideoPlaybackQuality().totalVideoFrames > 24, null, {timeout:30000});
    // An upright phone docks chat under the picture; elsewhere the toggle opens it.
    if (await page.locator('#chat-toggle').isVisible()) await page.locator('#chat-toggle').click();
    await page.locator('#chat-panel').waitFor({state:'visible'});
    await page.waitForTimeout(300);
    const previousCount=await page.locator('.chat-message').count();
    await page.locator('#chat-input').fill('<b>Viewer note</b>');
    await page.locator('#chat-send').click();
    await page.waitForFunction(count=>document.querySelectorAll('.chat-message').length===count+1,previousCount);
    assert.equal(await page.locator('.chat-text b').count(),0,'Viewer content must remain literal');
    assert.equal(await page.locator('.chat-actions').count(),0,'No persistent message action rows');
    await page.locator('.chat-text').last().tap();
    await page.locator('#chat-menu [data-reaction=heart]').click();
    await page.waitForFunction(()=>!!document.querySelector('.chat-reaction.selected'));
    await page.waitForTimeout(600);
    await page.locator('.chat-text').last().tap();
    await page.locator('#chat-menu-reply').click();
    await page.locator('#chat-capture').click();
    await page.locator('#chat-preview').waitFor({state:'visible'});
    await page.locator('#chat-input').fill('This is the frame I mean.');
    await page.locator('#chat-send').click();
    await page.waitForFunction(count=>document.querySelectorAll('.chat-message').length===count+2 && [...document.querySelectorAll('.chat-frame')].some(image=>image.naturalWidth>0),previousCount);
    await page.locator('#chat-input').fill('');
    const emptyComposer = await page.evaluate(viewerLayoutEvidence, []);
    assert.ok(emptyComposer.usable && emptyComposer.form.height <= 56,
      'Empty phone composer must be visible in one row with reachable 44 px controls: ' + JSON.stringify(emptyComposer));
    const reports=[];
    await page.locator('#chat-input').fill('Draft survives rotation');
    for (const [name,width,height] of [['iphone-portrait',390,844],['iphone-landscape',844,390],['ipad-portrait',768,1024],['ipad-landscape',1024,768],['ipad-air-portrait',820,1180],['ipad-air-landscape',1180,820],['split-width',320,640],['short-keyboard',844,260]]) {
      await page.setViewportSize({width,height});
      await page.waitForFunction(docked => document.getElementById('player').classList.contains('chat-docked') === docked, width <= 600 && height > width);
      if (!(await page.locator('#chat-panel').isVisible())) {
        await page.locator('#picture').tap();
        await page.locator('#chat-toggle').tap();
      }
      await page.locator('#chat-panel').waitFor({state:'visible'});
      await page.waitForTimeout(150);
      const geometry = await page.evaluate(viewerLayoutEvidence, []);
      assert.ok(Math.abs(geometry.width - width) <= 1 && Math.abs(geometry.height - height) <= 1, name+' has the wrong visual viewport');
      assert.ok(geometry.scrollWidth<=width+1,name+' has horizontal overflow');
      assert.ok(geometry.usable, name+' composer is hidden, clipped or blocked: '+JSON.stringify(geometry));
      assert.ok(geometry.font>=16,name+' input may trigger focus zoom');
      assert.equal(geometry.draft,'Draft survives rotation');
      if(width<=600 && height>width) assert.ok(geometry.chat.bottom>=height-16 && geometry.chat.bottom<=height,name+' conversation should fill the remaining phone height');
      await page.screenshot({path:path.join(output,name+'.png'),fullPage:true});
      reports.push({name,...geometry});
    }
    await page.locator('.chat-text').last().tap();
    await page.locator('#chat-menu-reply').click();
    await page.locator('#chat-capture').click();
    await page.locator('#chat-preview').waitFor({state:'visible'});
    const chips = await page.evaluate(viewerLayoutEvidence, ['chat-remove-frame', 'chat-cancel-reply']);
    assert.ok(chips.usable, 'Compact draft controls must be visible and reachable: '+JSON.stringify(chips));
    await page.screenshot({path:path.join(output,'compact-draft-controls.png'),fullPage:true});
    await page.locator('#chat-remove-frame').click();
    await page.locator('#chat-cancel-reply').click();
    assert.equal(await page.locator('#chat-input').inputValue(),'Draft survives rotation');
    assert.deepEqual(errors,[],'Browser exceptions');
    const result={passed:true,engine:'installed Chrome',checks:['actual decoded sample','identity/color','literal text','likes','reply','audience frame attachment','54 px empty composer','44 px capture and Send targets','eight layouts','rotation draft retention'],emptyComposer,chips,reports};
    fs.writeFileSync(path.join(output,'browser-results.json'),JSON.stringify(result,null,2));
    console.log(JSON.stringify({passed:true,layouts:reports.length,checks:result.checks}));
  } catch (error) { console.log(JSON.stringify({errors,state:await page.evaluate(()=>({state:document.getElementById('state')?.textContent,copy:document.getElementById('join-copy')?.textContent,status:document.getElementById('join-status')?.textContent,rows:document.querySelectorAll('.chat-message').length,chat:document.getElementById('chat-status')?.textContent}))})); await page.screenshot({path:path.join(output,'failure.png'),fullPage:true}); throw error; } finally { await browser.close(); }
})().catch(error=>{console.error(error.message);process.exitCode=1});
