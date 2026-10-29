import { EmbeddingSpace, EmbeddingConfig, EmbeddingProvider, EmbeddingRegion, EmbeddingAccess } from '../domain/EmbeddingModels';
import { embeddingConfigBinding } from './EmbeddingBasisPolicy';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { BoundedDocumentJson } from './BoundedDocumentJson';
import { pdfCodecUtf8 } from './PdfSnapshotCodec';

/** Credential/config revisions authorize requests; they do not change an already stored vector's geometry. */
export function unifiedQuerySpaceMatches(space: EmbeddingSpace, config: EmbeddingConfig): boolean {
  const stored: string[] = space.configFingerprint.split('|');
  const current: string[] = embeddingConfigBinding(config).split('|');
  if (stored.length !== 8 || current.length !== 8 ||
    !new RegExp('^(0|[1-9][0-9]*)$').test(stored[6]) || !new RegExp('^(0|[1-9][0-9]*)$').test(stored[7]) ||
    !Number.isSafeInteger(Number(stored[6])) || !Number.isSafeInteger(Number(stored[7]))) { return false; }
  for (let index: number = 0; index < 6; index++) { if (stored[index] !== current[index]) { return false; } }
  return space.provider === config.provider && space.region === config.region && space.access === config.access &&
    space.workspaceId === config.workspaceId && space.requestedModel === config.modelId && space.returnedModel === config.modelId;
}

/** Only spaces with identical semantic contracts may share a single query vector and distance ranking. */
export function unifiedQuerySpacesCompatible(left: EmbeddingSpace, right: EmbeddingSpace): boolean {
  return left.dimension === right.dimension && left.preprocessing === right.preprocessing &&
    left.profileId === right.profileId && left.profileRevision === right.profileRevision &&
    left.tokenizerSha256 === right.tokenizerSha256 && left.profileParameters === right.profileParameters &&
    left.rolePair === right.rolePair && left.normalization === right.normalization && left.metric === right.metric &&
    left.providerRevision === right.providerRevision && left.providerConsistency === right.providerConsistency;
}

export function embeddingSpaceCopy(source: EmbeddingSpace): EmbeddingSpace {
  return embeddingSpaceDecode(JSON.stringify(source));
}
export function embeddingSpaceDecode(wire: string): EmbeddingSpace {
  const node = new BoundedDocumentJson(pdfCodecUtf8(wire),new KnowledgeCancellation()).read();
  const space: EmbeddingSpace = new EmbeddingSpace();
  space.id = node.required('id').string(); space.fingerprint = node.required('fingerprint').string();
  space.configFingerprint = node.required('configFingerprint').string();
  const provider = [EmbeddingProvider.SiliconFlow,EmbeddingProvider.Bailian,EmbeddingProvider.Gemini,EmbeddingProvider.OpenAI].find((item: EmbeddingProvider): boolean => item === node.required('provider').string());
  const region = [EmbeddingRegion.Unselected,EmbeddingRegion.Beijing,EmbeddingRegion.Singapore].find((item: EmbeddingRegion): boolean => item === node.required('region').string());
  const access = [EmbeddingAccess.Public,EmbeddingAccess.Workspace].find((item: EmbeddingAccess): boolean => item === node.required('access').string());
  if (provider === undefined || region === undefined || access === undefined) { throw new KnowledgeFailure('SpaceEnumInvalid','space'); }
  space.provider = provider; space.region = region; space.access = access; space.workspaceId = node.required('workspaceId').string();
  space.requestedModel = node.required('requestedModel').string(); space.returnedModel = node.required('returnedModel').string();
  space.providerRevision = node.required('providerRevision').string(); space.dimension = node.required('dimension').integer();
  space.profileId = node.required('profileId').string(); space.preprocessing = node.required('preprocessing').string();
  space.rolePair = node.required('rolePair').string(); space.normalization = node.required('normalization').string();
  space.metric = node.required('metric').string(); space.detectionFingerprint = node.required('detectionFingerprint').string();
  space.profileRevision = node.optional('profileRevision')?.string() ?? ''; space.tokenizerSha256 = node.optional('tokenizerSha256')?.string() ?? ''; space.profileParameters = node.optional('profileParameters')?.string() ?? ''; space.providerConsistency = node.optional('providerConsistency')?.string() ?? 'UnverifiedRevisionAndHiddenProcessing';
  if (!new RegExp('^kb-[a-f0-9]{32}$').test(space.id) || !Number.isSafeInteger(space.dimension) || space.dimension < 1 || space.dimension > 4096 || space.fingerprint.length === 0 || space.metric !== 'Cosine') { throw new KnowledgeFailure('SpaceIdentityInvalid','space'); }
  return space;
}
