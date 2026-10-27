import common from '@ohos.app.ability.common';
import { NativeAgentRdbOpen } from '../model/AgentRdbResources';
import { ChatPurpose, ChatRuntimeFactory } from '../model/ChatRuntimeAssembly';
import { ShuviRuntimeController } from '../model/ShuviRuntimeController';
import { CalendarDraftSession } from './CalendarDraftSession';

export class CalendarDraftService {
  static readonly controller: ShuviRuntimeController = new ShuviRuntimeController();
  static readonly session: CalendarDraftSession = new CalendarDraftSession(CalendarDraftService.controller);
  static async start(context: common.Context, debugBuild: boolean, key: Uint8Array): Promise<void> {
    try {
      const factory = new ChatRuntimeFactory(new NativeAgentRdbOpen(context), debugBuild,
        CalendarDraftService.session.context, ChatPurpose.CALENDAR_DRAFT);
      await CalendarDraftService.session.start(factory, key);
    } finally { key.fill(0); }
  }
}
