import {z} from 'zod';
import {validateAnalysis} from './mobile-pipeline.js';
import {canonicalJson} from './mobile-json.js';
import {mergeMapSummaryProposals} from './map-metadata.js';
import {prioritizeQuestions} from './question-policy.js';

/** All segments are validated independently, then combined locally; no source text is discarded. */
export function mergeJournalParts(value:unknown) {
  const input=z.object({parts:z.array(z.object({rawText:z.string(),result:z.unknown()})).min(1),answers:z.array(z.string())}).parse(value);
  const parts=input.parts.map(p=>validateAnalysis(p.rawText,p.result,input.answers));
  const unique=<T>(rows:T[])=>[...new Map(rows.map(row=>[canonicalJson(row),row])).values()];
  const last=parts.at(-1)!;
  let sequenceOffset=0;
  const observations=parts.flatMap((part,index)=>{
    // Sequence is known within a segment; segment order alone is not event chronology.
    const rows=(part.emotional_memory?.observations??[]).map(o=>({...o,sequence:o.sequence+sequenceOffset,
      ...(parts.length>1?{order_group:'segment-'+index}:{} )}));
    if(rows.length)sequenceOffset=Math.max(...rows.map(o=>o.sequence))+1;
    return rows;
  });
  const merged={...last,
    reflection:parts.map((p,i)=>`${parts.length>1?`Bölüm ${i+1}\n`:''}${p.reflection}`).join('\n\n'),
    confidence:parts.some(p=>p.confidence==='low')?'low':parts.some(p=>p.confidence==='medium')?'medium':'high',
    living_memory:{...last.living_memory!,summary:parts.map(p=>p.living_memory!.summary).join('\n\n').slice(0,6000),
      map_summaries:mergeMapSummaryProposals(parts.flatMap(p=>p.living_memory?.map_summaries??[])),
      notes:unique(parts.flatMap(p=>p.living_memory!.notes)),
      deadlines:unique(parts.flatMap(p=>p.living_memory!.deadlines)),
      followups:unique(parts.flatMap(p=>p.living_memory!.followups??[]))},
    emotional_memory:{observations:unique(observations),helpful:unique(parts.flatMap(p=>p.emotional_memory?.helpful??[]))},
    connections:unique(parts.flatMap(p=>p.connections)),
    open_questions:prioritizeQuestions(unique(parts.flatMap(p=>p.open_questions))).slice(0,3),
    boolean_questions:prioritizeQuestions(unique(parts.flatMap(p=>p.boolean_questions))).slice(0,5),
    ...Object.fromEntries(['emotions','events','memories','people','patterns','values','perspectives','profile_notes','inferences']
      .map(key=>[key,unique(parts.flatMap(p=>(p as unknown as Record<string,unknown[]>)[key]))])),
  };
  return validateAnalysis(input.parts.map(p=>p.rawText).join(''),merged,input.answers);
}
