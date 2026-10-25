import { ShuviRuntimeController } from './ShuviRuntimeController';

/** One controller for the current single-Ability application; no automatic configuration or network I/O. */
export class ShuviRuntimeService {
  static readonly session: ShuviRuntimeController = new ShuviRuntimeController();
}
