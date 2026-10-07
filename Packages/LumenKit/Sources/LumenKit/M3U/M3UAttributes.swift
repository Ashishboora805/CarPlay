import Foundation

/// Tokenizer for M3U attribute lists such as `-1 tvg-id="a" group-title="News, World" tvg-logo=x.png`.
///
/// Keys are lowercased. Quoted values may contain spaces and commas; unquoted values end at
/// whitespace. A leading duration token (`-1`, `0`, `123.4`) is skipped.
public enum M3UAttributes {
    public static func parse(_ text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        let scalars = Array(text.unicodeScalars)
        var i = 0
        let count = scalars.count

        func skipWhitespace() {
            while i < count, scalars[i].properties.isWhitespace { i += 1 }
        }

        while i < count {
            skipWhitespace()
            guard i < count else { break }

            // Read a key (or bare token) up to '=' or whitespace.
            let keyStart = i
            while i < count, scalars[i] != "=", !scalars[i].properties.isWhitespace { i += 1 }
            let key = String(String.UnicodeScalarView(scalars[keyStart..<i])).lowercased()

            guard i < count, scalars[i] == "=" else {
                continue // bare token such as the duration; ignore
            }
            i += 1 // '='

            var value = ""
            if i < count, scalars[i] == "\"" {
                i += 1
                let valueStart = i
                while i < count, scalars[i] != "\"" { i += 1 }
                value = String(String.UnicodeScalarView(scalars[valueStart..<i]))
                if i < count { i += 1 } // closing quote
            } else {
                let valueStart = i
                while i < count, !scalars[i].properties.isWhitespace { i += 1 }
                value = String(String.UnicodeScalarView(scalars[valueStart..<i]))
            }
            if !key.isEmpty, result[key] == nil {
                result[key] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }
}
