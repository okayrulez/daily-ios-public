import {expect,it} from 'vitest';
import {groundedTiming,followupDelivery} from '../src/main/memory/followup-timing';
import type {FollowupTiming} from '../src/shared/living-memory';
const now='2026-09-25T08:00:00.000Z';
const timing:FollowupTiming={not_before:'2026-09-26T19:30:00+03:00',expires_at:'2026-09-26T21:30:00+03:00',event_at:'2026-09-26T15:00:00+03:00',intent:'after_event',basis:'inferred',reason:'Görüşme sonrası',quote:'Yarın 15:00 görüşmem var.'};
it('keeps the grounded chosen time instead of replacing it with a global hour',()=>{
 const valid=groundedTiming(timing,()=>true,now)!;expect(followupDelivery(valid,now)).toEqual({notBefore:'2026-09-26T16:30:00.000Z',expiresAt:'2026-09-26T18:30:00.000Z'});
});
it('rejects result questions before the event and preparation reminders after it',()=>{
 expect(groundedTiming({...timing,not_before:'2026-09-26T10:00:00+03:00'},()=>true,now)).toBeNull();expect(groundedTiming({...timing,intent:'before_event'},()=>true,now)).toBeNull();
});
it('refuses unsupported schedules, expired windows and unbounded reminders',()=>{
 expect(groundedTiming(timing,()=>false,now)).toBeNull();expect(groundedTiming(timing,()=>true,'2026-09-27T08:00:00Z')).toBeNull();expect(groundedTiming({...timing,expires_at:'2027-09-26T21:30:00+03:00'},()=>true,now)).toBeNull();
});
it('respects quiet hours only while the contextual window still fits',()=>{
 const night={...timing,not_before:'2026-09-26T23:00:00+03:00',expires_at:'2026-09-27T09:00:00+03:00'};expect(followupDelivery(night,now)?.notBefore).toBe('2026-09-27T05:00:00.000Z');expect(followupDelivery({...night,expires_at:'2026-09-27T07:00:00+03:00'},now)).toBeNull();
});
