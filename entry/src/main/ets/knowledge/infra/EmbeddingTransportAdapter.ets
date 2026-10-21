import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { EmbeddingTransportPort, KnowledgeIdentityPort, KnowledgeQueryAdmissionPort } from '../domain/KnowledgePorts';
import { QueryConsentSnapshot } from '../domain/EmbeddingModels';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { EmbeddingConfig, EmbeddingPurpose, EmbeddingGrant, EmbeddingModelInfo, EmbeddingVectorResponse, EmbeddingBudget } from '../domain/EmbeddingModels';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { embeddingAuthorize, embeddingEndpoint, embeddingDecodeModels, embeddingDecodeVector, embeddingPayload } from '../pipeline/EmbeddingPolicy';
import { EmbeddingCredentialStore } from './EmbeddingCredentialStore';
import { EmbeddingTokenCounterPort, EmbeddingBaselinePort } from '../domain/VectorWorkflowModels';
import { TokenEligibilityEvidence } from '../domain/EmbeddingModels';
import { embeddingLocalEligible } from '../pipeline/EmbeddingBasisPolicy';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { UnifiedCorpusTransportPort, UnifiedTokenPort } from '../domain/UnifiedEmbeddingPorts';
import { ParsedCancellation, ParsedFailure } from '../domain/ParsedDocumentModels';
import { UNIFIED_TEXT_POLICY } from '../domain/UnifiedKnowledgeModels';
import { UnifiedQueryTransportPort, UnifiedQueryTokenPort } from '../domain/UnifiedQueryPorts';
import { UnifiedQueryGrant, UnifiedQueryAdmissionPort } from '../domain/UnifiedQueryModels';
import { UNIFIED_QUERY_POLICY } from '../domain/UnifiedKnowledgeModels';


export class EmbeddingTransportAdapter implements EmbeddingTransportPort, UnifiedCorpusTransportPort, UnifiedQueryTransportPort {
  queryEgress: boolean = false;
  private credential: EmbeddingCredentialStore; private sessions: rcp.Session[] = [];
  private identity: KnowledgeIdentityPort | undefined;
  private counter: EmbeddingTokenCounterPort | undefined; private baselines: EmbeddingBaselinePort | undefined;
  private admission: KnowledgeQueryAdmissionPort | undefined = undefined;
  private unifiedCounter: UnifiedTokenPort | undefined;
  private queryCounter: UnifiedQueryTokenPort | undefined;
  private unifiedAdmission: UnifiedQueryAdmissionPort | undefined;
  attachUnifiedQuery(counter: UnifiedQueryTokenPort, admission: UnifiedQueryAdmissionPort): void { this.queryCounter=counter; this.unifiedAdmission=admission; }
  attachUnifiedCounter(counter: UnifiedTokenPort): void { this.unifiedCounter=counter; }
  attachQueryAdmission(port: KnowledgeQueryAdmissionPort): void { this.admission = port; }
  attachInputPolicy(counter: EmbeddingTokenCounterPort, baselines: EmbeddingBaselinePort): void { this.counter = counter; this.baselines = baselines; }
  constructor(credential: EmbeddingCredentialStore, identity?: KnowledgeIdentityPort) { this.credential = credential; this.identity = identity; }
  cancel(): void { for (const session of this.sessions) { session.cancel(); } this.credential.clearTransient(); }
  private async fetch(config: EmbeddingConfig, purpose: EmbeddingPurpose, content: string, cancel: KnowledgeCancellation, grant?: EmbeddingGrant, input: string = ''): Promise<string> {
    cancel.check(); let end: boolean = false; let active: boolean = true; let total: number = 0; const chunks: Uint8Array[] = [];
    const attempt: string = Date.now().toString(16); let status: number = 0;
    const timeout: rcp.Timeout = { connectMs: Math.min(30000, Math.max(1,cancel.deadline-Date.now())), transferMs: Math.min(EmbeddingBudget.requestMs,Math.max(1,cancel.deadline-Date.now())), inactivityMs: 30000 };
    const transfer: rcp.TransferConfiguration = { autoRedirect: false, timeout: timeout };
    const events: rcp.HttpEventsHandler = { onDataEnd: (): void => { end = true; } };
    const tracing: rcp.TracingConfiguration = { verbose: false, collectTimeInfo: false, plaintextInException: false, httpEventsHandler: events };
    const requestConfiguration: rcp.Configuration = { transfer: transfer, tracing: tracing };
    const cache: rcp.CacheControl = { noCache: true, noStore: true, keepCache: false };
    const sessionConfiguration: rcp.SessionConfiguration = { requestConfiguration: requestConfiguration, cacheControl: cache };
    const session: rcp.Session = rcp.createSession(sessionConfiguration); this.sessions.push(session);
    const request: rcp.Request = new rcp.Request(embeddingEndpoint(config,purpose), purpose === EmbeddingPurpose.Models ? 'GET' : 'POST');
    if (purpose !== EmbeddingPurpose.Models) { request.content = content; }
    request.destination = (buffer: ArrayBuffer): void => {
      cancel.check();
      if (!active || buffer.byteLength > EmbeddingBudget.responseBytes-total) { session.cancel(request); throw new KnowledgeFailure('ResponseBudgetOrLate', 'embedding'); }
      total += buffer.byteLength; chunks.push(new Uint8Array(buffer).slice());
    };
    let timer: number = -1;
    try {
      const deadline: Promise<rcp.Response> = new Promise<rcp.Response>((_resolve: (response: rcp.Response) => void, reject: (error: Object) => void): void => {
        timer = setTimeout((): void => { active = false; cancel.invalid = true; session.cancel(request); reject(new KnowledgeFailure('Timeout', 'embedding')); }, Math.max(1,Math.min(EmbeddingBudget.requestMs,cancel.deadline-Date.now())));
      });
      hilog.info(0x0001,'SHUVI_R2','R2_EMBED_REQUEST attempt=%{public}s purpose=%{public}s stage=Start http=0 sdk=0 category=None',attempt,purpose);
      const guard = async (launch: () => void): Promise<void> => {
        if (grant === undefined) { throw new KnowledgeFailure('NoRequestGrantMissing','query'); }
        embeddingAuthorize(config,grant,purpose); cancel.check();
        if (purpose===EmbeddingPurpose.Query && grant instanceof UnifiedQueryGrant) {
          if (this.unifiedAdmission===undefined) { throw new KnowledgeFailure('UnifiedQueryAdmissionRequired','query'); }
          const token: ParsedCancellation=grant.cancellation ?? new ParsedCancellation(); token.deadline=cancel.deadline;
          await this.unifiedAdmission.admitUnified(grant.approval,input,token,(): void=> { cancel.check(); embeddingAuthorize(config,grant,purpose); this.queryEgress=true; launch(); }); return;
        }
        const approval: QueryConsentSnapshot | undefined = grant.queryApproval;
        if (purpose === EmbeddingPurpose.Query && grant.trialId.length === 0) {
          if (approval === undefined || this.admission === undefined) { throw new KnowledgeFailure('NoRequestCurrentScopeAdmissionRequired','query'); }
          await this.admission.admit(approval,input,cancel,(): void => { embeddingAuthorize(config,grant,purpose); this.queryEgress = true; launch(); });
        } else { if (purpose === EmbeddingPurpose.Query) { this.queryEgress = true; } launch(); }
      };
      const response: rcp.Response = await Promise.race<rcp.Response>([this.credential.fetch(config,purpose,request,session,(): void => { cancel.check(); if (!active) { throw new KnowledgeFailure('Canceled','embedding'); } }, purpose === EmbeddingPurpose.Query ? guard : undefined),deadline]);
      status = response.statusCode;
      hilog.info(0x0001,'SHUVI_R2','R2_EMBED_REQUEST attempt=%{public}s purpose=%{public}s stage=Http http=%{public}d sdk=0 category=None',attempt,purpose,status);
      cancel.check(); if (response.statusCode !== 200) { throw new KnowledgeFailure(`HttpRejected:${response.statusCode}`, 'embedding'); }
      if (!end) { throw new KnowledgeFailure('ResponseIncomplete', 'embedding'); }
      const bytes: Uint8Array = new Uint8Array(total); let offset: number = 0;
      for (const chunk of chunks) { bytes.set(chunk,offset); offset += chunk.length; }
      return util.TextDecoder.create('utf-8',{ fatal: true }).decodeToString(bytes);
    } catch (error) {
      const native: BusinessError = error; const sdk: number = typeof native.code === 'number' && Number.isSafeInteger(native.code) ? native.code : 0;
      const category: string = error instanceof KnowledgeFailure ? (error.category.startsWith('HttpRejected:') ? 'HttpRejected' : ['Timeout','ResponseIncomplete','ResponseBudgetOrLate','Canceled','CredentialMissing','CredentialStale','CredentialType'].includes(error.category) ? error.category : 'LocalPolicyOrCredentialRejected') : 'NetworkTlsOrCredentialRejected';
      hilog.info(0x0001,'SHUVI_R2','R2_EMBED_REQUEST attempt=%{public}s purpose=%{public}s stage=Failed http=%{public}d sdk=%{public}d category=%{public}s',attempt,purpose,status,sdk,category);
      if (error instanceof KnowledgeFailure) { throw error; } throw new KnowledgeFailure('NetworkTlsOrCredentialRejected','embedding'); }
    finally { active = false; clearTimeout(timer); request.headers = undefined; request.content = undefined; request.destination = undefined; session.close(); this.sessions = this.sessions.filter((item: rcp.Session): boolean => item !== session); }
  }
  async models(config: EmbeddingConfig, grant: EmbeddingGrant, cancel: KnowledgeCancellation): Promise<EmbeddingModelInfo[]> {
    embeddingAuthorize(config,grant,EmbeddingPurpose.Models); return embeddingDecodeModels(await this.fetch(config,EmbeddingPurpose.Models,'',cancel),config);
  }
  async embed(config: EmbeddingConfig, grant: EmbeddingGrant, purpose: EmbeddingPurpose, input: string, cancel: KnowledgeCancellation): Promise<EmbeddingVectorResponse> {
    if (purpose === EmbeddingPurpose.Query) { this.queryEgress = false; }
    embeddingAuthorize(config,grant,purpose);
    if (purpose === EmbeddingPurpose.Probe) { if (input !== EmbeddingBudget.probe) { throw new KnowledgeFailure('ProbeInputMismatch','embedding'); } }
    else {
      if ((purpose !== EmbeddingPurpose.Corpus && purpose !== EmbeddingPurpose.ImageCorpus && purpose !== EmbeddingPurpose.DocxCorpus && purpose !== EmbeddingPurpose.Query) || this.identity === undefined) { throw new KnowledgeFailure('InputEvidenceUnavailable','embedding'); }
      const hash: string = await this.identity.hash(pdfCodecUtf8(input));
      if (this.counter === undefined || this.baselines === undefined) { throw new KnowledgeFailure('InputPolicyUnavailable','embedding'); }
      const proof: TokenEligibilityEvidence = await this.counter.evidence(config.modelId,purpose === EmbeddingPurpose.Query ? 'query' : 'document',input,hash); proof.baseline = await this.baselines.baseline(config);
      if (!embeddingLocalEligible(proof,config) || !grant.inputHashes.includes(hash) || !grant.inputEvidence.some((evidence): boolean => evidence.textHash === hash && evidence.bindingHash === proof.bindingHash && evidence.upperBound === proof.upperBound && embeddingLocalEligible(evidence,config))) { throw new KnowledgeFailure('InputOutsideGrant','embedding'); }
    }
    return embeddingDecodeVector(await this.fetch(config,purpose,embeddingPayload(config,input),cancel,grant,input),config);
  }
  async embedUnifiedCorpus(config: EmbeddingConfig, input: string, proof: TokenEligibilityEvidence, cancel: ParsedCancellation, admit: (launch: () => void) => Promise<void>): Promise<EmbeddingVectorResponse> {
    if (config.provider!=='SiliconFlow' || config.modelId!=='BAAI/bge-m3' || config.mutationPending || this.identity===undefined || proof.policyVersion!==UNIFIED_TEXT_POLICY || !proof.profileBoundProven || proof.localState!=='SafeUnderPinnedProfile' || proof.upperBound<1 || proof.upperBound>8192 || await this.identity.hash(pdfCodecUtf8(input))!==proof.textHash) { throw new ParsedFailure('UnifiedInputPolicy','embedding'); }
    if (this.unifiedCounter===undefined) { throw new ParsedFailure('UnifiedCounterRequired','embedding'); }
    const counted: TokenEligibilityEvidence=await this.unifiedCounter.unifiedEvidence(config,input,proof.textHash);
    if (counted.bindingHash!==proof.bindingHash || counted.upperBound!==proof.upperBound || counted.policyVersion!==UNIFIED_TEXT_POLICY || counted.localState!=='SafeUnderPinnedProfile') { throw new ParsedFailure('UnifiedInputProofMismatch','embedding'); }
    cancel.check(); let end: boolean=false; let size: number=0; let active: boolean=true; const chunks: Uint8Array[]=[];
    const timeout: rcp.Timeout={connectMs:30000,transferMs:120000,inactivityMs:30000}; const transfer: rcp.TransferConfiguration={autoRedirect:false,timeout:timeout};
    const events: rcp.HttpEventsHandler={onDataEnd:(): void=>{end=true;}}; const tracing: rcp.TracingConfiguration={verbose:false,plaintextInException:false,collectTimeInfo:false,httpEventsHandler:events};
    const requestConfig: rcp.Configuration={transfer:transfer,tracing:tracing}; const cache: rcp.CacheControl={noCache:true,noStore:true,keepCache:false}; const sessionConfig: rcp.SessionConfiguration={requestConfiguration:requestConfig,cacheControl:cache};
    const session: rcp.Session=rcp.createSession(sessionConfig); const request: rcp.Request=new rcp.Request(embeddingEndpoint(config,EmbeddingPurpose.Corpus),'POST'); request.content=embeddingPayload(config,input);
    request.destination=(buffer: ArrayBuffer): void=> { cancel.check(); if (!active || size+buffer.byteLength>EmbeddingBudget.responseBytes) { session.cancel(request); throw new ParsedFailure('EmbeddingResponseBudget','embedding'); } size+=buffer.byteLength; chunks.push(new Uint8Array(buffer).slice()); };
    let timer: number=-1;
    try {
      const deadline: Promise<rcp.Response>=new Promise<rcp.Response>((_resolve: (r: rcp.Response)=>void,reject: (e: Object)=>void): void=> { timer=setTimeout((): void=> { active=false; session.cancel(request); reject(new ParsedFailure('EmbeddingTimeoutUnknown','embedding')); },Math.max(1,Math.min(120000,cancel.deadline-Date.now()))); });
      const response: rcp.Response=await Promise.race<rcp.Response>([this.credential.fetch(config,EmbeddingPurpose.Corpus,request,session,(): void=> { cancel.check(); if (!active) { throw new ParsedFailure('Canceled','embedding'); } },admit),deadline]);
      cancel.check(); if (response.statusCode!==200 || !end) { throw new ParsedFailure(`EmbeddingHttpOrIncomplete:${response.statusCode}`,'embedding'); }
      const bytes: Uint8Array=new Uint8Array(size); let at: number=0; for (const c of chunks) { bytes.set(c,at); at+=c.length; } return embeddingDecodeVector(util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(bytes),config);
    } finally { active=false; if (timer>=0) { clearTimeout(timer); } request.headers=undefined; request.destination=undefined; request.content=undefined; session.close(); }
  }
  async embedUnifiedQuery(config: EmbeddingConfig, grant: UnifiedQueryGrant, input: string, cancel: ParsedCancellation): Promise<EmbeddingVectorResponse> {
    this.queryEgress=false; embeddingAuthorize(config,grant,EmbeddingPurpose.Query); cancel.check();
    if (this.identity===undefined || this.queryCounter===undefined || input!==grant.approval.actual || await this.identity.hash(pdfCodecUtf8(input))!==grant.approval.inputHash) { throw new KnowledgeFailure('UnifiedQueryActualInput','query'); }
    const proof=await this.queryCounter.unifiedQueryEvidence(config,input,grant.approval.inputHash);
    if (proof.policyVersion!==UNIFIED_QUERY_POLICY || proof.role!=='query' || proof.bindingHash!==grant.approval.proofBinding || proof.upperBound!==grant.proof.upperBound || proof.localState!=='SafeUnderPinnedProfile') { throw new KnowledgeFailure('UnifiedQueryProofChanged','query'); }
    const token: KnowledgeCancellation=new KnowledgeCancellation(); token.deadline=cancel.deadline; cancel.check();
    const raw: string=await this.fetch(config,EmbeddingPurpose.Query,embeddingPayload(config,input),token,grant,input); cancel.check(); return embeddingDecodeVector(raw,config);
  }
}
