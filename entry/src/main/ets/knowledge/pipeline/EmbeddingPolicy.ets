import {
  EmbeddingConfig, EmbeddingProvider, EmbeddingRegion, EmbeddingAccess, EmbeddingPurpose, EmbeddingGrant,
  EmbeddingFreeEligibility, EmbeddingBudget, EmbeddingProfile, EmbeddingVectorResponse, EmbeddingModelInfo,
  EmbeddingModelSource, EmbeddingCapability
} from '../domain/EmbeddingModels';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { documentUtf8Bytes } from '../domain/DocumentParseModels';
import { embeddingLocalEligible, embeddingConfigBinding } from './EmbeddingBasisPolicy';

export function embeddingCredentialAlias(config: EmbeddingConfig): string {
  if ([EmbeddingProvider.SiliconFlow,EmbeddingProvider.Bailian,EmbeddingProvider.Gemini,EmbeddingProvider.OpenAI].indexOf(config.provider) < 0 || [EmbeddingRegion.Unselected,EmbeddingRegion.Beijing,EmbeddingRegion.Singapore].indexOf(config.region) < 0 || [EmbeddingAccess.Public,EmbeddingAccess.Workspace].indexOf(config.access) < 0) { throw new KnowledgeFailure('ProviderConfigurationInvalid','embedding'); }
  if (config.provider !== EmbeddingProvider.Bailian) { return `shuvi.embedding.v1.${config.provider}`; }
  if (config.workspaceId.length > 63 || (config.workspaceId.length > 0 && !new RegExp('^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$').test(config.workspaceId))) { throw new KnowledgeFailure('WorkspaceInvalid', 'configuration'); }
  return `shuvi.embedding.v1.${config.provider}.${config.region}.${config.access}.${config.access === EmbeddingAccess.Workspace ? config.workspaceId : 'public'}`;
}
export function embeddingFingerprint(config: EmbeddingConfig): string {
  return embeddingConfigBinding(config);
}
export function embeddingEndpoint(config: EmbeddingConfig, purpose: EmbeddingPurpose): string {
  if (config.provider === EmbeddingProvider.SiliconFlow) {
    return purpose === EmbeddingPurpose.Models ? 'https://api.siliconflow.cn/v1/models?sub_type=embedding' : 'https://api.siliconflow.cn/v1/embeddings';
  }
  if (config.provider !== EmbeddingProvider.Bailian) { throw new KnowledgeFailure('ContractUnverified', 'provider'); }
  if (purpose === EmbeddingPurpose.Models) { throw new KnowledgeFailure('DiscoveryUnsupportedManualOnly', 'provider'); }
  if (config.region === EmbeddingRegion.Unselected) { throw new KnowledgeFailure('RegionUnselected', 'provider'); }
  embeddingCredentialAlias(config);
  if (config.access === EmbeddingAccess.Workspace) {
    if (config.workspaceId.length < 1) { throw new KnowledgeFailure('WorkspaceMissing', 'provider'); }
    return config.region === EmbeddingRegion.Beijing ? `https://${config.workspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/embeddings` : `https://${config.workspaceId}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/embeddings`;
  }
  return config.region === EmbeddingRegion.Beijing ? 'https://dashscope.aliyuncs.com/compatible-mode/v1/embeddings' : 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1/embeddings';
}
export function embeddingValidateConfig(config: EmbeddingConfig): void {
  embeddingCredentialAlias(config);
  if (documentUtf8Bytes(config.modelId) > EmbeddingBudget.modelBytes || new RegExp('[\x00-\x1f\x7f]').test(config.modelId) || !Number.isSafeInteger(config.revision) || config.revision < 0 || !Number.isSafeInteger(config.credentialRevision) || config.credentialRevision < 0) { throw new KnowledgeFailure('ConfigurationInvalid', 'embedding'); }
}
export function embeddingAuthorize(config: EmbeddingConfig, grant: EmbeddingGrant, purpose: EmbeddingPurpose): void {
  embeddingValidateConfig(config); embeddingEndpoint(config, purpose);
  if (config.mutationPending || grant.revoked || grant.purpose !== purpose || grant.provider !== config.provider || grant.configFingerprint !== embeddingFingerprint(config) || grant.credentialRevision !== config.credentialRevision || grant.free !== EmbeddingFreeEligibility.Confirmed || grant.issuedAt <= 0 || grant.expiresAt <= Date.now() || grant.issuedAt > Date.now()) { throw new KnowledgeFailure('NoRequest', 'egress-grant'); }
  if (purpose !== EmbeddingPurpose.Models && config.modelId.trim().length === 0) { throw new KnowledgeFailure('ModelMissing', 'embedding'); }
  if (purpose === EmbeddingPurpose.Corpus || purpose === EmbeddingPurpose.Query) {
    if (config.provider !== EmbeddingProvider.SiliconFlow || config.modelId !== 'BAAI/bge-m3' || grant.spaceId.length === 0 || grant.sessionId.length === 0 || grant.inputHashes.length === 0 || grant.inputEvidence.length !== grant.inputHashes.length || grant.inputEvidence.some((evidence, index: number): boolean => !embeddingLocalEligible(evidence,config) || evidence.modelId !== config.modelId || evidence.textHash !== grant.inputHashes[index] || evidence.role !== (purpose === EmbeddingPurpose.Corpus ? 'document' : 'query') || evidence.applicableScope.length === 0 || !Number.isSafeInteger(evidence.upperBound) || evidence.upperBound < 1 || evidence.contextLimit !== 8192 || evidence.upperBound > evidence.contextLimit)) { throw new KnowledgeFailure('InputLimitUnverified','embedding'); }
  }
  if (grant.trialId.length > 0 && (purpose !== EmbeddingPurpose.Query || grant.trialSetHash.length !== 64 || grant.documentId.length === 0 || grant.generation.length === 0 || grant.snapshotHash.length !== 64 || grant.inputHashes.length !== 1 || grant.scopeChunkIds.length !== 3 || new Set<string>(grant.scopeChunkIds).size !== 3 || grant.scopeInputHashes.length !== 3)) { throw new KnowledgeFailure('TrialQueryScopeGrantInvalid','egress-grant'); }
}
export function embeddingProfile(config: EmbeddingConfig): EmbeddingProfile {
  const profile: EmbeddingProfile = new EmbeddingProfile(); profile.id = `${config.provider}:${config.modelId}:2026-10-16`; profile.modelId = config.modelId;
  if (config.provider === EmbeddingProvider.SiliconFlow && (config.modelId === 'BAAI/bge-m3' || config.modelId === 'Pro/BAAI/bge-m3')) { profile.contextLimit = 8192; }
  if (config.provider === EmbeddingProvider.Bailian && (config.modelId === 'text-embedding-v3' || config.modelId === 'text-embedding-v4')) { profile.contextLimit = 8192; }
  // Context size is not a tokenizer proof. No unverified byte→token conversion.
  return profile;
}

class EmbeddingJsonField { key: string = ''; node: EmbeddingJsonNode = new EmbeddingJsonNode(); }
class EmbeddingJsonNode {
  kind: string = ''; text: string = ''; numeric: number = 0; fields: EmbeddingJsonField[] = []; items: EmbeddingJsonNode[] = [];
  field(key: string): EmbeddingJsonNode | undefined {
    if (this.kind !== 'object') { throw new KnowledgeFailure('ResponseShape', 'embedding-json'); }
    return this.fields.find((field: EmbeddingJsonField): boolean => field.key === key)?.node;
  }
  required(key: string): EmbeddingJsonNode { const node: EmbeddingJsonNode | undefined = this.field(key); if (node === undefined) { throw new KnowledgeFailure('ResponseField', 'embedding-json'); } return node; }
  string(): string { if (this.kind !== 'string') { throw new KnowledgeFailure('ResponseString', 'embedding-json'); } return this.text; }
  integer(): number { if (this.kind !== 'number' || !Number.isSafeInteger(this.numeric) || this.numeric < 0) { throw new KnowledgeFailure('ResponseInteger', 'embedding-json'); } return this.numeric; }
  array(): EmbeddingJsonNode[] { if (this.kind !== 'array') { throw new KnowledgeFailure('ResponseArray', 'embedding-json'); } return this.items; }
}
class EmbeddingJsonReader {
  private raw: string; private at: number = 0; private tokens: number = 0;
  constructor(raw: string) { if (raw.length > EmbeddingBudget.responseBytes || documentUtf8Bytes(raw) > EmbeddingBudget.responseBytes) { throw new KnowledgeFailure('ResponseBudget', 'embedding-json'); } this.raw = raw; }
  private fail(): KnowledgeFailure { return new KnowledgeFailure('ResponseJsonInvalid', 'embedding-json'); }
  private space(): void { while (this.at < this.raw.length && ' \t\r\n'.indexOf(this.raw.charAt(this.at)) >= 0) { this.at++; } }
  private take(expected: string): void { this.space(); if (this.raw.charAt(this.at++) !== expected) { throw this.fail(); } }
  private text(): string {
    this.take('"'); let text: string = ''; let bytes: number = 0;
    while (this.at < this.raw.length) {
      let part: string = this.raw.charAt(this.at++);
      if (part === '"') { documentUtf8Bytes(text); return text; }
      if (part.charCodeAt(0) < 32) { throw this.fail(); }
      if (part === '\\') {
        part = this.raw.charAt(this.at++);
        if (part === 'u') { const hex: string = this.raw.slice(this.at,this.at+4); if (!new RegExp('^[a-fA-F0-9]{4}$').test(hex)) { throw this.fail(); } this.at += 4; part = String.fromCharCode(Number.parseInt(hex,16)); }
        else if (part === 'n') { part = '\n'; } else if (part === 'r') { part = '\r'; } else if (part === 't') { part = '\t'; }
        else if (part === 'b') { part = '\b'; } else if (part === 'f') { part = '\f'; }
        else if (part !== '"' && part !== '\\' && part !== '/') { throw this.fail(); }
      }
      bytes += part.charCodeAt(0) < 128 ? 1 : part.charCodeAt(0) < 2048 ? 2 : 3;
      if (bytes > 262144) { throw this.fail(); } text += part;
    }
    throw this.fail();
  }
  private node(depth: number): EmbeddingJsonNode {
    this.space(); if (depth > 32 || ++this.tokens > 200000) { throw this.fail(); }
    const node: EmbeddingJsonNode = new EmbeddingJsonNode(); const c: string = this.raw.charAt(this.at);
    if (c === '{' || c === '[') {
      this.at++; node.kind = c === '{' ? 'object' : 'array'; this.space(); const end: string = c === '{' ? '}' : ']';
      if (this.raw.charAt(this.at) === end) { this.at++; return node; }
      while (this.at < this.raw.length) {
        if (c === '{') {
          if (node.fields.length >= 256) { throw this.fail(); }
          const key: string = this.text(); if (node.fields.some((field: EmbeddingJsonField): boolean => field.key === key)) { throw this.fail(); }
          this.take(':'); const field: EmbeddingJsonField = new EmbeddingJsonField(); field.key = key; field.node = this.node(depth+1); node.fields.push(field);
        } else { if (node.items.length >= 4096) { throw this.fail(); } node.items.push(this.node(depth+1)); }
        this.space(); if (this.raw.charAt(this.at) === end) { this.at++; return node; } this.take(',');
      } throw this.fail();
    }
    if (c === '"') { node.kind = 'string'; node.text = this.text(); return node; }
    for (const literal of ['true','false','null']) { if (this.raw.slice(this.at,this.at+literal.length) === literal) { this.at += literal.length; node.kind = literal; return node; } }
    const start: number = this.at; while (this.at < this.raw.length && '-+0123456789.eE'.indexOf(this.raw.charAt(this.at)) >= 0) { if (this.at-start > 128) { throw this.fail(); } this.at++; }
    const numeric: string = this.raw.slice(start,this.at); if (!new RegExp('^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$').test(numeric)) { throw this.fail(); }
    node.kind = 'number'; node.numeric = Number(numeric); if (!Number.isFinite(node.numeric)) { throw this.fail(); } return node;
  }
  read(): EmbeddingJsonNode { const node: EmbeddingJsonNode = this.node(1); this.space(); if (this.at !== this.raw.length) { throw this.fail(); } return node; }
}
export function embeddingDecodeModels(raw: string, config: EmbeddingConfig): EmbeddingModelInfo[] {
  const root: EmbeddingJsonNode = new EmbeddingJsonReader(raw).read();
  if (root.required('object').string() !== 'list') { throw new KnowledgeFailure('ModelsObject', 'embedding'); }
  const models: EmbeddingModelInfo[] = []; const seen: Set<string> = new Set<string>();
  for (const node of root.required('data').array()) {
    const model: EmbeddingModelInfo = new EmbeddingModelInfo(); model.id = node.required('id').string();
    if (model.id.length === 0 || documentUtf8Bytes(model.id) > EmbeddingBudget.modelBytes || new RegExp('[\x00-\x1f\x7f]').test(model.id) || seen.has(model.id)) { throw new KnowledgeFailure('ModelsIdentity', 'embedding'); }
    seen.add(model.id); model.source = EmbeddingModelSource.Remote; model.configFingerprint = embeddingFingerprint(config);
    model.observedAt = Date.now(); model.capability = EmbeddingCapability.VerifiedContract; models.push(model);
  } return models;
}
export function embeddingValidateVector(values: number[], expected: number = 0): Float32Array {
  if (values.length === 0 || values.length > EmbeddingBudget.dimension || (expected !== 0 && values.length !== expected)) { throw new KnowledgeFailure('VectorDimension', 'embedding'); }
  const vector: Float32Array = new Float32Array(values.length); let norm: number = 0;
  for (let i: number = 0; i < values.length; i++) {
    if (!Number.isFinite(values[i])) { throw new KnowledgeFailure('VectorNonFinite', 'embedding'); }
    vector[i] = values[i]; if (!Number.isFinite(vector[i])) { throw new KnowledgeFailure('VectorFloat32Overflow', 'embedding'); } norm += vector[i] * vector[i];
  }
  if (!Number.isFinite(norm) || norm <= 0) { throw new KnowledgeFailure('VectorZeroNorm', 'embedding'); } return vector;
}
export function embeddingDecodeVector(raw: string, config: EmbeddingConfig): EmbeddingVectorResponse {
  const root: EmbeddingJsonNode = new EmbeddingJsonReader(raw).read();
  if (root.required('object').string() !== 'list' || root.required('model').string() !== config.modelId) { throw new KnowledgeFailure('VectorModelMismatch', 'embedding'); }
  const data: EmbeddingJsonNode[] = root.required('data').array();
  if (data.length !== 1 || data[0].required('index').integer() !== 0 || data[0].required('object').string() !== 'embedding') { throw new KnowledgeFailure('VectorCountOrIndex', 'embedding'); }
  const values: number[] = [];
  for (const value of data[0].required('embedding').array()) { if (value.kind !== 'number') { throw new KnowledgeFailure('VectorValueType', 'embedding'); } values.push(value.numeric); }
  const response: EmbeddingVectorResponse = new EmbeddingVectorResponse(); response.model = config.modelId; response.index = 0; response.vector = embeddingValidateVector(values);
  const usage: EmbeddingJsonNode | undefined = root.field('usage');
  if (usage !== undefined) { const total: EmbeddingJsonNode | undefined = usage.field('total_tokens'); const prompt: EmbeddingJsonNode | undefined = usage.field('prompt_tokens'); response.usage.totalTokens = total?.integer(); response.usage.promptTokens = prompt?.integer(); }
  return response;
}
export function embeddingPayload(config: EmbeddingConfig, input: string): string {
  // Deliberately no dimensions, text_type, instruction, images, truncate or chat fields.
  return `{"model":${JSON.stringify(config.modelId)},"input":${JSON.stringify(input)},"encoding_format":"float"}`;
}
