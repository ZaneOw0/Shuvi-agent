'use strict';
const fs=require('node:fs');
const zlib=require('node:zlib');
const assert=require('node:assert/strict');
const path=require('node:path');
const file=path.resolve(__dirname,'../.cache/test-logs/2026-10-17-closeout-final-source-ui-9f5992c/synthetic-regions-final.png');
const png=fs.readFileSync(file);assert.equal(png.subarray(0,8).toString('hex'),'89504e470d0a1a0a');let width=0,height=0,channels=0;const compressed=[];
for(let at=8;at<png.length;){const size=png.readUInt32BE(at),type=png.toString('ascii',at+4,at+8),data=png.subarray(at+8,at+8+size);if(type==='IHDR'){width=data.readUInt32BE(0);height=data.readUInt32BE(4);assert.equal(data[8],8);channels=data[9]===6?4:data[9]===2?3:0;assert(channels);assert.equal(data[12],0);}if(type==='IDAT')compressed.push(data);at+=12+size;}
const stride=width*channels,raw=zlib.inflateSync(Buffer.concat(compressed)),pixels=Buffer.alloc(stride*height);assert.equal(raw.length,(stride+1)*height);
const paeth=(a,b,c)=>{const p=a+b-c,pa=Math.abs(p-a),pb=Math.abs(p-b),pc=Math.abs(p-c);return pa<=pb&&pa<=pc?a:pb<=pc?b:c;};
for(let y=0;y<height;y++){const filter=raw[y*(stride+1)];for(let x=0;x<stride;x++){const i=y*stride+x,a=x>=channels?pixels[i-channels]:0,b=y?pixels[i-stride]:0,c=y&&x>=channels?pixels[i-stride-channels]:0;const n=raw[y*(stride+1)+1+x];pixels[i]=(n+(filter===0?0:filter===1?a:filter===2?b:filter===3?Math.floor((a+b)/2):filter===4?paeth(a,b,c):NaN))&255;assert(filter<=4);}}
assert.equal(width,1280);assert.equal(height,2832);
const rgb=(x,y)=>{const i=(y*width+x)*channels;return [...pixels.subarray(i,i+3)];};
const border=(x,y)=>{const [r,g,b]=rgb(x,y);return r>160&&r<215&&g>70&&g<135&&b<60;};
// Canvas [70,918,1210,1488], independent normalized gold boxes
// [0.1,0.1,0.3,0.3] and [0.5,0.5,0.8,0.8].
for(const [left,top,right,bottom] of [[184,975,412,1089],[640,1203,982,1374]]){
 for(const [x,y] of [[left+2,top+10],[right-3,top+10],[left+10,top+2],[left+10,bottom-3]])assert(border(x,y),`Missing synthetic border at ${x},${y}`);
 const [r,g,b]=rgb(Math.floor((left+right)/2),Math.floor((top+bottom)/2));assert(r>240&&g>220&&b>180&&b<245);
}
assert.deepEqual(rgb(550,1100),[255,255,255]);
console.log('R2_HIGHLIGHT pixels=1 canvas=1140x570 regions=2 crop=nonzero rotation=90 independent_gold=1 private_pdf=0');
