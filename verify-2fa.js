(() => {
  const config=window.AFTERHOURS_CONFIG||{},configured=config.supabaseUrl&&config.supabaseAnonKey&&window.supabase;
  const db=configured?window.supabase.createClient(config.supabaseUrl,config.supabaseAnonKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null;
  const $=id=>document.getElementById(id),challengeId=sessionStorage.getItem('afterhours.pending-login-challenge');
  function feedback(message,success=false){const node=$('verifyFeedback');node.textContent=message;node.classList.toggle('success',success)}
  if(!db){feedback('Supabase is not configured.');$('verifySubmit').disabled=true}
  else if(!challengeId){feedback('This sign-in request has expired. Return to the sign-in page and try again.');$('verifySubmit').disabled=true}
  else setTimeout(()=>$('verificationCode').focus(),100);
  $('verifyForm').addEventListener('submit',async event=>{
    event.preventDefault();const code=$('verificationCode').value.trim();if(!/^[A-Za-z0-9]{8}$/.test(code)){feedback('Enter the 8-character code from your email.');return}
    const button=$('verifySubmit');button.disabled=true;button.firstChild.textContent='Verifying…';feedback('');
    try{const {data,error}=await db.functions.invoke('email-2fa',{body:{action:'verify_login',challengeId,code}});if(error)throw error;if(data?.error)throw new Error(data.error);if(!data?.session?.access_token||!data?.session?.refresh_token)throw new Error('Verification did not return a session.');const {error:setError}=await db.auth.setSession(data.session);if(setError)throw setError;sessionStorage.removeItem('afterhours.pending-login-challenge');try{localStorage.removeItem(`afterhours.login-attempts.v1:${data.session.user.email.trim().toLowerCase()}`)}catch{}location.replace('./')}
    catch(error){feedback(error.message||'Code verification failed. Try again.');button.disabled=false;button.firstChild.textContent='Confirm code '}
  });
})();
