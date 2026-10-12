import Foundation

/// `application/x-www-form-urlencoded` body builder (Real-Debrid takes form posts, not JSON).
enum FormURLEncoded {
    static let contentType = "application/x-www-form-urlencoded"

    static func encode(_ fields: [(String, String)]) -> Data {
        let body = fields
            .map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    /// Unreserved characters only (RFC 3986), so `&`, `=`, `+` and `:` inside magnets survive.
    private static func escape(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
