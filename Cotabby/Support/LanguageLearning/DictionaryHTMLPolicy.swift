import Foundation

/// This wrapper is paired with JavaScript disabled and a scoped URL handler. Escaping or regex
/// cleanup alone cannot secure third-party HTML; CSP forbids remote subresources and execution.
nonisolated enum DictionaryHTMLPolicy {
    static func document(_ html: String) -> String {
        let content = html.replacingOccurrences(of: "(?is)<base\\b[^>]*>|<meta\\b[^>]*>|<!doctype[^>]*>|</?(?:html|head|body)\\b[^>]*>",
                                                with: "", options: .regularExpression)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none';
        script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none';
        base-uri 'none'; img-src lingrove-dictionary:; style-src 'unsafe-inline' lingrove-dictionary:;
        font-src lingrove-dictionary:; media-src 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:light dark}html,body{margin:0;
        padding:0;background:transparent;color:CanvasText;font:13px -apple-system;overflow-wrap:anywhere}
        img{max-width:100%;height:auto}pre{white-space:pre-wrap}a{color:LinkText}table{max-width:100%}</style>
        </head><body>\(content)</body></html>
        """
    }
}
