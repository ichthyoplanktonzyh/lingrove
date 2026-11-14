import Foundation
import LingroveNotebook

extension LingroveNotebookCardMaterial {
    /// A content digest names the same held resource within a workspace. The workspace remains
    /// part of identity so a cache hit cannot grant access across accounts.
    public static func mediaAssetID(reference: ReviewMaterialMediaReference, workspaceID: String) -> String {
        stableID("material-media|" + reference.digest, workspace: workspaceID,
                 sense: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!).uuidString.lowercased()
    }
}
