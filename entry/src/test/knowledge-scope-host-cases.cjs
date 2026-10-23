'use strict';
const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
module.exports=project=>{
  const root=path.join(project,'entry/src/main/ets/knowledge');
  const newFiles=[
    'domain/PdfKnowledgeModels','domain/EmbeddingModels','domain/KnowledgeSearchModels','domain/KnowledgePorts',
    'pipeline/SafeZipPolicy','pipeline/BoundedDocumentJson','pipeline/PdfTableDecoder','pipeline/MineruPdfNormalizer',
    'pipeline/PdfSnapshotCodec','pipeline/PdfStructureChunker','pipeline/PdfMappingPolicy','pipeline/EmbeddingPolicy','pipeline/KnowledgeRetrievalPolicy',
    'application/PdfIngestionService','application/EmbeddingService','application/KnowledgeLifecycleService','application/KnowledgeSearchService',
    'infra/KnowledgeStoreHost','infra/PdfKnowledgeRepository','infra/PdfArchiveAdapter','infra/PdfAssetAdapter',
    'infra/PdfPageAdapter','infra/VectorRdbRepository','infra/EmbeddingCredentialStore','infra/EmbeddingTransportAdapter','infra/KnowledgeAssembly'
  ];
  return [
    {name:'new code strict types no pseudo vectors provider chat or core Kit coupling',run:async()=>{
      for(const relative of newFiles){const code=fs.readFileSync(path.join(root,relative+'.ets'),'utf8');const source=code.replace(/\/\/[^\n]*/g,'');
        assert(!/\b(?:any|unknown)\b|\bas\s+[A-Z]|JSON\.parse|PseudoEmbedding|chat\/completions|decompressFile/.test(source),relative);
        if(/^(domain|pipeline|application)\//.test(relative))assert(!/@kit\.|from ['"][^'"]*\/infra\//.test(code),relative);
      }
      const declaration=fs.readFileSync(path.join(root,'domain/EmbeddingModels.ets'),'utf8');assert(!/apiKey|authorization|secretInput/.test(declaration));
      const credential=fs.readFileSync(path.join(root,'infra/EmbeddingCredentialStore.ets'),'utf8');assert(!/IS_PERSISTENT|mineru\.precision|Preferences/.test(credential));assert(credential.includes('embeddingEndpoint(config, purpose)'));assert(credential.includes('asset.ReturnType.ATTRIBUTES'));
      const transport=fs.readFileSync(path.join(root,'infra/EmbeddingTransportAdapter.ets'),'utf8');assert(transport.includes('autoRedirect: false'));assert(transport.includes('plaintextInException: false'));assert(!/retry|while\s*\(/.test(transport));
    }},
    {name:'unverified native vector and input capabilities cannot report ready',run:async()=>{
      const archive=fs.readFileSync(path.join(root,'infra/PdfArchiveAdapter.ets'),'utf8');assert(archive.includes('await KnowledgeCapabilityService.requireArchive()'));assert(!archive.includes("throw new KnowledgeFailure('NativeZlibRuntimeUnverified'"));
      const vector=fs.readFileSync(path.join(root,'infra/VectorRdbRepository.ets'),'utf8');assert(!vector.includes('VectorStoreRuntimeUnverified'));assert(vector.includes('relationalStore.isVectorSupported()'));assert(vector.includes('getRdbStore(this.context,config)'));assert(vector.includes('FLOATVECTOR(${space.dimension})'));assert(!/CREATE\s+(?:VIRTUAL\s+)?INDEX.*(?:hnsw|ivf)/i.test(vector));
      const embedding=fs.readFileSync(path.join(root,'pipeline/EmbeddingPolicy.ets'),'utf8');assert(embedding.includes('embeddingLocalEligible')&&embedding.includes('InputLimitUnverified')&&embedding.includes('grant.inputEvidence'));const basis=fs.readFileSync(path.join(root,'pipeline/EmbeddingBasisPolicy.ets'),'utf8');assert(basis.includes('!proof.verified')&&basis.includes('embeddingBaselineMatches')&&basis.includes('UnverifiedRevisionAndHiddenProcessing'));
    }},
    {name:'parse deletion and every physical cleanup require shared protection',run:async()=>{
      const parse=fs.readFileSync(path.join(root,'application/DocumentParseService.ets'),'utf8');
      const remove=parse.slice(parse.indexOf('async deleteOriginal('),parse.indexOf('private async deleteOriginalGuarded('));assert(remove.includes('withSource<void>'));assert(remove.includes('assertDeletable'));
      const cleanup=parse.slice(parse.indexOf('async retryCleanup('),parse.indexOf('async inspectOccupancy('));assert(cleanup.indexOf('assertCleanup')<cleanup.indexOf('.remove(cleanup.assets)'));assert(cleanup.includes('protection === undefined'));
      const ports=fs.readFileSync(path.join(root,'domain/TextKnowledgePorts.ets'),'utf8');assert(ports.includes('interface TextCandidatePort extends TextRepositoryPort'));
    }}
  ];
};
