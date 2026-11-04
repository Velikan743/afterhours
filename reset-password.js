(() => {
  const config=window.AFTERHOURS_CONFIG||{};
  const configured=config.supabaseUrl&&!config.supabaseUrl.includes('YOUR_PROJECT')&&config.supabaseAnonKey&&!config.supabaseAnonKey.includes('YOUR_SUPABASE');
  const client=configured&&window.supabase?window.supabase.createClient(config.supabaseUrl,config.supabaseAnonKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null;
  const $=id=>document.getElementById(id);
  let recoveryReady=false;
  const show=id=>$(id).classList.remove('hidden');
  const hide=id=>$(id).classList.add('hidden');
  function failed(message){hide('resetChecking');hide('resetForm');$('resetFailureCopy').textContent=message||'It may have expired or already been used. Request a new password reset email and try again.';show('resetFailure')}
  if(!client){failed('Connect Supabase in config.js before using password reset.');return}
  client.auth.onAuthStateChange((event,session)=>{
    if(event==='PASSWORD_RECOVERY'&&session){recoveryReady=true;hide('resetChecking');hide('resetFailure');show('resetForm');$('newPassword').focus()}
  });
  const params=new URLSearchParams(location.search);
  if(params.has('error')||params.has('error_description')){failed('This reset link is invalid or expired. Request a new password reset email and try again.');return}
  setTimeout(()=>{if(!recoveryReady)failed('This reset link is invalid or expired. Request a new password reset email and try again.')},5000);
  $('resetForm').addEventListener('submit',async event=>{
    event.preventDefault();if(!recoveryReady)return;
    const password=$('newPassword').value,confirm=$('confirmPassword').value;
    if(password!==confirm){$('resetFeedback').textContent='Those passwords do not match.';$('confirmPassword').focus();return}
    const button=$('resetSubmit');button.disabled=true;button.firstChild.textContent='Saving…';$('resetFeedback').textContent='';
    const {error}=await client.auth.updateUser({password});
    if(error){button.disabled=false;button.firstChild.textContent='Save new password';$('resetFeedback').textContent=error.message;return}
    try{for(let i=localStorage.length-1;i>=0;i--){const key=localStorage.key(i);if(key?.startsWith('afterhours.login-attempts.v1:'))localStorage.removeItem(key)}}catch{}
    await client.auth.signOut();
    hide('resetForm');hide('resetChecking');show('resetSuccess');
  });
})();
