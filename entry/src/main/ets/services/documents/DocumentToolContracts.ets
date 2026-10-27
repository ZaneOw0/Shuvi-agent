export class DocumentChatCommand {
  action: string = '';
  fileName: string = '';
  documentId: string = '';
  expectedVersion: number = 0;
  content: string = '';
}
export class DocumentChatResult {
  documentId: string = '';
  fileName: string = '';
  version: number = 0;
  content: string = '';
  receipt: string = '';
  savedToDownloads: boolean = false;
  storageLocation: string = '';
  fileUri: string = '';
}
export interface DocumentChatPort {
  resolve(target: string): Promise<DocumentChatResult | undefined>;
  execute(command: DocumentChatCommand): Promise<DocumentChatResult>;
  stop(): Promise<void>;
}
export interface ModelDocumentToolsPort {
  invoke(name: string, argumentsJson: string): Promise<string>;
  cancel(): Promise<void>;
  close(): Promise<void>;
}
