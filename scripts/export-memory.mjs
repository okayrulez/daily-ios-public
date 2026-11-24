import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {runInNewContext} from 'node:vm';
const [input,output,revision='1']=process.argv.slice(2);
if(!input||!output)throw Error('Usage: node scripts/export-memory.mjs <desktop-snapshot.json> <dailyx-memory.json> [revision]');
const sandbox={};
runInNewContext(readFileSync(new URL('../ios/DailyCore/Resources/dailyx-analysis.js',import.meta.url),'utf8'),sandbox);
const result=sandbox.DailyXAnalysis.invoke('importDesktopSnapshot',JSON.stringify({
  snapshot:JSON.parse(readFileSync(resolve(input),'utf8')),revision:Number(revision)}));
// Never overwrite an existing export, and never infer sources from atlas display pages.
writeFileSync(resolve(output),result,{flag:'wx',mode:0o600});
console.log('Validated DailyX memory export saved.');
