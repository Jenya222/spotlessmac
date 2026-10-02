import sharp from 'sharp';
import {mkdir,writeFile,copyFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const images=path.join(root,'public/images');
for(const name of ['hero','developer-tools'])await sharp(path.join(images,`${name}.png`)).webp({quality:88}).toFile(path.join(images,`${name}.webp`));
const catalog=path.resolve(root,'../SpotlessMac/Assets.xcassets');
const iconset=path.join(catalog,'AppIcon.appiconset');
const brand=path.join(catalog,'BrandIcon.imageset');
await mkdir(iconset,{recursive:true});await mkdir(brand,{recursive:true});
const info={author:'xcode',version:1};const icons=[];
for(const size of [16,32,128,256,512])for(const scale of [1,2]){
 const filename=`icon_${size}x${size}${scale===2?'@2x':''}.png`;
 await sharp(path.join(images,'app-icon.png')).resize(size*scale,size*scale).png().toFile(path.join(iconset,filename));
 icons.push({filename,idiom:'mac',size:`${size}x${size}`,scale:`${scale}x`});
}
await writeFile(path.join(catalog,'Contents.json'),JSON.stringify({info},null,2));
await writeFile(path.join(iconset,'Contents.json'),JSON.stringify({images:icons,info},null,2));
await copyFile(path.join(images,'app-icon.png'),path.join(brand,'BrandIcon.png'));
await writeFile(path.join(brand,'Contents.json'),JSON.stringify({images:[{filename:'BrandIcon.png',idiom:'universal'}],info},null,2));
console.log('Optimized website images and generated 10 macOS AppIcon representations.');
