export class EmbeddingPinnedBasis {
  static readonly model: string = 'BAAI/bge-m3';
  static readonly profile: string = 'BGE-M3-MS-a46a138-fast-scalar-v1';
  static readonly revision: string = 'a46a13810c9d7f876fccd8d7017512ebc265d2c1';
  static readonly tokenizer: string = '21106b6d7dab2952c1d496fb21d5dc9db75c28ed361a05f5020bbba27810dd08';
  static readonly weights: string = 'd05d0175a046b03c786c08ef8d5f396ddc9330516c76067cfae6a3f0ad19ff41';
  static readonly metadata: string = '4f0e7a8a26e481c9c2dade315528e60630d2075aa5801363b93f9bfbd224603e';
  static readonly evidence: string = 'BGE-M3-SCALAR-BOUND-1';
  static readonly parameters: string = 'SingleString;Fast;SpecialTokens;NoPadding;NoTruncation;NoHiddenPrefix';
  static readonly policy: string = 'PDF-EMBED-TEXT-1';
}
export class EmbeddingBaselineAcceptance {
  state: string = 'NotAccepted'; model: string = EmbeddingPinnedBasis.model; profile: string = EmbeddingPinnedBasis.profile;
  revision: string = EmbeddingPinnedBasis.revision; tokenizer: string = EmbeddingPinnedBasis.tokenizer;
  weights: string = EmbeddingPinnedBasis.weights; metadata: string = EmbeddingPinnedBasis.metadata;
  parameters: string = EmbeddingPinnedBasis.parameters; policy: string = EmbeddingPinnedBasis.policy;
  configFingerprint: string = ''; configRevision: number = -1; acceptedAt: number = 0;
  providerRevision: string = 'NotReported'; providerConsistency: string = 'UnverifiedRevisionAndHiddenProcessing';
}
export class EmbeddingInputReview {
  chunkId: string = ''; ordinal: number = 0; hash: string = ''; bindingHash: string = ''; state: string = ''; bound: number = -1;
  eligible: boolean = false; attemptState: string = 'NotSent';
}
export class EmbeddingDryReview {
  documentId: string = ''; generation: string = ''; snapshotHash: string = ''; configFingerprint: string = ''; setHash: string = '';
  rows: EmbeddingInputReview[] = []; safe: number = 0; unproven: number = 0; invalid: number = 0; eligible: number = 0;
  totalBound: number = 0; maxBound: number = 0; recipient: string = 'https://api.siliconflow.cn/v1/embeddings';
  model: string = EmbeddingPinnedBasis.model; baseline: EmbeddingBaselineAcceptance = new EmbeddingBaselineAcceptance();
}
