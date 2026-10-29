import { ShuviRuntimeController } from './ShuviRuntimeController';
import { AssistantRuntimeSession } from '../calendar/AssistantRuntimeSession';
import { AssistantConversations } from '../conversation/AssistantConversations';

export class RuntimeChatService {
  static readonly controller: ShuviRuntimeController = new ShuviRuntimeController();
  static readonly session: AssistantRuntimeSession = new AssistantRuntimeSession(RuntimeChatService.controller);
  /** Saved assistant conversations; the current one's model memory is the session context's memory. */
  static readonly conversations: AssistantConversations = new AssistantConversations(RuntimeChatService.session.context.memory);
}
