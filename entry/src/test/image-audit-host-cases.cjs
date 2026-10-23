'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),cp=require('node:child_process');
exports.run=async function(project){
  const protectedFiles=['entry/src/main/ets/knowledge/domain/TextKnowledgeModels.ets','entry/src/main/ets/knowledge/application/TextKnowledgeService.ets','entry/src/main/ets/knowledge/infra/TextFileAdapter.ets','entry/src/main/ets/knowledge/infra/TextRdbRepository.ets','entry/src/main/ets/knowledge/pipeline/TextNormalizer.ets','entry/src/main/ets/knowledge/pipeline/PdfSnapshotCodec.ets','entry/src/main/ets/knowledge/pipeline/MineruPdfNormalizer.ets','entry/src/test/eval/text-m1-golden.json','oh-package.json5','entry/src/main/module.json5'];
  for(const file of protectedFiles){const old=cp.execFileSync('git',['show',`HEAD:${file}`],{cwd:project,maxBuffer:10*1024*1024});if(!fs.readFileSync(path.join(project,file)).equals(old)){console.log(`M3_AUDIT_BYTE_CHANGED ${file}`);throw Error('ProtectedBytesChanged');}}
  const permission=fs.readFileSync(path.join(project,'entry/src/main/module.json5'),'utf8').match(/ohos\.permission\.[A-Z_]+/g);assert.deepEqual(permission,['ohos.permission.INTERNET']);
  const changes=cp.execFileSync('git',['diff','--name-only','--','entry/src/main/ets','entry/src/test'],{cwd:project,encoding:'utf8'}).trim().split('\n').filter(f=>f.endsWith('.ets'));
  const added=cp.execFileSync('git',['ls-files','--others','--exclude-standard','--','entry/src/main/ets','entry/src/test'],{cwd:project,encoding:'utf8'}).trim().split('\n').filter(f=>f.endsWith('.ets'));
  const inputs=[...new Set([...changes,...added])].sort();
  // This is a source-rule audit, not a compiler/checker or build.
  for(const file of added){const source=fs.readFileSync(path.join(project,file),'utf8');if(/:\s*(?:any|unknown)\b|\bas\s+[A-Z]|JSON\.parse|Object\.assign|\.bind\(/.test(source)){console.log(`M3_AUDIT_SOURCE_REJECT ${file}`);throw Error('SourceRuleRejected');}}
  console.log(`M3_AUDIT protected_byte_identical=${protectedFiles.length} permissions=1 new_dependencies=0 checker=not-run requests=0`);
  for(const file of inputs)console.log(`M3_CHECKER_INPUT ${file}`);
  const hash=crypto.createHash('sha256');for(const file of inputs){hash.update(file+'\0');hash.update(fs.readFileSync(path.join(project,file)));}console.log(`M3_SOURCESET_SHA256 ${hash.digest('hex')} files=${inputs.length}`);
};
