import { describe, expect, it } from '@ohos/hypium';
import {
  AgentRuntimeEvent,
  AgentTaskStatus,
  AuthorizationDecision,
  AuthorizationDecisionType,
  ClarificationRequest,
  ClarificationResponse,
  PolicyRequest,
  ReconciliationReport,
  ReconciliationStatus,
  TaskControlAction,
  TaskControlCommand,
  TaskHandle,
  TaskSubmission
} from '@harmony_agent/agent-contracts';
import {
  AgentRuntimeFacade,
  AgentRuntimeObserver,
  AgentSubscription,
  FakeAgentRuntimeConfig,
  FakeAgentConsumer,
  FakeTaskScript,
  FakeTaskScriptKind,
  ShutdownMode,
  SubscriptionRequest,
  createFakeAgentRuntime
} from '../../Index';

class RecordingObserver implements AgentRuntimeObserver {
  events: AgentRuntimeEvent[] = [];
  policyRequests: PolicyRequest[] = [];
  clarificationRequests: ClarificationRequest[] = [];

  onEvent(event: AgentRuntimeEvent): void {
    this.events.push(event);
  }

  onPolicyRequest(request: PolicyRequest): void {
    this.policyRequests.push(request);
  }

  onClarificationRequest(request: ClarificationRequest): void {
    this.clarificationRequests.push(request);
  }
}

function submission(requestId: string): TaskSubmission {
  const value: TaskSubmission = new TaskSubmission();
  value.requestId = requestId;
  value.userId = 'user-local';
  value.userIntent = '执行 headless fake 验收任务';
  value.locale = 'zh-CN';
  value.timeZone = 'Asia/Shanghai';
  value.referenceTime = '1970-01-01T00:00:01.000Z';
  value.submittedAt = '1970-01-01T00:00:01.000Z';
  value.requestedBudget.maxWallTimeMs = 10000;
  value.requestedBudget.maxInputTokens = 1000;
  value.requestedBudget.maxOutputTokens = 1000;
  value.requestedBudget.maxMonetaryCostMicros = 100;
  value.requestedBudget.maxToolCalls = 2;
  value.requestedBudget.maxAgentActivations = 2;
  value.requestedBudget.maxRetries = 1;
  value.requestedBudget.maxReplans = 1;
  return value;
}

function runtime(requestId: string, kind: FakeTaskScriptKind): AgentRuntimeFacade {
  const script: FakeTaskScript = new FakeTaskScript();
  script.requestId = requestId;
  script.kind = kind;
  const config: FakeAgentRuntimeConfig = new FakeAgentRuntimeConfig();
  config.startTimeMs = 1000;
  config.scripts = [script];
  return createFakeAgentRuntime(config);
}

async function subscribe(value: AgentRuntimeFacade, taskId: string, afterSequence: number,
  observer: RecordingObserver): Promise<AgentSubscription> {
  const request: SubscriptionRequest = new SubscriptionRequest();
  request.subscriptionId = 'subscription:' + taskId + ':' + afterSequence.toString();
  request.taskId = taskId;
  request.afterSequence = afterSequence;
  return await value.subscribe(request, observer);
}

function control(commandId: string, taskId: string, action: TaskControlAction): TaskControlCommand {
  const value: TaskControlCommand = new TaskControlCommand();
  value.commandId = commandId;
  value.taskId = taskId;
  value.action = action;
  value.reasonCode = 'consumer-requested';
  value.requestedAt = '1970-01-01T00:00:01.100Z';
  return value;
}

export default function fakeAgentRuntimeTest(): void {
  describe('FakeAgentRuntime', () => {
    it('assignsAgentOwnedTaskIdentityAndCompletesFixedTask', 0, async () => {
      const value: AgentRuntimeFacade = runtime('request-complete', FakeTaskScriptKind.COMPLETE);
      const input: TaskSubmission = submission('request-complete');
      const handle: TaskHandle = await value.submitTask(input);
      expect(handle.taskId).assertEqual('fake-task:request-complete');
      expect(handle.sessionId).assertEqual('fake-session:request-complete');
      expect((await value.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.COMPLETED);
      const detachedSnapshot = await value.getTaskSnapshot(handle.taskId);
      detachedSnapshot.status = AgentTaskStatus.FAILED;
      expect((await value.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.COMPLETED);
      expect((await value.submitTask(input)).taskId).assertEqual(handle.taskId);
      input.userIntent = 'changed after first submission';
      let rejected: boolean = false;
      try {
        await value.submitTask(input);
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('replaysEventsAfterSequenceAndReleasesSubscription', 0, async () => {
      const value: AgentRuntimeFacade = runtime('request-pause', FakeTaskScriptKind.PAUSABLE);
      const handle: TaskHandle = await value.submitTask(submission('request-pause'));
      const observer: RecordingObserver = new RecordingObserver();
      const active: AgentSubscription = await subscribe(value, handle.taskId, 1, observer);
      expect(observer.events.length).assertEqual(1);
      expect(observer.events[0].sequence).assertEqual(2);
      active.close();
      expect(active.isClosed()).assertTrue();
      await value.pauseTask(control('pause-1', handle.taskId, TaskControlAction.PAUSE));
      expect(observer.events.length).assertEqual(1);
    });

    it('completesAuthorizationApprovalAndMakesCommandReplayIdempotent', 0, async () => {
      const value: AgentRuntimeFacade = runtime('request-auth', FakeTaskScriptKind.AUTHORIZATION);
      const handle: TaskHandle = await value.submitTask(submission('request-auth'));
      const observer: RecordingObserver = new RecordingObserver();
      await subscribe(value, handle.taskId, 0, observer);
      expect(observer.policyRequests.length).assertEqual(1);
      const decision: AuthorizationDecision = new AuthorizationDecision();
      decision.commandId = 'authorize-1';
      decision.policyRequestId = observer.policyRequests[0].requestId;
      decision.userId = 'user-local';
      decision.taskId = handle.taskId;
      decision.decision = AuthorizationDecisionType.APPROVED;
      decision.decidedAt = '1970-01-01T00:00:01.002Z';
      decision.decidedAtMs = 1002;
      expect((await value.provideAuthorization(decision)).accepted).assertTrue();
      expect((await value.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.COMPLETED);
      expect((await value.provideAuthorization(decision)).duplicate).assertTrue();
    });

    it('keepsAuthorizationDenialAndCancellationConsumerVisible', 0, async () => {
      const denied: AgentRuntimeFacade = runtime('request-denied', FakeTaskScriptKind.AUTHORIZATION);
      const deniedHandle: TaskHandle = await denied.submitTask(submission('request-denied'));
      const deniedObserver: RecordingObserver = new RecordingObserver();
      await subscribe(denied, deniedHandle.taskId, 0, deniedObserver);
      const decision: AuthorizationDecision = new AuthorizationDecision();
      decision.commandId = 'deny-1';
      decision.policyRequestId = deniedObserver.policyRequests[0].requestId;
      decision.userId = 'user-local';
      decision.taskId = deniedHandle.taskId;
      decision.decision = AuthorizationDecisionType.DENIED;
      decision.denialReasonCode = 'USER_REJECTED';
      decision.decidedAt = '1970-01-01T00:00:01.002Z';
      decision.decidedAtMs = 1002;
      await denied.provideAuthorization(decision);
      expect((await denied.getTaskSnapshot(deniedHandle.taskId)).status).assertEqual(AgentTaskStatus.FAILED);

      const cancelled: AgentRuntimeFacade = runtime('request-cancel', FakeTaskScriptKind.AUTHORIZATION);
      const cancelledHandle: TaskHandle = await cancelled.submitTask(submission('request-cancel'));
      const command: TaskControlCommand = control('cancel-1', cancelledHandle.taskId, TaskControlAction.CANCEL);
      expect((await cancelled.cancelTask(command)).accepted).assertTrue();
      expect((await cancelled.cancelTask(command)).duplicate).assertTrue();
      command.reasonCode = 'changed-command';
      expect((await cancelled.cancelTask(command)).rejectionCode).assertEqual('COMMAND_ID_CONFLICT');
      expect((await cancelled.getTaskSnapshot(cancelledHandle.taskId)).status)
        .assertEqual(AgentTaskStatus.CANCELLED);
    });

    it('roundTripsClarificationThroughFacade', 0, async () => {
      const value: AgentRuntimeFacade = runtime('request-clarify', FakeTaskScriptKind.CLARIFICATION);
      const handle: TaskHandle = await value.submitTask(submission('request-clarify'));
      const observer: RecordingObserver = new RecordingObserver();
      await subscribe(value, handle.taskId, 0, observer);
      expect(observer.clarificationRequests.length).assertEqual(1);
      const response: ClarificationResponse = new ClarificationResponse();
      response.commandId = 'clarify-1';
      response.clarificationId = observer.clarificationRequests[0].clarificationId;
      response.taskId = handle.taskId;
      response.answerJson = '{"timeZone":"Asia/Shanghai"}';
      response.respondedAt = '1970-01-01T00:00:01.002Z';
      response.respondedAtMs = 1002;
      expect((await value.provideClarification(response)).accepted).assertTrue();
      expect((await value.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.COMPLETED);
    });

    it('pausesAndResumesThroughTheSingleFacade', 0, async () => {
      const value: AgentRuntimeFacade = runtime('request-resume', FakeTaskScriptKind.PAUSABLE);
      const handle: TaskHandle = await value.submitTask(submission('request-resume'));
      expect((await value.pauseTask(control('pause-2', handle.taskId, TaskControlAction.PAUSE))).accepted)
        .assertTrue();
      expect((await value.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.PAUSED);
      expect((await value.resumeTask(control('resume-2', handle.taskId, TaskControlAction.RESUME))).accepted)
        .assertTrue();
      expect((await value.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.COMPLETED);
    });

    it('doesNotHideUnknownOutcomeWhenCancellationArrives', 0, async () => {
      const value: AgentRuntimeFacade = runtime('request-reconcile', FakeTaskScriptKind.RECONCILIATION);
      const handle: TaskHandle = await value.submitTask(submission('request-reconcile'));
      expect((await value.cancelTask(
        control('cancel-unknown', handle.taskId, TaskControlAction.CANCEL))).accepted)
        .assertTrue();
      expect((await value.getTaskSnapshot(handle.taskId)).status)
        .assertEqual(AgentTaskStatus.WAITING_RECONCILIATION);
      const report: ReconciliationReport = new ReconciliationReport();
      report.commandId = 'reconcile-1';
      report.taskId = handle.taskId;
      report.stepId = 'fake-step';
      report.operationId = 'fake-operation:request-reconcile';
      report.status = ReconciliationStatus.CONFIRMED_SUCCEEDED;
      report.evidenceDigest = 'sha256:provider-receipt';
      report.reportedAt = '1970-01-01T00:00:01.005Z';
      expect((await value.provideReconciliation(report)).accepted).assertTrue();
      expect((await value.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.CANCELLED);
    });

    it('exposesPartialResultWithoutProductSpecificFields', 0, async () => {
      const value: AgentRuntimeFacade = runtime('request-partial', FakeTaskScriptKind.PARTIAL_SUCCESS);
      const handle: TaskHandle = await value.submitTask(submission('request-partial'));
      const snapshot = await value.getTaskSnapshot(handle.taskId);
      expect(snapshot.status).assertEqual(AgentTaskStatus.COMPLETED);
      expect(snapshot.resultJson.includes('"status":"partial"')).assertTrue();
      expect(snapshot.resultJson.includes('calendar')).assertFalse();
    });

    it('closesSubscriptionsAndRejectsCallsAfterShutdown', 0, async () => {
      const value: AgentRuntimeFacade = runtime('request-shutdown', FakeTaskScriptKind.PAUSABLE);
      const handle: TaskHandle = await value.submitTask(submission('request-shutdown'));
      const observer: RecordingObserver = new RecordingObserver();
      const active: AgentSubscription = await subscribe(value, handle.taskId, 0, observer);
      await value.shutdown(ShutdownMode.GRACEFUL);
      expect(active.isClosed()).assertTrue();
      let rejected: boolean = false;
      try {
        await value.getTaskSnapshot(handle.taskId);
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('providesReusableHeadlessFakeConsumer', 0, async () => {
      const value: AgentRuntimeFacade = runtime('request-consumer', FakeTaskScriptKind.AUTHORIZATION);
      const handle: TaskHandle = await value.submitTask(submission('request-consumer'));
      const consumer: FakeAgentConsumer = new FakeAgentConsumer();
      await consumer.attach(value, 'fake-consumer-subscription', handle.taskId, 0);
      expect(consumer.isAttached()).assertTrue();
      expect(consumer.events.length).assertEqual(2);
      expect(consumer.policyRequests.length).assertEqual(1);
      consumer.close();
      expect(consumer.isAttached()).assertFalse();
    });

    it('rejectsFutureSequenceAndMalformedClarificationAnswer', 0, async () => {
      const value: AgentRuntimeFacade = runtime('request-sequence', FakeTaskScriptKind.CLARIFICATION);
      const handle: TaskHandle = await value.submitTask(submission('request-sequence'));
      const observer: RecordingObserver = new RecordingObserver();
      let futureRejected: boolean = false;
      try {
        await subscribe(value, handle.taskId, 99, observer);
      } catch (error) {
        futureRejected = true;
      }
      expect(futureRejected).assertTrue();

      await subscribe(value, handle.taskId, 0, observer);
      const response: ClarificationResponse = new ClarificationResponse();
      response.commandId = 'clarify-malformed';
      response.clarificationId = observer.clarificationRequests[0].clarificationId;
      response.taskId = handle.taskId;
      response.answerJson = '{invalid';
      response.respondedAt = '1970-01-01T00:00:01.002Z';
      response.respondedAtMs = 1002;
      expect((await value.provideClarification(response)).rejectionCode).assertEqual('INVALID_ANSWER_JSON');
      expect((await value.getTaskSnapshot(handle.taskId)).status).assertEqual(AgentTaskStatus.WAITING_INPUT);
    });
  });
}
