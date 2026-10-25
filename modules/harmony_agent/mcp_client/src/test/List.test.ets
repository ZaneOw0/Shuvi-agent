import smokeTest from './Smoke.test';
import protocolTest from './Protocol.test';
import managerTest from './Manager.test';

export default function testsuite(): void {
  smokeTest();
  protocolTest();
  managerTest();
}

