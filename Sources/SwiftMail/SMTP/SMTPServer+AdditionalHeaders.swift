import Foundation

extension SMTPServer {
    /// Refuses ``Email/additionalHeaders`` that would let the content every
    /// recipient receives name a blind-copy recipient: a `Bcc` or `Resent-Bcc`
    /// field (BCC recipients belong in ``Email/bccRecipients``, envelope only),
    /// or a CR or LF that does not fold the field (CRLF, then a space or tab),
    /// which would start a new field.
    static func checkAdditionalHeaders(of email: Email) throws {
        let blindFieldNames: Set = ["bcc", "resent-bcc"]
        for (name, value) in email.additionalHeaders ?? [:] {
            if blindFieldNames.contains(name.trimmingCharacters(in: .whitespaces).lowercased()) {
                throw SMTPError.sendFailed(
                    "Additional header \(name) would show blind-copy recipients to every recipient"
                )
            }
            let unfolded = "\(name): \(value)"
                .replacingOccurrences(of: "\r\n ", with: "")
                .replacingOccurrences(of: "\r\n\t", with: "")
            if unfolded.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) {
                throw SMTPError.sendFailed("An additional header has a line break that would start a new header field")
            }
        }
    }
}
