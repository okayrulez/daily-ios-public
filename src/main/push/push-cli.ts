import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { createAdminFirestore,resolveFirebaseAdminConfig } from '../firebase/admin-app.js';
import { ApnsSender } from './apns-sender.js';
import { FirebasePushWorker } from './firebase-push-worker.js';
export async function runPushWorker(env=process.env,once=process.argv.includes('--once')) {
  const required=(name:string)=>{const value=env[name]?.trim();if(!value)throw Error(`${name} gerekli.`);return value;};
  const sender=new ApnsSender({keyId:required('DAILYX_APNS_KEY_ID'),teamId:required('DAILYX_APNS_TEAM_ID'),keyPath:required('DAILYX_APNS_KEY_PATH'),bundleId:'com.okayrulez.daily'});
  const db=createAdminFirestore(env),uid=required('DAILYX_FIREBASE_UID');
  const worker=new FirebasePushWorker(db,uid,resolveFirebaseAdminConfig(env).projectId,sender);
  const heartbeat=async()=>{
    const key='note:companion/push-service.json';
    const content=JSON.stringify(JSON.stringify({bundleID:'com.okayrulez.daily',capabilities:['agenda-v1','agenda-explicit-hours','agenda-native-device-v1'],updatedAt:new Date().toISOString()}));
    const hash=(value:string)=>createHash('sha256').update(value).digest('hex');
    await db.collection('users').doc(uid).collection('dailyXRecords').doc(hash(key))
      .set({schemaVersion:1,key,kind:'note',content,hash:hash(content)});
  };
  let stopped=false;process.once('SIGINT',()=>{stopped=true;});process.once('SIGTERM',()=>{stopped=true;});
  do {try{const result=await worker.runOnce();await heartbeat();console.log(JSON.stringify(result));}catch{console.error('Bildirim kontrolü başarısız; kişisel içerik ve token günlüğe yazılmadı.');if(once)throw Error('Push kontrolü başarısız.');}if(!once&&!stopped)await new Promise(resolve=>setTimeout(resolve,300000));}while(!once&&!stopped);
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url)runPushWorker().catch(error=>{console.error(error.message);process.exitCode=1;});
