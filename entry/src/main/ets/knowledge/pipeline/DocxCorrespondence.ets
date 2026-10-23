import { DocxProjection, DocxProjectionRange, DocxSnapshot, DocxNativeNode, DocxCorrespondence, DocxCoverageIssue, DocxCoverageKind, DocxFailure, DocxHeadingIdentity } from '../domain/DocxKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';

function docxProjectionAppend(p: DocxProjection, text: string, start: number, end: number): void {
  const last: DocxProjectionRange | undefined = p.ranges[p.ranges.length-1];
  if (last !== undefined && last.end-last.start === last.artifactEnd-last.artifactStart && text.length === end-start && last.artifactEnd === start) { last.end += text.length; last.artifactEnd = end; p.text += text; return; }
  const range: DocxProjectionRange = new DocxProjectionRange(); range.start = p.text.length; range.end = range.start+text.length; range.artifactStart = start; range.artifactEnd = end;
  p.text += text; p.ranges.push(range);
}
export function docxProjectMarkdown(raw: string, member: string, hash: string, cancel: KnowledgeCancellation = new KnowledgeCancellation()): DocxProjection {
  const p: DocxProjection = new DocxProjection(); p.member = member; p.memberHash = hash; let at: number = 0; let lineStart: boolean = true;
  while (at < raw.length) {
    if (at%4096 === 0) { cancel.check(); }
    if (lineStart) {
      const marker: RegExpExecArray | null = new RegExp('^(#{1,6} |[-+*] |[0-9]+[.)] )').exec(raw.slice(at));
      if (marker !== null) { at += marker[0].length; }
      lineStart = false; if (at >= raw.length) { break; }
    }
    if (raw[at] === '\r' && raw[at+1] === '\n') { docxProjectionAppend(p,'\n',at,at+2); at += 2; lineStart = true; continue; }
    if (raw[at] === '\n') { docxProjectionAppend(p,'\n',at,at+1); at++; lineStart = true; continue; }
    if (raw[at] === '&') {
      const end: number = raw.indexOf(';',at+1); const token: string = end < 0 ? '' : raw.slice(at,end+1);
      const literals: string[] = ['&amp;','&lt;','&gt;','&quot;','&apos;']; const values: string[] = ['&','<','>','"',"'"];
      const index: number = literals.indexOf(token); if (index >= 0) { docxProjectionAppend(p,values[index],at,end+1); at = end+1; continue; }
    }
    // No case folding, NFKC, punctuation stripping or whitespace collapse is source proof.
    const unit: number = raw.charCodeAt(at); const size: number = unit >= 0xd800 && unit <= 0xdbff ? 2 : 1;
    docxProjectionAppend(p,raw.slice(at,at+size),at,at+size); at += size;
  } return p;
}
function docxRecordCorrespondence(snapshot: DocxSnapshot, node: DocxNativeNode, start: number, method: string): void {
  const match: DocxCorrespondence = new DocxCorrespondence(); match.nodeId = node.id; match.nativeEnd = node.text.length; match.projectedStart = start; match.projectedEnd = start+node.text.length; match.method = method;
  match.artifactRanges = snapshot.projection.ranges.filter((r: DocxProjectionRange): boolean => r.end > match.projectedStart && r.start < match.projectedEnd);
  snapshot.correspondence.push(match); snapshot.coverage.matched++;
}
function docxOccurrences(text: string, needle: string): number[] {
  const positions: number[] = []; if (needle.length === 0) { return positions; } let at: number = 0;
  while (at <= text.length-needle.length) { const found: number = text.indexOf(needle,at); if (found < 0) { break; } positions.push(found); at = found+1; if (positions.length > 20000) { throw new DocxFailure('CorrespondenceCandidateBudget','correspondence'); } } return positions;
}
function docxLiteralObjectBoundary(text: string, start: number, length: number): boolean {
  return (start === 0 || text[start-1] === '\n') && (start+length === text.length || text[start+length] === '\n');
}
function docxMarkdownRowContext(text: string, start: number, length: number): boolean {
  const lineStart: number = text.lastIndexOf('\n',Math.max(0,start-1))+1;
  let lineEnd: number = text.indexOf('\n',start+length); if (lineEnd < 0) { lineEnd = text.length; }
  if (text.slice(lineStart,start).trim() !== '|' || text.slice(start+length,lineEnd).trim() !== '|') { return false; }
  let cursor: number = lineStart;
  while (cursor > 0) {
    const previousStart: number = text.lastIndexOf('\n',Math.max(0,cursor-2))+1; const previous: string = text.slice(previousStart,cursor-1).trim();
    if (new RegExp('^\\|[ :|-]+\\|$').test(previous) && previous.indexOf('-') >= 0) { return true; }
    if (!previous.startsWith('|') || !previous.endsWith('|')) { break; } if (previousStart >= cursor) { break; } cursor = previousStart;
  }
  const followingEnd: number = text.indexOf('\n',lineEnd+1); const following: string = text.slice(lineEnd+1,followingEnd < 0 ? text.length : followingEnd).trim();
  return new RegExp('^\\|[ :|-]+\\|$').test(following) && following.indexOf('-') >= 0;
}
export function docxCorrespond(snapshot: DocxSnapshot, cancel: KnowledgeCancellation = new KnowledgeCancellation()): void {
  snapshot.correspondence = []; snapshot.coverage.matched = 0; snapshot.coverage.ambiguous = 0; snapshot.coverage.unmatched = 0;
  snapshot.coverage.issues = snapshot.coverage.issues.filter((i: DocxCoverageIssue): boolean => i.kind !== DocxCoverageKind.Ambiguous && i.kind !== DocxCoverageKind.Unmatched);
  let previousEnd: number = 0;
  for (const node of snapshot.nodes) {
    cancel.check();
    if (snapshot.correspondence.some((c: DocxCorrespondence): boolean => c.nodeId === node.id)) { continue; }
    const occurrences: number[] = docxOccurrences(snapshot.projection.text,node.text).filter((at: number): boolean => docxLiteralObjectBoundary(snapshot.projection.text,at,node.text.length));
    const nativeDuplicates: number = snapshot.nodes.filter((n: DocxNativeNode): boolean => n.text === node.text).length;
    if (occurrences.length === 0 && node.locator.cell === undefined) {
      const ordinal: number = snapshot.nodes.findIndex((n: DocxNativeNode): boolean => n.id === node.id); let combined: string = node.text;
      for (let length: number = 2; length <= 4 && ordinal+length <= snapshot.nodes.length; length++) {
        const following: DocxNativeNode = snapshot.nodes[ordinal+length-1]; if (following.locator.cell !== undefined || following.locator.headings.map((h: DocxHeadingIdentity): string => h.nodeId).join('|') !== node.locator.headings.map((h: DocxHeadingIdentity): string => h.nodeId).join('|')) { break; }
        combined += following.text; const positions: number[] = docxOccurrences(snapshot.projection.text,combined).filter((at: number): boolean => docxLiteralObjectBoundary(snapshot.projection.text,at,combined.length));
        const native: string[] = []; for (let start: number = 0; start+length <= snapshot.nodes.length; start++) { native.push(snapshot.nodes.slice(start,start+length).map((n: DocxNativeNode): string => n.text).join('')); }
        if (positions.length === 1 && native.filter((text: string): boolean => text === combined).length === 1 && positions[0] >= previousEnd) {
          let offset: number = positions[0]; for (const n of snapshot.nodes.slice(ordinal,ordinal+length)) { docxRecordCorrespondence(snapshot,n,offset,'LiteralContinuousMerge'); offset += n.text.length; } previousEnd = offset; break;
        }
      }
      if (snapshot.correspondence.some((c: DocxCorrespondence): boolean => c.nodeId === node.id)) { continue; }
    }
    if (nativeDuplicates > 1 && node.locator.cell === undefined) {
      const ordinal: number = snapshot.nodes.findIndex((n: DocxNativeNode): boolean => n.id === node.id);
      const before: DocxNativeNode | undefined = snapshot.nodes[ordinal-1]; const after: DocxNativeNode | undefined = snapshot.nodes[ordinal+1];
      if (before !== undefined && after !== undefined && before.locator.cell === undefined && after.locator.cell === undefined && snapshot.nodes.filter((n: DocxNativeNode): boolean => n.text === before.text).length === 1 && snapshot.nodes.filter((n: DocxNativeNode): boolean => n.text === after.text).length === 1) {
        const context: string = before.text+'\n\n'+node.text+'\n\n'+after.text; const found: number[] = docxOccurrences(snapshot.projection.text,context);
        if (found.length === 1 && found[0]+before.text.length+2 >= previousEnd) { const start: number = found[0]+before.text.length+2; docxRecordCorrespondence(snapshot,node,start,'LiteralUniqueNeighbors'); previousEnd = start+node.text.length; continue; }
      }
    }
    // Table cell values alone do not prove a row/column context. Until an entire row is evidenced they remain local-only.
    let tableUnproven: boolean = node.locator.cell !== undefined;
    if (node.locator.cell !== undefined) {
      const address = node.locator.cell;
      const row: DocxNativeNode[] = snapshot.nodes.filter((n: DocxNativeNode): boolean => n.locator.cell?.tableId === address.tableId && n.locator.cell?.row === address.row);
      const whole: string = row.map((n: DocxNativeNode): string => n.text).join(' | ');
      const candidates: number[] = docxOccurrences(snapshot.projection.text,whole).filter((at: number): boolean => docxMarkdownRowContext(snapshot.projection.text,at,whole.length));
      const rowStarts: DocxNativeNode[] = snapshot.nodes.filter((n: DocxNativeNode): boolean => n.locator.cell !== undefined && n.locator.cell.column === 0);
      const duplicateRows: number = rowStarts.filter((start: DocxNativeNode): boolean => snapshot.nodes.filter((n: DocxNativeNode): boolean => n.locator.cell?.tableId === start.locator.cell?.tableId && n.locator.cell?.row === start.locator.cell?.row).map((n: DocxNativeNode): string => n.text).join(' | ') === whole).length;
      if (row.length > 1 && duplicateRows === 1 && candidates.length === 1 && row.every((n: DocxNativeNode): boolean => n.locator.cell?.rowSpan === 1 && n.locator.cell?.columnSpan === 1) && candidates[0] >= previousEnd) {
        let offset: number = candidates[0];
        for (const cellNode of row) { if (!snapshot.correspondence.some((c: DocxCorrespondence): boolean => c.nodeId === cellNode.id)) { docxRecordCorrespondence(snapshot,cellNode,offset,'LiteralUniqueRowContext'); } offset += cellNode.text.length+3; }
        previousEnd = candidates[0]+whole.length; continue;
      }
      tableUnproven = true;
    }
    if (snapshot.correspondence.some((c: DocxCorrespondence): boolean => c.nodeId === node.id)) { continue; }
    if (occurrences.length !== 1 || nativeDuplicates !== 1 || occurrences[0] < previousEnd || tableUnproven) {
      const issue: DocxCoverageIssue = new DocxCoverageIssue(); const ambiguous: boolean = occurrences.length > 1 || nativeDuplicates > 1 || occurrences.length === 1 && occurrences[0] < previousEnd;
      issue.kind = ambiguous ? DocxCoverageKind.Ambiguous : DocxCoverageKind.Unmatched; issue.code = tableUnproven ? 'TableContextNotProven' : ambiguous ? 'LiteralCorrespondenceAmbiguous' : 'LiteralCorrespondenceMissing'; issue.nodeId = node.id; issue.part = node.locator.part; issue.path = node.locator.path;
      snapshot.coverage.issues.push(issue); if (ambiguous) { snapshot.coverage.ambiguous++; } else { snapshot.coverage.unmatched++; } continue;
    }
    docxRecordCorrespondence(snapshot,node,occurrences[0],'LiteralUniqueMonotonic'); previousEnd = occurrences[0]+node.text.length;
  }
  snapshot.coverage.partial = snapshot.coverage.unsupported > 0 || snapshot.coverage.ambiguous > 0 || snapshot.coverage.unmatched > 0;
  snapshot.coverage.empty = snapshot.correspondence.length === 0;
}
