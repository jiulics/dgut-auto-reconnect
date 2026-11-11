const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const file = require('node:path').join(__dirname, 'dgut-reconnect.user.js');
test('userscript exists', () => assert.ok(fs.existsSync(file), 'missing improved userscript'));
function scenario({paused=false, button=true, hidden=false, disabled=false,online=false,captcha=true,legacy=false,ocr='1234',mutate=false,offline=false,appears=false}={}) {
  let clicks=0, oldPauses=0, pixels='original', grants=0; const timers=[]; const values={paused}; const ids={};
  const element=()=>({textContent:'',style:{},append(){},addEventListener(){},getClientRects:()=>[{}],setAttribute(k,v){this[k]=v},dispatchEvent(){}});
  const target={...element(),disabled,getClientRects:()=>hidden?[]:[{}],click:()=>clicks++};
  if(button) ids.loginLink=target;
  ids.validCode=element(); ids.validCode_tip=element();
  if(captcha) ids.isDisplayValidCode=element();
  ids.validImage={complete:true,naturalWidth:100,naturalHeight:30,click(){pixels='new'}};
  if(legacy) ids['dgut-float-control']={style:{},querySelector:()=>({textContent:'暂停',click(){oldPauses++}})};
  const doc={getElementById:id=>ids[id]||null,
    createElement:tag=>tag==='canvas'?{getContext:()=>({drawImage(){}}),toDataURL:()=>pixels}:element(),
    body:{append(el){ids[el.id]=el}},documentElement:{}};
  const context={document:doc,window:{top:1,self:1},Event:class{constructor(type){this.type=type}},getComputedStyle:()=>({visibility:'visible'}),
    GM_getValue:(k,d)=>k in values?values[k]:d,GM_setValue:(k,v)=>values[k]=v,
    GM_xmlhttpRequest(req){
      if(offline) return req.onerror();
      let result={};
      if(req.url.endsWith('/state')) result={online};
      if(req.url.endsWith('/attempt')) {result={allowed:grants++===0}; if(appears) ids.isDisplayValidCode=element();}
      if(req.url.endsWith('/ocr')) {result={code:ocr};if(mutate)pixels='changed';}
      req.onload({status:200,responseText:JSON.stringify(result)});
    },setTimeout:fn=>timers.push(fn),console};
  vm.runInNewContext(fs.readFileSync(file,'utf8'),context);
  return {clicks:()=>clicks,oldPauses:()=>oldPauses,input:ids.validCode,tick:async()=>{const fn=timers.shift();if(fn)await fn();},reinject:()=>vm.runInNewContext(fs.readFileSync(file,'utf8'),context),timers};
}
test('OCR fills actual field before login and respects shared budget',async()=>{const s=scenario();await s.tick();assert.equal(s.input.value,'1234');assert.equal(s.clicks(),1);await s.tick();assert.equal(s.clicks(),1);});
test('no captcha still allows login',async()=>{const s=scenario({captcha:false});await s.tick();assert.equal(s.clicks(),1);});
for(const opt of [{paused:true},{button:false},{hidden:true},{disabled:true},{online:true},{online:null},{legacy:true},{ocr:'12x4'},{mutate:true},{offline:true}]) {
  test('does not click '+JSON.stringify(opt),async()=>{const s=scenario(opt);await s.tick();assert.equal(s.clicks(),0);});
}
test('old timer is paused and v2 refuses to compete',async()=>{const s=scenario({legacy:true});await s.tick();assert.equal(s.oldPauses(),1);assert.equal(s.clicks(),0);});
test('duplicate v2 injection creates no second loop',()=>{const s=scenario();s.reinject();assert.equal(s.timers.length,1);});
