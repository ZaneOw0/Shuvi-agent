import common from '@ohos.app.ability.common';
import { KnowledgeRagReadiness } from '../../knowledge/domain/KnowledgeRuntimePorts';
import { KnowledgeAssembly } from '../../knowledge/infra/KnowledgeAssembly';
import { AssistantContext } from '../calendar/AssistantIntent';
import { AssistantToolPrompt, AssistantToolTurn } from '../calendar/AssistantTools';
import { CalendarNativeTool } from '../calendar/CalendarNativeTool';
import { CalendarRuntimeFactory } from '../calendar/CalendarRuntimeAssembly';
import { ModelDocumentToolsPort } from '../documents/DocumentToolContracts';
import { modelDocumentTools } from '../documents/ModelDocumentTools';
import { NativeAgentRdbOpen } from './AgentRdbResources';
import { ChatPurpose, ChatRuntimeFactory, ChatToolKit } from './ChatRuntimeAssembly';
import { KnowledgeAgentRuntime } from './KnowledgeAgentRuntime';
import { DeepSeekKeyService } from './DeepSeekCredentialStore';
import { CombinedLoopTools } from './ModelLoopTools';
import { RuntimeChatService } from './RuntimeChatService';
import { RuntimeKnowledgeService } from './RuntimeKnowledgeService';
import { RuntimeSearchService } from './RuntimeSearchService';
import { searchRuntimeFactory } from './SearchRuntimeAssembly';
import { ShuviRuntimeState } from './ShuviRuntimeController';

/**
 * One PERSONAL model session chooses answers, authorized knowledge/web-search/document tools and calendar proposals.
 * The knowledge store and the search Runtime open only on explicit authorization; neither owns a model session.
 */
export class RuntimeAssistantCoordinator {
  static async start(context: common.Context, debug: boolean, key: Uint8Array): Promise<void> {
    const chatKey: Uint8Array = key.slice(); key.fill(0);
    try {
      const chatState: ShuviRuntimeState = RuntimeChatService.session.snapshot().lifecycle;
      if (chatState === ShuviRuntimeState.STARTING || chatState === ShuviRuntimeState.READY ||
        chatState === ShuviRuntimeState.STOPPING || chatState === ShuviRuntimeState.BLOCKED) { return; }
      const knowledgeState: ShuviRuntimeState = RuntimeKnowledgeService.session.snapshot().lifecycle;
      if (knowledgeState === ShuviRuntimeState.STARTING || knowledgeState === ShuviRuntimeState.READY ||
        knowledgeState === ShuviRuntimeState.STOPPING || knowledgeState === ShuviRuntimeState.BLOCKED) {
        await RuntimeKnowledgeService.session.stop();
      }
      const opener: NativeAgentRdbOpen = new NativeAgentRdbOpen(context);
      // Knowledge and document tools return to this same loop; calendar_propose still ends at the confirmation card.
      const assistant: AssistantContext = RuntimeChatService.session.context;
      const knowledge = RuntimeKnowledgeService.session;
      const search = KnowledgeAssembly.forContext(context).createAgentSearch();
      knowledge.prepare(search, new KnowledgeAgentRuntime(opener, search, (): boolean => knowledge.snapshot().consent),
        (): Promise<void> => RuntimeChatService.session.cancel(),
        (): Promise<void> => RuntimeChatService.session.send('请仅基于上一轮已返回的个人资料重试回答，禁止重新检索。'));
      const web = RuntimeSearchService.session;
      web.prepare((): Promise<void> => RuntimeChatService.session.cancel(), (): Promise<Uint8Array | undefined> =>
        DeepSeekKeyService.store.load());
      const tools: ChatToolKit = new ChatToolKit((): ModelDocumentToolsPort => modelDocumentTools(context),
        new AssistantToolTurn(assistant), new CombinedLoopTools([knowledge, web]));
      await RuntimeChatService.session.start(
        new ChatRuntimeFactory(opener, debug, new AssistantToolPrompt(assistant), ChatPurpose.ASSISTANT, tools),
        new CalendarRuntimeFactory(opener, new CalendarNativeTool(), debug), chatKey);
      if (RuntimeChatService.session.snapshot().lifecycle !== ShuviRuntimeState.READY) {
        await knowledge.stop(); await web.stop(); return;
      }
    } finally { chatKey.fill(0); }
  }

  static async enableKnowledge(queryEgress: boolean = true): Promise<KnowledgeRagReadiness> {
    return await RuntimeKnowledgeService.session.activateRag(queryEgress);
  }

  static async disableKnowledge(): Promise<void> {
    await RuntimeKnowledgeService.session.deactivateRag();
  }

  /** Lets the assistant search the web on its own for this conversation. The key is the DeepSeek key (session setup). */
  static async enableSearch(context: common.Context, debug: boolean, key: Uint8Array): Promise<boolean> {
    if (RuntimeChatService.session.snapshot().lifecycle !== ShuviRuntimeState.READY) { key.fill(0); return false; }
    return await RuntimeSearchService.session.activate(searchRuntimeFactory(context, debug), key);
  }

  static async disableSearch(): Promise<void> {
    await RuntimeSearchService.session.deactivate();
  }

  static async stop(): Promise<void> {
    let failed: boolean = false;
    try { await RuntimeSearchService.session.stop(); } catch { failed = true; }
    try { await RuntimeKnowledgeService.session.stop(); } catch { failed = true; }
    try { await RuntimeChatService.session.stop(); } catch { failed = true; }
    if (failed) { throw new Error('RUNTIME_ASSISTANT_STOP_FAILED'); }
  }
}
