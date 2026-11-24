import fs from 'node:fs';
import { createPrivateKey, sign } from 'node:crypto';
import { connect } from 'node:http2';
import type { PushEnvelope,PushResult,PushSender } from '../../shared/push.js';
export function apnsPayload(input:PushEnvelope) {
  const alert = /^journal_questions_\d{4}-\d{2}-\d{2}$/.test(input.cardId)
    ? { title: 'Günlüğünün soruları hazır', body: 'Sorularını görmek için dAIly’yi aç.' }
    : input.kind === 'deadline' || input.kind === 'pinned'
      ? { title: 'Hatırlatma', body: 'Ayrıntıları görmek için dAIly’yi aç.' }
      : input.hasQuestion || input.kind === 'followup'
        ? { title: 'Takip sorusu', body: 'Soruyu görmek için dAIly’yi aç.' }
        : { title: 'Günün önerisi', body: 'Öneriyi görmek için dAIly’yi aç.' };
  return { aps: { alert, sound: 'default' }, companionScope: input.scope, companionCard: input.cardId };
}
export function classifyApns(status:number,reason:string):PushResult {
  return {accepted:status===200,retryable:status===0||status===429||status>=500,invalidToken:status===410||reason==='BadDeviceToken',code:status===200?'accepted':reason.replace(/[^A-Za-z0-9_]/g,'').slice(0,80)||`http_${status}`};
}
export class ApnsSender implements PushSender {
  private readonly key:ReturnType<typeof createPrivateKey>;
  private jwt=''; private signedAt=0;
  constructor(private readonly config:{keyId:string;teamId:string;keyPath:string;bundleId:string}) {
    if(!/^[A-Z0-9]{10}$/.test(config.keyId)||!/^[A-Z0-9]{10}$/.test(config.teamId)||!/^com\.[A-Za-z0-9.-]+$/.test(config.bundleId))throw Error('APNs kimlik yapılandırması geçersiz.');
    this.key=createPrivateKey(fs.readFileSync(config.keyPath));
    if(this.key.asymmetricKeyType!=='ec'||this.key.asymmetricKeyDetails?.namedCurve!=='prime256v1')throw Error('APNs P-256 anahtarı gerekir.');
  }
  private authorization() {
    const now=Math.floor(Date.now()/1000);
    if(!this.jwt||now-this.signedAt>=3000){const head=Buffer.from(JSON.stringify({alg:'ES256',kid:this.config.keyId})).toString('base64url');const body=Buffer.from(JSON.stringify({iss:this.config.teamId,iat:now})).toString('base64url');const value=`${head}.${body}`;this.jwt=`${value}.${sign('sha256',Buffer.from(value),{key:this.key,dsaEncoding:'ieee-p1363'}).toString('base64url')}`;this.signedAt=now;}
    return this.jwt;
  }
  send(input:PushEnvelope):Promise<PushResult> {
    if(!/^[a-f0-9]{32,256}$/.test(input.token)||!/^[a-f0-9]{64}$/.test(input.deliveryId))throw Error('Geçersiz bildirim hedefi.');
    return new Promise(resolve=>{
      const client=connect(input.environment==='development'?'https://api.sandbox.push.apple.com':'https://api.push.apple.com');
      let finished=false;const finish=(result:PushResult)=>{if(finished)return;finished=true;clearTimeout(timer);client.destroy();resolve(result);};
      const timer=setTimeout(()=>finish({accepted:false,retryable:true,invalidToken:false,code:'timeout'}),15000);
      client.on('error',()=>finish({accepted:false,retryable:true,invalidToken:false,code:'connection_error'}));
      const request=client.request({':method':'POST',':path':`/3/device/${input.token}`,authorization:`bearer ${this.authorization()}`,'apns-topic':this.config.bundleId,'apns-push-type':'alert','apns-priority':'10','apns-expiration':String(Math.floor(Date.parse(input.expiresAt)/1000)),'apns-collapse-id':input.deliveryId});
      let status=0,body='';request.on('response',headers=>{status=Number(headers[':status']);});request.setEncoding('utf8');request.on('data',chunk=>{body=(body+chunk).slice(0,4096);});request.on('error',()=>finish({accepted:false,retryable:true,invalidToken:false,code:'stream_error'}));request.on('end',()=>{let reason='';try{reason=JSON.parse(body).reason??'';}catch{}finish(classifyApns(status,reason));});request.end(JSON.stringify(apnsPayload(input)));
    });
  }
}
