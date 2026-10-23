'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const fixture = require('./unified-fixtures.cjs');
const hash = b => crypto.createHash('sha256').update(b).digest('hex');
exports.cases = h => {
  const M = h.load('domain/ParsedDocumentModels');
  const U = h.load('domain/UnifiedKnowledgeModels');
  const C = h.load('pipeline/ParsedDocumentCodec');
  const { KnowledgeStoreHost } = h.load('infra/KnowledgeStoreHost');
  const { KnowledgeStorageScope } = h.load('domain/KnowledgeStorageScope');
  const { TextChannel } = h.load('domain/TextKnowledgeModels');
  const { ParsedDocumentRepository } = h.load('infra/ParsedDocumentRepository');
  const { ParsedDocumentAssets } = h.load('infra/ParsedDocumentAssets');
  const { KnowledgeDerivedBudget } = h.load('infra/KnowledgeDerivedBudget');
  const { PARSED_STORE_DDL } = h.load('infra/ParsedDocumentStoreLayout');
  let serial=0;
  async function setup(options={}) {
    const id=(++serial).toString(16).padStart(16,'0'), scope=KnowledgeStorageScope.isolated(id);
    const context={ filesDir:'/synthetic-'+id+'/files',cacheDir:'/synthetic-'+id+'/cache',databaseDir:'/synthetic-'+id+'/db' };
    const host=KnowledgeStoreHost.forContext(context,scope); host.requireUnifiedProtection();
    const store=await host.acquireM1(async s=>{
      await s.executeSql('CREATE TABLE legacy_fixture (id TEXT PRIMARY KEY,wire TEXT NOT NULL,hash TEXT NOT NULL,space TEXT NOT NULL,free INTEGER NOT NULL,active TEXT NOT NULL)');
      await s.executeSql('INSERT INTO legacy_fixture VALUES(?,?,?,?,?,?)',['old',fixture.legacyWire,fixture.gold.legacyHash,'PDF-OLD-1',0,'old-active']);
      return TextChannel.Like;
    });
    const repo=new ParsedDocumentRepository(host,h.identity), budget=new KnowledgeDerivedBudget(context,scope);
    repo.attachPhysicalBudget(budget);
    if (!options.skipOpen) await repo.open();
    const assets=new ParsedDocumentAssets(context.filesDir,context.cacheDir,scope,repo,h.identity,'synthetic-session');
    repo.attachPublicationVerifier(assets);
    return { host,store,repo,assets,budget,scope,context };
  }
  async function document(s,id='doc-a',format=M.ParsedFormat.Text) {
    const d=new M.ParsedDocumentRecord(); d.id=id;d.namespace='Synthetic';d.legacyId=id;d.sourceHash=hash('synthetic-source');d.title=id;
    await s.repo.register(d);
    const p=new M.ParsedDocument();p.documentKey=id;p.generation='gen-'+id;p.source_hash=d.sourceHash;p.parser_signature='SYNTHETIC-ADAPTER-1';p.engine='synthetic';p.format=format;p.title=id;p.markdown='合成正文';
    p.coverage.selectedOutput.state=M.ParsedCoverageState.Complete;p.coverage.selectedOutput.expected=1;p.coverage.selectedOutput.recovered=1;
    return p;
  }
  async function image(s,d,id='image-a') {
    const bytes=new Uint8Array(fixture.png()),a=new M.ParsedImageAsset();a.id=id;a.relativePath='images/'+id;a.payloadHash=hash(bytes);a.bytes=bytes.length;a.mime='image/png';a.pixelWidth=1;a.pixelHeight=1;a.frames=1;
    const w=new M.ParsedAssetWrite();w.id=id;w.documentKey=d.documentKey;w.generation=d.generation;w.hash=a.payloadHash;w.bytes=a.bytes;w.relativePath=a.relativePath;w.role='image';
    return { a,w,bytes };
  }
  const ref=(holder,d,asset,owner='ParsedDocumentAssets',role='image')=>{
    const r=new M.ParsedAssetRef();r.holder=holder;r.documentKey=d.documentKey;r.generation=d.generation;r.assetId=asset;r.owner=owner;r.role=role;return r;
  };
  async function chunk(d,id='chunk-a') {
    const c=new M.ParsedTextChunk();c.id=id;c.documentKey=d.documentKey;c.generation=d.generation;c.text=d.markdown;c.inputHash=hash(c.text);c.end=c.text.length;return c;
  }
  async function scalar(s,sql,args=[]) { const rows=await s.store.querySql(sql,args);try{assert(rows.goToNextRow());return rows.getLong(0);}finally{rows.close();} }
  return [
    ['four_format_synthetic_products_validate_without_producer_claim',async()=>{
      const products=fixture.parsedOutputs(M);assert.deepEqual(products.map(d=>d.format),fixture.gold.formats);
      for(const d of products){C.parsedValidate(d);const b=await C.parsedEncodeSnapshot(d,h.identity,new M.ParsedCancellation());const m=await C.parsedDecodeManifest(b.manifestBytes,h.identity,new M.ParsedCancellation());const read=C.parsedDocumentFromManifest(m);for(let at=0;at<m.parts.length;at++)await C.parsedApplyPayload(read,m.parts[at],b.payloads[at],h.identity,new M.ParsedCancellation());C.parsedValidate(read);assert.equal(read.markdown,d.markdown);assert.equal(read.format,d.format);}
      const pdf=fixture.pdf();assert.equal(hash(Buffer.concat(pdf.parts)),fixture.gold.pdfPayloadHash);assert.notEqual(fixture.gold.pdfPayloadHash,fixture.gold.pdfContainerHash);assert(pdf.parts.length>2);assert.equal(pdf.payload.readUInt16BE(0),0xffd8);assert.equal(pdf.payload.readUInt16BE(pdf.payload.length-2),0xffd9);
    }],
    ['exact_layout_old_wire_reopen',async()=>{
      const s=await setup();assert(s.repo.ready());assert.equal(await scalar(s,"SELECT count(*) FROM sqlite_master WHERE name GLOB 'upd_*' AND type='table'"),20);
      const meta=await s.store.querySql('SELECT value FROM upd_meta WHERE id=?',['ddl_hash']);assert(meta.goToNextRow());assert.equal(meta.getString(0),hash(PARSED_STORE_DDL.join('\n')));meta.close();
      await s.repo.close();await s.repo.open();const old=await s.store.querySql('SELECT wire,hash,space,free,active FROM legacy_fixture');assert(old.goToNextRow());
      assert.equal(old.getString(0),fixture.legacyWire);assert.equal(hash(old.getString(0)),fixture.gold.legacyHash);assert.equal(old.getString(1),fixture.gold.legacyHash);assert.equal(old.getString(2),'PDF-OLD-1');assert.equal(old.getLong(3),0);assert.equal(old.getString(4),'old-active');old.close();
    }],
    ['actual_old_image_docx_exact_layouts_coexist_without_fifth_registry',async()=>{
      const s=await setup({skipOpen:true}),I=h.load('infra/ImageStoreLayout'),D=h.load('infra/DocxStoreLayout');
      for(const ddl of I.IMAGE_STORE_DDL.concat(D.DOCX_STORE_DDL))await s.store.executeSql(ddl);
      await s.store.executeSql('INSERT INTO kb_image_meta VALUES(?,?)',['layout',I.IMAGE_STORE_LAYOUT]);for(const [kind,reader]of [['Text','TEXT-SNAPSHOT-1'],['Pdf','PDF-NORMALIZED-1'],['Image','IMAGE-NORMALIZED-1'],['Docx','DOCX-NORMALIZED-1']])await s.store.executeSql('INSERT INTO kb_source_registry VALUES(?,?,?)',[kind,reader,'Enabled']);
      await s.store.executeSql('INSERT INTO kb_docx_meta VALUES(?,?)',['layout',D.DOCX_STORE_LAYOUT]);await s.store.executeSql('INSERT INTO kb_docx_meta VALUES(?,?)',['state','Committed']);
      await s.repo.open();const tx=await s.store.createTransaction();try{assert(await I.imageVerifyExisting(tx));assert(await D.docxVerifyExisting(tx));await tx.commit();}catch(error){await tx.rollback();throw error;}
      assert.equal(await scalar(s,'SELECT count(*) FROM kb_source_registry'),4);const rows=await s.store.querySql("SELECT name,sql FROM sqlite_master WHERE type='table' AND name GLOB 'kb_*'");const original=I.IMAGE_STORE_DDL.concat(D.DOCX_STORE_DDL);let count=0;while(rows.goToNextRow()){assert(original.includes(rows.getString(1)));count++;}rows.close();assert.equal(count,original.length);
    }],
    ['layout_transaction_rollback_and_retry',async()=>{
      const s=await setup({skipOpen:true});h.fault('CREATE TABLE upd_annotation');await assert.rejects(s.repo.open());h.fault('');
      assert.equal(await scalar(s,"SELECT count(*) FROM sqlite_master WHERE name GLOB 'upd_*'"),0);assert(s.host.m1Ready);await s.repo.open();assert(s.repo.ready());
    }],
    ['concurrent_open_single_lease_and_reopen',async()=>{
      const s=await setup({skipOpen:true});await Promise.all([s.repo.open(),s.repo.open(),s.repo.open()]);await s.repo.close();await s.host.release();assert.equal(s.host.m1Ready,false);
    }],
    ['unknown_upd_table_fail_closed_without_drop',async()=>{
      const s=await setup();await s.repo.close();await s.store.executeSql('CREATE TABLE upd_unrecognized (id TEXT)');await assert.rejects(s.repo.open(),/LayoutMismatch/);
      assert.equal(await scalar(s,"SELECT count(*) FROM sqlite_master WHERE name='upd_unrecognized'"),1);assert.equal(await scalar(s,'SELECT count(*) FROM legacy_fixture'),1);assert(s.host.m1Ready);
      await assert.rejects(s.host.assertUnifiedUnheld('DocumentParseService',['original-a']),/UnifiedProtectionUnavailable/);
    }],
    ['ddl_metadata_mismatch_does_not_repair',async()=>{
      const s=await setup();await s.repo.close();await s.store.executeSql("UPDATE upd_meta SET value='tampered' WHERE id='ddl_hash'");await assert.rejects(s.repo.open(),/LayoutUncommitted/);
      assert.equal(await scalar(s,'SELECT count(*) FROM upd_meta'),3);
    }],
    ['six_fields_block_formula_unknown_roundtrip',async()=>{
      const s=await setup(),d=await document(s);d.blocks=[];
      for (const [at,id] of fixture.gold.mixedOrder.entries()) {
        const b=new M.ParsedBlock();b.id=id;b.order=at;
        if(id==='image-only'){b.kind=M.ParsedKind.Image;b.limitation='MissingImage';}
        else if(id==='formula-only'){b.kind=M.ParsedKind.Formula;b.formula.latex='x^2';}
        else if(id==='unknown-only'){b.kind=M.ParsedKind.Unknown;b.limitation='UnsupportedObject';}
        else if(id==='table-cell'){b.kind=M.ParsedKind.Cell;b.row=0;b.column=0;b.text='cell';}
        else b.text='重复文字';
        d.blocks.push(b);
      }
      const bundle=await s.assets.saveSnapshot(d,new M.ParsedCancellation());assert.equal(bundle.payloads.length,0,'production uses streaming sink');
      const restored=await s.assets.readSnapshot(d.generation+'-manifest',new M.ParsedCancellation());
      assert.deepEqual(restored.blocks.map(b=>b.id),fixture.gold.mixedOrder);assert.equal(restored.blocks[2].formula.latex,'x^2');assert.equal(restored.source_hash,d.source_hash);assert.equal(restored.parser_signature,d.parser_signature);assert.equal(restored.engine,d.engine);assert.equal(restored.markdown,d.markdown);
      assert.match(restored.asset_dir,/knowledge_unified_v1_/);
    }],
    ['optional_blocks_and_local_directory_not_in_hash',async()=>{
      const s=await setup(),d=await document(s);d.asset_dir='/synthetic/local-one';const a=await C.parsedEncodeSnapshot(d,h.identity,new M.ParsedCancellation());
      d.asset_dir='/synthetic/local-two';const b=await C.parsedEncodeSnapshot(d,h.identity,new M.ParsedCancellation());assert.equal(a.manifest.contentHash,b.manifest.contentHash);assert(!Buffer.from(a.manifestBytes).toString().includes('asset_dir'));
      const read=await C.parsedDecodeManifest(a.manifestBytes,h.identity,new M.ParsedCancellation());assert.equal(read.hasBlocks,false);
    }],
    ['bounded_payload_stream_and_manifest_tamper_rejected',async()=>{
      const s=await setup(),d=await document(s);d.markdown='中😀'.repeat(150000);const bundle=await s.assets.saveSnapshot(d,new M.ParsedCancellation());assert(bundle.manifest.parts.length>1);assert(bundle.manifest.parts.every(p=>p.bytes<=M.ParsedLimits.payloadBytes));assert(bundle.manifestBytes.length<=M.ParsedLimits.manifestBytes);assert.equal((await s.assets.readSnapshot(d.generation+'-manifest',new M.ParsedCancellation())).markdown,d.markdown);
      const manifest=JSON.parse(Buffer.from(bundle.manifestBytes).toString());manifest.title='tampered';await assert.rejects(C.parsedDecodeManifest(new Uint8Array(Buffer.from(JSON.stringify(manifest))),h.identity,new M.ParsedCancellation()),/ManifestHashOrIdentity/);
      manifest.title=d.title;manifest.unrecognized='must-not-ignore';await assert.rejects(C.parsedDecodeManifest(new Uint8Array(Buffer.from(JSON.stringify(manifest))),h.identity,new M.ParsedCancellation()),/WireFields/);
    }],
    ['runtime_validation_duplicate_json_locator_and_links',async()=>{
      assert.throws(()=>C.parsedJson(Buffer.from('{"x":1,"x":2}'),new M.ParsedCancellation()));
      const s=await setup(),d=await document(s);const b=new M.ParsedBlock();b.id='block';b.kind=M.ParsedKind.Formula;d.blocks=[b];assert.throws(()=>C.parsedValidate(d),/FormulaPlaceholder/);
      b.formula.text='x';b.locator.precision=M.ParsedPrecision.Page;b.locator.pageIndex0=0;assert.throws(()=>C.parsedValidate(d),/LocatorEvidence/);
      b.locator.precision=M.ParsedPrecision.Unknown;b.locator.pageIndex0=-1;b.imageOccurrenceId='missing';assert.throws(()=>C.parsedValidate(d),/OccurrenceMissing/);
    }],
    ['full_png_file_readback_not_just_hash',async()=>{
      const s=await setup(),d=await document(s),i=await image(s,d);const ready=await s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation());assert.equal(ready.state,'Ready');
      const file=s.assets.assetDirectory()+'/images/'+i.a.id;assert(h.memoryFiles.get(file).equals(i.bytes));assert.equal(hash(await s.assets.read(i.a.id,new M.ParsedCancellation())),fixture.gold.pngHash);assert.equal(h.handles.size,0);
      assert.equal((await s.repo.assetWrite(i.a.id)).reserved,0);assert.equal(await scalar(s,'SELECT count(*) FROM upd_read_lease'),0);
    }],
    ['physical_readback_corruption_marks_missing',async()=>{
      const s=await setup(),d=await document(s),i=await image(s,d);await s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation());h.memoryFiles.set(s.assets.assetDirectory()+'/images/'+i.a.id,Buffer.from('changed'));
      await assert.rejects(s.assets.read(i.a.id,new M.ParsedCancellation()));assert.equal((await s.repo.asset(i.a.id)).state,'Missing');assert.equal(await scalar(s,'SELECT count(*) FROM upd_read_lease'),0);
    }],
    ['image_identity_and_animated_or_wrong_header_rejected',async()=>{
      const s=await setup(),d=await document(s),i=await image(s,d);i.a.pixelWidth=2;await assert.rejects(s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation()),/ImageHeaderIdentity/);
      assert.equal(await scalar(s,'SELECT count(*) FROM upd_asset'),0);i.a.pixelWidth=1;i.a.relativePath='images/../../escape';await assert.rejects(s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation()));
    }],
    ['rename_failure_recovers_from_durable_ledger',async()=>{
      const s=await setup(),d=await document(s),i=await image(s,d);h.fault('rename');await assert.rejects(s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation()));h.fault('');
      assert.equal((await s.repo.assetWrite(i.a.id)).phase,'Materialized');assert.equal((await s.repo.assetWrite(i.a.id)).reserved,0);
      await s.repo.close();await s.repo.open();await s.assets.reconcile(new M.ParsedCancellation());assert.equal((await s.repo.asset(i.a.id)).state,'Ready');assert.deepEqual(await s.assets.read(i.a.id,new M.ParsedCancellation()),i.bytes);
    }],
    ['rename_before_db_ready_recovers_without_rewrite',async()=>{
      const s=await setup(),d=await document(s),i=await image(s,d);h.fault("UPDATE upd_asset_write SET phase='Ready'");await assert.rejects(s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation()));h.fault('');
      const final=s.assets.assetDirectory()+'/images/'+i.a.id;assert(h.memoryFiles.has(final));assert.notEqual((await s.repo.asset(i.a.id)).state,'Ready');await s.assets.reconcile(new M.ParsedCancellation());assert.equal((await s.repo.asset(i.a.id)).state,'Ready');assert(h.memoryFiles.get(final).equals(i.bytes));
    }],
    ['write_and_reserve_faults_preserve_old_records',async()=>{
      const s=await setup(),d=await document(s),i=await image(s,d);h.fault('INSERT INTO upd_asset_write');await assert.rejects(s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation()));h.fault('');assert.equal(await scalar(s,'SELECT count(*) FROM upd_asset'),0);
      h.fault('write');await assert.rejects(s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation()));h.fault('');assert.equal((await s.repo.asset(i.a.id)).state,'Reserved');assert((await s.repo.assetWrite(i.a.id)).reserved>0);await s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation());assert.equal((await s.repo.asset(i.a.id)).state,'Ready');
    }],
    ['fsync_failure_not_ready_until_recovery_fsync',async()=>{
      const s=await setup(),d=await document(s),i=await image(s,d);h.fault('fsync');await assert.rejects(s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation()));assert.notEqual((await s.repo.asset(i.a.id)).state,'Ready');h.fault('');await s.assets.reconcile(new M.ParsedCancellation());assert.equal((await s.repo.asset(i.a.id)).state,'Ready');
    }],
    ['shared_budget_counts_roots_db_temp_and_unmaterialized_once',async()=>{
      const s=await setup(),d=await document(s),i=await image(s,d);const before=(await s.budget.usage()).total();await s.repo.reserve(i.w,Object.assign(i.a,{state:M.ParsedAssetState.Reserved}));
      const reserved=await s.budget.usage();assert.equal(reserved.pendingReserved,4096);assert.equal(reserved.total()-before,4096);
      const dir=s.assets.assetDirectory();for(const p of [dir,dir+'/images'])h.memoryFiles.set(p,null);h.memoryFiles.set(dir+'/images/'+i.a.id+'-pending',Buffer.from(i.bytes));
      assert.equal((await s.budget.usage()).pendingReserved,0);
      const dbRoot=s.context.databaseDir+'/rdb';h.memoryFiles.set(dbRoot,null);for(const n of [s.scope.databaseName,s.scope.vectorDatabaseName,s.scope.databaseName+'-wal','shuvi_r2_parse_'+s.scope.key+'.db'])h.memoryFiles.set(dbRoot+'/'+n,Buffer.alloc(16));
      const usage=await s.budget.usage();assert.equal(usage.vectorPhysical,4096);assert.equal(usage.sharedNonReclaimable,12288);
      const other=await image(s,d,'image-budget');s.repo.attachPhysicalBudget({totalBytes:async()=>M.ParsedLimits.sharedBytes-4096});await assert.rejects(s.assets.save(other.a,other.w,other.bytes,new M.ParsedCancellation()),/SharedPhysicalBudget/);assert.equal(await s.repo.asset('image-budget'),undefined);
    }],
    ['legacy_owner_refs_protect_original_zip_and_all_owners',async()=>{
      const s=await setup(),d=await document(s);const owners=['TextFileAdapter','DocumentParseService','PdfAssetAdapter','ImageSnapshotAssets','DocxSnapshotAssets'];
      for(const owner of owners){await s.repo.addRef(ref('hold-'+owner,d,'original-'+owner,owner,'original'));await assert.rejects(s.host.withUnifiedCleanup(owner,['original-'+owner],async()=>{throw Error('MustNotUnlink');}),/UnifiedAssetHeld/);}
      await s.repo.addRef(ref('hold-zip',d,'result-zip','DocumentParseService','result'));await assert.rejects(s.host.assertUnifiedUnheld('DocumentParseService',['original-x','result-zip']),/UnifiedAssetHeld/);
      assert.deepEqual((await s.repo.heldLegacyAssets('DocumentParseService')).sort(),['original-DocumentParseService','result-zip'].sort());await s.repo.releaseRefs('hold-zip');await s.host.assertUnifiedUnheld('DocumentParseService',['result-zip']);
    }],
    ['cleanup_serializes_against_ref_admission',async()=>{
      const s=await setup(),d=await document(s);let unblock;const blocked=new Promise(r=>{unblock=r;});let entered=false,refDone=false;
      const cleaning=s.host.withUnifiedCleanup('DocumentParseService',['original-race'],async()=>{entered=true;await blocked;});await new Promise(r=>setImmediate(r));assert(entered);
      const adding=s.repo.addRef(ref('hold-race',d,'original-race','DocumentParseService'));const rejected=assert.rejects(adding,/AssetCleanupClaimed/);await new Promise(r=>setImmediate(r));assert(!refDone);unblock();await cleaning;await rejected;assert.equal(await scalar(s,"SELECT count(*) FROM upd_asset_ref WHERE asset='original-race'"),0);
    }],
    ['multiparent_refs_and_lease_block_final_cleanup',async()=>{
      const s=await setup(),a=await document(s,'parent-a'),b=await document(s,'parent-b'),i=await image(s,a);await s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation());
      await s.repo.addRef(ref('parent-a',a,i.a.id));await s.repo.addRef(ref('parent-b',b,i.a.id));await s.repo.releaseRefs('write-'+i.a.id);await s.repo.releaseRefs('parent-a');assert.equal(await s.assets.cleanup(i.a.id),false);
      const lease=new M.ParsedReadLease();lease.id='read-one';lease.assetId=i.a.id;lease.owner='ParsedDocumentAssets';lease.session='synthetic';lease.holder='source-view';await s.repo.acquireLease(lease);await s.repo.releaseRefs('parent-b');assert.equal(await s.assets.cleanup(i.a.id),false);
      await s.repo.releaseLease(lease.id);assert.equal(await s.assets.cleanup(i.a.id),true);assert.equal((await s.repo.asset(i.a.id)).state,'Removed');assert(!h.memoryFiles.has(s.assets.assetDirectory()+'/images/'+i.a.id));
    }],
    ['cleanup_failure_durable_retry_and_unknown_file_retained',async()=>{
      const s=await setup(),d=await document(s),i=await image(s,d);await s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation());await s.repo.releaseRefs('write-'+i.a.id);h.fault('unlink');assert.equal(await s.assets.cleanup(i.a.id),false);h.fault('');assert.notEqual((await s.repo.asset(i.a.id)).state,'Removed');assert.equal(await s.assets.cleanup(i.a.id),true);
      const path=s.assets.assetDirectory()+'/images/user-unknown';h.memoryFiles.set(path,Buffer.from('unregistered'));await s.assets.reconcile(new M.ParsedCancellation());assert(h.memoryFiles.has(path));
    }],
    ['publish_cas_readback_and_old_generation_preserved',async()=>{
      const s=await setup(),d=await document(s);const bundle=await s.assets.saveSnapshot(d,new M.ParsedCancellation()),c=await chunk(d);
      assert.equal(await s.repo.publish(d,[c],d.generation+'-manifest',bundle.manifest.contentHash,1,''),false);assert.equal((await s.repo.get(d.documentKey)).activeGeneration,'');
      assert.equal(await s.repo.publish(d,[c],d.generation+'-manifest',bundle.manifest.contentHash,0,''),true);assert.equal((await s.repo.chunks(d.documentKey))[0].text,d.markdown);
      const old=d.generation;d.generation='gen-next';d.markdown='新版';const next=await s.assets.saveSnapshot(d,new M.ParsedCancellation()),nc=await chunk(d,'chunk-next');h.fault('UPDATE upd_document SET active=');await assert.rejects(s.repo.publish(d,[nc],d.generation+'-manifest',next.manifest.contentHash,0,old));h.fault('');assert.equal((await s.repo.get(d.documentKey)).activeGeneration,old);assert.equal(await scalar(s,'SELECT count(*) FROM upd_generation WHERE id=?',['gen-next']),0);
      assert.equal(await s.repo.publish(d,[nc],d.generation+'-manifest',next.manifest.contentHash,0,old),true);assert.equal(await scalar(s,"SELECT count(*) FROM upd_generation WHERE state='Retained'"),1);
    }],
    ['namespace_identity_not_source_hash_dedup',async()=>{
      const s=await setup();const a=await document(s,'doc-one'),b=await document(s,'doc-two');assert.equal(a.source_hash,b.source_hash);assert.equal((await s.repo.list()).length,2);
      const l=new M.ParsedLegacyLink();l.namespace='Image';l.legacyId='old-id';l.legacyGeneration='old-gen';l.legacyWire='Image2';l.legacyHash=fixture.gold.legacyHash;l.documentKey=a.documentKey;l.generation=a.generation;l.oldActive='old-active';await s.repo.saveLegacyLink(l);await s.repo.saveLegacyLink(l);l.legacyWire='Image3';await assert.rejects(s.repo.saveLegacyLink(l),/LegacyLinkConflict/);
    }],
    ['publication_manifest_not_arbitrary_hash_and_write_refs_transferred',async()=>{
      const s=await setup(),d=await document(s);const b=await s.assets.saveSnapshot(d,new M.ParsedCancellation());const c=await chunk(d);
      await assert.rejects(s.repo.publish(d,[c],d.generation+'-manifest',hash('unrelated'),0,''),/PublicationManifestBinding/);
      d.markdown='different supplied text';await assert.rejects(s.repo.publish(d,[await chunk(d)],d.generation+'-manifest',b.manifest.contentHash,0,''),/PublicationPayloadBinding/);d.markdown='合成正文';
      await s.repo.publish(d,[c],d.generation+'-manifest',b.manifest.contentHash,0,'');assert.equal(await scalar(s,"SELECT count(*) FROM upd_asset_ref WHERE role='write'"),0);assert.equal(await scalar(s,"SELECT count(*) FROM upd_asset_ref WHERE role='snapshot'"),b.manifest.parts.length+1);
    }],
    ['missing_restore_reserves_again_before_rewrite',async()=>{
      const s=await setup(),d=await document(s),i=await image(s,d);await s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation());h.memoryFiles.delete(s.assets.assetDirectory()+'/images/'+i.a.id);await s.assets.reconcile(new M.ParsedCancellation());assert.equal((await s.repo.asset(i.a.id)).state,'Missing');assert.equal((await s.repo.assetWrite(i.a.id)).reserved,0);
      s.repo.attachPhysicalBudget({totalBytes:async()=>M.ParsedLimits.sharedBytes});await assert.rejects(s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation()),/SharedPhysicalBudget/);assert(!h.memoryFiles.has(s.assets.assetDirectory()+'/images/'+i.a.id+'-pending'));s.repo.attachPhysicalBudget(s.budget);await s.assets.save(i.a,i.w,i.bytes,new M.ParsedCancellation());assert.equal((await s.repo.asset(i.a.id)).state,'Ready');
    }],
    ['real_old_pdf_header_codec_retains_wire_bytes',async()=>{
      const P=h.load('domain/PdfKnowledgeModels'), codec=h.load('pipeline/PdfSnapshotCodec');const snap=new P.PdfNormalizedDocument();snap.id='old-pdf';snap.documentId='old-doc';snap.generation='old-generation';snap.hash=hash('old-snapshot');snap.binding.originalHash=hash('old-original');snap.binding.originalVersion=1;snap.binding.originalBytes=100;
      const before=JSON.stringify(snap),digest=hash(before);const decoded=codec.pdfDecodeSnapshotHeader(new Uint8Array(Buffer.from(before)),new P.KnowledgeCancellation());assert.equal(JSON.stringify(decoded),before);assert.equal(hash(JSON.stringify(decoded)),digest);assert.equal(decoded.profile,'MINERU-HOSTED-PDF-3.4.4-OBSERVED-1');console.log(`UPD_OLD_WIRE wire=PDF-NORMALIZED-1 before=${digest} after=${hash(JSON.stringify(decoded))}`);
    }],
    ['real_old_text_snapshot_codec_retains_wire_bytes',async()=>{
      const T=h.load('domain/TextKnowledgeModels'),codec=h.load('pipeline/StructuredChunker');const doc=new T.TextDocument();doc.id='old-text';doc.title='synthetic.md';doc.format=T.TextFormat.Markdown;doc.original.assetId='original-text';doc.original.hash=hash('text-original');doc.original.bytes=24;
      const output=codec.processText(new Uint8Array(Buffer.from('# 合成标题\n\n合成正文')),doc,'old-generation');const before=codec.encodeSnapshot(output.snapshot),digest=hash(before);const read=codec.decodeSnapshot(before);assert.equal(codec.encodeSnapshot(read),before);console.log(`UPD_OLD_WIRE wire=TEXT-SNAPSHOT-1 before=${digest} after=${hash(codec.encodeSnapshot(read))}`);
    }],
    ['real_old_image_v1_v2_codecs_do_not_add_fields_to_v1',async()=>{
      const I=h.load('domain/ImageKnowledgeModels'), P=h.load('domain/PdfKnowledgeModels'), codec=h.load('pipeline/ImageSnapshotCodec');
      for(const wire of ['IMAGE-NORMALIZED-1','IMAGE-NORMALIZED-2']){
        const snap=new I.ImageSnapshot();snap.wire=wire;snap.profile='IMAGE-CONTROLLED-TEXT-1';snap.producer='ShuviControlledFixture-1';snap.documentId='old-image';snap.generation='old-generation';snap.resultHash=hash('result');
        const o=snap.original;o.documentId=snap.documentId;o.assetId='original-old';o.sourceId='source-old';o.title='synthetic.png';o.suffix='.png';o.hash=fixture.gold.pngHash;o.bytes=fixture.png().length;o.version=1;o.sdkVerified=true;o.frames=1;o.header.encoding=I.ImageEncoding.Png;o.header.mime='image/png';o.header.width=1;o.header.height=1;o.header.orientation=1;o.header.staticContainer=true;snap.coverage.fullDocument=true;snap.coverage.empty=1;
        await codec.imageSealSnapshot(snap,h.identity,new P.KnowledgeCancellation());const before=codec.imageSnapshotWire(snap),digest=hash(before);const decoded=codec.imageDecodeSnapshot(new Uint8Array(Buffer.from(before)),new P.KnowledgeCancellation());await codec.imageVerifySnapshot(decoded,h.identity,new P.KnowledgeCancellation());assert.equal(codec.imageSnapshotWire(decoded),before);assert.equal(hash(codec.imageSnapshotWire(decoded)),digest);
        if(wire.endsWith('-1')){assert(!before.includes('basicQualified'));assert(!before.includes('projection'));}
        console.log(`UPD_OLD_WIRE wire=${wire} before=${digest} after=${hash(codec.imageSnapshotWire(decoded))}`);
      }
    }],
    ['real_old_docx_codec_preserves_sealed_identity',async()=>{
      const D=h.load('domain/DocxKnowledgeModels'),P=h.load('domain/PdfKnowledgeModels'),codec=h.load('pipeline/DocxSnapshotCodec');const snap=new D.DocxSnapshot();snap.documentId='old-docx';snap.generation='old-generation';snap.original.documentId=snap.documentId;snap.original.sourceId='source-old';snap.original.assetId='original-old';snap.original.hash=hash('original');snap.original.version=1;snap.original.bytes=100;snap.original.title='synthetic.docx';snap.original.mainPart='word/document.xml';snap.result.taskId='task-old';snap.result.dataId='data-old';snap.result.assetId='result-old';snap.result.hash=hash('result');snap.result.bytes=100;snap.result.originalHash=snap.original.hash;snap.result.originalVersion=1;
      await codec.docxSealSnapshot(snap,h.identity,new P.KnowledgeCancellation());const before=JSON.stringify(snap),digest=hash(before);const decoded=codec.docxDecodeSnapshot(new Uint8Array(Buffer.from(before)),new P.KnowledgeCancellation());await codec.docxVerifySnapshot(decoded,h.identity,new P.KnowledgeCancellation());assert.equal(JSON.stringify(decoded),before);assert.equal(hash(JSON.stringify(decoded)),digest);console.log(`UPD_OLD_WIRE wire=DOCX-NORMALIZED-1 before=${digest} after=${hash(JSON.stringify(decoded))}`);
    }],
    ['new_settings_default_disabled_never_legacy_free_permission',async()=>{
      const s=await setup();for(const purpose of ['Vision','Embedding']){const value=await s.repo.settings(purpose);assert.equal(value.enabled,false);assert.equal(value.costAcknowledged,false);assert.equal(value.automatic,false);}
      const settings=new U.UnifiedProcessingSettings();settings.purpose='Vision';settings.revision=1;settings.enabled=true;await assert.rejects(s.repo.saveSettings(settings),/SettingsCostConsent/);
      settings.automatic=true;settings.recipient='DeepSeek';settings.model='deepseek-flash';settings.costAcknowledged=true;settings.costRevision=1;settings.policy='VISION-TEST';await s.repo.saveSettings(settings);assert.equal((await s.repo.settings('Vision')).revision,1);settings.recipient='Other';await assert.rejects(s.repo.saveSettings(settings),/SettingsRevisionConflict/);
    }],
    ['persistent_origin_unknown_and_attempt_ledgers',async()=>{
      const s=await setup(),d=await document(s);const batch=new U.UnifiedProcessingBatch();batch.id='local-batch';batch.inputIds=['one','two'];batch.inputSetHash=hash('one-two');await s.repo.saveBatch(batch);batch.inputIds.push('three');await assert.rejects(s.repo.saveBatch(batch),/FrozenBatchConflict/);
      const job=new U.UnifiedProcessingJob();job.id='local-job';job.dedupKey='local-key';job.documentKey=d.documentKey;job.batchId='local-batch';job.expected=2;await s.repo.saveJob(job);assert.equal((await s.repo.jobs())[0].origin,'LocalMigration');job.id='different-job';await assert.rejects(s.repo.saveJob(job),/JobDedupIdentityConflict/);job.id='local-job';job.origin=U.UnifiedJobOrigin.Import;await assert.rejects(s.repo.saveJob(job),/JobIdentityOrUnknownConflict/);job.origin=U.UnifiedJobOrigin.LocalMigration;job.state=U.UnifiedJobState.Unknown;await s.repo.saveJob(job);job.state=U.UnifiedJobState.Pending;await assert.rejects(s.repo.saveJob(job),/JobIdentityOrUnknownConflict/);
      const attempt=new U.UnifiedProcessingAttempt();attempt.id='attempt';attempt.jobId=job.id;attempt.inputHash=hash('input');attempt.launched=true;attempt.outcome='Unknown';await s.repo.saveAttempt(attempt);attempt.launched=false;await assert.rejects(s.repo.saveAttempt(attempt),/AttemptIdentityConflict/);
      assert.equal(h.requests(),0);
    }],
    ['annotation_transaction_tag_index_and_proxy_only_invalidation',async()=>{
      const s=await setup();for(const domain of ['upd-body','upd-image']){const binding=new U.UnifiedIndexBinding();binding.ownerNamespace=domain;binding.ownerId='lineage';binding.version='old-effective';binding.expected=1;binding.inputSetHash=hash('inputs');await s.repo.saveBinding(binding);}
      const a=new U.UnifiedEffectiveAnnotation();a.id='effective-new';a.lineage='lineage';a.revision=2;a.imageHash=fixture.gold.pngHash;a.textHash=hash('text');a.description='描述';a.tags=['图形','无字'];h.fault('INSERT INTO upd_tag');await assert.rejects(s.repo.saveAnnotation(a));h.fault('');assert.equal(await scalar(s,'SELECT count(*) FROM upd_annotation'),0);await s.repo.saveAnnotation(a);assert.equal(await scalar(s,'SELECT count(*) FROM upd_tag'),2);
      const r=await s.store.querySql('SELECT namespace,state FROM upd_index_binding ORDER BY namespace');assert(r.goToNextRow());assert.equal(r.getString(0),'upd-body');assert.equal(r.getString(1),'Pending');assert(r.goToNextRow());assert.equal(r.getString(1),'Invalid');r.close();
    }],
    ['history_append_event_idempotence_not_legacy_same_id_drop',async()=>{
      const s=await setup();for(let i=1;i<=3;i++){const r=new U.UnifiedHistoryRevision();r.recordId='record';r.eventId='page-'+i;r.revision=i;r.snapshotAsset='snapshot-'+i;r.snapshotHash=hash('snapshot-'+i);await s.repo.appendHistory(r);await s.repo.appendHistory(r);}
      assert.equal(await scalar(s,'SELECT count(*) FROM upd_history'),3);const r=new U.UnifiedHistoryRevision();r.recordId='record';r.eventId='page-1';r.revision=1;r.snapshotAsset='other';r.snapshotHash=hash('other');await assert.rejects(s.repo.appendHistory(r),/HistoryEventConflict/);assert.equal(await scalar(s,'SELECT count(*) FROM legacy_fixture'),1);
    }],
    ['startup_before_legacy_cleanup_and_failure_preserves_base',async()=>{
      const {TextKnowledgeService}=h.load('application/TextKnowledgeService');const events=[];
      const repository={open:async()=>events.push('base-open'),reconcile:async()=>events.push('legacy-reconcile'),cleanups:async()=>[],assetIds:async()=>[],list:async()=>[],jobs:async()=>[],channel:()=>TextChannel.Like};
      const service=new TextKnowledgeService({}, {reconcile:async()=>events.push('files-reconcile')}, {},repository);
      service.attachBeforeCleanup(async()=>{events.push('upd-protection');});await service.initialize();assert.deepEqual(events,['base-open','upd-protection','legacy-reconcile','files-reconcile']);
      events.length=0;await service.initialize(true);events.push('legacy-extension-open');await service.recoverLocal();assert.deepEqual(events,['base-open','upd-protection','legacy-extension-open','legacy-reconcile','files-reconcile']);
      events.length=0;service.attachBeforeCleanup(async()=>{events.push('upd-protection-failed');throw Error('LayoutFailed');});await service.initialize();assert.deepEqual(events,['base-open','upd-protection-failed']);assert(service.state.message.includes('引用保护'));
    }],
    ['foundation_wiring_backup_and_zero_egress_scope',async()=>{
      const root=path.resolve(__dirname,'../../..'),ets=path.join(root,'entry/src/main/ets/knowledge');
      const assembly=fs.readFileSync(path.join(ets,'infra/KnowledgeAssembly.ets'),'utf8');assert(assembly.includes('requireUnifiedProtection()'));assert(assembly.includes('attachBeforeCleanup'));assert(assembly.includes('unified.attachPhysicalBudget'));assert(!assembly.includes('sourceRegistry.register(this.unified'));
      for(const name of ['TextFileAdapter','DocumentFileAdapter'])assert(fs.readFileSync(path.join(ets,'infra/'+name+'.ets'),'utf8').includes('withUnifiedCleanup'));
      for(const name of ['PdfAssetAdapter','ImageSnapshotAssets','DocxSnapshotAssets'])assert(fs.readFileSync(path.join(ets,'infra/'+name+'.ets'),'utf8').includes('cleanupGuard'));
      const backup=JSON.parse(fs.readFileSync(path.join(root,'entry/src/main/resources/base/profile/backup_config.json'),'utf8'));for(const type of ['files','cache'])assert(backup.excludes.includes('/data/storage/el2/base/'+type+'/knowledge_unified_v1/'));assert(!backup.excludes.some(x=>x.includes('shuvi_kb_user_v1')));
      assert.equal(h.requests(),0);
    }]
  ];
};
