import {expect,it,vi} from 'vitest';
import {FirebasePushWorker} from '../src/main/push/firebase-push-worker';
import type {Firestore} from 'firebase-admin/firestore';
it('does not read journals, maps or cards when no phone is registered',async()=>{
 const get=vi.fn(async()=>({docs:[],size:0}));
 const devices={limit:vi.fn(()=>({get}))};
 const collection=vi.fn((name:string)=>{if(name==='dailyXPushDevices')return devices;throw Error('Unexpected record read: '+name);});
 const db={collection:()=>({doc:()=>({collection})})} as unknown as Firestore;
 const sender={send:vi.fn()};
 const result=await new FirebasePushWorker(db,'owner','project',sender,()=>new Date('2026-10-13T10:00:00Z')).runOnce();
 expect(result).toEqual({accepted:0,reason:'no_devices'});
 expect(collection).toHaveBeenCalledTimes(1);
 expect(sender.send).not.toHaveBeenCalled();
});
