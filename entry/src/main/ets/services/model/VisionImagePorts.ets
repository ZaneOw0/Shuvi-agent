import { VisionChatImage } from './VisionChatProtocol';

export class VisionPreparedImage {
  displayName: string = '';
  image: VisionChatImage = new VisionChatImage();
}

export interface VisionImagePreparerPort {
  prepare(uri: string, displayName: string): Promise<VisionPreparedImage>;
}

export class VisionImageFailure extends Error {
  code: string;
  constructor(code: string) { super(code); this.code = code; }
}
