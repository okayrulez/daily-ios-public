/** Conservative lexical duplicate suppression; distinct times and negation remain distinct. */
export function questionKey(text:string):string {
 return text.normalize('NFKC').toLocaleLowerCase('tr-TR').replace(/[^\p{L}\p{N}]+/gu,' ').trim();
}
export function novelQuestions<T extends {prompt:string;reminder_proposal?:unknown}>(items:T[],known:string[]):T[] {
 const seen=new Set(known.map(questionKey));
 return items.filter(q=>{
  const key=questionKey(q.prompt);
  // Reminder consent must remain specific to the actual proposal, not just a generic prompt.
  if(q.reminder_proposal)return true;
  if(!key||seen.has(key))return false;
  seen.add(key);return true;
 });
}
