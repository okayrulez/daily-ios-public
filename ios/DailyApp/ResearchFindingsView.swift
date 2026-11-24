import SwiftUI
import DailyCore

/// Each research claim is followed by its provider-validated source links.
struct ResearchFindingsView: View {
    let raw: String
    private var findings: [JSONValue] {
        (try? JSONValue.parse(raw).object?["findings"]?.array) ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                if let row = finding.object {
                    Text(row["label"]?.string ?? "").font(.subheadline.bold())
                    Text(row["detail"]?.string ?? "").font(.callout).textSelection(.enabled)
                    ForEach(row["urls"]?.array?.compactMap(\.string) ?? [], id: \.self) { rawURL in
                        if let url = URL(string: rawURL),
                           ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                           url.user == nil, url.password == nil {
                            Link(rawURL, destination: url).font(.footnote)
                        }
                    }
                }
            }
        }
    }
}
