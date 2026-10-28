/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { SourceLinkService } from '../services/SourceLinkService';
import { McpConnectionCheckService } from '../services/McpConnectionCheckService';
import { DirectModelCheckService } from '../services/model/DirectModelCheckService';
import { ShuviRuntimeService } from '../services/model/ShuviRuntimeService';
import { RuntimeChatService } from '../services/model/RuntimeChatService';
import { RuntimeSearchService } from '../services/model/RuntimeSearchService';
import { PdfJsRuntime } from '../knowledge/infra/PdfJsRuntime';
import { RuntimeKnowledgeService } from '../services/model/RuntimeKnowledgeService';
import { RuntimeVisionService } from '../services/model/RuntimeVisionService';
import { DocumentParseAssembly } from '../knowledge/infra/DocumentParseAssembly';
import { KnowledgeAssembly } from '../knowledge/infra/KnowledgeAssembly';
import { SemanticQualitySession } from '../knowledge/platformtests/SemanticQualitySuite';
import { ImageIngestionService } from '../knowledge/application/ImageIngestionService';
import { DocxIngestionService } from '../knowledge/application/DocxIngestionService';
import { ImageIntegrationSuite } from '../knowledge/platformtests/ImageIntegrationSuite';
import { CalendarProbeService } from '../services/calendar/CalendarProbeService';
import { CalendarDraftService } from '../services/calendar/CalendarDraftService';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    SourceLinkService.bind(this.context);
    CalendarProbeService.bind(this.context);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    PdfJsRuntime.shared.detach();
    void CalendarDraftService.controller.onDestroy().catch((): void => {});
    CalendarProbeService.release();
    void RuntimeSearchService.session.onDestroy().catch((): void => {});
    void RuntimeKnowledgeService.session.onDestroy().catch((): void => {});
    void RuntimeVisionService.session.onDestroy().catch((): void => {});
    void RuntimeChatService.controller.onDestroy().catch((): void => {});
    void RuntimeChatService.session.calendar.onDestroy().catch((): void => {});
    void RuntimeChatService.session.stop().catch((): void => {});
    void ShuviRuntimeService.session.onDestroy().catch((): void => {
      hilog.error(DOMAIN, 'ShuviRuntime', 'Agent session shutdown failed');
    });
    DirectModelCheckService.session.detach();
    McpConnectionCheckService.session.detach();
    SourceLinkService.release();
    DocxIngestionService.background();
    ImageIntegrationSuite.background();
    ImageIngestionService.background();
    SemanticQualitySession.background();
    KnowledgeAssembly.background();
    DocumentParseAssembly.background();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    PdfJsRuntime.shared.detach();
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    CalendarDraftService.controller.onForeground();
    RuntimeSearchService.session.onForeground();
    RuntimeKnowledgeService.session.onForeground();
    RuntimeVisionService.session.onForeground();
    RuntimeChatService.controller.onForeground();
    RuntimeChatService.session.calendar.onForeground();
    ShuviRuntimeService.session.onForeground();
    KnowledgeAssembly.foreground();
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    PdfJsRuntime.shared.closePreview();
    void CalendarDraftService.controller.onBackground().catch((): void => {});
    CalendarProbeService.background();
    void RuntimeSearchService.session.onBackground().catch((): void => {});
    void RuntimeKnowledgeService.session.onBackground().catch((): void => {});
    void RuntimeVisionService.session.onBackground().catch((): void => {});
    void RuntimeChatService.controller.onBackground().catch((): void => {});
    void RuntimeChatService.session.calendar.onBackground().catch((): void => {});
    void RuntimeChatService.session.stop().catch((): void => {});
    void ShuviRuntimeService.session.onBackground().catch((): void => {
      hilog.error(DOMAIN, 'ShuviRuntime', 'Agent session background cleanup failed');
    });
    DirectModelCheckService.background();
    McpConnectionCheckService.session.cancel();
    DocxIngestionService.background();
    ImageIntegrationSuite.background();
    ImageIngestionService.background();
    SemanticQualitySession.background();
    KnowledgeAssembly.background();
    DocumentParseAssembly.background();
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
