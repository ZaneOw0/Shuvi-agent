// Host-only scoped loader. SDK enum declarations are real; SDK operations never run here.
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const { TextEncoder, TextDecoder } = require('node:util');

module.exports = function loadMineruCases(outputRoot, sdkHome, ts) {
  const declaration = fs.readFileSync(path.join(sdkHome, 'default/openharmony/ets/api/@ohos.security.asset.d.ts'), 'utf8');
  const sdkSource = ts.createSourceFile('asset.ts', declaration, ts.ScriptTarget.Latest, true);
  const namespace = sdkSource.statements.find(node => ts.isModuleDeclaration(node) && node.name.text === 'asset');
  const names = ['TagType', 'Tag', 'Accessibility', 'SyncType', 'ReturnType', 'ConflictResolution'];
  const enums = namespace.body.statements.filter(node => ts.isEnumDeclaration(node) && names.includes(node.name.text));
  if (enums.length !== names.length) throw new Error('SDK enum declarations missing');
  const enumSource = `namespace asset { ${enums.map(node => 'export ' + node.getText(sdkSource)).join('\n')} }\nexport { asset };`;
  const enumModule = new Module(path.join(outputRoot, 'host-asset-enums.js'));
  enumModule.filename = enumModule.id;
  enumModule._compile(ts.transpileModule(enumSource, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, enumModule.filename);
  class MineruHostEncoder { encodeInto(text) { return new TextEncoder().encode(text); } }
  class MineruHostDecoder { static create(encoding, options) { return { decodeToString: bytes => new TextDecoder(encoding, options).decode(bytes) }; } }
  const unexpected = () => { throw new Error('Platform operation forbidden in host test'); };
  const kits = {
    '@kit.AssetStoreKit': { asset: { ...enumModule.exports.asset, query: unexpected, add: unexpected, update: unexpected, remove: unexpected } },
    '@kit.ArkTS': { util: { TextEncoder: MineruHostEncoder, TextDecoder: MineruHostDecoder } },
    '@kit.CoreFileKit': { fileIo: {
      access: async target => target.endsWith('/knowledge_parse_v1'),
      lstat: async () => ({ isDirectory: () => true, isSymbolicLink: () => false })
    } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: {
      createRandom: () => ({ generateRandom: async count => ({ data: new Uint8Array(count).fill(7) }) })
    } },
    '@kit.RemoteCommunicationKit': {},
    '@kit.BasicServicesKit': {}
  };
  function load(relative) {
    const filename = path.join(outputRoot, relative);
    const loaded = new Module(filename, module); loaded.filename = filename; loaded.paths = Module._nodeModulePaths(path.dirname(filename));
    const baseRequire = loaded.require.bind(loaded);
    loaded.require = function (id) { return Object.hasOwn(kits, id) ? kits[id] : baseRequire(id); };
    require.cache[filename] = loaded;
    loaded._compile(fs.readFileSync(filename, 'utf8'), filename); loaded.loaded = true; return loaded.exports;
  }
  load('entry/src/main/ets/knowledge/infra/MineruCredentialStore.js');
  const tests = load('entry/src/test/MineruCredentialStoreCases.js');
  tests.hostAssetEnums = enumModule.exports.asset; return tests;
};
