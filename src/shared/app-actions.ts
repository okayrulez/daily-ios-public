import {z} from 'zod';
import {AgendaEntry,AgendaSchedule,occurs,type AgendaItem} from './mobile-agenda.js';
import type {PortableMemoryV1} from './portable-memory.js';
import {hash,canonicalJson} from './mobile-json.js';
import {refreshMapDescriptions} from './map-descriptions.js';
const quote=z.string().min(1).max(2000),id=z.string().min(1).max(100);
export const RequestedAgendaSchedule=AgendaSchedule.safeExtend({
  appleDestination:z.enum(['calendar','reminders','alarm']).nullable().optional(),
});
const EventFields={title:z.string().min(1).max(250),details:z.string().max(4000),schedule:RequestedAgendaSchedule};
export const AppAction=z.discriminatedUnion('tool',[
  z.object({tool:z.literal('agenda_create'),quote,...EventFields}).strict(),
  z.object({tool:z.literal('agenda_update'),quote,id,...EventFields}).strict(),
  z.object({tool:z.literal('agenda_cancel'),quote,id,dates:z.array(z.iso.date()).max(366)}).strict(),
  z.object({tool:z.literal('agenda_restore'),quote,id,dates:z.array(z.iso.date()).max(366)}).strict(),
  z.object({tool:z.literal('map_update'),quote,id,label:z.string().min(1).max(250),topicPath:z.array(z.string().min(1).max(180)).min(1).max(8)}).strict(),
  z.object({tool:z.literal('map_correct'),quote,id,text:z.string().min(1).max(4000),verdict:z.enum(['context','incorrect','no_longer'])}).strict(),
  z.object({tool:z.literal('map_retract'),quote,id}).strict(),
  z.object({tool:z.literal('map_restore'),quote,id}).strict(),
  z.object({tool:z.literal('map_link'),quote,source:id,target:id,relation:z.string().min(1).max(160)}).strict(),
  z.object({tool:z.literal('map_unlink'),quote,id}).strict(),
]);
export type AppOperation=z.infer<typeof AppAction>;
export const GraphPreferences=z.object({
  nodes:z.record(z.string(),z.object({label:z.string().optional(),topicPath:z.array(z.string()).optional(),
    status:z.enum(['observation','candidate','retracted']).optional()}).strict()),
  removedEdges:z.array(z.string()),edges:z.array(z.object({id:z.string(),source:z.string(),target:z.string(),relation:z.string()}).strict()),
}).strict();
export function applyGraphPreferences(memory:PortableMemoryV1) {
  const prefs=memory.graphPreferences;
  if(prefs){
    for(const node of memory.graph.nodes){
      const override=prefs.nodes[node.id];
      if(override)Object.assign(node,override,override.topicPath?{topicId:hash(canonicalJson(override.topicPath)).slice(0,24)}:{});
    }
    const ids=new Set(memory.graph.nodes.map(n=>n.id));
    memory.graph.edges=memory.graph.edges.filter(e=>!prefs.removedEdges.includes(e.id));
    for(const edge of prefs.edges)if(ids.has(edge.source)&&ids.has(edge.target)&&!memory.graph.edges.some(e=>e.id===edge.id))memory.graph.edges.push(edge);
  }
  memory.graph.topics=[...new Set(memory.graph.nodes.map(n=>n.topicId))].map(id=>{
    const nodes=memory.graph.nodes.filter(n=>n.topicId===id);
    return {id,path:nodes[0].topicPath,count:nodes.length,sourceCount:new Set(nodes.flatMap(n=>n.evidence.map(e=>e.sourceId))).size};
  });
  return refreshMapDescriptions(memory);
}
export function applyAppActions(memory:PortableMemoryV1,operations:AppOperation[],evidence:string[],sourceID:string,now:string,jobID:string) {
  const next=JSON.parse(canonicalJson(memory)) as PortableMemoryV1;
  const entries:AgendaItem[]=next.agenda??[];
  const changes:string[]=[];
  for(const [index,op] of operations.entries()){
    if(!evidence.some(s=>s.includes(op.quote)))throw Error('Unsupported action quote');
    if(op.tool==='agenda_create'){
      const {appleDestination: _requestedDestination,...schedule}=op.schedule;
      const duplicate=entries.find(e=>e.status==='active'&&e.title===op.title&&canonicalJson(e.schedule)===canonicalJson(schedule));
      if(duplicate){changes.push('Zaten ajandanda: '+op.title);continue;}
      entries.push(AgendaEntry.parse({id:'event_'+hash(jobID+':'+index).slice(0,32),title:op.title,details:op.details,
        schedule,status:'active',excludedDates:[],sourceQuote:op.quote,sourceID,createdAt:now,updatedAt:now,revision:1}));
      changes.push('Ajandaya eklendi: '+op.title);
      if(op.schedule.reminderMinutes===null)changes.push('Bu kayıtta bildirim zamanı yok: '+op.title);
      continue;
    }
    if(op.tool==='agenda_update'||op.tool==='agenda_cancel'||op.tool==='agenda_restore'){
      const entry=entries.find(e=>e.id===op.id);if(!entry)throw Error('Unknown action target');
      if(op.tool==='agenda_update'){
        entry.title=op.title;entry.details=op.details;
        // The shared agenda format remains readable by older apps and notification workers.
        const {appleDestination: _requestedDestination,...schedule}=op.schedule;
        entry.schedule=schedule;
        changes.push('Etkinlik güncellendi: '+entry.title);
        changes.push((op.schedule.reminderMinutes===null?'Bu kayıtta bildirim zamanı yok: ':'Hatırlatma zamanı ajandaya kaydedildi: ')+entry.title);
      }else if(op.tool==='agenda_cancel'){
        if(op.dates.length){
          if(op.dates.some(d=>!occurs(entry,d)))throw Error('Invalid occurrence');
          entry.excludedDates=[...new Set([...entry.excludedDates,...op.dates])];
        }else entry.status='cancelled';
        changes.push('İptal edildi: '+entry.title+(op.dates.length?' ('+op.dates.join(', ')+')':' (bütün seri)'));
      }else{
        if(op.dates.length){
          if(entry.status!=='active'||op.dates.some(d=>!entry.excludedDates.includes(d)))throw Error('Invalid occurrence');
          entry.excludedDates=entry.excludedDates.filter(d=>!op.dates.includes(d));
        }
        else entry.status='active';
        changes.push('Geri alındı: '+entry.title);
      }
      entry.updatedAt=now;entry.revision++;continue;
    }
    const prefs=next.graphPreferences??{nodes:{},removedEdges:[],edges:[]};
    next.graphPreferences=prefs;
    if(op.tool==='map_link'){
      if(op.source===op.target||![op.source,op.target].every(id=>next.graph.nodes.some(n=>n.id===id)))throw Error('Unknown action target');
      const edge={id:hash([op.source,op.target,op.relation].join(':')).slice(0,24),source:op.source,target:op.target,relation:op.relation};
      prefs.edges=prefs.edges.filter(e=>e.id!==edge.id).concat(edge);
      prefs.removedEdges=prefs.removedEdges.filter(id=>id!==edge.id);changes.push('Harita bağlantısı eklendi');continue;
    }
    if(op.tool==='map_unlink'){
      if(!next.graph.edges.some(e=>e.id===op.id))throw Error('Unknown action target');
      prefs.removedEdges=[...new Set([...prefs.removedEdges,op.id])];prefs.edges=prefs.edges.filter(e=>e.id!==op.id);
      changes.push('Harita bağlantısı kaldırıldı');continue;
    }
    const node=next.graph.nodes.find(n=>n.id===op.id);if(!node)throw Error('Unknown action target');
    if(op.tool==='map_update')prefs.nodes[node.id]={...prefs.nodes[node.id],label:op.label,topicPath:op.topicPath};
    if(op.tool==='map_retract'||op.tool==='map_restore')prefs.nodes[node.id]={...prefs.nodes[node.id],status:op.tool==='map_retract'?'retracted':'candidate'};
    if(op.tool==='map_correct'){
      node.corrections.push({id:hash(jobID+':'+index).slice(0,32),nodeId:node.id,text:op.text,verdict:op.verdict,createdAt:now});
      if(op.verdict!=='context')prefs.nodes[node.id]={...prefs.nodes[node.id],status:'retracted'};
    }
    changes.push('Harita güncellendi: '+node.label);
  }
  if(operations.some(op=>op.tool.startsWith('agenda_')))next.agenda=entries;
  const retract=new Set(Object.entries(next.graphPreferences?.nodes??{}).filter(([,p])=>p.status==='retracted').map(([id])=>id));
  let grew=true;
  while(grew){grew=false;for(const node of next.graph.nodes)if(!retract.has(node.id)&&
    [...(node.inference?.parentIds??[]),...(node.inference?.rootNodeIds??[])].some(id=>retract.has(id))){retract.add(node.id);grew=true;}}
  for(const node of next.graph.nodes)if(retract.has(node.id)){
    node.status='retracted';
    const prefs=next.graphPreferences??{nodes:{},removedEdges:[],edges:[]};prefs.nodes[node.id]={...prefs.nodes[node.id],status:'retracted'};next.graphPreferences=prefs;
  }
  return {memory:applyGraphPreferences(next),changes};
}
