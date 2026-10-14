const fs=require('node:fs'),path=require('node:path');
class MediaStreams {
 constructor(){this.active=new Map();this.retired=[];}
 canonical(file){try{return fs.realpathSync(file);}catch{return path.resolve(file);}}
 inside(root,file){const rel=path.relative(this.canonical(root),this.canonical(file));return rel===''||rel!=='..'&&!rel.startsWith('..'+path.sep)&&!path.isAbsolute(rel);}
 open(file,range){if(this.retired.some(root=>this.inside(root,file)))throw Error('临时预览已结束');const stream=fs.createReadStream(file,range);this.active.set(stream,this.canonical(file));stream.once('close',()=>this.active.delete(stream));return stream;}
 async closeOwned(roots){
  this.retired.push(...roots.map(root=>this.canonical(root)));if(this.retired.length>5000)this.retired=this.retired.slice(-5000);
  const selected=[...this.active].filter(([,file])=>roots.some(root=>this.inside(root,file)));
  await Promise.all(selected.map(([stream])=>new Promise(resolve=>{if(stream.closed)return resolve();stream.once('close',resolve);stream.destroy();})));
 }
}
module.exports={MediaStreams};
