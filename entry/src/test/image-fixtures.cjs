'use strict';
// Self-authored structure fixtures; JPEG/WebP are not complete pixel decodes.
const zlib = require('node:zlib');
function crc(bytes) { let n=0xffffffff; for(const b of bytes){n^=b;for(let i=0;i<8;i++)n=(n>>>1)^((n&1)?0xedb88320:0);}return (n^0xffffffff)>>>0; }
function pngChunk(name,bytes) { const tag=Buffer.from(name), len=Buffer.alloc(4), sum=Buffer.alloc(4);len.writeUInt32BE(bytes.length);sum.writeUInt32BE(crc(Buffer.concat([tag,bytes])));return Buffer.concat([len,tag,bytes,sum]); }
function png(width=3,height=2,animated=false) { const ihdr=Buffer.alloc(13);ihdr.writeUInt32BE(width);ihdr.writeUInt32BE(height,4);ihdr[8]=8;ihdr[9]=6;const chunks=[pngChunk('IHDR',ihdr)];if(animated){const a=Buffer.alloc(8);a.writeUInt32BE(1);chunks.push(pngChunk('acTL',a));}if(width*height<1000){const raw=Buffer.alloc(height*(1+width*4));for(let y=0;y<height;y++)for(let x=0;x<width;x++){const at=y*(1+width*4)+1+x*4;raw[at]=x*80;raw[at+1]=y*120;raw[at+2]=20;raw[at+3]=x===0?0:255;}chunks.push(pngChunk('IDAT',zlib.deflateSync(raw)));}else chunks.push(pngChunk('IDAT',Buffer.from([0])));chunks.push(pngChunk('IEND',Buffer.alloc(0)));return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),...chunks]); }
function riffChunk(name,data){const len=Buffer.alloc(4);len.writeUInt32LE(data.length);return Buffer.concat([Buffer.from(name),len,data,data.length%2?Buffer.alloc(1):Buffer.alloc(0)]);}
function webp(variant='VP8L',animated=false){let body;if(variant==='VP8L')body=riffChunk('VP8L',Buffer.from([47,2,64,0,16,0]));else body=riffChunk('VP8 ',Buffer.from([16,0,0,157,1,42,3,0,2,0]));if(animated){const x=Buffer.alloc(10);x[0]=2;x[4]=2;x[7]=1;body=Buffer.concat([riffChunk('VP8X',x),riffChunk('ANIM',Buffer.alloc(6)),body]);}const len=Buffer.alloc(4);len.writeUInt32LE(body.length+4);return Buffer.concat([Buffer.from('RIFF'),len,Buffer.from('WEBP'),body]);}
function jpeg(width=3,height=2,orientation=1){const exif=Buffer.from([69,120,105,102,0,0,73,73,42,0,8,0,0,0,1,0,18,1,3,0,1,0,0,0,orientation,0,0,0,0,0,0,0]);const len=Buffer.alloc(2);len.writeUInt16BE(exif.length+2);const sof=Buffer.from([255,192,0,11,8,height>>8,height&255,width>>8,width&255,1,1,17,0]);return Buffer.concat([Buffer.from([255,216,255,225]),len,exif,sof,Buffer.from([255,218,0,8,1,1,0,0,63,0,10,255,217])]);}
function solidWebp(red=32,green=96,blue=160,alpha=255){
  const bits=[];const put=(n,count)=>{for(let i=0;i<count;i++)bits.push((n>>>i)&1);};
  put(2,14);put(1,14);put(alpha!==255?1:0,1);put(0,3);
  put(0,1);put(0,1);put(0,1);
  for(const symbol of [green,red,blue,alpha,0]){put(1,1);put(0,1);put(1,1);put(symbol,8);}
  const payload=Buffer.alloc(1+Math.ceil(bits.length/8));payload[0]=47;bits.forEach((bit,i)=>{payload[1+(i>>3)]|=bit<<(i&7);});
  const body=riffChunk('VP8L',payload),len=Buffer.alloc(4);len.writeUInt32LE(body.length+4);return Buffer.concat([Buffer.from('RIFF'),len,Buffer.from('WEBP'),body]);
}
const orientationGold=[
  [1,0,0,1,0,0],[-1,0,0,1,3,0],[-1,0,0,-1,3,2],[1,0,0,-1,0,2],
  [0,1,1,0,0,0],[0,1,-1,0,2,0],[0,-1,-1,0,2,3],[0,-1,1,0,0,3]
];
module.exports={png,jpeg,webp,solidWebp,orientationGold,crc};
