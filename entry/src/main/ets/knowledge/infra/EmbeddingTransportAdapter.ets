import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { EmbeddingTransportPort, KnowledgeIdentityPort } from '../domain/KnowledgePorts';
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


export class EmbeddingTransportAdapter implements EmbeddingTransportPort {
  private credential: EmbeddingCredentialStore; private sessions: rcp.Session[] = [];
  private identity: KnowledgeIdentityPort | undefined;
  private counter: EmbeddingTokenCounterPort | undefined; private baselines: EmbeddingBaselinePort | undefined;
  attachInputPolicy(counter: EmbeddingTokenCounterPort, baselines: EmbeddingBaselinePort): void { this.counter = counter; this.baselines = baselines; }
  constructor(credential: EmbeddingCredentialStore, identity?: KnowledgeIdentityPort) { this.credential = credential; this.identity = identity; }
  cancel(): void { for (const session of this.sessions) { session.cancel(); } this.credential.clearTransient(); }
  private async fetch(config: EmbeddingConfig, purpose: EmbeddingPurpose, content: string, cancel: KnowledgeCancellation): Promise<string> {
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
      const response: rcp.Response = await Promise.race<rcp.Response>([this.credential.fetch(config,purpose,request,session,(): void => { cancel.check(); if (!active) { throw new KnowledgeFailure('Canceled','embedding'); } }),deadline]);
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
    embeddingAuthorize(config,grant,purpose);
    if (purpose === EmbeddingPurpose.Probe) { if (input !== EmbeddingBudget.probe) { throw new KnowledgeFailure('ProbeInputMismatch','embedding'); } }
    else {
      if ((purpose !== EmbeddingPurpose.Corpus && purpose !== EmbeddingPurpose.Query) || this.identity === undefined) { throw new KnowledgeFailure('InputEvidenceUnavailable','embedding'); }
      const hash: string = await this.identity.hash(pdfCodecUtf8(input));
      if (this.counter === undefined || this.baselines === undefined) { throw new KnowledgeFailure('InputPolicyUnavailable','embedding'); }
      const proof: TokenEligibilityEvidence = await this.counter.evidence(config.modelId,purpose === EmbeddingPurpose.Corpus ? 'document' : 'query',input,hash); proof.baseline = await this.baselines.baseline(config);
      if (!embeddingLocalEligible(proof,config) || !grant.inputHashes.includes(hash) || !grant.inputEvidence.some((evidence): boolean => evidence.textHash === hash && evidence.bindingHash === proof.bindingHash && evidence.upperBound === proof.upperBound && embeddingLocalEligible(evidence,config))) { throw new KnowledgeFailure('InputOutsideGrant','embedding'); }
    }
    return embeddingDecodeVector(await this.fetch(config,purpose,embeddingPayload(config,input),cancel),config);
  }
}
