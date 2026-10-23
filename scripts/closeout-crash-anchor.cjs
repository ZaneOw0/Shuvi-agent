'use strict';
const cp=require('node:child_process');
const r=cp.spawnSync('devecocli',['log','--crash','--device','127.0.0.1:5555','--bundle-name','com.example.shuvi'],{encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024});
let count=0;
for(const line of (r.stdout||'').split('\n')){
 const frame=line.match(/(?:entry\/src\/main\/ets\/|[A-Za-z]+\()([^\s()]*\.ets:\d+:?\d*)/);if(frame){console.log('R2_CRASH_FRAME '+frame[1].replace(/[^A-Za-z0-9_/.:-]/g,''));count++;}
 const type=line.match(/(?:Error name|Reason):\s*((?:Type|Reference|Range|Business)?Error)/);if(type){console.log('R2_CRASH_TYPE '+type[1]);count++;}
 const message=line.match(/Error message: (?:@\w+\s+)?(?:Cannot read property|Cannot read properties|is not callable|UI execution context not found|Stack overflow|ForEach)[A-Za-z0-9_ .:'()\[\]-]{0,150}/);if(message){console.log('R2_CRASH_ANCHOR '+message[0]);count++;}
}
console.log(`R2_CRASH_CAPTURE rc=${r.status??1} anchors=${count}`);
process.exitCode=r.status||0;
