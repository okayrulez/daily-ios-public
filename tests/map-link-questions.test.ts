import {invoke} from '../src/shared/mobile-analysis-core';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
import {describe,it,expect} from 'vitest';
import {prepareMapQuestions,installMapQuestions,prepareMapLinks,applyMapLinks} from '../src/shared/map-link-questions';
import {exportPortableMemory} from '../src/main/memory/portable-memory-export';
import {snapshot} from './fixtures';
import {canonicalJson,hash} from '../src/shared/mobile-json';
const date='2026-10-10',now='2026-10-10T10:00:00Z';
const question={prompt:'Bu iki düşüncenin birlikte olduğu bir örnek anlatır mısın?',rationale:'İlişkiyi netleştirmek için'};
function fixture(){
 const memory=exportPortableMemory(snapshot(),1);
 const journal={entry:{id:'focus-journal',local_date:date,raw_text:'Haritalarımın bağlantılarını geliştirmek istiyorum.',content_hash:hash('Haritalarımın bağlantılarını geliştirmek istiyorum.'),saved_at:now,analysis_status:'pending',analysis_error:null},questions:[],analyses:[]};
 const selected=memory.graph.nodes.map(n=>n.id);
 const installed=installMapQuestions({journal,nodeIDs:selected,result:{open_questions:Array(3).fill(question),boolean_questions:Array(3).fill({...question,prompt:'Bunlar birlikte gerçekleşiyor mu?'})},sessionID:'focus-test',now});
 return {memory,journal:installed.journal,selected,cards:installed.cards};
}
const result={kind:'map_links_result',reflection:'Verdiğin örnek bu düşünceler arasında bir ilişkiyi destekliyor.',links:[]};
function apply(f:ReturnType<typeof fixture>,r:unknown){return applyMapLinks({memory:f.memory,journal:f.journal,result:r,expectedMemoryHash:hash(canonicalJson(f.memory)),expectedSourceHash:hash(canonicalJson(f.journal)),jobID:hash('map-job'),model:'fixture',now});}
describe('focused map question rounds',()=>{
 it('accepts a JSON code fence without weakening the six-question or link contract',()=>{
  const q={open_questions:Array(3).fill(question),boolean_questions:Array(3).fill(question)};
  expect(JSON.parse(invoke('validateMapQuestions','```json\n'+JSON.stringify(q)+'\n```'))).toEqual(q);
  expect(JSON.parse(invoke('validateMapLinks','```json\n'+JSON.stringify(result)+'\n```'))).toEqual(result);
  expect(()=>invoke('validateMapQuestions',JSON.stringify({...q,boolean_questions:[question]}))).toThrow();
 });
 it('runs focused question and link commands inside the actual iOS JavaScript bundle',()=>{
  const sandbox:Record<string,any>={};runInNewContext(readFileSync(new URL('../ios/DailyCore/Resources/dailyx-analysis.js',import.meta.url),'utf8'),sandbox,{timeout:5000});
  const f=fixture();f.journal.questions[0].answer_text='Bu iki düşünce birlikte ortaya çıkıyor.' as never;
  const args={memory:f.memory,journal:f.journal,result,expectedMemoryHash:hash(canonicalJson(f.memory)),expectedSourceHash:hash(canonicalJson(f.journal)),jobID:hash('bundle-job'),model:'fixture',now};
  expect(JSON.parse(sandbox.DailyXAnalysis.invoke('applyMapLinks',JSON.stringify(args)))).toEqual(applyMapLinks(args));
  expect(JSON.parse(sandbox.DailyXAnalysis.invoke('prepareMapLinks',JSON.stringify(f)))).toEqual(prepareMapLinks(f));
 });
 it('creates exactly three open and three boolean questions with empty answers and a notification',()=>{
  const f=fixture();expect(f.journal.questions.filter(q=>q.kind==='open')).toHaveLength(3);expect(f.journal.questions.filter(q=>q.kind==='boolean')).toHaveLength(3);
  expect(f.journal.questions.every(q=>q.answer_text===null&&q.answer_boolean===null)).toBe(true);
  expect(JSON.parse(JSON.parse(f.cards[0].content)).id).toBe('journal_questions_'+date);
  expect(()=>installMapQuestions({journal:f.journal,nodeIDs:f.selected,result:{open_questions:Array(3).fill(question),boolean_questions:Array(3).fill(question)},sessionID:'next',now})).toThrow('active question session');
 });
 it('refuses a round with fewer than two selected nodes or wrong question counts',()=>{
  expect(()=>prepareMapQuestions({nodes:[{id:'one',label:'One',summary:'',topicPath:[]}]})).toThrow();
  const f=fixture();expect(()=>installMapQuestions({journal:f.journal,nodeIDs:f.selected,result:{open_questions:[question],boolean_questions:[question]},sessionID:'bad',now})).toThrow();
 });
 it('requires an actual answer and refuses disappeared focus nodes',()=>{
  const f=fixture();expect(()=>prepareMapLinks(f)).toThrow('Answer at least one');
  f.journal.questions[0].answer_text='Birlikte düşünürken yürüyüş yapıyorum.' as never;
  expect(JSON.parse(prepareMapLinks(f).input[0].content).answers[0].answer).toContain('yürüyüş');
  f.memory.graph.nodes=[];f.memory.graph.edges=[];f.memory.graph.topics=[];expect(()=>prepareMapLinks(f)).toThrow('Focus nodes changed');
 });
 it('adds only grounded links between selected nodes and archives saved answers',()=>{
  const f=fixture();f.journal.questions[0].answer_text='Yürürken düşüncelerimi toparlarım.' as never;
  const link={source:f.selected[0],target:f.selected[1],relation:'birlikte gerçekleşiyor',answerIDs:[f.journal.questions[0].id]};
  const saved=apply(f,{...result,links:[link]});
  expect(saved.memory.graph.nodes).toEqual(f.memory.graph.nodes);expect(saved.memory.sources).toEqual(f.memory.sources);
  expect(saved.memory.graph.edges).toHaveLength(f.memory.graph.edges.length+1);
  expect(saved.journal.question_history).toEqual(f.journal.questions);expect(saved.journal.questions).toEqual([]);
  expect(saved.journal.map_link_session.phase).toBe('complete');
  expect(()=>apply(f,{...result,links:[{...link,target:'outside'}]})).toThrow('Unsupported focused link');
  expect(()=>apply(f,{...result,links:[{...link,answerIDs:[f.journal.questions[1].id]}]})).toThrow('Unsupported focused link');
 });
 it('keeps the graph unchanged when answers do not support a new relation and rejects stale hashes',()=>{
  const f=fixture();f.journal.questions[3].answer_boolean=0 as never;
  const saved=apply(f,result);expect(saved.memory.graph.edges).toEqual(f.memory.graph.edges);
  expect(()=>applyMapLinks({memory:f.memory,journal:f.journal,result,expectedMemoryHash:hash('stale'),expectedSourceHash:hash(canonicalJson(f.journal)),jobID:hash('job'),model:'fixture',now})).toThrow('Source or memory changed');
 });
});
