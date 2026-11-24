import Foundation

public enum WorkspaceConnectionDiagnostic {
    public static func auth(_ error: Error) -> String {
        let failure = error as NSError
        guard failure.domain == "FIRAuthErrorDomain" else { return "AUTH_ERROR: Firebase girişi tamamlanamadı." }
        let explanation: String
        switch failure.code {
        case 17004, 17009, 17011:
            return "AUTH_CREDENTIALS: E-posta veya şifre doğrulanamadı. İlk kez kullanıyorsan Hesap oluştur; diğer cihazda aynı hesapla giriş yap."
        case 17008: explanation = "E-posta adresinin biçimini kontrol et."
        case 17007: explanation = "Bu e-posta kullanılıyor. Hesap oluştur yerine Giriş yap seçeneğini kullan."
        case 17026: explanation = "Şifre güvenlik koşullarını karşılamıyor; daha güçlü bir şifre seç."
        case 17006: explanation = "Firebase projesinde E-posta/Parola girişi etkin değil."
        case 17020: explanation = "Firebase giriş servisine ulaşılamadı; internet bağlantısını kontrol et."
        case 17010: explanation = "Çok fazla deneme yapıldı. Biraz bekleyip tekrar dene."
        case 17023, 17028: explanation = "Firebase uygulama yapılandırması veya API anahtarı yetkisi kontrol edilmeli."
        case 17005: explanation = "Bu hesabın erişimi devre dışı."
        case 17995: explanation = "Giriş oturumu cihazın güvenli deposunda saklanamadı."
        default: explanation = "Firebase girişi tamamlanamadı. Daha sonra yeniden dene."
        }
        return "AUTH_\(failure.code): \(explanation)"
    }

    /// Only allowlisted descriptions and numeric codes; never credentials,
    /// URLs, raw server descriptions or journal content from NSError.userInfo.
    public static func firestore(_ error: Error?) -> String {
        guard let error else { return "FIRESTORE_SNAPSHOT: Sunucudan kayıt yanıtı alınamadı." }
        if error is WorkspaceError { return "WORKSPACE_VALIDATION: Kayıt biçimi veya bütünlüğü doğrulanamadı." }
        let failure = error as NSError
        guard failure.domain == "FIRFirestoreErrorDomain" else {
            return "WORKSPACE_ERROR: İşlem tamamlanamadı (kod \(failure.code))."
        }
        let explanation: String
        switch failure.code {
        case 7: explanation = "Giriş yapılmış olsa da günlük alanına erişim reddedildi. DailyX Firestore kuralları bu Firebase projesine yayınlanmalı."
        case 16: explanation = "Firebase oturumu doğrulanamadı."
        case 14: explanation = "Firebase servisine ulaşılamadı; ağ veya servis geçici olarak kullanılamıyor."
        case 4: explanation = "Firebase isteği zaman aşımına uğradı."
        case 9: explanation = "Firestore isteğinin önkoşulu sağlanmadı; proje veya sorgu ayarı kontrol edilmeli."
        default: explanation = "Firestore işlemi tamamlanamadı."
        }
        return "FIRESTORE_\(failure.code): \(explanation)"
    }
}
