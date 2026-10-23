import { PdfBox } from './PdfKnowledgeModels';
export class PdfEvidenceContext {
  originalHash: string = ''; originalVersion: number = 0; zipHash: string = ''; snapshotHash: string = ''; snapshotId: string = ''; generation: string = ''; nodeId: string = ''; protocol: string = '';
  providerPage: number = -1; originalPages: number = 0; rotation: number = 0; media: PdfBox = new PdfBox(); crop: PdfBox = new PdfBox();
}
export class PdfLocalMetadata {
  document: string = ''; generation: string = ''; job: string = ''; snapshot: string = ''; snapshotHash: string = ''; reportHash: string = '';
  originalHash: string = ''; zipHash: string = ''; chunks: number = 0; assets: number = 0; ledgerBytes: number = 0; readLeases: number = 0;
  nodes: number = 0; primary: number = 0; inline: number = 0; formulas: number = 0; tables: number = 0; cells: number = 0; images: number = 0;
  verifiedImages: number = 0; excluded: number = 0; published: boolean = false;
}

export enum PdfPageReferenceState { Unknown = 'Unknown', Verified = 'Verified', Partial = 'Partial', Conflict = 'Conflict' }
export class PdfPageIdentityContext {
  documentId: string = ''; originalHash: string = ''; originalVersion: number = 0; originalPages: number = 0;
  zipHash: string = ''; snapshotId: string = ''; snapshotHash: string = ''; generation: string = ''; protocol: string = '';
}
export class PdfReviewedPageFragment {
  start: number = 0; end: number = 0; textHash: string = ''; originalPage1: number = 0;
}
export class PdfPageIdentityEvidence extends PdfPageIdentityContext {
  wire: string = 'PAGE-IDENTITY-1'; id: string = ''; nodeId: string = ''; nodeHash: string = ''; providerPage0: number = -1;
  fragments: PdfReviewedPageFragment[] = [];
  reviewVersion: string = ''; reviewRecordHash: string = ''; uniqueAnchorHash: string = ''; structureAnchorHash: string = '';
}
export class ResultPageReference extends PdfPageIdentityContext {
  state: PdfPageReferenceState = PdfPageReferenceState.Unknown; physicalPages1Based: number[] = []; evidenceIds: string[] = [];
  uncoveredNodeIds: string[] = []; reason: string = 'PageEvidenceMissing';
}
