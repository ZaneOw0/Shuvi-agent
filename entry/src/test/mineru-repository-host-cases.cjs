// Exercises production migration/row codec with SQLite in memory, not ArkData or a user database.
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');

module.exports = function repositoryHostCases(outputRoot) {
  const models = require(path.join(outputRoot, 'entry/src/main/ets/knowledge/domain/DocumentParseModels.js'));
  let active;
  class HostRows {
    constructor(statement, rows) { this.columns = statement.columns().map(c => c.name); this.rows = rows; this.at = -1; }
    goToNextRow() { return ++this.at < this.rows.length; }
    getColumnIndex(name) { const i = this.columns.indexOf(name); if (i < 0) throw new Error('Missing column'); return i; }
    getString(i) { return String(this.rows[this.at][this.columns[i]]); }
    getLong(i) { return Number(this.rows[this.at][this.columns[i]]); }
    close() {}
  }
  function session() {
    const db = new DatabaseSync(':memory:'); let version = 1; let failMigration = false;
    const store = {
      get version() { return version; }, set version(n) { version = n; },
      querySql: async (sql, args = []) => { const q = db.prepare(sql); return new HostRows(q, q.all(...args)); },
      createTransaction: async () => {
        db.exec('BEGIN'); return { execute: async (sql, args = []) => {
          if (failMigration && sql.startsWith('UPDATE parse_meta SET layout')) throw new Error('host migration failure');
          db.prepare(sql).run(...args);
        }, commit: async () => { db.exec('COMMIT'); }, rollback: async () => { db.exec('ROLLBACK'); } };
      }, close: async () => {}
    };
    active = store; return { db, store, fail: () => { failMigration = true; } };
  }
  const filename = path.join(outputRoot, 'entry/src/main/ets/knowledge/infra/DocumentParseRepository.js');
  const loaded = new Module(filename, module); loaded.filename = filename; loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  const original = loaded.require.bind(loaded);
  const kits = { '@kit.AbilityKit': {}, '@kit.ArkData': { relationalStore: { SecurityLevel: { S3: 3 }, getRdbStore: async () => active } },
    '@kit.CoreFileKit': { fileIo: { access: async () => true, lstat: async () => ({ isFile: () => true, isSymbolicLink: () => false }) } } };
  loaded.require = id => Object.hasOwn(kits, id) ? kits[id] : original(id);
  loaded._compile(fs.readFileSync(filename, 'utf8') + '\nexports.hostBaselineDDL = DOCUMENT_PARSE_DDL; exports.hostLayout = DOCUMENT_PARSE_LAYOUT;', filename);
  const { DocumentParseRepository, hostBaselineDDL, hostLayout } = loaded.exports;
  function seed(s) {
    for (const ddl of hostBaselineDDL) s.db.exec(ddl);
    s.db.prepare('INSERT INTO parse_meta VALUES(1,?,1,1)').run(hostLayout);
    s.db.prepare('INSERT INTO original VALUES(?,?,?,?,?,?,?,?,?,?,?)').run('unit-original','original-unit','unit-only.pdf','a'.repeat(64),100,'PDF',1,'身份预检通过',1,'',1);
    s.db.prepare('INSERT INTO grant VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)').run('unit-grant','unit-original','a'.repeat(64),1,'PDF',1,models.DocumentParseBudget.policy,models.DocumentParseBudget.parameters,1,1,1,1,1,1,0);
    s.db.prepare('INSERT INTO task VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)').run('unit-task','unit-original','unit-task','unit-batch','unit-grant','a'.repeat(64),1,1,'本机暂停','等待文件','waiting-file',1,7,1,0,1,'lease-unit-upload','','',0,0);
    s.db.prepare('INSERT INTO remote_slot VALUES(1,?,?,?,?,?,?)').run('unit-task','unit-task','unit-batch',1,'waiting-file',0);
    return new DocumentParseRepository({ databaseDir: '/host/database' });
  }
  return [
    { name: 'v1 additive migration preserves every old row and unknown upload history', run: async () => {
      const s = session(); const repo = seed(s); const before = JSON.stringify(s.db.prepare('SELECT * FROM task').all());
      await repo.open(); const snapshot = await repo.load();
      assert.equal(JSON.stringify(s.db.prepare('SELECT * FROM task').all()), before); assert.equal(snapshot.tasks[0].uploadAttempted, true);
      assert.equal(snapshot.tasks[0].uploadRequestStarted, false); assert.equal(snapshot.tasks[0].recoveryUploadUsed, false);
      snapshot.tasks[0].recoveryUploadUsed = true; snapshot.tasks[0].queries = 137; snapshot.tasks[0].uploadBytes = 99; snapshot.tasks[0].lastQueryAt = 15;
      snapshot.tasks[0].failureStage = '原件PUT'; snapshot.tasks[0].failureCode = '403'; await repo.save(snapshot); await repo.close();
      const reopened = new DocumentParseRepository({ databaseDir: '/host/database' }); await reopened.open(); const result = await reopened.load();
      assert.equal(result.tasks[0].recoveryUploadUsed, true); assert.equal(result.tasks[0].queries, 137); assert.equal(result.tasks[0].failureCode, '403'); assert.equal(result.tasks[0].lastQueryAt, 15);
      assert.equal(result.originals[0].hash, 'a'.repeat(64)); assert.equal(result.occupancy.batchId, 'unit-batch'); assert.equal(s.store.version, 2); s.db.close();
    } },
    { name: 'migration interruption rolls back and old task batch lease remain usable on reopen', run: async () => {
      const s = session(); const repo = seed(s); s.fail(); await assert.rejects(repo.open(), /迁移/);
      assert.equal(s.db.prepare('SELECT upload_attempted FROM task').get().upload_attempted, 1);
      assert.equal(s.db.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name='task_transfer'").get().n, 0);
      assert.equal(s.store.version, 1); assert.equal(s.db.prepare('SELECT layout FROM parse_meta').get().layout, hostLayout); s.db.close();
    } },
    { name: 'unknown existing layout rejected without blank database fallback', run: async () => {
      const s = session(); const repo = seed(s); s.db.exec('CREATE TABLE unexpected (id INTEGER)'); await assert.rejects(repo.open(), /布局未知/);
      assert.equal(s.db.prepare('SELECT count(*) AS n FROM task').get().n, 1); s.db.close();
    } }
  ];
};
