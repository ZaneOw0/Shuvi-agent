import common from '@ohos.app.ability.common';
import { DocumentChatRuntime } from './DocumentChatRuntime';
// The tool declarations live in DocumentToolContracts so the model transport does not load the native runtime.
import { DOCUMENT_MODEL_TOOL_NAMES, DocumentChatCommand, DocumentChatPort, ModelDocumentToolsPort } from './DocumentToolContracts';

export class ModelDocumentTools implements ModelDocumentToolsPort {
  private readonly factory: () => DocumentChatPort;
  private runtime?: DocumentChatPort;
  private closed: boolean = false;
  private cancelling?: Promise<void>;
  constructor(factory: () => DocumentChatPort) { this.factory = factory; }
  active(): boolean { return !this.closed && this.cancelling === undefined; }
  async invoke(name: string, argumentsJson: string): Promise<string> {
    if (this.closed || this.cancelling !== undefined) throw new Error('DOCUMENT_SESSION_CLOSED');
    if (!DOCUMENT_MODEL_TOOL_NAMES.includes(name) || argumentsJson.length > 300000) throw new Error('DOCUMENT_INVALID_ARGUMENTS');
    const args: Record<string, Object> = JSON.parse(argumentsJson) as Record<string, Object>;
    if (args === null || typeof args !== 'object' || Array.isArray(args)) throw new Error('DOCUMENT_INVALID_ARGUMENTS');
    const keys: string[] = name === 'document_read' ? ['fileName'] :
      (name === 'document_create' ? ['fileName', 'content'] : ['fileName', 'expectedVersion', 'content']);
    if (Object.keys(args).length !== keys.length || Object.keys(args).some((key: string): boolean => !keys.includes(key)) ||
      typeof args['fileName'] !== 'string') throw new Error('DOCUMENT_INVALID_ARGUMENTS');
    const fileName: string = args['fileName'] as string;
    if (!fileName || fileName.length > 120 || fileName !== fileName.trim() || /[\/\\:*?"<>|\x00-\x1f\x7f]/.test(fileName) ||
      (!/\.(md|txt)$/i.test(fileName) && !/^doc-[a-f0-9]{64}$/.test(fileName))) throw new Error('DOCUMENT_INVALID_NAME');
    if (name !== 'document_read' && (typeof args['content'] !== 'string' || (args['content'] as string).length > 262144)) {
      throw new Error('DOCUMENT_INVALID_ARGUMENTS');
    }
    const command: DocumentChatCommand = new DocumentChatCommand();
    command.action = name.slice('document_'.length); command.fileName = fileName;
    if (name !== 'document_read') command.content = args['content'] as string;
    if (name === 'document_update') {
      if (typeof args['expectedVersion'] !== 'number' || !Number.isSafeInteger(args['expectedVersion'] as number) ||
        (args['expectedVersion'] as number) < 1) throw new Error('DOCUMENT_INVALID_ARGUMENTS');
      command.expectedVersion = args['expectedVersion'] as number;
    }
    if (this.runtime === undefined) this.runtime = this.factory();
    const current = await this.runtime.resolve(fileName);
    if (this.closed || this.cancelling !== undefined) throw new Error('DOCUMENT_SESSION_CLOSED');
    if (command.action === 'create' && current !== undefined) throw new Error('DOCUMENT_ALREADY_EXISTS');
    if (command.action !== 'create') {
      if (current === undefined) throw new Error('DOCUMENT_NOT_FOUND');
      command.documentId = current.documentId; command.fileName = current.fileName;
    }
    const result = await this.runtime.execute(command);
    if (command.action !== 'read' && !result.savedToDownloads) throw new Error('DOCUMENT_DOWNLOAD_UNCERTAIN');
    const output: Record<string, Object> = { 'ok': true, 'fileName': result.fileName, 'documentId': result.documentId,
      'version': result.version, 'receipt': result.receipt, 'savedToDownloads': result.savedToDownloads,
      'storageLocation': result.storageLocation, 'fileUri': result.fileUri };
    if (command.action === 'read') { output['content'] = result.content.slice(0, 8000); output['truncated'] = result.content.length > 8000; }
    return JSON.stringify(output);
  }
  cancel(): Promise<void> {
    if (this.cancelling !== undefined) return this.cancelling;
    const runtime: DocumentChatPort | undefined = this.runtime;
    if (runtime === undefined) return Promise.resolve();
    this.cancelling = runtime.stop().then((): void => { this.runtime = undefined; }, (error: Error): void => {
      this.closed = true; throw error;
    }).finally((): void => { this.cancelling = undefined; });
    return this.cancelling;
  }
  async close(): Promise<void> { this.closed = true; await this.cancel(); }
}

export function modelDocumentTools(context: common.Context): ModelDocumentTools {
  const tools: ModelDocumentTools = new ModelDocumentTools((): DocumentChatPort =>
    new DocumentChatRuntime(context, (): boolean => tools.active()));
  // The session transport owns closure/cancellation; no page gets a file or credential handle.
  return tools;
}
