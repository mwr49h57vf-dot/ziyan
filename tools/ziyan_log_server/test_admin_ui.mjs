import {spawn} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve, sep} from 'node:path';
import assert from 'node:assert/strict';

const temporary = mkdtempSync(join(tmpdir(), 'ziyan-admin-ui-'));
const python = process.argv[2];
assert(python, 'Pass the existing Python runtime path');
const service = spawn(python, ['tools/ziyan_log_server/ui_fixture.py', join(temporary,'data')], {windowsHide:true});
let chrome, ws;
try {
  const port = await new Promise((resolve,reject)=>{
    let text='';
    const timer=setTimeout(()=>reject(new Error('fixture startup timed out')),15000);
    service.stdout.on('data',chunk=>{text+=chunk;const match=text.match(/\{"port": (\d+)\}/);if(match){clearTimeout(timer);resolve(Number(match[1]));}});
    service.once('exit',code=>reject(new Error('fixture exited '+code)));
  });
  const profile=join(temporary,'chrome');
  chrome=spawn('C:/Program Files/Google/Chrome/Application/chrome.exe',[
    '--headless=new','--remote-debugging-port=0',`--user-data-dir=${profile}`,
    '--no-first-run','--no-default-browser-check','--disable-gpu','--window-size=1500,1100','about:blank'
  ],{stdio:['ignore','ignore','pipe'],windowsHide:true});
  chrome.stderr.on('data',chunk=>process.stderr.write(chunk));
  let debugPort;
  for(let i=0;i<60&&!debugPort;i++){
    try{debugPort=Number(readFileSync(join(profile,'DevToolsActivePort'),'utf8').split('\n')[0]);}catch{}
    if(!debugPort)await new Promise(r=>setTimeout(r,250));
  }
  const pages=await(await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
  console.log('Connected fixture port='+port+' browser='+debugPort);
  ws=new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl);
  await new Promise((res,rej)=>{ws.onopen=res;ws.onerror=rej;});
  let next=1;const pending=new Map(), exceptions=[], responses=[], consoleErrors=[], loadingFailures=[];
  const send=(method,params={})=>new Promise((resolve,reject)=>{
    const id=next++,timer=setTimeout(()=>{pending.delete(id);reject(new Error('CDP timeout '+method));},15000);
    pending.set(id,{resolve:value=>{clearTimeout(timer);resolve(value);},reject});
    ws.send(JSON.stringify({id,method,params}));
  });
  ws.onmessage=event=>{
    const message=JSON.parse(event.data);
    if(message.id){const p=pending.get(message.id);if(p){pending.delete(message.id);message.error?p.reject(message.error):p.resolve(message.result);}return;}
    if(message.method==='Runtime.exceptionThrown')exceptions.push(message.params.exceptionDetails);
    if(message.method==='Runtime.consoleAPICalled'&&message.params.type==='error')consoleErrors.push(message.params.args);
    if(message.method==='Network.loadingFailed')loadingFailures.push(message.params.errorText);
    if(message.method==='Network.responseReceived'&&message.params.response.url.includes('/api/'))responses.push({url:message.params.response.url,status:message.params.response.status});
  };
  ws.onerror=event=>console.error('CDP socket error',event.message,event.error);
  ws.onclose=event=>console.log('CDP socket closed',event.code);
  const evaluate=async expression=>{
    const r=await send('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});
    if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));
    return r.result.value;
  };
  const click=async id=>{
    const point=await evaluate(`(()=>{const el=document.getElementById(${JSON.stringify(id)});el.scrollIntoView({block:'center'});const r=el.getBoundingClientRect();const x=r.left+r.width/2,y=r.top+r.height/2;return {x,y,hit:document.elementFromPoint(x,y)===el};})()`);
    assert(point.hit,'button must receive clicks: '+id);
    await send('Input.dispatchMouseEvent',{type:'mousePressed',x:point.x,y:point.y,button:'left',clickCount:1});
    await send('Input.dispatchMouseEvent',{type:'mouseReleased',x:point.x,y:point.y,button:'left',clickCount:1});
  };
  const waitText=async(id,part)=>{
    for(let i=0;i<60;i++){
      const text=await evaluate(`document.getElementById(${JSON.stringify(id)}).textContent`);
      if(text.includes(part))return text;
      await new Promise(r=>setTimeout(r,100));
    }
    throw new Error('missing UI result '+id+' '+part);
  };
  console.log('Enabling CDP domains');
  await send('Runtime.enable');await send('Page.enable');await send('Network.enable');
  await send('Page.navigate',{url:`http://127.0.0.1:${port}/`});
  await waitText('authMsg','尚未授权');
  await click('btnPublish');
  const missing=await waitText('pubMsg','缺少管理员凭证');
  await evaluate(`document.getElementById('adminToken').value='synthetic-browser-device-token'`);
  await click('btnAuthorize');
  const denied=await waitText('authMsg','权限不足');
  assert(responses.some(r=>r.url.endsWith('/api/admin/session')&&r.status===403));
  await evaluate(`document.getElementById('adminToken').value='synthetic-expired-token'`);
  await click('btnPublish');
  const expired=await waitText('pubMsg','已失效');
  assert(responses.some(r=>r.url.endsWith('/api/hotupdate/publish')&&r.status===403));
  await evaluate(`document.getElementById('adminToken').value='synthetic-browser-publisher-token'`);
  await click('btnAuthorize');
  const authorized=await waitText('authMsg','已获得发布权限');
  await evaluate(`document.getElementById('pVersion').value='1.2-1';document.getElementById('pPkg').value='sample.deb';document.getElementById('pZMin').value='1.0'`);
  await click('btnPublish');
  const published=await waitText('pubMsg','发布成功');
  await click('btnManifest');
  await waitText('manifestBox','1.2-1');
  await click('btnForgetAuth');
  assert.equal(await evaluate(`document.getElementById('adminToken').value`),'');
  assert.equal(await evaluate('localStorage.length+sessionStorage.length'),0);
  assert.deepEqual(exceptions,[]);
  assert.deepEqual(consoleErrors,[]);
  assert.deepEqual(loadingFailures,[]);
  const result={missing,denied,expired,authorized,published,exceptions,consoleErrors,loadingFailures,responses,credentialStored:false};
  const screenshot=await send('Page.captureScreenshot',{format:'png'});
  writeFileSync('DOCS/repair-20260912/admin-ui.png',Buffer.from(screenshot.data,'base64'));
  writeFileSync('DOCS/repair-20260912/admin-ui-result.json',JSON.stringify(result,null,2));
  console.log(JSON.stringify(result,null,2));
} finally {
  ws?.close();chrome?.kill();service.kill();
  await new Promise(r=>setTimeout(r,500));
  // The only recursive cleanup target is the exact directory returned by mkdtemp.
  assert(resolve(temporary).startsWith(resolve(tmpdir())+sep));
  try{rmSync(temporary,{recursive:true,force:true,maxRetries:5,retryDelay:300});}catch(e){console.error('Temporary cleanup deferred: '+e.message);}
}
