import Foundation

/// A regular Anki note generates two conditional card types. Gap text is prepared locally,
/// rather than mixing Anki's special Cloze note type with an ordinary recognition template.
/// Existing templates are never rewritten, preserving changes users make in Anki.
nonisolated enum AnkiNoteTemplate {
    static let css = """
    .card { font-family: -apple-system, sans-serif; font-size: 22px; line-height: 1.6;
      text-align: left; color: #202124; background: #fff; padding: 24px; }
    b { color: #087cff; } .meaning { font-weight: 600; } .extra { font-size: 17px; opacity: .75; }
    .nightMode.card { color: #eee; background: #202124; } hr { opacity: .2; }
    """
    static let recognitionFront = """
    {{#Recognition}}{{#Sentence}}{{Sentence}}{{/Sentence}}{{^Sentence}}{{Expression}}{{/Sentence}}{{/Recognition}}
    """
    static let gapFront = "{{#GapPrompt}}{{GapPrompt}}<div class='extra'>{{Meaning}}</div>{{/GapPrompt}}"
    static let recognitionBack = """
    {{FrontSide}}<hr id=answer><div class='meaning'>{{Meaning}}</div><div>{{Expression}}</div>
    <div class='extra'>{{Translation}}</div><div class='extra'>{{Notes}}</div><div class='extra'>{{Explanation}}</div>
    """
    static let gapBack = """
    {{FrontSide}}<hr id=answer><div>{{GapAnswer}}</div><div>{{Sentence}}</div>
    <div class='meaning'>{{Meaning}}</div><div>{{Expression}}</div>
    <div class='extra'>{{Translation}}</div><div class='extra'>{{Notes}}</div><div class='extra'>{{Explanation}}</div>
    """
}
