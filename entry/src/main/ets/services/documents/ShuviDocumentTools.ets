import common from '@ohos.app.ability.common';
import relationalStore from '@ohos.data.relationalStore';
import { McpRuntimeToolExtension } from '@harmony_agent/agent-connectors';
import {
  createOhosNativeDocumentTools, NativeCancellationResolverPort, NativeExecutionEnvironmentPort,
  NativeGrantVerifierPort, OhosNativeDocumentToolSet
} from '@harmony_agent/native-tools';

/** Background-only composition. The owner opens/closes the encrypted RDB and drains its Runtime first. */
export class ShuviDocumentTools {
  readonly documents: OhosNativeDocumentToolSet;
  private constructor(documents: OhosNativeDocumentToolSet) { this.documents = documents; }

  static async create(context: common.UIAbilityContext, database: relationalStore.RdbStore, scopeId: string,
    grants: NativeGrantVerifierPort, environment: NativeExecutionEnvironmentPort,
    cancellations: NativeCancellationResolverPort): Promise<ShuviDocumentTools> {
    const documents: OhosNativeDocumentToolSet = await createOhosNativeDocumentTools(
      context.filesDir, scopeId, database, grants, environment, cancellations);
    return new ShuviDocumentTools(documents);
  }

  extension(): McpRuntimeToolExtension {
    return new McpRuntimeToolExtension(this.documents.tools.entries(), this.documents.tools);
  }
}
