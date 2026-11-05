(() => {
  const config = window.AFTERHOURS_CONFIG || {};
  const configured = config.supabaseUrl && !config.supabaseUrl.includes("YOUR_PROJECT") && config.supabaseAnonKey && !config.supabaseAnonKey.includes("YOUR_SUPABASE");
  const db = configured && window.supabase ? window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } }) : null;
  const $ = (id) => document.getElementById(id);
  const ui = { roomList:$('roomList'), currentRoomName:$('currentRoomName'), welcome:$('welcomeState'), chat:$('chatView'), stream:$('messageStream'), people:$('peopleList'), peopleCount:$('peopleCount'), onlineLabel:$('onlineLabel'), typing:$('typingLine'), messageInput:$('messageInput'), authGate:$('authGate'), createModal:$('createModal'), toast:$('toast') };
  let user = null, currentRoom = null, roomChannel = null, rooms = [], typingTimer = null, toastTimer = null, sentTyping = 0, currentDay = '';
  const initials = (name='?') => name.trim().split(/\s+/).slice(0,2).map(x=>x[0]||'').join('').toUpperCase() || '?';
  const displayName = (u) => u?.user_metadata?.username || u?.user_metadata?.full_name || u?.user_metadata?.name || u?.email?.split('@')[0] || 'Someone';
  const notify = (message) => { ui.toast.textContent=message;ui.toast.classList.add('show');clearTimeout(toastTimer);toastTimer=setTimeout(()=>ui.toast.classList.remove('show'),2600); };
  const escapeRoomName = (name) => name.trim().toLowerCase().replace(/[^a-z0-9\s_-]/g,'').replace(/[\s_]+/g,'-').replace(/-+/g,'-').slice(0,32);
  let authView='login';
  function showAuth(view='login'){
    authView=view;document.body.classList.remove('authenticated');ui.authGate.classList.remove('hidden');
    document.querySelectorAll('[data-auth-view]').forEach(el=>el.classList.toggle('hidden',el.dataset.authView!==view));
    if(view==='forgot'&&$('loginEmail').value)$('forgotEmail').value=$('loginEmail').value;
    if(view==='login')updateLoginLimit();
  }
  function showDialog(dialog){if(!dialog.open)dialog.showModal()}
  function openCreate(){if(!user){showAuth('login');notify('Sign in to create your own room.');return}showDialog(ui.createModal);setTimeout(()=>$('roomNameInput').focus(),50)}

  const attemptKey=(email)=>`afterhours.login-attempts.v1:${email.trim().toLowerCase()}`;
  function attemptsFor(email){try{return Math.max(0,Number(localStorage.getItem(attemptKey(email)))||0)}catch{return 0}}
  function updateLoginLimit(){const email=$('loginEmail').value, count=attemptsFor(email), locked=count>=5;$('attemptHint').textContent=locked?'Too many attempts. Use “Forgot password?” to reset your password.':`${5-count} login attempt${5-count===1?'':'s'} remaining.`;$('loginSubmit').disabled=locked}
  function setFeedback(id,message,success=false){const node=$(id);node.textContent=message;node.classList.toggle('success',success)}
  function setBusy(id,busy,label){const button=$(id);button.disabled=busy||button.disabled;button.dataset.originalLabel ||= button.textContent;button.firstChild.textContent=busy?label:button.dataset.originalLabel}
  function clearAttemptHistory(){try{for(let i=localStorage.length-1;i>=0;i--){const key=localStorage.key(i);if(key?.startsWith('afterhours.login-attempts.v1:'))localStorage.removeItem(key)}}catch{}}

  async function submitLogin(event){
    event.preventDefault();const email=$('loginEmail').value.trim(),password=$('loginPassword').value;
    if(!db){setFeedback('loginFeedback','Connect Supabase in config.js before signing in.');return}
    if(attemptsFor(email)>=5){updateLoginLimit();setFeedback('loginFeedback','This email has reached the five-attempt limit on this browser. Reset the password to continue.');return}
    const button=$('loginSubmit');button.disabled=true;button.dataset.idleText='Sign in';button.firstChild.textContent='Signing in…';setFeedback('loginFeedback','');
    const {error}=await db.auth.signInWithPassword({email,password});
    if(error){
      const countsAsFailure=error.code==='invalid_credentials'||((error.status===400||error.status===401)&&error.code!=='email_not_confirmed')||/invalid login credentials/i.test(error.message||'');
      if(countsAsFailure){const count=Math.min(5,attemptsFor(email)+1);try{localStorage.setItem(attemptKey(email),String(count))}catch{};updateLoginLimit();setFeedback('loginFeedback',count>=5?'That was attempt 5 of 5. Reset your password to sign in again.':`Email or password is incorrect. ${5-count} attempt${5-count===1?'':'s'} remaining.`)}
      else setFeedback('loginFeedback',error.message||'Unable to sign in right now. Please try again.');
      button.firstChild.textContent='Sign in ';button.disabled=attemptsFor(email)>=5;return;
    }
    try{localStorage.removeItem(attemptKey(email))}catch{};button.firstChild.textContent='Sign in ';button.disabled=false;
  }
  async function submitSignup(event){
    event.preventDefault();if(!db){setFeedback('signupFeedback','Connect Supabase in config.js before creating an account.');return}
    const email=$('signupEmail').value.trim(),mobile=$('signupMobile').value.trim(),username=$('signupUsername').value.trim(),password=$('signupPassword').value,confirm=$('signupConfirm').value;
    if(password!==confirm){setFeedback('signupFeedback','Those passwords do not match.');$('signupConfirm').focus();return}
    const digits=mobile.replace(/\D/g,'');if(digits.length<7||digits.length>15){setFeedback('signupFeedback','Enter a mobile number with 7–15 digits.');$('signupMobile').focus();return}
    if(!/^[A-Za-z0-9_]{3,24}$/.test(username)){setFeedback('signupFeedback','Use 3–24 letters, numbers, or underscores for your username.');$('signupUsername').focus();return}
    const button=$('signupSubmit');button.disabled=true;button.firstChild.textContent='Creating account…';setFeedback('signupFeedback','');
    const {data,error}=await db.auth.signUp({email,password,options:{data:{username,full_name:username,phone:mobile},emailRedirectTo:location.origin+location.pathname+location.search}});
    button.disabled=false;button.firstChild.textContent='Create account';
    if(error){setFeedback('signupFeedback',error.message);return}
    if(data.session){setFeedback('signupFeedback','Your account is ready.',true)}else{setFeedback('signupFeedback','Check your email to confirm your account, then come back here to sign in.',true)}
  }
  async function submitForgot(event){
    event.preventDefault();const email=$('forgotEmail').value.trim();if(!db){setFeedback('forgotFeedback','Connect Supabase in config.js before requesting a reset.');return}
    const button=$('forgotSubmit');button.disabled=true;button.firstChild.textContent='Sending…';setFeedback('forgotFeedback','');
    const redirectTo=new URL('reset-password.html',location.href).href;
    const {error}=await db.auth.resetPasswordForEmail(email,{redirectTo});button.disabled=false;button.firstChild.textContent='Send reset link';
    if(error){setFeedback('forgotFeedback',error.message);return}
    setFeedback('forgotFeedback','If an account exists for that email, reset instructions are on the way.',true);
  }

  function renderProfile(){
    $('profileName').textContent=user?displayName(user):'Guest';$('profileStatus').textContent=user?'Here for a good chat':'Not signed in';
    const avatar=$('profileAvatar');avatar.textContent=initials(user?displayName(user):'?');avatar.style.background=user?'#d2e8a7':'#26312a';
  }
  function renderRooms(){
    const query=$('roomSearch').value.trim().toLowerCase();
    ui.roomList.replaceChildren();
    const filtered=rooms.filter(room=>room.name.toLowerCase().includes(query));
    if(!filtered.length){const empty=document.createElement('div');empty.className='room-placeholder';empty.textContent=user?(query?'No matching rooms.':'No rooms yet. Make one for your people.'):'Sign in to find rooms.';ui.roomList.append(empty);renderPublicRooms();return}
    filtered.forEach(room=>{const b=document.createElement('button');b.className='room-item'+(currentRoom?.id===room.id?' active':'');b.innerHTML=`<span class="room-hash">${room.is_private?'⌑':'#'}</span>`;const n=document.createElement('span');n.textContent=room.name;b.append(n);b.addEventListener('click',()=>joinRoom(room));ui.roomList.append(b)});
    renderPublicRooms();
  }
  function renderPublicRooms(){
    const grid=$('publicRoomGrid');if(!grid)return;const query=$('publicRoomSearch').value.trim().toLowerCase();const publicRooms=rooms.filter(r=>!r.is_private);const matches=publicRooms.filter(r=>r.name.toLowerCase().includes(query));
    $('publicRoomCount').textContent=String(publicRooms.length);grid.replaceChildren();
    if(!user){const empty=document.createElement('div');empty.className='directory-empty';empty.textContent='Sign in to explore public rooms.';grid.append(empty);return}
    if(!matches.length){const empty=document.createElement('div');empty.className='directory-empty';empty.textContent=publicRooms.length?'No public rooms match that search yet.':'No public rooms yet. Create one and make it public.';grid.append(empty);return}
    matches.forEach(room=>{const card=document.createElement('article');card.className='public-room-card';const badge=document.createElement('span');badge.className='room-card-badge';badge.textContent='PUBLIC';const title=document.createElement('h3');title.textContent=room.name;const desc=document.createElement('p');desc.textContent=room.description||'A place to talk.';const button=document.createElement('button');button.className='button button-primary';button.type='button';button.textContent='Join room ↗';button.addEventListener('click',()=>joinRoom(room));card.append(badge,title,desc,button);grid.append(card)});
  }
  function setRoomHeader(room){currentRoom=room;ui.currentRoomName.textContent=room.name;ui.welcome.classList.add('hidden');ui.chat.classList.remove('hidden');$('roomHeading').textContent=room.name;$('roomDescription').textContent=room.description||'A place to talk.';$('roomSymbol').textContent='#';const privacy=$('roomPrivacyPill');privacy.textContent=room.is_private?'PRIVATE':'PUBLIC';privacy.classList.toggle('private',!!room.is_private);history.replaceState(null,'',`${location.pathname}?room=${encodeURIComponent(room.id)}`);renderRooms()}
  function dateLabel(date){return new Intl.DateTimeFormat(undefined,{weekday:'long',month:'long',day:'numeric'}).format(date)}
  function timeLabel(date){return new Intl.DateTimeFormat(undefined,{hour:'numeric',minute:'2-digit'}).format(date)}
  function appendDivider(text){const d=document.createElement('div');d.className='date-divider';d.textContent=text;ui.stream.append(d)}
  function appendMessage(message){
    if(ui.stream.querySelector(`[data-message-id="${CSS.escape(message.id)}"]`))return;
    const date=new Date(message.created_at),day=dateLabel(date);if(currentDay!==day){appendDivider(day);currentDay=day}
    const row=document.createElement('article');row.className='message'+(message.user_id===user?.id?' own':'');row.dataset.messageId=message.id;
    const avatar=document.createElement('span');avatar.className='avatar message-avatar';avatar.textContent=initials(message.author_name||'Someone');
    const body=document.createElement('div');body.className='message-body';const meta=document.createElement('div');meta.className='message-meta';const name=document.createElement('strong');name.textContent=message.author_name||'Someone';const time=document.createElement('time');time.dateTime=date.toISOString();time.textContent=timeLabel(date);meta.append(name,time);
    const text=document.createElement('div');text.className='message-text';text.textContent=message.content;body.append(meta,text);
    if(message.user_id===user?.id){const actions=document.createElement('span');actions.className='message-actions';const edit=document.createElement('button');edit.type='button';edit.textContent='edit';edit.addEventListener('click',()=>editMessage(message));const del=document.createElement('button');del.type='button';del.textContent='delete';del.addEventListener('click',()=>deleteMessage(message.id));actions.append(edit,del);meta.append(actions)}
    row.append(avatar,body);ui.stream.append(row);ui.stream.scrollTop=ui.stream.scrollHeight;
  }
  async function editMessage(message){const next=prompt('Edit your message',message.content);if(next===null||!next.trim()||next.trim()===message.content)return;const {error}=await db.from('messages').update({content:next.trim()}).eq('id',message.id).eq('user_id',user.id);if(error)notify(error.message);else{const text=ui.stream.querySelector(`[data-message-id="${CSS.escape(message.id)}"] .message-text`);if(text)text.textContent=next.trim();notify('Message updated.')}}
  async function deleteMessage(id){if(!confirm('Delete this message?'))return;const {error}=await db.from('messages').delete().eq('id',id).eq('user_id',user.id);if(error)notify(error.message);else{ui.stream.querySelector(`[data-message-id="${CSS.escape(id)}"]`)?.remove();notify('Message deleted.')}}
  function renderPeople(state){
    const peers=Object.values(state||{}).flat().filter(p=>p.user_id!==user?.id);ui.people.replaceChildren();ui.peopleCount.textContent=String(peers.length+(user?1:0));
    const all=user?[{user_id:user.id,name:displayName(user)},...peers]:peers;
    if(!all.length){const empty=document.createElement('div');empty.className='people-empty';empty.innerHTML='<span class="empty-orbit">◎</span><span>It\'s a little quiet<br />in here.</span>';ui.people.append(empty);ui.onlineLabel.textContent='Waiting for your people';return}
    all.forEach((person,index)=>{const row=document.createElement('div');row.className='person-row';const a=document.createElement('span');a.className='avatar';a.textContent=initials(person.name);const n=document.createElement('span');n.className='person-name';n.textContent=(person.name||'Someone')+(person.user_id===user?.id?' (you)':'');const dot=document.createElement('i');dot.className='person-presence'+(index===0&&user?'':'');row.append(a,n,dot);ui.people.append(row)});
    ui.onlineLabel.textContent=all.length===1?'Just you, for now':`${all.length} people here now`;
  }
  function renderTyping(payloads){const active=Object.values(payloads||{}).flat().filter(p=>p.user_id!==user?.id&&p.typing);ui.typing.textContent=active.length?`${active.map(p=>p.name).slice(0,2).join(' and ')} ${active.length===1?'is':'are'} typing…`:''}
  async function leaveRoom(){if(roomChannel){await db.removeChannel(roomChannel);roomChannel=null}currentRoom=null}
  async function joinRoom(room){
    if(!user){showAuth('login');notify('Sign in to join the conversation.');return}
    if(currentRoom?.id===room.id)return;await leaveRoom();setRoomHeader(room);ui.stream.replaceChildren();currentDay='';ui.typing.textContent='';
    if(!room.is_private){const {error:joinError}=await db.from('room_members').upsert({room_id:room.id,user_id:user.id},{onConflict:'room_id,user_id',ignoreDuplicates:true});if(joinError){notify(joinError.message);return}}
    const {data,error}=await db.from('messages').select('*').eq('room_id',room.id).order('created_at',{ascending:true}).limit(100);if(error)notify(error.message);else data.forEach(appendMessage);
    roomChannel=db.channel(`room-${room.id}`,{config:{presence:{key:user.id}}});
    roomChannel.on('postgres_changes',{event:'INSERT',schema:'public',table:'messages',filter:`room_id=eq.${room.id}`},payload=>appendMessage(payload.new));
    roomChannel.on('postgres_changes',{event:'UPDATE',schema:'public',table:'messages',filter:`room_id=eq.${room.id}`},payload=>{const node=ui.stream.querySelector(`[data-message-id="${CSS.escape(payload.new.id)}"] .message-text`);if(node)node.textContent=payload.new.content});
    roomChannel.on('postgres_changes',{event:'DELETE',schema:'public',table:'messages',filter:`room_id=eq.${room.id}`},payload=>ui.stream.querySelector(`[data-message-id="${CSS.escape(payload.old.id)}"]`)?.remove());
    roomChannel.on('broadcast',{event:'typing'},({payload})=>{clearTimeout(typingTimer);if(payload.typing){renderTyping({[payload.user_id]:[payload]});typingTimer=setTimeout(()=>ui.typing.textContent='',2200)}else ui.typing.textContent=''});
    roomChannel.on('presence',{event:'sync'},()=>renderPeople(roomChannel.presenceState()));
    roomChannel.subscribe(async status=>{if(status==='SUBSCRIBED'){await roomChannel.track({user_id:user.id,name:displayName(user),online_at:new Date().toISOString()});renderPeople(roomChannel.presenceState())}else if(status==='CHANNEL_ERROR')notify('Live connection interrupted. Reconnecting…')});
    $('messageInput').focus();
  }
  async function loadRooms(){if(!db||!user){rooms=[];renderRooms();return}const params=new URLSearchParams(location.search);const invite=params.get('invite');if(invite){const {data,error}=await db.rpc('join_room_with_invite',{p_invite_code:invite});if(error||!data?.length){notify('That invite link is invalid or expired.');history.replaceState(null,'',location.pathname);params.delete('invite')}else{params.delete('invite');params.set('room',data[0].id);history.replaceState(null,'',`${location.pathname}?${params.toString()}`)}}const {data,error}=await db.from('rooms').select('id,name,description,created_at,is_private,invite_code').order('created_at',{ascending:true});if(error){notify(`Could not load rooms: ${error.message}`);return}rooms=data||[];renderRooms();const requested=new URLSearchParams(location.search).get('room');const room=rooms.find(r=>r.id===requested);if(room)await joinRoom(room);else{await leaveRoom();ui.currentRoomName.textContent='welcome';ui.chat.classList.add('hidden');ui.welcome.classList.remove('hidden')}}
  async function handleSession(session){user=session?.user||null;renderProfile();if(!user){document.body.classList.remove('authenticated');ui.authGate.classList.remove('hidden');await leaveRoom();rooms=[];renderRooms();ui.welcome.classList.remove('hidden');ui.chat.classList.add('hidden');return}document.body.classList.add('authenticated');ui.authGate.classList.add('hidden');await loadRooms()}

  $('newRoomButton').addEventListener('click',openCreate);$('welcomeCreateButton').addEventListener('click',openCreate);$('profileButton').addEventListener('click',()=>user?db.auth.signOut():showAuth('login'));
  $('homeButton').addEventListener('click',async()=>{await leaveRoom();history.replaceState(null,'',location.pathname);ui.currentRoomName.textContent='welcome';ui.chat.classList.add('hidden');ui.welcome.classList.remove('hidden');renderRooms()});
  document.querySelectorAll('[data-show-view]').forEach(button=>button.addEventListener('click',()=>showAuth(button.dataset.showView)));
  $('loginForm').addEventListener('submit',submitLogin);$('signupForm').addEventListener('submit',submitSignup);$('forgotForm').addEventListener('submit',submitForgot);$('loginEmail').addEventListener('input',updateLoginLimit);
  document.querySelectorAll('[data-close]').forEach(b=>b.addEventListener('click',()=>$(b.dataset.close).close()));
  $('createRoomForm').addEventListener('submit',async e=>{e.preventDefault();if(!db||!user)return;const name=escapeRoomName($('roomNameInput').value);if(!name){notify('Choose a room name with letters or numbers.');return}const description=$('roomDescriptionInput').value.trim()||null;const visibility=document.querySelector('input[name="roomVisibility"]:checked')?.value||'public';const {data,error}=await db.from('rooms').insert({name,description,created_by:user.id,is_private:visibility==='private'}).select().single();if(error){notify(error.message.includes('duplicate')?'That room name is already taken.':error.message);return}rooms.push(data);ui.createModal.close();e.target.reset();renderRooms();await joinRoom(data);notify(data.is_private?'Private room ready. Share its invite link.':'Public room ready to discover.')});
  $('messageForm').addEventListener('submit',async e=>{e.preventDefault();const content=ui.messageInput.value.trim();if(!content||!user||!currentRoom)return;ui.messageInput.value='';const {error}=await db.from('messages').insert({room_id:currentRoom.id,user_id:user.id,author_name:displayName(user),content});if(error){ui.messageInput.value=content;notify(error.message)}});
  ui.messageInput.addEventListener('input',()=>{if(!roomChannel||!user)return;const now=Date.now();if(now-sentTyping>900){sentTyping=now;roomChannel.send({type:'broadcast',event:'typing',payload:{user_id:user.id,name:displayName(user),typing:true}})}});
  $('emojiButton').addEventListener('click',()=>{ui.messageInput.value+='👋';ui.messageInput.focus()});$('inviteButton').addEventListener('click',async()=>{if(!currentRoom){notify('Open a room first to invite your people.');return}const url=currentRoom.is_private?`${location.origin}${location.pathname}?invite=${encodeURIComponent(currentRoom.invite_code)}`:`${location.origin}${location.pathname}?room=${encodeURIComponent(currentRoom.id)}`;try{await navigator.clipboard.writeText(url);notify('Room link copied.')}catch{prompt('Copy this room link',url)}});
  $('roomSearch').addEventListener('input',()=>{const box=$('publicRoomSearch');box.value=$('roomSearch').value;renderRooms()});$('publicRoomSearch').addEventListener('input',()=>{ $('roomSearch').value=$('publicRoomSearch').value;renderRooms()});
  $('peopleInfo').addEventListener('click',()=>notify('People in the list are here right now.'));$('mobileMenu').addEventListener('click',()=>$('sidebar').classList.toggle('open'));document.addEventListener('click',e=>{if(e.target.closest('.room-item'))$('sidebar').classList.remove('open')});

  renderProfile();
  if(!db){renderRooms();ui.onlineLabel.textContent='Add Supabase keys to connect';$('authConfigNote').classList.remove('hidden');}else{db.auth.getSession().then(({data})=>handleSession(data.session));db.auth.onAuthStateChange((_event,session)=>{setTimeout(()=>handleSession(session),0)})}
  showAuth(new URLSearchParams(location.search).get('view')==='forgot'?'forgot':'login');
})();
