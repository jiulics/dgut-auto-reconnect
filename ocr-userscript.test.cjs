const {test}=require('node:test');
const assert=require('node:assert/strict');
const api=require('./dgut-reconnect.user.js');
test('four ascii digits only',()=>{
  assert.equal(typeof api.validCode,'function');
  assert.equal(api.validCode('1234'),true);
  for(const s of ['123','12O4','１２３４','12345']) assert.equal(api.validCode(s),false);
});
test('fill real input dispatches events, not placeholder',()=>{
  assert.equal(typeof api.fillCode,'function');
  const events=[]; const input={value:'',setAttribute(k,v){this[k]=v},dispatchEvent(e){events.push(e.type)}};
  api.fillCode(input,'1234',class {constructor(type){this.type=type}});
  assert.equal(input.value,'1234');assert.deepEqual(events,['input','change','blur']);
});
test('no stale captcha submit',()=>{
  assert.equal(typeof api.maySubmit,'function');
  assert.equal(api.maySubmit({paused:false,conflict:false,before:'a',after:'a'}),true);
  for(const args of [{paused:true,conflict:false,before:'a',after:'a'},{paused:false,conflict:true,before:'a',after:'a'},{paused:false,conflict:false,before:'a',after:'b'}]) assert.equal(api.maySubmit(args),false);
});
