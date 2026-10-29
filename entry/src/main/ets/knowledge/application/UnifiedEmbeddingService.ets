import { UnifiedProcessingRepositoryPort } from '../domain/UnifiedProcessingPorts';
import { UnifiedCorpusTransportPort, UnifiedTokenPort, UnifiedEmbeddingConfigPort } from '../domain/UnifiedEmbeddingPorts';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { ParsedCancellation, ParsedFailure } from '../domain/ParsedDocumentModels';
import { UnifiedProcessingJob, UnifiedProcessingSettings, UnifiedTextInput, UnifiedProcessingAttempt } from '../domain/UnifiedKnowledgeModels';
import { EmbeddingConfig, EmbeddingVectorResponse, TokenEligibilityEvidence } from '../domain/EmbeddingModels';
import { UnifiedVectorRepository } from '../infra/UnifiedVectorRepository';
import { embeddingConfigBinding, unifiedEmbeddingEligible } from '../pipeline/EmbeddingBasisPolicy';
import { parsedUtf8 } from '../pipeline/ParsedDocumentCodec';

export class UnifiedEmbeddingService {
  private repository: UnifiedProcessingRepositoryPort; private vectors: UnifiedVectorRepository; private counter: UnifiedTokenPort; private transport: UnifiedCorpusTransportPort; private config: UnifiedEmbeddingConfigPort; private identity: ParsedIdentityPort;
  constructor(repository: UnifiedProcessingRepositoryPort, vectors: UnifiedVectorRepository, counter: UnifiedTokenPort, transport: UnifiedCorpusTransportPort, config: UnifiedEmbeddingConfigPort, identity: ParsedIdentityPort) { this.repository=repository; this.vectors=vectors; this.counter=counter; this.transport=transport; this.config=config; this.identity=identity; }
  currentConfig(): EmbeddingConfig { return this.config.currentConfig(); }
  async process(job: UnifiedProcessingJob, cancel: ParsedCancellation, admit: (inputHash: string, launch: () => void) => Promise<void>): Promise<void> {
    const config: EmbeddingConfig=this.config.currentConfig(); const binding: string=embeddingConfigBinding(config);
    const settings: UnifiedProcessingSettings=await this.repository.settings('Embedding');
    if (settings.configBinding!==binding || settings.credentialRevision!==config.credentialRevision || config.mutationPending || !settings.baselineAccepted) { throw new ParsedFailure('UnifiedConfigChanged','embedding'); }
    if (job.expected!==job.inputs.length || job.expected<1) { throw new ParsedFailure('UnifiedExpectedSetInvalid','embedding'); }
    const setHash: string=await this.identity.hash(parsedUtf8(job.inputs.map((i: UnifiedTextInput): string=>i.id+'|'+i.inputHash).join('\n')));
    if (setHash!==job.inputHash) { throw new ParsedFailure('ExpectedInputSetHash','embedding'); }
    if (job.stage==='ImageEmbedding') { await this.repository.reserveProxyInputs(job.ownerId,job.annotationId,job.inputs); }
    for (let ordinal: number=0;ordinal<job.inputs.length;ordinal++) {
      cancel.check(); const input=job.inputs[ordinal];
      const currentSettings: UnifiedProcessingSettings=await this.repository.settings('Embedding');
      if (binding!==embeddingConfigBinding(this.config.currentConfig()) || currentSettings.configBinding!==binding || !currentSettings.baselineAccepted || this.config.currentConfig().mutationPending) { throw new ParsedFailure('UnifiedConfigChanged','embedding'); }
      if (await this.identity.hash(parsedUtf8(input.actualText))!==input.inputHash) { throw new ParsedFailure('ActualInputHash','embedding'); }
      if (await this.vectors.reusable(job,input.id,input.inputHash)) { job.completed=ordinal+1; await this.repository.saveJob(job); continue; }
      const proof: TokenEligibilityEvidence=await this.counter.unifiedEvidence(config,input.actualText,input.inputHash);
      if (!unifiedEmbeddingEligible(proof,config,await this.repository.settings('Embedding'))) { throw new ParsedFailure('UnifiedBaselineOrCountRequired','embedding'); }
      const response: EmbeddingVectorResponse=await this.transport.embedUnifiedCorpus(config,input.actualText,proof,cancel,async (launch: () => void): Promise<void>=> {
        if (binding!==embeddingConfigBinding(this.config.currentConfig())) { throw new ParsedFailure('ConfigChanged','embedding'); }
        await admit(input.inputHash,(): void=> { if (binding!==embeddingConfigBinding(this.config.currentConfig())) { throw new ParsedFailure('ConfigChanged','embedding'); } launch(); });
      });
      for (const attempt of await this.repository.attempts(job.id)) { if (attempt.inputHash===input.inputHash && attempt.outcome==='InFlight') { attempt.outcome='Received'; attempt.usageState=response.usage.totalTokens===undefined && response.usage.promptTokens===undefined?'NotReported':'Reported'; attempt.receipt=JSON.stringify(response.usage); await this.repository.saveAttempt(attempt); } }
      cancel.check(); await this.vectors.put(job,ordinal,response,config); job.completed=ordinal+1; job.checkpoint=input.id; await this.repository.saveJob(job);
    }
    await this.vectors.finish(job,cancel);
  }
}
