# Firebase üzerinden analiz önpromptları

İlk kurulum için bu özelliği içeren iOS sürümü ve Firestore kuralları gerekir.
Sonraki yönerge değişiklikleri yeni uygulama sürümü gerektirmez.

Firebase Console → Firestore Database → `dailyXConfig` koleksiyonu →
`analysisPrompts` belgesi. Alanların başlangıç değerleri
`config/analysis-prompts.json` dosyasındadır. Bu belge bütün DailyX hesapları için
ortaktır; kişisel günlük veya parola içermemelidir.

- `schemaVersion`: number, 1.
- `revision`: string, örneğin `dailyx-remote-v2` (harf, rakam, nokta, tire, alt çizgi).
- `enabled`: boolean. `false` paketle gelen yönergelere geri döner.
- `instructions`: map; altındaki `journal`, `questionRepair`, `crossMap`,
  `crossMapRepair` alanları string önpromptlardır. Eksik aşamalar paket varsayılanını kullanır.

Sunucudan doğrulanan yönergeler aynı çalışma alanı oturumunda 60 saniye kullanılır. Her yeni analizde çalışma alanının bulut sürümü denetlenir. Başlamış analiz aynı yapılandırmayla
tamamlanır. Önceden üretilmiş ve kaydı bekleyen sonuç önce kaydedilir; yeniden model
çağrılmaz. İçerik değişince eski analiz önbelleği yeniden kullanılmaz. Kullanılan
revision Ayarlar → ChatGPT bağlantısı → Gelişmiş analiz ve yedekleme ve hata
günlüğünde görünür. Prompt metinleri loglanmaz.

Belge yoksa paket varsayılanı kullanılır. Bulut bağlantı hatası eşitleme durumuna yazılır ve cihaz paket yönergelerini kullanır. Geçersiz yapılandırma veya sürüm çakışması analizi durdurur. Alan adlarını doğru yaz:
bilinmeyen alanlar, boş yönergeler veya 20 KB üzerindeki aşamalar reddedilir.
Belge toplamı en fazla 100 KB olmalıdır. Ek metadata/Timestamp alanı ekleme.

Önpromptlar davranış ve üslubu değiştirir. Dinamik günlük/hafıza içeriği,
çıktı JSON şeması ve kaynak doğrulaması kod tarafından korunur. Soru adetlerini
veya veri şemasını yalnız prompt değiştirerek değiştirmek doğrulama hatası doğurur.
Bağlantı testi, kişisel veri içermeyen sabit bir erişim kontrolüdür; bu ayara tabi değildir.

Mevcut istemci arama/tarayıcı araçlarını göndermiyor. Bu nedenle bu ayar Instagram'a
giriş veya web araştırması yeteneği eklemez. Böyle bir özellik ayrıca araç entegrasyonu
ve uygulama sürümü gerektirir.

Normal uygulama kullanıcıları belgeyi sadece okuyabilir; yazma Firebase Console
veya yetkili Admin SDK üzerinden yapılır. Mevcut ortak projede yalnız kökteki
`firestore.rules` dağıtılır; bağımsız DailyX kuralları ortak kuralların yerine kullanılmaz.
