import CoreGraphics

/// One screen-space snapshot keeps placement arguments coherent when the parent moves while a
/// dictionary reply is pending. The sentence panel supplies it; the child never queries focus.
nonisolated struct LearningDetailPlacement {
    let parent: CGRect
    let caret: CGRect
    let reserved: CGRect?
    let screen: CGRect
    let anchorY: CGFloat
    var standalone = false
}
