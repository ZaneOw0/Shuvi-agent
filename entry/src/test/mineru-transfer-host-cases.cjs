// Production adapter methods with isolated in-memory SDK doubles, never a real network or user file.
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { TextEncoder, TextDecoder } = require('node:util');

module.exports = function transferHostCases(outputRoot, asset) {
  const files = new Map(); const handles = new Map(); let nextFd = 1; let calls = [];
  let behavior = 'OK'; let shortRead = 65536; let activeTimers = new Map(); let serial = 0; const secrets = new Map(); let lateDestination;
  const stat = bytes => ({ size: bytes.length, mtime: 1, isFile: () => true, isDirectory: () => false, isSymbolicLink: () => false });
  const io = {
    OpenMode: { READ_ONLY: 0, READ_WRITE: 2, CREATE: 64, NOFOLLOW: 128 },
    access: async p => files.has(p) || p.endsWith('knowledge_parse_v1'), mkdir: async () => {},
    lstat: async p => files.has(p) ? stat(files.get(p)) : ({ isDirectory: () => true, isSymbolicLink: () => false }),
    open: async (p, mode) => { if (!files.has(p)) { if (!(mode & 64)) throw new Error('host file missing'); files.set(p, Buffer.alloc(0)); } const file = { fd: nextFd++ }; handles.set(file.fd, p); return file; },
    close: async f => { handles.delete(f.fd); }, stat: async fd => stat(files.get(handles.get(fd))),
    read: async (fd, buffer, options) => {
      const bytes = files.get(handles.get(fd)); const n = Math.max(0, Math.min(options.length, shortRead, bytes.length - options.offset));
      new Uint8Array(buffer).set(bytes.subarray(options.offset, options.offset + n)); return n;
    },
    write: async (fd, buffer, options) => {
      await new Promise(resolve => setImmediate(resolve));
      if (behavior === 'DISK') throw new Error('host nonsecret disk failure');
      const p = handles.get(fd); const old = files.get(p); const bytes = Buffer.alloc(Math.max(old.length, options.offset + options.length));
      old.copy(bytes); Buffer.from(buffer).copy(bytes, options.offset, 0, options.length); files.set(p, bytes); return options.length;
    },
    fsync: async () => {}, rename: async (from, to) => { files.set(to, files.get(from)); files.delete(from); }, unlink: async p => { files.delete(p); }
  };
  class HostRequest { constructor(url, method) { this.url = url; this.method = method; } }
  class HostUpload { constructor(reader) { this.fileOrPath = reader; } }
  class HostEncoder { encodeInto(s) { return new TextEncoder().encode(s); } }
  class HostDecoder { static create(e, options) { return { decodeToString: b => new TextDecoder(e, options).decode(b) }; } }
  const kit = {
    '@kit.AssetStoreKit': { asset: asset },
    '@kit.RemoteCommunicationKit': { rcp: { Request: HostRequest, UploadFromFile: HostUpload, createSession: config => ({
      cancel: () => {}, close: () => {}, fetch: async request => {
        calls.push(request); assert.equal(config.requestConfiguration.transfer.autoRedirect, false);
        assert.equal(config.cacheControl.noStore, true); assert.equal(request.headers?.authorization, undefined);
        if (behavior === 'TIMEOUT') { lateDestination = request.destination; return await new Promise(() => {}); }
        if (behavior === 'SDK_ERROR') throw Object.assign(new Error('must-not-expose-detail'), { code: 1007900001 });
        if (request.method === 'PUT') {
          assert.equal(request.headers['content-length'], String(files.get('/host/files/knowledge_parse_v1/original-unit').length));
          assert.equal(request.headers['content-type'], ' ');
          const reader = request.content.fileOrPath;
          const supplied = [];
          for (;;) { const b = new ArrayBuffer(131072); const n = await reader.read(b); if (!n) break; supplied.push(Buffer.from(b).subarray(0, n)); if (behavior === 'PARTIAL') break; }
          assert.equal(Buffer.concat(supplied).length > 0, true);
        } else if(behavior==='IMAGE_CONTROL' && (request.method==='POST' || request.url.includes('/extract-results/'))) {
          const reply=request.method==='POST'?{code:0,msg:'ok',data:{batch_id:'image-batch',file_urls:['https://'+codec.MINERU_UPLOAD_HOST+'/api-upload/unit']}}:{code:0,msg:'ok',data:{batch_id:'image-batch',extract_result:[{data_id:'unit',file_name:'unit.jpg',state:'done',full_zip_url:'https://'+codec.MINERU_RESULT_HOST+'/pdf/unit.zip'}]}};
          const bytes=Buffer.from(JSON.stringify(reply));await request.destination(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.length));request.configuration.tracing.httpEventsHandler.onDataEnd();
        } else {
          const bytes = zipBytes(); await request.destination(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
          const handler = request.configuration.tracing.httpEventsHandler;
          if (behavior === 'LENGTH') handler.onHeaderReceive({ 'content-length': '99' });
          if (behavior !== 'NO_END') handler.onDataEnd();
        }
        const code = behavior === 'HTTP403' ? 403 : behavior === 'HTTP204' ? 204 : 200;
        request.configuration.tracing.httpEventsHandler.onStatusCodeReceive(code);
        return { statusCode: code, headers: behavior === 'LENGTH' ? { 'content-length': '99' } : {} };
      }
    }) } },
    '@kit.ArkTS': { util: { TextEncoder: HostEncoder, TextDecoder: HostDecoder }, taskpool: { Task: { isCanceled: () => false } } },
    '@kit.CoreFileKit': { fileIo: io }, '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.ArkData': {},
    '@kit.CryptoArchitectureKit': { cryptoFramework: {
      CryptoMode: { ENCRYPT_MODE: 0, DECRYPT_MODE: 1 },
      createRandom: () => ({ generateRandom: async n => ({ data: new Uint8Array(crypto.randomBytes(n)) }) }),
      createSymKeyGenerator: () => ({ convertKey: async blob => { const key = Buffer.from(blob.data); return { key, clearMem: () => key.fill(0) }; } }),
      createCipher: () => {
        let mode; let key; let params;
        return { init: async (m, k, p) => { mode = m; key = k.key; params = p; }, doFinal: async blob => {
          if (mode === 0) {
            const cipher = crypto.createCipheriv('aes-256-gcm', key, params.iv.data); cipher.setAAD(params.aad.data);
            return { data: new Uint8Array(Buffer.concat([cipher.update(blob.data), cipher.final(), cipher.getAuthTag()])) };
          }
          const cipher = crypto.createDecipheriv('aes-256-gcm', key, params.iv.data); cipher.setAAD(params.aad.data); cipher.setAuthTag(params.authTag.data);
          return { data: new Uint8Array(Buffer.concat([cipher.update(blob.data), cipher.final()])) };
        } };
      }, createMd: () => {
      const hash = crypto.createHash('sha256'); return { update: async blob => hash.update(blob.data), digest: async () => ({ data: new Uint8Array(hash.digest()) }) };
    } } }
  };
  // Each suite owns its SDK doubles; never reuse another suite's compiled adapters.
  const adapterModules = new Map();
  function load(relative) {
    const name = path.join(outputRoot, relative); if (adapterModules.has(name)) return adapterModules.get(name).exports; const loaded = new Module(name, module); loaded.filename = name; loaded.paths = Module._nodeModulePaths(path.dirname(name));
    const original = loaded.require.bind(loaded); loaded.require = id => { if(Object.hasOwn(kit,id))return kit[id]; if(id.startsWith('.')){const target=path.resolve(path.dirname(name),id+'.js');if(!target.startsWith(path.resolve(outputRoot)+path.sep))throw Error('HostModuleBoundary');return load(path.relative(outputRoot,target));}return original(id); };
    // Only this adapter gets virtual timers. The test runner and other suites keep real timers.
    adapterModules.set(name, loaded);
    try {
      loaded._compile(`const setTimeout = global.__mineruHostTimers.set; const clearTimeout = global.__mineruHostTimers.clear;\n${fs.readFileSync(name, 'utf8')}`, name);
      loaded.loaded = true; return loaded.exports;
    } catch (error) { adapterModules.delete(name); throw error; }
  }
  global.__mineruHostTimers = { set: fn => { const id = ++serial; activeTimers.set(id, fn); if (behavior === 'TIMEOUT') setImmediate(() => activeTimers.get(id)?.()); return id; }, clear: id => activeTimers.delete(id) };
  const models = load('entry/src/main/ets/knowledge/domain/DocumentParseModels.js');
  const codec = load('entry/src/main/ets/knowledge/pipeline/MineruProtocolCodec.js');
  load('entry/src/main/ets/knowledge/infra/DocumentFileOperations.js');
  const { DocumentFileAdapter } = load('entry/src/main/ets/knowledge/infra/DocumentFileAdapter.js');
  const { MineruTransportAdapter } = load('entry/src/main/ets/knowledge/infra/MineruTransportAdapter.js');
  const { MineruCredentialStore } = load('entry/src/main/ets/knowledge/infra/MineruCredentialStore.js');
  const assetApi = {
    query: async query => {
      const alias = Buffer.from(query.get(asset.Tag.ALIAS)).toString('utf8'); const value = secrets.get(alias);
      if (!value) throw Object.assign(new Error('host secret missing'), { code: 24000002 });
      const row = new Map([[asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED], [asset.Tag.SYNC_TYPE, asset.SyncType.NEVER]]);
      if (query.get(asset.Tag.RETURN_TYPE) === asset.ReturnType.ALL) row.set(asset.Tag.SECRET, new Uint8Array(value)); return [row];
    },
    add: async attrs => { secrets.set(Buffer.from(attrs.get(asset.Tag.ALIAS)).toString('utf8'), Buffer.from(attrs.get(asset.Tag.SECRET))); }
  };
  function leaseSetup() {
    setup(); secrets.clear();
    const b = new models.DocumentLeaseBinding(); b.id = 'lease-unit'; b.taskId = 'unit'; b.hash = 'a'.repeat(64); b.version = 1; b.credentialRevision = 1;
    b.purpose = 'UPLOAD'; b.issuedAt = Date.now() - 2000; b.expiresAt = Date.now() + 100000; return { b, store: new MineruCredentialStore('/host/files', assetApi) };
  }
  function zipBytes() {
    // Constructed external-boundary bytes only. Not a MinerU result or a user sample.
    const bytes = Buffer.alloc(100); bytes.writeUInt32LE(0x04034b50, 0); bytes.writeUInt32LE(0x06054b50, 78);
    bytes.writeUInt16LE(1, 86); bytes.writeUInt16LE(1, 88); bytes.writeUInt32LE(46, 90); bytes.writeUInt32LE(32, 94); return bytes;
  }
  function setup(mode = 'OK') {
    files.clear(); handles.clear(); calls = []; activeTimers.clear(); behavior = mode; shortRead = 7001; lateDestination = undefined;
    const a = new models.DocumentParseAction(); a.task.id = 'unit'; a.task.dataId = 'unit'; a.task.hash = a.original.hash = crypto.createHash('sha256').update(Buffer.alloc(262147, 7)).digest('hex');
    a.original.id = a.task.originalId = 'image-source'; a.original.assetId = 'original-unit'; a.original.bytes = 262147; a.original.version = a.task.version = 1; a.task.uploadLease = 'lease-unit'; a.task.resultLease = 'lease-unit-result';
    files.set('/host/files/knowledge_parse_v1/original-unit', Buffer.alloc(262147, 7));
    a.onUploadStarting = async () => { a.task.uploadAttempted = true; a.task.uploadRequestStarted = true; };
    const credential = { clearTransient: () => {}, authenticatedFetch:async(request,session,check)=>{check();return session.fetch(request);},sealLease:async()=>{}, withLease: async (binding, consume) => {
      if (behavior === 'LEASE') throw new models.DocumentParseFailure('租约已失效', '恢复');
      await consume('https://' + (binding.purpose === 'UPLOAD' ? codec.MINERU_UPLOAD_HOST + '/api-upload/unit' : codec.MINERU_RESULT_HOST + '/pdf/unit.zip'));
    } };
    const assets = new DocumentFileAdapter({ filesDir: '/host/files', cacheDir: '/host/cache' });
    return { a, assets, adapter: new MineruTransportAdapter(credential, assets, '/host/files') };
  }
  return [
    { name:'legacy U03 permit retains original policy and transport identity',run:async()=>{
      const s=setup('IMAGE_CONTROL');Object.assign(s.a.original,{hash:'f8157d2c4ea7ad363a771d961fe0795442ffc4c968b2b2f6fe146ab2d48a71a4',bytes:129998,format:models.DocumentParseFormat.Jpeg});s.a.task.hash=s.a.original.hash;Object.assign(s.a.grant,{id:'legacy-grant',originalId:s.a.original.id,hash:s.a.original.hash,version:1,format:s.a.original.format,credentialRevision:s.a.task.credentialRevision,policy:models.ImageParsePermit.policy,parameters:models.ImageParsePermit.parameters,issuedAt:Date.now()});Object.assign(s.a.grant.acknowledgement,{fullFile:true,freeEligible:true});s.a.onAllocation=async batch=>s.a.task.batchId=batch;await s.adapter.allocate(s.a);assert.equal(calls.length,1);s.a.grant.policy=models.ImageParsePermit.productionPolicy;await assert.rejects(s.adapter.inspect(s.a));assert.equal(calls.length,1);
    }},
    { name:'formal image adapter allocation PUT same batch and received ZIP',run:async()=>{
      const s=setup('IMAGE_CONTROL');s.a.original.format=models.DocumentParseFormat.Jpeg;Object.assign(s.a.grant,{id:'image-grant',originalId:s.a.original.id,hash:s.a.original.hash,version:s.a.original.version,format:s.a.original.format,credentialRevision:s.a.task.credentialRevision,issuedAt:Date.now(),policy:models.ImageParsePermit.productionPolicy,parameters:models.ImageParsePermit.parameters});s.a.grant.acknowledgement.fullFile=true;s.a.grant.acknowledgement.freeEligible=true;s.a.onAllocation=async batch=>{s.a.task.batchId=batch;};
      const allocated=await s.adapter.allocate(s.a);assert.equal(allocated.batchId,'image-batch');assert.equal(JSON.parse(calls[0].content??codec.mineruAllocationPayload('unit',models.DocumentParseFormat.Jpeg)).files[0].name,'unit.jpg');
      await s.adapter.upload(s.a);const inspected=await s.adapter.inspect(s.a);assert.equal(inspected.state,models.DocumentRemoteState.Done);await s.adapter.receive(s.a,new models.DocumentParseUsage());assert.equal(calls.length,4);assert.equal(calls.filter(c=>c.method==='POST').length,1);assert.equal(calls.filter(c=>c.method==='PUT').length,1);assert.equal(handles.size,0);
    }},
    { name:'ordinary image production permit validates current identity before any SDK request',run:async()=>{
      for(const format of [models.DocumentParseFormat.Jpeg,models.DocumentParseFormat.Png,models.DocumentParseFormat.Webp]){
        const s=setup('IMAGE_CONTROL');Object.assign(s.a.original,{format});Object.assign(s.a.grant,{id:'ordinary-grant',originalId:s.a.original.id,hash:s.a.original.hash,version:s.a.original.version,format,credentialRevision:s.a.task.credentialRevision,issuedAt:Date.now(),policy:models.ImageParsePermit.productionPolicy,parameters:models.ImageParsePermit.parameters});Object.assign(s.a.grant.acknowledgement,{fullFile:true,freeEligible:true});s.a.onAllocation=async batch=>s.a.task.batchId=batch;
        await s.adapter.allocate(s.a);assert.equal(calls.length,1);await s.adapter.upload(s.a);assert.equal(calls.length,2);
      }
      for(const mutate of [a=>a.grant.acknowledgement.fullFile=false,a=>a.grant.acknowledgement.freeEligible=false,a=>a.grant.hash='0'.repeat(64),a=>a.grant.version++,a=>a.grant.format=models.DocumentParseFormat.Png,a=>a.grant.credentialRevision++,a=>a.grant.parameters='changed',a=>a.grant.revoked=true]){
        const s=setup('IMAGE_CONTROL');Object.assign(s.a.original,{format:models.DocumentParseFormat.Jpeg});Object.assign(s.a.grant,{id:'ordinary-grant',originalId:s.a.original.id,hash:s.a.original.hash,version:1,format:s.a.original.format,credentialRevision:s.a.task.credentialRevision,issuedAt:Date.now(),policy:models.ImageParsePermit.productionPolicy,parameters:models.ImageParsePermit.parameters});Object.assign(s.a.grant.acknowledgement,{fullFile:true,freeEligible:true});mutate(s.a);await assert.rejects(s.adapter.allocate(s.a));assert.equal(calls.length,0);
      }
    }},
    { name: 'short file reads fill SDK buffer; exact SHA length EOF and empty HTTP200 PUT succeeds', run: async () => {
      const s = setup(); await s.adapter.upload(s.a); assert.equal(s.a.task.uploadBytes, 262147); assert.equal(calls.length, 1); assert.equal(handles.size, 0);
    } },
    { name: 'expired lease has zero PUT and does not mark request started', run: async () => {
      const s = setup('LEASE'); await assert.rejects(s.adapter.upload(s.a), /租约/); assert.equal(calls.length, 0); assert.equal(s.a.task.uploadAttempted, false);
    } },
    ...['HTTP403', 'HTTP204', 'PARTIAL', 'SDK_ERROR', 'TIMEOUT'].map(mode => ({ name: `${mode} cannot confirm upload or leak SDK detail`, run: async () => {
      const s = setup(mode); let failure; try { await s.adapter.upload(s.a); } catch (e) { failure = e; }
      assert.ok(failure instanceof models.DocumentParseFailure); assert.ok(!failure.message.includes('must-not-expose-detail'));
      if (mode === 'SDK_ERROR') assert.equal(failure.serviceCode, '1007900001');
      if (mode === 'TIMEOUT') { assert.equal(s.a.cancel.reason, 'TIMEOUT'); assert.equal(s.a.cancel.invalid, true); }
      assert.equal(handles.size, 0);
    } })),
    { name: 'result waits actual asynchronous disk writes and publishes hash-checked UNVALIDATED bytes', run: async () => {
      const s = setup(); const result = await s.adapter.receive(s.a, new models.DocumentParseUsage());
      assert.equal(result.bytes, 100); assert.equal(result.hash, crypto.createHash('sha256').update(zipBytes()).digest('hex')); assert.equal(result.status, 'UNVALIDATED');
      assert.deepEqual(files.get('/host/files/knowledge_parse_v1/result-unit'), zipBytes()); assert.equal(s.a.task.downloadBytes, 100); assert.equal(handles.size, 0);
    } },
    { name: 'result disk failure cannot publish and removes owned part', run: async () => {
      const s = setup('DISK'); await assert.rejects(s.adapter.receive(s.a, new models.DocumentParseUsage()));
      assert.equal(files.has('/host/files/knowledge_parse_v1/result-unit'), false); assert.equal(files.has('/host/cache/knowledge_parse_v1/part-unit'), false); assert.equal(handles.size, 0);
    } },
    ...['LENGTH', 'NO_END'].map(mode => ({ name: `result ${mode} cannot publish with missing completion or mismatched length`, run: async () => {
      const s = setup(mode); await assert.rejects(s.adapter.receive(s.a, new models.DocumentParseUsage()));
      assert.equal(files.has('/host/files/knowledge_parse_v1/result-unit'), false); assert.equal(handles.size, 0);
    } })),
    { name: 'result hard cap enforced before overflowing chunk is written', run: async () => {
      const s = setup(); const sink = await s.assets.resultSink(s.a, new models.DocumentParseUsage());
      await assert.rejects(sink.write(new ArrayBuffer(models.DocumentParseBudget.resultBytes + 1))); assert.equal(sink.actualBytes(), 0); await sink.abort();
      assert.equal(handles.size, 0);
    } },
    { name: 'lease original GCM layout decrypts with disk AAD even when requested issuedAt differs', run: async () => {
      const s = leaseSetup(); await s.store.sealLease(s.b, 'unit-nonsecret-address');
      assert.ok(!files.get('/host/files/knowledge_parse_v1/lease-unit').includes(Buffer.from('unit-nonsecret-address')));
      s.b.issuedAt = Date.now(); let consumed = false; await s.store.withLease(s.b, async address => { consumed = address === 'unit-nonsecret-address'; }); assert.equal(consumed, true);
    } },
    { name: 'lease tampered auth tag or mismatched grant revision never reaches consumer', run: async () => {
      for (const mode of ['TAG', 'REVISION']) {
        const s = leaseSetup(); await s.store.sealLease(s.b, 'unit-nonsecret-address');
        if (mode === 'TAG') { const b = files.get('/host/files/knowledge_parse_v1/lease-unit'); b[b.length - 1] ^= 1; } else { s.b.credentialRevision++; }
        let consumed = false; await assert.rejects(s.store.withLease(s.b, async () => { consumed = true; })); assert.equal(consumed, false);
      }
    } },
    { name: 'expired encrypted lease stops without consuming clear address', run: async () => {
      const s = leaseSetup(); s.b.issuedAt = Date.now() - 2000; s.b.expiresAt = Date.now() - 1; await s.store.sealLease(s.b, 'unit-nonsecret-address');
      let consumed = false; await assert.rejects(s.store.withLease(s.b, async () => { consumed = true; }), /过期/); assert.equal(consumed, false);
    } },
    { name: 'timeout late SDK callback cannot write bytes or publish a result', run: async () => {
      const s = setup('TIMEOUT'); await assert.rejects(s.adapter.receive(s.a, new models.DocumentParseUsage()), failure=>failure.detail.kind===models.ParseFailureKind.Network);
      await assert.rejects(lateDestination(new ArrayBuffer(100)), /迟到/);
      assert.equal(s.a.task.downloadBytes, 0); assert.equal(files.has('/host/files/knowledge_parse_v1/result-unit'), false); assert.equal(handles.size, 0);
    } },
    { name: 'progress callbacks expose supplied bytes separately from actual disk-written bytes', run: async () => {
      const s = setup(); const upload = []; const download = [];
      s.a.onProgress = () => { upload.push(s.a.task.uploadBytes); download.push(s.a.task.downloadBytes); };
      await s.adapter.upload(s.a); assert.ok(upload.some(n => n > 0 && n < s.a.original.bytes)); assert.equal(s.a.task.uploadBytes, s.a.original.bytes);
      await s.adapter.receive(s.a, new models.DocumentParseUsage()); assert.ok(download.includes(100)); assert.equal(s.a.task.downloadBytes, 100);
    } }
  ];
};
