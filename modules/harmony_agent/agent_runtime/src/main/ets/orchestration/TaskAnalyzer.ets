import { RiskLevel, TaskEnvelope, TaskFrame } from '@harmony_agent/agent-contracts';

export class TaskAnalyzer {
  analyze(envelope: TaskEnvelope): TaskFrame {
    const frame: TaskFrame = new TaskFrame();
    frame.taskId = envelope.taskId;
    frame.goal = envelope.userIntent.trim();
    frame.constraints = [
      'privacy:' + envelope.privacyClass,
      'locale:' + envelope.locale,
      'timeZone:' + envelope.timeZone,
      'referenceTime:' + envelope.referenceTime
    ];
    frame.capabilityCategories = [];
    frame.riskLevel = RiskLevel.LOW;
    frame.canParallelize = false;
    frame.featuresJson = '{"inputRefCount":' + envelope.inputRefs.length.toString() + '}';
    return frame;
  }
}
