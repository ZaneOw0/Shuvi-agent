import { describe, expect, it } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { UIAbility, Want } from '@kit.AbilityKit';
import {
  MCP_CLIENT_VERSION,
  McpAuthorizationDecision,
  McpCancellationSource,
  McpCapabilityKind,
  McpClientError,
  McpClientManager,
  McpConnectionState,
  McpErrorCode,
  McpInvocationContext,
  McpInvocationPolicy,
  McpProtocolEra,
  McpProtocolMode
} from '@harmony_agent/mcp-client';

class AllowFixturePolicy implements McpInvocationPolicy {
  authorize(_context: McpInvocationContext): Promise<McpAuthorizationDecision> {
    const decision: McpAuthorizationDecision = { allowed: true };
    return Promise.resolve(decision);
  }
}

class TestHostMonitor implements abilityDelegatorRegistry.AbilityMonitor {
  abilityName: string = 'TestHostAbility';
  moduleName: string = 'test_host';
}

function fixtureUrl(): string {
  const parameters: Record<string, string> = abilityDelegatorRegistry.getArguments().parameters;
  const directValue: string | undefined = parameters['fixtureUrl'];
  if (directValue !== undefined) return directValue;
  const literalValue: string | undefined = parameters['-s fixtureUrl'];
  return literalValue === undefined ? '' : literalValue;
}

export default function deviceSmokeTest(): void {
  describe('McpDeviceSmoke', () => {
    it('loadsHar', 0, () => {
      expect(MCP_CLIENT_VERSION).assertEqual('0.2.0');
    });

    it('callsModernFixtureOverRealNetwork', 0, async () => {
      const baseUrl: string = fixtureUrl();
      expect(baseUrl.length > 0).assertTrue();
      const manager: McpClientManager = new McpClientManager({
        clientName: 'harmony_agent Device Test',
        clientVersion: MCP_CLIENT_VERSION,
        debugBuild: true,
        invocationPolicy: new AllowFixturePolicy()
      });
      manager.registerServer({
        id: 'modern-device',
        endpoint: `${baseUrl}/modern`,
        protocolMode: McpProtocolMode.MODERN,
        allowInsecureHttp: true,
        connectTimeoutMs: 5000,
        requestTimeoutMs: 5000
      });
      try {
        const connected = await manager.connect('modern-device');
        expect(connected.era).assertEqual(McpProtocolEra.MODERN);
        const tools = await manager.listTools();
        expect(tools.errors.length).assertEqual(0);
        expect(tools.items.length).assertEqual(3);
        const result = await manager.callTool({
          serverId: 'modern-device',
          kind: McpCapabilityKind.TOOL,
          name: 'echo'
        }, JSON.parse('{"text":"device-network"}'));
        expect(result.isError).assertFalse();
        expect(result.content[0].text).assertEqual('device-network');
      } finally {
        await manager.disconnectAll();
      }
    });

    it('doesNotTreatAuthenticationOrServerFailureAsLegacy', 0, async () => {
      const baseUrl: string = fixtureUrl();
      const statuses: number[] = [401, 403, 500];
      const codes: McpErrorCode[] = [
        McpErrorCode.AUTHENTICATION, McpErrorCode.FORBIDDEN, McpErrorCode.NETWORK
      ];
      for (let index: number = 0; index < statuses.length; index++) {
        const manager: McpClientManager = new McpClientManager({ debugBuild: true });
        const serverId: string = `failure-device-${statuses[index]}`;
        manager.registerServer({
          id: serverId,
          endpoint: `${baseUrl}/status/${statuses[index]}`,
          protocolMode: McpProtocolMode.AUTO,
          allowInsecureHttp: true,
          connectTimeoutMs: 5000,
          requestTimeoutMs: 5000
        });
        let errorCode: string = '';
        try {
          await manager.connect(serverId);
        } catch (error) {
          errorCode = error instanceof McpClientError ? error.code : '';
        } finally {
          await manager.disconnectAll();
        }
        expect(errorCode).assertEqual(codes[index]);
      }
    });

    it('enforcesResponseSizeAndTimeoutOnRealTransport', 0, async () => {
      const baseUrl: string = fixtureUrl();
      const oversized: McpClientManager = new McpClientManager({ debugBuild: true });
      oversized.registerServer({
        id: 'oversized-device',
        endpoint: `${baseUrl}/modern?large=1`,
        protocolMode: McpProtocolMode.MODERN,
        allowInsecureHttp: true,
        maxResponseBytes: 512
      });
      let oversizedCode: string = '';
      try {
        await oversized.connect('oversized-device');
      } catch (error) {
        oversizedCode = error instanceof McpClientError ? error.code : '';
      } finally {
        await oversized.disconnectAll();
      }
      expect(oversizedCode).assertEqual(McpErrorCode.RESPONSE_TOO_LARGE);

      const timeout: McpClientManager = new McpClientManager({ debugBuild: true });
      timeout.registerServer({
        id: 'timeout-device',
        endpoint: `${baseUrl}/slow`,
        protocolMode: McpProtocolMode.AUTO,
        allowInsecureHttp: true,
        connectTimeoutMs: 1000,
        requestTimeoutMs: 100
      });
      let timeoutCode: string = '';
      try {
        await timeout.connect('timeout-device');
      } catch (error) {
        timeoutCode = error instanceof McpClientError ? error.code : '';
      } finally {
        await timeout.disconnectAll();
      }
      expect(timeoutCode).assertEqual(McpErrorCode.TIMEOUT);
    });

    it('isolatesDroppedNetworkConnectionWithoutLegacyFallback', 0, async () => {
      const baseUrl: string = fixtureUrl();
      const manager: McpClientManager = new McpClientManager({ debugBuild: true });
      manager.registerServer({
        id: 'drop-device',
        endpoint: `${baseUrl}/drop`,
        protocolMode: McpProtocolMode.AUTO,
        allowInsecureHttp: true,
        connectTimeoutMs: 1000,
        requestTimeoutMs: 1000
      });
      let code: string = '';
      try {
        await manager.connect('drop-device');
      } catch (error) {
        code = error instanceof McpClientError ? error.code : '';
      } finally {
        await manager.disconnectAll();
      }
      expect(code).assertEqual(McpErrorCode.NETWORK);
    });

    it('deniesToolCallsBeforeSendingWithoutPolicy', 0, async () => {
      const baseUrl: string = fixtureUrl();
      const manager: McpClientManager = new McpClientManager({ debugBuild: true });
      manager.registerServer({
        id: 'policy-device',
        endpoint: `${baseUrl}/modern`,
        protocolMode: McpProtocolMode.MODERN,
        allowInsecureHttp: true
      });
      try {
        await manager.connect('policy-device');
        await manager.listTools();
        const before = await manager.readResource({
          serverId: 'policy-device',
          kind: McpCapabilityKind.RESOURCE,
          name: 'fixture://stats'
        });
        const beforeResource: Record<string, Object> = before.contents[0].resource as Record<string, Object>;
        const beforeStats: Record<string, Object> = JSON.parse(String(beforeResource['text'])) as Record<string, Object>;
        let errorCode: string = '';
        try {
          await manager.callTool({
            serverId: 'policy-device',
            kind: McpCapabilityKind.TOOL,
            name: 'echo'
          }, JSON.parse('{"text":"must-not-send"}'));
        } catch (error) {
          errorCode = error instanceof McpClientError ? error.code : '';
        }
        const after = await manager.readResource({
          serverId: 'policy-device',
          kind: McpCapabilityKind.RESOURCE,
          name: 'fixture://stats'
        });
        const afterResource: Record<string, Object> = after.contents[0].resource as Record<string, Object>;
        const afterStats: Record<string, Object> = JSON.parse(String(afterResource['text'])) as Record<string, Object>;
        expect(errorCode).assertEqual(McpErrorCode.POLICY_DENIED);
        expect(Number(afterStats['toolCalls'])).assertEqual(Number(beforeStats['toolCalls']));
      } finally {
        await manager.disconnectAll();
      }
    });

    it('reconnectsAndReleasesResources', 0, async () => {
      const baseUrl: string = fixtureUrl();
      const manager: McpClientManager = new McpClientManager({ debugBuild: true });
      manager.registerServer({
        id: 'recovery-device',
        endpoint: `${baseUrl}/modern`,
        protocolMode: McpProtocolMode.MODERN,
        allowInsecureHttp: true
      });
      await manager.connect('recovery-device');
      await manager.disconnect('recovery-device');
      expect(manager.getConnections()[0].state).assertEqual(McpConnectionState.DISCONNECTED);
      await manager.connect('recovery-device');
      expect(manager.getConnections()[0].state).assertEqual(McpConnectionState.READY);
      await manager.disconnectAll();
      expect(manager.getConnections()[0].state).assertEqual(McpConnectionState.DISCONNECTED);
    });

    it('cancelsActiveRequestOverRealTransport', 0, async () => {
      const baseUrl: string = fixtureUrl();
      const manager: McpClientManager = new McpClientManager({
        debugBuild: true,
        invocationPolicy: new AllowFixturePolicy()
      });
      manager.registerServer({
        id: 'cancel-device',
        endpoint: `${baseUrl}/modern`,
        protocolMode: McpProtocolMode.MODERN,
        allowInsecureHttp: true,
        requestTimeoutMs: 10000
      });
      try {
        await manager.connect('cancel-device');
        await manager.listTools();
        const cancellation: McpCancellationSource = new McpCancellationSource();
        setTimeout(() => cancellation.cancel(), 100);
        let errorCode: string = '';
        try {
          await manager.callTool({
            serverId: 'cancel-device',
            kind: McpCapabilityKind.TOOL,
            name: 'echo'
          }, JSON.parse('{"text":"device-cancel"}'), cancellation);
        } catch (error) {
          errorCode = error instanceof McpClientError ? error.code : '';
        }
        expect(errorCode).assertEqual(McpErrorCode.CANCELLED);
      } finally {
        await manager.disconnectAll();
      }
    });

    it('retriesReadOnlyToolAfterExpiredLegacySession', 0, async () => {
      const baseUrl: string = fixtureUrl();
      const manager: McpClientManager = new McpClientManager({
        debugBuild: true,
        invocationPolicy: new AllowFixturePolicy()
      });
      manager.registerServer({
        id: 'expired-device',
        endpoint: `${baseUrl}/legacy-expire`,
        protocolMode: McpProtocolMode.LEGACY,
        allowInsecureHttp: true,
        retryToolCallOnExpiredSession: true
      });
      try {
        await manager.connect('expired-device');
        await manager.listTools();
        const result = await manager.callTool({
          serverId: 'expired-device',
          kind: McpCapabilityKind.TOOL,
          name: 'echo'
        }, JSON.parse('{"text":"after-expiry"}'));
        expect(result.isError).assertFalse();
        expect(result.content[0].text).assertEqual('after-expiry');
      } finally {
        await manager.disconnectAll();
      }
    });

    it('continuesAfterTestHostBackgroundForegroundCycle', 0, async () => {
      const baseUrl: string = fixtureUrl();
      const manager: McpClientManager = new McpClientManager({
        debugBuild: true,
        invocationPolicy: new AllowFixturePolicy()
      });
      manager.registerServer({
        id: 'lifecycle-device',
        endpoint: `${baseUrl}/modern`,
        protocolMode: McpProtocolMode.MODERN,
        allowInsecureHttp: true
      });
      const delegator: abilityDelegatorRegistry.AbilityDelegator =
        abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: TestHostMonitor = new TestHostMonitor();
      let monitorAdded: boolean = false;
      let hostAbility: UIAbility | undefined = undefined;
      try {
        await manager.connect('lifecycle-device');
        await delegator.addAbilityMonitor(monitor);
        monitorAdded = true;
        const waiting: Promise<UIAbility> = delegator.waitAbilityMonitor(monitor, 5000);
        const want: Want = {
          bundleName: 'com.example.shuvi.agenttest',
          moduleName: 'test_host',
          abilityName: 'TestHostAbility'
        };
        await delegator.startAbility(want);
        hostAbility = await waiting;
        await delegator.doAbilityBackground(hostAbility);
        await delegator.doAbilityForeground(hostAbility);
        const resources = await manager.listResources();
        expect(resources.errors.length).assertEqual(0);
        expect(resources.items.length).assertEqual(2);
      } finally {
        if (hostAbility !== undefined) {
          try {
            await hostAbility.context.terminateSelf();
          } catch (_error) {
          }
        }
        if (monitorAdded) {
          try {
            await delegator.removeAbilityMonitor(monitor);
          } catch (_error) {
          }
        }
        await manager.disconnectAll();
      }
    });
  });
}
