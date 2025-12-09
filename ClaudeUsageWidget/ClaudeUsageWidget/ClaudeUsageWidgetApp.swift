import SwiftUI
import AppKit

@main
struct ClaudeUsageWidgetApp: App {
    @StateObject private var viewModel = UsageViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        HStack(spacing: 2) {
            if let nsImage = NSImage(named: "ClaudeIcon") {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
            }
            Text(usageText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    private var usageText: String {
        guard let usage = viewModel.usageData?.fiveHour else {
            return "—%"
        }
        return "\(Int(usage.utilization))%"
    }
}
