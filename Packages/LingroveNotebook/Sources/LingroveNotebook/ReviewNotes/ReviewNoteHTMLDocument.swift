import Foundation

/// Both native hosts feed this inert document to WebKit. The page has no network access or
/// script bridge; media URLs can resolve only through the host's scoped in-memory handler.
public nonisolated enum ReviewNoteHTMLDocument {
    public static func make(html: String, css: String, dark: Bool) -> String {
        let appearance = dark ? "dark" : "light"
        // Closing style tags cannot escape the stylesheet into document markup. CSP and
        // navigation policy remain mandatory even for user-authored advanced templates.
        let safeCSS = css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src lingrove-review: data:; media-src lingrove-review:; font-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
        <style>\(safeCSS) :root{color-scheme:\(appearance)}</style></head><body><main class="card">\(html)</main></body></html>
        """
    }
}
