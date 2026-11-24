/* Session-only collaboration. Content is plain text, and image requests need the admitted pass. */
(() => {
  function attach(options) {
    const $ = id => document.getElementById(id);
    const player = $('player'), toggle = $('chat-toggle'), panel = $('chat-panel'), log = $('chat-log');
    if (!toggle || !panel || !log) return {update() {}};
    const form = $('chat-form'), input = $('chat-input'), send = $('chat-send'), status = $('chat-status');
    const capture = $('chat-capture'), preview = $('chat-preview'), reply = $('chat-reply');
    const framePreview = $('chat-frame-preview'), removeFrame = $('chat-remove-frame'), cancelReply = $('chat-cancel-reply');
    let admitted = false, active = false, suspended = false, live = false, revision = -1, open = false, posting = false;
    let pictureRevision, captureReady = false, attachment, replyTo, replyName, replyUnavailable = false, pendingSend, blockedPass, currentPass;
    let timer, generation = 0, pollFlight, pollAgain = false, history = [], lastJSON = '', renderedJSON = '';
    let readThrough = 0, lastActivity = 0, pollProblem = '', actionNotice = '';
    // On a phone held upright the conversation fills the space below the picture, so it stays open there.
    const dockQuery = globalThis.matchMedia?.('(max-width:600px) and (orientation:portrait)');
    const docked = () => !!dockQuery?.matches;
    let dockedOpen = false;
    function updateUnread() {
      if (open && !document.hidden) readThrough = Math.max(readThrough, history.at(-1)?.id || 0);
      const unread = history.filter(message => message.id > readThrough && !message.ownMessage).length;
      const badge = $('chat-unread');
      if (badge) { badge.hidden = !unread; text(badge, String(unread)); }
      toggle.setAttribute('aria-label', unread ? 'Open session chat, ' + unread + ' unread messages' : 'Open session chat');
    }
    function activity(id) {
      if (Number.isSafeInteger(id) && id > lastActivity) {
        lastActivity = id;
        if (admitted && !open) poll(true);
      }
    }
    const rows = new Map(), blobs = new Map(), loadingFrames = new Map(), reactionWrites = new Map();
    function uuid() {
      if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
      const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16));
      return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
    }
    const text = (element, value) => { if (element.textContent === value) return; if (element.childNodes.length === 1 && element.firstChild.nodeType === 3) element.firstChild.nodeValue = value; else element.textContent = value; };
    async function request(path, body) {
      const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 5000);
      const epoch = generation;
      try {
        const response = await fetch(path, {method: body ? 'POST' : 'GET', cache: 'no-store', signal: controller.signal,
          headers: {'X-Setbeam-Pass': currentPass || '', ...(body ? {'Content-Type': 'application/json'} : {})},
          ...(body ? {body: JSON.stringify(body)} : {})});
        if (response.status === 403 || response.status === 404) {
          if (epoch === generation) endAccess();
          throw Error('Chat access ended.');
        }
        if (!response.ok) {
          const result = await response.json().catch(() => null);
          throw Object.assign(Error(result?.error || 'Chat could not update. Try again.'), {
            rejected: response.status === 400 && typeof result?.error === 'string', code: result?.code
          });
        }
        return await response.json();
      } finally { clearTimeout(timeout); }
    }
    function clearAttachment() {
      attachment = undefined; preview.hidden = true; framePreview.removeAttribute('src');
    }
    function clearReply() { replyTo = undefined; replyName = undefined; replyUnavailable = false; }
    function sizeDraft() {
      input.style.height='auto';
      input.style.height=Math.min(Math.max(44,input.scrollHeight),player.classList.contains('keyboard-tight')?44:88)+'px';
    }
    function draftState() {
      const stale = attachment?.stale;
      const locked = posting || !!pendingSend;
      send.disabled = posting || !!pendingSend?.checking || !admitted || !active || suspended ||
        (!pendingSend && (replyUnavailable || stale || (!input.value.trim() && !attachment)));
      const sendLabel = pendingSend ? 'Retry same message' : 'Send message';
      send.setAttribute('aria-label', sendLabel); send.title = sendLabel;
      input.readOnly = locked; capture.disabled = locked || !admitted || !active || !frameReady();
      cancelReply.disabled = locked; removeFrame.disabled = locked;
      reply.hidden = !replyTo;
      if (replyTo) text($('chat-reply-label'), replyUnavailable ? 'Original message unavailable' : 'Replying to ' + replyName);
      framePreview.hidden = !!stale;
      if (stale) framePreview.removeAttribute('src');
      text(status, suspended ? 'Reconnecting to chat…'
        : pendingSend ? (posting ? 'Sending…' : 'Send unconfirmed. Checking delivery. You can retry the same message.')
        : replyUnavailable ? 'Cancel the reply or choose another message before sending.'
        : stale ? 'Remove the frame or capture a new one before sending.'
        : actionNotice || pollProblem);
    }
    function schedulePoll() {
      clearInterval(timer);
      if (admitted && active) timer = setInterval(poll, open ? 2000 : 5000);
    }
    function show(value) {
      open = !!value && admitted && active; panel.hidden = !open;
      player.classList.toggle('chat-open', open); toggle.setAttribute('aria-expanded', String(open));
      if (!open) { copyAttempt++; cancelPress(); closeActions(); closeImage(); if(copyDialog.open)closeCopy(false);$('chat-copy-text').value=''; }
      else { updateUnread(); renderHistory(true); poll(true); }
      schedulePoll();
    }
    function endAccess() { blockedPass = currentPass; reset(); }
    function reset() {
      generation++; admitted = false; active = false; suspended = false; live = false; captureReady = false; posting = false;
      pendingSend = undefined; pollFlight = undefined; pollAgain = false;
      show(false); toggle.hidden = true; dockedOpen = false; player.classList.toggle('chat-docked', false);
      rovingID=undefined;log.tabIndex=0;
      rows.clear(); log.replaceChildren(); blobs.forEach(URL.revokeObjectURL); blobs.clear(); loadingFrames.clear(); reactionWrites.clear();
      clearAttachment(); clearReply(); input.value = ''; sizeDraft();
      history = []; lastJSON = ''; renderedJSON = ''; pollProblem = ''; actionNotice = ''; draftState();
      readThrough = 0; lastActivity = 0; updateUnread();
    }
    async function loadFrame(message, image) {
      if (blobs.has(message.id)) { image.src = blobs.get(message.id); return; }
      if (loadingFrames.has(message.id)) return;
      const epoch = generation; loadingFrames.set(message.id, epoch);
      const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 5000);
      try {
        const response = await fetch('chat/frame/' + message.id, {cache: 'no-store', signal: controller.signal,
          headers: {'X-Setbeam-Pass': currentPass || ''}});
        if (response.status === 403) { if (epoch === generation) endAccess(); return; }
        if (!response.ok) { image.alt = response.status === 404 ? 'Frame no longer available' : 'Frame could not load'; return; }
        const data = await response.blob();
        if (epoch !== generation || !admitted || !rows.get(message.id)?.message.hasFrame) return;
        const url = URL.createObjectURL(data); blobs.set(message.id, url); image.src = url;
      } catch { image.alt = 'Frame could not load. Reopen chat to retry.'; }
      finally { clearTimeout(timeout); if (loadingFrames.get(message.id) === epoch) loadingFrames.delete(message.id); }
    }
    const REACTIONS = [
      ['heart','❤️','Love'], ['thumbsUp','👍','Like'], ['laugh','😂','Laugh'],
      ['surprised','😮','Surprise'], ['sad','😢','Sad'], ['emphasis','‼️','Emphasis']
    ];
    const menu = $('chat-menu'), imageDialog = $('chat-image-dialog'), copyDialog = $('chat-copy-dialog');
    let menuID, menuReturn, imageID, imageReturn, copyID, rovingID, press, suppressClick, copyAttempt=0, touchOrigin, menuFollowEnd = false;
    function summaries(message) {
      if (!message.reactions) return message.likes ? [{reaction:'heart', count:message.likes, selected:message.liked}] : [];
      return REACTIONS.flatMap(([kind]) => message.reactions.filter(item => item.reaction === kind).slice(0, 1));
    }
    function cancelPress() { if (press) clearTimeout(press.timer); press = undefined; }
    function setRoving(id, focus = false) {
      rovingID = rows.has(id) ? id : undefined;
      log.tabIndex = rovingID ? -1 : 0;
      for (const [key,row] of rows) row.article.tabIndex = key === rovingID ? 0 : -1;
      if (focus) (rows.get(rovingID)?.article || log).focus({preventScroll:true});
    }
    function closeActions(restore = false, resume = false) {
      const target = menuReturn, follow = menuFollowEnd; menuFollowEnd = false; menuID = undefined; menuReturn = undefined; menu.hidden = true;
      for (const row of rows.values()) row.more.setAttribute('aria-expanded','false');
      if (resume && follow && open) log.scrollTop = log.scrollHeight;
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
      const write = reactionWrites.get(row.message.id);
      const selected = write ? write.reaction : summaries(row.message).find(item=>item.selected)?.reaction;
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
      closeActions(); menuFollowEnd = log.scrollHeight - log.scrollTop - log.clientHeight < 64; menuID = id; menuReturn = rows.get(id).article; setRoving(id);
      menu.hidden = false; menu.scrollTop=0; rows.get(id).more.setAttribute('aria-expanded','true'); syncMenu();
      menu.querySelector('[role=menuitemradio]').focus({preventScroll:true});
    }
    async function react(id, kind) {
      const row = rows.get(id); if (!row || suspended) return;
      closeActions(true);
      const queued = reactionWrites.get(id);
      const selected = queued ? queued.reaction : summaries(row.message).find(item => item.selected)?.reaction;
      const desired = selected === kind ? null : kind;
      if (queued) { queued.reaction = desired; return; }
      const write = {reaction: desired};
      reactionWrites.set(id, write);
      const epoch = generation;
      try {
        let sent;
        do {
          sent = write.reaction;
          try {
            const result = await request('chat', {action:'react', id, reaction:sent});
            if (result?.ok !== true) throw Error('Chat could not update. Try again.');
            if (epoch === generation) actionNotice = '';
          } catch (error) {
            if (epoch === generation) actionNotice = error.message;
          }
          if (epoch !== generation) return;
          await poll(true);
        } while (epoch === generation && !suspended && sent !== write.reaction);
      } finally {
        if (epoch === generation) {
          reactionWrites.delete(id);
          if (menuID === id) syncMenu();
          draftState();
        }
      }
    }
    function closeImage(restore = true) {
      if (imageDialog.open) imageDialog.close();
      $('chat-image-full').removeAttribute('src'); imageID = undefined;
      if (restore && imageReturn?.isConnected) imageReturn.focus({preventScroll:true}); imageReturn = undefined;
    }
    function openImage(id) {
      const row = rows.get(id), url = blobs.get(id);
      if (!row?.message.hasFrame || !url) { actionNotice = 'This image is not available yet. Try again.'; draftState(); return; }
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
      if (copied) { actionNotice = 'Copied'; draftState(); closeActions(true); return; }
      if (navigator.clipboard?.writeText) {
        closeActions(true);
        navigator.clipboard.writeText(value).then(()=>{if(current()){actionNotice = 'Copied'; draftState();closeActions(true);}}).catch(()=>{if(current())selectableCopy(id,value);});
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
      if (!menu.hidden && !menu.contains(event.target)) closeActions();
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
      if (event.key==='Escape'||event.key==='Tab') {event.preventDefault();event.stopPropagation();closeActions(true, true);}
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
      const row=rows.get(menuID);if(!row || posting || pendingSend)return;
      replyTo=row.message.id; replyName=row.message.name; replyUnavailable=false; actionNotice='';
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
      const visibleTop = log.getBoundingClientRect().top;
      const anchor = [...rows.values()].find(row => ids.has(row.message.id) && row.article.getBoundingClientRect().bottom > visibleTop);
      const anchorTop = anchor?.article.getBoundingClientRect().top;
      let lostFocus;
      for (const [id,row] of rows) if (!ids.has(id)) {
        const focused=document.activeElement;
        if(row.article.contains(focused)||menuID===id&&menu.contains(focused)||imageID===id&&imageDialog.contains(focused)||copyID===id&&copyDialog.contains(focused))lostFocus=id;
        if(menuID===id)closeActions();if(imageID===id)closeImage(false);if(copyID===id)closeCopy(false);
        row.article.remove();rows.delete(id);if(blobs.has(id)){URL.revokeObjectURL(blobs.get(id));blobs.delete(id);}
      }
      text($('chat-empty'),messages.length?'':'Send a note or attach a frame. Hold a message to reply or react.');
      let previous;
      for (const message of messages) {
        let row=rows.get(message.id);
        if(!row){
          const article=document.createElement('article');article.className='chat-message';article.dataset.id=message.id;article.tabIndex=-1;
          article.setAttribute('aria-haspopup','menu');article.setAttribute('aria-roledescription','message');
          article.innerHTML='<div class="chat-byline" aria-hidden="true"><span class="chat-avatar"></span><strong></strong><span class="chat-role"></span><time></time></div><div class="chat-bubble"><p class="chat-quote"></p><p class="chat-text"></p><button class="chat-image-button" type="button" tabindex="-1" hidden><img class="chat-frame" alt="" draggable="false"><span class="chat-image-caption">Image<span class="chat-sample">Sample media</span></span></button></div><div class="chat-reactions" aria-hidden="true"></div><button class="chat-more" type="button" tabindex="-1" aria-label="Message actions" aria-haspopup="menu" aria-expanded="false">•••</button>';
          row={article,message,bubble:article.querySelector('.chat-bubble'),more:article.querySelector('.chat-more'),imageButton:article.querySelector('.chat-image-button'),chips:article.querySelector('.chat-reactions')};
          rows.set(message.id,row);log.append(article);bindMessage(row);
        }
        row.message=message;
        const own=message.ownMessage===true, start=!previous||previous.authorNumber!==message.authorNumber||previous.name!==message.name||previous.color!==message.color||message.sentAt-previous.sentAt>300;
        row.article.classList.toggle('own',own);row.article.classList.toggle('group-start',start);
        row.article.querySelector('.chat-byline').hidden=!start||own;
        const palette=globalThis.SetbeamPointers?.COLORS||{};
        const avatar=row.article.querySelector('.chat-avatar'),colors=palette[message.color]||['#a9b7cb','#111'];
        avatar.style.setProperty('--c',colors[0]);avatar.style.setProperty('--t',colors[1]);text(avatar,([...(message.name||'').trim()][0]||'').toUpperCase());
        text(row.article.querySelector('strong'),message.name);row.article.querySelector('strong').title=message.name;
        text(row.article.querySelector('.chat-role'),message.operatorMessage?'✓':'');
        const time=new Date(message.sentAt*1000).toLocaleTimeString([], {hour:'numeric',minute:'2-digit'});
        text(row.article.querySelector('time'),time);
        const quote=row.article.querySelector('.chat-quote'),parent=messages.find(item=>item.id===message.replyTo);
        quote.hidden=!message.replyTo;
        text(quote,parent?parent.name+': '+(parent.text||'Image'):'Original message unavailable');
        const expiredFrame = !message.hasFrame && (message.hadFrame ?? (message.sampleFrame || !message.text));
        const frameLabel = (message.sampleFrame ? 'Sample image' : 'Image') + ' no longer available';
        text(row.article.querySelector('.chat-text'), [message.text, expiredFrame ? frameLabel : ''].filter(Boolean).join('\n'));
        if (!message.hasFrame && row.imageButton.contains(document.activeElement)) lostFocus = message.id;
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
        const label=[message.name+(message.operatorMessage?', operator':''),time,message.replyTo?quote.textContent:'',message.text,expiredFrame?frameLabel:'',message.hasFrame?'Image attached':'',message.hasFrame&&message.sampleFrame?'Sample media':'',...reactions.map(item=>(REACTIONS.find(choice=>choice[0]===item.reaction)?.[2]||'Reaction')+', '+item.count+(item.selected?', selected':''))].filter(Boolean).join('. ');
        row.article.setAttribute('aria-label',label);previous=message;
      }
      setRoving(rovingID);
      if(lostFocus!==undefined){const neighbour=messages.find(message=>message.id>=lostFocus)||messages.at(-1);setRoving(neighbour?.id,true);}
      if (atEnd && menuID === undefined && !log.contains(document.activeElement)) log.scrollTop=log.scrollHeight;
      else if (anchor) log.scrollTop += anchor.article.getBoundingClientRect().top - anchorTop;
      if(menuID!==undefined)syncMenu();
    }
    function renderHistory(force = false) {
      if (!open || (!force && renderedJSON === lastJSON)) return;
      render(history); renderedJSON = lastJSON;
    }
    async function poll(force = false) {
      if (!admitted || !active || suspended) return;
      if (pollFlight) { pollAgain ||= force; return pollFlight; }
      const epoch = generation;
      pollFlight = (async () => {
        try {
          const messages = await request('chat');
          if (epoch !== generation) return;
          if (!Array.isArray(messages)) throw Error('Chat could not update. Try again.');
          history = messages;
          lastJSON = JSON.stringify(messages);
          if (replyTo && !messages.some(message => message.id === replyTo)) replyUnavailable = true;
          pollProblem = ''; updateUnread();
          if (open && renderedJSON === lastJSON) {
            for (const row of rows.values()) {
              if (row.message.hasFrame && !blobs.has(row.message.id)) loadFrame(row.message, row.article.querySelector('img'));
            }
          } else renderHistory();
        } catch {
          if (epoch === generation) pollProblem = 'Chat could not update. Reconnecting…';
        } finally {
          if (epoch === generation) {
            pollFlight = undefined;
            const again = pollAgain; pollAgain = false;
            if (again) await poll();
            if (epoch === generation && pendingSend && !posting) await reconcileSend();
            if (epoch === generation) draftState();
          }
        }
      })();
      return pollFlight;
    }
    toggle.addEventListener('click', () => show(!open));
    $('chat-close').addEventListener('click', () => { show(false); toggle.focus(); });
    cancelReply.addEventListener('click', () => {
      if (posting || pendingSend) return;
      clearReply(); actionNotice = ''; draftState(); input.focus({preventScroll:true});
    });
    removeFrame.addEventListener('click', () => {
      if (posting || pendingSend) return;
      clearAttachment(); actionNotice = ''; draftState(); input.focus({preventScroll:true});
    });
    input.addEventListener('input', () => { actionNotice = ''; sizeDraft(); draftState(); });
    input.addEventListener('keydown',event=>{if(event.key==='Enter'&&(event.metaKey||event.ctrlKey)){event.preventDefault();form.requestSubmit();}});
    const displayedRevision = () => options.displayedRevision ? options.displayedRevision() : pictureRevision;
    const frameReady = () => !suspended && live && options.live() && Number.isSafeInteger(revision) && revision >= 0 &&
      displayedRevision() === revision;
    capture.addEventListener('click', () => {
      if (capture.disabled || !frameReady()) return;
      const video = $('video');
      if (video.readyState < 2 || !video.videoWidth || !video.videoHeight) return;
      try {
        const canvas = document.createElement('canvas'), scale = Math.min(1, 960 / Math.max(video.videoWidth, video.videoHeight));
        canvas.width = Math.max(1, Math.round(video.videoWidth * scale)); canvas.height = Math.max(1, Math.round(video.videoHeight * scale));
        canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
        let data = canvas.toDataURL('image/jpeg', 0.7);
        if (data.length > 170000) data = canvas.toDataURL('image/jpeg', 0.4);
        if (data.length > 170000) throw Error('This frame is too detailed. Try another frame.');
        attachment = {data, revision};
        framePreview.src = data; preview.hidden = false;
        actionNotice = 'Frame attached. Send shares it with the session.'; draftState();
      } catch (error) { actionNotice = error.message || 'This frame could not be captured.'; draftState(); }
    });
    function completeSend() {
      pendingSend = undefined; actionNotice = ''; input.value = ''; sizeDraft(); clearAttachment(); clearReply();
    }
    async function reconcileSend() {
      const draft = pendingSend, epoch = generation;
      if (!draft || posting || draft.checking || suspended) return false;
      draft.checking = true; draftState();
      try {
        const result = await request('chat', {action:'receipt', requestID:draft.body.requestID});
        if (epoch !== generation || pendingSend !== draft || !Number.isSafeInteger(result?.messageID)) return false;
        completeSend(); poll(true); return true;
      } catch { return false; }
      finally { draft.checking = false; if (epoch === generation) draftState(); }
    }
    form.addEventListener('submit', async event => {
      event.preventDefault();
      if (send.disabled || posting || pendingSend?.checking) return;
      // Messages carry the sender's name, so an unnamed viewer chooses one first. The draft is kept.
      if (!pendingSend && options.needsName?.()) { options.askName?.(); return; }
      if (attachment && !pendingSend && !frameReady()) { attachment.stale = true; draftState(); return; }
      pendingSend ??= {body: {action:'post', text:input.value, replyTo, requestID:uuid(),
        ...(attachment ? {frame:attachment.data.split(',')[1], revision:attachment.revision} : {})}};
      posting = true; draftState();
      const epoch = generation;
      try {
        const result = await request('chat', pendingSend.body);
        if (epoch !== generation) return;
        if (result?.ok !== true) throw Error('Send unconfirmed.');
        completeSend();
      } catch (error) {
        if (epoch !== generation) return;
        if (error.rejected) {
          pendingSend = undefined;
          if (error.code === 'replyUnavailable') replyUnavailable = true;
          if (error.code === 'frameStale' && attachment) attachment.stale = true;
          actionNotice = error.message;
        }
      } finally {
        if (epoch === generation) { posting = false; draftState(); poll(true); }
      }
    });
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape' && open && !event.defaultPrevented) {
        if (!menu.hidden) { event.preventDefault();closeActions(true, true);return; }
        if(imageDialog.open){event.preventDefault();closeImage();return;}
        if(copyDialog.open){event.preventDefault();closeCopy();return;}
        if(!$('chat-information').hidden){event.preventDefault();$('chat-information').hidden=true;$('chat-info').setAttribute('aria-expanded','false');return;}
        if (docked()) return;
        event.preventDefault(); show(false); toggle.focus(); }
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
    // Turning the phone sideways returns the picture's full height; chat opened by docking closes there.
    function dock() {
      const on = docked() && admitted && active;
      player.classList.toggle('chat-docked', on); toggle.hidden = !admitted || !active || on;
      if (on && !open) { show(true); dockedOpen = true; }
      else if (!on && dockedOpen) { dockedOpen = false; if (open) show(false); }
    }
    dockQuery?.addEventListener?.('change', dock);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) { updateUnread(); poll(true); } });
    return {activity, update(next) {
      const pass = options.pass();
      if (currentPass !== pass) { reset(); currentPass = pass; blockedPass = undefined; }
      if (!next.admitted || !next.active) {
        if (admitted || active) reset();
        blockedPass = undefined;
        return;
      }
      if (!pass || blockedPass === pass) return;
      const first = !admitted, suspensionChanged = suspended !== (next.suspended === true);
      admitted = next.admitted; active = next.active; live = next.live; revision = next.revision;
      suspended = next.suspended === true;
      pictureRevision = Object.hasOwn(next, 'displayedRevision') ? next.displayedRevision : (live ? revision : undefined);
      const ready = frameReady(), stale = attachment && !attachment.stale && (attachment.revision !== revision || !ready);
      if (stale) attachment.stale = true;
      if (first || suspensionChanged || captureReady !== ready || stale) draftState();
      captureReady = ready;
      if (first) { dock(); poll(); schedulePoll(); }
      else if (suspensionChanged && !suspended) poll(true);
    }};
  }
  globalThis.SetbeamChat = {attach};
})();
