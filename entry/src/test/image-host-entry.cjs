'use strict';
// Explicit allowlist: never imports the legacy full runner or private PDF suites.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const project = path.resolve(__dirname, '../../..');
const inputs = [
  ['1339a3e7d8673e0687a9d61581894e52c6b8e82d03dfd62d7c1acf3a55a6f66b.webp',231821,'818091b7959d295b01516f9439cc37277d786deaaf8a5830c1a3addd10464df3'],
  ['1772906562874.png',731350,'47ae1f0a095fc7efb27cb11ee53a6c63c0bf4834436881ea382cca9117289d74'],
  ['Image_1791726664793_321.jpg',129998,'f8157d2c4ea7ad363a771d961fe0795442ffc4c968b2b2f6fe146ab2d48a71a4'],
  ['IMG20260921190425.jpg',2744281,'a8feca7c5c35e48f47761994eca103f32a5c6975e702dcc4fc600bedef2d4e47'],
  ['IMG20260923092347.jpg',3024305,'96854814a6fc3660782656d109170128c0b4e111f7bfe593952d24f6b708001e'],
  ['IMG20260925171856.jpg',4858944,'eef3550d520f8f1fea1c7ca9b50c5cfb46ad4c45463b3d6e0c6fc3c245cfe4ab'],
  ['mmexport1783594230220.jpg',154048,'33ef2178c6d85699e6d80b98d54ff2f738d7f7b0605194b561e5fa4c18c3b808'],
  ['mmexport1790315212949.jpg',317735,'3b0b709f55cca08f040fb64b8a4668e5b260a7b60c120b65ef3600e5299dbe67'],
  ['mmexport1790674761209.png',1043975,'7c6315b723635913d8f5fece88f2a10602acf132cd3bb0115df883764b747955'],
  ['Screenshot_2026-09-18-17-43-39-94_9d26c6446fd7bb8e41d99b6262b17def.jpg',709381,'bf1c01efea7c81abf4ef3c549b8ef8d5f94d763ffa53c399b3d926abcc2b634c'],
  ['Screenshot_2026-09-28-14-47-54-67_9d26c6446fd7bb8e41d99b6262b17def.jpg',632853,'1383a92286b35e583cf2bea0792a343c9049fa7f78cd2534279a8aba3d3750a1']
];
function inventory() {
  let total = 0;
  for (const [name, size, hash] of inputs) {
    const file = path.join(project, '.cache/m3-input', name);
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) throw Error('M3 input type mismatch');
    const bytes = fs.readFileSync(file);
    if (bytes.length !== size || crypto.createHash('sha256').update(bytes).digest('hex') !== hash) throw Error('M3 input identity mismatch');
    total += bytes.length;
  }
  console.log(`M3_INPUT_IDENTITY count=${inputs.length} bytes=${total} matched=11 content_logged=0 requests=0`);
}
exports.inputManifest=inputs;
exports.feature='knowledge-image-happy-path-11-v1';
exports.changedEts=[
  'knowledge/domain/ImageKnowledgeModels','knowledge/domain/ImageKnowledgePorts','knowledge/domain/DocumentParseModels','knowledge/domain/DocumentParsePorts',
  'knowledge/application/DocumentParseService','knowledge/application/ImageOriginalImportService','knowledge/application/ImageIngestionService',
  'knowledge/infra/DocumentParseRepository','knowledge/infra/ImageStoreLayout','knowledge/infra/ImageKnowledgeRepository','knowledge/infra/ImageOriginalAdapter','knowledge/infra/ImageSourceSession','knowledge/infra/ImageResultReader','knowledge/infra/ImageProcessingAdapter','knowledge/infra/DocumentParseAssembly','knowledge/infra/MineruTransportAdapter','knowledge/infra/MineruCredentialStore','knowledge/infra/DocumentFileOperations',
  'knowledge/pipeline/ImageHeaderPolicy','knowledge/pipeline/DocumentParsePolicy','knowledge/pipeline/MineruProtocolCodec','knowledge/pipeline/ImageContentNormalizer','knowledge/pipeline/ImageSnapshotCodec','knowledge/pipeline/ParseFailurePolicy','knowledge/pipeline/BoundedDocumentJson',
  'knowledge/ui/ImageIngestionView','knowledge/ui/ImageSourceView','knowledge/ui/DocumentParseView','knowledge/ui/KnowledgePlatformDiagnostics','knowledge/ui/ImageIntegrationView','knowledge/platformtests/ImageIntegrationSuite','pages/Index'
].map(name=>'entry/src/main/ets/'+name+'.ets').concat(['entry/src/test/DocumentParseCases.ets']);
if(process.argv.includes('--image-happy-path')){
  for(const name of exports.changedEts.concat(['entry/src/test/image-host-entry.cjs','entry/src/test/image-store-host-cases.cjs','entry/src/test/image-pipeline-host-cases.cjs','entry/src/test/image-service-host-cases.cjs','entry/src/test/image-source-host-cases.cjs','entry/src/test/mineru-transfer-host-cases.cjs','entry/src/test/run-host-tests.cjs'])){
    console.log(`IMAGE_SOURCE_HASH file=${name} sha256=${crypto.createHash('sha256').update(fs.readFileSync(path.join(project,name))).digest('hex')}`);
  }
}
if (process.argv.includes('--resources')) {
  const fixture=require('./image-fixtures.cjs');
  const target=path.join(project,'entry/src/main/resources/rawfile');
  if(!fs.statSync(target).isDirectory())throw Error('Resource parent missing');
  fs.writeFileSync(path.join(target,'m3-synthetic.png'),fixture.png());
  fs.writeFileSync(path.join(target,'m3-synthetic.webp'),fixture.solidWebp());
  console.log('M3_RESOURCES generated=2 self_authored=1 private_inputs=0 requests=0');
} else if (process.argv.includes('--inventory')) inventory();
else require('./image-store-host-cases.cjs').run(project).catch(error=>{
  const code=typeof error?.code==='string'&&/^[A-Z_]{1,40}$/.test(error.code)?error.code:'none';
  const missing=code==='MODULE_NOT_FOUND'?String(error.message).match(/Cannot find module '([^']+)'/):null;
  const moduleName=missing&&/^[A-Za-z0-9_@.\/-]+$/.test(missing[1])?missing[1]:'not-reported';
  console.log(`M3_HOST_SETUP_FAILED category=${error instanceof Error?error.constructor.name:'Error'} code=${code} module=${moduleName}`);process.exitCode=1;
});
