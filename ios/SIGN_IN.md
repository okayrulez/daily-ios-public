# DailyX hesap bağlantıları

Firebase hesabı günlük/harita verilerine erişir. ChatGPT bağlantısı ayrı bir hesaptır ve model kullanımı için izin ister. Birine giriş yapmak diğerine giriş sağlamaz.

## ChatGPT

`Continue with ChatGPT` sistem tarayıcısını açar. Kod, [resmî SIWC OSS girişini](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) uygular: dinamik istemci kaydı, host kimliği, PKCE S256, state/nonce, HTTP 127.0.0.1 callback ve token değişimi. iOS'ta NWListener ve ASWebAuthenticationSession kullanımı **fiziksel cihazda henüz doğrulanmadı**. Callback çalışmazsa bu sürüm giriş yapamaz.

ID token sabit sağlayıcının JWKS anahtarlarıyla RS256 olarak doğrulanır; issuer, audience, nonce ve süre kontrol edilir. İstemci sırrı kullanılmaz. İstemci kimliği hesapla saklanır. Token yenilemesi seri yürür.

Giriş sonrası model listesi ve günlük içermeyen gerçek Responses çağrısıyla erişim sınanır. İzinler ve tamamlanmış yanıt doğrulanmadan günlük analizi açılmaz. Hesabın veya uygulamanın erişimi reddedilirse bu kod erişim sağlayamaz. Depo lisansı ve OpenAI uygunluğu ayrı konulardır; bu çalışma lisans değiştirmedi.

Akış okuyucu tamamlanmış asistan mesajlarını `response.output_item.done` olayından da toplar. Son `response.completed` olayının metni boşsa bu mesajlar kullanılır; doluysa son yanıt esas alınır, metin iki kez birleştirilmez. Tek başına delta, metin-done veya `[DONE]` yeterli değildir. Kesilmiş, reddedilmiş, araç çağrısı içeren veya sonradan hata dönen akışlar sonuç olarak kaydedilmez. Hata raporu ayrıca tamamlanmış mesaj ve metin olayı sayılarını içerir; içeriklerini içermez.

OAuth bilgileri cihaz Keychain'inde tutulur; Firestore'a, loglara veya JavaScriptCore'a aktarılmaz. Bağlantıyı kaldırma resmî endpoint üzerinden refresh token iptalini dener ve yerel anahtarı kaldırır; uzaktaki iptal doğrulanamazsa bildirilir.

## Cihazdaki bağlantı hata günlüğü

Ayarlar > ChatGPT bağlantısı > Bağlantı hata günlüğü bölümünden son 50 olay görülebilir, kopyalanabilir ve temizlenebilir. Analiz ekranında da raporu kopyalama düğmesi bulunur. Yeni sürüm yüklendikten sonraki giriş/bağlantı/analiz denemeleri kaydedilir; önceki sürümdeki kayıp hatalar geri getirilemez.

Kayıtlar tarih, uygulama sürümü/build, seçili model, işlem aşaması, HTTP durum kodu, sağlayıcının hata kodu/türü/parametresi, istek numarası, varsa Retry-After zamanı ve akışın son olay bilgilerini içerir. OAuth hata kodları ve ağ hatasının sayısal kodu da korunur. Ham HTTP gövdesi, hata mesajı, URL sorgusu, NSError userInfo, günlük, model cevabı veya kimlik bilgileri kaydedilmez.

Geçmiş Firebase hesap alanına göre ayrılmış, iOS dosya korumalı yerel dosyada tutulur; yedeğe ve sunucuya gönderilmez. Yeniden deneme veya uygulamayı kapatma geçmişi silmez. Kopyalama kullanıcının dokunmasıyla yapılır; pano yalnızca bu cihaz içindir ve 10 dakika sonra sona erer. Kayıt yazılamazsa arayüz bildirir.

Native testler: ConnectionDiagnosticLogTests; mahrem alanların dışlanması, hata kodlarının korunması, 50 olay sınırı, yeniden açılış, hesap ayrımı ve temizleme. Bu Windows ortamında Swift/Xcode bulunmadığından native testler burada çalıştırılmadı; Codemagic doğrulama adımı çalıştırır.

## Firebase yapılandırması

Uygulama mevcut dAIly üzerine `com.okayrulez.daily` kimliğiyle güncellenir; mevcut Firebase iOS kaydı kullanılır. DailyX koleksiyonları `dailyX*` adlarıyla ayrılır. Eski dAIly kayıtlarına otomatik migrasyon yapılmaz.

Codemagic varsayılan olarak mevcut dAIly public client plist'ini ve Google callback scheme'ini kullanır. İsteğe bağlı `DAILYX_FIREBASE_PLIST_BASE64` aynı bundle ID'li başka bir public client plist ile bu ayarı değiştirebilir. Servis hesabı JSON'u kullanılmaz.

Kurallar ve Apple signing [README](../README.md) içindedir. Native derleme, gerçek abonelik erişimi ve fiziksel cihaz testi henüz yapılmadı.
