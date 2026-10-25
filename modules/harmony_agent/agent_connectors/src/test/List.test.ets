import mcpAgentAdapterTest from './McpAgentAdapter.test';
import providerConnectorsTest from './ProviderConnectors.test';
import localAIGatewayTransportTest from './LocalAIGatewayTransport.test';
import providerSemanticPlannerTest from './ProviderSemanticPlanner.test';
import assetStoreProviderCredentialPortTest from './AssetStoreProviderCredentialPort.test';
import shuviWebSearchTest from './ShuviWebSearch.test';

export default function testsuite(): void {
  mcpAgentAdapterTest();
  providerConnectorsTest();
  localAIGatewayTransportTest();
  providerSemanticPlannerTest();
  assetStoreProviderCredentialPortTest();
  shuviWebSearchTest();
}
