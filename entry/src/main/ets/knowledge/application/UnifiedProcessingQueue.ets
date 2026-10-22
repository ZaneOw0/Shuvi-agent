import { ParsedRepositoryPort, ParsedAssetPort, ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { UnifiedProcessingRepositoryPort } from '../domain/UnifiedProcessingPorts';
import { ParsedDocument, ParsedCancellation, ParsedFailure, ParsedTextChunk } from '../domain/ParsedDocumentModels';
import { UnifiedProcessingJob, UnifiedProcessingAttempt, UnifiedProcessingSettings, UnifiedJobState, UnifiedJobOrigin, UnifiedTextInput, UnifiedInputKind, UNIFIED_TEXT_POLICY, UnifiedImageRecord } from '../domain/UnifiedKnowledgeModels';
import { VisionFailure } from '../domain/VisionModels';
import { ImageKnowledgeService } from './ImageKnowledgeService';
import { UnifiedEmbeddingService } from './UnifiedEmbeddingService';
import { parsedUtf8 } from '../pipeline/ParsedDocumentCodec';
import { parsedEncodeSnapshot } from '../pipeline/ParsedDocumentCodec';
import { ParsedUpgradeBatch, ParsedUpgradeTarget } from '../domain/ParsedMigrationModels';
import { unifiedProxyInputs, unifiedProxyText } from '../pipeline/UnifiedTextPolicy';

export class UnifiedProcessingQueue {
  private repository: UnifiedProcessingRepositoryPort; private documents: ParsedRepositoryPort; private assets: ParsedAssetPort; private identity: ParsedIdentityPort;
  private images: ImageKnowledgeService; private embedding: UnifiedEmbeddingService; private foreground: boolean=true; private paused: boolean=false;
  private visionRunning: Promise<void> | undefined; private embeddingRunning: Promise<void> | undefined; private cancellations: ParsedCancellation[]=[]; private listeners: Array<() => void>=[];
  private visionRequested: boolean=false; private embeddingRequested: boolean=false;
  private control: Promise<void>=Promise.resolve();
  private stopping: boolean=false;
  message: string='';
  private settled: (() => Promise<void>) | undefined;
  attachSettled(callback: () => Promise<void>): void { this.settled=callback; }
  constructor(repository: UnifiedProcessingRepositoryPort, documents: ParsedRepositoryPort, assets: ParsedAssetPort, identity: ParsedIdentityPort, images: ImageKnowledgeService, embedding: UnifiedEmbeddingService) { this.repository=repository; this.documents=documents; this.assets=assets; this.identity=identity; this.images=images; this.embedding=embedding; images.attachChanged((): void=> { this.kick(); this.emit(); }); }
  subscribe(listener: () => void): void { if (this.listeners.indexOf(listener)<0) { this.listeners.push(listener); } }
  unsubscribe(listener: () => void): void { this.listeners=this.listeners.filter((l: () => void): boolean=>l!==listener); }
  private emit(): void { for (const l of this.listeners) { l(); } }
  async jobs(): Promise<UnifiedProcessingJob[]> { return this.repository.jobs(); }
  async upgradeBatchIds(): Promise<string[]> { return this.repository.upgradeBatchIds(); }
  async loadUpgrade(id: string): Promise<ParsedUpgradeBatch> { const batch=await this.repository.upgradeBatch(id); if (batch===undefined) { throw new ParsedFailure('FrozenUpgradeMissing','upgrade'); } return batch; }
  async initialize(): Promise<void> {
    this.stopping=false; this.foreground=true;
    this.paused=await this.repository.meta('queue-paused')==='true';
    await this.repository.reconcileUnifiedOwners();
    for (const job of await this.repository.jobs()) {
      if (job.state===UnifiedJobState.Running) { const attempts=await this.repository.attempts(job.id); job.state=attempts.some((a: UnifiedProcessingAttempt): boolean=>a.launched && a.outcome==='InFlight')?UnifiedJobState.Unknown:UnifiedJobState.Paused; job.failure='PreviousProcessCheckpoint'; await this.repository.releaseProcessingJob(job,job.state===UnifiedJobState.Unknown); }
    }
    for (const document of await this.documents.list()) { if (!document.tombstone && !document.archived && document.activeGeneration.length>0 && ['Text','Pdf','Image','Docx'].indexOf(document.namespace)>=0) { await this.enqueue(await this.assets.readSnapshot(`${document.activeGeneration}-manifest`,new ParsedCancellation())); } }
    // Origin is persistent: opening settings/restarting cannot upgrade local history.
    for (const id of await this.repository.upgradeBatchIds()) { const batch=await this.repository.upgradeBatch(id); if (batch?.approved && !batch.paused) { try { await this.approveUpgrade(id,true); } catch { this.message='ApprovedUpgradeScopeChangedNeedsReview'; } } }
    this.kick();
  }
  async enqueue(document: ParsedDocument, origin: UnifiedJobOrigin=UnifiedJobOrigin.Import, batch: string=''): Promise<void> {
    const permit: ParsedUpgradeBatch | undefined=origin===UnifiedJobOrigin.ExplicitUpgrade?await this.repository.upgradeBatch(batch):undefined;
    if (origin===UnifiedJobOrigin.ExplicitUpgrade && permit!==undefined && !permit.approved) { throw new ParsedFailure('UpgradeNotApproved','queue'); }
    const record=await this.documents.get(document.documentKey); if (record===undefined || record.tombstone || record.activeGeneration!==document.generation) { return; }
    const chunks: ParsedTextChunk[]=await this.documents.chunks(record.id);
    if (chunks.length>0 && (permit===undefined || permit.embeddingRevision>0)) {
      const body: UnifiedProcessingJob=new UnifiedProcessingJob(); body.id='job-'+(await this.identity.hash(parsedUtf8(`body|${record.id}|${document.generation}|${origin}|${batch}`))).slice(0,40); body.dedupKey=body.id; body.documentKey=record.id; body.ownerId=record.id; body.version=document.generation; body.origin=origin; body.batchId=batch; body.epoch=record.epoch; body.settingsPurpose='Embedding'; body.stage='BodyEmbedding';
      for (const c of chunks) { const i: UnifiedTextInput=new UnifiedTextInput(); i.id=c.id; i.documentKey=c.documentKey; i.ownerId=record.id; i.version=c.generation; i.kind=c.evidence==='Ocr'?UnifiedInputKind.Ocr:UnifiedInputKind.Body; i.ordinal=c.ordinal; i.actualText=c.text; i.inputHash=c.inputHash; i.blockId=c.blockId; i.occurrenceId=c.occurrenceId; i.start=c.start; i.end=c.end; body.inputs.push(i); }
      body.expected=body.inputs.length; body.inputHash=await this.identity.hash(parsedUtf8(body.inputs.map((i: UnifiedTextInput): string=>i.id+'|'+i.inputHash).join('\n'))); await this.saveNew(body);
    }
    for (const image of await this.repository.imageRecords(record.id)) {
      if (permit!==undefined && permit.visionRevision===0) { continue; }
      const job: UnifiedProcessingJob=new UnifiedProcessingJob(); job.id='job-'+(await this.identity.hash(parsedUtf8(`vision|${image.occurrenceId}|${image.imageHash}|${origin}|${batch}`))).slice(0,40); job.dedupKey=job.id; job.documentKey=record.id; job.ownerId=image.occurrenceId; job.version=document.generation; job.assetId=image.assetId; job.occurrenceId=image.occurrenceId; job.inputHash=image.imageHash; job.expected=1; job.origin=origin; job.batchId=batch; job.epoch=record.epoch; job.stage='Vision'; job.settingsPurpose='Vision'; await this.saveNew(job);
    }
    this.kick(); this.emit();
  }
  private async saveNew(job: UnifiedProcessingJob): Promise<void> { if (!(await this.repository.jobs()).some((j: UnifiedProcessingJob): boolean=>j.id===job.id)) { await this.repository.saveJob(job); } }
  kick(): void {
    this.visionRequested=true; this.embeddingRequested=true;
    if (!this.foreground || this.paused || this.stopping) { return; }
    if (this.visionRunning===undefined) {
      this.visionRunning=this.runLane('Vision').catch((): void=> { this.message='VisionQueueCheckpointFailed'; }).then((): void=> { this.visionRunning=undefined; this.emit(); });
    }
    if (this.embeddingRunning===undefined) {
      this.embeddingRunning=this.runLane('Embedding').catch((): void=> { this.message='EmbeddingQueueCheckpointFailed'; }).then((): void=> { this.embeddingRunning=undefined; this.emit(); });
    }
  }
  private async waitRunning(): Promise<void> {
    while (this.visionRunning!==undefined || this.embeddingRunning!==undefined) {
      const active: Promise<void>[]=[];
      if (this.visionRunning!==undefined) { active.push(this.visionRunning); }
      if (this.embeddingRunning!==undefined) { active.push(this.embeddingRunning); }
      await Promise.all<void>(active);
    }
  }
  async drain(): Promise<void> { await this.control; this.kick(); await this.waitRunning(); }
  background(): void { this.foreground=false; }
  resumeForeground(): void { this.foreground=true; this.control=this.reactivatePaused().then((): void=> { this.kick(); }).catch((): void=> { this.message='ForegroundCheckpointUnavailable'; this.emit(); }); }
  pause(): void { this.paused=true; for (const c of this.cancellations) { c.invalid=true; } this.control=this.repository.putMeta('queue-paused','true').catch((): void=> { this.message='PauseCheckpointFailed'; }); this.emit(); }
  async stop(): Promise<void> { this.stopping=true; this.foreground=false; for (const c of this.cancellations) { c.invalid=true; } await this.control; await this.waitRunning(); }
  resume(): void { this.control=this.repository.putMeta('queue-paused','false').then(async (): Promise<void>=> { this.paused=false; this.foreground=true; await this.reactivatePaused(); this.kick(); }).catch((): void=> { this.message='ResumeCheckpointFailed'; }); }
  private async reactivatePaused(): Promise<void> {
    for (const job of await this.repository.jobs()) { if (job.state!==UnifiedJobState.Paused || job.origin===UnifiedJobOrigin.LocalMigration) { continue; }
      const attempts=await this.repository.attempts(job.id); if (attempts.some((a: UnifiedProcessingAttempt): boolean=>a.outcome==='InFlight' || a.outcome==='Unknown')) { continue; }
      job.state=UnifiedJobState.Pending; await this.repository.saveJob(job);
    }
  }
  async retry(id: string, acceptsCost: boolean): Promise<void> { if (!acceptsCost) { throw new ParsedFailure('ExplicitRetryCostRequired','queue'); } await this.repository.retryUnknown(id); this.kick(); }
  async freezeUpgrade(ids: string[]): Promise<ParsedUpgradeBatch> {
    if (ids.length===0 || new Set<string>(ids).size!==ids.length) { throw new ParsedFailure('UpgradeSelection','upgrade'); }
    const batch: ParsedUpgradeBatch=new ParsedUpgradeBatch(); batch.id=this.identity.id(); const vision=await this.repository.settings('Vision'); const embedding=await this.repository.settings('Embedding');
    if ((!vision.enabled || !vision.costAcknowledged) && (!embedding.enabled || !embedding.costAcknowledged)) { throw new ParsedFailure('UpgradeCostSettingsRequired','upgrade'); }
    batch.visionRevision=vision.enabled?vision.revision:0; batch.visionCostRevision=vision.enabled?vision.costRevision:0; batch.embeddingRevision=embedding.enabled?embedding.revision:0; batch.embeddingCostRevision=embedding.enabled?embedding.costRevision:0;
    for (const id of ids.slice().sort()) {
      const record=await this.documents.get(id); if (record===undefined || record.tombstone || record.archived || !record.namespace.startsWith('Legacy:') || record.activeGeneration.length===0) { throw new ParsedFailure('MigratedCurrentDocumentRequired','upgrade'); }
      const document=await this.assets.readSnapshot(`${record.activeGeneration}-manifest`,new ParsedCancellation()); const snapshot=await parsedEncodeSnapshot(document,this.identity,new ParsedCancellation(),async (): Promise<void>=>{});
      const t: ParsedUpgradeTarget=new ParsedUpgradeTarget(); t.documentKey=id; t.generation=record.activeGeneration; t.epoch=record.epoch; t.manifestHash=snapshot.manifest.contentHash;
      const chunks=await this.documents.chunks(id); t.bodyInputHash=await this.identity.hash(parsedUtf8(chunks.map((c: ParsedTextChunk): string=>c.id+'|'+c.inputHash).join('\n')));
      const images=await this.repository.imageRecords(id); t.images=images.map((r: UnifiedImageRecord): string=>r.occurrenceId+'|'+r.assetId+'|'+r.imageHash); t.annotations=images.map((r: UnifiedImageRecord): string=>r.occurrenceId+'|'+r.effectiveId); batch.targets.push(t);
    }
    batch.inputSetHash=await this.identity.hash(parsedUtf8(JSON.stringify(batch.targets))); await this.repository.saveUpgradeBatch(batch); return batch;
  }
  async approveUpgrade(id: string, possibleCost: boolean): Promise<void> {
    if (!possibleCost) { throw new ParsedFailure('ExplicitUpgradeCostRequired','upgrade'); } const batch=await this.repository.upgradeBatch(id); if (batch===undefined) { throw new ParsedFailure('FrozenUpgradeMissing','upgrade'); }
    await this.verifyUpgrade(batch); batch.approved=true; await this.repository.saveUpgradeBatch(batch);
    for (const target of batch.targets) {
      const document=await this.assets.readSnapshot(`${target.generation}-manifest`,new ParsedCancellation()); await this.enqueue(document,UnifiedJobOrigin.ExplicitUpgrade,batch.id);
      if (batch.embeddingRevision>0) { for (const record of await this.repository.imageRecords(target.documentKey)) {
        const annotation=await this.repository.annotation(record.effectiveId); if (annotation===undefined) { continue; }
        const inputs=await unifiedProxyInputs(record.documentKey,annotation.lineage,annotation.id,unifiedProxyText(annotation.description,annotation.tags),this.identity); if (inputs.length===0) { continue; }
        const job: UnifiedProcessingJob=new UnifiedProcessingJob(); job.id='job-'+(await this.identity.hash(parsedUtf8('proxy|'+annotation.lineage+'|'+annotation.id+'|ExplicitUpgrade|'+batch.id))).slice(0,40); job.dedupKey=job.id; job.documentKey=record.documentKey; job.ownerId=annotation.lineage; job.version=record.generation; job.assetId=record.assetId; job.occurrenceId=record.occurrenceId; job.annotationId=annotation.id; job.origin=UnifiedJobOrigin.ExplicitUpgrade; job.batchId=batch.id; job.stage='ImageEmbedding'; job.settingsPurpose='Embedding'; job.epoch=target.epoch; job.inputs=inputs; job.expected=inputs.length; job.inputHash=await this.identity.hash(parsedUtf8(inputs.map((i: UnifiedTextInput): string=>i.id+'|'+i.inputHash).join('\n'))); await this.saveNew(job);
      } }
    }
    this.kick();
  }
  async pauseUpgrade(id: string, paused: boolean): Promise<void> { const batch=await this.repository.upgradeBatch(id); if (batch===undefined || !batch.approved) { throw new ParsedFailure('FrozenUpgradeMissing','upgrade'); } if (!paused) { await this.verifyUpgrade(batch); } batch.paused=paused; await this.repository.saveUpgradeBatch(batch); if (!paused) { await this.approveUpgrade(id,true); for (const j of await this.jobs()) { if (j.batchId===id && j.state===UnifiedJobState.Paused && !(await this.repository.attempts(j.id)).some((a: UnifiedProcessingAttempt): boolean=>a.outcome==='Unknown' || a.outcome==='InFlight')) { await this.repository.retryUnknown(j.id); } } this.kick(); } }
  private async verifyUpgrade(batch: ParsedUpgradeBatch): Promise<void> {
    if (await this.identity.hash(parsedUtf8(JSON.stringify(batch.targets)))!==batch.inputSetHash) { throw new ParsedFailure('FrozenUpgradeHash','upgrade'); }
    const vision=await this.repository.settings('Vision'); const embedding=await this.repository.settings('Embedding');
    if (batch.visionRevision>0 && (!vision.enabled || !vision.costAcknowledged || vision.revision!==batch.visionRevision || vision.costRevision!==batch.visionCostRevision) || batch.embeddingRevision>0 && (!embedding.enabled || !embedding.costAcknowledged || embedding.revision!==batch.embeddingRevision || embedding.costRevision!==batch.embeddingCostRevision)) { throw new ParsedFailure('UpgradeSettingsChanged','upgrade'); }
    for (const target of batch.targets) { const doc=await this.documents.get(target.documentKey); if (doc===undefined || doc.tombstone || doc.archived || doc.epoch!==target.epoch || doc.activeGeneration!==target.generation) { throw new ParsedFailure('UpgradeScopeChanged','upgrade'); }
      const snapshot=await this.assets.readSnapshot(`${target.generation}-manifest`,new ParsedCancellation()); const manifest=await parsedEncodeSnapshot(snapshot,this.identity,new ParsedCancellation(),async (): Promise<void>=>{}); if (manifest.manifest.contentHash!==target.manifestHash) { throw new ParsedFailure('UpgradeManifestChanged','upgrade'); }
      const records=await this.repository.imageRecords(doc.id); if (JSON.stringify(records.map((r: UnifiedImageRecord): string=>r.occurrenceId+'|'+r.assetId+'|'+r.imageHash))!==JSON.stringify(target.images)) { throw new ParsedFailure('UpgradeImageOrAnnotationChanged','upgrade'); }
      for (const record of records) { if (target.annotations.indexOf(record.occurrenceId+'|'+record.effectiveId)>=0) { continue; }
        const annotation=await this.repository.annotation(record.effectiveId); const ownVision=(await this.repository.jobs()).some((j: UnifiedProcessingJob): boolean=>j.batchId===batch.id && j.stage==='Vision' && j.occurrenceId===record.occurrenceId && j.state===UnifiedJobState.Complete);
        if (!batch.approved || !ownVision || annotation===undefined || annotation.overlay.lineage.length>0) { throw new ParsedFailure('UpgradeAnnotationChanged','upgrade'); }
      }
    }
  }
  private async runLane(purpose: string): Promise<void> {
    // A newly imported image may start while a long corpus job is still running.
    // Each purpose owns one runner; query requests use neither corpus slot.
    do {
      if (purpose==='Vision') { this.visionRequested=false; } else { this.embeddingRequested=false; }
      await this.lane(purpose);
    } while ((purpose==='Vision'?this.visionRequested:this.embeddingRequested) && this.foreground && !this.paused && !this.stopping);
  }
  private async nextJob(purpose: string): Promise<UnifiedProcessingJob | undefined> {
    const jobs: UnifiedProcessingJob[]=await this.repository.jobs();
    for (const candidate of jobs) { if (candidate.settingsPurpose!==purpose || candidate.origin===UnifiedJobOrigin.LocalMigration || [UnifiedJobState.Pending,UnifiedJobState.AwaitingConfig].indexOf(candidate.state)<0) { continue; }
      if (candidate.origin===UnifiedJobOrigin.ExplicitUpgrade && (await this.repository.upgradeBatch(candidate.batchId))?.paused) { continue; }
      return candidate;
    }
    return undefined;
  }
  private async lane(purpose: string): Promise<void> {
    const until: number=Date.now()+900000;
    while (this.foreground && !this.paused && !this.stopping && Date.now()<until) {
      const settings: UnifiedProcessingSettings=await this.repository.settings(purpose);
      if (!settings.enabled || settings.paused || !settings.costAcknowledged || !settings.automatic) { return; }
      const job: UnifiedProcessingJob | undefined=await this.nextJob(purpose);
      if (job===undefined) { return; }
      const document=await this.repository.get(job.documentKey);
      const image: UnifiedImageRecord | undefined=job.stage==='Vision' || job.stage==='ImageEmbedding'?(await this.repository.imageRecords(job.documentKey)).find((r: UnifiedImageRecord): boolean=>r.occurrenceId===job.occurrenceId):undefined;
      if (document===undefined || document.tombstone || document.archived || document.activeGeneration!==job.version || document.epoch!==job.epoch || job.stage==='ImageEmbedding' && image?.effectiveId!==job.annotationId || job.stage==='Vision' && image===undefined) { job.state=UnifiedJobState.Canceled; job.failure='OwnerVersionNoLongerCurrent'; await this.repository.saveJob(job); continue; }
      if (purpose==='Embedding' && job.configBinding.length>0 && job.configBinding!==settings.configBinding && (await this.repository.attempts(job.id)).some((a: UnifiedProcessingAttempt): boolean=>a.launched)) {
        job.state=UnifiedJobState.Canceled; job.failure='ConfigChangedRetained'; await this.repository.saveJob(job);
        const replacement: UnifiedProcessingJob=new UnifiedProcessingJob(); replacement.id='job-'+(await this.identity.hash(parsedUtf8(job.id+'|'+settings.configBinding))).slice(0,40); replacement.dedupKey=replacement.id;
        replacement.documentKey=job.documentKey; replacement.ownerId=job.ownerId; replacement.version=job.version; replacement.inputHash=job.inputHash; replacement.origin=job.origin; replacement.batchId=job.batchId; replacement.stage=job.stage; replacement.settingsPurpose=job.settingsPurpose; replacement.epoch=job.epoch; replacement.expected=job.expected; replacement.inputs=job.inputs; replacement.assetId=job.assetId; replacement.occurrenceId=job.occurrenceId; replacement.annotationId=job.annotationId; replacement.configBinding=settings.configBinding; replacement.state=UnifiedJobState.AwaitingConfig;
        await this.saveNew(replacement); this.emit(); continue;
      }
      job.settingsRevision=settings.revision; job.costRevision=settings.costRevision; job.credentialRevision=settings.credentialRevision; job.configBinding=settings.configBinding; job.state=UnifiedJobState.Running; await this.repository.saveJob(job);
      const cancel: ParsedCancellation=new ParsedCancellation(); cancel.deadline=until; this.cancellations.push(cancel); let launched: boolean=false; let receipt: string=''; let last: UnifiedProcessingAttempt | undefined;
      const admit=async (hash: string, launch: () => void): Promise<void>=> {
        cancel.check(); if (!this.foreground || this.paused) { throw new ParsedFailure('DispatchPaused','queue'); }
        const attempt: UnifiedProcessingAttempt=new UnifiedProcessingAttempt(); attempt.id=this.identity.id(); attempt.jobId=job.id; attempt.inputHash=hash; attempt.settingsRevision=job.settingsRevision; attempt.costRevision=job.costRevision; last=attempt;
        let dispatched: boolean=false;
        try {
          await this.repository.admitAttempt(job,attempt,(): void=> { cancel.check(); if (!this.foreground || this.paused) { throw new ParsedFailure('DispatchPaused','queue'); } dispatched=true; launched=true; launch(); });
        } catch (error) {
          // Admission persists InFlight before invoking launch. A foreground change
          // during that write is a proven no-send, not an unknown network result.
          if (!dispatched) {
            const stored=(await this.repository.attempts(job.id)).find((a: UnifiedProcessingAttempt): boolean=>a.id===attempt.id);
            if (stored?.outcome==='InFlight') { stored.outcome='NotSent'; stored.receipt='DispatchNotLaunched'; await this.repository.saveAttempt(stored); }
          }
          if (error instanceof Error) { throw error; }
          throw new ParsedFailure('AdmissionFailed','queue');
        }
      };
      try {
        await this.repository.holdProcessingJob(job);
        if (purpose==='Vision') { receipt=await this.images.process(job,cancel,async (launch: () => void): Promise<void>=> { await admit(job.inputHash,launch); }); job.completed=1; }
        else { await this.embedding.process(job,cancel,admit); }
        job.state=UnifiedJobState.Complete; job.failure='';
        if (last!==undefined && purpose==='Vision') { last.outcome='Received'; last.receipt=receipt; await this.repository.saveAttempt(last); }
      } catch (error) {
        const pending: boolean=(await this.repository.attempts(job.id)).some((a: UnifiedProcessingAttempt): boolean=>a.outcome==='InFlight');
        job.state=launched && pending?UnifiedJobState.Unknown:cancel.invalid || !this.foreground || this.paused?UnifiedJobState.Paused:UnifiedJobState.Failed;
        if (error instanceof VisionFailure && (error.stage==='response' || error.stage==='auth')) { job.state=UnifiedJobState.Failed; }
        job.failure=error instanceof ParsedFailure || error instanceof VisionFailure?error.category:'RequestOrReadbackUnknown';
        if (last!==undefined && last.launched) { const stored=(await this.repository.attempts(job.id)).find((a: UnifiedProcessingAttempt): boolean=>a.id===last?.id); if (stored?.outcome==='InFlight') { last.outcome=job.state; await this.repository.saveAttempt(last); } }
      } finally { this.cancellations=this.cancellations.filter((c: ParsedCancellation): boolean=>c!==cancel); try { await this.repository.releaseProcessingJob(job,job.state===UnifiedJobState.Unknown); } catch { job.resourcePhase='ReleasePending'; this.message='JobReleaseCheckpointPending'; await this.repository.saveJob(job); } await this.repository.reconcileUnifiedOwners(); try { await this.settled?.(); } catch { this.message='LocalMirrorPending'; } this.emit(); }
    }
  }
}
