export enum McpErrorCode {
  CONFIGURATION = 'CONFIGURATION',
  NETWORK = 'NETWORK',
  AUTHENTICATION = 'AUTHENTICATION',
  FORBIDDEN = 'FORBIDDEN',
  NEGOTIATION = 'NEGOTIATION',
  PROTOCOL = 'PROTOCOL',
  JSON_RPC = 'JSON_RPC',
  POLICY_DENIED = 'POLICY_DENIED',
  TIMEOUT = 'TIMEOUT',
  CANCELLED = 'CANCELLED',
  RESPONSE_TOO_LARGE = 'RESPONSE_TOO_LARGE',
  INVALID_ARGUMENT = 'INVALID_ARGUMENT',
  SCHEMA_MISMATCH = 'SCHEMA_MISMATCH',
  UNSUPPORTED = 'UNSUPPORTED'
}

export class McpClientError extends Error {
  readonly code: McpErrorCode;
  readonly serverId?: string;
  readonly statusCode?: number;
  readonly rpcCode?: number;
  readonly details?: Object;

  constructor(code: McpErrorCode, message: string, serverId?: string,
    statusCode?: number, rpcCode?: number, details?: Object) {
    super(message);
    this.name = 'McpClientError';
    this.code = code;
    this.serverId = serverId;
    this.statusCode = statusCode;
    this.rpcCode = rpcCode;
    this.details = details;
  }
}

