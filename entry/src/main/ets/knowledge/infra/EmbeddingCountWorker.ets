import { BgeM3TokenCounter, BgeM3CountInput, BgeM3CountEvidence } from './EmbeddingTokenCounter';
import { taskpool } from '@kit.ArkTS';

@Concurrent
export function embeddingCountWorker(weights: string, input: BgeM3CountInput): BgeM3CountEvidence {
  if (taskpool.Task.isCanceled()) { throw new Error('EmbeddingCountCanceled'); }
  const result: BgeM3CountEvidence = new BgeM3TokenCounter(weights).count(input);
  if (taskpool.Task.isCanceled()) { throw new Error('EmbeddingCountCanceled'); } return result;
}
