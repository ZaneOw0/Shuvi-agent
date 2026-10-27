import common from '@ohos.app.ability.common';
import { KnowledgeRagReadiness } from '../../knowledge/domain/KnowledgeRuntimePorts';
import { KnowledgeAssembly } from '../../knowledge/infra/KnowledgeAssembly';
import { KnowledgeRagSessionAdapter } from '../../knowledge/infra/KnowledgeRagSessionAdapter';
import { CalendarNativeTool } from '../calendar/CalendarNativeTool';
import { CalendarRuntimeFactory } from '../calendar/CalendarRuntimeAssembly';
import { NativeAgentRdbOpen } from './AgentRdbResources';
import { ChatPurpose, ChatRuntimeFactory } from './ChatRuntimeAssembly';
import { knowledgeAnswerRuntimeFactory } from './KnowledgeAnswerRuntimeAssembly';
import { RuntimeChatService } from './RuntimeChatService';
import { RuntimeKnowledgeService } from './RuntimeKnowledgeService';
import { ShuviRuntimeState } from './ShuviRuntimeController';

/**
 * Coordinates one user-entered DeepSeek key across the calendar-capable assistant session and the PERSONAL RAG session.
 * The assistant session (ChatPurpose.ASSISTANT) answers or drafts calendar events; writing still requires the
 * authorized native calendar tool. start() only prepares the RAG answer session; the knowledge store is opened by
 * enableKnowledge(). The two sessions keep separate planners, adapters and execution stores.
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
      await RuntimeChatService.session.start(
        new ChatRuntimeFactory(opener, debug, RuntimeChatService.session.context, ChatPurpose.ASSISTANT),
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
