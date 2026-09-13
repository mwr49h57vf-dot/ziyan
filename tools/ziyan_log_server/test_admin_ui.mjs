// Browser acceptance for the ZiYan log-service admin page.
//
// Runs a REAL Chrome over CDP and performs REAL mouse clicks (Input.dispatchMouseEvent),
// not element.click() from JS. Two modes:
//
//   fixture : boots tools/ziyan_log_server/ui_fixture.py (synthetic loopback server) and
//             exercises the auth / publish / manifest flows plus the desktop export.
//   --live  : attaches to an already-running real server, e.g.
//             node tools/ziyan_log_server/test_admin_ui.mjs --live http://127.0.0.1:18091
//
// Usage:
//   node tools/ziyan_log_server/test_admin_ui.mjs [--python /usr/bin/python3]
//   node tools/ziyan_log_server/test_admin_ui.mjs --live http://127.0.0.1:18091
//
// Chrome is resolved per platform (override with ZY_CHROME=/path/to/chrome).
import {spawn} from 'node:child_process';
import {existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join, resolve, sep} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');

// --- Chrome discovery -------------------------------------------------------
// The original script hardcoded 'C:/Program Files/Google/Chrome/Application/chrome.exe',
// which cannot run on macOS at all, so browser-side clicks were never actually verified.
function findChrome(){
  const candidates = [];
  if(process.env.ZY_CHROME) candidates.push(process.env.ZY_CHROME);
  if(process.platform === 'darwin'){
    candidates.push(
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
      '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    );
  } else if(process.platform === 'win32'){
    for(const base of [process.env['PROGRAMFILES'], process.env['PROGRAMFILES(X86)'], process.env['LOCALAPPDATA']]){
      if(base) candidates.push(join(base,'Google/Chrome/Application/chrome.exe'));
    }
  } else {
    candidates.push('/usr/bin/google-chrome','/usr/bin/chromium','/usr/bin/chromium-browser');
  }
  for(const c of candidates){ if(c && existsSync(c)) return c; }
  throw new Error('Chrome not found. Tried:\n  '+candidates.filter(Boolean).join('\n  ')+
    '\nSet ZY_CHROME=/path/to/chrome to override.');
}

// --- args -------------------------------------------------------------------
const argv = process.argv.slice(2);
const flag = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i+1] : undefined; };
const LIVE = argv.includes('--live') ? (flag('--live') || 'http://127.0.0.1:18091') : null;
const python = flag('--python') || argv.find(a => !a.startsWith('--') && !LIVE) || '/usr/bin/python3';
const EVIDENCE = process.env.ZY_EVIDENCE_DIR || join(REPO_ROOT, 'DOCS', 'repair-20260913');
mkdirSync(EVIDENCE, {recursive:true});

const chromePath = findChrome();
console.log('Chrome: '+chromePath);
console.log('Mode: '+(LIVE ? 'live '+LIVE : 'fixture (python='+python+')'));

const temporary = mkdtempSync(join(tmpdir(), 'ziyan-admin-ui-'));
let service = null, chrome = null, ws = null;
let fixturePort = null;

async function waitForFixturePort(){
  return await new Promise((resolvePort, reject)=>{
    let text='';
    const timer=setTimeout(()=>reject(new Error('fixture startup timed out')),15000);
    service.stdout.on('data',chunk=>{text+=chunk;const match=text.match(/\{"port": (\d+)\}/);if(match){clearTimeout(timer);resolvePort(Number(match[1]));}});
    service.stderr.on('data',chunk=>process.stderr.write('[fixture] '+chunk));
    service.once('exit',code=>reject(new Error('fixture exited '+code)));
  });
}

try {
  let baseUrl;
  if(LIVE){
    baseUrl = LIVE.replace(/\/+$/,'')+'/';
  } else {
    // Absolute paths + explicit cwd: the script must run from anywhere, not only the repo root.
    service = spawn(python, [join(REPO_ROOT,'tools','ziyan_log_server','ui_fixture.py'), join(temporary,'data')],
      {cwd:REPO_ROOT, windowsHide:true});
    fixturePort = await waitForFixturePort();
    baseUrl = `http://127.0.0.1:${fixturePort}/`;
    // Seed one durable record so /api/logs/export_desktop has something real to write.
    const seeded = await fetch(baseUrl+'api/logs',{method:'POST',
      headers:{'Content-Type':'application/json','Authorization':'Bearer synthetic-browser-device-token'},
      body:JSON.stringify({event_id:'zye_browser_export_1',device:'browser-fixture',type:'script_error',
        time_unix:Math.floor(Date.now()/1000),script:'browser_e2e.lua',message:'browser export seed'})});
    assert.equal(seeded.status,200,'fixture must accept the seeded log record');
  }

  const profile=join(temporary,'chrome');
  chrome=spawn(chromePath,[
    '--headless=new','--remote-debugging-port=0',`--user-data-dir=${profile}`,
    '--no-first-run','--no-default-browser-check','--disable-gpu','--window-size=1500,1100','about:blank'
  ],{stdio:['ignore','ignore','pipe'],windowsHide:true});
  chrome.stderr.on('data',chunk=>process.stderr.write(chunk));
  chrome.on('error',e=>{throw e;});
  let debugPort;
  for(let i=0;i<60&&!debugPort;i++){
    try{debugPort=Number(readFileSync(join(profile,'DevToolsActivePort'),'utf8').split('\n')[0]);}catch{}
    if(!debugPort)await new Promise(r=>setTimeout(r,250));
  }
  assert(debugPort,'Chrome did not expose a DevTools port');
  const pages=await(await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
  console.log('Connected base='+baseUrl+' browser='+debugPort);
  ws=new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl);
  await new Promise((res,rej)=>{ws.onopen=res;ws.onerror=rej;});
  let next=1;const pending=new Map(), exceptions=[], responses=[], requests=[], consoleErrors=[], loadingFailures=[];
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
    // Record EVERY request/response. Filtering on '/api/' here previously hid the
    // /apt/* and /hotupdate/manifest.json calls the page also makes.
    if(message.method==='Network.requestWillBeSent'){
      const u=message.params.request.url;
      if(u.startsWith('http')) requests.push({url:u,method:message.params.request.method});
    }
    if(message.method==='Network.responseReceived'){
      const u=message.params.response.url;
      if(u.startsWith('http')) responses.push({url:u,status:message.params.response.status});
    }
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
  // Same real-click semantics, but addressed by CSS selector for non-id targets
  // (e.g. anchor links the page builds itself).
  const clickSel=async selector=>{
    const point=await evaluate(`(()=>{const el=document.querySelector(${JSON.stringify(selector)});if(!el)return null;el.scrollIntoView({block:'center'});const r=el.getBoundingClientRect();const x=r.left+r.width/2,y=r.top+r.height/2;return {x,y,hit:document.elementFromPoint(x,y)===el};})()`);
    assert(point,'selector must exist: '+selector);
    assert(point.hit,'element must receive clicks: '+selector);
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
  await send('Page.navigate',{url:baseUrl});
  await waitText('boardMsg','已刷新');

  // --- desktop export: real click, real API call, real files on disk ---------
  // Regression lock for the defect this test previously never touched:
  // `const q = buildQuery(false)` referenced a function that does not exist, so the
  // click always threw ReferenceError and listMsg stayed at "导出到桌面中...".
  const startedAt = new Date();
  const stampNow = (d)=>{const p=n=>String(n).padStart(2,'0');
    return `${d.getFullYear()}${p(d.getMonth()+1)}${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;};
  const beforeStamp = stampNow(new Date(startedAt.getTime()-2000));
  await click('btnExportDesktop');
  const exportMsg = await waitText('listMsg','已写入桌面');
  assert(!exportMsg.includes('导出异常'),'export must not report an exception: '+exportMsg);
  assert(!exportMsg.includes('导出失败'),'export must not report failure: '+exportMsg);
  const exportCall = responses.filter(r=>r.url.includes('/api/logs/export_desktop')&&r.status===200);
  assert(exportCall.length>0,'browser must have called /api/logs/export_desktop and got 200: '+JSON.stringify(responses));
  const m = exportMsg.match(/已写入桌面:\s*(.+?)（(\d+)\s*条）/);
  assert(m,'export message must carry the written directory: '+exportMsg);
  const [, exportDir, exportCount] = m;
  assert(Number(exportCount)>0,'export must write at least one record, got '+exportCount);
  assert(existsSync(exportDir),'export directory must exist: '+exportDir);
  const exportStamp = exportDir.split('/').pop();
  assert(exportStamp >= beforeStamp,'export must be a NEW directory, not a stale one: '+exportStamp+' < '+beforeStamp);
  console.log('EXPORT dir='+exportDir+' count='+exportCount);

  // --- every OTHER API the page calls, driven by a real click ----------------
  // Acceptance requires real evidence for each endpoint, and curl may not be used
  // to stand in for a browser click.
  const apiEvidence = {};
  const waitForRequest = async (urlPart, since, timeoutMs=15000) => {
    const deadline = Date.now()+timeoutMs;
    while(Date.now() < deadline){
      const hit = responses.slice(since).filter(r=>r.url.includes(urlPart));
      if(hit.length) return hit;
      await new Promise(r=>setTimeout(r,100));
    }
    throw new Error('no request observed matching '+urlPart+' within '+timeoutMs+'ms; saw '+
      JSON.stringify(responses.slice(since)));
  };
  const record = async (label, buttonId, waitId, waitPart, urlPart) => {
    const before = responses.length;
    console.log('SWEEP click '+label+' ('+buttonId+')');
    await click(buttonId);
    console.log('SWEEP clicked '+label+', waiting for '+urlPart+' request + '+waitId+'~'+JSON.stringify(waitPart));
    let text;
    try {
      // Evidence must be the API call the click actually caused, so wait for that
      // call first; then confirm the UI reflected its result.
      const hit = await waitForRequest(urlPart, before);
      if(waitPart) text = await waitText(waitId, waitPart);
      else text = await evaluate(`document.getElementById(${JSON.stringify(waitId)}).textContent`);
      const statuses = hit.map(r=>r.status);
      assert(statuses.every(s=>s<400),'API call must succeed for '+label+': '+JSON.stringify(hit));
      console.log('SWEEP ok '+label+' :: '+statuses.join(',')+' :: '+String(text).slice(0,120).replace(/\n/g,' '));
      apiEvidence[label]={ok:true,button:buttonId,uiText:String(text).slice(0,200),requests:hit};
      return apiEvidence[label];
    }
    catch(e){
      let diag=null;
      try{ diag = await evaluate(`(()=>{const el=document.getElementById(${JSON.stringify(waitId)});return el?el.textContent:'(no such element)';})()`); }catch(_){}
      console.log('SWEEP FAILED '+label+' :: '+e+' :: targetText='+JSON.stringify(diag));
      apiEvidence[label]={ok:false,button:buttonId,error:String(e),targetText:diag,
      seen:responses.slice(before)}; return apiEvidence[label];
    }
  };

  await record('看板刷新 /api/logs','btnRefresh','boardMsg','已刷新','/api/logs?');
  await record('查询 /api/logs','btnQuery','listMsg','返回=','/api/logs?limit=');
  await record('APT Release /apt/Release','btnAptRelease','aptMsg','HTTP 200','/apt/Release');
  await record('热更新检查 /api/hotupdate/check','btnCheck','checkResult','"ok"','/api/hotupdate/check');
  await record('拉取 manifest','btnManifest','manifestBox','versions','/hotupdate/manifest.json');

  // Downloads: an <a download> click is not dispatched through the Network domain,
  // so assert the bytes actually land on disk with a real download path instead of
  // pretending a request was observed.
  const downloadDir = join(temporary,'downloads');
  mkdirSync(downloadDir,{recursive:true});
  const setDownload = async () => {
    try { await send('Browser.setDownloadBehavior',{behavior:'allow',downloadPath:downloadDir,eventsEnabled:true}); return 'Browser.setDownloadBehavior'; }
    catch { await send('Page.setDownloadBehavior',{behavior:'allow',downloadPath:downloadDir}); return 'Page.setDownloadBehavior'; }
  };
  const sweepDownload = async (label, buttonId, expectName) => {
    const before = responses.length;
    console.log('SWEEP click '+label+' ('+buttonId+')');
    await click(buttonId);
    const msg = await waitText('listMsg', expectName ? 'download.zip' : 'download.zip');
    const deadline = Date.now()+20000;
    let landed = null;
    while(Date.now()<deadline){
      const f = readdirSync(downloadDir).filter(n=>n.endsWith('.zip') && !n.endsWith('.crdownload'));
      if(f.length){ landed = f[0]; break; }
      await new Promise(r=>setTimeout(r,200));
    }
    if(!landed){
      apiEvidence[label]={ok:false,button:buttonId,uiText:msg,note:'no zip appeared in download dir',
        downloadDir, requests:responses.slice(before)};
      console.log('SWEEP FAILED '+label+' :: no zip landed');
      return apiEvidence[label];
    }
    const full = join(downloadDir,landed);
    const size = statSync(full).size;
    // A real .deb-style zip starts with the PK signature.
    const head = readFileSync(full).subarray(0,2).toString('latin1');
    assert(head==='PK','downloaded file must be a real zip, got '+JSON.stringify(head));
    assert(size>0,'downloaded zip must be non-empty');
    console.log('SWEEP ok '+label+' :: '+landed+' bytes='+size);
    apiEvidence[label]={ok:true,button:buttonId,uiText:msg,file:landed,bytes:size,downloadDir};
    return apiEvidence[label];
  };
  const downloadMode = await setDownload();
  await sweepDownload('下载全部 /api/logs/download.zip','btnDownloadAll',true);
  await sweepDownload('按筛选下载 /api/logs/download.zip','btnDownload',true);

  // 公钥链接是 location.href 跳转（不是 fetch），所以用真实点击 + 真实导航来验证，
  // 验证完再导航回管理页继续其余检查。
  {
    const label='公钥 /apt/ziyan-apt-key.asc';
    const before=responses.length;
    console.log('SWEEP click '+label+' (a[href="/apt/ziyan-apt-key.asc"])');
    await clickSel('a[href="/apt/ziyan-apt-key.asc"]');
    try{
      await waitForRequest('/apt/ziyan-apt-key.asc', before);
      // 等到地址栏真的变成该 URL，确认导航发生
      const deadline=Date.now()+15000;
      let href=null;
      while(Date.now()<deadline){
        href=await evaluate('location.pathname');
        if(href && href.includes('ziyan-apt-key.asc')) break;
        await new Promise(r=>setTimeout(r,150));
      }
      const body=await evaluate('document.body.innerText.slice(0,80)');
      const hit=responses.slice(before).filter(r=>r.url.includes('ziyan-apt-key.asc'));
      const ok = href && href.includes('ziyan-apt-key.asc') && hit.some(r=>r.status===200)
        && /BEGIN PGP PUBLIC KEY BLOCK/.test(body);
      console.log((ok?'SWEEP ok ':'SWEEP FAILED ')+label+' :: pathname='+href+' :: '+JSON.stringify(body.slice(0,40)));
      apiEvidence[label]={ok:!!ok,link:'a[href="/apt/ziyan-apt-key.asc"]',pathname:href,
        bodyHead:body.slice(0,80),requests:hit};
    }catch(e){
      apiEvidence[label]={ok:false,error:String(e),seen:responses.slice(before)};
      console.log('SWEEP FAILED '+label+' :: '+e);
    }
    // 回到管理页，保证后续步骤不受导航影响
    await send('Page.navigate',{url:baseUrl});
    await waitText('boardMsg','已刷新');
  }

  // 详情 GET /api/logs/<id>: click the first row's 查看 button
  const rowBtn = await evaluate(`(()=>{const b=document.querySelector('#rows tr td:last-child button');return b?true:false;})()`);
  if(rowBtn){
    const before=responses.length;
    await clickSel('#rows tr td:last-child button');
    try{
      const hit=(await waitForRequest('/api/logs/',before)).filter(r=>/\/api\/logs\/[^/?]+$/.test(r.url));
      await waitText('detail','event_id');
      apiEvidence['详情 /api/logs/<id>']={ok:hit.length>0,requests:hit};
    }catch(e){
      apiEvidence['详情 /api/logs/<id>']={ok:false,error:String(e),seen:responses.slice(before)};
    }
  } else {
    apiEvidence['详情 /api/logs/<id>']={ok:false,error:'no row button rendered (list empty)'};
  }

  // --- auth / publish / manifest (fixture mode only) -------------------------
  const result={mode:LIVE?'live':'fixture',baseUrl,exportMsg,exportDir,exportCount:Number(exportCount),
    apiEvidence,downloadEvidence:{dir:downloadDir,mode:downloadMode}};
  if(!LIVE){
    const missing=await waitText('authMsg','尚未授权');
    await click('btnPublish');
    result.missing=await waitText('pubMsg','缺少管理员凭证');
    await evaluate(`document.getElementById('adminToken').value='synthetic-browser-device-token'`);
    await click('btnAuthorize');
    result.denied=await waitText('authMsg','权限不足');
    assert(responses.some(r=>r.url.endsWith('/api/admin/session')&&r.status===403));
    await evaluate(`document.getElementById('adminToken').value='synthetic-expired-token'`);
    await click('btnPublish');
    result.expired=await waitText('pubMsg','已失效');
    assert(responses.some(r=>r.url.endsWith('/api/hotupdate/publish')&&r.status===403));
    await evaluate(`document.getElementById('adminToken').value='synthetic-browser-publisher-token'`);
    await click('btnAuthorize');
    result.authorized=await waitText('authMsg','已获得发布权限');
    await evaluate(`document.getElementById('pVersion').value='1.2-1';document.getElementById('pPkg').value='sample.deb';document.getElementById('pZMin').value='1.0'`);
    await click('btnPublish');
    result.published=await waitText('pubMsg','发布成功');
    await click('btnManifest');
    await waitText('manifestBox','1.2-1');
    await click('btnForgetAuth');
    assert.equal(await evaluate(`document.getElementById('adminToken').value`),'');
    assert.equal(await evaluate('localStorage.length+sessionStorage.length'),0);
    result.credentialStored=false;
  } else {
    const missing=await waitText('authMsg','尚未授权');
    result.missing=missing;
  }

  // --- the whole point: no uncaught exception anywhere, including the export --
  assert.deepEqual(exceptions,[],'no uncaught page exception allowed (ReferenceError would land here)');
  assert.deepEqual(consoleErrors,[]);
  assert.deepEqual(loadingFailures,[]);
  // Recording a failed sweep item in the evidence file is NOT enough: without this
  // assertion a real API regression was written out as {ok:false} while the run still
  // exited 0. Every endpoint the page exposes must actually work for the run to pass.
  const failedSweep = Object.keys(apiEvidence).filter(k=>!apiEvidence[k].ok);
  assert.deepEqual(failedSweep,[],'every API sweep item must pass; failing: '+failedSweep.join(', '));
  result.exceptions=exceptions;result.consoleErrors=consoleErrors;
  result.loadingFailures=loadingFailures;result.responses=responses;

  const suffix = LIVE ? '-live' : '';
  const screenshot=await send('Page.captureScreenshot',{format:'png'});
  writeFileSync(join(EVIDENCE,'admin-ui'+suffix+'.png'),Buffer.from(screenshot.data,'base64'));
  writeFileSync(join(EVIDENCE,'admin-ui'+suffix+'-result.json'),JSON.stringify(result,null,2));
  console.log(JSON.stringify(result,null,2));
  console.log('EVIDENCE '+join(EVIDENCE,'admin-ui'+suffix+'-result.json'));
} catch (e) {
  // Without this catch the pending exception was discarded by the process.exit()
  // below, so EVERY failure exited 0 and CI could never see a red run.
  console.error('FAIL', e && e.stack ? e.stack : e);
  process.exitCode = 1;
} finally {
  // Chrome/browser download bookkeeping keeps handles open, so an explicit exit is
  // required; otherwise the assertions pass but the process never terminates.
  ws?.close();chrome?.kill('SIGKILL');service?.kill('SIGKILL');
  await new Promise(r=>setTimeout(r,500));
  // The only recursive cleanup target is the exact directory returned by mkdtemp.
  assert(resolve(temporary).startsWith(resolve(tmpdir())+sep));
  try{rmSync(temporary,{recursive:true,force:true,maxRetries:5,retryDelay:300});}catch(e){console.error('Temporary cleanup deferred: '+e.message);}
  // Exit explicitly so a lingering Chrome/CDP handle cannot turn the run into a hang,
  // while still propagating the failure code set by the catch above.
  process.exit(process.exitCode ?? 0);
}
