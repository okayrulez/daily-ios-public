import Foundation

/// Only protocol metadata is shown. Never retain server messages or response text.
public struct ChatGPTServiceFailure: Error, Sendable {
    public let stage: String
    public let status: Int?
    public let code: String?
    public let parameter: String?
    public let errorType: String?
    public let requestID: String?
    public let shape: String
    public let retryAt: Date?
    public let contentType: String?
    public let streamDiagnostic: String?
    public var isUsageLimit: Bool { code == "subscription_sharing_usage_limit_exceeded" || code == "insufficient_quota" }
    public var isRateLimited: Bool { status == 429 || isUsageLimit || code == "rate_limit_exceeded" }

    public init(stage: String, status: Int? = nil, body: Data = Data(), requestID: String? = nil,
                fallbackCode: String? = nil, retryAfter: String? = nil, contentType: String? = nil,
                streamDiagnostic: String? = nil, fallbackErrorType: String? = nil,
                fallbackParameter: String? = nil, now: Date = Date()) {
        self.stage = stage; self.status = status
        self.streamDiagnostic = streamDiagnostic
        self.retryAt = Self.retryDate(retryAfter, now: now)
        let mime = contentType?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.contentType = mime.flatMap { $0.count <= 100 && $0.range(of: "^[a-z0-9.+-]+/[a-z0-9.+-]+$", options: .regularExpression) != nil ? $0 : nil }
        let object = (try? JSONValue.parse(String(decoding: body.prefix(8192), as: UTF8.self)))?.object
        let error = object?["error"]?.object
        self.code = Self.safe(error?["code"]?.string ?? object?["error"]?.string ?? fallbackCode)
        self.errorType = Self.safe(error?["type"]?.string ?? fallbackErrorType)
        self.parameter = Self.safe(error?["param"]?.string ?? fallbackParameter)
        self.requestID = Self.safe(requestID)
        self.shape = error != nil ? "error" : object?["detail"] != nil ? "detail" : object != nil ? "json" : "other"
    }

    private static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0, seconds <= 31_536_000 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value), date >= now else { return nil }
        return date
    }

    public static func safe(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128,
              value.range(of: "^[A-Za-z0-9_.\\[\\]-]+$", options: .regularExpression) != nil else { return nil }
        return value
    }

    public var summary: String {
        if isRateLimited {
            let reason: String
            switch code {
            case "subscription_sharing_usage_limit_exceeded":
                reason = "OpenAI, ChatGPT planının uygulamalarda kullanım sınırına ulaşıldığını bildirdi. Metin istekleri de bu kullanıma sayılır. Bu uygulamanın sınırı veya genel plan sınırı dolmuş olabilir; tüm ChatGPT/Codex hakkının bittiği bu koddan anlaşılmaz. ChatGPT → Ayarlar → Kullanım bölümündeki uygulama limitini kontrol et."
            case "insufficient_quota":
                reason = "OpenAI bu istek için yeterli kota bulunmadığını bildirdi (insufficient_quota). Bu yanıt hangi kotanın eksik olduğunu göstermiyor; Codex hakkının bittiği sonucunu çıkaramıyoruz."
            default:
                reason = "ChatGPT istek sınırına ulaşıldı. Analiz yapılamadı."
            }
            if let retryAt { return reason + " " + retryAt.formatted(date: .abbreviated, time: .shortened) + " sonrasında yeniden dene." }
            return reason + " OpenAI yeniden deneme saatini bildirmedi. Kullanım durumunu ChatGPT’den kontrol edebilirsin."
        }
        let explanation: String
        switch code ?? "" {
        case "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused":
            explanation = "ChatGPT oturumu yenilenemedi. Yeniden giriş yap."
        case "no_available_models": explanation = "Giriş yapıldı, fakat OpenAI bu hesap için kullanılabilir model bildirmedi. Başka bir hesap seçebilir veya hesap erişimini kontrol edebilirsin."
        case "model_not_found", "model_not_available", "unsupported_model": explanation = "Seçilen model bu hesapta kullanılamıyor. Ayarlar’dan model listesini yenileyip başka model seç."
        case "invalid_client": explanation = "OpenAI uygulama kaydını kabul etmedi. Hata raporunu kopyalayıp paylaşabilirsin."
        case "subscription_sharing_unsupported_capability": explanation = "Seçilen model veya istek alanı bu bağlantıda desteklenmiyor."
        case "subscription_sharing_user_not_eligible": explanation = "Bu hesap veya çalışma alanı ChatGPT planıyla uygulama kullanımına uygun değil."
        case "subscription_sharing_route_not_supported": explanation = "OpenAI bu bağlantı için kullanılan uç noktayı kabul etmedi."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": explanation = "ChatGPT plan erişimi şu anda kontrol edilemiyor."
        case "expected_event_stream": explanation = "ChatGPT’den beklenen analiz yanıtı gelmedi. Bu hata kullanım hakkının bittiğini göstermiyor."
        case "stream_ended_before_completion": explanation = "ChatGPT yanıt akışı tamamlanmadan kapandı. Kullanım hakkının bittiği doğrulanmadı. Uygulamayı açık tutarak yeniden dene; yeniden giriş yapman gerekmiyor."
        case "response_incomplete_max_output_tokens": explanation = "ChatGPT bu yanıt için üretim sınırına ulaştı ve yanıtı tamamlayamadı. Bu, abonelik kullanım hakkının bittiği anlamına gelmez."
        case "response_incomplete_content_filter", "refusal": explanation = "ChatGPT bu isteği içerik kısıtlaması nedeniyle tamamlamadı."
        case "response_incomplete_unknown": explanation = "OpenAI yanıtın tamamlanmadığını bildirdi. Uygulama nedenini belirleyemedi; yeniden deneyebilirsin."
        case "completed_without_text": explanation = "ChatGPT isteği tamamladı ama okunabilir bir yanıt göndermedi. Yeniden deneyebilirsin."
        case "stream_timeout": explanation = "ChatGPT yanıtı beklenirken süre doldu. Bağlantını kontrol edip uygulamayı açık tutarak yeniden dene."
        case "stream_connection_lost": explanation = "ChatGPT yanıtı alınırken internet bağlantısı kesildi. Bağlantını kontrol edip yeniden dene."
        default:
            switch status ?? 0 {
            case 401: explanation = "ChatGPT oturumu veya kullanım yetkisi kabul edilmedi."
            case 403: explanation = "OpenAI hesap, bölge veya uygulama erişimini reddetti."
            case 429: explanation = "Kullanım sınırı nedeniyle istek durduruldu."
            case 500...599: explanation = "OpenAI servisi şu anda kullanılamıyor."
            default: explanation = "ChatGPT bağlantısının bu adımı tamamlanamadı."
            }
        }
        return explanation
    }

    public var diagnostic: String {
        let fields: [String] = [stage, status.map { "HTTP \($0)" }, code, errorType.map { "hata_türü=\($0)" }, parameter.map { "alan=\($0)" },
                      "biçim=\(shape)", contentType.map { "tür=\($0)" }, requestID.map { "istek=\($0)" }, streamDiagnostic].compactMap { $0 }
        return fields.joined(separator: " · ")
    }
    public var userMessage: String { summary + "\n" + diagnostic }
}
