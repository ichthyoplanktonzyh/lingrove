import SwiftUI

/// One shared selection affordance, whether anchored by the reading coordinator's AppKit
/// panel or by Home's example text. Its host owns acquisition and the translation action.
struct LearningSelectionButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "character.bubble").font(.system(size: 16, weight: .medium)).frame(width: 30, height: 30)
        }.buttonStyle(.plain).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .help(String(localized: "Translate selected text", table: "Learning"))
            .accessibilityLabel(String(localized: "Translate selected text", table: "Learning"))
    }
}
