import type { FollowupTiming } from '../../shared/living-memory.js';

/** Deterministic safety checks on an existing analysis; never invents a schedule. */
export function groundedTiming(timing:FollowupTiming|null|undefined, hasQuote:(text:string)=>boolean, now:string):FollowupTiming|null {
  if (!timing || !hasQuote(timing.quote)) return null;
  const start=Date.parse(timing.not_before),end=Date.parse(timing.expires_at),current=Date.parse(now);
  if (!(start<end) || end<=current || end-start>7*86400000 || start>current+366*86400000) return null;
  const event=timing.event_at===null?null:Date.parse(timing.event_at);
  if(timing.intent==='before_event'&&(event===null||end>event))return null;
  if(timing.intent==='after_event'&&(event===null||start<event))return null;
  return {...timing,not_before:new Date(start).toISOString(),expires_at:new Date(end).toISOString(),event_at:event===null?null:new Date(event).toISOString()};
}

/** Quiet hours may delay a nudge, but cannot extend its useful time window. */
export function followupDelivery(timing:FollowupTiming, now:string) {
  let start=new Date(Math.max(Date.parse(timing.not_before),Date.parse(now)));
  const local=new Date(start.getTime()+3*3600000),hour=local.getUTCHours();
  if(hour<8||hour>=22){local.setUTCHours(hour<8?8:32,0,0,0);start=new Date(local.getTime()-3*3600000);}
  if(start.getTime()>=Date.parse(timing.expires_at))return null;
  return {notBefore:start.toISOString(),expiresAt:timing.expires_at};
}
