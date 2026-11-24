import {expect,it} from 'vitest';
import {invoke,invokeChecked} from '../src/shared/mobile-analysis-core.js';
import {hash} from '../src/shared/mobile-json.js';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
const call=(command:string,input:unknown)=>JSON.parse(invoke(command,JSON.stringify(input)));
const journal={entry:{id:'j',local_date:'2026-11-17',raw_text:'Bugün yürüyüş iyi geldi.',content_hash:hash('Bugün yürüyüş iyi geldi.'),saved_at:'2026-11-17T08:00:00Z',analysis_status:'pending',analysis_error:null},analyses:[],questions:[]};
it('exposes routing cross-field rules to the model and gives private, specific rejection codes',()=>{
 const prepared=call('prepareTask',{journal});
 expect(prepared.instructions).toContain('questions boş dizi');
 const result=JSON.parse(invokeChecked('validateTaskDecision',JSON.stringify({action:'diary',goal:'',reply:'',questions:['Gizli günlük metni?']})));
 expect(result.error.issues).toContain('custom:questions:task_route_unexpected_questions');
 expect(JSON.stringify(result)).not.toContain('Gizli');
});
it('prepares a separate small routing repair with the existing schema instead of the journal/map contract',()=>{
 const prepared=call('prepareTask',{journal});
 const repair=call('prepareTaskRepair',{prepared,output:'{"action":"diary","goal":"","reply":"","questions":["Nasıl?"]}',command:'validateTaskDecision',errorCode:'schema_validation',issues:['custom:questions:task_route_unexpected_questions']});
 expect(repair.webResearch).toBe(false);
 const input=JSON.parse(repair.input[0].content);
 expect(input.outputSchema).toEqual(JSON.parse(prepared.input[0].content).outputSchema);
 expect(input.request.userText).toBe(journal.entry.raw_text);
 expect(repair.instructions).toContain('Yeni araştırma');
 expect(repair.instructions).toContain('questions boş dizi');
 expect(JSON.stringify(input)).not.toContain('living_memory');
});
it('identifies each missing routing rule without exporting user content',()=>{
 for(const [input,issue] of [
   [{action:'respond',goal:'',reply:'',questions:[]},'custom:goal:task_route_missing_goal'],
   [{action:'clarify',goal:'Bildirim',reply:'',questions:[]},'custom:questions:task_route_missing_clarification'],
 ] as const){
   const result=JSON.parse(invokeChecked('validateTaskDecision',JSON.stringify(input)));
   expect(result.error.issues).toContain(issue);
 }
});
it('runs separate routing repair and validation in the actual iOS JavaScript bundle',()=>{
 const sandbox:Record<string,any>={};
 runInNewContext(readFileSync(new URL('../ios/DailyCore/Resources/dailyx-analysis.js',import.meta.url),'utf8'),sandbox,{timeout:5000});
 const bundled=(command:string,value:unknown)=>JSON.parse(sandbox.DailyXAnalysis.invoke(command,JSON.stringify(value)));
 const prepared=bundled('prepareTask',{journal});
 const output=JSON.stringify({action:'diary',goal:'',reply:'',questions:['Nasıl?']});
 expect(()=>bundled('validateTaskDecision',JSON.parse(output))).toThrow();
 expect(bundled('prepareTaskRepair',{prepared,output,command:'validateTaskDecision',errorCode:'schema_validation',issues:[]}).webResearch).toBe(false);
 expect(bundled('validateTaskDecision',{action:'diary',goal:'',reply:'',questions:[]})).toEqual({action:'diary',goal:'',reply:'',questions:[]});
});
it('repairs execution formatting without a second web search or replacing search evidence',()=>{
 const prepared=call('prepareTaskExecution',{journal,decision:{action:'research',goal:'Araştır',reply:'',questions:[]}});
 const repair=call('prepareTaskRepair',{prepared,output:'```json\n{}\n```',command:'finishTask',errorCode:'invalid_json',issues:[]});
 expect(repair.webResearch).toBe(false);
 expect(JSON.parse(repair.input[0].content).outputSchema).toEqual(JSON.parse(prepared.input[0].content).outputSchema);
 for(const issues of [['custom:root:task_unknown_citation'],['custom:root:task_missing_operations']]){
   expect(()=>call('prepareTaskRepair',{prepared,output:'{}',command:'finishTask',errorCode:'schema_validation',issues})).toThrow();
 }
 expect(()=>call('prepareTaskRepair',{prepared,output:'{}',command:'finishTask',errorCode:'unsupported_action_quote',issues:[]})).toThrow();
});
