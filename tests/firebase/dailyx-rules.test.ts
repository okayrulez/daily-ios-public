import {readFileSync} from 'node:fs';
import {afterAll,beforeAll,it,expect} from 'vitest';
import {initializeTestEnvironment,assertFails,assertSucceeds,type RulesTestEnvironment} from '@firebase/rules-unit-testing';
import {doc,setDoc,getDoc,runTransaction,deleteDoc} from 'firebase/firestore';
import {canonicalJson,hash} from '../../src/shared/mobile-json.js';
let env:RulesTestEnvironment;
beforeAll(async()=>{
  // Explicit emulator host: cannot silently fall back to production.
  env=await initializeTestEnvironment({projectId:'demo-dailyx',firestore:{host:'127.0.0.1',port:8089,
    rules:readFileSync('firestore.rules','utf8')}});
});
afterAll(async()=>{await env.cleanup();});
it.each(['analysisPrompts','taskPrompts'])('reads %s after sign-in but denies client writes and anonymous reads',async name=>{
  const path='dailyXConfig/'+name;
  const config={schemaVersion:1,revision:'v1',enabled:true,instructions:{journal:'Example'}};
  await env.withSecurityRulesDisabled(async context=>{await setDoc(doc(context.firestore(),path),config);});
  const signed=env.authenticatedContext('prompt-reader').firestore();
  expect((await assertSucceeds(getDoc(doc(signed,path)))).data()).toEqual(config);
  await assertFails(setDoc(doc(signed,path),config));
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(),path)));
  await assertFails(getDoc(doc(signed,'dailyXConfig/other')));
});
const record=(key:string,value:unknown)=>{
  const content=canonicalJson(value);
  return {schemaVersion:1,key,kind:key.split(':')[0],content,hash:hash(content)};
};
it('lets only the owner erase workspace data and historical versions for reset',async()=>{
  const owner=env.authenticatedContext('reset-owner').firestore();
  const other=env.authenticatedContext('reset-other').firestore();
  const anonymous=env.unauthenticatedContext().firestore();
  const r=record('journal:2026-11-15',{text:'Reset this workspace'});
  const parent='users/reset-owner/dailyXRecords/'+hash(r.key);
  const paths=[parent,parent+'/versions/'+r.hash,
    'users/reset-owner/dailyXRequests/job','users/reset-owner/dailyXPushDeliveries/notice',
    'users/reset-owner/dailyXPushBudgets/day'];
  await env.withSecurityRulesDisabled(async c=>{
    for(const path of paths) await setDoc(doc(c.firestore(),path),r);
  });
  for(const path of paths){
    await assertFails(deleteDoc(doc(other,path)));
    await assertFails(deleteDoc(doc(anonymous,path)));
  }
  for(const path of [...paths].reverse()) await assertSucceeds(deleteDoc(doc(owner,path)));
  for(const path of paths) expect((await getDoc(doc(owner,path))).exists()).toBe(false);
});
it('separates owners and denies writes to the original dAIly namespace',async()=>{
  const db=env.authenticatedContext('alice').firestore(),other=env.authenticatedContext('bob').firestore();
  const r=record('journal:2026-09-30',{example:true}),path='users/alice/dailyXRecords/'+hash(r.key);
  await assertSucceeds(setDoc(doc(db,path),r));
  await assertFails(getDoc(doc(other,path)));
  await assertFails(setDoc(doc(other,path),r));
  await assertFails(setDoc(doc(db,'users/alice/workspaceRecords/'+hash(r.key)),r));
  await assertFails(setDoc(doc(env.unauthenticatedContext().firestore(),path),r));
});
it('allows atomic previous-version preservation but rejects fabricated history',async()=>{
  const db=env.authenticatedContext('history').firestore(),key='journal:2026-09-29';
  const before=record(key,{text:'before'}),after=record(key,{text:'after'});
  const ref=doc(db,'users/history/dailyXRecords/'+hash(key));
  await setDoc(ref,before);
  await assertSucceeds(runTransaction(db,async tx=>{
    const current=await tx.get(ref);expect(current.data()).toEqual(before);
    tx.set(doc(db,ref.path+'/versions/'+before.hash),before);tx.set(ref,after);
  }));
  await assertFails(setDoc(doc(db,ref.path+'/versions/'+after.hash),before));
});
it('keeps receipts immutable and service readiness admin-authored',async()=>{
  const db=env.authenticatedContext('receipt').firestore();
  const r=record('note:dailyx/receipts/'+hash('job'),'receipt');
  const ref=doc(db,'users/receipt/dailyXRecords/'+hash(r.key));
  await assertSucceeds(setDoc(ref,r));
  await assertSucceeds(setDoc(ref,r));
  await assertFails(setDoc(ref,record(r.key,'different')));
  const heartbeat=record('note:companion/push-service.json','{}');
  await assertFails(setDoc(doc(db,'users/receipt/dailyXRecords/'+hash(heartbeat.key)),heartbeat));
  await assertFails(setDoc(doc(db,'users/receipt/dailyXPushDeliveries/fake'),{status:'sent'}));
});
it('only registers DailyX devices under their owner',async()=>{
  const db=env.authenticatedContext('phone').firestore(),data={schemaVersion:1,transport:'apns',
    token:'a'.repeat(64),environment:'production',enabled:true,updatedAt:'2026-09-30T12:00:00Z',expiresAt:'2026-10-07T12:00:00Z'};
  await assertSucceeds(setDoc(doc(db,'users/phone/dailyXPushDevices/one'),data));
  await assertFails(setDoc(doc(db,'users/other/dailyXPushDevices/one'),data));
  await assertFails(setDoc(doc(db,'users/phone/dailyXPushDevices/one'),{...data,token:'bad'}));
});

it('recovers a missing journal atomically without inventing a previous server version',async()=>{
  const db=env.authenticatedContext('recovery').firestore();
  const recovered=record('journal:2026-10-01',{text:'Recovered journal',questions:[{answer_boolean:0}]});
  const ref=doc(db,'users/recovery/dailyXRecords/'+hash(recovered.key));
  expect((await getDoc(ref)).exists()).toBe(false);
  expect((await getDoc(doc(db,ref.path+'/versions/'+recovered.hash))).exists()).toBe(false);
  await assertSucceeds(runTransaction(db,async tx=>{
    const current=await tx.get(ref);
    if(current.exists()) throw new Error('Source changed');
    tx.set(ref,recovered);
  }));
  expect((await getDoc(ref)).data()).toEqual(recovered);
  expect((await getDoc(doc(db,ref.path+'/versions/'+recovered.hash))).exists()).toBe(false);
});
