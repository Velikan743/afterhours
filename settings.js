(() => {
  const config=window.AFTERHOURS_CONFIG||{};
  const configured=config.supabaseUrl&&config.supabaseAnonKey;
  const db=configured&&window.supabase?window.supabase.createClient(config.supabaseUrl,config.supabaseAnonKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null;
  const $=id=>document.getElementById(id);
  let user=null, selectedFile=null, toastTimer, cropSourceUrl='', previewUrl='', cropWidth=0, cropHeight=0, zoom=1, panX=0, panY=0, drag=null;
  const showFeedback=(id,text,success=false)=>{const node=$(id);node.textContent=text;node.classList.toggle('success',success)};
  function initials(name='?'){return name.trim().split(/\s+/).slice(0,2).map(part=>part[0]||'').join('').toUpperCase()||'?'}
  function showAvatar(node,name,url){node.replaceChildren();if(url){const img=document.createElement('img');img.src=url;img.alt=`${name}'s profile picture`;node.append(img)}else node.textContent=initials(name)}
  function toast(message){const node=$('settingsToast');node.textContent=message;node.classList.add('show');clearTimeout(toastTimer);toastTimer=setTimeout(()=>node.classList.remove('show'),2600)}
  function setBusy(buttonId,busy,label){const button=$(buttonId);button.disabled=busy;if(busy){button.dataset.idle=button.firstChild.textContent;button.firstChild.textContent=label}else if(button.dataset.idle){button.firstChild.textContent=button.dataset.idle;delete button.dataset.idle}}
  async function requireUser(){if(!db){toast('Supabase is not configured.');return}const {data,error}=await db.auth.getUser();user=data?.user||null;if(error||!user){location.replace('./?view=login');return}const metadata=user.user_metadata||{};const name=metadata.username||metadata.full_name||metadata.name||user.email?.split('@')[0]||'Someone';$('settingsUsername').value=metadata.username||metadata.full_name||name;$('settingsMobile').value=metadata.phone||'';$('settingsEmail').value=user.email||'';showAvatar($('avatarPreview'),name,metadata.avatar_url||'')}
  function paintCrop(){if(!cropWidth||!cropHeight)return;const box=$('cropViewport'),img=$('cropImage'),width=box.clientWidth,height=box.clientHeight,scale=Math.max(width/cropWidth,height/cropHeight)*zoom,imageWidth=cropWidth*scale,imageHeight=cropHeight*scale;const baseX=(width-imageWidth)/2,baseY=(height-imageHeight)/2;panX=Math.min((imageWidth-width)/2,Math.max(-(imageWidth-width)/2,panX));panY=Math.min((imageHeight-height)/2,Math.max(-(imageHeight-height)/2,panY));img.style.width=`${imageWidth}px`;img.style.height=`${imageHeight}px`;img.style.left=`${baseX+panX}px`;img.style.top=`${baseY+panY}px`}
  function closeCrop(){if($('cropDialog').open)$('cropDialog').close();if(cropSourceUrl){URL.revokeObjectURL(cropSourceUrl);cropSourceUrl=''}$('avatarFile').value=''}
  $('avatarFile').addEventListener('change',async()=>{const file=$('avatarFile').files?.[0];if(!file)return;if(!['image/png','image/jpeg','image/webp','image/gif'].includes(file.type)){showFeedback('profileFeedback','Choose a PNG, JPG, WebP, or GIF image.');$('avatarFile').value='';return}if(file.size>2*1024*1024){showFeedback('profileFeedback','The profile picture must be 2 MB or smaller.');$('avatarFile').value='';return}if(cropSourceUrl)URL.revokeObjectURL(cropSourceUrl);cropSourceUrl=URL.createObjectURL(file);$('cropImage').src=cropSourceUrl;try{await $('cropImage').decode();cropWidth=$('cropImage').naturalWidth;cropHeight=$('cropImage').naturalHeight;zoom=1;panX=0;panY=0;$('cropZoom').value='1';$('cropDialog').showModal();requestAnimationFrame(paintCrop);showFeedback('profileFeedback','')}catch{showFeedback('profileFeedback','This image could not be opened. Choose another picture.');closeCrop()}});
  $('cropZoom').addEventListener('input',()=>{zoom=Number($('cropZoom').value);paintCrop()});
  $('cropDialog').addEventListener('close',()=>{if(cropSourceUrl){URL.revokeObjectURL(cropSourceUrl);cropSourceUrl=''}$('avatarFile').value=''});
  window.addEventListener('resize',()=>{if($('cropDialog').open)paintCrop()});
  $('cropViewport').addEventListener('pointerdown',event=>{drag={x:event.clientX,y:event.clientY,panX,panY};$('cropViewport').setPointerCapture(event.pointerId)});
  $('cropViewport').addEventListener('pointermove',event=>{if(!drag)return;panX=drag.panX+(event.clientX-drag.x);panY=drag.panY+(event.clientY-drag.y);paintCrop()});
  $('cropViewport').addEventListener('pointerup',()=>{drag=null});$('cropViewport').addEventListener('pointercancel',()=>{drag=null});
  $('cropCancel').addEventListener('click',closeCrop);$('cropClose').addEventListener('click',closeCrop);
  $('cropApply').addEventListener('click',async()=>{const size=512,box=$('cropViewport'),img=$('cropImage'),width=box.clientWidth,height=box.clientHeight,scale=Math.max(width/cropWidth,height/cropHeight)*zoom,imageWidth=cropWidth*scale,imageHeight=cropHeight*scale,left=(width-imageWidth)/2+panX,top=(height-imageHeight)/2+panY,canvas=document.createElement('canvas');canvas.width=size;canvas.height=size;const context=canvas.getContext('2d');context.fillStyle='#111714';context.fillRect(0,0,size,size);context.drawImage(img,left/width*size,top/height*size,imageWidth/width*size,imageHeight/height*size);const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',0.9));if(!blob){showFeedback('profileFeedback','Could not prepare this crop. Try another image.');return}selectedFile=new File([blob],'profile-picture.jpg',{type:'image/jpeg'});if(previewUrl)URL.revokeObjectURL(previewUrl);previewUrl=URL.createObjectURL(blob);showAvatar($('avatarPreview'),$('settingsUsername').value||'You',previewUrl);showFeedback('profileFeedback','Picture adjusted. Save your profile to upload it.',true);closeCrop()});
  $('settingsUsername').addEventListener('input',()=>{if(!selectedFile)showAvatar($('avatarPreview'),$('settingsUsername').value||'You',user?.user_metadata?.avatar_url||'')});
  $('profileForm').addEventListener('submit',async event=>{
    event.preventDefault();showFeedback('profileFeedback','');const username=$('settingsUsername').value.trim(),phone=$('settingsMobile').value.trim();
    if(!/^[A-Za-z0-9_]{3,24}$/.test(username)){showFeedback('profileFeedback','Use 3–24 letters, numbers, or underscores for the username.');return}
    const digits=phone.replace(/\D/g,'');if(digits.length<7||digits.length>15){showFeedback('profileFeedback','Enter a mobile number with 7–15 digits.');return}
    setBusy('profileSave',true,'Saving…');
    try{
      let avatarUrl=user.user_metadata?.avatar_url||null;
      if(selectedFile){const extension=selectedFile.type==='image/jpeg'?'jpg':selectedFile.type.split('/')[1];const path=`${user.id}/${crypto.randomUUID()}.${extension}`;const {error:uploadError}=await db.storage.from('profile-avatars').upload(path,selectedFile,{contentType:selectedFile.type,cacheControl:'3600',upsert:false});if(uploadError)throw uploadError;avatarUrl=db.storage.from('profile-avatars').getPublicUrl(path).data.publicUrl}
      const {data,error}=await db.auth.updateUser({data:{username,full_name:username,phone,avatar_url:avatarUrl}});if(error)throw error;user=data.user||user;
      const {error:historyError}=await db.from('messages').update({author_name:username,author_avatar_url:avatarUrl}).eq('user_id',user.id);
      selectedFile=null;showFeedback('profileFeedback',historyError?'Profile saved. Some older messages could not be refreshed.':'Profile saved.',!historyError);showAvatar($('avatarPreview'),username,avatarUrl||'');toast('Profile updated.');
    }catch(error){showFeedback('profileFeedback',`Could not save profile: ${error.message||'Please try again.'}`)}finally{setBusy('profileSave',false)}
  });
  $('passwordForm').addEventListener('submit',async event=>{
    event.preventDefault();showFeedback('passwordFeedback','');const current=$('currentPassword').value,next=$('newPassword').value,confirm=$('confirmPassword').value;
    if(next.length<8){showFeedback('passwordFeedback','Use at least 8 characters for the new password.');return}
    if(next!==confirm){showFeedback('passwordFeedback','The new passwords do not match.');return}
    if(next===current){showFeedback('passwordFeedback','Choose a new password that differs from your current one.');return}
    setBusy('passwordSave',true,'Verifying…');
    try{
      const {error:verifyError}=await db.auth.signInWithPassword({email:user.email,password:current});if(verifyError)throw new Error('The current password is incorrect.');
      setBusy('passwordSave',true,'Updating…');const {error:updateError}=await db.auth.updateUser({password:next});if(updateError)throw updateError;
      $('passwordForm').reset();showFeedback('passwordFeedback','Password updated successfully.',true);toast('Password updated.');
    }catch(error){showFeedback('passwordFeedback',error.message||'Could not update password. Please try again.')}finally{setBusy('passwordSave',false)}
  });
  requireUser();
})();
