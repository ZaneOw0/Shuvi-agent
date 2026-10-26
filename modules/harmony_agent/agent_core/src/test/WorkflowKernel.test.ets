import { describe, expect, it } from '@ohos/hypium';
import {
  AgentErrorClass,
  IdempotencyMode,
  RiskLevel,
  SideEffect,
  WorkflowGraph,
  WorkflowInputBinding,
  WorkflowStep,
  WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import {
  DeterministicRecoveryPolicy,
  OperationJournal,
  OperationJournalState,
  RecoveryAction,
  StepExecutionResult,
  StepExecutionStatus,
  WorkflowGraphValidator,
  WorkflowRunState,
  WorkflowScheduler,
  WorkflowStepState
} from '../../Index';

function step(stepId: string, dependencies: string[] = []): WorkflowStep {
  const value: WorkflowStep = new WorkflowStep();
  value.stepId = stepId;
  value.kind = WorkflowStepKind.LLM;
  value.goal = 'execute ' + stepId;
  value.dependencies = dependencies;
  value.expectedOutputSchemaJson = '{"type":"object"}';
  value.sideEffect = SideEffect.NONE;
  value.riskLevel = RiskLevel.LOW;
  value.idempotencyMode = IdempotencyMode.NONE;
  value.timeoutMs = 1000;
  value.retryPolicyRef = 'retry.none';
  value.verificationPolicyRef = 'verify.shape';
  return value;
}

function diamondGraph(): WorkflowGraph {
  const graph: WorkflowGraph = new WorkflowGraph();
  graph.workflowId = 'workflow-diamond';
  graph.taskId = 'task-1';
  graph.workflowVersion = '1.0.0';
  graph.createdAt = '2026-09-29T10:00:00+08:00';
  graph.entryStepIds = ['start'];
  graph.steps = [step('start'), step('branch-a', ['start']), step('branch-b', ['start']),
    step('join', ['branch-a', 'branch-b'])];
  graph.steps[3].kind = WorkflowStepKind.JOIN;
  graph.steps[3].timeoutMs = 0;
  return graph;
}

function success(digest: string = ''): StepExecutionResult {
  const result: StepExecutionResult = new StepExecutionResult();
  result.status = StepExecutionStatus.SUCCEEDED;
  result.outputDigest = digest;
  return result;
}

function runSuccess(scheduler: WorkflowScheduler, stepId: string, nowMs: number): void {
  scheduler.markRunning(stepId, nowMs);
  scheduler.markVerifying(stepId, nowMs + 1);
  scheduler.completeStep(stepId, success('sha256:' + stepId), nowMs + 2);
}

export default function workflowKernelTest(): void {
  describe('WorkflowKernel', () => {
    it('validatesDiamondGraphAndUsesStableReadyOrder', 0, () => {
      const graph: WorkflowGraph = diamondGraph();
      expect(WorkflowGraphValidator.validate(graph).valid).assertTrue();
      const scheduler: WorkflowScheduler = new WorkflowScheduler(graph);
      scheduler.start(100);
      expect(scheduler.readyStepIds().join(',')).assertEqual('start');
      runSuccess(scheduler, 'start', 110);
      expect(scheduler.readyStepIds().join(',')).assertEqual('branch-a,branch-b');
    });

    it('rejectsCycleMissingDependencyAndUnsafeSideEffectBeforeStart', 0, () => {
      const graph: WorkflowGraph = diamondGraph();
      graph.entryStepIds = ['branch-b'];
      graph.steps[0].dependencies = ['join'];
      graph.steps[1].dependencies = ['missing'];
      graph.steps[2].sideEffect = SideEffect.IRREVERSIBLE;
      expect(WorkflowGraphValidator.validate(graph).valid).assertFalse();
      let threw: boolean = false;
      try {
        new WorkflowScheduler(graph);
      } catch (error) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('rejectsInvalidBindingsAndToolWithoutCapability', 0, () => {
      const graph: WorkflowGraph = diamondGraph();
      const binding: WorkflowInputBinding = new WorkflowInputBinding();
      binding.name = 'input';
      binding.sourceStepId = 'start';
      binding.literalJson = '{}';
      graph.steps[1].inputBindings = [binding];
      graph.steps[2].kind = WorkflowStepKind.TOOL;
      expect(WorkflowGraphValidator.validate(graph).valid).assertFalse();
    });

    it('joinsParallelBranchesAndCompletesDeterministically', 0, () => {
      const scheduler: WorkflowScheduler = new WorkflowScheduler(diamondGraph());
      scheduler.start(100);
      runSuccess(scheduler, 'start', 110);
      runSuccess(scheduler, 'branch-b', 120);
      expect(scheduler.readyStepIds().length).assertEqual(1);
      expect(scheduler.readyStepIds()[0]).assertEqual('branch-a');
      runSuccess(scheduler, 'branch-a', 130);
      expect(scheduler.readyStepIds()[0]).assertEqual('join');
      runSuccess(scheduler, 'join', 140);
      expect(scheduler.getRunState()).assertEqual(WorkflowRunState.COMPLETED);
      const events = scheduler.getEvents();
      for (let i: number = 0; i < events.length; i++) {
        expect(events[i].sequence).assertEqual(i + 1);
      }
    });

    it('serializesSideEffectsButKeepsIndependentReadsParallel', 0, () => {
      const readScheduler: WorkflowScheduler = new WorkflowScheduler(diamondGraph());
      readScheduler.start(100);
      runSuccess(readScheduler, 'start', 110);
      readScheduler.markRunning('branch-a', 120);
      expect(readScheduler.readyStepIds().join(',')).assertEqual('branch-b');

      const writeGraph: WorkflowGraph = diamondGraph();
      writeGraph.steps[1].sideEffect = SideEffect.REVERSIBLE;
      writeGraph.steps[1].idempotencyMode = IdempotencyMode.RECONCILE;
      const writeScheduler: WorkflowScheduler = new WorkflowScheduler(writeGraph);
      writeScheduler.start(100);
      runSuccess(writeScheduler, 'start', 110);
      expect(writeScheduler.readyStepIds().join(',')).assertEqual('branch-a');
      writeScheduler.markRunning('branch-a', 120);
      expect(writeScheduler.readyStepIds().length).assertEqual(0);
      let conflictRejected: boolean = false;
      try {
        writeScheduler.markRunning('branch-b', 121);
      } catch (error) {
        conflictRejected = true;
      }
      expect(conflictRejected).assertTrue();
    });

    it('propagatesCancellationAndDeadline', 0, () => {
      const cancelled: WorkflowScheduler = new WorkflowScheduler(diamondGraph());
      cancelled.start(100);
      cancelled.requestCancellation('user request', 110);
      expect(cancelled.getRunState()).assertEqual(WorkflowRunState.CANCELLED);
      expect(cancelled.getStepRecord('branch-a').state).assertEqual(WorkflowStepState.CANCELLED);

      const timedOut: WorkflowScheduler = new WorkflowScheduler(diamondGraph());
      timedOut.start(100, 150);
      expect(timedOut.enforceDeadline(150)).assertTrue();
      expect(timedOut.getRunState()).assertEqual(WorkflowRunState.FAILED);
      expect(timedOut.getStepRecord('start').lastErrorClass).assertEqual(AgentErrorClass.TIMEOUT);

      const stepTimedOut: WorkflowScheduler = new WorkflowScheduler(diamondGraph());
      stepTimedOut.start(100);
      stepTimedOut.markRunning('start', 110);
      expect(stepTimedOut.enforceDeadline(1110)).assertTrue();
      expect(stepTimedOut.getRunState()).assertEqual(WorkflowRunState.FAILED);
      expect(stepTimedOut.getStepRecord('start').lastErrorClass).assertEqual(AgentErrorClass.TIMEOUT);
    });

    it('requiresVerificationBeforeSuccessfulCompletion', 0, () => {
      const scheduler: WorkflowScheduler = new WorkflowScheduler(diamondGraph());
      scheduler.start(100);
      scheduler.markRunning('start', 110);
      let threw: boolean = false;
      try {
        scheduler.completeStep('start', success(), 120);
      } catch (error) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(scheduler.getStepRecord('start').state).assertEqual(WorkflowStepState.RUNNING);
    });

    it('retriesInterruptedReadButReconcilesInterruptedSideEffect', 0, () => {
      const readGraph: WorkflowGraph = diamondGraph();
      const readScheduler: WorkflowScheduler = new WorkflowScheduler(readGraph);
      readScheduler.start(100);
      readScheduler.markRunning('start', 110);
      const restoredRead: WorkflowScheduler = WorkflowScheduler.restore(readGraph, readScheduler.snapshot(), 200);
      expect(restoredRead.getRunState()).assertEqual(WorkflowRunState.RUNNING);
      expect(restoredRead.readyStepIds()[0]).assertEqual('start');

      const writeGraph: WorkflowGraph = diamondGraph();
      writeGraph.steps[0].sideEffect = SideEffect.IRREVERSIBLE;
      writeGraph.steps[0].idempotencyMode = IdempotencyMode.RECONCILE;
      const writeScheduler: WorkflowScheduler = new WorkflowScheduler(writeGraph);
      writeScheduler.start(100);
      writeScheduler.markRunning('start', 110);
      const restoredWrite: WorkflowScheduler = WorkflowScheduler.restore(writeGraph,
        writeScheduler.snapshot(), 200);
      expect(restoredWrite.getRunState()).assertEqual(WorkflowRunState.WAITING_RECONCILIATION);
      expect(restoredWrite.readyStepIds().length).assertEqual(0);
      expect(restoredWrite.getStepRecord('start').state).assertEqual(WorkflowStepState.UNKNOWN_OUTCOME);
      restoredWrite.requestCancellation('user request during reconciliation', 205);
      expect(restoredWrite.getRunState()).assertEqual(WorkflowRunState.WAITING_RECONCILIATION);
      restoredWrite.reconcileUnknownOutcome('start', success('sha256:confirmed'), 210);
      expect(restoredWrite.getRunState()).assertEqual(WorkflowRunState.CANCELLED);
      expect(restoredWrite.readyStepIds().length).assertEqual(0);
    });

    it('doesNotHideInFlightWriteOutcomeOnCancelOrTimeout', 0, () => {
      const writeGraph: WorkflowGraph = diamondGraph();
      writeGraph.steps[0].sideEffect = SideEffect.IRREVERSIBLE;
      writeGraph.steps[0].idempotencyMode = IdempotencyMode.RECONCILE;

      const cancelled: WorkflowScheduler = new WorkflowScheduler(writeGraph);
      cancelled.start(100);
      cancelled.markRunning('start', 110);
      cancelled.requestCancellation('user request', 120);
      expect(cancelled.getRunState()).assertEqual(WorkflowRunState.WAITING_RECONCILIATION);
      expect(cancelled.getStepRecord('start').state).assertEqual(WorkflowStepState.UNKNOWN_OUTCOME);

      const timedOut: WorkflowScheduler = new WorkflowScheduler(writeGraph);
      timedOut.start(100);
      timedOut.markRunning('start', 110);
      expect(timedOut.enforceDeadline(1110)).assertTrue();
      expect(timedOut.getRunState()).assertEqual(WorkflowRunState.WAITING_RECONCILIATION);
      expect(timedOut.getStepRecord('start').state).assertEqual(WorkflowStepState.UNKNOWN_OUTCOME);
    });

    it('makesBoundedRecoveryDecisions', 0, () => {
      const policy: DeterministicRecoveryPolicy = new DeterministicRecoveryPolicy(1);
      const graph: WorkflowGraph = diamondGraph();
      const scheduler: WorkflowScheduler = new WorkflowScheduler(graph);
      scheduler.start(100);
      scheduler.markRunning('start', 110);
      const failure: StepExecutionResult = new StepExecutionResult();
      failure.status = StepExecutionStatus.FAILED;
      failure.errorClass = AgentErrorClass.NETWORK;
      expect(policy.decide(graph.steps[0], scheduler.getStepRecord('start'), failure).action)
        .assertEqual(RecoveryAction.RETRY_STEP);
      failure.status = StepExecutionStatus.UNKNOWN_OUTCOME;
      expect(policy.decide(graph.steps[0], scheduler.getStepRecord('start'), failure).action)
        .assertEqual(RecoveryAction.RECONCILE);
      failure.status = StepExecutionStatus.FAILED;
      failure.errorClass = AgentErrorClass.POLICY_DENIED;
      expect(policy.decide(graph.steps[0], scheduler.getStepRecord('start'), failure).action)
        .assertEqual(RecoveryAction.FAIL_TASK);
    });

    it('appliesRetryDecisionAndPreservesRecoveryAcrossRestart', 0, () => {
      const policy: DeterministicRecoveryPolicy = new DeterministicRecoveryPolicy(1);
      const graph: WorkflowGraph = diamondGraph();
      const scheduler: WorkflowScheduler = new WorkflowScheduler(graph);
      scheduler.start(100);
      scheduler.markRunning('start', 110);
      const failure: StepExecutionResult = new StepExecutionResult();
      failure.status = StepExecutionStatus.FAILED;
      failure.errorClass = AgentErrorClass.NETWORK;
      scheduler.completeStep('start', failure, 120);
      expect(scheduler.getRunState()).assertEqual(WorkflowRunState.RECOVERING);

      const restored: WorkflowScheduler = WorkflowScheduler.restore(graph, scheduler.snapshot(), 130);
      expect(restored.getRunState()).assertEqual(WorkflowRunState.RECOVERING);
      restored.applyRecoveryDecision('start', policy.decide(graph.steps[0],
        restored.getStepRecord('start'), failure), 140);
      expect(restored.readyStepIds()[0]).assertEqual('start');
      restored.markRunning('start', 150);
      expect(policy.decide(graph.steps[0], restored.getStepRecord('start'), failure).action)
        .assertEqual(RecoveryAction.FAIL_TASK);
      restored.markVerifying('start', 151);
      restored.completeStep('start', success('sha256:start'), 152);
      expect(restored.getStepRecord('start').attemptCount).assertEqual(2);
    });

    it('journalBlocksRedispatchAfterUnknownRestartOutcome', 0, () => {
      const journal: OperationJournal = new OperationJournal();
      journal.prepare('operation-1', 'start', 'idem-1', 100);
      expect(journal.canDispatch('operation-1')).assertTrue();
      journal.markInFlight('operation-1', 110);
      const restored: OperationJournal = OperationJournal.restore(journal.snapshot());
      expect(restored.get('operation-1').state).assertEqual(OperationJournalState.UNKNOWN_OUTCOME);
      expect(restored.canDispatch('operation-1')).assertFalse();
      restored.reconcileUnknownOutcome('operation-1', false, 120);
      expect(restored.canDispatch('operation-1')).assertTrue();
    });

    it('runsFixedWorkflowThroughFakeExecutorBoundary', 0, () => {
      const scheduler: WorkflowScheduler = new WorkflowScheduler(diamondGraph());
      scheduler.start(100);
      let nowMs: number = 110;
      while (scheduler.getRunState() === WorkflowRunState.RUNNING) {
        const ready: string[] = scheduler.readyStepIds();
        for (let i: number = 0; i < ready.length; i++) {
          runSuccess(scheduler, ready[i], nowMs);
          nowMs += 10;
        }
      }
      expect(scheduler.getRunState()).assertEqual(WorkflowRunState.COMPLETED);
      expect(scheduler.getStepRecord('join').state).assertEqual(WorkflowStepState.SUCCEEDED);
    });
  });
}
