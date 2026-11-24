import {z} from 'zod';
import {canonicalJson,hash} from './mobile-json.js';

export const QuestionPurpose=z.enum(['reminder_setup','reminder_consent','emotion_clarification','emotion_consent','personal_context']);
type QuestionLike={prompt:string;purpose?:unknown;reminder_proposal?:unknown;emotion_proposal?:unknown};
export const QUESTION_GOAL_GUIDANCE=`SORU ÖNCELİĞİ: Soruyu sorarken cevabın uygulamada neyi değiştireceğini belirle. Önce kullanıcının anlattığı gerçek bir planı/hatırlatmayı uygulanabilir hâle getiren eksik bilgiyi veya hazır bir önerinin açık onayını sor. Ardından duyguyu, hangi olayda oluştuğunu, zaman sırasını, karışık hisleri, iyi gelen eylemi veya benzer geçmiş günle farkı anlamak için gerçekten eksik olan ayrıntıyı sor.
Bu işlevsel ihtiyaçlar mevcut yazı, önceki cevaplar ve kayıtlı ayarlarla yeterince karşılanmışsa kalan sorularda kişinin tercihlerini, ihtiyaçlarını, ilişkilerini, alışkanlıklarını ve hedeflerini daha iyi tanımaya yarayan ilgili bilgi boşluklarına geç. Sırf işlevsel görünsün diye alarm veya duygu sorusu icat etme; zaten bilinen tarihi/saati, onaylanmış veya reddedilmiş aynı öneriyi, yanıtlanmış duygu sorusunu tekrar sorma. Önceki yanıt değişmişse hangi koşulun değiştiğini gerekçede belirt. Girdi değişmediyse bekleyen aynı soruyu başka kelimelerle yeniden üretme. inputChanged işaretli eski soru için yeni girdide hâlâ ihtiyaç varsa güncel koşullarla yeniden soru üret; geçersizleşmiş öneriyi taşıma.
Yazılı soru, eksik plan ayrıntısını veya duygusal deneyimi kullanıcının kendi sözüyle açsın. Evet/hayır sorusu tek, açık bir karar veya ayrımı sorsun; yönlendiren varsayım, çift soru veya her şeye olumlu cevap bekleyen kalıp kurma. rationale, cevabın hatırlatmayı, duygu akışını veya kişisel bağlamı nasıl geliştireceğini somutça anlatsın. Kaynak kullanıcının gerçek yazısı veya mevcut kaynaklı geçmiş olsun. 3 yazılı / 5 evet-hayır üst sınırdır; doldurulacak kota değildir.`;
export const QUESTION_PRIORITY_GUIDANCE=QUESTION_GOAL_GUIDANCE+`
Her soruda mümkünse purpose belirt: reminder_setup (eksik tarih/saat/tekrar/hatırlatma tercihi), reminder_consent (uygulanabilir hatırlatmaya onay), emotion_clarification (hissi/olayı/koşulu anlamak), emotion_consent (yalnız takvim duygu etiketine onay), personal_context (diğer ilgili kişisel bilgi).
reminder_consent yalnız boolean_questions içinde geçerli reminder_proposal ile; emotion_consent yalnız boolean_questions içinde emotion_proposal ile kullanılır. Duyguyu veya nedenini anlamaya çalışan evet/hayır sorusu emotion_clarification olsun; sırf duyguyla ilgili diye emotion_proposal ekleme. Eksik saat/tarih bilgisine sembolik onay isteme, yazılı olarak netleştir. purpose etiketi tek başına işlem yetkisi değildir.
AI zaten bir duygu etiketi kaydediyorsa sırf aynı etiketi yeniden onaylatmak için soru üretme. Gerçek belirsizlik hissin anlamı veya nedeni ise emotion_clarification sor; yalnız kullanıcının takvim etiketi tercihini değiştirmek/onaylamak gerekiyorsa emotion_consent kullan.
Soruları her iki cevap türünde de bu fayda sırasıyla ver. Günlükteki her cümleden yeni görev çıkarma. İşlevsel soru gerekmiyorsa doğrudan ilgili kişisel bilgi sorulabilir; yeni bilgi boşluğu da yoksa boş dizi döndür.`;

export function prioritizeQuestions<T extends QuestionLike>(items:T[]):T[] {
  const rank=(q:T)=>q.reminder_proposal?0:q.purpose==='reminder_setup'?1:q.purpose==='emotion_clarification'?2:
    q.emotion_proposal?3:q.purpose==='personal_context'?5:4;
  return items.map((q,index)=>({q,index})).sort((a,b)=>rank(a.q)-rank(b.q)||a.index-b.index).map(row=>row.q);
}

export function questionBasis(rawText:string,answers:string[]) {return hash(canonicalJson({rawText,answers}));}
function proposalKey(value:unknown):string|undefined {
  if(!value||typeof value!=='object')return;
  const p=value as {title?:unknown;schedule?:unknown};
  if(typeof p.title!=='string'||!p.schedule)return;
  return canonicalJson({title:p.title.normalize('NFKC').toLocaleLowerCase('tr').trim(),schedule:p.schedule});
}
function consentKey(q:{reminder_proposal?:unknown;emotion_proposal?:unknown}):string|undefined {
  const reminder=proposalKey(q.reminder_proposal);
  if(reminder)return 'reminder:'+reminder;
  if(q.emotion_proposal&&typeof q.emotion_proposal==='object') {
    const key=(q.emotion_proposal as {key?:unknown}).key;
    if(typeof key==='string')return 'emotion:'+key.toLocaleLowerCase('tr');
  }
}
/** Repeated decisions are suppressed only for unchanged personal input. New written input can reopen them. */
export function usefulQuestions<T extends QuestionLike>(items:T[],args:{basis:string;history:unknown[];agenda:Array<{title:string;schedule:unknown;status:string}>;pending?:QuestionLike[]}):T[] {
  const seen=new Set<string>();
  const resolved=new Set(args.history.flatMap(value=>{
    if(!value||typeof value!=='object')return [];
    const q=value as Record<string,unknown>,key=consentKey(q);
    return key&&q.kind==='boolean'&&q.question_basis===args.basis&&
      (q.answer_boolean===0||q.answer_boolean===1||typeof q.session_closed_at==='string')?[key]:[];
  }));
  const active=new Set(args.agenda.filter(e=>e.status==='active').flatMap(e=>proposalKey(e)?['reminder:'+proposalKey(e)!]:[]));
  const pending=new Set((args.pending??[]).flatMap(q=>consentKey(q)?[consentKey(q)!]:[]));
  return prioritizeQuestions(items).filter(q=>{
    const key=consentKey(q);
    if(!key)return true;
    if(seen.has(key)||resolved.has(key)||active.has(key)||pending.has(key))return false;
    seen.add(key);return true;
  });
}

export function questionPlanningState(history:unknown[],basis?:string) {
  return history.slice().reverse().slice(0,12).flatMap(value=>{
    if(!value||typeof value!=='object')return [];
    const q=value as Record<string,unknown>;
    if(typeof q.prompt!=='string')return [];
    const operational=q.reminder_proposal!=null||q.emotion_proposal!=null;
    return [{prompt:q.prompt,purpose:q.reminder_proposal?'reminder_consent':q.emotion_proposal?'emotion_consent':q.purpose,
      ...(basis?{inputChanged:q.question_basis!==basis}:{}),
      state:operational&&q.answer_boolean===1?'approved':operational&&q.answer_boolean===0?'declined':
        q.answer_boolean===0||q.answer_boolean===1||typeof q.answer_text==='string'&&q.answer_text.trim()?'answered':
          typeof q.session_closed_at==='string'?'skipped':'pending'}];
  });
}
