import { RuntimeVisionSession } from './RuntimeVisionSession';
import { VisionImagePreparer } from './VisionImagePreparer';

export class RuntimeVisionService {
  static readonly session: RuntimeVisionSession = new RuntimeVisionSession(new VisionImagePreparer());
}
