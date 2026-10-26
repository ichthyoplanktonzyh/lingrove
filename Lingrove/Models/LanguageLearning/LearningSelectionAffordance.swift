import CoreGraphics

/// The reading coordinator owns the short-lived selection affordance. Its action is an explicit
/// user trigger; presenting it must not acquire screenshots or start a model. Tests substitute a
/// value-only presenter so this ordering is verified without clicking a real floating window.
@MainActor
protocol LearningSelectionAffordancePresenting {
    func show(anchor: CGRect, action: @escaping () -> Void)
    func showProgress(anchor: CGRect)
    func hide()
}
