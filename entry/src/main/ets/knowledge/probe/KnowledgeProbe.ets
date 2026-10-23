import { deviceInfo } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { relationalStore, intelligence } from '@kit.ArkData';
import { retrieval } from '@kit.DataAugmentationKit';
import { common } from '@kit.AbilityKit';
import { CapabilityReport, ProbeStep } from '../domain/KnowledgeTypes';
import { KB_STORE_NAME } from '../infra/RdbKnowledgeStore';

export async function probeCapabilities(context: common.Context): Promise<CapabilityReport> {
  const steps: ProbeStep[] = [];
  steps.push(apiVersionStep());
  steps.push(probeVectorSupport());
  steps.push(probeTokenizerSupport());
  steps.push(await probeRetrieval(context));
  steps.push(await probeTextEmbedding());
  const vectorSupported: boolean = relationalStore.isVectorSupported();
  const report: CapabilityReport = {
    steps: steps,
    searchPath: retrievalAvailable(steps)
      ? 'retrieval-retrieveRdb'
      : (vectorSupported ? 'relationalStore-fts + brute-force-knn' : 'relationalStore-fts only'),
    vectorStoreSupported: vectorSupported
  };
  return report;
}

function apiVersionStep(): ProbeStep {
  return { name: 'sdkApiVersion', ok: true, detail: `${deviceInfo.sdkApiVersion}` };
}

function probeVectorSupport(): ProbeStep {
  let supported: boolean = false;
  try {
    supported = relationalStore.isVectorSupported();
  } catch (error) {
    const businessError: BusinessError = error as BusinessError;
    return { name: 'isVectorSupported', ok: false, detail: describeError(businessError) };
  }
  return { name: 'isVectorSupported', ok: supported, detail: `${supported}` };
}

function probeTokenizerSupport(): ProbeStep {
  let supported: boolean = false;
  try {
    supported = relationalStore.isTokenizerSupported(relationalStore.Tokenizer.CUSTOM_TOKENIZER);
  } catch (error) {
    const businessError: BusinessError = error as BusinessError;
    return { name: 'isTokenizerSupported(CUSTOM_TOKENIZER)', ok: false, detail: describeError(businessError) };
  }
  return { name: 'isTokenizerSupported(CUSTOM_TOKENIZER)', ok: supported, detail: `${supported}` };
}

async function probeRetrieval(context: common.Context): Promise<ProbeStep> {
  try {
    const storeConfig: relationalStore.StoreConfig = {
      name: KB_STORE_NAME,
      securityLevel: relationalStore.SecurityLevel.S3
    };
    const channel: retrieval.ChannelConfig = {
      channelType: retrieval.ChannelType.INVERTED_INDEX_DATABASE,
      context: context,
      dbConfig: storeConfig
    };
    const config: retrieval.RetrievalConfig = { channelConfigs: [channel] };
    const retriever: retrieval.Retriever = await retrieval.getRetriever(config);
    const callable: boolean = retriever !== undefined && retriever !== null;
    return { name: 'retrieval.getRetriever', ok: callable, detail: callable ? 'available' : 'undefined' };
  } catch (error) {
    const businessError: BusinessError = error as BusinessError;
    return { name: 'retrieval.getRetriever', ok: false, detail: describeError(businessError) };
  }
}

async function probeTextEmbedding(): Promise<ProbeStep> {
  try {
    const config: intelligence.ModelConfig = {
      version: intelligence.ModelVersion.BASIC_MODEL,
      isNpuAvailable: false
    };
    const model: intelligence.TextEmbedding = await intelligence.getTextEmbeddingModel(config);
    await model.loadModel();
    const vector: Array<number> = await model.getEmbedding('探测文本');
    return { name: 'intelligence.getTextEmbeddingModel', ok: vector.length > 0, detail: `dim=${vector.length}` };
  } catch (error) {
    const businessError: BusinessError = error as BusinessError;
    return { name: 'intelligence.getTextEmbeddingModel', ok: false, detail: describeError(businessError) };
  }
}

function retrievalAvailable(steps: ProbeStep[]): boolean {
  for (let i = 0; i < steps.length; i++) {
    if (steps[i].name === 'retrieval.getRetriever') {
      return steps[i].ok;
    }
  }
  return false;
}

function describeError(error: BusinessError): string {
  if (error.code === undefined) {
    return `unavailable(${error.message})`;
  }
  return `${error.code}: ${error.message}`;
}
