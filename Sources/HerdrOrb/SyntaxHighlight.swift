import Foundation
import JavaScriptCore

struct CodeToken: Equatable, Sendable { var text: String; var scope: String }

/// The bundled highlight.js grammar engine runs locally in a serialized JSContext.
/// Model-supplied source is passed as a value, never evaluated as JavaScript.
enum SyntaxHighlight {
    private static let queue = DispatchQueue(label: "herdrorb.syntax", qos: .userInitiated)
    private static var context: JSContext?
    private static var resources: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
    private final class Entry {
        let tokens: [CodeToken]
        init(_ tokens: [CodeToken]) { self.tokens = tokens }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let result = NSCache<NSString, Entry>()
        result.totalCostLimit = 8 * 1024 * 1024
        result.countLimit = 128
        return result
    }()
    static func tokens(_ source: String, language: String) -> [CodeToken] {
        let language = normalizedLanguage(language)
        let key = (language + "\0" + source) as NSString
        if let cached = cache.object(forKey: key) { return cached.tokens }
        return queue.sync {
            if let cached = cache.object(forKey: key) { return cached.tokens }
            if context == nil, let url = resources.url(forResource: "syntax-highlighter", withExtension: "js"),
               let script = try? String(contentsOf: url, encoding: .utf8) {
                let engine = JSContext()
                engine?.exceptionHandler = { _, _ in }
                engine?.evaluateScript(script)
                context = engine
            }
            let values = context?.objectForKeyedSubscript("herdrHighlight")?.call(withArguments: [source, language])?.toArray() as? [[String: Any]]
            var tokens = values?.compactMap { value -> CodeToken? in
                guard let text = value["text"] as? String else { return nil }
                return CodeToken(text: text, scope: value["scope"] as? String ?? "")
            } ?? []
            // Unknown syntax or an engine failure must never drop or alter source.
            if tokens.map(\.text).joined() != source { tokens = [.init(text: source, scope: "")] }
            cache.setObject(Entry(tokens), forKey: key, cost: source.utf8.count * 4 + tokens.count * 64)
            return tokens
        }
    }
    static func normalizedLanguage(_ raw: String) -> String {
        let value = raw.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased() ?? "text"
        return ["sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "js": "javascript", "jsx": "javascript",
                "ts": "typescript", "tsx": "typescript", "py": "python", "yml": "yaml", "html": "xml",
                "objc": "objectivec", "c++": "cpp", "patch": "diff" ][value] ?? value
    }
}
