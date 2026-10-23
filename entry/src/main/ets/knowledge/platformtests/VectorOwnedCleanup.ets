import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';

export async function vectorCleanupOwnedFailures(context: common.Context): Promise<number> {
  let count: number = 0;
  // Exact run identities emitted by this turn's vector suite. No discovery,
  // production name, derived asset or other agent's scope is accepted here.
  for (const run of ['000001a14548138d','000001a145495aee','000001a1454ab601','000001a1454c10c9','000001a1454d52da','000001a1454f0531','000001a1455a9226','000001a1455c17af','000001a1455fba91','000001a14567ab96']) {
    const scope: KnowledgeStorageScope = KnowledgeStorageScope.isolated(run); scope.requireTestOwner(run);
    const config: relationalStore.StoreConfig = { name: scope.vectorDatabaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: true };
    await relationalStore.deleteRdbStore(context,config); count++;
  }
  for (const run of ['000001a145b4ce5b','000001a145b73907','000001a145b97e38','000001a145bd1b31','000001a145bf41a2']) {
    const scope: KnowledgeStorageScope = KnowledgeStorageScope.isolated(run); scope.requireTestOwner(run);
    const ordinary: relationalStore.StoreConfig = { name: scope.databaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: false };
    const vector: relationalStore.StoreConfig = { name: scope.vectorDatabaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: true };
    await relationalStore.deleteRdbStore(context,ordinary); await relationalStore.deleteRdbStore(context,vector); count++;
  } return count;
}
