import { describe, expect, it } from '@ohos/hypium';
import { MCP_CLIENT_VERSION } from '../../Index';

export default function smokeTest(): void {
  describe('McpClientSmoke', () => {
    it('exportsVersion', 0, () => {
      expect(MCP_CLIENT_VERSION).assertEqual('0.2.0');
    });
  });
}

