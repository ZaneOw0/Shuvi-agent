import { CollaborationMode, ExecutionBudget, TaskFrame } from '@harmony_agent/agent-contracts';
import { CollaborationPolicyPreparationPort } from '../main/ets/routing/CollaborationPreparation';
import { CollaborationPlan, CollaborationRoleAssignment } from '../main/ets/orchestration/OrchestrationTypes';
import { ArtifactPolicyCancellationSignalPort } from '../main/ets/artifact/ArtifactPolicyReleaseTypes';

export class FakeCollaborationPreparation implements CollaborationPolicyPreparationPort {
  calls: number = 0;
  pending: boolean = false;
  cancelled: boolean = false;
  taskId: string = '';
  entered: Promise<void>;
  private enteredResolve?: () => void;
  constructor() {
    this.entered = new Promise<void>((resolve) => { this.enteredResolve = resolve; });
  }
  async prepare(frame: TaskFrame, budget: ExecutionBudget,
    cancellation: ArtifactPolicyCancellationSignalPort): Promise<void> {
    this.calls++;
    this.taskId = frame.taskId;
    cancellation.subscribe(() => { this.cancelled = true; });
    const entered = this.enteredResolve;
    if (entered !== undefined) entered();
    if (this.pending) return new Promise<void>(() => {});
  }
  selectPlan(frame: TaskFrame, budget: number): CollaborationPlan { return this.plan(frame, Math.min(2, budget)); }
  selectBaselinePlan(frame: TaskFrame, budget: number): CollaborationPlan { return this.plan(frame, 1); }
  private plan(frame: TaskFrame, count: number): CollaborationPlan {
    const plan = new CollaborationPlan();
    plan.taskId = frame.taskId;
    plan.mode = count > 1 ? CollaborationMode.MULTI : CollaborationMode.SINGLE;
    plan.roleRegistryDigest = 'sha256:' + 'a'.repeat(64);
    plan.decisionDigest = 'sha256:' + 'b'.repeat(64);
    for (let i: number = 0; i < count; i++) {
      const role = new CollaborationRoleAssignment();
      role.roleId = 'role-' + i.toString(); role.roleVersion = '1'; role.roleRegistryDigest = plan.roleRegistryDigest;
      plan.assignments.push(role);
    }
    return plan;
  }
}
