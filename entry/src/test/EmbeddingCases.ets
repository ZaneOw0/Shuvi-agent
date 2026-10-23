import { EmbeddingConfig, EmbeddingProvider, EmbeddingRegion, EmbeddingAccess, EmbeddingPurpose, EmbeddingGrant, EmbeddingFreeEligibility, EmbeddingCredentialStatus, EmbeddingDetection, EmbeddingModelInfo, EmbeddingVectorResponse, EmbeddingBudget, EmbeddingDetectionStatus } from '../main/ets/knowledge/domain/EmbeddingModels';
import { embeddingCredentialAlias, embeddingEndpoint, embeddingAuthorize, embeddingFingerprint, embeddingValidateVector, embeddingDecodeVector, embeddingPayload, embeddingProfile } from '../main/ets/knowledge/pipeline/EmbeddingPolicy';
import { EmbeddingService, EmbeddingMetadataPort, copyEmbeddingConfig } from '../main/ets/knowledge/application/EmbeddingService';
import { EmbeddingCredentialPort, EmbeddingTransportPort, KnowledgeIdentityPort } from '../main/ets/knowledge/domain/KnowledgePorts';
import { KnowledgeCancellation, KnowledgeFailure } from '../main/ets/knowledge/domain/PdfKnowledgeModels';
export interface EmbeddingTestCase { name: string; run: () => Promise<void>; }
export function embeddingCheck(ok: boolean): void { if (!ok) { throw new Error('Embedding boundary expectation failed'); } }
function embeddingRejects(action: () => void): void { let rejected: boolean = false; try { action(); } catch { rejected = true; } embeddingCheck(rejected); }
class EmbeddingTestMetadata implements EmbeddingMetadataPort {
  records: EmbeddingConfig[] = []; grants: EmbeddingGrant[] = []; detections: EmbeddingDetection[] = [];
  async saveConfig(config: EmbeddingConfig): Promise<void> { this.records = this.records.filter((item: EmbeddingConfig): boolean => item.provider !== config.provider).concat([copyEmbeddingConfig(config)]); }
  async configs(): Promise<EmbeddingConfig[]> { return this.records; }
  async saveDetection(detection: EmbeddingDetection): Promise<void> { this.detections.push(detection); }
  async revokeGrants(fingerprint: string): Promise<void> { for (const grant of this.grants) { if (grant.configFingerprint === fingerprint) { grant.revoked = true; } } }
  async saveGrant(grant: EmbeddingGrant): Promise<void> { this.grants.push(grant); }
  async saveModels(_config: EmbeddingConfig, _models: EmbeddingModelInfo[]): Promise<void> {}
}
class EmbeddingTestCredential implements EmbeddingCredentialPort {
  present: Set<string> = new Set<string>();
  async status(config: EmbeddingConfig): Promise<EmbeddingCredentialStatus> { return this.present.has(embeddingCredentialAlias(config)) ? EmbeddingCredentialStatus.Configured : EmbeddingCredentialStatus.Missing; }
  async save(config: EmbeddingConfig, _input: string, _replace: boolean): Promise<EmbeddingCredentialStatus> { this.present.add(embeddingCredentialAlias(config)); return EmbeddingCredentialStatus.Configured; }
  async remove(config: EmbeddingConfig): Promise<EmbeddingCredentialStatus> { this.present.delete(embeddingCredentialAlias(config)); return EmbeddingCredentialStatus.Missing; }
  clearTransient(): void {}
}
class EmbeddingTestTransport implements EmbeddingTransportPort {
  lists: number = 0; probes: number = 0; inputs: string[] = [];
  response: EmbeddingVectorResponse = new EmbeddingVectorResponse();
  mode: string = ''; during: () => void = (): void => {};
  async models(_config: EmbeddingConfig, _grant: EmbeddingGrant, _cancel: KnowledgeCancellation): Promise<EmbeddingModelInfo[]> { this.lists++; return []; }
  async embed(_config: EmbeddingConfig, _grant: EmbeddingGrant, _purpose: EmbeddingPurpose, input: string, cancel: KnowledgeCancellation): Promise<EmbeddingVectorResponse> { this.probes++; this.inputs.push(input); this.during(); if (this.mode.length > 0) { throw new KnowledgeFailure(this.mode,'unit-transport'); } cancel.check(); return this.response; }
  cancel(): void {}
}
class EmbeddingTestIdentity implements KnowledgeIdentityPort {
  sequence: number = 0;
  id(): string { return `unit-${++this.sequence}`; }
  async hash(_bytes: Uint8Array): Promise<string> { return 'unit-injected-hash-not-a-production-digest'; }
}
export class EmbeddingTestSession {
  repository: EmbeddingTestMetadata = new EmbeddingTestMetadata(); credential: EmbeddingTestCredential = new EmbeddingTestCredential();
  transport: EmbeddingTestTransport = new EmbeddingTestTransport();
  service: EmbeddingService = new EmbeddingService(this.repository,this.credential,this.transport,new EmbeddingTestIdentity());
}
export function embeddingCases(): EmbeddingTestCase[] {
  return [
    { name: '取消/429/鉴权/超时零重试且不保存Passed', run: async (): Promise<void> => {
      for (const failure of ['HttpRejected:429','HttpRejected:401','Timeout','Canceled']) {
        const session: EmbeddingTestSession = new EmbeddingTestSession(); await session.service.initialize(); session.service.state.config.modelId = 'unit-model'; session.service.state.credential = EmbeddingCredentialStatus.Configured;
        session.transport.mode = failure; await session.service.probe(true);
        embeddingCheck(session.transport.probes === 1 && session.service.state.detection.status !== EmbeddingDetectionStatus.Passed);
      }
      const session: EmbeddingTestSession = new EmbeddingTestSession(); await session.service.initialize(); session.service.state.config.modelId = 'unit-model'; session.service.state.credential = EmbeddingCredentialStatus.Configured;
      session.transport.during = (): void => { session.service.pause(); }; await session.service.probe(true);
      embeddingCheck(session.service.state.detection.status !== EmbeddingDetectionStatus.Passed && session.repository.detections.every((item: EmbeddingDetection): boolean => item.status !== EmbeddingDetectionStatus.Passed));
    } },
    { name: '模型上下文不等请求前Token证明且corpus/query禁发', run: async (): Promise<void> => {
      const config: EmbeddingConfig = new EmbeddingConfig(); config.modelId = 'BAAI/bge-m3';
      if (embeddingProfile(config).contextLimit !== 8192 || embeddingProfile(config).tokenEvidence.verified) { throw new Error('Context mistaken for input proof'); }
      for (const purpose of [EmbeddingPurpose.Corpus,EmbeddingPurpose.Query]) {
        const grant: EmbeddingGrant = new EmbeddingGrant(); grant.purpose = purpose; grant.provider = config.provider; grant.configFingerprint = embeddingFingerprint(config); grant.free = EmbeddingFreeEligibility.Confirmed; grant.issuedAt = Date.now(); grant.expiresAt = Date.now()+1000;
        embeddingRejects((): void => { embeddingAuthorize(config,grant,purpose); });
      }
      const session: EmbeddingTestSession = new EmbeddingTestSession(); await session.service.vectorizePdf('unit-pdf',true,true);
      embeddingCheck(session.transport.probes === 0 && session.service.corpusGate() === 'InputLimitUnverified' && session.service.queryGate() === 'InputLimitUnverified');
    } },
    { name: '固定句只有一次请求且检测不保存向量为语料', run: async (): Promise<void> => {
      const session: EmbeddingTestSession = new EmbeddingTestSession(); await session.service.initialize();
      session.service.state.config.modelId = 'BAAI/bge-m3'; session.service.state.credential = EmbeddingCredentialStatus.Configured;
      session.transport.response.model = 'BAAI/bge-m3'; session.transport.response.index = 0;
      session.transport.response.vector = new Float32Array([0.25,-0.5]);
      await session.service.probe(false); embeddingCheck(session.transport.probes === 0);
      await session.service.probe(true); embeddingCheck(session.transport.probes === 1 && session.transport.inputs[0] === EmbeddingBudget.probe);
      embeddingCheck(session.service.state.detection.status === EmbeddingDetectionStatus.Passed && session.service.state.detection.dimension === 2);
      embeddingCheck(!session.service.state.corpusEnabled && !session.service.state.queryEnabled);
    } },
    { name: '非法向量/Float32溢出或下溢到零拒绝', run: async (): Promise<void> => {
      for (const values of [[],[0,0],[NaN,1],[Infinity,1],[1e100,1],[1e-100]]) { embeddingRejects((): void => { embeddingValidateVector(values); }); }
      embeddingRejects((): void => { embeddingValidateVector([1,2],3); });
      embeddingCheck(embeddingValidateVector([1,-2]).length === 2);
    } },
    { name: '响应数量/索引/模型绑定与total_tokens-only', run: async (): Promise<void> => {
      const config: EmbeddingConfig = new EmbeddingConfig(); config.modelId = 'unit-model';
      const valid: string = '{"object":"list","model":"unit-model","data":[{"index":0,"object":"embedding","embedding":[0.5,-0.5]}],"usage":{"total_tokens":3}}';
      const result: EmbeddingVectorResponse = embeddingDecodeVector(valid,config);
      embeddingCheck(result.usage.totalTokens === 3 && result.usage.promptTokens === undefined);
      for (const invalid of [valid.replace('"index":0','"index":1'),valid.replace('"model":"unit-model"','"model":"other"'),valid.replace('[0.5,-0.5]','[0,0]'),valid.replace('"embedding":[0.5,-0.5]','"embedding":["x"]')]) {
        embeddingRejects((): void => { embeddingDecodeVector(invalid,config); });
      }
      const payload: string = embeddingPayload(config,EmbeddingBudget.probe);
      embeddingCheck(!payload.includes('dimensions') && !payload.includes('text_type') && !payload.includes('messages') && payload.includes('"encoding_format":"float"'));
    } },
    { name: '保存/进入/切换不联网且Key修订先失效', run: async (): Promise<void> => {
      const session: EmbeddingTestSession = new EmbeddingTestSession(); await session.service.initialize();
      const config: EmbeddingConfig = copyEmbeddingConfig(session.service.state.config); config.modelId = 'BAAI/bge-m3';
      await session.service.saveConfiguration(config); await session.service.changeCredential('unit-nonsecret-input',false);
      embeddingCheck(session.transport.lists === 0 && session.transport.probes === 0 && !session.repository.records[0].mutationPending);
      embeddingCheck(session.repository.records[0].credentialRevision === 1 && JSON.stringify(session.service.state).indexOf('unit-nonsecret-input') < 0);
      await session.service.discover(false); embeddingCheck(session.transport.lists === 0);
      await session.service.select(EmbeddingProvider.OpenAI); await session.service.discover(true); embeddingCheck(session.transport.lists === 0);
    } },
    { name: '四提供商凭据用途隔离且不沿用MinerU', run: async (): Promise<void> => {
      const aliases: string[] = [];
      for (const provider of [EmbeddingProvider.SiliconFlow, EmbeddingProvider.Bailian, EmbeddingProvider.Gemini, EmbeddingProvider.OpenAI]) {
        const config: EmbeddingConfig = new EmbeddingConfig(); config.provider = provider;
        aliases.push(embeddingCredentialAlias(config));
      }
      embeddingCheck(new Set<string>(aliases).size === 4 && aliases.every((alias: string): boolean => alias.indexOf('mineru') < 0));
    } },
    { name: '百炼默认地域未选且接入凭据不流转', run: async (): Promise<void> => {
      const config: EmbeddingConfig = new EmbeddingConfig(); config.provider = EmbeddingProvider.Bailian;
      embeddingCheck(config.region === EmbeddingRegion.Unselected); embeddingRejects((): void => { embeddingEndpoint(config, EmbeddingPurpose.Probe); });
      config.region = EmbeddingRegion.Beijing; const before: string = embeddingCredentialAlias(config);
      config.region = EmbeddingRegion.Singapore; embeddingCheck(before !== embeddingCredentialAlias(config));
      config.access = EmbeddingAccess.Workspace; config.workspaceId = 'safe-workspace';
      embeddingCheck(embeddingCredentialAlias(config) !== before);
      for (const invalid of ['a/b', 'a.b', 'https://x', '-a', 'a-', 'a:443', 'a@b']) {
        config.workspaceId = invalid; embeddingRejects((): void => { embeddingEndpoint(config, EmbeddingPurpose.Probe); });
      }
    } },
    { name: '免费未知NoRequest且用途不共享', run: async (): Promise<void> => {
      const config: EmbeddingConfig = new EmbeddingConfig(); config.modelId = 'BAAI/bge-m3';
      const grant: EmbeddingGrant = new EmbeddingGrant(); grant.configFingerprint = embeddingFingerprint(config); grant.issuedAt = Date.now(); grant.expiresAt = Date.now() + 1000;
      embeddingRejects((): void => { embeddingAuthorize(config, grant, EmbeddingPurpose.Probe); });
      grant.free = EmbeddingFreeEligibility.Confirmed; embeddingAuthorize(config, grant, EmbeddingPurpose.Probe);
      embeddingRejects((): void => { embeddingAuthorize(config, grant, EmbeddingPurpose.Query); });
      config.credentialRevision++; embeddingRejects((): void => { embeddingAuthorize(config, grant, EmbeddingPurpose.Probe); });
    } },
    { name: 'Gemini/OpenAI只有配置而无网络接入', run: async (): Promise<void> => {
      for (const provider of [EmbeddingProvider.Gemini, EmbeddingProvider.OpenAI]) {
        const config: EmbeddingConfig = new EmbeddingConfig(); config.provider = provider;
        embeddingRejects((): void => { embeddingEndpoint(config, EmbeddingPurpose.Probe); });
        embeddingRejects((): void => { embeddingEndpoint(config, EmbeddingPurpose.Models); });
      }
    } }
  ];
}
