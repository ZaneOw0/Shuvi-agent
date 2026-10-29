import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { KnowledgeVectorPort } from '../domain/KnowledgePorts';
import { EmbeddingSpace, KnowledgeVectorRow, KnowledgeVectorCandidate } from '../domain/EmbeddingModels';
import { KnowledgeCancellation, KnowledgeCleanupIntent, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { embeddingValidateVector } from '../pipeline/EmbeddingPolicy';
import { embeddingSpaceCopy, embeddingSpaceDecode } from '../pipeline/EmbeddingSpacePolicy';
import { VectorEligibility, VectorWorkflowStorePort } from '../domain/VectorWorkflowModels';
import { KnowledgeVectorCleanupPort } from '../application/KnowledgeLifecycleService';
import { KnowledgeCapabilityAudit, CapabilityAuditGate } from './KnowledgeCapabilityAudit';
import { UnifiedNumericVectorPort } from '../domain/UnifiedEmbeddingPorts';
import { UnifiedQueryNumericPort } from '../domain/UnifiedQueryPorts';
import { UnifiedQueryTarget } from '../domain/UnifiedQueryModels';
import { ParsedCancellation } from '../domain/ParsedDocumentModels';

function vectorTableId(spaceId: string): string {
  if (!new RegExp('^kb-[a-f0-9]{32}$').test(spaceId)) { throw new KnowledgeFailure('UnregisteredSpaceId','vector-store'); }
  return 'v_'+spaceId.slice(3);
}
function vectorNumbers(values: Float32Array): number[] { const result: number[] = []; for (const value of values) { result.push(value); } return result; }
function vectorLayout(space: EmbeddingSpace): string { return `CREATE TABLE ${vectorTableId(space.id)} (chunk TEXT,generation TEXT,doc TEXT,content_generation TEXT,input_hash TEXT,epoch INTEGER,eligible INTEGER,embedding FLOATVECTOR(${space.dimension}),PRIMARY KEY(chunk,generation))`; }
export class VectorRdbRepository implements KnowledgeVectorPort, VectorWorkflowStorePort, KnowledgeVectorCleanupPort, UnifiedNumericVectorPort, UnifiedQueryNumericPort {
  private static selfCheck: Promise<void> | undefined;
  private static auditGate: CapabilityAuditGate = new CapabilityAuditGate();
  private static checkSequence: number = 0;
  private context: common.Context; private scope: KnowledgeStorageScope;
  private store: relationalStore.RdbStore | undefined = undefined;
  private spaces: Map<string,EmbeddingSpace> = new Map<string,EmbeddingSpace>();
  private unavailable: Map<string,string> = new Map<string,string>();
  private tail: Promise<void> = Promise.resolve(); private status: string = 'NotChecked';
  private fault: string = '';
  constructor(context: common.Context, scope: KnowledgeStorageScope = KnowledgeStorageScope.production()) { this.context = context; this.scope = scope; }
  capability(): string { return this.status; }
  injectFault(owner: string, stage: string): void { this.scope.requireTestOwner(owner); this.fault = stage; }
  private boundary(stage: string): void { if (this.fault === stage) { this.fault = ''; throw new KnowledgeFailure(`Injected${stage}`,'vector-store'); } }
  async open(): Promise<void> {
    if (!this.scope.testing) {
      if (VectorRdbRepository.selfCheck === undefined) { VectorRdbRepository.selfCheck = VectorRdbRepository.checkSession(this.context); }
      const selfCheck: Promise<void> = VectorRdbRepository.selfCheck;
      await selfCheck;
    }
    await this.write<void>(async (): Promise<void> => {
      if (this.store !== undefined) { return; } this.status = 'Checking';
      if (!relationalStore.isVectorSupported()) { this.status = 'Unavailable'; throw new KnowledgeFailure('VectorStoreUnsupported','vector-store'); }
      const config: relationalStore.StoreConfig = { name: this.scope.vectorDatabaseName, securityLevel: relationalStore.SecurityLevel.S3, vector: true };
      try {
        this.store = await relationalStore.getRdbStore(this.context,config);
        await this.requireStore().execute('CREATE TABLE IF NOT EXISTS vector_space_registry_v2 (id TEXT PRIMARY KEY,fingerprint TEXT,dimension INTEGER,wire TEXT)');
        await this.requireStore().execute('CREATE TABLE IF NOT EXISTS vector_retired (id TEXT PRIMARY KEY)');
        await this.requireStore().execute('CREATE TABLE IF NOT EXISTS vector_creation_v1 (id TEXT PRIMARY KEY,wire TEXT,phase TEXT)');
        const pending = await this.requireStore().querySql('SELECT wire FROM vector_creation_v1 WHERE phase=?',['Planned']); const recovering: EmbeddingSpace[] = [];
        try { while (pending.goToNextRow()) { recovering.push(embeddingSpaceDecode(pending.getString(0))); } } finally { pending.close(); }
        for (const space of recovering) { await this.completeCreation(space); }
        const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT id,fingerprint,dimension,wire FROM vector_space_registry_v2');
        const restored: EmbeddingSpace[] = [];
        try {
          while (rows.goToNextRow()) {
            const space: EmbeddingSpace = embeddingSpaceDecode(rows.getString(3));
            if (space.id !== rows.getString(0) || space.fingerprint !== rows.getString(1) || space.dimension !== rows.getLong(2)) { throw new KnowledgeFailure('SpaceRegistryMismatch','vector-open'); }
            restored.push(space); if (restored.length > 1000) { throw new KnowledgeFailure('SpaceRegistryBudget','vector-open'); }
          }
        } finally { rows.close(); }
        for (const space of restored) {
          this.spaces.set(space.id,space);
          try { await this.verifyLayout(space); }
          catch (error) { this.unavailable.set(space.id,error instanceof KnowledgeFailure ? error.category : 'VectorLayoutProbeFailed'); }
        }
        this.status = 'Available';
      } catch (error) {
        this.status = 'Failed'; this.spaces.clear(); this.unavailable.clear();
        if (this.store !== undefined) { await this.store.close(); this.store = undefined; }
        if (error instanceof Error) { throw error; } throw new KnowledgeFailure('VectorOpenFailed','vector-store');
      }
    });
  }
  private static async checkSession(context: common.Context): Promise<void> {
    const audit = new KnowledgeCapabilityAudit(context); const descriptor = await audit.identity('Vector','VECTOR-SESSION-3','R2-VECTOR-1');
    await VectorRdbRepository.auditGate.require(audit,descriptor,async (): Promise<void> => {
    const key: string = (Date.now()+VectorRdbRepository.checkSequence++).toString(16).padStart(16,'0'); const scope: KnowledgeStorageScope = KnowledgeStorageScope.isolated(key);
    let repository: VectorRdbRepository = new VectorRdbRepository(context,scope);
    const space: EmbeddingSpace = new EmbeddingSpace(); space.id = 'kb-'+key.repeat(2); space.fingerprint = 'VECTOR-SESSION-2'; space.dimension = 3;
    try {
      await repository.open(); await repository.register(space); const row: KnowledgeVectorRow = new KnowledgeVectorRow(); row.spaceId = space.id; row.chunkId = 'selfcheck'; row.vectorGeneration = 'selfcheck'; row.documentId = 'selfcheck'; row.contentGeneration = 'selfcheck'; row.inputHash = '0'.repeat(64); row.eligible = true; row.values = new Float32Array([1,0,0]); await repository.put(row);
      const hits = await repository.knn(space,row.values,1,new KnowledgeCancellation()); if (hits.length !== 1 || Math.abs(hits[0].distance) > 0.00001) { throw new KnowledgeFailure('VectorSessionKnnFailed','vector-capability'); }
      await repository.close(); repository = new VectorRdbRepository(context,scope); await repository.open(); const read = await repository.read(space.id,row.chunkId,row.vectorGeneration); if (read === undefined || read.values[0] !== 1) { throw new KnowledgeFailure('VectorSessionReopenFailed','vector-capability'); }
    } finally { try { await repository.close(); const config: relationalStore.StoreConfig = { name: scope.vectorDatabaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: true }; await relationalStore.deleteRdbStore(context,config); } catch { throw new KnowledgeFailure('VectorSelfCheckReleaseUnconfirmed','capability'); } }
    });
  }
  private async verifyLayout(space: EmbeddingSpace): Promise<void> {
    const probe: Float32Array = new Float32Array(space.dimension); probe[0] = 1;
    const store = this.requireStore(); const transaction: number = await store.beginTrans();
    try {
      // A reserved identity is never committed or exposed to KNN. VALUES also
      // rejects an altered column count; explicit names check the required layout.
      await store.execute(`INSERT INTO ${vectorTableId(space.id)} VALUES(?,?,?,?,?,?,?,?)`,transaction,['__schema_probe__','__schema_probe__','__schema_probe__','__schema_probe__','0'.repeat(64),0,0,probe]);
      await store.execute(`UPDATE ${vectorTableId(space.id)} SET doc=?,content_generation=?,input_hash=?,epoch=?,eligible=?,embedding=? WHERE chunk=? AND generation=?`,transaction,['__schema_probe__','__schema_probe__','0'.repeat(64),0,0,probe,'__schema_probe__','__schema_probe__']);
      const wrong: Float32Array = new Float32Array(space.dimension === 4096 ? 4095 : space.dimension+1); wrong[0] = 1; let rejected: boolean = false;
      try { await store.execute(`INSERT INTO ${vectorTableId(space.id)} VALUES(?,?,?,?,?,?,?,?)`,transaction,['__schema_wrong__','__schema_probe__','','','',0,0,wrong]); } catch { rejected = true; }
      if (!rejected) { throw new KnowledgeFailure('VectorFixedDimensionNotEnforced','vector-open'); }
    } finally { await store.rollback(transaction); }
    const rows = await store.querySql(`SELECT count(*) FROM ${vectorTableId(space.id)} WHERE chunk IN (?,?)`,['__schema_probe__','__schema_wrong__']);
    try { if (!rows.goToNextRow() || rows.getLong(0) !== 0) { throw new KnowledgeFailure('VectorSchemaProbeRollbackUnconfirmed','vector-open'); } } finally { rows.close(); }
  }
  private async completeCreation(space: EmbeddingSpace): Promise<void> {
    const store = this.requireStore();
    await store.execute(vectorLayout(space).replace('CREATE TABLE ','CREATE TABLE IF NOT EXISTS ')); this.boundary('AfterDdl');
    await this.verifyLayout(space); const transaction: number = await store.beginTrans();
    try { await store.execute('INSERT INTO vector_space_registry_v2 VALUES(?,?,?,?)',transaction,[space.id,space.fingerprint,space.dimension,JSON.stringify(space)]); await store.execute('UPDATE vector_creation_v1 SET phase=? WHERE id=?',transaction,['Active',space.id]); this.boundary('Register'); await store.commit(transaction); }
    catch (error) { await store.rollback(transaction); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('SpaceRegistrationFailed','vector-store'); }
  }
  private requireStore(): relationalStore.RdbStore { if (this.store === undefined) { throw new KnowledgeFailure('VectorStoreUnavailable','vector-store'); } return this.store; }
  private write<T>(action: () => Promise<T>): Promise<T> { const result: Promise<T> = this.tail.then(action); this.tail = result.then((): void => {},(_error: Error): void => {}); return result; }
  async register(input: EmbeddingSpace): Promise<void> {
    const space: EmbeddingSpace = embeddingSpaceCopy(input);
    await this.write<void>(async (): Promise<void> => {
      const existing: EmbeddingSpace | undefined = this.spaces.get(space.id);
      if (existing !== undefined) { if (JSON.stringify(existing) !== JSON.stringify(space)) { throw new KnowledgeFailure('SpaceIdentityConflict','vector-store'); } return; }
      const store: relationalStore.RdbStore = this.requireStore();
      const rows = await store.querySql('SELECT wire,phase FROM vector_creation_v1 WHERE id=?',[space.id]); let planned: boolean = false;
      try { if (rows.goToNextRow()) { if (rows.getString(0) !== JSON.stringify(space) || rows.getString(1) !== 'Planned') { throw new KnowledgeFailure('SpaceCreationIdentityConflict','register'); } planned = true; } } finally { rows.close(); }
      if (!planned) { await store.execute('INSERT INTO vector_creation_v1 VALUES(?,?,?)',[space.id,JSON.stringify(space),'Planned']); }
      this.boundary('BeforeDdl'); await this.completeCreation(space); this.spaces.set(space.id,space);
    });
  }
  registeredSpaces(): EmbeddingSpace[] { const result: EmbeddingSpace[] = []; this.spaces.forEach((space: EmbeddingSpace): void => { if (!this.unavailable.has(space.id)) { result.push(embeddingSpaceCopy(space)); } }); return result; }
  private space(id: string): EmbeddingSpace { const reason: string | undefined = this.unavailable.get(id); if (reason !== undefined) { throw new KnowledgeFailure(reason,'vector-store'); } const space: EmbeddingSpace | undefined = this.spaces.get(id); if (space === undefined) { throw new KnowledgeFailure('UnregisteredSpace','vector-store'); } return space; }
  spaceFailure(id: string): string { return this.unavailable.get(id) ?? ''; }
  async put(row: KnowledgeVectorRow): Promise<void> {
    const space: EmbeddingSpace = this.space(row.spaceId); embeddingValidateVector(vectorNumbers(row.values),space.dimension);
    await this.write<void>(async (): Promise<void> => {
      const store: relationalStore.RdbStore = this.requireStore(); const transaction: number = await store.beginTrans();
      try { await store.execute(`INSERT OR REPLACE INTO ${vectorTableId(space.id)} VALUES(?,?,?,?,?,?,?,?)`,transaction,[row.chunkId,row.vectorGeneration,row.documentId,row.contentGeneration,row.inputHash,row.epoch,row.eligible ? 1 : 0,row.values]); this.boundary('Put'); await store.commit(transaction); }
      catch (error) { await store.rollback(transaction); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('VectorWriteFailed','vector-store'); }
    });
    const readback: KnowledgeVectorRow | undefined = await this.read(space.id,row.chunkId,row.vectorGeneration);
    if (readback === undefined || readback.spaceId !== row.spaceId || readback.chunkId !== row.chunkId || readback.documentId !== row.documentId || readback.vectorGeneration !== row.vectorGeneration || readback.inputHash !== row.inputHash || readback.contentGeneration !== row.contentGeneration || readback.epoch !== row.epoch || readback.eligible !== row.eligible || readback.values.length !== row.values.length || readback.values.some((value: number,index: number): boolean => value !== row.values[index])) { throw new KnowledgeFailure('VectorReadbackMismatch','vector-store'); }
  }
  private row(rows: relationalStore.ResultSet, space: EmbeddingSpace): KnowledgeVectorRow {
    const row: KnowledgeVectorRow = new KnowledgeVectorRow(); row.spaceId = space.id; row.chunkId = rows.getString(0); row.vectorGeneration = rows.getString(1); row.documentId = rows.getString(2); row.contentGeneration = rows.getString(3); row.inputHash = rows.getString(4); row.epoch = rows.getLong(5); row.eligible = rows.getLong(6) === 1;
    const raw: relationalStore.ValueType = rows.getValue(7);
    if (!(raw instanceof Float32Array)) { throw new KnowledgeFailure('VectorReadbackType','vector-store'); } row.values = embeddingValidateVector(vectorNumbers(raw),space.dimension); return row;
  }
  async read(spaceId: string, chunkId: string, vectorGeneration: string): Promise<KnowledgeVectorRow | undefined> {
    return this.write<KnowledgeVectorRow | undefined>(async (): Promise<KnowledgeVectorRow | undefined> => {
      const space: EmbeddingSpace = this.space(spaceId); const rows: relationalStore.ResultSet = await this.requireStore().querySql(`SELECT * FROM ${vectorTableId(spaceId)} WHERE chunk=? AND generation=?`,[chunkId,vectorGeneration]);
      try { return rows.goToNextRow() ? this.row(rows,space) : undefined; } finally { rows.close(); }
    });
  }
  async knn(space: EmbeddingSpace, query: Float32Array, limit: number, cancel: KnowledgeCancellation): Promise<KnowledgeVectorCandidate[]> {
    return this.write<KnowledgeVectorCandidate[]>(async (): Promise<KnowledgeVectorCandidate[]> => {
      const registered: EmbeddingSpace = this.space(space.id);
      if (JSON.stringify(embeddingSpaceCopy(space)) !== JSON.stringify(registered) || !Number.isSafeInteger(limit) || limit < 1 || limit > 20) { throw new KnowledgeFailure('KnnSpaceMismatch','vector-store'); }
      const vector: Float32Array = embeddingValidateVector(vectorNumbers(query),registered.dimension); cancel.check();
      const rows: relationalStore.ResultSet = await this.requireStore().querySql(`SELECT *,embedding <=> ? AS distance FROM ${vectorTableId(space.id)} WHERE eligible=1 ORDER BY embedding <=> ? LIMIT ${limit}`,[vector,vector]);
      const candidates: KnowledgeVectorCandidate[] = [];
      try { while (rows.goToNextRow()) { cancel.check(); const candidate: KnowledgeVectorCandidate = new KnowledgeVectorCandidate(); candidate.row = this.row(rows,registered); candidate.distance = rows.getDouble(8); if (!Number.isFinite(candidate.distance)) { throw new KnowledgeFailure('KnnDistanceInvalid','vector-store'); } candidates.push(candidate); } } finally { rows.close(); } return candidates;
    });
  }
  async remove(claim: KnowledgeCleanupIntent): Promise<void> {
    if (claim.claim.length === 0 || claim.vectorTargets.length === 0) { throw new KnowledgeFailure('CleanupClaimRequired','vector-store'); }
    for (const target of claim.vectorTargets) { await this.removeTarget(claim,target.spaceId,target.vectorGeneration); }
  }
  async synchronize(target: VectorEligibility): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      const store: relationalStore.RdbStore = this.requireStore(); const transaction: number = await store.beginTrans();
      try {
        for (const space of this.registeredSpaces()) { if (!this.unavailable.has(space.id)) { await store.execute(`UPDATE ${vectorTableId(space.id)} SET eligible=0 WHERE doc=?`,transaction,[target.documentId]); } }
        await store.execute(`UPDATE ${vectorTableId(this.space(target.spaceId).id)} SET eligible=1,epoch=? WHERE doc=? AND content_generation=? AND generation=?`,transaction,[target.epoch,target.documentId,target.contentGeneration,target.vectorGeneration]); this.boundary('Mirror'); await store.commit(transaction);
      } catch (error) { await store.rollback(transaction); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('VectorMirrorFailed','vector-store'); }
    });
  }
  async synchronizeUnified(spaceId: string, owner: string, content: string, generation: string, epoch: number): Promise<void> {
    if (!owner.startsWith('upd:') || this.space(spaceId).preprocessing!=='UNIFIED-KNOWLEDGE-TEXT-1') { throw new KnowledgeFailure('UnifiedOwnerOrSpaceRequired','mirror'); }
    await this.write<void>(async (): Promise<void>=> { const store=this.requireStore(); const tx: number=await store.beginTrans();
      try { await store.execute(`UPDATE ${vectorTableId(spaceId)} SET eligible=0 WHERE doc=?`,tx,[owner]); await store.execute(`UPDATE ${vectorTableId(spaceId)} SET eligible=1,epoch=? WHERE doc=? AND content_generation=? AND generation=?`,tx,[epoch,owner,content,generation]); await store.commit(tx); }
      catch (error) { await store.rollback(tx); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('UnifiedMirrorFailed','mirror'); }
    });
  }
  async revokeUnified(spaceId: string, owner: string): Promise<void> {
    if (!owner.startsWith('upd:') || this.space(spaceId).preprocessing!=='UNIFIED-KNOWLEDGE-TEXT-1') { throw new KnowledgeFailure('UnifiedOwnerOrSpaceRequired','revoke'); }
    await this.write<void>(async (): Promise<void>=> { await this.requireStore().execute(`UPDATE ${vectorTableId(spaceId)} SET eligible=0 WHERE doc=?`,[owner]); });
  }
  async filteredKnn(space: EmbeddingSpace, query: Float32Array, targets: VectorEligibility[], cancel: KnowledgeCancellation): Promise<KnowledgeVectorCandidate[]> {
    return this.write<KnowledgeVectorCandidate[]>(async (): Promise<KnowledgeVectorCandidate[]> => {
      const registered: EmbeddingSpace = this.space(space.id); if (JSON.stringify(embeddingSpaceCopy(space)) !== JSON.stringify(registered)) { throw new KnowledgeFailure('KnnSpaceMismatch','vector-store'); }
      const vector: Float32Array = embeddingValidateVector(vectorNumbers(query),registered.dimension); const candidates: KnowledgeVectorCandidate[] = [];
      // Each bounded partition filters before exact distance sorting. Merging its
      // top20 is equivalent to a global top20, unlike filtering a stale top20.
      for (let start: number = 0; start < targets.length; start += 64) {
        cancel.check(); const conditions: string[] = []; const args: relationalStore.ValueType[] = [vector];
        for (const target of targets.slice(start,start+64)) { if (target.spaceId !== space.id || target.chunkIds.length !== 1) { throw new KnowledgeFailure('KnnAuthorityInvalid','query'); } conditions.push('(chunk=? AND generation=? AND doc=? AND content_generation=? AND epoch=? AND input_hash=?)'); args.push(target.chunkIds[0],target.vectorGeneration,target.documentId,target.contentGeneration,target.epoch,target.inputHash); }
        args.push(vector);
        const rows = await this.requireStore().querySql(`SELECT *,embedding <=> ? AS distance FROM ${vectorTableId(space.id)} WHERE eligible=1 AND (${conditions.join(' OR ')}) ORDER BY embedding <=> ? LIMIT 20`,args);
        try { while (rows.goToNextRow()) { cancel.check(); const item: KnowledgeVectorCandidate = new KnowledgeVectorCandidate(); item.row = this.row(rows,registered); item.distance = rows.getDouble(8); if (!Number.isFinite(item.distance)) { throw new KnowledgeFailure('KnnDistanceInvalid','query'); } candidates.push(item); } } finally { rows.close(); }
        candidates.sort((a: KnowledgeVectorCandidate,b: KnowledgeVectorCandidate): number => a.distance-b.distance || a.row.chunkId.localeCompare(b.row.chunkId)); if (candidates.length > 20) { candidates.splice(20); }
      } return candidates;
    });
  }
  async filteredKnnAll(space: EmbeddingSpace, query: Float32Array, targets: UnifiedQueryTarget[], cancel: ParsedCancellation): Promise<KnowledgeVectorCandidate[]> {
    return this.write<KnowledgeVectorCandidate[]>(async (): Promise<KnowledgeVectorCandidate[]>=> {
      const registered: EmbeddingSpace=this.space(space.id);
      if (space.preprocessing!=='UNIFIED-KNOWLEDGE-TEXT-1' || JSON.stringify(embeddingSpaceCopy(space))!==JSON.stringify(registered) || targets.length>30000) { throw new KnowledgeFailure('UnifiedKnnScope','query'); }
      const vector: Float32Array=embeddingValidateVector(vectorNumbers(query),registered.dimension); const candidates: KnowledgeVectorCandidate[]=[];
      for (let start: number=0;start<targets.length;start+=64) {
        cancel.check(); const conditions: string[]=[]; const args: relationalStore.ValueType[]=[vector];
        for (const input of targets.slice(start,start+64)) { const target=input.qualification; if (target.spaceId!==space.id || target.chunkIds.length!==1 || !target.documentId.startsWith('upd:')) { throw new KnowledgeFailure('UnifiedKnnTargetIdentity','query'); } conditions.push('(chunk=? AND generation=? AND doc=? AND content_generation=? AND epoch=? AND input_hash=?)'); args.push(target.chunkIds[0],target.vectorGeneration,target.documentId,target.contentGeneration,target.epoch,target.inputHash); }
        const rows=await this.requireStore().querySql(`SELECT *,embedding <=> ? AS distance FROM ${vectorTableId(space.id)} WHERE eligible=1 AND (${conditions.join(' OR ')}) ORDER BY distance,doc,chunk,generation`,args);
        try { while (rows.goToNextRow()) { cancel.check(); const c: KnowledgeVectorCandidate=new KnowledgeVectorCandidate(); c.row=this.row(rows,registered); c.distance=rows.getDouble(8); if (!Number.isFinite(c.distance)) { throw new KnowledgeFailure('UnifiedKnnDistance','query'); } candidates.push(c); if (candidates.length>30000) { throw new KnowledgeFailure('UnifiedKnnCandidateBudget','query'); } } } finally { rows.close(); }
      }
      candidates.sort((a: KnowledgeVectorCandidate,b: KnowledgeVectorCandidate): number=>a.distance-b.distance || a.row.documentId.localeCompare(b.row.documentId) || a.row.chunkId.localeCompare(b.row.chunkId) || a.row.vectorGeneration.localeCompare(b.row.vectorGeneration)); return candidates;
    });
  }
  async trialKnn(space: EmbeddingSpace, query: Float32Array, targets: VectorEligibility[], cancel: KnowledgeCancellation): Promise<KnowledgeVectorCandidate[]> {
    return this.write<KnowledgeVectorCandidate[]>(async (): Promise<KnowledgeVectorCandidate[]> => {
      const registered = this.space(space.id); if (JSON.stringify(embeddingSpaceCopy(space)) !== JSON.stringify(registered) || targets.length !== 3 || new Set<string>(targets.map((target: VectorEligibility): string => target.chunkIds[0])).size !== 3) { throw new KnowledgeFailure('TrialKnnScopeInvalid','trial-query'); }
      const vector = embeddingValidateVector(vectorNumbers(query),registered.dimension); cancel.check();
      const conditions: string[] = []; const args: relationalStore.ValueType[] = [vector];
      for (const target of targets) { if (target.spaceId !== space.id || target.chunkIds.length !== 1) { throw new KnowledgeFailure('TrialKnnSpaceMismatch','trial-query'); } conditions.push('(chunk=? AND generation=? AND doc=? AND content_generation=? AND epoch=? AND input_hash=?)'); args.push(target.chunkIds[0],target.vectorGeneration,target.documentId,target.contentGeneration,target.epoch,target.inputHash); }
      args.push(vector);
      const rows = await this.requireStore().querySql(`SELECT *,embedding <=> ? AS distance FROM ${vectorTableId(space.id)} WHERE eligible=0 AND (${conditions.join(' OR ')}) ORDER BY embedding <=> ? LIMIT 3`,args); const result: KnowledgeVectorCandidate[] = [];
      try { while (rows.goToNextRow()) { cancel.check(); const item = new KnowledgeVectorCandidate(); item.row = this.row(rows,registered); item.distance = rows.getDouble(8); if (!Number.isFinite(item.distance)) { throw new KnowledgeFailure('TrialDistanceInvalid','trial-query'); } result.push(item); } } finally { rows.close(); }
      if (result.length !== 3) { throw new KnowledgeFailure('TrialKnnCoverageChanged','trial-query'); } result.sort((a: KnowledgeVectorCandidate,b: KnowledgeVectorCandidate): number => a.distance-b.distance || a.row.chunkId.localeCompare(b.row.chunkId)); return result;
    });
  }
  async removeTarget(claim: KnowledgeCleanupIntent, spaceId: string, generation: string): Promise<void> {
    if (claim.claim.length === 0 || !claim.vectorTargets.some((target): boolean => target.spaceId === spaceId && target.vectorGeneration === generation && target.contentGeneration === claim.generation)) { throw new KnowledgeFailure('VectorCleanupTargetClaimRequired','vector-store'); }
    await this.write<void>(async (): Promise<void> => {
      this.boundary('Remove'); const store: relationalStore.RdbStore = this.requireStore();
      if (!this.spaces.has(spaceId)) { const retired = await store.querySql('SELECT id FROM vector_retired WHERE id=?',[spaceId]); try { if (retired.goToNextRow()) { return; } } finally { retired.close(); } throw new KnowledgeFailure('CleanupSpaceRegistryMissing','vector-cleanup'); }
      const table: string = vectorTableId(spaceId);
      await store.execute(`DELETE FROM ${table} WHERE generation=? AND content_generation=? AND doc=?`,[generation,claim.generation,claim.documentId]);
      const rows = await store.querySql(`SELECT count(*) FROM ${table}`); let empty: boolean = false; try { empty = rows.goToNextRow() && rows.getLong(0) === 0; } finally { rows.close(); }
      if (empty) {
        const transaction: number = await store.beginTrans();
        try { await store.execute('INSERT OR REPLACE INTO vector_retired VALUES(?)',transaction,[spaceId]); await store.execute('DELETE FROM vector_space_registry_v2 WHERE id=?',transaction,[spaceId]); await store.commit(transaction); }
        catch (error) { await store.rollback(transaction); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('VectorRetirementUnconfirmed','cleanup'); }
        // Empty retired tables remain physical accounted overhead. DDL is not
        // transactional on this Kit, so do not drop before the durable receipt.
        this.spaces.delete(spaceId); this.unavailable.delete(spaceId);
      }
    });
  }
  async close(): Promise<void> { await this.write<void>(async (): Promise<void> => { this.status = 'Releasing'; this.boundary('Close'); if (this.store !== undefined) { await this.store.close(); this.store = undefined; this.spaces.clear(); this.unavailable.clear(); } this.status = 'NotChecked'; }); }
}
