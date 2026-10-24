import { DEBUG } from 'BuildProfile';
import { ArkTsDeepSeekHttpClient } from './DeepSeekHttpClient';
import { DirectModelCheckSession } from './DirectModelCheckSession';

// Keep the actual provider/composition surface available from the app service entry.
export { createDeepSeekProvider, DeepSeekProviderBundle } from './DeepSeekProvider';
export { createShuviModelBackend, ShuviModelBackendConfig, ShuviModelBackendPorts } from './ShuviModelBackend';
export { createShuviDeviceHostResources, ShuviDeviceHostResources } from './ShuviDeviceHostResources';

export class DirectModelCheckService {
  static readonly session: DirectModelCheckSession = new DirectModelCheckSession(new ArkTsDeepSeekHttpClient(), DEBUG);

  static background(): void {
    DirectModelCheckService.session.clearInput();
    DirectModelCheckService.session.cancel();
  }
}
