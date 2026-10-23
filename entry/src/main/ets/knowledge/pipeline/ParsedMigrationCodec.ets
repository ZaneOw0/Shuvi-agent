import { ParsedMigrationInput, ParsedMigrationBatch, ParsedMigrationReceipt, ParsedUpgradeBatch, ParsedUpgradeTarget } from '../domain/ParsedMigrationModels';
import { ParsedSourceAsset, ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { ParsedCancellation, ParsedFailure, parsedHash, parsedId } from '../domain/ParsedDocumentModels';
import { parsedJson, parsedUtf8 } from './ParsedDocumentCodec';
import { PdfJsonNode } from './BoundedDocumentJson';

function ms(n: PdfJsonNode,key: string): string { return n.required(key).string(); }
function mn(n: PdfJsonNode,key: string): number { return n.required(key).integer(); }
function mb(n: PdfJsonNode,key: string): boolean { const v=n.required(key); if (v.kind!=='true' && v.kind!=='false') { throw new ParsedFailure('MigrationBoolean','codec'); } return v.kind==='true'; }
export async function migrationInputHash(input: ParsedMigrationInput, identity: ParsedIdentityPort): Promise<string> {
  const old: string=input.inputHash; input.inputHash=''; try { return await identity.hash(parsedUtf8(JSON.stringify(input))); } finally { input.inputHash=old; }
}
export async function migrationSetHash(inputs: ParsedMigrationInput[], identity: ParsedIdentityPort): Promise<string> { return identity.hash(parsedUtf8(inputs.map((i: ParsedMigrationInput): string=>i.key+'|'+i.inputHash).join('\n'))); }
function migrationInput(n: PdfJsonNode): ParsedMigrationInput {
  const i: ParsedMigrationInput=new ParsedMigrationInput(); i.key=ms(n,'key'); i.namespace=ms(n,'namespace'); i.legacyId=ms(n,'legacyId'); i.active=ms(n,'active'); i.epoch=mn(n,'epoch'); i.sourceHash=ms(n,'sourceHash'); i.sourceVersion=mn(n,'sourceVersion'); i.title=ms(n,'title'); i.archived=mb(n,'archived'); i.snapshotAsset=ms(n,'snapshotAsset'); i.snapshotHash=ms(n,'snapshotHash'); i.snapshotFamily=ms(n,'snapshotFamily'); i.originalAsset=ms(n,'originalAsset'); i.originalBytes=mn(n,'originalBytes'); i.resultAsset=ms(n,'resultAsset'); i.resultHash=ms(n,'resultHash'); i.resultBytes=mn(n,'resultBytes'); i.inputHash=ms(n,'inputHash');
  for (const raw of n.required('sources').array()) { const s: ParsedSourceAsset=new ParsedSourceAsset(); s.id=ms(raw,'id'); s.owner=ms(raw,'owner'); s.role=ms(raw,'role'); if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,160}$/.test(s.id) || s.owner.length===0) { throw new ParsedFailure('MigrationAssetIdentity','codec'); } i.sources.push(s); }
  if (['Text','Pdf','Image','Docx'].indexOf(i.namespace)<0 || i.key!==i.namespace+':'+i.legacyId || !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,160}$/.test(i.legacyId) || !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,160}$/.test(i.active) || !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,160}$/.test(i.snapshotAsset) || i.epoch<0 || i.sourceVersion<1 || i.originalBytes<0 || i.originalBytes>20971520 || i.resultBytes<0 || i.resultBytes>31457280 || !parsedHash(i.sourceHash) || !parsedHash(i.snapshotHash) || !parsedHash(i.inputHash) || i.sources.length>20000) { throw new ParsedFailure('MigrationInputIdentity','codec'); } return i;
}
export async function migrationDecodeBatch(raw: string, identity: ParsedIdentityPort): Promise<ParsedMigrationBatch> {
  const n=parsedJson(parsedUtf8(raw),new ParsedCancellation()); const b: ParsedMigrationBatch=new ParsedMigrationBatch(); b.wire=ms(n,'wire'); b.id=ms(n,'id'); b.inputSetHash=ms(n,'inputSetHash');
  for (const value of n.required('inputs').array()) { if (b.inputs.length>=10000) { throw new ParsedFailure('MigrationBatchBudget','codec'); } b.inputs.push(migrationInput(value)); }
  if (b.wire!=='UNIFIED-LOCAL-MIGRATION-1' || !parsedId(b.id) || new Set<string>(b.inputs.map((i: ParsedMigrationInput): string=>i.key)).size!==b.inputs.length) { throw new ParsedFailure('MigrationBatchIdentity','codec'); }
  for (const i of b.inputs) { if (await migrationInputHash(i,identity)!==i.inputHash) { throw new ParsedFailure('MigrationInputHash','codec'); } }
  if (await migrationSetHash(b.inputs,identity)!==b.inputSetHash) { throw new ParsedFailure('MigrationSetHash','codec'); } return b;
}
export function migrationDecodeReceipt(raw: string): ParsedMigrationReceipt {
  const n=parsedJson(parsedUtf8(raw),new ParsedCancellation()); const r: ParsedMigrationReceipt=new ParsedMigrationReceipt(); r.batchId=ms(n,'batchId'); r.inputKey=ms(n,'inputKey'); r.inputHash=ms(n,'inputHash'); r.documentKey=ms(n,'documentKey'); r.generation=ms(n,'generation'); r.phase=ms(n,'phase'); r.state=ms(n,'state'); r.failure=ms(n,'failure'); r.legacyWire=ms(n,'legacyWire'); r.legacyHash=ms(n,'legacyHash'); r.wireByteHash=ms(n,'wireByteHash'); r.contentHash=ms(n,'contentHash'); r.expected=mn(n,'expected'); r.warnings=n.required('warnings').array().map((v: PdfJsonNode): string=>v.string()); return r;
}
export function upgradeDecodeBatch(raw: string): ParsedUpgradeBatch {
  const n=parsedJson(parsedUtf8(raw),new ParsedCancellation()); const b: ParsedUpgradeBatch=new ParsedUpgradeBatch(); b.wire=ms(n,'wire'); b.id=ms(n,'id'); b.inputSetHash=ms(n,'inputSetHash'); b.visionRevision=mn(n,'visionRevision'); b.visionCostRevision=mn(n,'visionCostRevision'); b.embeddingRevision=mn(n,'embeddingRevision'); b.embeddingCostRevision=mn(n,'embeddingCostRevision'); b.approved=mb(n,'approved'); b.paused=mb(n,'paused');
  for (const raw of n.required('targets').array()) { const t: ParsedUpgradeTarget=new ParsedUpgradeTarget(); t.documentKey=ms(raw,'documentKey'); t.generation=ms(raw,'generation'); t.epoch=mn(raw,'epoch'); t.manifestHash=ms(raw,'manifestHash'); t.bodyInputHash=ms(raw,'bodyInputHash'); t.images=raw.required('images').array().map((v: PdfJsonNode): string=>v.string()); t.annotations=raw.required('annotations').array().map((v: PdfJsonNode): string=>v.string()); b.targets.push(t); }
  if (b.wire!=='UNIFIED-EXPLICIT-UPGRADE-1' || !parsedId(b.id) || !parsedHash(b.inputSetHash) || b.targets.length===0 || b.targets.length>10000 || new Set<string>(b.targets.map((t: ParsedUpgradeTarget): string=>t.documentKey)).size!==b.targets.length || b.visionRevision<0 || b.visionCostRevision<0 || b.embeddingRevision<0 || b.embeddingCostRevision<0) { throw new ParsedFailure('UpgradeBatchIdentity','codec'); }
  for (const target of b.targets) { if (!parsedId(target.documentKey) || !parsedId(target.generation) || target.epoch<0 || !parsedHash(target.manifestHash) || !parsedHash(target.bodyInputHash) || target.images.length>1000 || target.annotations.length!==target.images.length || new Set<string>(target.images).size!==target.images.length) { throw new ParsedFailure('UpgradeTargetIdentity','codec'); } } return b;
}
