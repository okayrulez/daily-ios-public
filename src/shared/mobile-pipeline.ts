import {brief,contextItems} from './compact-context.js';
import {refreshMapDescriptions,descriptionNodes,mapDescriptionFingerprint} from './map-descriptions.js';
import {validateEmotionEvidence,canonicalEmotionKey,correctedEmotionObservations,EmotionObservationOverridesSchema} from './emotional-memory.js';
import {usefulQuestions,questionBasis,questionPlanningState,prioritizeQuestions} from './question-policy.js';
import {EmotionProposal,isFunctionalQuestion,functionalPrompts} from './functional-answers.js';
import {novelQuestions} from './question-novelty.js';
import {nodeMapId} from './map-clusters.js';
import {mapCatalog,placeNotes,stabilizeSources} from './map-registry.js';
import {advanceMapReview,failedMapReview} from './map-review.js';
import {applyApprovedReminders,reminderQuestion} from './reminder-proposals.js';
import { z } from 'zod';
import { PortableMemorySchema, type PortableMemoryV1 } from './portable-memory.js';
import { JournalAnalysisSchema } from '../main/analysis/schemas.js';
import { defaultMemoryRouter } from '../main/memory/memory-router.js';
import { buildMemoryGraph } from '../main/memory/mobile-graph.js';
import { mobileAtlasRecords } from '../main/memory/mobile-atlas.js';
import { canonicalJson, hash, utf8 } from './mobile-json.js';
import { WritingSchema } from './living-memory.js';
import { applyCrossMap } from './mobile-cross-map.js';
import { followupRecords } from './mobile-followups.js';
import { CompanionCardSchema } from './companion-inbox.js';
import {agendaRecord} from './mobile-agenda.js';
import {applyGraphPreferences} from './app-actions.js';

const question = z.object({ id: z.string(), journal_id: z.string(), kind: z.enum(['open','boolean']),
  position: z.number().int(), prompt: z.string(), rationale: z.string(), source_ref: z.string(),
  answer_text: z.string().nullable(), answer_boolean: z.union([z.literal(0),z.literal(1)]).nullable() }).passthrough();
export const JournalPayloadSchema = z.object({
  entry: z.object({ id: WritingSchema.shape.id, local_date: z.iso.date(), raw_text: z.string().min(1),
    content_hash: z.string(), saved_at: z.string(), analysis_status: z.string(), analysis_error: z.string().nullable() }).passthrough(),
  analyses: z.array(z.object({ id: z.string(), version: z.number().int().positive() }).passthrough()),
  questions: z.array(question),
}).passthrough().superRefine((journal, ctx) => {
  if (hash(journal.entry.raw_text) !== journal.entry.content_hash ||
      journal.questions.some(q => q.journal_id !== journal.entry.id) ||
      new Set(journal.questions.map(q => q.id)).size !== journal.questions.length)
    ctx.addIssue({code:'custom',message:'Invalid journal identity'});
});
type Journal = z.infer<typeof JournalPayloadSchema>;
export const emptyMemory = (): PortableMemoryV1 => ({
  schemaVersion: 1, revision: 0, sources: [], graph: {nodes:[],edges:[],topics:[]},
  deadlines: [], routing: {version:1,bindings:{}},
});
export function journalAnswers(journal: Journal) {
  const replies=z.array(z.object({id:z.string(),question:z.string(),answer:z.string().max(10000)}).strict()).parse(journal.supplemental_answers??[]);
  const correction=z.object({source_hash:z.string(),choices:z.array(z.string())}).safeParse(journal.emotion_override);
  const edits=EmotionObservationOverridesSchema.safeParse(journal.emotion_observation_overrides);
  const targeted=edits.success&&edits.data.source_hash===journal.entry.content_hash;
  const choice=!targeted && correction.success && correction.data.source_hash===journal.entry.content_hash
    ? [{question:'Bu günün duygu etiketleri',answer:correction.data.choices.length
      ? 'Duygu seçimi: '+correction.data.choices.join(', ') : 'Bu gün için duygu işareti istemiyorum.'}] : [];
  const perObservation=edits.success&&edits.data.source_hash===journal.entry.content_hash?edits.data.edits.map(e=>({
    question:'Duygu gözlemi düzeltmesi · '+e.observation_id,
    answer:'Alıntı: '+e.quote+'\nBu alıntıdaki kendi seçimim: '+(e.choices.join(', ')||'Duygu işaretini kaldır')+'. Diğer olayların sırasını ve hislerini koru.',
  })):[];
  return [...journal.questions.filter(q=>!isFunctionalQuestion(q)).flatMap(q => q.kind === 'boolean'
    ? q.answer_boolean === null ? [] : [{ question:q.prompt, answer:q.answer_boolean === 1 ? 'Evet' : 'Hayır' }]
    : q.answer_text?.trim() ? [{question:q.prompt,answer:q.answer_text}] : []),
    ...replies.map(r=>({question:'[Yanıt '+r.id+'] '+r.question,answer:r.answer})),...choice,...perObservation];
}
export function evidenceTexts(journal: Journal) { return [journal.entry.raw_text, ...journalAnswers(journal).map(a=>a.answer)]; }
function personalQuestionBasis(memory:PortableMemoryV1,journal:Journal) {
  const functional=functionalPrompts(journal),previous=memory.sources.find(s=>s.id===journal.entry.id)?.answers??[];
  const answers=[...new Map([...previous.filter(a=>!functional.has(a.question)),...journalAnswers(journal)].map(a=>[a.question,a])).values()];
  return questionBasis(journal.entry.raw_text,answers.map(a=>a.question+'\n'+a.answer));
}
export function validateAnalysis(rawText: string, result: unknown, answers: string[] = []) {
  const parsed = JournalAnalysisSchema.parse(result), living = parsed.living_memory;
  if (!(result as Record<string,unknown>).emotions && parsed.emotional_memory) {
    // Old clients require numeric intensity. Unknown intensity stays only in the richer contract.
    parsed.emotions = parsed.emotional_memory.observations.flatMap(o=>o.intensity==null?[]:[{key:o.key,label:o.label,
      intensity:o.intensity,trigger:o.event||null,evidence_ref:o.quote}]);
  }
  if (!living) throw new Error('Missing living memory');
  validateLivingEvidence(rawText,living,answers);
  if (parsed.emotional_memory) validateEmotionEvidence(parsed.emotional_memory, [rawText, ...answers]);
  if(parsed.open_questions.some(q=>q.reminder_proposal))throw Error('Reminder consent must be boolean');
  if(parsed.open_questions.some(q=>q.emotion_proposal))throw Error('Emotion consent must be boolean');
  for(const q of [...parsed.open_questions,...parsed.boolean_questions]) {
    if(q.purpose==='reminder_consent'&&!q.reminder_proposal)throw Error('Missing reminder consent proposal');
    if(q.purpose==='emotion_consent'&&!q.emotion_proposal)throw Error('Missing emotion consent proposal');
  }
  for(const q of parsed.boolean_questions)if(q.emotion_proposal) {
    const proposal=EmotionProposal.parse(q.emotion_proposal);
    if(q.reminder_proposal)throw Error('Ambiguous functional question');
    if(!rawText.includes(proposal.quote))throw Error('Unsupported emotion quote');
  }
  for(const q of parsed.boolean_questions)if(q.reminder_proposal && ![rawText,...answers].some(t=>t.includes(q.reminder_proposal!.quote)))throw Error('Unsupported reminder quote');
  return parsed;
}
export function validateLivingEvidence(rawText:string,living:NonNullable<z.infer<typeof JournalAnalysisSchema>['living_memory']>,answers:string[]) {
  const quotes = [...living.notes, ...living.deadlines, ...(living.followups ?? [])].map(item=>item.quote);
  for (const f of living.followups ?? []) if (f.timing) quotes.push(f.timing.quote);
  if (quotes.some(q=>!q.trim() || ![rawText,...answers].some(text=>text.includes(q)))) throw new Error('Unsupported source quote');
}

/** Extractive cluster summaries + a few relevant notes, never the whole historical graph. */
export function selectContext(memory: PortableMemoryV1, journal: Journal, feedback=''): string {
  const current=journal.entry,answers=journalAnswers(journal);
  const query=[current.raw_text,...answers.map(a=>a.answer)].join(' ');
  const router=defaultMemoryRouter(),request={consumer:'reflection',query,sensitiveConsent:true,mapBindings:memory.routing.bindings};
  const routed=router.select(memory.graph,request),readable=router.readableNodeIds(memory.graph,request);
  const correction=z.object({source_hash:z.string(),choices:z.array(z.string())}).safeParse(journal.emotion_override);
  const sections:Record<string,unknown>={
    contextVersion:2,currentDate:new Date(Date.now()+3*3600000).toISOString().slice(0,10),
    timezone:'Europe/Istanbul',currentEmotionCorrection:!journal.emotion_observation_overrides&&correction.success&&correction.data.source_hash===current.content_hash?{
      source_hash:brief(correction.data.source_hash,80),choices:correction.data.choices.slice(0,8).map(s=>brief(s,60)),
    }:null,
  };
  const fit=(name:string,items:unknown[],budget:number)=>contextItems(sections,name,items,budget);
  fit('questionPlanningStateNotPersonalEvidence',questionPlanningState([
    ...(Array.isArray(journal.question_history)?journal.question_history:[]),...journal.questions],
    personalQuestionBasis(memory,journal)),2400);
  const words=query.toLocaleLowerCase('tr').split(/[^\p{L}\p{N}]+/u).filter(w=>w.length>2);
  const score=(n:typeof memory.graph.nodes[number])=>{
    const label=[n.label,...n.topicPath].join(' ').toLocaleLowerCase('tr');
    return words.filter(w=>label.includes(w)).length;
  };
  const maps=mapCatalog(memory).map(m=>{
    const nodes=memory.graph.nodes.filter(n=>nodeMapId(n)===m.id);
    const selected=routed.nodes.filter(n=>nodeMapId(n)===m.id);
    return {id:m.id,title:m.title,aliases:m.aliases.slice(0,3),nodeCount:nodes.length,
      summary:m.description&&m.descriptionFingerprint===mapDescriptionFingerprint(memory,m.id,m.title)&&
        descriptionNodes(memory,m.id).every(n=>readable.has(n.id)) ? m.description :
        brief(selected.slice(0,3).map(n=>n.label).join('; ')||m.title,180),
      relevance:Math.max(0,...selected.map(score))};
  }).sort((a,b)=>b.relevance-a.relevance||a.title.localeCompare(b.title,'tr'));
  fit('mapSummaries',maps,2800);
  // IDs and names remain available for precise placement, without duplicate descriptions.
  fit('mapCatalog',maps.map(({id,title,aliases})=>({id,title,aliases})),1200);
  fit('userCorrectionsOverrideModel',memory.graph.nodes.flatMap(n=>n.corrections.map(c=>({
    id:c.id,nodeId:n.id,verdict:c.verdict,text:brief(c.text,400),subject:brief(c.subject??n.label,120),createdAt:c.createdAt,
  }))).sort((a,b)=>b.createdAt.localeCompare(a.createdAt)),2200);
  fit('currentUserAnswers',answers,1800); // Full current answers also travel separately, without this history budget.
  const selected=routed.nodes.slice(0,8);
  fit('existingGraphNotNewEvidence',selected.map(n=>({
    id:n.id,map_id:nodeMapId(n),key:n.key,label:brief(n.label,140),path:n.topicPath,scope:brief(n.scope,100),status:n.status,
    description:brief(n.description,360),inference:n.inference,
    evidence:n.evidence.slice(-2).map(e=>({sourceId:e.sourceId,date:e.date,nature:e.nature,quote:brief(e.quote,240),observation:brief(e.observation,200)})),
    corrections:n.corrections.slice(-2).map(c=>({verdict:c.verdict,text:brief(c.text,250)})),
  })),4000);
  fit('agendaEvents',[...(memory.agenda??[])].sort((a,b)=>
    Number(a.status!=='active')-Number(b.status!=='active')||
    Number(words.some(w=>b.title.toLocaleLowerCase('tr').includes(w)))-Number(words.some(w=>a.title.toLocaleLowerCase('tr').includes(w))))
    .map(e=>({id:e.id,title:e.title,status:e.status,schedule:e.schedule,excludedDates:e.excludedDates,details:brief(e.details,180)})),1700);
  fit('appMapTargets',[...memory.graph.nodes].sort((a,b)=>score(b)-score(a)).slice(0,18)
    .map(n=>({id:n.id,label:brief(n.label,100),path:n.topicPath,status:n.status})),1800);
  fit('confirmedDates',memory.deadlines.filter(d=>d.status==='confirmed').slice(0,6),700);
  const ids=new Set(selected.map(n=>n.id));
  for(const target of sections.appMapTargets as Array<{id:string}>)ids.add(target.id);
  fit('mapConnections',memory.graph.edges.filter(e=>ids.has(e.source)||ids.has(e.target)).slice(0,10),900);
  const sourceIDs=new Set(selected.flatMap(n=>n.evidence.map(e=>e.sourceId)));
  fit('priorEmotionalExperience',memory.sources.filter(s=>s.id!==current.id&&s.kind==='journal'&&s.date<=current.local_date)
    .sort((a,b)=>Number(sourceIDs.has(b.id))-Number(sourceIDs.has(a.id))||b.date.localeCompare(a.date))
    .flatMap(s=>{
      const observations=(s.analysis?.notes.filter(n=>n.consumers?.includes('emotion'))??[]).slice(0,4)
        .map(n=>({key:n.key,label:n.label,context_key:/^[a-z][a-z0-9-]{0,99}$/.test(n.scope)?n.scope:undefined,
          quote:brief(n.quote,200),observation:brief(n.observation,220)}));
      return observations.length?[{id:s.id,date:s.date,observations}]:[];
    }).slice(0,3),1400);
  if(feedback.trim())sections.userFeedback=brief(feedback,500);
  sections.evidenceRule='Only current original user text and full current answers are new personal evidence. Historical summaries may be abbreviated; do not turn them into direct quotations or claim all maps were read. Research and prior AI conclusions are not new user evidence.';
  return canonicalJson(sections);
}

export const ApplyInput = z.object({ memory:PortableMemorySchema, journal:JournalPayloadSchema,
  result:z.unknown(), expectedMemoryHash:z.string(), expectedSourceHash:z.string(), jobID:z.string().regex(/^[a-f0-9]{64}$/),
  model:z.string().min(1).max(200), now:z.iso.datetime({offset:true}), crossMapResult:z.unknown().optional(), mapReviewFailed:z.boolean().optional() }).strict();

/** Pure commit preparation; native Firestore must compare BOTH hashes in one transaction. */
export function applyAnalysis(input: z.infer<typeof ApplyInput>) {
  const {memory,journal,jobID,model,now} = input;
  if (hash(canonicalJson(memory))!==input.expectedMemoryHash || hash(canonicalJson(journal))!==input.expectedSourceHash)
    throw new Error('Source or memory changed');
  const result = validateAnalysis(journal.entry.raw_text,input.result,journalAnswers(journal).map(a=>a.answer));
  // Keep the portable source schema readable by desktop builds already in use.
  // Rich chronology lives on the extensible journal; grounded notes use the existing graph contract.
  if (result.emotional_memory) {
    const override=z.object({source_hash:z.string(),choices:z.array(z.string())}).safeParse(journal.emotion_override);
    const edits=EmotionObservationOverridesSchema.safeParse(journal.emotion_observation_overrides);
    const targeted=edits.success&&edits.data.source_hash===journal.entry.content_hash;
    const chosen=!targeted && override.success && override.data.source_hash===journal.entry.content_hash
      ? new Set(override.data.choices.map(canonicalEmotionKey)) : null;
    if(chosen||(edits.success&&edits.data.source_hash===journal.entry.content_hash))result.living_memory!.notes=result.living_memory!.notes.filter(note=>!note.consumers?.includes('emotion'));
    for (const observation of correctedEmotionObservations(result.emotional_memory,journal)) {
      if(chosen && !chosen.has(canonicalEmotionKey(observation.key)))continue;
      const scope = (observation.context_key || observation.event.trim() || 'Gün içindeki deneyim').slice(0,200);
      const key='emotion-'+hash(canonicalEmotionKey(observation.key)+':'+scope.toLocaleLowerCase('tr')).slice(0,20);
      if (result.living_memory!.notes.some(note => note.key===key && note.quote===observation.quote)) continue;
      const existing=memory.graph.nodes.find(n=>n.key===key&&n.status!=='retracted');
      result.living_memory!.notes.push({
        topic_path:existing?.topicPath??(observation.topic_path?.length?observation.topic_path:['Duygu deneyimleri']), key,
        ...(existing?{existing_node_id:existing.id}:{}),
        label:(observation.label+' · '+(observation.context_label||observation.event||scope)).slice(0,250),
        observation:(observation.label+'; '+observation.event+'; '+(observation.conditions??[]).join(', ')+'; '+(observation.order_basis==='unknown'?'Zaman sırası belirtilmedi':'anlatılan sıra '+observation.sequence)).slice(0,4000),
        quote:observation.quote,nature:'observation',scope,status:'active',related_keys:[],consumers:['emotion'],
      });
    }
  }
  const maps=placeNotes(memory,result.living_memory!,jobID);
  const closed=new Set([...(memory.closedFollowupKeys??[]),...memory.sources.flatMap(s=>(s.analysis?.followups??[]).filter(f=>f.status==='resolved').map(f=>f.key))]);
  for(const f of result.living_memory!.followups??[])if(closed.has(f.key)){f.status='resolved';f.timing=null;}
  for(const f of result.living_memory!.followups??[])if(f.status==='resolved')closed.add(f.key);
  const old = memory.sources.find(s=>s.id===journal.entry.id);
  // A revised answer replaces the old answer to that question. The journal's
  // question_history retains history; old answers do not become competing current evidence.
  const functional=functionalPrompts(journal);
  const answers = [...new Map([...(old?.answers??[]).filter(a=>!functional.has(a.question)),...journalAnswers(journal)].map(a=>[a.question,a])).values()];
  const source = WritingSchema.parse({...old,id:journal.entry.id,kind:'journal',title:journal.entry.local_date,
    date:journal.entry.local_date,text:journal.entry.raw_text,revision:(old?.revision??0)+1,
    createdAt:old?.createdAt??journal.entry.saved_at,updatedAt:now,status:'complete',error:null,
    analysis:result.living_memory,answers,warnings:[]});
  const sources = stabilizeSources(memory).filter(s=>s.id!==source.id).concat(source);
  const corrections = memory.graph.nodes.flatMap(n=>n.corrections);
  const graph = buildMemoryGraph(sources,corrections);
  // Imported graph may include manual notes and cross-map conclusions with no analysis row.
  // Preserve them, but never retain evidence for a superseded version of this journal.
  for (const previous of memory.graph.nodes) if (!graph.nodes.some(n=>n.id===previous.id)) {
    const evidence = previous.evidence.filter(e=>e.sourceId!==source.id);
    if (evidence.length || previous.corrections.length || previous.inference) graph.nodes.push({...previous,evidence,
      status:previous.inference && previous.evidence.some(e=>e.sourceId===source.id) &&
        !['corrected','retracted'].includes(previous.status) ? 'weakening' : previous.status});
  }
  // Prune invalid ancestry recursively instead of relinking an inference to invented roots.
  let removed = true;
  while (removed) {
    const ids = new Set(graph.nodes.map(n=>n.id));
    const keep = graph.nodes.filter(n=>[...(n.inference?.parentIds??[]),...(n.inference?.rootNodeIds??[])].every(id=>ids.has(id)));
    removed = keep.length!==graph.nodes.length; graph.nodes=keep;
  }
  const ids = new Set(graph.nodes.map(n=>n.id));
  graph.edges = [...graph.edges,...memory.graph.edges.filter(e=>!graph.edges.some(x=>x.id===e.id))]
    .filter(e=>ids.has(e.source)&&ids.has(e.target));
  graph.topics = [...new Set(graph.nodes.map(n=>n.topicId))].map(id=>{
    const nodes = graph.nodes.filter(n=>n.topicId===id);
    return {id,path:nodes[0].topicPath,count:nodes.length,sourceCount:new Set(nodes.flatMap(n=>n.evidence.map(e=>e.sourceId))).size};
  });
  let nextMemory = PortableMemorySchema.parse({...memory,revision:memory.revision+1,sources,graph,maps,closedFollowupKeys:[...closed].sort()});
  nextMemory=advanceMapReview(memory,nextMemory,source.id);
  if(input.mapReviewFailed)nextMemory=failedMapReview(nextMemory);
  if(input.crossMapResult!==undefined)nextMemory=PortableMemorySchema.parse(applyCrossMap(nextMemory,input.crossMapResult));
  nextMemory=PortableMemorySchema.parse(applyGraphPreferences(nextMemory));
  nextMemory=PortableMemorySchema.parse(refreshMapDescriptions(nextMemory,result.living_memory?.map_summaries??[],memory));
  const approvals=applyApprovedReminders(nextMemory,journal,now);
  nextMemory=PortableMemorySchema.parse(approvals.memory);
  const knownQuestions=[...memory.sources.flatMap(s=>s.answers.filter(a=>a.answer.trim()).map(a=>a.question)),
    ...journalAnswers(journal).map(a=>a.question)];
  const history=[...z.array(z.unknown()).parse(journal.question_history??[]),...journal.questions];
  const basis=personalQuestionBasis(memory,journal);
  const pending=journal.questions.filter(q=>isFunctionalQuestion(q)&&q.answer_boolean===null&&!q.session_closed_at&&q.question_basis===basis);
  const finishingQuestionSession = journal.questions.some(q => !isFunctionalQuestion(q) &&
    typeof q.session_closed_at === 'string' && (q.answer_boolean !== null || !!q.answer_text?.trim()));
  const generated = (['open','boolean'] as const).flatMap(kind=>
    usefulQuestions(novelQuestions(
      (kind === 'open' ? result.open_questions : result.boolean_questions)
        .filter(q => !finishingQuestionSession || q.reminder_proposal || q.emotion_proposal),
      knownQuestions),
      {basis,history,agenda:nextMemory.agenda??[],pending}).map((q,position)=>({
      ...q,prompt:q.reminder_proposal?reminderQuestion(q.reminder_proposal):q.emotion_proposal?
        `Bu günü “${q.emotion_proposal.label}” duygu etiketiyle işaretleyeyim mi?`:q.prompt,
      id:hash(jobID+':'+kind+':'+position).slice(0,32),journal_id:source.id,kind,position,question_basis:basis,answer_text:null,answer_boolean:null
    })));
  const questions=(['open','boolean'] as const).flatMap(kind=>prioritizeQuestions([
    ...pending.filter(q=>q.kind===kind),...generated.filter(q=>q.kind===kind),
  ]).slice(0,kind==='open'?3:5).map((q,position)=>({...q,position})));
  const pendingIDs=new Set(pending.map(q=>q.id));
  const carriedIDs=new Set(questions.filter(q=>pendingIDs.has(q.id)).map(q=>q.id));
  const hasNewQuestions=questions.some(q=>!carriedIDs.has(q.id));
  const oldHistory = z.array(z.unknown()).parse(journal.question_history ?? []);
  const {daily_task: _previousTask, ...journalFields} = journal;
  const updated = {...journalFields,emotional_memory:result.emotional_memory ? {...result.emotional_memory,source_hash:hash(journal.entry.raw_text)} : undefined,entry:{...journal.entry,analysis_status:'complete',analysis_error:null},
    questions,reminder_results:approvals.changes,questions_generated_at:hasNewQuestions?now:journal.questions_generated_at??now,question_history:[...oldHistory,...journal.questions.filter(q=>!carriedIDs.has(q.id))],
    analyses:[...journal.analyses,{id:jobID,journal_id:source.id,version:Math.max(0,...journal.analyses.map(a=>a.version))+1,
      provider:'ChatGPT / '+model,reflection:result.reflection,confidence:result.confidence,created_at:now,
      source_hash:input.expectedSourceHash,result}],
  };
  const content = canonicalJson(updated);
  const previousCards=followupRecords(memory,now),currentCards=followupRecords(nextMemory,now);
  const cards=currentCards.filter(card=>!previousCards.some(old=>old.key===card.key&&old.hash===card.hash));
  for(const previous of previousCards)if(!currentCards.some(card=>card.key===previous.key)){
    const value=JSON.parse(JSON.parse(previous.content));
    if(!value.withdrawn) {
      const content=canonicalJson(canonicalJson({...value,withdrawn:true}));
      cards.push({...previous,content,hash:hash(content)});
    }
  }
  if(hasNewQuestions)cards.push(questionNotificationRecord(source.id,source.date,jobID,now));
  return {memory:nextMemory,journal:updated,appleDestinations:approvals.appleDestinations,atlas:[agendaRecord(nextMemory.agenda??[]),...mobileAtlasRecords(nextMemory.graph,nextMemory)],cards};
}

export function questionNotificationRecord(journalID:string,date:string,jobID:string,now:string) {
  const questionCard=CompanionCardSchema.parse({schemaVersion:1,withdrawn:false,id:'journal_questions_'+date,
    kind:'checkin',title:'Günlüğünün soruları hazır',body:'Sorularına istediğin zaman dönebilirsin.',question:'',
    sourceIds:[journalID],nodeIds:[],basis:'Tamamlanmış günlük analizi',basisKey:jobID,fingerprint:jobID,
    notBefore:now,expiresAt:new Date(Date.parse(now)+7*86400000).toISOString(),createdAt:now,deadlineId:null,
    notification:{reason:'Kullanıcının etkinleştirdiği yeni soru bildirimi',basis:'user_preference',sourceQuote:''}});
  const questionContent=canonicalJson(canonicalJson(questionCard));
  return {key:'note:companion/cards/'+questionCard.id+'.md',kind:'note' as const,content:questionContent,hash:hash(questionContent)};
}
