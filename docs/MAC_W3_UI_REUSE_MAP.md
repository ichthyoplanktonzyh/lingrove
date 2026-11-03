# Mac Wave 3 UI source adoption

Frozen source: `8a796f9d9cca57b75208e3636b24c9edf188a44e`. `Nibomo/` remains read-only.
The selected code is MIT, Copyright (c) 2026 Kirill Markin; the application bundles
`Lingrove/Resources/NibomoUI-LICENSE.txt`. New native types use Lingrove names.

| Actual upstream source/component | Adopted native source/component | Adoption and necessary differences |
| --- | --- | --- |
| `ReadableContentLayout.swift` | `UI/NibomoPresentation/LingroveReadableContentLayout.swift` | Verbatim body/initializer/820 and 720 widths; symbol rename and teaching comments only. |
| `NativeActionButtonStyles.swift` | `UI/NibomoPresentation/LingroveNativeActionButtonStyles.swift` | Same glass/prominent and bordered fallback; mechanical iOS → macOS availability guard. |
| `Review/View/Content/ReviewCardSideView.swift` | `UI/NibomoPresentation/LingroveReviewCardSideView.swift` | Actual extracted surface, caption/select action, copy/speech capsule row, materials, 24 radius/padding. AppKit pasteboard replaces UIKit. Injected local-byte renderer replaces the UIKit/MarkdownUI renderer. AI button omitted because no AI companion is in this module. Copy retains exact source Markdown. |
| `Review/View/Content/ReviewCardTextSelectionSheet.swift` | `UI/NibomoPresentation/LingroveReviewTextSelectionSheet.swift` | Same source-text sheet, Done toolbar and native selection; NSScrollView/NSTextView replaces UITextView. |
| `Review/View/ReviewView.swift`: `activeCardView`, `activeCardContentView`, header and answer bottom accessory | `UI/BuiltInReview/BuiltInReviewPracticeView.swift`, `BuiltInReviewWindowView.swift` | Same readable scroll column, 20-point stack, front/back surfaces, automatic back scroll, edit/source row, centered header, queue action. Existing session supplies pinned Card/link; sense chooser replaces unavailable Deck/tag filter. Local entry opens the due question directly; source-targeted entry opens participation details. |
| `Review/View/ReviewView.swift`: `showAnswerButton`, `reviewAnswerButtonsGrid`, `reviewAnswerButton` | `UI/NibomoPresentation/LingroveReviewAnswerControls.swift` | Extracted fixed reveal/rating layout, eye/symbol/title/interval, 56/44 minimum heights, original 600-point horizontal/2-column fallback. Closures replace mobile store calls. Window-local existing keyboard policy remains the only key handler. |
| `Review/View/ReviewAnswerSupport.swift` | `Support/BuiltInReview/LingroveReviewAnswerSupport.swift` | Actual source extraction with symbol renames and shared Engine import; no scheduling formula copied or changed. |
| `Review/Queue/Preview/ReviewQueuePreviewScreen.swift`: row/separator/due label | `UI/NibomoPresentation/LingroveReviewQueueRows.swift`, `BuiltInReviewQueuePreviewView` | Actual row, current badge, due/tag metadata, material, outline and Later divider. Parent supplies already bounded notebook-only snapshot; unrelated mobile pagination/runtime omitted. |
| `Notebook/UI/LingroveNotebookPreparationScreen.swift`: material form and review materials list | `UI/BuiltInReview/BuiltInReviewPreparationView.swift`, `BuiltInReviewSenseView.swift`, `BuiltInReviewSenseChooser` | Original Form/List/Section, example Picker, preview and toolbar structure, bound to existing frozen draft/action. Lingrove’s explicit sense enrollment, additional exercises, pause/withdraw/retained source controls remain. |
| `Cards/CardEditorScreen.swift`: text navigation rows, `CardTextPreviewRow`, `CardTextEditorScreen` text area | `BuiltInReviewPreparationView`, `LingroveReviewTextPreviewRow`, `LingroveReviewTextEditorScreen` | Actual separate front/back navigation, preview flattening, material text area. Native TextEditor on macOS 14; no Photos/remote authoring/telemetry/mobile store. Existing material draft owns text, save/cancel and original CAS. |
| `Settings/Account/AccountStatusView.swift`: status List and actions | `UI/Settings/Panes/AccountPaneView.swift` | Original separate status/server/sign-in structure, labeled state/email/destination rows, sign-out confirmation. Native grouped Form supplies AppKit row chrome. Existing service binds safe state. No guest/installation ID/social method management/clear-library semantics. |
| `Settings/Account/ServerSettingsView.swift` | `UI/Settings/Account/LingroveAccountServerView.swift` | Original Current Server section plus editable connection section and disconnect/apply confirmation. API/auth fields remain separate explicit URLs because Lingrove has no bundled official server or derived-domain rule. No validation network request from drafts. |
| `Settings/Account/CloudSignIn/CloudSignInSheet.swift`: `emailForm` | `UI/Settings/Account/LingroveAccountSignInSheet.swift` | Extracted separate email Form, focus, send section and push to code. Starts at email because it is the only available method; removes native provider/analytics/post-auth mobile graph. |
| `Settings/Account/CloudSignIn/CloudOtpVerificationSheet.swift`: content | `LingroveAccountSignInSheet.codeForm` | Original Email/One-time code sections, challenge prompt, field/Continue/resend/focus and error placement. Existing AccountSessionService owns challenge, expiry, generation and credential effects. |
| `Settings/Account/CloudSignIn/CloudWorkspaceSelectionSheet.swift`, `Settings/Workspace/Cloud/CloudWorkspaceSelectionSupport.swift` | `LingroveAccountWorkspaceSelectionSheet`, `LingroveAccountWorkspaceRow` | Original explicit List choice and row layout; uses real existing workspace metadata, omits unsupported create-new operation. Follow-on retain/accept and opt-in remain controller commands. |
| `Settings/Account/AccountStatusView.swift`: `SyncStatusIndicatorView` | `LingroveSyncStatusIndicator` / `AccountNotebookSyncSection` | Extracted dot/text layout, safe independent lane status binding; existing original-proposal acceptance and first-connection expected snapshots preserved. |
| `ReviewCards.xcstrings`, selected `*.lproj/AISettings.strings` | `Resources/ReviewCards.xcstrings`, `Resources/NibomoAccount.xcstrings` | Selected upstream translations restricted to the existing 15 Mac locales; existing Mac `es` adopts upstream `es-ES`, and `zh-Hant` is self-translated locally because upstream has no Traditional Chinese. No default URLs/assets/provider settings imported. |

The full `ReviewView` is not directly importable: UIKit, FlashcardsStore, navigation,
Premium, AI companion, reactions, notifications and remote media own other application services.
`AccountMethodsView` manages provider linking, reauthentication and connection previews that
Lingrove’s current OTP capability does not expose; displaying those controls would create dead
paths. Those components are audited reference, not claimed as adopted. Nibomo’s math renderer
uses MarkdownUI/RaTeX/UIKit; this port keeps the existing safe native Markdown text/local PNG
boundary, so math/table rendering parity remains a documented gap rather than importing the
whole mobile rendering/dependency graph. The original dark/orange appearance is applied only
inside these owned surfaces. No remote image/CDN load, guest request or telemetry was added.

## Inspected native content captures

All samples are drawn by real AppKit/SwiftUI windows in the private test host, with synthetic
values. They capture content bounds, not a complete onscreen window or mouse journey.

| Capture under this worktree’s `build/mac-w3-b/native-ui/` | What was inspected and necessary difference |
| --- | --- |
| `extracted-server-draft.png` | Actual saved API/auth destination remains visibly separate from the editable draft URLs. Separate URLs replace Nibomo’s unsupported derived-domain/official-server choices. |
| `extracted-otp.png` / `extracted-otp-reopened.png` | Original Email and One-time code section layout; the same service challenge survives reopening without another send. Social provider choices are absent. |
| `extracted-workspace-chooser.png` / `extracted-sync-ownership.png` | Original workspace rows plus Lingrove’s explicit retain/accept and opt-in. Synthetic controller status is shown; chooser presentation does not connect or enable sync. |
| `native-preparation.png` | Original material example Picker and front/back navigation rows; source meaning stays distinct from exercise draft. macOS 14 uses native TextEditor without the newer selection-binding initializer. |
| `native-answer.png` | Original front/back material surfaces, readable column and bottom rating structure; paragraphs remain separate. Cached content images omit compositor-rendered glass backgrounds; black rating labels here do **not** establish usable onscreen contrast. |

The attempted in-process accessibility press could not find the offscreen SwiftUI glass control,
even after one corrective host rerun. That path was stopped and its failed xcresults retained.
The final artifact-only bar capture is not mouse-interaction or glass appearance evidence (its
standalone cached image is empty). The AppKit window-local keyboard reveal/rate/edit gating,
persisted result and undo journey executed successfully. Real mouse presses and onscreen glass
contrast remain explicit integration checks; no product navigation/style was changed to make
the automation pass. Native execution details and exact evidence are in `MAC_W3_B_DELIVERY.md`.

