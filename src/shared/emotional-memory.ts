import { z } from 'zod';
import {canonicalJson,hash} from './mobile-json.js';

/** Stable meaning is separate from the user's chosen emoji and display colour. */
export const EmotionObservationSchema = z.object({
  key: z.string().min(1).max(100),
  label: z.string().min(1).max(100),
  definition: z.string().max(500).optional(),
  intensity: z.number().int().min(1).max(5).nullable().optional(),
  event: z.string().max(1000),
  quote: z.string().min(1).max(2000),
  sequence: z.number().int().nonnegative(),
  context_key: z.string().regex(/^[a-z][a-z0-9-]{0,99}$/).optional(),
  context_label: z.string().min(1).max(180).optional(),
  conditions: z.array(z.string().min(1).max(180)).max(8).optional(),
  topic_path: z.array(z.string().min(1).max(180)).max(8).optional(),
  kind: z.enum(['emotion','energy']).optional(),
  order_basis: z.enum(['stated','unknown']).optional(),
  order_group: z.string().max(100).optional(),
}).strict();

export const EmotionObservationOverridesSchema=z.object({source_hash:z.string(),edits:z.array(z.object({
  observation_id:z.string(),original_key:z.string(),quote:z.string(),sequence:z.number().int().nonnegative(),
  choices:z.array(z.string().min(1).max(100)).max(20),
}).strict())}).strict();
export function emotionObservationID(o:{key:string;quote:string;sequence:number}) {
  return hash(canonicalJson([canonicalEmotionKey(o.key),o.quote,o.sequence]));
}
/** Corrections replace just their grounded observation, preserving every other event and the AI original. */
export function correctedEmotionObservations(memory:EmotionalMemory, journal:{entry:{content_hash:string};emotion_observation_overrides?:unknown}) {
  const parsed=EmotionObservationOverridesSchema.safeParse(journal.emotion_observation_overrides);
  const edits=parsed.success&&parsed.data.source_hash===journal.entry.content_hash?parsed.data.edits:[];
  return memory.observations.flatMap(o=>{
    const candidates=edits.filter(e=>canonicalEmotionKey(e.original_key)===canonicalEmotionKey(o.key)&&e.quote===o.quote);
    const uniqueQuote=memory.observations.filter(item=>canonicalEmotionKey(item.key)===canonicalEmotionKey(o.key)&&item.quote===o.quote).length===1;
    const edit=[...candidates].reverse().find(e=>e.observation_id===emotionObservationID(o)&&e.sequence===o.sequence)
      ??(uniqueQuote&&candidates.length===1?candidates[0]:undefined);
    return edit?[...new Set(edit.choices.map(canonicalEmotionKey))].map(key=>({...o,key,
      label:memory.observations.find(item=>canonicalEmotionKey(item.key)===key)?.label??emotionTitle(key),
      intensity:key===canonicalEmotionKey(o.key)?o.intensity:null,
      kind:key===canonicalEmotionKey(o.key)?o.kind:(key==='fatigue'?'energy' as const:'emotion' as const)})): [o];
  });
}
export function emotionTitle(key:string) {
  return ({joy:'Neşe',calm:'Huzur',relief:'Rahatlama',excitement:'Heyecan',anxiety:'Kaygı',tension:'Gerilim',
    sadness:'Üzüntü',anger:'Öfke',loneliness:'Yalnızlık',hope:'Umut',pride:'Gurur',fatigue:'Yorgunluk'} as Record<string,string>)[key]??key;
}

export const EmotionalMemorySchema = z.object({
  observations: z.array(EmotionObservationSchema),
  helpful: z.array(z.object({
    action: z.string().min(1).max(1000),
    quote: z.string().min(1).max(2000),
  }).strict()),
}).strict();
export type EmotionalMemory = z.infer<typeof EmotionalMemorySchema>;

export const EMOTION_GUIDANCE = [
  'Duygu değerlendirmesi aynı günlük analizinde otomatik yapılır. emotional_memory alanını üret.',
  'observations her biri key (kararlı ASCII), label, definition (yeni ad için kısa anlam), intensity (1-5 veya null), event, quote ve sequence içerir. Yoğunluk metinde desteklenmiyorsa null; zorunlu puan uydurma.',
  'Olay merkezli yaz: context_key aynı deneyim için tekrar kullanılabilen kararlı ASCII anahtarı (ör. work-presentation); context_label deneyimin adı; topic_path mevcut ilgili haritanın yolu; kind emotion veya energy; order_basis stated veya unknown. Önceki kaynaklarda aynı deneyim için kullanılan context_key varsa koru. Duygu adı veya tek bir ortak kelime aynı deneyim demek değildir.',
  'conditions yalnız metinde belirtilen koşullardır (ör. hazırlık eksikliği, yüksek beklenti); desteklenmeyen koşul ekleme. Aynı koşulu sonraki günlerde aynı kısa ifadeyle adlandır. Koşul belirtilmiyorsa boş dizi kullan.',
  'sequence gün içindeki anlatılan gerçek sıradır; metin sırası kronoloji değilse açıklanan zamanı izle. Zaman bilinmiyorsa aynı sequence kullan.',
  'Aynı anda yaşanan hislere aynı sequence ver. Açık sıra yoksa order_basis unknown kullan; olaylar arasında zaman veya neden-sonuç bağı üretme. Gerilim sonrasında rahatlama relief; zaten sakin olmak calm; yorgunluk fatigue ve kind energy. Enerji, aynı anda yaşanan olumlu veya olumsuz duyguları geçersiz kılmaz.',
  'Temel anahtarlar joy, calm, relief, excitement, anxiety, tension, sadness, anger, loneliness, hope, pride, fatigue; gerekirse yeni bir anahtar ve tanım üret. Benzer adları aynı anlamda birleştir.',
  'Yalnız kullanıcının kendi yaşadığı duyguları, ham yazı veya cevabından birebir quote ile kaydet. Başkasının duygusunu, kurmacayı, olumsuzlanan hissi veya web araştırmasını kullanıcıya atfetme.',
  'Karışık ve değişen duyguları koru. Helpful listesine yalnız kullanıcının iyi geldiğini söylediği eylemi action ve birebir quote ile yaz. Kanıt yoksa boş dizi kullan.',
  'Yalnız bir duygu etiketinin takvime işaretlenmesini onaylatacaksan boolean_questions içinde emotion_proposal:{key,label,quote} kullan; quote bu günlükten birebir olsun. Bu yapılandırılmış seçim uygulamada doğrudan işlenir. Hisleri veya nedenlerini araştıran sıradan evet/hayır sorularına emotion_proposal koyma; onların yanıtı analize gider.',
  'reflection bugünkü hisleri ve olayları, mevcut kaynaklarla doğrulanan tarihli karşılaştırmaları ve uygunsa somut önerileri içersin. Uzunluğu metnin gerektirdiği derinliğe göre belirle.',
  'Sana daha önce iyi gelenler bölümünde yalnız kullanıcının helpful kayıtları ve tarihli alıntılarıyla desteklenen eylemleri anımsat. Yeni öneriyi geçmiş deneyim gibi sunma. Hatırlatma için onay sorusu oluştur; saat veya tarih belli değilse önce sor, otomatik alarm kurma.',
  'Aynı kelimeyi duygu döngüsü sayma; bağlam, farklı kaynak günler, kullanıcı düzeltmeleri ve ters örnekleri değerlendir. Benzerliği neden-sonuç veya kalıcı kişilik hükmü olarak sunma.',
].join('\n');

export function validateEmotionEvidence(value: EmotionalMemory, texts: string[]): void {
  const quotes = [...value.observations, ...value.helpful].map(item => item.quote);
  if (quotes.some(quote => !quote.trim() || !texts.some(text => text.includes(quote)))) {
    throw new Error('Unsupported emotion quote');
  }
}

export function canonicalEmotionKey(value: string): string {
  const key=value.toLocaleLowerCase('tr').normalize('NFKD').replace(/\p{M}/gu,'').replace(/ı/g,'i');
  const aliases:Record<string,string>={nese:'joy',mutluluk:'joy',happy:'joy',happiness:'joy',huzur:'calm',peace:'calm',rahatlama:'relief',sakinlik:'calm',
    relief:'relief',heyecan:'excitement',kaygi:'anxiety',endise:'anxiety',gerilim:'tension',stres:'tension',
    stress:'tension',overwhelmed:'tension',uzuntu:'sadness',ofke:'anger',yalnizlik:'loneliness',umut:'hope',gurur:'pride',yorgunluk:'fatigue',tired:'fatigue'};
  return aliases[key]??key;
}
