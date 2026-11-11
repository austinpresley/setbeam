/* Session-only collaboration. Content is plain text, and image requests need the admitted pass. */
(() => {
  function attach(options) {
    const $ = id => document.getElementById(id);
    const player = $('player'), toggle = $('chat-toggle'), panel = $('chat-panel'), log = $('chat-log');
    if (!toggle || !panel || !log) return {update() {}};
    const form = $('chat-form'), input = $('chat-input'), send = $('chat-send'), status = $('chat-status');
    const capture = $('chat-capture'), preview = $('chat-preview'), reply = $('chat-reply');
    let admitted = false, active = false, live = false, revision = -1, open = false, posting = false, polling = false;
    let attachment, replyTo, requestID, timer, generation = 0, lastJSON = '';
    let readThrough = 0, lastActivity = 0;
    function activity(id) {
      if (!Number.isSafeInteger(id) || id < 0) return;
      lastActivity = id; if (open) readThrough = Math.max(readThrough, id);
      const unread = Math.min(99, Math.max(0, lastActivity - readThrough)), badge = $('chat-unread');
      if (badge) { badge.hidden = !unread; text(badge, String(unread)); }
      toggle.setAttribute('aria-label', unread ? 'Open session chat, ' + unread + ' unread messages' : 'Open session chat');
    }
    const rows = new Map(), blobs = new Map(), loadingFrames = new Set();
    const uuid = () => globalThis.crypto?.randomUUID?.() || Math.random().toString(36).slice(2) + Date.now().toString(36);
    const text = (element, value) => { if (element.textContent === value) return; if (element.childNodes.length === 1 && element.firstChild.nodeType === 3) element.firstChild.nodeValue = value; else element.textContent = value; };
    async function request(path, body) {
      const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 5000);
      try {
        const response = await fetch(path, {method: body ? 'POST' : 'GET', cache: 'no-store', signal: controller.signal,
          headers: {'X-Setbeam-Pass': options.pass() || '', ...(body ? {'Content-Type': 'application/json'} : {})},
          ...(body ? {body: JSON.stringify(body)} : {})});
        if (response.status === 403 || response.status === 404) { reset(); throw Error('Chat access ended.'); }
        const result = await response.json();
        if (!response.ok) throw Error(result?.error || 'Chat could not update. Try again.');
        return result;
      } finally { clearTimeout(timeout); }
    }
    function clearAttachment() {
      if (attachment) requestID = undefined;
      attachment = undefined; preview.hidden = true; $('chat-frame-preview').removeAttribute('src');
    }
    function sizeDraft() {
      input.style.height='auto';
      input.style.height=Math.min(input.scrollHeight,player.classList.contains('keyboard-tight')?44:88)+'px';
    }
    function draftState() {
      send.disabled = posting || !admitted || !active || (!input.value.trim() && !attachment);
      capture.disabled = !live || posting;
      reply.hidden = !replyTo;
    }
    function show(value) {
      open = !!value && admitted && active; panel.hidden = !open;
      player.classList.toggle('chat-open', open); toggle.setAttribute('aria-expanded', String(open));
      clearInterval(timer);
      if (!open) { copyAttempt++; cancelPress(); closeActions(); closeImage(); if(copyDialog.open)closeCopy();$('chat-copy-text').value=''; }
      if (open) { activity(lastActivity); lastJSON = ''; poll(); timer = setInterval(poll, 2000); }
    }
    function reset() {
      generation++; admitted = false; active = false; show(false); toggle.hidden = true;
      cancelPress();closeActions();closeImage();rovingID=undefined;log.tabIndex=0;
      rows.clear(); log.replaceChildren(); blobs.forEach(URL.revokeObjectURL); blobs.clear(); loadingFrames.clear();
      clearAttachment(); input.value = ''; sizeDraft(); replyTo = undefined; lastJSON = ''; draftState();
      readThrough = 0; lastActivity = 0; activity(0);
    }
    async function loadFrame(message, image) {
      if (blobs.has(message.id)) { image.src = blobs.get(message.id); return; }
      if (loadingFrames.has(message.id)) return;
      const epoch = generation; loadingFrames.add(message.id);
      const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 5000);
      try {
        const response = await fetch('chat/frame/' + message.id, {cache: 'no-store', signal: controller.signal,
          headers: {'X-Setbeam-Pass': options.pass() || ''}});
        if (response.status === 403) { reset(); return; }
        if (!response.ok) { image.alt = 'Frame no longer available'; return; }
        const data = await response.blob();
        if (epoch !== generation || !admitted || !rows.get(message.id)?.message.hasFrame) return;
        const url = URL.createObjectURL(data); blobs.set(message.id, url); image.src = url;
      } catch { image.alt = 'Frame could not load. Reopen chat to retry.'; }
      finally { clearTimeout(timeout); loadingFrames.delete(message.id); }
    }
    const REACTIONS = [
      ['heart','❤️','Love'], ['thumbsUp','👍','Like'], ['laugh','😂','Laugh'],
      ['surprised','😮','Surprise'], ['sad','😢','Sad'], ['emphasis','‼️','Emphasis']
    ];
    const menu = $('chat-menu'), imageDialog = $('chat-image-dialog'), copyDialog = $('chat-copy-dialog');
    let menuID, menuReturn, imageID, imageReturn, copyID, rovingID, press, suppressClick, copyAttempt=0, touchOrigin, menuFollowEnd=false;
    function summaries(message) {
      return message.reactions || (message.likes ? [{reaction:'heart', count:message.likes, selected:message.liked}] : []);
    }
    function cancelPress() { if (press) clearTimeout(press.timer); press = undefined; }
    function setRoving(id, focus = false) {
      rovingID = rows.has(id) ? id : undefined;
      log.tabIndex = rovingID ? -1 : 0;
      for (const [key,row] of rows) row.article.tabIndex = key === rovingID ? 0 : -1;
      if (focus) (rows.get(rovingID)?.article || log).focus({preventScroll:true});
    }
    function closeActions(restore = false, resume = true) {
      const target = menuReturn, follow=menuFollowEnd; menuFollowEnd=false; menuID = undefined; menuReturn = undefined; menu.hidden = true;
      for (const row of rows.values()) row.more.setAttribute('aria-expanded','false');
      if(follow && resume && open && active)log.scrollTop=log.scrollHeight;
      if (restore && target?.isConnected) { setRoving(Number(target.dataset.id)); target.focus({preventScroll:true}); }
    }
    function positionMenu() {
      const row = rows.get(menuID); if (!row || menu.hidden) return;
      const anchor = row.bubble.getBoundingClientRect(), view = globalThis.visualViewport;
      const left = view?.offsetLeft || 0, top = view?.offsetTop || 0;
      const width = Math.min(view?.width || innerWidth,innerWidth), height = Math.min(view?.height || innerHeight,innerHeight);
      menu.style.maxWidth = Math.max(0,width - 16) + 'px';
      menu.style.maxHeight = Math.max(0,height - 16) + 'px';
      const box = menu.getBoundingClientRect();
      menu.style.left = Math.max(left + 8,Math.min(anchor.left,left + width - box.width - 8)) + 'px';
      const below = anchor.bottom + 8;
      menu.style.top = Math.max(top + 8,Math.min(below + box.height <= top + height - 8 ? below : anchor.top - box.height - 8,top + height - box.height - 8)) + 'px';
    }
    function syncMenu() {
      const row = rows.get(menuID); if (!row) { closeActions(); return; }
      const focus=document.activeElement;
      const selected = summaries(row.message).find(item=>item.selected)?.reaction;
      for (const button of menu.querySelectorAll('[data-reaction]')) {
        button.setAttribute('aria-checked',String(button.dataset.reaction === selected));
        const choice = REACTIONS.find(item=>item[0] === button.dataset.reaction);
        button.setAttribute('aria-label',(choice[0] === selected ? 'Remove ' : 'React with ') + choice[2]);
      }
      $('chat-menu-copy').hidden = !row.message.text;
      $('chat-menu-image').hidden = !row.message.hasFrame;
      if(menu.contains(focus)&&focus.hidden)menu.querySelector('[role=menuitemradio]').focus({preventScroll:true});
      text($('chat-menu-time'),'Sent ' + new Date(row.message.sentAt*1000).toLocaleTimeString([], {hour:'numeric',minute:'2-digit'}));
      positionMenu();
    }
    function openActions(id) {
      if (!admitted || !active || !rows.has(id)) return;
      cancelPress();
      if (menuID === id && !menu.hidden) { syncMenu(); return; }
      const follow=log.scrollHeight-log.scrollTop-log.clientHeight<64;
      closeActions(false,false);menuFollowEnd=follow; menuID = id; menuReturn = rows.get(id).article; setRoving(id);
      menu.hidden = false; menu.scrollTop=0; rows.get(id).more.setAttribute('aria-expanded','true'); syncMenu();
      menu.querySelector('[role=menuitemradio]').focus({preventScroll:true});
    }
    async function react(id, kind) {
      const row = rows.get(id); if (!row) return;
      const selected = summaries(row.message).some(item=>item.reaction === kind && item.selected);
      const epoch = generation; closeActions(true);
      try {
        await request('chat',{action:'react',id,reaction:selected ? null : kind});
        if (epoch === generation) { text(status,''); await poll(); }
      } catch(error) { if (epoch === generation) text(status,error.message); }
    }
    function closeImage(restore = true) {
      if (imageDialog.open) imageDialog.close();
      $('chat-image-full').removeAttribute('src'); imageID = undefined;
      if (restore && imageReturn?.isConnected) imageReturn.focus({preventScroll:true}); imageReturn = undefined;
    }
    function openImage(id) {
      const row = rows.get(id), url = blobs.get(id);
      if (!row?.message.hasFrame || !url) { text(status,'This image is not available yet. Try again.'); return; }
      closeActions(); setRoving(id); imageID = id; imageReturn = row.article;
      $('chat-image-full').src = url;
      text($('chat-image-title'),'Image from ' + row.message.name);
      $('chat-image-sample').hidden = !row.message.sampleFrame;
      imageDialog.showModal();
    }
    function closeCopy(restore = true) { copyAttempt++; if (copyDialog.open) copyDialog.close(); copyID=undefined; $('chat-copy-text').value=''; if(restore)setRoving(rovingID,true); }
    function selectableCopy(id,value) {
      if(!open || !admitted || !active || rows.get(id)?.message.text!==value)return;
      closeActions();copyID=id; $('chat-copy-text').value = value; copyDialog.showModal();
      $('chat-copy-text').focus({preventScroll:true}); $('chat-copy-text').select();
    }
    function copyMessage() {
      const row = rows.get(menuID); if (!row) return;
      const id=row.message.id, epoch=generation, attempt=++copyAttempt, value=row.message.text, area=document.createElement('textarea');
      const current=()=>attempt===copyAttempt&&epoch===generation&&open&&admitted&&active&&rows.get(id)?.message.text===value;
      area.value = value; area.readOnly = true; area.className = 'chat-copy-helper'; document.body.append(area);
      area.style.fontSize="16px"; area.focus({preventScroll:true}); area.select(); area.setSelectionRange(0,value.length); let copied = false;
      try { copied = area.selectionStart===0 && area.selectionEnd===value.length && document.execCommand('copy'); } catch {}
      area.remove();
      if (copied) { text(status,'Copied'); closeActions(true); return; }
      if (navigator.clipboard?.writeText) {
        closeActions(true);
        navigator.clipboard.writeText(value).then(()=>{if(current()){text(status,'Copied');closeActions(true);}}).catch(()=>{if(current())selectableCopy(id,value);});
      } else selectableCopy(id,value);
    }
    function bindMessage(row) {
      const {article,bubble,more} = row;
      more.addEventListener('click',()=>openActions(row.message.id));
      article.addEventListener('contextmenu',event=>{event.preventDefault();cancelPress();suppressClick={id:row.message.id,until:performance.now()+1200};openActions(row.message.id);});
      article.addEventListener('click',event=>{
        if (suppressClick?.id === row.message.id && performance.now() < suppressClick.until) {
          event.preventDefault();event.stopImmediatePropagation();suppressClick=undefined;
        }
      },true);
      bubble.addEventListener('pointerdown',event=>{
        if (!event.isPrimary || event.button !== 0) return;
        cancelPress();
        const current = {id:event.pointerId, x:event.clientX,y:event.clientY,type:event.pointerType,message:row.message.id};
        current.timer=setTimeout(()=>{
          if (press !== current) return;
          suppressClick={id:current.message,until:performance.now()+1200}; openActions(current.message);
        },500); press=current;
      });
      bubble.addEventListener('click',event=>{
        if (event.target.closest('button')) return;
        if (event.pointerType === 'touch' || row.touchAt && performance.now()-row.touchAt < 600) openActions(row.message.id);
      });
      row.imageButton.addEventListener('click',()=>openImage(row.message.id));
      row.chips.addEventListener('click',()=>openActions(row.message.id));
    }
    document.addEventListener('pointermove',event=>{
      if (press?.id === event.pointerId && Math.hypot(event.clientX-press.x,event.clientY-press.y)>10) cancelPress();
    },{passive:true});
    document.addEventListener('pointerup',event=>{
      if (press?.id === event.pointerId) {
        if (press.type === 'touch' && rows.has(press.message)) rows.get(press.message).touchAt=performance.now();
        cancelPress();
      }
    },{passive:true});
    document.addEventListener('pointercancel',cancelPress,{passive:true});
    document.addEventListener('pointerdown',event=>{
      if (!menu.hidden && !menu.contains(event.target)) closeActions(false,!log.contains(event.target));
      if (!$('chat-information').contains(event.target) && !$('chat-info').contains(event.target)) {
        $('chat-information').hidden=true;$('chat-info').setAttribute('aria-expanded','false');
      }
    });
    log.addEventListener('wheel',()=>{cancelPress();closeActions();},{passive:true});
    log.addEventListener('touchstart',event=>{const touch=event.touches[0];touchOrigin=touch?{x:touch.clientX,y:touch.clientY}:undefined;},{passive:true});
    log.addEventListener('touchmove',event=>{
      const touch=event.touches[0];
      if(touchOrigin&&touch&&Math.hypot(touch.clientX-touchOrigin.x,touch.clientY-touchOrigin.y)>10){cancelPress();closeActions();}
    },{passive:true});
    log.addEventListener('touchend',()=>{touchOrigin=undefined;},{passive:true});
    log.addEventListener('touchcancel',()=>{touchOrigin=undefined;cancelPress();},{passive:true});
    log.addEventListener('scroll',positionMenu,{passive:true});
    globalThis.addEventListener('scroll',positionMenu,{passive:true});
    globalThis.addEventListener('orientationchange',()=>{cancelPress();closeActions(true);});
    menu.addEventListener('keydown',event=>{
      const items=[...menu.querySelectorAll('[role^=menuitem]')].filter(item=>!item.hidden), index=items.indexOf(document.activeElement);
      let next;
      if (event.key==='ArrowDown'||event.key==='ArrowRight') next=(index+1)%items.length;
      if (event.key==='ArrowUp'||event.key==='ArrowLeft') next=(index-1+items.length)%items.length;
      if (event.key==='Home') next=0; if (event.key==='End') next=items.length-1;
      if (next!==undefined) {event.preventDefault();items[next].focus({preventScroll:true});items[next].scrollIntoView({block:'nearest'});}
      if (event.key==='Escape'||event.key==='Tab') {event.preventDefault();event.stopPropagation();closeActions(true);}
    });
    log.addEventListener('keydown',event=>{
      if (event.target.closest('button')) return;
      const ids=[...rows.keys()], index=ids.indexOf(rovingID);
      if (['ArrowUp','ArrowDown','Home','End'].includes(event.key)) {
        event.preventDefault();
        const next=event.key==='Home'?0:event.key==='End'?ids.length-1:Math.max(0,Math.min(ids.length-1,index<0?(event.key==='ArrowDown'?0:ids.length-1):index+(event.key==='ArrowDown'?1:-1)));
        if (ids[next]) {setRoving(ids[next],true);rows.get(ids[next]).article.scrollIntoView({block:'nearest'});}
      } else if (event.key==='Enter'||event.key===' '||event.key==='ContextMenu'||event.key==='F10'&&event.shiftKey) {
        event.preventDefault();if (rovingID||ids.length) openActions(rovingID||ids[ids.length-1]);
      }
    });
    menu.querySelector('.chat-reaction-palette').replaceChildren(...REACTIONS.map(([kind,emoji,label])=>{
      const button=document.createElement('button');button.type='button';button.setAttribute('role','menuitemradio');button.tabIndex=-1;
      button.dataset.reaction=kind;button.textContent=emoji;button.setAttribute('aria-label','React with '+label);button.setAttribute('aria-checked','false');
      button.addEventListener('click',()=>react(menuID,kind));return button;
    }));
    $('chat-menu-reply').addEventListener('click',()=>{
      const row=rows.get(menuID);if(!row)return;
      replyTo=row.message.id;text($('chat-reply-label'),'Replying to '+row.message.name);requestID=undefined;
      closeActions();draftState();input.focus({preventScroll:true});
    });
    $('chat-menu-copy').addEventListener('click',copyMessage);
    $('chat-menu-image').addEventListener('click',()=>openImage(menuID));
    $('chat-image-close').addEventListener('click',closeImage);
    imageDialog.addEventListener('cancel',event=>{event.preventDefault();closeImage();});
    imageDialog.addEventListener('click',event=>{if(event.target===imageDialog)closeImage();});
    $('chat-copy-close').addEventListener('click',closeCopy);
    copyDialog.addEventListener('cancel',event=>{event.preventDefault();closeCopy();});
    $('chat-info').addEventListener('click',()=>{
      const info=$('chat-information');info.hidden=!info.hidden;$('chat-info').setAttribute('aria-expanded',String(!info.hidden));
    });
    function render(messages) {
      if (!Array.isArray(messages)) return;
      const atEnd = log.scrollHeight - log.scrollTop - log.clientHeight < 64;
      const ids = new Set(messages.map(message => message.id));
      if (replyTo && !ids.has(replyTo)) { replyTo = undefined; draftState(); }
      let lostFocus;
      for (const [id,row] of rows) if (!ids.has(id)) {
        const focused=document.activeElement;
        if(row.article.contains(focused)||menuID===id&&menu.contains(focused)||imageID===id&&imageDialog.contains(focused)||copyID===id&&copyDialog.contains(focused))lostFocus=id;
        if(menuID===id)closeActions(false,false);if(imageID===id)closeImage(false);if(copyID===id)closeCopy(false);
        row.article.remove();rows.delete(id);if(blobs.has(id)){URL.revokeObjectURL(blobs.get(id));blobs.delete(id);}
      }
      text($('chat-empty'),messages.length?'':'Send a note or attach a frame. Hold a message to reply or react.');
      let previous;
      for (const message of messages) {
        let row=rows.get(message.id);
        if(!row){
          const article=document.createElement('article');article.className='chat-message';article.dataset.id=message.id;article.tabIndex=-1;
          article.setAttribute('aria-haspopup','menu');article.setAttribute('aria-roledescription','message');
          article.innerHTML='<div class="chat-byline" aria-hidden="true"><svg class="chat-avatar" viewBox="0 0 24 24"><path d="m5 3 14 8-6.2 1.5L9.6 19z"/></svg><strong></strong><span class="chat-role"></span><time></time></div><div class="chat-bubble"><p class="chat-quote"></p><p class="chat-text"></p><button class="chat-image-button" type="button" tabindex="-1" hidden><img class="chat-frame" alt="" draggable="false"><span class="chat-image-caption">Image<span class="chat-sample">Sample media</span></span></button></div><div class="chat-reactions" aria-hidden="true"></div><button class="chat-more" type="button" tabindex="-1" aria-label="Message actions" aria-haspopup="menu" aria-expanded="false">•••</button>';
          row={article,message,bubble:article.querySelector('.chat-bubble'),more:article.querySelector('.chat-more'),imageButton:article.querySelector('.chat-image-button'),chips:article.querySelector('.chat-reactions')};
          rows.set(message.id,row);log.append(article);bindMessage(row);
        }
        row.message=message;
        const own=message.ownMessage===true, start=!previous||previous.authorNumber!==message.authorNumber||previous.name!==message.name||previous.color!==message.color||message.sentAt-previous.sentAt>300;
        row.article.classList.toggle('own',own);row.article.classList.toggle('group-start',start);
        row.article.querySelector('.chat-byline').hidden=!start||own;
        const palette=globalThis.SetbeamPointers?.COLORS||{};
        row.article.querySelector('.chat-avatar').style.color=palette[message.color]?.[0]||'#a9b7cb';
        text(row.article.querySelector('strong'),message.name);row.article.querySelector('strong').title=message.name;
        text(row.article.querySelector('.chat-role'),message.operatorMessage?'✓':'');
        const time=new Date(message.sentAt*1000).toLocaleTimeString([], {hour:'numeric',minute:'2-digit'});
        text(row.article.querySelector('time'),time);
        const quote=row.article.querySelector('.chat-quote'),parent=messages.find(item=>item.id===message.replyTo);
        quote.hidden=!message.replyTo;
        text(quote,parent?parent.name+': '+(parent.text||'Image'):'Original message unavailable');
        text(row.article.querySelector('.chat-text'),message.text||(!message.hasFrame?'Image no longer available':''));
        row.imageButton.hidden=!message.hasFrame;row.imageButton.setAttribute('aria-label','Open image from '+message.name);
        const image=row.article.querySelector('img');
        row.article.querySelector('.chat-sample').hidden=!message.sampleFrame;
        if(message.hasFrame)loadFrame(message,image);
        else if(blobs.has(message.id)){if(imageID===message.id)closeImage();URL.revokeObjectURL(blobs.get(message.id));blobs.delete(message.id);image.removeAttribute('src');}
        const reactions=summaries(message);
        row.chips.hidden=!reactions.length;
        const signature=JSON.stringify(reactions);
        if(row.reactionsJSON!==signature){
          row.reactionsJSON=signature;row.chips.replaceChildren(...reactions.map(item=>{
            const chip=document.createElement('span'),kind=REACTIONS.find(choice=>choice[0]===item.reaction);
            chip.className='chat-reaction'+(item.selected?' selected':'');chip.textContent=(kind?.[1]||'')+' '+item.count;return chip;
          }));
        }
        const label=[message.name+(message.operatorMessage?', operator':''),time,message.replyTo?quote.textContent:'',message.text||(!message.hasFrame?'Image no longer available':''),message.hasFrame?'Image attached':'',message.hasFrame&&message.sampleFrame?'Sample media':'',...reactions.map(item=>(REACTIONS.find(choice=>choice[0]===item.reaction)?.[2]||'Reaction')+', '+item.count+(item.selected?', selected':''))].filter(Boolean).join('. ');
        row.article.setAttribute('aria-label',label);previous=message;
      }
      setRoving(rovingID);
      if(lostFocus!==undefined){const neighbour=messages.find(message=>message.id>lostFocus)||messages.at(-1);setRoving(neighbour?.id,true);}
      if (atEnd && menuID===undefined) log.scrollTop=log.scrollHeight;
      if(menuID!==undefined)syncMenu();
      activity(Math.max(lastActivity,messages.at(-1)?.id||0));
    }
    async function poll() {
      if (polling || !admitted || !active || !open) return;
      polling = true; const epoch = generation;
      try {
        const messages = await request('chat');
        if (epoch !== generation) return;
        const json = JSON.stringify(messages); if (json !== lastJSON) { render(messages); lastJSON = json; }
      } catch (error) { if (epoch === generation) text(status, error.message); }
      finally { polling = false; }
    }
    toggle.addEventListener('click', () => show(!open));
    $('chat-close').addEventListener('click', () => { show(false); toggle.focus(); });
    $('chat-cancel-reply').addEventListener('click', () => { replyTo = undefined; requestID = undefined; draftState(); });
    $('chat-remove-frame').addEventListener('click', () => { clearAttachment(); draftState(); });
    input.addEventListener('input', () => { requestID = undefined; sizeDraft(); draftState(); });
    input.addEventListener('keydown',event=>{if(event.key==='Enter'&&(event.metaKey||event.ctrlKey)){event.preventDefault();form.requestSubmit();}});
    capture.addEventListener('click', () => {
      if (!live || !options.live()) return;
      const video = $('video');
      if (video.readyState < 2 || !video.videoWidth || !video.videoHeight) return;
      try {
        const canvas = document.createElement('canvas'), scale = Math.min(1, 960 / Math.max(video.videoWidth, video.videoHeight));
        canvas.width = Math.max(1, Math.round(video.videoWidth * scale)); canvas.height = Math.max(1, Math.round(video.videoHeight * scale));
        canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
        let data = canvas.toDataURL('image/jpeg', 0.7);
        if (data.length > 170000) data = canvas.toDataURL('image/jpeg', 0.4);
        if (data.length > 170000) throw Error('This frame is too detailed. Try another frame.');
        attachment = {data, revision}; requestID = undefined;
        $('chat-frame-preview').src = data; preview.hidden = false; text(status, 'Frame attached. Send shares it with the session.'); draftState();
      } catch (error) { text(status, error.message || 'This frame could not be captured.'); }
    });
    form.addEventListener('submit', async event => {
      event.preventDefault(); if (posting || !admitted || !active || (!input.value.trim() && !attachment)) return;
      if (attachment && (!live || attachment.revision !== revision)) { clearAttachment(); text(status, 'The feed changed. Capture a new frame.'); draftState(); return; }
      posting = true; draftState(); requestID ||= uuid();
      const epoch = generation, sentText = input.value, sentAttachment = attachment, sentReply = replyTo;
      try {
        await request('chat', {action: 'post', text: sentText, replyTo: sentReply, requestID,
          ...(attachment ? {frame: attachment.data.split(',')[1], revision: attachment.revision} : {})});
        if (epoch !== generation) return;
        if (input.value === sentText) { input.value = ''; sizeDraft(); }
        if (attachment === sentAttachment) clearAttachment();
        if (replyTo === sentReply) replyTo = undefined;
        requestID = undefined; text(status, ''); await poll();
      } catch (error) { if (epoch === generation) text(status, error.message || 'Message not sent. Try again.'); }
      finally { posting = false; draftState(); }
    });
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape' && open && !event.defaultPrevented) {
        if (!menu.hidden) { event.preventDefault();closeActions(true);return; }
        if(imageDialog.open){event.preventDefault();closeImage();return;}
        if(copyDialog.open){event.preventDefault();closeCopy();return;}
        if(!$('chat-information').hidden){event.preventDefault();$('chat-information').hidden=true;$('chat-info').setAttribute('aria-expanded','false');return;} event.preventDefault(); show(false); toggle.focus(); }
    });
    function viewport() {
      const view = globalThis.visualViewport;
      const height = Math.min(view?.height || globalThis.innerHeight, globalThis.innerHeight);
      document.documentElement.style.setProperty('--visual-height', height + 'px');
      document.documentElement.style.setProperty('--visual-top', (view?.offsetTop || 0) + 'px');
      player.classList.toggle('keyboard-tight', height < 300);
      sizeDraft(); if(menuID!==undefined)requestAnimationFrame(positionMenu);
    }
    globalThis.visualViewport?.addEventListener('resize', viewport);
    globalThis.visualViewport?.addEventListener('scroll', viewport);
    globalThis.addEventListener('resize', viewport); viewport();
    return {activity, update(next) {
      if (!next.admitted || !next.active) { if (admitted || active) reset(); return; }
      admitted = next.admitted; active = next.active; live = next.live;
      if (revision !== next.revision || !live) clearAttachment();
      revision = next.revision; toggle.hidden = false; draftState();
      player.classList.toggle('chat-open', open);
    }};
  }
  globalThis.SetbeamChat = {attach};
})();
