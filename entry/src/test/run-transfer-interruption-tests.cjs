'use strict';
// Exact production transport + synthetic SDK/file/network doubles. Never load a user file or contact a provider.
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),crypto=require('node:crypto');
const { relativePosix }=require('./lib/portable.cjs');
if(process.env.CAPTURE_HOST_ONLY!=='1'||process.env.CAPTURE_SAFE_HOST!=='1')throw Error('CaptureHostBoundaryRequired');
const project=path.resolve(__dirname,'../../..'),sdk='/Applications/DevEco-Studio.app/Contents/sdk';
const ts=require(path.join(sdk,'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const out=path.join(project,'.cache/transfer-interruption');fs.mkdirSync(out,{recursive:true});
const roots=['infra/MineruTransportAdapter','infra/MineruCredentialStore','infra/DocumentFileAdapter'].map(n=>'entry/src/main/ets/knowledge/'+n+'.ets');
const visited=new Set();
function transpile(relative){if(visited.has(relative))return;visited.add(relative);const filename=path.join(project,relative),source=fs.readFileSync(filename,'utf8');for(const m of source.matchAll(/from\s+'(\.[^']+)'/g)){const target=relativePosix(project,path.resolve(path.dirname(filename),m[1]+'.ets'));if(!target.startsWith('entry/src/main/ets/knowledge/'))throw Error('RelativeSourceBoundary');transpile(target);}const target=path.join(out,relative.replace(/\.ets$/,'.js'));fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,ts.transpileModule(source,{fileName:filename.replace(/\.ets$/,'.ts'),compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText);console.log('TRANSFER_SOURCE_HASH file='+relative+' sha256='+crypto.createHash('sha256').update(source).digest('hex'));}
for(const root of roots)transpile(root);
const sdkSource=ts.createSourceFile('asset.ts',fs.readFileSync(path.join(sdk,'default/openharmony/ets/api/@ohos.security.asset.d.ts'),'utf8'),ts.ScriptTarget.Latest,true),ns=sdkSource.statements.find(n=>ts.isModuleDeclaration(n)&&n.name.text==='asset');
const names=['TagType','Tag','Accessibility','SyncType','ReturnType','ConflictResolution'],enums=ns.body.statements.filter(n=>ts.isEnumDeclaration(n)&&names.includes(n.name.text));if(enums.length!==names.length)throw Error('MissingSdkEnums');
const mod=new Module(path.join(out,'asset-enums.js'));mod._compile(ts.transpileModule('namespace asset {'+enums.map(n=>'export '+n.getText(sdkSource)).join('\n')+'}\nexport { asset };',{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,mod.id);
(async()=>{let passed=0,failed=0;for(const c of require('./mineru-transfer-host-cases.cjs')(out,mod.exports.asset)){try{await c.run();passed++;console.log('TRANSFER_INTERRUPTION PASS '+c.name);}catch(e){failed++;console.log('TRANSFER_INTERRUPTION FAIL '+c.name+' category='+e.constructor.name+' detail='+String(e.message).slice(0,160));}}console.log(`TRANSFER_INTERRUPTION_SUMMARY passed=${passed} failed=${failed} real_requests=0 private_files=0 native_sdk=not-run`);if(failed)process.exitCode=1;})().catch(e=>{console.log('TRANSFER_SETUP_FAIL '+e.constructor.name+' '+String(e.stack).slice(0,1000));process.exitCode=1;});
