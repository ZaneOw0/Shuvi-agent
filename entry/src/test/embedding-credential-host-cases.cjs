'use strict';
const Module=require('node:module');
const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
module.exports=(outputRoot,asset)=>{
  const file=path.join(outputRoot,'entry/src/main/ets/knowledge/infra/EmbeddingCredentialStore.js');
  const loaded=new Module(file,module);loaded.filename=file;loaded.paths=Module._nodeModulePaths(path.dirname(file));
  const actual=loaded.require.bind(loaded),noPlatform=()=>{throw Error('SDK operation forbidden');};
  loaded.require=id=>id==='@kit.AssetStoreKit'?{asset:{...asset,query:noPlatform,add:noPlatform,update:noPlatform,remove:noPlatform}}:id==='@kit.ArkTS'?{util:{TextEncoder:class {encodeInto(text){return new TextEncoder().encode(text);}},TextDecoder:class {static create(encoding,options){return {decodeToString:bytes=>new TextDecoder(encoding,options).decode(bytes)};}}}}:id==='@kit.RemoteCommunicationKit'||id==='@kit.BasicServicesKit'?{}:actual(id);
  loaded._compile(fs.readFileSync(file,'utf8'),file);
  const {EmbeddingCredentialStore}=loaded.exports;
  const {EmbeddingConfig,EmbeddingProvider,EmbeddingRegion}=require(path.join(outputRoot,'entry/src/main/ets/knowledge/domain/EmbeddingModels.js'));
  class Asset {
    constructor(){this.rows=new Map();this.calls=[];this.fail=0;}
    alias(map){return new TextDecoder().decode(map.get(asset.Tag.ALIAS));}
    async query(map){this.calls.push(['query',new Map(map)]);if(this.fail)throw {code:this.fail,message:'unit-nonsecret-injected-detail'};const row=this.rows.get(this.alias(map));if(!row)throw {code:24000002};const copy=new Map(row);if(map.get(asset.Tag.RETURN_TYPE)===asset.ReturnType.ATTRIBUTES)copy.delete(asset.Tag.SECRET);else copy.set(asset.Tag.SECRET,row.get(asset.Tag.SECRET).slice());return [copy];}
    async add(map){this.calls.push(['add',new Map(map)]);if(this.rows.has(this.alias(map)))throw {code:24000003};const copy=new Map(map);copy.set(asset.Tag.SECRET,map.get(asset.Tag.SECRET).slice());this.rows.set(this.alias(map),copy);}
    async update(query,map){this.calls.push(['update',new Map(map)]);const row=this.rows.get(this.alias(query));if(!row)throw {code:24000002};row.set(asset.Tag.SECRET,map.get(asset.Tag.SECRET).slice());}
    async remove(map){this.rows.delete(this.alias(map));}
  }
  return [
    {name:'independent secure aliases attributes and zeroed transient bytes',run:async()=>{
      const port=new Asset(),store=new EmbeddingCredentialStore(port),a=new EmbeddingConfig(),b=new EmbeddingConfig();b.provider=EmbeddingProvider.Bailian;b.region=EmbeddingRegion.Beijing;
      await store.save(a,'unit-nonsecret-a',false);await store.save(b,'unit-nonsecret-b',false);assert.equal(port.rows.size,2);
      const adds=port.calls.filter(c=>c[0]==='add');for(const call of adds){assert.equal(call[1].get(asset.Tag.ACCESSIBILITY),asset.Accessibility.DEVICE_UNLOCKED);assert.equal(call[1].get(asset.Tag.SYNC_TYPE),asset.SyncType.NEVER);assert.equal(call[1].has(asset.Tag.IS_PERSISTENT),false);assert(call[1].get(asset.Tag.SECRET).every(b=>b===0));}
      await store.status(a);assert.equal(port.calls.at(-1)[1].get(asset.Tag.RETURN_TYPE),asset.ReturnType.ATTRIBUTES);
      await store.remove(a);assert.equal(await store.status(a),'Missing');assert.equal(await store.status(b),'Configured');
    }},
    {name:'locked secure storage unavailable no plaintext fallback or raw details',run:async()=>{
      const port=new Asset(),store=new EmbeddingCredentialStore(port),config=new EmbeddingConfig();port.fail=24000005;
      assert.equal(await store.status(config),'Unavailable');await assert.rejects(()=>store.save(config,'unit-nonsecret',false),error=>error.message.includes('24000005')&&!error.message.includes('unit-nonsecret-injected-detail'));
    }}
  ];
};
