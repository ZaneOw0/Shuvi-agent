import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { KnowledgeCapabilityAudit, CapabilityAuditGate } from './KnowledgeCapabilityAudit';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { pdfRunNativeSuite, PdfNativeSuiteResult, PdfNativeCaseResult } from '../platformtests/PdfNativeSuite';

export enum KnowledgeCapabilityState {
  NotChecked = 'NotChecked', Checking = 'Checking', Available = 'Available', Unavailable = 'Unavailable', Failed = 'Failed', Releasing = 'Releasing'
}
export class KnowledgePlatformCapability {
  state: KnowledgeCapabilityState = KnowledgeCapabilityState.NotChecked; stage: string = ''; reason: string = ''; code: number = 0;
  implementation: string = 'R2-ZLIB-1'; suite: string = 'R2-NATIVE-1'; environment: string = ''; app: string = '';
  checkedAt: number = 0; cases: PdfNativeCaseResult[] = [];
}
export class KnowledgeCapabilityService {
  private static context: common.Context | undefined;
  static attachContext(context: common.Context): void { KnowledgeCapabilityService.context = context; }
  private static record: KnowledgePlatformCapability = new KnowledgePlatformCapability();
  private static checking: Promise<void> | undefined = undefined;
  private static auditGate: CapabilityAuditGate = new CapabilityAuditGate();
  static archive(): KnowledgePlatformCapability {
    const copy: KnowledgePlatformCapability = new KnowledgePlatformCapability(); const current: KnowledgePlatformCapability = KnowledgeCapabilityService.record;
    copy.state = current.state; copy.stage = current.stage; copy.reason = current.reason; copy.code = current.code;
    copy.environment = current.environment; copy.app = current.app; copy.implementation = current.implementation; copy.suite = current.suite; copy.checkedAt = current.checkedAt; return copy;
  }
  private static async checkArchive(): Promise<void> {
    const record: KnowledgePlatformCapability = KnowledgeCapabilityService.record; record.state = KnowledgeCapabilityState.Checking;
    record.environment = `${deviceInfo.sdkApiVersion}|${deviceInfo.osFullName}|${deviceInfo.abiList}`;
    const context = KnowledgeCapabilityService.context; if (context === undefined) { throw new KnowledgeFailure('CapabilityAuditContextRequired','capability'); }
    const audit = new KnowledgeCapabilityAudit(context); const descriptor = await audit.identity('Archive',record.implementation,record.suite); record.app = descriptor.app;
    await KnowledgeCapabilityService.auditGate.require(audit,descriptor,async (): Promise<void> => {
    const result: PdfNativeSuiteResult = await pdfRunNativeSuite(KnowledgeStorageScope.isolated('0000000000000001'),true);
    record.cases = result.cases; record.checkedAt = Date.now();
    const failed: PdfNativeCaseResult | undefined = result.cases.find((row: PdfNativeCaseResult): boolean => !row.passed);
    if (failed !== undefined) {
      record.state = failed.ends === 0 && failed.id !== 'stored' ? KnowledgeCapabilityState.Releasing : KnowledgeCapabilityState.Failed;
      record.stage = failed.id; record.reason = failed.reason; record.code = failed.code;
      throw new KnowledgeFailure(`${record.reason}:${record.code}`,`native-selftest-${record.stage}`);
    }
    record.state = KnowledgeCapabilityState.Available; record.stage = 'SelfTestReadbackReleased'; record.reason = '';
    });
  }
  static async requireArchive(): Promise<void> {
    if (KnowledgeCapabilityService.record.state === KnowledgeCapabilityState.Releasing) { throw new KnowledgeFailure('NativeReleaseUnconfirmed','native-selftest'); }
    if (KnowledgeCapabilityService.record.state === KnowledgeCapabilityState.Available) { return; }
    if (KnowledgeCapabilityService.checking === undefined) { KnowledgeCapabilityService.checking = KnowledgeCapabilityService.checkArchive(); }
    const checking: Promise<void> = KnowledgeCapabilityService.checking;
    try { await checking; }
    catch (error) {
      if (KnowledgeCapabilityService.archive().state !== KnowledgeCapabilityState.Releasing) { KnowledgeCapabilityService.record.state = KnowledgeCapabilityState.Failed; KnowledgeCapabilityService.record.reason = 'SelfTestAborted'; }
      if (error instanceof Error) { throw error; } throw new KnowledgeFailure('SelfTestAborted','native-selftest');
    } finally { KnowledgeCapabilityService.checking = undefined; }
  }
}
