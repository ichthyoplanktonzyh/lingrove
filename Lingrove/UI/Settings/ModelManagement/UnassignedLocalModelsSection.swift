import SwiftUI

/// Existing imported/LM Studio files remain discoverable without being automatically enabled
/// for every task. This explicit action borrows the existing manager and its directory-change
/// callback; the view owns no registry, file scan or runtime.
struct UnassignedLocalModelsSection: View {
    @ObservedObject var downloads: ModelDownloadManager
    let task: LocalModelTask

    var body: some View {
        let models = downloads.unassignedModels(for: task)
        if !models.isEmpty {
            Section {
                DisclosureGroup(String(localized: "Custom models", table: "Learning")) {
                    ForEach(models) { model in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.filename).lineLimit(2)
                                LocalModelDetailsView(filename: model.filename, location: model.url,
                                    source: downloads.sourceURL(for: model.filename))
                            }
                            Spacer()
                            Button(String(localized: "Use for this task", table: "Learning")) {
                                downloads.assignModel(model.filename, for: task)
                            }
                        }
                    }
                }
            }
        }
    }
}
