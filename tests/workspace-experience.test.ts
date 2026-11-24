import {describe,it,expect} from 'vitest';
import {novelQuestions} from '../src/shared/question-novelty.js';
import {editMemory} from '../src/shared/memory-edit.js';
import {exportPortableMemory} from '../src/main/memory/portable-memory-export.js';
import {mobileAtlasRecords} from '../src/main/memory/mobile-atlas.js';
import {snapshot} from './fixtures.js';
const now='2026-11-03T10:00:00Z';
describe('workspace experience',()=>{
 it('suppresses repeats but preserves negation',()=>{
  expect(novelQuestions([{prompt:'NASILDI?'},{prompt:'Nasıldı?'},{prompt:'Salı mı?'},{prompt:'Salı değil mi?'}],['nasıldı']).map(q=>q.prompt)).toEqual(['Salı mı?','Salı değil mi?']);
 });
 it('preserves specific reminder consent',()=>{
  expect(novelQuestions([{prompt:'Hatırlatayım mı?',reminder_proposal:{time:'18:00'}}],['Hatırlatayım mı?'])).toHaveLength(1);
 });
 it('corrects a node and retracts dependent inferences without deleting sources',()=>{
  const memory=exportPortableMemory(snapshot(),3),original=JSON.stringify(memory);
  const result=editMemory({memory,action:'correct',nodeID:'node-one',text:'Bu kalıcı bir alışkanlığım değil.',verdict:'incorrect',id:'manual',now});
  expect(result.memory.revision).toBe(4);
  expect(result.memory.graph.nodes.every(n=>n.status==='retracted')).toBe(true);
  expect(result.memory.graph.nodes[0].corrections.at(-1)?.text).toBe('Bu kalıcı bir alışkanlığım değil.');
  expect(result.memory.sources).toEqual(memory.sources);
  expect(JSON.stringify(memory)).toBe(original);
 });
 it('rejects unknown targets and empty corrections',()=>{
  const memory=exportPortableMemory(snapshot(),3);
  expect(()=>editMemory({memory,action:'correct',nodeID:'missing',text:'Yanlış',verdict:'incorrect',id:'manual',now})).toThrow();
  expect(()=>editMemory({memory,action:'correct',nodeID:'node-one',text:' ',verdict:'incorrect',id:'manual',now})).toThrow();
 });
 it('rolls back content at a new revision',()=>{
  const prior=exportPortableMemory(snapshot(),1),memory=exportPortableMemory(snapshot(),8);
  memory.graph.nodes[0].label='Changed';
  const result=editMemory({memory,prior,action:'rollback',id:'undo',now});
  expect(result.memory.revision).toBe(9);
  expect(result.memory.graph.nodes[0].label).toBe(prior.graph.nodes[0].label);
  expect(result.memory.sources).toEqual(prior.sources);
 });
 it('projects quote and source provenance',()=>{
  const rows=mobileAtlasRecords(snapshot().graph);
  const notes=rows.filter(r=>r.key.includes('-notes-')).flatMap(r=>JSON.parse(JSON.parse(r.content)).items);
  expect(notes.find(n=>n.kind==='observation')).toMatchObject({quote:'Bugün yürüdüm.',sourceId:'source-one',sourceTitle:'Günlük'});
 });
});
