import policyGatewayTest from './PolicyGateway.test';
import collaborationPreparationTests from './CollaborationPreparation.test';
import fakeAgentRuntimeTest from './FakeAgentRuntime.test';
import runtimeCoordinatorTest from './RuntimeCoordinator.test';
import deterministicRoutersTest from './DeterministicRouters.test';
import productionAgentRuntimeTest from './ProductionAgentRuntime.test';
import artifactRegistryTest from './ArtifactRegistry.test';
import artifactPolicyReleaseRunnerTest from './ArtifactPolicyReleaseRunner.test';
import managedArtifactPolicyLoaderTest from './ManagedArtifactPolicyLoader.test';
import singleAgentHostRuntimeTest from './SingleAgentHostRuntime.test';

export default function testsuite(): void {
  collaborationPreparationTests();
  policyGatewayTest();
  fakeAgentRuntimeTest();
  runtimeCoordinatorTest();
  deterministicRoutersTest();
  productionAgentRuntimeTest();
  artifactRegistryTest();
  artifactPolicyReleaseRunnerTest();
  managedArtifactPolicyLoaderTest();
  singleAgentHostRuntimeTest();
}
