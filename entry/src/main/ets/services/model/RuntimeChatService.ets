import { ShuviRuntimeController } from './ShuviRuntimeController';
import { RuntimeChatSession } from './RuntimeChatSession';

export class RuntimeChatService {
  static readonly controller: ShuviRuntimeController = new ShuviRuntimeController();
  static readonly session: RuntimeChatSession = new RuntimeChatSession(RuntimeChatService.controller);
}
