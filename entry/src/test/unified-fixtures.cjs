'use strict';
const crypto = require('node:crypto');
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
// Self-authored tiny raster. No user originals or downloaded assets.
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jV1kAAAAASUVORK5CYII=', 'base64');
// Self-authored baseline 1x1 grayscale JPEG: DC=0, AC=EOB. Legal APP padding
// makes the complete file span several legacy 64 KiB parts, without transcoding.
const segment = (marker, payload) => Buffer.concat([Buffer.from([255,marker,(payload.length+2)>>8,(payload.length+2)&255]),payload]);
const huffmanCounts = Buffer.from([1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]);
const jpegPayload = Buffer.concat([Buffer.from([255,216]),
  segment(0xe1,Buffer.alloc(65530,17)),segment(0xe2,Buffer.alloc(65530,18)),
  segment(0xdb,Buffer.concat([Buffer.from([0]),Buffer.alloc(64,1)])),
  segment(0xc0,Buffer.from([8,0,1,0,1,1,1,17,0])),
  segment(0xc4,Buffer.concat([Buffer.from([0]),huffmanCounts,Buffer.from([0,16]),huffmanCounts,Buffer.from([0])])),
  segment(0xda,Buffer.from([1,1,0,0,63,0])),Buffer.from([0x3f,255,217])]);
const pdfParts = [];
for (let at = 0; at < jpegPayload.length; at += 65536) pdfParts.push(jpegPayload.subarray(at, at + 65536));
const legacyWire = 'RESULT3|synthetic-only|source=Image2|hash=unchanged|free=false|space=PDF-OLD-1';
exports.gold = Object.freeze({ version: 'UPD-SYNTHETIC-1', formats: ['Text','Pdf','Image','Docx'],
  mixedOrder: ['text-repeat','image-only','formula-only','unknown-only','table-cell','text-repeat-2'],
  formula: 'x^2', sourcePrecision: 'Block', secondPageDirectImage: 17, pageSize: 10, cards: 23,
  legacyHash: hash(legacyWire), pngHash: hash(png), pdfPayloadHash: hash(jpegPayload),
  pdfContainerHash: hash(JSON.stringify(pdfParts.map(p => ({ hash: hash(p), bytes: p.length })))) });
exports.png = () => Buffer.from(png);
exports.pdf = () => ({ payload: Buffer.from(jpegPayload), parts: pdfParts.map(p => Buffer.from(p)) });
exports.legacyWire = legacyWire;
exports.annotation = () => ({ auto: { description: '合成无字图', tags: ['图形','无字'] },
  overlay: { lineage: 'user-parent-a', revision: 2, removedTags: ['无字'] }, parents: ['parent-a','parent-b'] });
exports.parsedOutputs = M => exports.gold.formats.map((format,index) => {
  const d=new M.ParsedDocument();d.documentKey='fixture-'+index;d.generation='generation-'+index;d.source_hash=hash('synthetic-'+format);
  d.parser_signature='SYNTHETIC-PRODUCER-'+format+'-1';d.engine='synthetic-only';d.title=format;d.format=format;
  d.markdown=format==='Image'?'':'重复文字\n\n重复文字';
  if(format==='Text')return d;
  d.blocks=[];
  for(const [order,id]of exports.gold.mixedOrder.entries()){
    if(format!=='Docx'&&order>1)break;
    const b=new M.ParsedBlock();b.id=id;b.order=order;
    if(id==='image-only'){
      b.kind=M.ParsedKind.Image;b.imageOccurrenceId='occurrence';
      const a=new M.ParsedImageAsset();a.id='asset';a.payloadHash=exports.gold.pngHash;a.bytes=png.length;a.mime='image/png';a.pixelWidth=1;a.pixelHeight=1;a.frames=1;a.state=M.ParsedAssetState.Missing;a.limitation='FixtureNotMaterialized';d.images.push(a);
      const o=new M.ParsedImageOccurrence();o.id='occurrence';o.documentKey=d.documentKey;o.generation=d.generation;o.blockId=b.id;o.order=order;o.assetId=a.id;
      o.provenance=format==='Image'?M.ParsedProvenance.Original:format==='Pdf'?M.ParsedProvenance.Derived:M.ParsedProvenance.Native;o.limitation='FixtureNotMaterialized';d.occurrences.push(o);
    }else if(id==='formula-only'){b.kind=M.ParsedKind.Formula;b.formula.latex='x^2';}
    else if(id==='unknown-only'){b.kind=M.ParsedKind.Unknown;b.limitation='UnsupportedSyntheticObject';}
    else if(id==='table-cell'){b.kind=M.ParsedKind.Cell;b.row=0;b.column=0;b.text='cell';}
    else b.text=format==='Image'?'':'重复文字';
    d.blocks.push(b);
  }
  return d;
});
