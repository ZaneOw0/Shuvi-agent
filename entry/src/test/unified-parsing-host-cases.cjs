'use strict';
// US1 tests are registered before production edits. Synthetic ports only.
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const fs=require('node:fs'),path=require('node:path');
const fixture=require('./unified-fixtures.cjs');
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const {zip}=require('./docx-fixtures.cjs');
const W='http://schemas.openxmlformats.org/wordprocessingml/2006/main',R='http://schemas.openxmlformats.org/officeDocument/2006/relationships';
function sourceParts(){return [
  ['[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'],
  ['_rels/.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="root" Type="'+R+'/officeDocument" Target="word/document.xml"/></Relationships>'],
  ['word/document.xml','<w:document xmlns:w="'+W+'" xmlns:r="'+R+'" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"><w:body><w:p><w:r><w:t>原生不同</w:t><w:drawing><a:blip r:embed="img"/></w:drawing><w:t>尾文</w:t></w:r><m:oMath><m:r><m:t>x</m:t></m:r></m:oMath><w:r><w:object/></w:r></w:p><w:p><w:r><w:drawing><a:blip r:embed="img"/></w:drawing></w:r></w:p><w:p><m:oMath><m:r><m:t>y</m:t></m:r></m:oMath></w:p></w:body></w:document>'],
  ['word/_rels/document.xml.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="img" Type="'+R+'/image" Target="media/source.png"/><Relationship Id="external" Type="'+R+'/image" Target="https://invalid.example/no-fetch" TargetMode="External"/></Relationships>'],
  ['word/media/source.png',fixture.png()]
];}
exports.cases=h=>{
  const M=h.load('domain/ParsedDocumentModels');
  const C=h.load('pipeline/ParsedDocumentCodec');
  const {ParsedDocumentAdapters}=h.load('infra/ParsedDocumentAdapters');
  const {ParsedDocumentIngestionService}=h.load('application/ParsedDocumentIngestionService');
  const {parsedDocumentChunks}=h.load('pipeline/ParsedDocumentChunker');
  const {ParsedImportRequest,ParsedSourceAsset}=h.load('domain/ParsedDocumentPorts');
  const {KnowledgeStoreHost}=h.load('infra/KnowledgeStoreHost');
  const {KnowledgeStorageScope}=h.load('domain/KnowledgeStorageScope');
  const {TextChannel}=h.load('domain/TextKnowledgeModels');
  const {ParsedDocumentRepository}=h.load('infra/ParsedDocumentRepository');
  const {ParsedDocumentAssets}=h.load('infra/ParsedDocumentAssets');
  const {KnowledgeDerivedBudget}=h.load('infra/KnowledgeDerivedBudget');
  let serial=8000;
  async function session(){
    const key=(++serial).toString(16).padStart(16,'0'),scope=KnowledgeStorageScope.isolated(key),ctx={filesDir:'/us1-'+key+'/files',cacheDir:'/us1-'+key+'/cache',databaseDir:'/us1-'+key+'/db'};
    const host=KnowledgeStoreHost.forContext(ctx,scope);await host.acquireM1(async()=>TextChannel.Like);host.requireUnifiedProtection();
    const repo=new ParsedDocumentRepository(host,h.identity);repo.attachPhysicalBudget(new KnowledgeDerivedBudget(ctx,scope));await repo.open();
    const assets=new ParsedDocumentAssets(ctx.filesDir,ctx.cacheDir,scope,repo,h.identity,'us1');repo.attachPublicationVerifier(assets);
    return {repo,assets,host,ctx,service:new ParsedDocumentIngestionService(repo,assets,h.identity)};
  }
  function request(id,format){const r=new ParsedImportRequest();r.namespace='Import-'+format;r.sourceId=id;r.sourceHash=hash('source-'+id);r.sourceVersion=1;r.title=id;r.format=format;r.parserSignature='fixture-parser';r.engine='synthetic';return r;}
  const outputs=[
    ['text',M.ParsedFormat.Text,'# 标题\n\n正文 ![外链](https://invalid.example/image.png) 尾文'],
    ['pdf',M.ParsedFormat.Pdf,'PDF正文\n\n![图](images/shared.png)'],
    ['image',M.ParsedFormat.Image,'现有OCR正文'],
    ['docx',M.ParsedFormat.Docx,'服务抽取正文，不等于原生逐字内容\n\n$$x^2$$']
  ];
  return [
    ['four_producers_one_real_consumer_and_managed_images',async()=>{
      const s=await session();
      for(const [id,format,markdown]of outputs){
        const r=request(id,format);const source=new ParsedSourceAsset();source.id='original-'+id;source.owner='DocumentParseService';source.role='original';r.sources=[source];
        const adapter=new ParsedDocumentAdapters(h.identity);adapter.setOutput(markdown,undefined,'fixture-output');
        if(format!==M.ParsedFormat.Text)adapter.addImage('images/shared.png',new Uint8Array(fixture.png()),format===M.ParsedFormat.Image?M.ParsedProvenance.Original:M.ParsedProvenance.Derived);
        await s.service.ingest(r,adapter);assert.equal(s.service.state.stage,'Published');assert.equal(s.service.state.enhancement,'AwaitingConfig');assert(s.service.state.document.source_hash===r.sourceHash);
        const stored=await s.repo.get(s.service.state.document.documentKey);assert(stored.activeGeneration);assert((await s.repo.chunks(stored.id)).some(c=>c.text.includes(id==='docx'?'服务抽取正文':id==='image'?'OCR':'正文')));
        const restored=await s.assets.readSnapshot(stored.activeGeneration+'-manifest',new M.ParsedCancellation());C.parsedValidate(restored);
        for(const image of restored.images.filter(a=>a.state==='Ready'))assert.equal(hash(await s.assets.read(image.id,new M.ParsedCancellation())),fixture.gold.pngHash);
      }
      assert.equal((await s.repo.list()).length,4);assert.equal(h.requests(),0);
    }],
    ['missing_blocks_external_links_and_partial_preserve_text',async()=>{
      const s=await session(),a=new ParsedDocumentAdapters(h.identity);a.setOutput('正文 ![外图](https://invalid.example/x) 后文\n\n![本机](/private/not-authorized.png)',undefined,'markdown-only');
      await s.service.ingest(request('partial',M.ParsedFormat.Text),a);const d=s.service.state.document;assert.equal(s.service.state.stage,'Published');assert(d.occurrences.length===2);assert(d.occurrences.every(o=>o.assetId===''&&o.limitation));assert.equal(d.coverage.nativeLocation.state,'Unknown');assert((await s.repo.chunks(d.documentKey)).some(c=>c.text.includes('后文')));assert(!d.images.some(i=>i.state==='Ready'));
    }],
    ['pure_image_formula_unknown_inline_order_no_fake_text',async()=>{
      const s=await session(),a=new ParsedDocumentAdapters(h.identity);a.setOutput('前文 $x+1$ ![图](images/a.png) 后文\n\n$$y^2$$\n\n![纯图](images/missing.png)',undefined,'markdown');a.addImage('images/a.png',new Uint8Array(fixture.png()),M.ParsedProvenance.Derived);
      await s.service.ingest(request('mixed',M.ParsedFormat.Pdf),a);const d=s.service.state.document;assert.deepEqual(d.blocks[0].inlines.map(r=>r.kind),['Text','Formula','Text','Image','Text']);assert.equal(d.blocks[1].kind,'Formula');assert.equal(d.blocks[2].kind,'Image');
      const chunks=await s.repo.chunks(d.documentKey);assert(chunks.some(c=>c.text.includes('x+1')));assert(chunks.some(c=>c.text==='y^2'));assert(!chunks.some(c=>c.text.includes('missing.png')||c.text.includes('Missing')||c.text.includes('纯图')));
    }],
    ['common_chunker_container_leaf_ocr_and_scalar_ranges',async()=>{
      const d=new M.ParsedDocument();d.documentKey='doc';d.generation='gen';d.source_hash=hash('src');d.parser_signature='test';d.engine='test';d.blocks=[];
      const parent=new M.ParsedBlock();parent.id='container';parent.kind=M.ParsedKind.Container;parent.text='不得重复';d.blocks.push(parent);
      const leaf=new M.ParsedBlock();leaf.id='leaf';leaf.parentId=parent.id;leaf.order=1;leaf.text='😀'.repeat(600);d.blocks.push(leaf);
      const rows=await parsedDocumentChunks(d,h.identity,new M.ParsedCancellation());assert.equal(rows.length,2);assert.equal(rows.map(c=>c.text).join(''),leaf.text);assert.equal(rows[0].end,1024);assert(rows.every(c=>Buffer.byteLength(c.text)<=2048&&hash(c.text)===c.inputHash));
    }],
    ['identity_order_payload_role_and_coverage_forgery_rejected',async()=>{
      const d=fixture.parsedOutputs(M)[3],bundle=await C.parsedEncodeSnapshot(d,h.identity,new M.ParsedCancellation());const m=await C.parsedDecodeManifest(bundle.manifestBytes,h.identity,new M.ParsedCancellation());
      const copy=C.parsedDocumentFromManifest(m);const wrong=new M.ParsedPayloadPart();Object.assign(wrong,m.parts[0]);wrong.role='blocks';await assert.rejects(C.parsedApplyPayload(copy,wrong,bundle.payloads[0],h.identity,new M.ParsedCancellation()));
      d.blocks[1].order=0;assert.throws(()=>C.parsedValidate(d));
    }],
    ['pdf_v1_v2_export_real_complete_jpeg_files_not_container_hash',async()=>{
      const P=h.load('domain/PdfKnowledgeModels'),{PdfImagePayloadExporter}=h.load('infra/PdfImagePayload');
      for(const version of [1,2]){
        const s=await session(),d=request('pdf-old-'+version,M.ParsedFormat.Pdf);const rec=new M.ParsedDocumentRecord();rec.id='doc';rec.namespace='Synthetic';rec.legacyId='pdf';rec.sourceHash=d.sourceHash;await s.repo.register(rec);
        const f=fixture.pdf(),id='kb-'+String(version).repeat(32),root='/legacy-pdf-'+version;
        const image=new P.PdfDerivedImage();Object.assign(image,{id,memberId:'images/page.jpg',sha256:hash(f.payload),bytes:f.payload.length,mime:'image/jpeg',pixelWidth:1,pixelHeight:1});
        const descriptor=new P.PdfAssetDescriptor();Object.assign(descriptor,{id,generation:'legacy-gen',bytes:f.payload.length,format:'PDF-DERIVED-JPEG-'+version,hash:hash(f.payload)});
        if(version===1)h.memoryFiles.set(root+'/'+id+'/part-0-0',f.payload);
        else{const raw=Buffer.from(['PDF-DERIVED-JPEG-2',id,image.sha256,String(image.bytes),f.parts.map(hash).join(',')].join('\n'));descriptor.hash=hash(raw);h.memoryFiles.set(root+'/'+id+'/manifest',raw);f.parts.forEach((p,i)=>h.memoryFiles.set(root+'/'+id+'/part-0-'+i,p));assert.notEqual(descriptor.hash,image.sha256);}
        const exporter=new PdfImagePayloadExporter(root,{assetDescriptor:async()=>descriptor},h.identity);const ready=await exporter.export(image,'legacy-gen','doc','new-gen','new-image-'+version,s.assets,new P.KnowledgeCancellation());
        assert.equal(ready.payloadHash,image.sha256);assert.equal(ready.legacyContainerHash,descriptor.hash);assert.deepEqual(Buffer.from(await s.assets.read(ready.id,new M.ParsedCancellation())),f.payload);assert(h.memoryFiles.has(s.assets.assetDirectory()+'/images/'+ready.id));
        if(version===2){h.memoryFiles.set(root+'/'+id+'/part-0-1',Buffer.alloc(f.parts[1].length,1));await assert.rejects(exporter.payload(image,'legacy-gen',new P.KnowledgeCancellation()),/LegacyImagePartHash/);}
      }
    }],
    ['docx_actual_original_and_result_archives_bypass_correspondence',async()=>{
      const s=await session(),{DocxProcessingAdapter}=h.load('infra/DocxProcessingAdapter'),{DocxResultReader}=h.load('infra/DocxResultReader'),D=h.load('domain/DocxKnowledgeModels'),P=h.load('domain/PdfKnowledgeModels');
      const original=zip(sourceParts(),{stored:true}),result=zip([['full.md','服务正文与原生不一致\n\n![结果图](images/result.png)\n\n$$x^2$$'],['images/result.png',fixture.png()]],{stored:true}),root='/docx-unified';h.memoryFiles.set(root+'/original-source',original);h.memoryFiles.set(root+'/result-task',result);
      const binding=new D.DocxResultBinding();Object.assign(binding,{taskId:'task',dataId:'data',assetId:'result-task',hash:hash(result),bytes:result.length,originalHash:hash(original),originalVersion:1});
      const source=new D.DocxOriginal();Object.assign(source,{documentId:'docx-source',sourceId:'docx-source',assetId:'original-source',hash:hash(original),version:1,bytes:original.length,title:'self.docx'});
      const parse={viewState:()=>({snapshot:{tasks:[{id:'task',dataId:'data',hash:source.hash,version:1}],results:[{assetId:'result-task',taskId:'task',dataId:'data',hash:binding.hash,bytes:binding.bytes,originalHash:source.hash,version:1,completeTransport:true,signature:true}],cleanup:[]}})};
      const reader=new DocxResultReader(root,parse,h.identity),adapter=new DocxProcessingAdapter(root,h.identity,reader);adapter.prepare=()=>{throw Error('LegacyCorrespondenceMustNotRun');};
      await adapter.withUnified(source,binding,new P.KnowledgeCancellation(),async producer=>{const r=request('docx-real',M.ParsedFormat.Docx);r.sourceHash=source.hash;await s.service.ingest(r,producer);});
      const d=s.service.state.document;assert.equal(s.service.state.stage,'Published');assert((await s.repo.chunks(d.documentKey)).some(c=>c.text.includes('服务正文与原生不一致')));assert(!(await s.repo.chunks(d.documentKey)).some(c=>c.text.includes('原生不同')));
      assert(d.occurrences.some(o=>o.provenance==='NativeMember'&&o.member==='word/media/source.png'));assert(d.occurrences.some(o=>o.provenance==='ProviderDerived'&&o.member==='images/result.png'));assert.equal(d.images.filter(i=>i.state==='Ready').length,1,'identical bytes may share, occurrences do not');
      const native=d.blocks.filter(b=>b.id.startsWith('native-'));assert.equal(native.length,3);assert.deepEqual(native[0].inlines.map(r=>r.kind),['Text','Image','Text','Formula','Unknown']);assert.equal(native[1].inlines[0].kind,'Image');assert.equal(native[2].inlines[0].kind,'Formula');assert(native[2].inlines[0].formula.unsupportedReason.includes('Omml'));assert.equal(h.handles.size,0);
      assert.deepEqual(Buffer.from(await s.assets.read(d.images[0].id,new M.ParsedCancellation())),fixture.png());
    }],
    ['typed_content_without_old_pdf_layout_or_profile_keeps_unknown_objects',async()=>{
      const s=await session(),a=new ParsedDocumentAdapters(h.identity);const content=[{type:'paragraph',content:{paragraph_content:[{type:'text',content:'保留正文'},{type:'equation_inline',content:'x+1'}]}},{type:'image',content:{image_source:{path:'images/a.png'},content:''}},{type:'unreported-object',content:{}},{type:'table',content:{html:'<table><tr><td>A</td><td>B</td></tr></table>'}}];a.setOutput('',new Uint8Array(Buffer.from(JSON.stringify([content]))),'content_v2');a.addImage('images/a.png',new Uint8Array(fixture.png()),M.ParsedProvenance.Derived);
      await s.service.ingest(request('content-only',M.ParsedFormat.Pdf),a);const d=s.service.state.document;assert(d.blocks.some(b=>b.kind==='Unknown'));assert.equal(d.blocks.filter(b=>b.kind==='Cell').length,2);assert((await s.repo.chunks(d.documentKey)).some(c=>c.text==='保留正文x+1'));assert(!d.warnings.includes('ProtocolProfileUnrecognized'));
    }],
    ['readback_preview_lease_and_ingest_repeat_do_not_duplicate',async()=>{
      const s=await session(),a=new ParsedDocumentAdapters(h.identity);a.setOutput('![无字图](images/a.png)',undefined,'fixed');a.addImage('images/a.png',new Uint8Array(fixture.png()),M.ParsedProvenance.Derived);const r=request('idempotent',M.ParsedFormat.Pdf);await s.service.ingest(r,a);const d=s.service.state.document,ready=d.images[0];const preview=await s.service.previewImage(ready.id);assert(preview.startsWith('file:'));assert.equal(await s.assets.cleanup(ready.id),false);await s.service.closePreview();await s.service.ingest(r,a);assert.equal((await s.repo.list()).length,1);assert.equal(s.service.state.document.generation,d.generation);assert.equal((await s.repo.chunks(d.documentKey)).length,0);
    }],
    ['actual_import_dispatch_pdf_image_docx_all_common_storage',async()=>{
      const s=await session(),{ParsedDocumentImportAdapter}=h.load('infra/ParsedDocumentImportAdapter'),D=h.load('domain/DocumentParseModels');
      const imports=new ParsedDocumentImportAdapter(s.ctx,s.host,h.identity,s.service);
      const originalZip=zip(sourceParts(),{stored:true}),zipResult=zip([['full.md','统一抽取正文\n\n![图](images/result.png)'],['images/result.png',fixture.png()]],{stored:true});
      for(const [at,format]of [D.DocumentParseFormat.Pdf,D.DocumentParseFormat.Png,D.DocumentParseFormat.Docx].entries()){
        const source=new D.DocumentOriginal();Object.assign(source,{id:'source-'+at,assetId:'original-source-'+at,title:'synthetic-'+at,hash:hash(format===D.DocumentParseFormat.Png?fixture.png():originalZip),bytes:(format===D.DocumentParseFormat.Png?fixture.png():originalZip).length,format,version:1});
        const result=new D.DocumentParseResultEnvelope();Object.assign(result,{assetId:'result-source-'+at,taskId:'task-'+at,dataId:'data-'+at,originalHash:source.hash,version:1,hash:hash(zipResult),bytes:zipResult.length,signature:true,completeTransport:true});
        const task=new D.DocumentParseTask();Object.assign(task,{id:result.taskId,dataId:result.dataId,originalId:source.id,hash:source.hash,version:1});
        h.memoryFiles.set(s.ctx.filesDir+'/knowledge_parse_v1/'+source.assetId,format===D.DocumentParseFormat.Png?fixture.png():originalZip);h.memoryFiles.set(s.ctx.filesDir+'/knowledge_parse_v1/'+result.assetId,zipResult);
        const parse={viewState:()=>({snapshot:{originals:[source],tasks:[task],results:[result],cleanup:[]}}),withReceivedResult:async(id,run)=>{assert.equal(id,result.assetId);return run(source,result,task);}};
        await imports.consume(parse,result.assetId);assert.equal(s.service.state.stage,'Published');assert.equal(s.service.state.document.format,format===D.DocumentParseFormat.Pdf?'Pdf':format===D.DocumentParseFormat.Docx?'Docx':'Image');
        const chunks=await s.repo.chunks(s.service.state.document.documentKey);assert(chunks.some(c=>c.text.includes('统一抽取正文')));if(format===D.DocumentParseFormat.Png){assert(chunks.every(c=>c.evidence==='Ocr'));assert(chunks.every(c=>c.occurrenceId.length>0));assert(s.service.state.document.occurrences.some(o=>o.provenance==='IndependentOriginal'&&o.ocr.includes('统一抽取正文')));}
      }
      assert.equal((await s.repo.list()).length,3);assert.equal(h.requests(),0);assert.equal(h.handles.size,0);
    }],
    ['partial_structured_record_retains_markdown_body_and_object',async()=>{
      const s=await session(),a=new ParsedDocumentAdapters(h.identity);a.setOutput('服务正文绝不能因未知块丢失',new Uint8Array(Buffer.from('[{"type":"future-object","content":{}}]')),'future');await s.service.ingest(request('future',M.ParsedFormat.Pdf),a);assert(s.service.state.document.blocks.some(b=>b.kind==='Unknown'));assert((await s.repo.chunks(s.service.state.document.documentKey)).some(c=>c.text.includes('绝不能')));assert.equal(s.service.state.document.coverage.selectedOutput.state,'Partial');
    }],
    ['global_text_input_budget_includes_legacy_current_routes',async()=>{
      const s=await session();await s.host.requireStore().executeSql('CREATE TABLE text_doc(id TEXT PRIMARY KEY,chunks INTEGER)');await s.host.requireStore().executeSql('INSERT INTO text_doc VALUES(?,?)',['old-doc',30000]);const a=new ParsedDocumentAdapters(h.identity);a.setOutput('新增正文',undefined,'budget');await assert.rejects(s.service.ingest(request('budget',M.ParsedFormat.Text),a),/AllCurrentInputBudget/);assert.equal(s.service.state.stage,'Failed');
    }],
    ['actual_text_picker_original_and_public_consumer_no_text_repository_write',async()=>{
      const s=await session(),{ParsedDocumentImportAdapter}=h.load('infra/ParsedDocumentImportAdapter');for(const dir of [s.ctx.filesDir,s.ctx.cacheDir])h.memoryFiles.set(dir,null);
      const input='/selected/self.md';h.memoryFiles.set(input,Buffer.from('# 独立文本\n\n正文 ![外链](https://invalid.example/no-read)'));h.select([input]);
      try{await new ParsedDocumentImportAdapter(s.ctx,s.host,h.identity,s.service).importText();}finally{h.select([]);}
      assert.equal(s.service.state.stage,'Published');assert.equal(s.service.state.document.engine,'Local');assert((await s.repo.chunks(s.service.state.document.documentKey)).some(c=>c.text.includes('正文')));assert.equal(s.service.state.document.occurrences[0].assetId,'');
      const rows=await s.host.requireStore().querySql("SELECT count(*) FROM sqlite_master WHERE name='text_doc'");assert(rows.goToNextRow());assert.equal(rows.getLong(0),0);rows.close();assert([...h.memoryFiles.keys()].some(p=>p.startsWith(s.ctx.filesDir+'/knowledge_user_v1/original-')));
    }],
    ['formal_view_handler_listener_rebind_and_unsubscribe_without_arkui_runtime',async()=>{
      const {ParsedDocumentView}=h.load('ui/ParsedDocumentView'),view=new ParsedDocumentView();let imports=0,subscriptions=0,unsubscribes=0;const state=new M.ParsedImportState();
      const service={state,refresh:async()=>{},subscribe:()=>subscriptions++,unsubscribe:()=>unsubscribes++,closePreview:async()=>{}};
      view.service=service;view.imports={importText:async()=>{imports++;state.stage='Published';state.message='正文已发布';}};view.aboutToAppear();await view.select('Text');assert.equal(imports,1);assert.equal(view.taskStage,'Published');assert.equal(subscriptions,1);view.service={...service};view.bindServices();assert.equal(subscriptions,2);assert.equal(unsubscribes,1);view.aboutToDisappear();assert.equal(unsubscribes,2);
      const root=path.resolve(__dirname,'../../..'),index=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/Index.ets'),'utf8');assert(fs.readFileSync(path.join(root,'entry/src/main/ets/knowledge/ui/UnifiedKnowledgeView.ets'),'utf8').includes("id: 'upd-entry', onOpen: this.onDocuments"));assert(index.includes('ParsedDocumentView({'));assert(index.includes('await this.consumeParsed(resultId)'));assert(index.includes('private async openDocx(): Promise<void> { await this.openParsed(); }'));assert(index.includes('private async openImages(): Promise<void> { await this.openParsed(); }'));
    }],
    ['mobile_library_groups_original_and_content_filters_and_keeps_services_by_reference',async()=>{
      const {ParsedDocumentView}=h.load('ui/ParsedDocumentView'),D=h.load('domain/DocumentParseModels'),view=new ParsedDocumentView();
      const record=Object.assign(new M.ParsedDocumentRecord(),{id:'doc',legacyId:'original',title:'会议记录',activeGeneration:'gen'}),archived=Object.assign(new M.ParsedDocumentRecord(),{id:'archived',legacyId:'other',title:'归档资料',activeGeneration:'g2',archived:true}),original=Object.assign(new D.DocumentOriginal(),{id:'original',title:'会议记录'}),pending=Object.assign(new D.DocumentOriginal(),{id:'pending',title:'新文档'});
      view.documents=[record,archived];view.originals=[original,pending];view.refreshLibrary();assert.equal(view.library.length,2);assert.equal(view.library.filter(r=>r.originalId==='original').length,1);assert.equal(view.library[0].documentId,'doc');
      view.filterText='新文档';view.refreshLibrary();assert.equal(view.library.length,1);await view.openItem(view.library[0]);assert.equal(view.selectedOriginal,'pending');assert.equal(view.selectedDocument,'');assert.equal(view.title,'新文档');assert.equal(view.blocks.length,0);
      view.filterText='';view.includeArchived=true;view.refreshLibrary();assert.equal(view.library.length,3);
      const root=path.resolve(__dirname,'../../..'),page=fs.readFileSync(path.join(root,'entry/src/main/ets/knowledge/ui/ParsedDocumentView.ets'),'utf8'),index=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/Index.ets'),'utf8');
      assert(!/@Prop[^\n]*(?:service|imports|parse):/.test(page));assert(!/@State[^\n]*(?:parsedService|parsedImports|parseService|embeddingService):/.test(index));assert(page.includes("id('upd-import')"));assert(index.includes('if (this.parsedOpening)'));assert(!index.includes("id('m3-image-entry')"));assert(!index.includes("id('m4-docx-entry')"));
    }],
    ['mobile_detail_hides_duplicate_native_text_but_keeps_unknown_and_failed_save_stays_selected',async()=>{
      const {ParsedDocumentView}=h.load('ui/ParsedDocumentView'),D=h.load('domain/DocumentParseModels'),view=new ParsedDocumentView(),state=new M.ParsedImportState();
      const body=Object.assign(new M.ParsedBlock(),{id:'body',kind:M.ParsedKind.Text,text:'服务正文'}),native=Object.assign(new M.ParsedBlock(),{id:'native',kind:M.ParsedKind.Text,text:'服务正文',evidenceType:'SourceContextOnly'}),unknown=Object.assign(new M.ParsedBlock(),{id:'object',kind:M.ParsedKind.Unknown,evidenceType:'SourceContextOnly',limitation:'未支持对象'});
      state.document.blocks=[body,native,unknown];state.document.documentKey='previous';view.alive=true;view.selectedDocument='previous';view.service={state};view.refreshView();assert.deepEqual(view.blocks.map(b=>b.id),['body','object']);
      view.selectedDocument='';view.selectedOriginal='new-source';const task=Object.assign(new D.DocumentParseTask(),{id:'new-task',originalId:'new-source'}),result=Object.assign(new D.DocumentParseResultEnvelope(),{assetId:'new-result',taskId:'new-task'});view.parse={viewState:()=>({snapshot:{originals:[],tasks:[task],results:[result]}})};view.imports={consume:async()=>{throw Error('InjectedReadbackFailure');}};view.refreshView();await view.saveSelected();assert.equal(view.selectedDocument,'');assert.match(view.message,/InjectedReadbackFailure/);
    }],
    ['failed_image_recovery_preserves_body_not_fake_ready',async()=>{
      const s=await session(),a=new ParsedDocumentAdapters(h.identity);a.setOutput('正文保留\n\n![坏图](images/bad.png)',undefined,'bad-image');a.addImage('images/bad.png',new Uint8Array([1,2,3]),M.ParsedProvenance.Derived);await s.service.ingest(request('bad-image',M.ParsedFormat.Pdf),a);assert.equal(s.service.state.stage,'Published');assert.equal(s.service.state.document.images[0].state,'Missing');assert.equal(s.service.state.document.coverage.imageRecovery.state,'Partial');assert((await s.repo.chunks(s.service.state.document.documentKey)).some(c=>c.text.includes('正文保留')));
    }],
    ['caption_text_table_cells_and_image_occurrences_preserve_reading_order',async()=>{
      const s=await session(),a=new ParsedDocumentAdapters(h.identity),content=[{type:'image',content:{image_source:{path:'images/z.png'},image_caption:[[{type:'text',content:'图注文字'}]]}},{type:'image',content:{image_source:{path:'images/a.png'}}},{type:'equation_interline',content:{math_type:'latex',math_content:'a=b',caption:[{type:'text',content:'公式解释'}]}}];
      a.setOutput('',new Uint8Array(Buffer.from(JSON.stringify([content]))),'ordered');a.addImage('images/a.png',new Uint8Array(fixture.png()),M.ParsedProvenance.Derived);a.addImage('images/z.png',new Uint8Array(fixture.png()),M.ParsedProvenance.Derived);await s.service.ingest(request('order',M.ParsedFormat.Pdf),a);
      const d=s.service.state.document;assert.deepEqual(d.occurrences.map(o=>o.member),['images/z.png','images/a.png']);const chunks=await s.repo.chunks(d.documentKey);assert(chunks.some(c=>c.text==='图注文字'));assert(chunks.some(c=>c.text==='a=b'));assert(chunks.some(c=>c.text==='公式解释'));assert(!chunks.some(c=>c.text.includes('images/')));
    }],
    ['explicit_local_rebuild_recovers_image_without_mutating_old_generation',async()=>{
      const s=await session(),r=request('rebuild',M.ParsedFormat.Pdf),bad=new ParsedDocumentAdapters(h.identity);bad.setOutput('正文\n\n![图](images/a.png)',undefined,'fixed');bad.addImage('images/a.png',new Uint8Array([1]),M.ParsedProvenance.Derived);await s.service.ingest(r,bad);const old=s.service.state.document.generation;
      const good=new ParsedDocumentAdapters(h.identity);good.setOutput('正文\n\n![图](images/a.png)',undefined,'fixed');good.addImage('images/a.png',new Uint8Array(fixture.png()),M.ParsedProvenance.Derived);await s.service.ingest(r,good,true);assert.notEqual(s.service.state.document.generation,old);assert.equal(s.service.state.document.images[0].state,'Ready');const retained=await s.assets.readSnapshot(old+'-manifest',new M.ParsedCancellation());assert.equal(retained.images[0].state,'Missing');assert.equal(h.requests(),0);
    }],
    ['damaged_native_xml_does_not_discard_service_text_or_original_media',async()=>{
      const s=await session(),{DocxProcessingAdapter}=h.load('infra/DocxProcessingAdapter'),{DocxResultReader}=h.load('infra/DocxResultReader'),D=h.load('domain/DocxKnowledgeModels'),P=h.load('domain/PdfKnowledgeModels');
      const parts=sourceParts();parts[2]=['word/document.xml','<bad/>'];const original=zip(parts,{stored:true}),result=zip([['full.md','原生损坏仍保正文']],{stored:true}),root='/docx-native-bad';h.memoryFiles.set(root+'/original-source',original);h.memoryFiles.set(root+'/result-task',result);
      const b=Object.assign(new D.DocxResultBinding(),{taskId:'task',dataId:'data',assetId:'result-task',hash:hash(result),bytes:result.length,originalHash:hash(original),originalVersion:1});const source=Object.assign(new D.DocxOriginal(),{documentId:'doc',sourceId:'src',assetId:'original-source',hash:hash(original),version:1,bytes:original.length});
      const parse={viewState:()=>({snapshot:{tasks:[{id:'task',dataId:'data',hash:source.hash,version:1}],results:[{...b,signature:true,completeTransport:true}],cleanup:[]}})};
      // Exact result envelope fields, not the binding's aliases.
      parse.viewState=()=>({snapshot:{tasks:[{id:'task',dataId:'data',hash:source.hash,version:1}],results:[{assetId:b.assetId,taskId:b.taskId,dataId:b.dataId,hash:b.hash,bytes:b.bytes,originalHash:b.originalHash,version:1,signature:true,completeTransport:true}],cleanup:[]}});
      await new DocxProcessingAdapter(root,h.identity,new DocxResultReader(root,parse,h.identity)).withUnified(source,b,new P.KnowledgeCancellation(),async a=>{const r=request('native-bad',M.ParsedFormat.Docx);r.sourceHash=source.hash;await s.service.ingest(r,a);});assert((await s.repo.chunks(s.service.state.document.documentKey)).some(c=>c.text==='原生损坏仍保正文'));assert.equal(s.service.state.document.images[0].state,'Ready');assert(s.service.state.document.warnings.includes('NativeEnhancementUnavailableParserBodyPreserved'));assert.equal(h.handles.size,0);
    }],
    ['local_publication_retry_reuses_saved_snapshot_zero_network',async()=>{
      const s=await session(),a=new ParsedDocumentAdapters(h.identity);a.setOutput('可恢复正文',undefined,'retry');h.fault('INSERT INTO upd_chunk');await assert.rejects(s.service.ingest(request('retry',M.ParsedFormat.Text),a));h.fault('');assert.equal(s.service.state.stage,'Failed');await s.service.retryLocal();assert.equal(s.service.state.stage,'Published');assert.equal(s.service.state.chunks[0].text,'可恢复正文');assert.equal(h.requests(),0);
    }],
    ['markdown_code_fence_does_not_invent_assets_or_formula',async()=>{
      const s=await session(),a=new ParsedDocumentAdapters(h.identity);a.setOutput('```text\n![literal](images/no.png)\n\n$x$\n```',undefined,'code');await s.service.ingest(request('code',M.ParsedFormat.Text),a);assert.equal(s.service.state.document.occurrences.length,0);assert(s.service.state.chunks.some(c=>c.text.includes('![literal]')));
    }]
  ];
};
