import {expect,it} from 'vitest';
import {invoke,invokeChecked} from '../src/shared/mobile-analysis-core.js';
import {analysis,snapshot} from './fixtures.js';
import {mobileAtlasRecords} from '../src/main/memory/mobile-atlas.js';
const call=(command:string,input:unknown)=>JSON.parse(invoke(command,JSON.stringify(input)));
it('prepares one full journal format repair for malformed JSON using the canonical contract',()=>{
 const args={rawText:'Bugün yürüdüm.',answers:['İyi geldi.'],output:'```json\n{}\n```',errorCode:'invalid_json'};
 const repair=call('prepareJournalRepair',args),input=JSON.parse(repair.input[0].content);
 expect(input.outputSchema.required).toContain('emotional_memory');
 expect(input.userAnswers).toEqual(args.answers);
 expect(repair.instructions).toContain('Tek JSON');
 expect(JSON.parse(invokeChecked('validateJournal',JSON.stringify({rawText:args.rawText,result:args.output}))).error.code).toBe('invalid_json');
 expect(call('validateJournal',{rawText:args.rawText,result:JSON.stringify(analysis())}).reflection).toBe(analysis().reflection);
 expect(()=>call('prepareJournalRepair',{...args,errorCode:'unsupported_source_quote'})).toThrow();
});
it('keeps final reflection format repair on the compact contract with the original evidence',()=>{
 const args={rawText:'Bugün yürüdüm.',answers:['İyi geldi.'],output:'```json\n{}\n```',errorCode:'invalid_json'};
 const standard=invoke('prepareJournalRepair',JSON.stringify(args));
 const final=invoke('prepareJournalRepair',JSON.stringify({...args,finishingQuestionSession:true}));
 const repair=JSON.parse(final),input=JSON.parse(repair.input[0].content);
 expect(Buffer.byteLength(final)).toBeLessThan(Buffer.byteLength(standard)*0.65);
 expect(input.userText).toBe(args.rawText);
 expect(input.userAnswers).toEqual(args.answers);
 expect(input.previousOutput).toBe(args.output);
 expect(input.outputSchema.properties.open_questions.maxItems).toBe(0);
 expect(input.outputSchema.properties.boolean_questions.items.anyOf).toHaveLength(2);
});
it('keeps long current note parts distinct from repeated evidence and dated history',()=>{
 const graph=snapshot().graph;graph.nodes[0].description='uzun not '.repeat(1100)+'SON';
 graph.nodes[0].evidence[0].sourceKind='journal';
 const records=mobileAtlasRecords(graph),pages=records.filter(r=>/-notes-/.test(r.key)).flatMap(r=>JSON.parse(JSON.parse(r.content)).items);
 const parts=pages.filter(p=>p.nodeId==='node-one'&&p.kind==='description');
 expect(parts.length).toBeGreaterThan(1);
 expect(new Set(parts.map(p=>p.contentID)).size).toBe(1);
 expect(parts.map(p=>p.part)).toEqual(parts.map((_,i)=>i));
 expect(parts.map(p=>p.text).join('')).toBe(graph.nodes[0].description);
 const evidence=pages.find(p=>p.nodeId==='node-one'&&p.kind==='observation');
 expect(evidence.contentID).not.toBe(parts[0].contentID);
 expect(evidence.sourceKind).toBe('journal');
 expect(parts[0]).not.toHaveProperty('sourceKind');
});

it('repairs only unsupported quotes, allowing exact answer evidence and rejecting invented or unrelated fields',()=>{
 const candidate = analysis();
 candidate.living_memory.notes[0].quote = 'model paraphrase';
 const args = {rawText:'Bugün yürüdüm.',answers:['Biraz dinlendim.'],output:JSON.stringify(candidate)};
 const request = call('prepareJournalQuoteRepair',args);
 expect(JSON.parse(request.input[0].content).items.map((v:{kind:string})=>v.kind)).toEqual(['note']);
 const patch=(value:unknown)=>call('finishJournalQuoteRepair',{...args,repair:JSON.stringify(value)});
 for(const invalid of [{quotes:['invented']},{quotes:[]},{quotes:['yürüdüm.'],reflection:'unauthorized edit'}]){
   expect(()=>patch(invalid)).toThrow();
 }
 const expected=structuredClone(candidate);
 expected.living_memory.notes[0].quote='Biraz dinlendim.';
 const corrected=patch({quotes:['Biraz dinlendim.']});
 expect(corrected).toEqual(expected);
 expect(call('validateJournal',{rawText:args.rawText,answers:args.answers,result:corrected})).toEqual(expected);
});
it('splits an appended entry at its verified UTF-16 boundary without repeating emoji or text',()=>{
 const earlier='Öğlen yürüdüm 🧑🏽‍🚀.', appended=' Akşam eve döndüm.';
 const source={journalId:'j',localDate:'2026-09-30',workContext:'',rawText:earlier+appended,
   previousDayReflection:'Önceki yorum',previousTextLength:earlier.length};
 const draft=call('prepareJournal',source).input[0].content;
 expect(draft.split(earlier)).toHaveLength(2);
 expect(draft.split(appended)).toHaveLength(2);
 const final=JSON.parse(call('prepareJournal',{...source,finishingQuestionSession:true}).input[0].content);
 expect(final).toMatchObject({earlierUserText:earlier,appendedUserText:appended,previousDayReflection:source.previousDayReflection});
 expect(final).not.toHaveProperty('userText');
 expect(()=>call('prepareJournal',{...source,previousTextLength:1000})).toThrow();
});

it('requires journal-only evidence for an emotion consent while allowing answers for helpful actions',()=>{
 const rawText='Bugün yürüdüm.';
 const answer='Ara vermek iyi geldi.';
 const candidate={...analysis(),emotional_memory:{observations:[],helpful:[{action:'Ara vermek',quote:'incorrect'}]},
   boolean_questions:[{prompt:'Etiketlensin mi?',rationale:'Duygu',source_ref:'j',purpose:'emotion_consent',
     emotion_proposal:{key:'calm',label:'Sakin',quote:'incorrect'}}]};
 const args={rawText,answers:[answer],output:JSON.stringify(candidate)};
 const prep=JSON.parse(call('prepareJournalQuoteRepair',args).input[0].content);
 expect(prep.items.map((v:{journalOnly:boolean})=>v.journalOnly)).toEqual([false,true]);
 const finish=(quotes:string[])=>call('finishJournalQuoteRepair',{...args,repair:JSON.stringify({quotes})});
 expect(()=>finish([answer,answer])).toThrow('Unsupported source quote');
 expect(call('validateJournal',{rawText,answers:[answer],result:finish([answer,rawText])}).boolean_questions[0].emotion_proposal.quote).toBe(rawText);
});


it('omits only unsupported independent observations and keeps supported records intact',()=>{
 const result=analysis();
 const supportedNote=result.living_memory.notes[0];
 const retained={key:'calm',label:'Sakin',event:'Yürüyüş',quote:'Bugün yürüdüm.',sequence:0};
 const candidate={...result,living_memory:{...result.living_memory,notes:[supportedNote,
   {...supportedNote,key:'invalid-note',quote:'unfounded note'}]},
   emotional_memory:{observations:[{...retained,key:'anger',quote:'unfounded emotion'},retained],helpful:[]}};
 const rawText='Bugün yürüdüm.';
 const patched=call('finishJournalQuoteRepair',{rawText,answers:[],output:JSON.stringify(candidate),
   repair:JSON.stringify({quotes:[null,null]})});
 const verified=call('validateJournal',{rawText,result:patched});
 expect(verified).toEqual({...result,emotional_memory:{observations:[retained],helpful:[]}});
});

it('fails the whole repair if a null quote would orphan a reference or change a deadline or consent',()=>{
 const result=analysis(), rawText='Bugün yürüdüm.';
 const note=result.living_memory.notes[0], bad={...note,key:'unsupported',quote:'unfounded'};
 const finish=(candidate:unknown,quotes:(string|null)[])=>call('finishJournalQuoteRepair',{
   rawText,answers:[],output:JSON.stringify(candidate),repair:JSON.stringify({quotes})});
 for(const noteChange of [{existing_node_id:'saved-node'},{status:'retracted'}]){
   expect(()=>finish({...result,living_memory:{...result.living_memory,notes:[{...bad,...noteChange}]}},[null])).toThrow();
 }
 expect(()=>finish({...result,living_memory:{...result.living_memory,notes:[bad,{...note,related_keys:[bad.key]}]}},[null])).toThrow();
 const deadline={title:'Tarih',due_date:'2026-11-21',quote:'unfounded deadline'};
 expect(()=>finish({...result,living_memory:{...result.living_memory,notes:[bad],deadlines:[deadline]}},[null,null])).toThrow();
 const proposal={key:'calm',label:'Huzur',quote:'unfounded consent'};
 expect(()=>finish({...result,boolean_questions:[{...result.boolean_questions[0],purpose:'emotion_consent',
   emotion_proposal:proposal}]},[null])).toThrow();
});
