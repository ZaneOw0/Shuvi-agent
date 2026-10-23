import { ParsedCancellation, ParsedImageAsset } from './ParsedDocumentModels';
import { UnifiedProcessingSettings } from './UnifiedKnowledgeModels';

export class VisionPolicyVersions {
  static readonly model: string = 'deepseek-flash';
  static readonly prompt: string = 'SHUVI-IMAGE-DESCRIPTION-ZH-1';
  static readonly schema: string = 'SHUVI-IMAGE-ANNOTATION-1';
  static readonly parameters: string = 'ORIGINAL-NOTHINK-NOSTREAM-2048-1';
}
export class VisionSettings extends UnifiedProcessingSettings {
  constructor() { super(); this.purpose = 'Vision'; this.recipient = 'DeepSeek'; this.model = VisionPolicyVersions.model; this.policy = VisionPolicyVersions.prompt; this.imageScope = 'CurrentManagedImageOnly'; }
}
export class VisionCredentialStatus { present: boolean = false; revision: number = 0; failure: string = ''; }
export class VisionUsage {
  state: string = 'NotReported'; promptTokens?: number; completionTokens?: number; totalTokens?: number;
}
export class VisionResponse {
  description: string = ''; tags: string[] = []; model: string = ''; responseId: string = '';
  finishReason: string = ''; usage: VisionUsage = new VisionUsage(); fingerprint: string = '';
}
export class VisionRequestIdentity {
  asset: ParsedImageAsset = new ParsedImageAsset(); imageHash: string = ''; settingsRevision: number = 0;
  costRevision: number = 0; credentialRevision: number = 0; cacheKey: string = ''; attemptId: string = '';
}
export interface VisionCredentialPort {
  status(): Promise<VisionCredentialStatus>; save(secret: string): Promise<void>; remove(): Promise<void>;
}
export interface VisionTransportPort {
  describe(request: VisionRequestIdentity, bytes: Uint8Array, cancel: ParsedCancellation, admit: (launch: () => void) => Promise<void>): Promise<VisionResponse>;
}
export interface VisionAdmissionPort {
  admit(request: VisionRequestIdentity): Promise<void>;
}
export class VisionFailure extends Error {
  category: string; stage: string; launched: boolean;
  constructor(category: string, stage: string, launched: boolean = false) { super(`${category} / ${stage}`); this.category = category; this.stage = stage; this.launched = launched; }
}
