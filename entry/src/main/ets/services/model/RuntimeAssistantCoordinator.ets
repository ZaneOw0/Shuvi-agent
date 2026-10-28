import common from '@ohos.app.ability.common';
import { KnowledgeRagReadiness } from '../../knowledge/domain/KnowledgeRuntimePorts';
import { KnowledgeAssembly } from '../../knowledge/infra/KnowledgeAssembly';
import { KnowledgeRagSessionAdapter } from '../../knowledge/infra/KnowledgeRagSessionAdapter';
import { AssistantContext } from '../calendar/AssistantIntent';
import { AssistantToolPrompt, AssistantToolTurn } from '../calendar/AssistantTools';
import { CalendarNativeTool } from '../calendar/CalendarNativeTool';
import { CalendarRuntimeFactory } from '../calendar/CalendarRuntimeAssembly';
import { ModelDocumentToolsPort } from '../documents/DocumentToolContracts';
import { modelDocumentTools } from '../documents/ModelDocumentTools';
import { NativeAgentRdbOpen } from './AgentRdbResources';
import { ChatPurpose, ChatRuntimeFactory, ChatToolKit } from './ChatRuntimeAssembly';
import { knowledgeAnswerRuntimeFactory } from './KnowledgeAnswerRuntimeAssembly';
import { RuntimeChatService } from './RuntimeChatService';
import { RuntimeKnowledgeService } from './RuntimeKnowledgeService';
import { ShuviRuntimeState } from './ShuviRuntimeController';

/**
 * Coordinates one user-entered DeepSeek key across the calendar-capable assistant session and the PERSONAL RAG session.
 * The assistant session (ChatPurpose.ASSISTANT) lets the model choose per turn: answer, run document tools, or propose a
 * calendar event; writing the event still requires the user's confirmation and the authorized native calendar tool.
 * start() only prepares the RAG answer session; the knowledge store is opened by enableKnowledge().
 * The two sessions keep separate planners, adapters and execution stores.
 */
export class RuntimeAssistantCoordinator {
  static async start(context: common.Context, debug: boolean, key: Uint8Array): Promise<void> {
    const chatKey: Uint8Array = key.slice(); const ragKey: Uint8Array = key.slice(); key.fill(0);
    try {
      const chatState: ShuviRuntimeState = RuntimeChatService.session.snapshot().lifecycle;
      if (chatState === ShuviRuntimeState.STARTING || chatState === ShuviRuntimeState.READY ||
        chatState === ShuviRuntimeState.STOPPING || chatState === ShuviRuntimeState.BLOCKED) { return; }
      const knowledgeState: ShuviRuntimeState = RuntimeKnowledgeService.session.snapshot().lifecycle;
      if (knowledgeState === ShuviRuntimeState.STARTING || knowledgeState === ShuviRuntimeState.READY ||
        knowledgeState === ShuviRuntimeState.STOPPING || knowledgeState === ShuviRuntimeState.BLOCKED) {
        try { await RuntimeKnowledgeService.session.stop(); } catch { /* The assistant session may still start; RAG stays fail-closed. */ }
      }
      const opener: NativeAgentRdbOpen = new NativeAgentRdbOpen(context);
      // One tool loop: the model chooses document tools (run in the loop) or calendar_propose (ends the turn and opens
      // the confirmation card); search and knowledge stay separate, explicitly enabled sessions.
      const assistant: AssistantContext = RuntimeChatService.session.context;
      const tools: ChatToolKit = new ChatToolKit((): ModelDocumentToolsPort => modelDocumentTools(context),
        new AssistantToolTurn(assistant));
      await RuntimeChatService.session.start(
        new ChatRuntimeFactory(opener, debug, new AssistantToolPrompt(assistant), ChatPurpose.ASSISTANT, tools),
        new CalendarRuntimeFactory(opener, new CalendarNativeTool(), debug), chatKey);
      if (RuntimeChatService.session.snapshot().lifecycle !== ShuviRuntimeState.READY) { return; }
      await RuntimeKnowledgeService.session.prepareRag(
        new KnowledgeRagSessionAdapter(KnowledgeAssembly.forContext(context)),
        knowledgeAnswerRuntimeFactory(context, debug, RuntimeKnowledgeService.session.answerContext,
          (taskId: string): void => { RuntimeKnowledgeService.session.answerOutcomeRejected(taskId); }),
        ragKey);
    } finally { chatKey.fill(0); ragKey.fill(0); }
  }

  static async enableKnowledge(): Promise<KnowledgeRagReadiness> {
    return await RuntimeKnowledgeService.session.activateRag();
  }

  static async disableKnowledge(): Promise<void> {
    await RuntimeKnowledgeService.session.deactivateRag();
  }

  static async stop(): Promise<void> {
    let failed: boolean = false;
    try { await RuntimeKnowledgeService.session.stop(); } catch { failed = true; }
    try { await RuntimeChatService.session.stop(); } catch { failed = true; }
    if (failed) { throw new Error('RUNTIME_ASSISTANT_STOP_FAILED'); }
  }
}
