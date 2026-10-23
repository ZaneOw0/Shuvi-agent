'use strict';
// Self-authored, frozen before reader implementation. No user/private fixture access.
const zlib = require('node:zlib');
const crypto = require('node:crypto');
const W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const P = 'http://schemas.openxmlformats.org/package/2006/relationships';
const C = 'http://schemas.openxmlformats.org/package/2006/content-types';
const gold = Object.freeze({
  version: 'docx-m4-gold-1',
  basic: { text: ['结构测试', '列表一', 'Alpha\tBeta\n尾段', '重复段', '重复段'], outline: 0, numId: '7', level: 0 },
  tableMedia: { rows: 2, columns: 3, anchor: [0,0], rowSpan: 2, columnSpan: 2, texts: ['合并值','值A','值B'], media: 'word/media/self.png', captionEvidence: 'Unknown' },
  revisions: { visible: ['新增','移入','恢复可见','当前可见'], absent: ['删除','移出','默认隐藏','样式隐藏','直接隐藏','框内文字','脚注正文','页眉正文','批注正文'], limitations: ['TextBox','FootnoteReference','NestedTable'] }
});
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) { crc ^= byte; for (let i=0;i<8;i++) crc = (crc>>>1)^((crc&1)?0xedb88320:0); }
  return (crc^0xffffffff)>>>0;
}
function zip(parts, options={}) {
  const locals=[], centrals=[]; let offset=0;
  for (const [name, body] of parts) {
    const data=Buffer.isBuffer(body)?body:Buffer.from(body); const filename=Buffer.from(name);
    const compressed=options.stored?data:zlib.deflateRawSync(data); const method=options.stored?0:8;
    const flags=0x800|(options.descriptor?8:0)|(method===8?2:0); const crc=crc32(data);
    const extra=options.metadata?Buffer.from([0x55,0x54,1,0,0]):Buffer.alloc(0);
    const local=Buffer.alloc(30); local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20,4); local.writeUInt16LE(flags,6); local.writeUInt16LE(method,8);
    if(!options.descriptor){local.writeUInt32LE(crc,14);local.writeUInt32LE(compressed.length,18);local.writeUInt32LE(data.length,22);}
    local.writeUInt16LE(filename.length,26);local.writeUInt16LE(extra.length,28);
    let descriptor=Buffer.alloc(0);
    if(options.descriptor){descriptor=Buffer.alloc(options.signature===false?12:16);let at=0;if(options.signature!==false){descriptor.writeUInt32LE(0x08074b50);at=4;}descriptor.writeUInt32LE(crc,at);descriptor.writeUInt32LE(compressed.length,at+4);descriptor.writeUInt32LE(data.length,at+8);}
    const central=Buffer.alloc(46);central.writeUInt32LE(0x02014b50);central.writeUInt16LE(20,4);central.writeUInt16LE(20,6);central.writeUInt16LE(flags,8);central.writeUInt16LE(method,10);central.writeUInt32LE(crc,16);central.writeUInt32LE(compressed.length,20);central.writeUInt32LE(data.length,24);central.writeUInt16LE(filename.length,28);central.writeUInt16LE(extra.length,30);central.writeUInt32LE(offset,42);
    const packed=Buffer.concat([local,filename,extra,compressed,descriptor]);locals.push(packed);centrals.push(Buffer.concat([central,filename,extra]));offset+=packed.length;
  }
  const directory=Buffer.concat(centrals), comment=options.metadata?Buffer.from('self-authored'):Buffer.alloc(0), end=Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50);end.writeUInt16LE(parts.length,8);end.writeUInt16LE(parts.length,10);end.writeUInt32LE(directory.length,12);end.writeUInt32LE(offset,16);end.writeUInt16LE(comment.length,20);
  return Buffer.concat([...locals,directory,end,comment]);
}
const paragraph=text=>`<q:p><q:r><q:t>${text}</q:t></q:r></q:p>`;
function parts(kind) {
  const main='word/main.xml'; let body='', styles='', extra=[];
  if(kind==='basic') body=`<q:p><q:pPr><q:outlineLvl q:val="0"/></q:pPr><q:r><q:t>结构测试</q:t></q:r></q:p><q:p><q:pPr><q:numPr><q:ilvl q:val="0"/><q:numId q:val="7"/></q:numPr></q:pPr><q:r><q:t>列表一</q:t></q:r></q:p><q:p><q:r><q:t>Alpha</q:t><q:tab/></q:r><q:r><q:t>Beta</q:t><q:br/><q:t>尾段</q:t></q:r></q:p>${paragraph('重复段')}${paragraph('重复段')}`;
  else if(kind==='table-media') {
    body=`<q:tbl><q:tblGrid><q:gridCol/><q:gridCol/><q:gridCol/></q:tblGrid><q:tr><q:tc><q:tcPr><q:gridSpan q:val="2"/><q:vMerge q:val="restart"/></q:tcPr>${paragraph('合并值')}</q:tc><q:tc>${paragraph('值A')}</q:tc></q:tr><q:tr><q:tc><q:tcPr><q:gridSpan q:val="2"/><q:vMerge/></q:tcPr>${paragraph('')}</q:tc><q:tc>${paragraph('值B')}</q:tc></q:tr></q:tbl><q:p><q:r><q:drawing><a:blip xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" rel:embed="img1"/></q:drawing></q:r></q:p>`;
    extra.push(['word/media/self.png',Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5x8AAAAASUVORK5CYII=','base64')]);
  } else if(kind==='revisions') {
    styles='<q:docDefaults><q:rPrDefault><q:rPr><q:vanish/></q:rPr></q:rPrDefault></q:docDefaults><q:style q:type="character" q:styleId="Hide"><q:rPr><q:vanish/></q:rPr></q:style>';
    body=`<q:p><q:ins><q:r><q:rPr><q:vanish q:val="false"/></q:rPr><q:t>新增</q:t></q:r></q:ins><q:moveTo><q:r><q:rPr><q:vanish q:val="0"/></q:rPr><q:t>移入</q:t></q:r></q:moveTo><q:del><q:r><q:delText>删除</q:delText></q:r></q:del><q:moveFrom><q:r><q:t>移出</q:t></q:r></q:moveFrom><q:r><q:t>默认隐藏</q:t></q:r><q:r><q:rPr><q:rStyle q:val="Hide"/></q:rPr><q:t>样式隐藏</q:t></q:r><q:r><q:rPr><q:vanish/></q:rPr><q:t>直接隐藏</q:t></q:r><q:r><q:rPr><q:vanish q:val="0"/></q:rPr><q:t>恢复可见</q:t></q:r><q:r><q:rPr><q:vanish q:val="0"/><q:rPrChange><q:rPr><q:vanish/></q:rPr></q:rPrChange></q:rPr><q:t>当前可见</q:t></q:r><q:r><q:footnoteReference q:id="1"/><q:txbxContent>${paragraph('框内文字')}</q:txbxContent></q:r></q:p><q:tbl><q:tr><q:tc><q:tbl><q:tr><q:tc>${paragraph('嵌套正文')}</q:tc></q:tr></q:tbl></q:tc></q:tr></q:tbl>`;
    extra.push(['word/footnotes.xml',`<q:footnotes xmlns:q="${W}">${paragraph('脚注正文')}</q:footnotes>`],['word/header1.xml',`<q:hdr xmlns:q="${W}">${paragraph('页眉正文')}</q:hdr>`],['word/comments.xml',`<q:comments xmlns:q="${W}">${paragraph('批注正文')}</q:comments>`]);
  } else throw Error('Synthetic fixture kind not allowed');
  return [
    ['[Content_Types].xml',`<Types xmlns="${C}"><Override PartName="/${main}" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>`],
    ['_rels/.rels',`<Relationships xmlns="${P}"><Relationship Id="root" Type="${R}/officeDocument" Target="${main}"/></Relationships>`],
    [main,`<?xml version="1.0" encoding="UTF-8"?><q:document xmlns:q="${W}" xmlns:rel="${R}"><q:body>${body}<q:sectPr/></q:body></q:document>`],
    ['word/styles.xml',`<q:styles xmlns:q="${W}">${styles}</q:styles>`],
    ['word/numbering.xml',`<q:numbering xmlns:q="${W}"><q:abstractNum q:abstractNumId="1"><q:lvl q:ilvl="0"><q:start q:val="1"/><q:numFmt q:val="decimal"/><q:lvlText q:val="%1."/></q:lvl></q:abstractNum><q:num q:numId="7"><q:abstractNumId q:val="1"/></q:num></q:numbering>`],
    ['word/_rels/main.xml.rels',`<Relationships xmlns="${P}"><Relationship Id="styles" Type="${R}/styles" Target="styles.xml"/><Relationship Id="num" Type="${R}/numbering" Target="numbering.xml"/>${kind==='table-media'?`<Relationship Id="img1" Type="${R}/image" Target="media/self.png"/>`:''}</Relationships>`],...extra
  ];
}
function fixture(kind,options={}) {const bytes=zip(parts(kind),options);return {kind,bytes,hash:crypto.createHash('sha256').update(bytes).digest('hex')};}
module.exports={gold,parts,fixture,zip,crc32};
