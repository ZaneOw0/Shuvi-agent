import { DocxPathStep, DocxOriginal, DocxSnapshot, DocxProjection, DocxRelationship } from './DocxKnowledgeModels';
import { KnowledgeCancellation } from './PdfKnowledgeModels';

export class DocxXmlAttribute { qname: string = ''; namespace: string = ''; localName: string = ''; text: string = ''; }
export class DocxXmlNode {
  namespace: string = ''; localName: string = ''; path: DocxPathStep[] = []; attributes: DocxXmlAttribute[] = [];
  children: DocxXmlNode[] = []; text: string = ''; order: number = 0;
}
export class DocxXmlWorkerResult { root: DocxXmlNode = new DocxXmlNode(); failure: string = ''; }
export class DocxProjectionWorkerResult { projection: DocxProjection = new DocxProjection(); failure: string = ''; }
export class DocxNativeWorkerResult { snapshot: DocxSnapshot = new DocxSnapshot(); failure: string = ''; }
export class DocxNativeWorkerInput {
  original: DocxOriginal = new DocxOriginal(); root: DocxXmlNode = new DocxXmlNode();
  styles: DocxXmlNode | undefined = undefined; numbering: DocxXmlNode | undefined = undefined;
  relationships: DocxRelationship[] = [];
}
export interface DocxXmlPort { parse(bytes: Uint8Array, cancel: KnowledgeCancellation): Promise<DocxXmlNode>; }
export function docxXmlAttr(node: DocxXmlNode, namespace: string, name: string): string | undefined { return node.attributes.find((a: DocxXmlAttribute): boolean => a.namespace === namespace && a.localName === name)?.text; }
export function docxXmlChild(node: DocxXmlNode, namespace: string, name: string): DocxXmlNode | undefined { return node.children.find((child: DocxXmlNode): boolean => child.namespace === namespace && child.localName === name); }
export function docxXmlChildren(node: DocxXmlNode, namespace: string, name: string): DocxXmlNode[] { return node.children.filter((child: DocxXmlNode): boolean => child.namespace === namespace && child.localName === name); }
