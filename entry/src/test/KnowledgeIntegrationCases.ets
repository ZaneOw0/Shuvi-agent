import { PdfLocator, PdfMappingEvidence, PdfMappingTier } from '../main/ets/knowledge/domain/PdfKnowledgeModels';
import { pdfEvidenceLocator } from '../main/ets/knowledge/pipeline/PdfMappingPolicy';
import { PdfEvidenceContext } from '../main/ets/knowledge/domain/PdfLocalModels';
import { KnowledgeHit, KnowledgeChannel, KnowledgeHistory, KnowledgeHistoryCursor, KnowledgeHistoryPage, KnowledgeSourceKind } from '../main/ets/knowledge/domain/KnowledgeSearchModels';
import { knowledgeKeywordList, knowledgeFuse, knowledgeMergeHistory } from '../main/ets/knowledge/pipeline/KnowledgeRetrievalPolicy';
export interface KnowledgeIntegrationTestCase { name: string; run: () => Promise<void>; }
export function knowledgeIntegrationCases(): KnowledgeIntegrationTestCase[] { return [
  { name: '双源历史游标只推进实际消费源无偏移漏页',run: async (): Promise<void> => {
    const kb: KnowledgeHistory = new KnowledgeHistory(); kb.id = 'kb-a'; kb.createdAt = 10;
    const old: KnowledgeHistory = new KnowledgeHistory(); old.id = 'text-a'; old.source = 'text'; old.createdAt = 9;
    const cursor: KnowledgeHistoryCursor = new KnowledgeHistoryCursor();
    const first: KnowledgeHistoryPage = knowledgeMergeHistory([kb],[old],cursor,1);
    if (first.records.length !== 1 || first.next.kbCreated !== 10 || first.next.textCreated !== Number.MAX_SAFE_INTEGER) { throw new Error('Unconsumed history source advanced'); }
    const second: KnowledgeHistoryPage = knowledgeMergeHistory([],[old],first.next,1);
    if (second.records[0].id !== 'text-a' || second.next.textCreated !== 9 || second.next.kbCreated !== 10) { throw new Error('History skipped or duplicated source'); }
  } },
  { name: 'M1/PDF合成单keyword票且RRF60去重稳定top5', run: async (): Promise<void> => {
    const text: KnowledgeHit = new KnowledgeHit(); text.id = 'text:a'; text.keywordScore = 2;
    const pdf: KnowledgeHit = new KnowledgeHit(); pdf.id = 'pdf:b'; pdf.keywordScore = 1; pdf.sourceKind = KnowledgeSourceKind.Pdf;
    const keyword: KnowledgeHit[] = knowledgeKeywordList([text],[pdf]);
    const vector: KnowledgeHit = new KnowledgeHit(); vector.id = 'pdf:b'; vector.sourceKind = KnowledgeSourceKind.Pdf; vector.spaceId = 'unit-space';
    const hits: KnowledgeHit[] = knowledgeFuse(keyword,[vector]);
    if (hits.length !== 2 || hits[0].id !== 'pdf:b' || hits[0].channels.length !== 2 || Math.abs(hits[0].rrfScore-(1/62+1/61)) > 1e-12 || hits[1].channels.indexOf(KnowledgeChannel.Vector) >= 0) { throw new Error('Route voting or RRF failed'); }
  } },
  { name: 'RRF拒绝混空间和M1伪向量票',run: async (): Promise<void> => {
    const a: KnowledgeHit = new KnowledgeHit(); a.id = 'pdf:a'; a.sourceKind = KnowledgeSourceKind.Pdf; a.spaceId = 'space-a';
    const b: KnowledgeHit = new KnowledgeHit(); b.id = 'pdf:b'; b.sourceKind = KnowledgeSourceKind.Pdf; b.spaceId = 'space-b';
    let rejected: boolean = false; try { knowledgeFuse([],[a,b]); } catch { rejected = true; } if (!rejected) { throw new Error('Mixed spaces accepted'); }
    a.sourceKind = KnowledgeSourceKind.Text; rejected = false; try { knowledgeFuse([],[a]); } catch { rejected = true; } if (!rejected) { throw new Error('M1 received vector vote'); }
  } },
  { name: '原件几何相同不等页身份且泛泛部分确认不授权高亮', run: async (): Promise<void> => {
    const locator: PdfLocator = new PdfLocator(); locator.originalHash = 'a'.repeat(64); locator.originalVersion = 1; locator.providerPageIndex0 = 2;
    if (pdfEvidenceLocator(locator,[]).tier !== PdfMappingTier.Unknown) { throw new Error('Unverified mapping upgraded'); }
    const evidence: PdfMappingEvidence = new PdfMappingEvidence(); evidence.id = 'page-specific'; evidence.originalHash = locator.originalHash; evidence.originalVersion = 1; evidence.providerPageIndex0 = 2; evidence.originalPageIndex0 = 4; evidence.tier = PdfMappingTier.Page; evidence.evidenceSource = 'unit-independent-page-proof';
    if (pdfEvidenceLocator(locator,[evidence]).tier !== PdfMappingTier.Unknown) { throw new Error('Incomplete identity upgraded'); }
    const context: PdfEvidenceContext = new PdfEvidenceContext(); context.originalHash = locator.originalHash; context.originalVersion = 1; context.zipHash = 'b'.repeat(64); context.snapshotHash = 'c'.repeat(64); context.snapshotId = 'snapshot'; context.generation = 'generation'; context.nodeId = 'node'; context.protocol = 'fixture'; context.originalPages = 5; context.providerPage = 2; context.crop.right = 100; context.crop.top = 200; context.media.right = 100; context.media.top = 200;
    evidence.zipHash = context.zipHash; evidence.snapshotHash = context.snapshotHash; evidence.snapshotId = context.snapshotId; evidence.generation = context.generation; evidence.nodeId = context.nodeId; evidence.protocol = context.protocol;
    evidence.unit = 'Points'; evidence.origin = 'BottomLeftYUp'; evidence.referenceBox = 'CropBox'; evidence.rotation = 0; evidence.transformVersion = 'PDF-CROP-ROTATE-1'; evidence.crop = context.crop; evidence.media = context.media;
    const checked: PdfLocator = pdfEvidenceLocator(locator,[evidence],context); if (checked.tier !== PdfMappingTier.Page || checked.candidatePhysicalPageIndex0 !== 4 || checked.regionEvidenceIds.length !== 0) { throw new Error('Page-only evidence highlighted'); }
  } }
]; }
export function knowledgePlatformCases(): string[] {
  return ['M1 empty bootstrap before extension','existing M1 layout and history byte preservation','extension transaction rollback/reopen','last repository lease closes handle only once','publish vs cleanupClaim both write orders','durable pin/job atomic fault boundaries','abandon waits read leases before Released','vector row readback and cosine KNN isolated test space','archive/delete eligibility mirror and final authority filter','process restart never auto-resumes cloud','PDF original crop/rotation/multiple evidence regions'];
}
export class KnowledgeSemanticQualityCase {
  kind: string = ''; question: string = ''; goldSourceIds: string[] = []; goldVerified: boolean = false;
}
export function knowledgeSemanticQualityPreparation(): KnowledgeSemanticQualityCase[] {
  const cases: KnowledgeSemanticQualityCase[] = [];
  const questions: string[] = ['周一想在北馆看书，最早几点能进去？','周日去南馆，下午几点必须离开？','普通纸书续借一次后，总共能借多少天？','一本书晚还很久，罚款最多收多少？','明天同一时间用研讨室，现在预约来得及吗？','轮椅使用者应从哪个门坐电梯？','宿舍出发去北馆该坐哪班车，几点开？','借书证不见了，补办前先做什么？','北馆不是每天开放，哪两天不开？','哪些印刷资料不能带走借回家？','不要到北馆，只去南馆，该避开哪条班车？','同一天能否订两场研讨室？','馆长的电话号码是什么？','阅览室空调固定设定多少度？','挂失可否通过手机 App 办理？','蓝线班车节假日的发车间隔是多少？'];
  const sources: string[] = ['F01','F02','F03','F04','F05','F06','F07','F08','F01','F03','F07','F05','','','',''];
  for (let at: number = 0; at < questions.length; at++) { const item: KnowledgeSemanticQualityCase = new KnowledgeSemanticQualityCase(); item.kind = at < 8 ? 'paraphrase' : at < 12 ? 'negation' : 'no-answer'; item.question = questions[at]; item.goldSourceIds = sources[at].length > 0 ? [sources[at]] : []; item.goldVerified = true; cases.push(item); }
  return cases;
}
