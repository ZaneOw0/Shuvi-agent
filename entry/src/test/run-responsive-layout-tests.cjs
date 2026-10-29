'use strict';
const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
const {test}=require('node:test');
const root=path.resolve(__dirname,'../../..');
const sdk=process.env.DEVECO_SDK_HOME;
if(!sdk)throw Error('DEVECO_SDK_HOME required');
const ts=require(path.join(sdk,'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function loadModel(name){
  const source=fs.readFileSync(path.join(root,'entry/src/main/ets/model',name+'.ets'),'utf8');
  const mod={exports:{}};
  new Function('module','exports',ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText)(mod,mod.exports);
  return mod.exports;
}
const {ResponsiveLayoutPolicy:P}=loadModel('ResponsiveLayoutPolicy');
test('navigation changes only at the outer 840vp boundary',()=>{
  for(const [w,expected] of [[0,false],[320,false],[599,false],[600,false],[839,false],[840,true],[1024,true],[1920,true]])assert.equal(P.embedded(w),expected,String(w));
  for(const w of [NaN,Infinity,-Infinity,-1])assert.equal(P.embedded(w),false);
});
test('embedded navigation keeps at least 600vp of content at its narrowest width',()=>{
  for(let width=840;width<=2400;width++){
    const sidebar=P.sideWidth(width);assert(sidebar>=240&&sidebar<=280);assert(width-sidebar>=600);
  }
});
test('content has readable limits and never depends on the physical device type',()=>{
  assert.equal(P.contentLimit(599,true),640);assert.equal(P.contentLimit(600,true),720);
  assert.equal(P.contentLimit(839,false),720);assert.equal(P.contentLimit(840,true),840);
  assert.equal(P.contentLimit(840,false),960);assert.equal(P.contentLimit(NaN,false),640);
});
test('short knowledge authorization label is selected by remaining content width',()=>{
  assert.equal(P.compactActions(0),true);assert.equal(P.compactActions(479),true);
  assert.equal(P.compactActions(480),false);assert.equal(P.compactActions(720),false);
});
function pageFixture(){
  const source=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/Index.ets'),'utf8');
  const method=source.match(/  private resizeWindow\(width: number\): void \{[\s\S]*?\n  \}/);assert(method);
  const code=ts.transpileModule('class LayoutFixture {\n'+method[0]+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.None}}).outputText;
  const page=new Function('ResponsiveLayoutPolicy',code+';return new LayoutFixture();')(P);
  Object.assign(page,{windowWidth:0,wideLayout:false,drawerOpen:false,input:'保留未发送文字',tab:2,
    messages:[{id:'existing',text:'保留消息'}],draft:{id:'pending'},changeTab(){throw Error('No navigation during resize');},
    resetConversation(){throw Error('No reset during resize');}});
  return page;
}
test('actual window handler changes navigation without losing messages, input, draft or selected page',()=>{
  const page=pageFixture(),messages=page.messages,draft=page.draft;
  page.drawerOpen=true;page.resizeWindow(840);assert.equal(page.wideLayout,true);assert.equal(page.drawerOpen,false);
  page.resizeWindow(839);assert.equal(page.wideLayout,false);assert.equal(page.drawerOpen,false);
  assert.equal(page.messages,messages);assert.equal(page.draft,draft);assert.equal(page.input,'保留未发送文字');assert.equal(page.tab,2);
});
test('same-size or invalid callbacks do not close a deliberately opened compact drawer',()=>{
  const page=pageFixture();page.resizeWindow(600);page.drawerOpen=true;
  for(const w of [600,0,-1,NaN,Infinity])page.resizeWindow(w);
  assert.equal(page.drawerOpen,true);assert.equal(page.windowWidth,600);
});
test('changing content width is not fed back into the outer-window navigation decision',()=>{
  const page=pageFixture();page.resizeWindow(840);page.contentWidth=600;
  assert.equal(page.wideLayout,true);page.resizeWindow(840);assert.equal(page.wideLayout,true);
  page.resizeWindow(1600);page.contentWidth=1320;assert.equal(page.wideLayout,true);
});
test('floating entry clamps to the content area after rotations and very small windows',()=>{
  const {FloatingAssistantPlacement}=loadModel('FloatingAssistantPlacement');const floating=new FloatingAssistantPlacement();
  for(const [w,h] of [[600,900],[1100,600],[360,720],[100,80],[720,900]]){
    floating.resize(w,h,68);
    if(floating.canPlace){assert(floating.x>=20);assert(floating.x+60<=w-20);assert(floating.y>=80);assert(floating.y+60<=h-20);}
    else {assert.equal(floating.x,0);assert.equal(floating.y,0);}
  }
});
