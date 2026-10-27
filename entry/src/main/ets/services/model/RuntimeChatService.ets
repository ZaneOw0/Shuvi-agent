import { ShuviRuntimeController } from './ShuviRuntimeController';
import { AssistantRuntimeSession } from '../calendar/AssistantRuntimeSession';

export class RuntimeChatService {
  static readonly controller: ShuviRuntimeController = new ShuviRuntimeController();
  static readonly session: AssistantRuntimeSession = new AssistantRuntimeSession(RuntimeChatService.controller);
}
