import SwiftUI

/// One shared selection affordance, whether anchored by the reading coordinator's AppKit
/// panel or by Home's example text. Its host owns acquisition and the translation action.
struct LearningSelectionButton: View {
    var isPreparing = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if isPreparing { ProgressView().controlSize(.small) } else {
                    // The catalog owns the light/dark palettes. Original rendering preserves
                    // the whale's eyes and belly instead of tinting the whole silhouette.
                    Image("ReadingSelectionWhale").renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 24, height: 24).accessibilityHidden(true)
                }
            }.frame(width: 30, height: 30)
        }.disabled(isPreparing).buttonStyle(.plain).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .help(String(localized: "Translate selected text", table: "Learning"))
            .accessibilityLabel(String(localized: "Translate selected text", table: "Learning"))
    }
}
