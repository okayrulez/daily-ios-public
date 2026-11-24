import {readFileSync} from 'node:fs';
import {afterAll,beforeAll,it,expect} from 'vitest';
import {initializeTestEnvironment,assertFails,assertSucceeds,type RulesTestEnvironment} from '@firebase/rules-unit-testing';
import {doc,setDoc,getDoc,runTransaction} from 'firebase/firestore';
import {canonicalJson,hash} from '../../src/shared/mobile-json.js';
let env:RulesTestEnvironment;
beforeAll(async()=>{
  env=await initializeTestEnvironment({projectId:'demo-dailyx',firestore:{host:'127.0.0.1',port:8089,
    rules:readFileSync('../firestore.rules','utf8')}});
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
const record=(text:string)=>{const content=canonicalJson({text});return {
  schemaVersion:1,key:'journal:2026-10-01',kind:'journal',content,hash:hash(content)};};
it('saves a journal and its previous version using the shared production rules',async()=>{
  const db=env.authenticatedContext('upgrade').firestore(),r=record('kept draft');
  const ref=doc(db,'users/upgrade/dailyXRecords/'+hash(r.key));
  await assertSucceeds(setDoc(ref,r));
  await assertSucceeds(runTransaction(db,async tx=>{
    const old=await tx.get(ref);expect(old.data()).toEqual(r);
    tx.set(doc(db,ref.path+'/versions/'+r.hash),r);tx.set(ref,record('saved again'));
  }));
  expect((await getDoc(ref)).data()).toEqual(record('saved again'));
});
it('preserves legacy owner access while rejecting other accounts and unauthenticated clients',async()=>{
  const db=env.authenticatedContext('legacy').firestore(),r=record('legacy');
  const legacy='users/legacy/workspaceRecords/'+hash(r.key),dailyx='users/legacy/dailyXRecords/'+hash(r.key);
  await assertSucceeds(setDoc(doc(db,legacy),r));
  await assertSucceeds(setDoc(doc(db,dailyx),r));
  for(const denied of [env.authenticatedContext('stranger').firestore(),env.unauthenticatedContext().firestore()]) {
    for(const path of [legacy,dailyx]) {
      await assertFails(getDoc(doc(denied,path)));await assertFails(setDoc(doc(denied,path),r));
    }
  }
});

it('recovers a missing journal atomically without inventing a previous server version',async()=>{
  const db=env.authenticatedContext('recovery-shared').firestore();
  const recovered=record('Recovered journal with its answers');
  const ref=doc(db,'users/recovery-shared/dailyXRecords/'+hash(recovered.key));
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
