import { relationalStore } from '@kit.ArkData';
import { ParsedFailure, PARSED_STORE_LAYOUT } from '../domain/ParsedDocumentModels';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { parsedUtf8 } from '../pipeline/ParsedDocumentCodec';

export const PARSED_STORE_DDL: string[] = [
  'CREATE TABLE upd_meta (id TEXT PRIMARY KEY,value TEXT NOT NULL)',
  'CREATE TABLE upd_document (id TEXT PRIMARY KEY,namespace TEXT NOT NULL,legacy_id TEXT NOT NULL,title TEXT NOT NULL,epoch INTEGER NOT NULL CHECK(epoch>=0),active TEXT NOT NULL,source_hash TEXT NOT NULL,archived INTEGER NOT NULL CHECK(archived IN (0,1)),tombstone INTEGER NOT NULL CHECK(tombstone IN (0,1)),UNIQUE(namespace,legacy_id))',
  'CREATE TABLE upd_generation (id TEXT PRIMARY KEY,doc TEXT NOT NULL,epoch INTEGER NOT NULL,manifest TEXT NOT NULL,content_hash TEXT NOT NULL,source_hash TEXT NOT NULL,expected INTEGER NOT NULL CHECK(expected>=0),state TEXT NOT NULL CHECK(state IN (\'Staging\',\'Active\',\'Retained\',\'Removed\')))',
  'CREATE TABLE upd_chunk (id TEXT PRIMARY KEY,doc TEXT NOT NULL,generation TEXT NOT NULL,ordinal INTEGER NOT NULL,text TEXT NOT NULL,input_hash TEXT NOT NULL,block TEXT NOT NULL,occurrence TEXT NOT NULL,evidence TEXT NOT NULL,start INTEGER NOT NULL,end INTEGER NOT NULL,UNIQUE(generation,ordinal))',
  'CREATE TABLE upd_index_binding (namespace TEXT NOT NULL,owner TEXT NOT NULL,version TEXT NOT NULL,epoch INTEGER NOT NULL,space TEXT NOT NULL,expected INTEGER NOT NULL,input_hash TEXT NOT NULL,vector_generation TEXT NOT NULL,readback_hash TEXT NOT NULL,state TEXT NOT NULL CHECK(state IN (\'Pending\',\'Synced\',\'Partial\',\'Invalid\')),PRIMARY KEY(namespace,owner))',
  'CREATE TABLE upd_asset (id TEXT PRIMARY KEY,owner TEXT NOT NULL,path TEXT UNIQUE NOT NULL,hash TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>=0),state TEXT NOT NULL CHECK(state IN (\'Reserved\',\'Ready\',\'Missing\',\'Unsupported\',\'Removed\')),metadata TEXT NOT NULL)',
  'CREATE TABLE upd_image_occurrence (id TEXT PRIMARY KEY,doc TEXT NOT NULL,generation TEXT NOT NULL,asset TEXT NOT NULL,lineage TEXT NOT NULL,effective TEXT NOT NULL,metadata TEXT NOT NULL)',
  'CREATE TABLE upd_asset_ref (holder TEXT NOT NULL,doc TEXT NOT NULL,generation TEXT NOT NULL,asset TEXT NOT NULL,owner TEXT NOT NULL,role TEXT NOT NULL,PRIMARY KEY(holder,owner,asset))',
  'CREATE TABLE upd_asset_write (id TEXT PRIMARY KEY,doc TEXT NOT NULL,generation TEXT NOT NULL,role TEXT NOT NULL,hash TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>0),path TEXT NOT NULL,phase TEXT NOT NULL CHECK(phase IN (\'Reserved\',\'Materialized\',\'Renamed\',\'Ready\',\'Missing\',\'Removed\')),reserved INTEGER NOT NULL CHECK(reserved>=0),failure TEXT NOT NULL)',
  'CREATE TABLE upd_read_lease (id TEXT PRIMARY KEY,asset TEXT NOT NULL,owner TEXT NOT NULL,session TEXT NOT NULL,holder TEXT NOT NULL)',
  'CREATE TABLE upd_cleanup (asset TEXT PRIMARY KEY,owner TEXT NOT NULL,state TEXT NOT NULL CHECK(state IN (\'Claimed\',\'Pending\',\'Done\')),failure TEXT NOT NULL)',
  'CREATE TABLE upd_annotation (id TEXT PRIMARY KEY,lineage TEXT NOT NULL,revision INTEGER NOT NULL,image_hash TEXT NOT NULL,text_hash TEXT NOT NULL,metadata TEXT NOT NULL,UNIQUE(lineage,revision))',
  'CREATE TABLE upd_tag (annotation TEXT NOT NULL,ordinal INTEGER NOT NULL,text TEXT NOT NULL,PRIMARY KEY(annotation,ordinal),UNIQUE(annotation,text))',
  'CREATE TABLE upd_settings (purpose TEXT PRIMARY KEY,revision INTEGER NOT NULL,metadata TEXT NOT NULL)',
  'CREATE TABLE upd_grant (id TEXT PRIMARY KEY,purpose TEXT NOT NULL,revision INTEGER NOT NULL,revoked INTEGER NOT NULL CHECK(revoked IN (0,1)),consumed INTEGER NOT NULL CHECK(consumed IN (0,1)),metadata TEXT NOT NULL)',
  'CREATE TABLE upd_batch (id TEXT PRIMARY KEY,origin TEXT NOT NULL CHECK(origin IN (\'Import\',\'LocalMigration\',\'ExplicitUpgrade\')),input_hash TEXT NOT NULL,metadata TEXT NOT NULL)',
  'CREATE TABLE upd_job (id TEXT PRIMARY KEY,dedup_key TEXT UNIQUE NOT NULL,doc TEXT NOT NULL,origin TEXT NOT NULL CHECK(origin IN (\'Import\',\'LocalMigration\',\'ExplicitUpgrade\')),batch TEXT NOT NULL,state TEXT NOT NULL,metadata TEXT NOT NULL)',
  'CREATE TABLE upd_attempt (id TEXT PRIMARY KEY,job TEXT NOT NULL,input_hash TEXT NOT NULL,outcome TEXT NOT NULL,metadata TEXT NOT NULL)',
  'CREATE TABLE upd_legacy_link (namespace TEXT NOT NULL,legacy_id TEXT NOT NULL,legacy_generation TEXT NOT NULL,legacy_wire TEXT NOT NULL,legacy_hash TEXT NOT NULL,doc TEXT NOT NULL,generation TEXT NOT NULL,epoch INTEGER NOT NULL,old_active TEXT NOT NULL,state TEXT NOT NULL,PRIMARY KEY(namespace,legacy_id,legacy_generation))',
  'CREATE TABLE upd_history (record TEXT NOT NULL,event TEXT NOT NULL,revision INTEGER NOT NULL,wire TEXT NOT NULL,asset TEXT NOT NULL,hash TEXT NOT NULL,created INTEGER NOT NULL,PRIMARY KEY(record,event),UNIQUE(record,revision))'
];
export function parsedStoreTableNames(): string[] { return PARSED_STORE_DDL.map((sql: string): string => sql.slice(13,sql.indexOf(' ('))); }
export async function parsedOpenLayout(tx: relationalStore.Transaction, identity: ParsedIdentityPort): Promise<void> {
  const names: string[] = parsedStoreTableNames(); const ddlHash: string = await identity.hash(parsedUtf8(PARSED_STORE_DDL.join('\n')));
  const rows: relationalStore.ResultSet = await tx.querySql("SELECT name,sql FROM sqlite_master WHERE type='table' AND name GLOB 'upd_*'"); let count: number = 0;
  try {
    while (rows.goToNextRow()) {
      const at: number = names.indexOf(rows.getString(0));
      if (at < 0 || rows.getString(1) !== PARSED_STORE_DDL[at]) { throw new ParsedFailure('LayoutMismatch','upd-open'); } count++;
    }
  } finally { rows.close(); }
  if (count === 0) {
    for (const ddl of PARSED_STORE_DDL) { await tx.execute(ddl); }
    await tx.execute('INSERT INTO upd_meta VALUES(?,?)',['layout',PARSED_STORE_LAYOUT]);
    await tx.execute('INSERT INTO upd_meta VALUES(?,?)',['ddl_hash',ddlHash]);
    await tx.execute('INSERT INTO upd_meta VALUES(?,?)',['state','Committed']); return;
  }
  if (count !== names.length) { throw new ParsedFailure('LayoutIncomplete','upd-open'); }
  const meta: relationalStore.ResultSet = await tx.querySql('SELECT id,value FROM upd_meta'); let seen: number = 0;
  try { while (meta.goToNextRow()) {
    const id: string = meta.getString(0); const expected: string = id === 'layout' ? PARSED_STORE_LAYOUT : id === 'ddl_hash' ? ddlHash : id === 'state' ? 'Committed' : '';
    if (expected.length === 0 || meta.getString(1) !== expected) { throw new ParsedFailure('LayoutUncommitted','upd-open'); } seen++;
  } } finally { meta.close(); }
  if (seen !== 3) { throw new ParsedFailure('LayoutMetadataIncomplete','upd-open'); }
}
