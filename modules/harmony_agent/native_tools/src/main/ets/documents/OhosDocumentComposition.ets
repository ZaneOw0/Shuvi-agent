import relationalStore from '@ohos.data.relationalStore';
import {
  NativeCancellationResolverPort, NativeExecutionEnvironmentPort, NativeGrantVerifierPort
} from '../native/NativeToolContracts';
import { SystemNativeCapabilityProbe, SystemNativeClock } from '../native/NativeToolSupport';
import { LocalDocumentStore } from './LocalDocumentStore';
import { NativeDocumentTools } from './NativeDocumentTools';
import { OhosDocumentBlobStore, RdbDocumentCatalog, SystemNativeDocumentDigest } from './OhosDocumentStorage';

export class OhosNativeDocumentToolSet {
  readonly store: LocalDocumentStore;
  readonly tools: NativeDocumentTools;
  constructor(store: LocalDocumentStore, tools: NativeDocumentTools) { this.store = store; this.tools = tools; }
}

/** Database lifecycle and a stable, owner-specific scope remain host-owned. No UI is created. */
export async function createOhosNativeDocumentTools(filesDir: string, scopeId: string,
  database: relationalStore.RdbStore, grants: NativeGrantVerifierPort, environment: NativeExecutionEnvironmentPort,
  cancellations: NativeCancellationResolverPort): Promise<OhosNativeDocumentToolSet> {
  const digest: SystemNativeDocumentDigest = new SystemNativeDocumentDigest();
  const clock: SystemNativeClock = new SystemNativeClock();
  const catalog: RdbDocumentCatalog = new RdbDocumentCatalog(database, scopeId, digest);
  await catalog.initialize();
  const blobs: OhosDocumentBlobStore = new OhosDocumentBlobStore(filesDir, scopeId);
  const identity: string = digest.digest('native-document-storage-v1|' + blobs.directory);
  const store: LocalDocumentStore = new LocalDocumentStore(scopeId, catalog, blobs, digest, clock, identity);
  const tools: NativeDocumentTools = new NativeDocumentTools(store, digest, clock,
    new SystemNativeCapabilityProbe(), environment, grants, cancellations);
  return new OhosNativeDocumentToolSet(store, tools);
}
