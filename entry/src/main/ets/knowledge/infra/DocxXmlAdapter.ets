import { taskpool } from '@kit.ArkTS';
import { DocxFailure } from '../domain/DocxKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { DocxXmlNode, DocxXmlPort, DocxXmlWorkerResult } from '../domain/DocxXmlModels';
import { docxParseXml } from './DocxXmlReader';

export { docxParseXml } from './DocxXmlReader';

@Concurrent
function docxXmlWorker(bytes: Uint8Array, deadline: number): DocxXmlWorkerResult {
  const result: DocxXmlWorkerResult = new DocxXmlWorkerResult(); const cancel: KnowledgeCancellation = new KnowledgeCancellation(); cancel.deadline = deadline;
  try { result.root = docxParseXml(bytes,cancel); } catch (error) { result.failure = error instanceof DocxFailure ? error.category : 'SystemXmlFailed'; } return result;
}
export class DocxXmlAdapter implements DocxXmlPort {
  async parse(bytes: Uint8Array, cancel: KnowledgeCancellation): Promise<DocxXmlNode> {
    cancel.check(); const task: taskpool.GenericsTask<[Uint8Array,number],DocxXmlWorkerResult> = new taskpool.GenericsTask<[Uint8Array,number],DocxXmlWorkerResult>(docxXmlWorker,bytes,cancel.deadline);
    const result: DocxXmlWorkerResult = await taskpool.execute<[Uint8Array,number],DocxXmlWorkerResult>(task); cancel.check();
    if (result.failure.length > 0) { throw new DocxFailure(result.failure,'xml'); } return result.root;
  }
}
// Preflight already runs inside the copy worker; avoid nested task dispatch.
export class DocxWorkerXmlAdapter implements DocxXmlPort {
  async parse(bytes: Uint8Array, cancel: KnowledgeCancellation): Promise<DocxXmlNode> { return docxParseXml(bytes,cancel); }
}
