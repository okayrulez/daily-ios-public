import SwiftUI

struct ResearchSourceLinks: View {
    let text: String
    private var urls: [URL] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil,
                  seen.insert(raw).inserted else { return nil }
            return url
        }
    }
    var body: some View {
        ForEach(urls, id: \.absoluteString) { url in
            Link(destination: url) { Label(url.host ?? "Kaynak", systemImage: "link").font(.footnote) }
        }
    }
}
