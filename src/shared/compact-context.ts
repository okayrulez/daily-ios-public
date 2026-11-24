import {canonicalJson} from './mobile-json.js';

/** Historical context only. Never use this on the user's current journal or answers. */
export const brief=(value:string|undefined,max:number)=> {
  const text=(value??'').replace(/\s+/g,' ').trim();
  return text.length<=max?text:text.slice(0,max-1)+'…';
};

/** Keep complete records/JSON; an oversized record never consumes the whole context. */
export function contextItems(sections:Record<string,unknown>,name:string,items:unknown[],budget:number,total=14000) {
  const selected:unknown[]=[];
  for(const item of items) {
    const candidate=[...selected,item];
    if(canonicalJson(candidate).length<=budget &&
       canonicalJson({...sections,[name]:candidate}).length<=total-1000)selected.push(item);
  }
  sections[name]=selected;
}

/** Routing needs a map directory, not evidence, past journals or write-tool schemas. */
export function taskContext(raw:string,action='route'):string {
  const limit=action==='route'?3200:8500,sections:Record<string,unknown>={contextVersion:2};
  let data:Record<string,unknown>;
  try {
    // Older callers appended feedback after the JSON. New native callers pass it structurally.
    data=JSON.parse(raw.split('\nKULLANICININ KAYITLI GERİ BİLDİRİMLERİ')[0]);
    if(!data||Array.isArray(data)||typeof data!=='object')throw Error();
  } catch { return brief(raw,action==='route'?1200:2500); }
  for(const key of ['currentDate','timezone'])if(typeof data[key]==='string')sections[key]=data[key];
  const rows=(key:string):unknown[]=>Array.isArray(data[key])?data[key] as unknown[]:[];
  contextItems(sections,'mapSummaries',rows('mapSummaries').length?rows('mapSummaries'):rows('mapCatalog'),2000,limit);
  if(action!=='route') {
    contextItems(sections,'userCorrectionsOverrideModel',rows('userCorrectionsOverrideModel'),1600,limit);
    contextItems(sections,'agendaEvents',rows('agendaEvents'),1800,limit);
    if(action==='manage')contextItems(sections,'appMapTargets',rows('appMapTargets'),1800,limit);
    contextItems(sections,'existingGraphNotNewEvidence',rows('existingGraphNotNewEvidence'),2500,limit);
    contextItems(sections,'mapConnections',rows('mapConnections'),800,limit);
    if(typeof data.userFeedback==='string')sections.userFeedback=brief(data.userFeedback,400);
  }
  sections.contextRule='Only a bounded selection is shown. Cluster summaries and old model conclusions are orientation, not new evidence. Do not claim the entire history was read. Never invent target IDs.';
  return canonicalJson(sections);
}

export function previousTaskContext(previous:Record<string,any>|undefined,query?:string) {
  if(!previous)return null;
  const result:Record<string,unknown>={action:previous.action,status:previous.status,goal:brief(previous.goal,700),round:previous.round,
    lastReply:brief(previous.reply,500),nextQueries:(previous.nextQueries??[]).slice(0,6).map((s:string)=>brief(s,140)),
    findingCount:(previous.findings??[]).length,
    recentFindings:(previous.findings??[]).slice(-5).map((f:Record<string,string>)=>brief(f.label,90)),
    reportStoredLocally:true};
  if(query&&previous.action==='research') {
    const words=new Set(query.toLocaleLowerCase('tr').match(/[\p{L}\p{N}]{3,}/gu)??[]);
    const score=(f:Record<string,string>)=>[...words].filter(w=>
      (f.label+' '+f.detail).toLocaleLowerCase('tr').includes(w)).length;
    contextItems(result,'findings',[...(previous.findings??[])].sort((a,b)=>score(b)-score(a))
      .slice(0,4).map(f=>({label:brief(f.label,100),detail:brief(f.detail,320),
        urls:(f.urls as string[]).filter(url=>url.length<=400).slice(0,2)})),1400,4500);
  }
  return result;
}
