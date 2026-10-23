import { xml, taskpool, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { DocxFailure, DocxLimits, DocxPathStep } from '../domain/DocxKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { pdfStrictUtf8 } from '../pipeline/SafeZipPolicy';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { documentUtf8Bytes } from '../domain/DocumentParseModels';
import { DocxXmlAttribute, DocxXmlNode } from '../domain/DocxXmlModels';

class DocxLexicalTag { qname: string = ''; attributes: DocxXmlAttribute[] = []; }
class DocxNamespaceBinding { prefix: string = ''; namespace: string = ''; }
function docxSystemNameMatches(actual: string, localName: string, qualifiedName: string): boolean {
  return actual === localName || actual === qualifiedName;
}
function docxSystemXmlFailure(error: BusinessError, operation: string): string {
  const code: string = typeof error?.code === 'number' && Number.isSafeInteger(error.code) ? `${error.code}` : 'NoCode';
  const message: string = typeof error?.message === 'string' ? error.message.toLowerCase() : '';
  const reason: string = message.includes('namespace') || message.includes('prefix') ? 'Namespace' :
    message.includes('callback') || message.includes('function') ? 'Callback' :
    message.includes('parameter') || message.includes('argument') ? 'Parameter' :
    message.includes('entity') ? 'Entity' : message.includes('mismatch') || message.includes('syntax') || message.includes('illegal') ? 'Syntax' : 'Unknown';
  return `SystemXml${operation}${reason}_${code}`;
}
function docxXmlEntity(text: string): string {
  let result: string = ''; let at: number = 0;
  while (at < text.length) {
    if (text[at] !== '&') { result += text[at++]; continue; }
    const end: number = text.indexOf(';',at+1); if (end < 0 || end-at > 32) { throw new DocxFailure('XmlEntityInvalid','xml'); }
    const token: string = text.slice(at+1,end);
    if (token === 'amp') { result += '&'; } else if (token === 'lt') { result += '<'; } else if (token === 'gt') { result += '>'; } else if (token === 'apos') { result += "'"; } else if (token === 'quot') { result += '"'; }
    else if (new RegExp('^#([0-9]+|x[0-9a-fA-F]+)$').test(token)) {
      const n: number = token.startsWith('#x') ? Number.parseInt(token.slice(2),16) : Number(token.slice(1));
      if (!Number.isSafeInteger(n) || n < 1 || n > 0x10ffff || n >= 0xd800 && n <= 0xdfff) { throw new DocxFailure('XmlEntityInvalid','xml'); } result += String.fromCodePoint(n);
    } else { throw new DocxFailure('XmlCustomEntityUnsupported','xml'); }
    at = end+1;
  } return result;
}
// Only start-tag qualified names/attributes are adapted. The system parser remains the XML grammar/text authority.
function docxLexicalTags(text: string): DocxLexicalTag[] {
  const tags: DocxLexicalTag[] = []; let at: number = 0;
  while (at < text.length) {
    const start: number = text.indexOf('<',at); if (start < 0) { break; }
    if (text.startsWith('<!--',start)) { const end: number = text.indexOf('-->',start+4); if (end < 0) { throw new DocxFailure('XmlCommentUnclosed','xml'); } at = end+3; continue; }
    if (text.startsWith('<![CDATA[',start)) { const end: number = text.indexOf(']]>',start+9); if (end < 0) { throw new DocxFailure('XmlCdataUnclosed','xml'); } at = end+3; continue; }
    if (text.startsWith('<!',start)) { throw new DocxFailure('XmlDoctypeOrDeclarationUnsupported','xml'); }
    if (text.startsWith('<?',start)) { const end: number = text.indexOf('?>',start+2); if (end < 0) { throw new DocxFailure('XmlInstructionUnclosed','xml'); } at = end+2; continue; }
    if (text.startsWith('</',start)) { const end: number = text.indexOf('>',start+2); if (end < 0) { throw new DocxFailure('XmlEndUnclosed','xml'); } at = end+1; continue; }
    at = start+1; const nameStart: number = at;
    while (at < text.length && !new RegExp('[\\s/>]').test(text[at])) { at++; }
    const tag: DocxLexicalTag = new DocxLexicalTag(); tag.qname = text.slice(nameStart,at);
    while (at < text.length) {
      while (at < text.length && new RegExp('\\s').test(text[at])) { at++; }
      if (text[at] === '/' || text[at] === '>') { const end: number = text.indexOf('>',at); if (end < 0) { throw new DocxFailure('XmlStartUnclosed','xml'); } at = end+1; break; }
      const keyStart: number = at;
      while (at < text.length && !new RegExp('[\\s=]').test(text[at])) { at++; }
      const attr: DocxXmlAttribute = new DocxXmlAttribute(); attr.qname = text.slice(keyStart,at);
      while (at < text.length && new RegExp('\\s').test(text[at])) { at++; }
      if (text[at++] !== '=') { throw new DocxFailure('XmlAttributeGrammar','xml'); }
      while (at < text.length && new RegExp('\\s').test(text[at])) { at++; }
      const quote: string = text[at++]; if (quote !== '"' && quote !== "'") { throw new DocxFailure('XmlAttributeQuote','xml'); }
      const end: number = text.indexOf(quote,at); if (end < 0) { throw new DocxFailure('XmlAttributeUnclosed','xml'); }
      attr.text = docxXmlEntity(text.slice(at,end).replace(new RegExp('[\t\r\n]','g'),' ')); at = end+1;
      tag.attributes.push(attr); if (tag.attributes.length > DocxLimits.attributes) { throw new DocxFailure('XmlAttributeBudget','xml'); }
    }
    tags.push(tag); if (tags.length > DocxLimits.events) { throw new DocxFailure('XmlEventBudget','xml'); }
  } return tags;
}
function docxXmlText(bytes: Uint8Array): string {
  if (bytes.length < 1 || bytes.length > DocxLimits.xml) { throw new DocxFailure('XmlBytesBudget','xml'); }
  const le: boolean = bytes[0] === 0xff && bytes[1] === 0xfe; const be: boolean = bytes[0] === 0xfe && bytes[1] === 0xff;
  const utf16: boolean = le || be || bytes[0] === 0x3c && bytes[1] === 0 || bytes[0] === 0 && bytes[1] === 0x3c;
  const text: string = utf16 ? util.TextDecoder.create(le || bytes[0] === 0x3c ? 'utf-16le' : 'utf-16be',{ fatal: true }).decodeToString(bytes.subarray(le || be ? 2 : 0)) : pdfStrictUtf8(bytes.subarray(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf ? 3 : 0));
  const declaration: RegExpExecArray | null = new RegExp('^<\\?xml\\s[^?]*encoding\\s*=\\s*["\u0027]([^"\u0027]+)["\u0027]','i').exec(text);
  if (declaration !== null) {
    const encoding: string = declaration[1].toLowerCase();
    if (utf16 ? encoding !== 'utf-16' && encoding !== (le || bytes[0] === 0x3c ? 'utf-16le' : 'utf-16be') : encoding !== 'utf-8' && encoding !== 'utf8') { throw new DocxFailure('XmlEncodingConflictOrUnsupported','xml'); }
  }
  return utf16 ? text.replace(new RegExp('^(<\\?xml\\s[^?]*encoding\\s*=\\s*)["\u0027][^"\u0027]+["\u0027]','i'),'$1"UTF-8"') : text;
}
export function docxParseXml(bytes: Uint8Array, cancel: KnowledgeCancellation): DocxXmlNode {
  const text: string = docxXmlText(bytes); const tags: DocxLexicalTag[] = docxLexicalTags(text);
   const stack: DocxXmlNode[] = []; const qualifiedNames: string[] = []; const bindings: DocxNamespaceBinding[][] = []; let root: DocxXmlNode | undefined = undefined;
  let tagAt: number = 0; let events: number = 0; let ended: boolean = false; let failure: string = ''; let closed: boolean = false;
   const options: xml.ParseOptions = { supportDoctype: false, ignoreNameSpace: true,
    tokenValueCallbackFunction: (type: xml.EventType, info: xml.ParseInfo): boolean => {
      try {
        cancel.check(); if (taskpool.Task.isCanceled()) { throw new DocxFailure('XmlCanceled','xml'); }
         if (++events > DocxLimits.events || info.getDepth() > DocxLimits.depth) { throw new DocxFailure('XmlEventDepthBudget','xml'); }
         if (type === xml.EventType.START_TAG) {
           if (info.getAttributeCount() > DocxLimits.attributes) { throw new DocxFailure('XmlAttributeBudget','xml'); }
          if (closed) { throw new DocxFailure('XmlMultipleRoots','xml'); }
          const tag: DocxLexicalTag | undefined = tags[tagAt++]; if (tag === undefined) { throw new DocxFailure('XmlQNameAlignment','xml'); }
          const scope: DocxNamespaceBinding[] = bindings.length === 0 ? [] : bindings[bindings.length-1].slice();
          for (const attr of tag.attributes) {
            if (attr.qname === 'xmlns' || attr.qname.startsWith('xmlns:')) {
              const prefix: string = attr.qname === 'xmlns' ? '' : attr.qname.slice(6); const old: number = scope.findIndex((b: DocxNamespaceBinding): boolean => b.prefix === prefix);
              if (old >= 0) { scope.splice(old,1); } const binding: DocxNamespaceBinding = new DocxNamespaceBinding(); binding.prefix = prefix; binding.namespace = attr.text; scope.push(binding);
            }
          }
          const node: DocxXmlNode = new DocxXmlNode(); const colon: number = tag.qname.indexOf(':'); const prefix: string = colon < 0 ? '' : tag.qname.slice(0,colon);
          node.localName = colon < 0 ? tag.qname : tag.qname.slice(colon+1); node.namespace = scope.find((b: DocxNamespaceBinding): boolean => b.prefix === prefix)?.namespace ?? '';
           // Namespace expansion is deliberately disabled in the platform parser.
           // Restore the original declarations here without depending on token URI representation.
           if (!docxSystemNameMatches(info.getName(),node.localName,tag.qname) || prefix.length > 0 && node.namespace.length === 0) { throw new DocxFailure('XmlNamespaceAlignment','xml'); }
          for (const attr of tag.attributes) {
            if (attr.qname === 'xmlns' || attr.qname.startsWith('xmlns:')) { continue; }
            const split: number = attr.qname.indexOf(':'); attr.localName = split < 0 ? attr.qname : attr.qname.slice(split+1);
            attr.namespace = split < 0 ? '' : attr.qname.startsWith('xml:') ? 'http://www.w3.org/XML/1998/namespace' : scope.find((b: DocxNamespaceBinding): boolean => b.prefix === attr.qname.slice(0,split))?.namespace ?? '';
            if (split >= 0 && attr.namespace.length === 0 || node.attributes.some((old: DocxXmlAttribute): boolean => old.namespace === attr.namespace && old.localName === attr.localName)) { throw new DocxFailure('XmlAttributeNamespaceConflict','xml'); } node.attributes.push(attr);
          }
          const parent: DocxXmlNode | undefined = stack[stack.length-1]; const step: DocxPathStep = new DocxPathStep(); step.namespace = node.namespace; step.localName = node.localName;
          step.ordinal = parent === undefined ? 0 : parent.children.filter((child: DocxXmlNode): boolean => child.namespace === node.namespace && child.localName === node.localName).length;
          node.path = parent === undefined ? [step] : parent.path.concat([step]); node.order = tagAt-1;
          if (parent !== undefined) { parent.children.push(node); } else { root = node; }
           stack.push(node); qualifiedNames.push(tag.qname); bindings.push(scope);
         } else if (type === xml.EventType.END_TAG) {
           const node: DocxXmlNode | undefined = stack.pop(); const qualifiedName: string | undefined = qualifiedNames.pop(); bindings.pop();
           if (node === undefined || qualifiedName === undefined || !docxSystemNameMatches(info.getName(),node.localName,qualifiedName)) { throw new DocxFailure('XmlRootNotClosed','xml'); } if (stack.length === 0) { closed = true; }
        } else if (type === xml.EventType.END_DOCUMENT) { ended = true; }
        else if ([xml.EventType.TEXT,xml.EventType.CDSECT,xml.EventType.WHITESPACE,xml.EventType.ENTITY_REFERENCE].indexOf(type) >= 0) {
          const node: DocxXmlNode | undefined = stack[stack.length-1]; const content: string = info.getText();
          if (documentUtf8Bytes(content) > DocxLimits.textEvent) { throw new DocxFailure('XmlTextEventBudget','xml'); }
          if (node !== undefined) { node.text += content; } else if (content.trim().length > 0) { throw new DocxFailure('XmlTextOutsideRoot','xml'); }
        } else if (type === xml.EventType.DOCDECL) { throw new DocxFailure('XmlDoctypeUnsupported','xml'); }
        return true;
      } catch (error) { failure = error instanceof DocxFailure ? error.category : 'XmlCanceledOrBudget'; return false; }
    }
  };
  const input: Uint8Array = pdfCodecUtf8(text); const buffer: ArrayBuffer = new ArrayBuffer(input.length); new Uint8Array(buffer).set(input);
   let parser: xml.XmlPullParser;
   try { parser = new xml.XmlPullParser(buffer,'utf-8'); }
   catch (error) { throw new DocxFailure(docxSystemXmlFailure(error,'Construct'),'xml'); }
   try { parser.parseXml(options); }
   catch (error) { throw new DocxFailure(failure || docxSystemXmlFailure(error,'Parse'),'xml'); }
  if (failure.length > 0 || !ended || !closed || root === undefined || stack.length !== 0 || tagAt !== tags.length) { throw new DocxFailure(failure || 'XmlIncomplete','xml'); }
  cancel.check(); return root;
}
