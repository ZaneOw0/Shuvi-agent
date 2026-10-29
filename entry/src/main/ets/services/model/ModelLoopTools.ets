/** Optional tool families composed with document tools; execution stays behind their Runtime adapters. */
export interface ModelLoopToolsPort {
  names(): string[];
  definitions(): Object[];
  policy(): string;
  revision(): number;
  begin(question: string, turnId: string, deadline: number): void;
  invoke(name: string, argumentsJson: string, callId: string): Promise<string>;
  finish(text: string): Promise<string>;
  cancel(): Promise<void>;
  close(): Promise<void>;
}
