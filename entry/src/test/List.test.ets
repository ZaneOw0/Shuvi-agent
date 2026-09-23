import { describe, it } from '@ohos/hypium';
import { mockAssistantCases } from './MockAssistantCases';

export default function testsuite(): void {
  describe('MockAssistantService', () => {
    for (const testCase of mockAssistantCases()) {
      it(testCase.name, 0, testCase.run);
    }
  });
}
