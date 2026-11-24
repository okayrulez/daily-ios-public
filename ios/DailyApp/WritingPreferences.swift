import SwiftUI

enum WritingAppearance: String, CaseIterable, Identifiable {
    case neon, notebook, grid, night
    var id: String { rawValue }
    var title: String {
        switch self {
        case .neon: "Modern neon"
        case .notebook: "Sade defter"
        case .grid: "Açık ızgara"
        case .night: "Gece mürekkebi"
        }
    }
    var paper: Color {
        switch self {
        case .neon: DailyTheme.paper
        case .notebook: Color(red: 0.99, green: 0.97, blue: 0.92)
        case .grid: Color(red: 0.95, green: 0.97, blue: 1)
        case .night: Color(red: 0.06, green: 0.10, blue: 0.18)
        }
    }
    var ink: Color { self == .night ? .white.opacity(0.94) : DailyTheme.ink }
}

struct WritingPreferencesScreen: View {
    @AppStorage("daily.writing.appearance") private var appearance = WritingAppearance.neon.rawValue
    @AppStorage("daily.writing.serif") private var serif = false
    @AppStorage("daily.writing.size") private var size = 21.0
    @AppStorage("daily.writing.spacing") private var spacing = 7.0
    var body: some View {
        Form {
            Section("Yazma görünümü") {
                Picker("Tema", selection: $appearance) {
                    ForEach(WritingAppearance.allCases) { theme in Text(LocalizedStringKey(theme.title)).tag(theme.rawValue) }
                }
                Toggle("Serif yazı tipi", isOn: $serif)
                LabeledContent("Yazı boyutu", value: "\(Int(size))")
                Slider(value: $size, in: 16...30, step: 1)
                LabeledContent("Satır aralığı", value: "\(Int(spacing))")
                Slider(value: $spacing, in: 2...14, step: 1)
            }
            Section("Önizleme") {
                Text("Aklından geçtiği gibi yaz. Günün, düşüncelerin ve hislerin burada birikir.")
                    .font(.system(size: size, design: serif ? .serif : .default))
                    .lineSpacing(spacing).foregroundStyle(theme.ink)
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.paper, in: RoundedRectangle(cornerRadius: 18))
            }
        }.navigationTitle("Yazma tercihleri")
    }
    private var theme: WritingAppearance { WritingAppearance(rawValue: appearance) ?? .neon }
}

struct WritingSurface: ViewModifier {
    let theme: WritingAppearance
    let focused: Bool
    func body(content: Content) -> some View {
        if theme == .neon {
            content.dailyGlass(cornerRadius: 28, accent: focused ? DailyTheme.energy : DailyTheme.line)
        } else {
            content.background {
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(theme.paper)
                    if theme == .grid {
                        Canvas { context, size in
                            var path = Path()
                            for x in stride(from: 0.0, through: size.width, by: 22) {
                                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                            }
                            for y in stride(from: 0.0, through: size.height, by: 22) {
                                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                            }
                            context.stroke(path, with: .color(.blue.opacity(0.06)), lineWidth: 0.5)
                        }.clipShape(RoundedRectangle(cornerRadius: 24))
                    }
                }.allowsHitTesting(false)
            }.overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(DailyTheme.line.opacity(0.5), lineWidth: 0.7).allowsHitTesting(false) }
        }
    }
}
