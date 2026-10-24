import { describe, it } from '@ohos/hypium';
import { mockAssistantCases } from './MockAssistantCases';
import { mockSearchCases } from './MockSearchCases';

export default function testsuite(): void {
  describe('MockAssistantService', () => {
    for (const testCase of mockAssistantCases()) {
      it(testCase.name, 0, testCase.run);
    }
  });
  describe('MockSearchSession', () => {
    for (const testCase of mockSearchCases()) {
      it(testCase.name, 0, testCase.run);
    }
  });
}
