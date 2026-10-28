import { CalendarNativeToolPort } from './CalendarToolAdapter';
import { CalendarProbeDraft, CalendarProbeResult } from './CalendarProbeSession';
import { CalendarProbeService } from './CalendarProbeService';

/** Same application-owned journal and calendar as the workbench; no parallel write store. */
export class CalendarNativeTool implements CalendarNativeToolPort {
  create(draft: CalendarProbeDraft, operationId: string, cancelled: () => boolean): Promise<CalendarProbeResult> {
    return CalendarProbeService.session.executeAuthorized(draft, operationId, cancelled);
  }
  cancel(): void { CalendarProbeService.session.stop(); }
}
