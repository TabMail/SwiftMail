import Foundation
import Testing
@testable import SwiftMail

/// An additional header written into SMTP content must stay one header field:
/// a line break that does not fold it would start a new field, such as a Bcc
/// field every recipient sees.
@Suite("Additional header line breaks", .serialized, .timeLimit(.minutes(1)))
struct AdditionalHeaderLineBreakTests {
    private static let blind = "hidden@example.com"

    @Test("an SMTP send refuses an additional header with a line break that is not a fold", arguments: [
        ["X-Note": "note\rBcc: \(blind)"],
        ["X-Note": "note\nBcc: \(blind)"],
        ["X-Note": "note\r\nBcc: \(blind)"],
        ["X-Note": "note\r\n \nBcc: \(blind)"],
        ["X-Note": "note\r\n"],
        ["X-Note\r\nBcc": blind]
    ])
    func refusesUnfoldedLineBreak(headers: [String: String]) {
        var email = BccHeaderTests.email
        email.additionalHeaders = headers
        #expect(throws: SMTPError.self) { try SMTPServer.prepareEmailForSend(email, capabilities: []) }
    }

    @Test("an SMTP send keeps folded additional headers byte for byte")
    func keepsFoldedAdditionalHeaders() throws {
        var email = BccHeaderTests.email
        email.additionalHeaders = [
            "References": "<a@example.com>\r\n <b@example.com>",
            "X-Note": "first\r\n\tsecond"
        ]
        let prepared = try SMTPServer.prepareEmailForSend(email, capabilities: [])
        let content = String(bytes: prepared.contentData, encoding: .utf8) ?? ""
        #expect(content.contains("\r\nReferences: <a@example.com>\r\n <b@example.com>\r\n"))
        #expect(content.contains("\r\nX-Note: first\r\n\tsecond\r\n"))
    }

    private static func storedDraft(note: String) -> Data {
        let lines = [
            "From: sender@example.com", "To: to@example.com", "Bcc: \(blind)",
            "Subject: Stored draft", "X-Note: \(note)", "", "Body."
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// Whether a send threw, and what the SMTP server received.
    private struct Delivery {
        let refused: Bool
        let recipients: [String]
        let content: String
    }

    private static func send(_ email: Email) async throws -> Delivery {
        let smtp = SMTPCaptureServer()
        try await smtp.start()
        let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
        try await client.connect()
        var refused = false
        do { _ = try await client.sendEmail(email) } catch is SMTPError { refused = true }
        try await client.disconnect()
        try await smtp.stop()
        return Delivery(
            refused: refused,
            recipients: smtp.recipients.sorted(),
            content: String(bytes: smtp.content, encoding: .utf8) ?? ""
        )
    }

    @Test("a stored draft whose header holds a lone carriage return is refused and nothing is sent")
    func convertedDraftWithLoneCRIsRefused() async throws {
        let email = try Email(message: Message(emlData: Self.storedDraft(note: "note\rBcc: \(Self.blind)")))
        #expect(email.bccRecipients.map(\.address) == [Self.blind])
        #expect(email.additionalHeaders?["x-note"]?.contains("\r") == true)

        let result = try await Self.send(email)
        #expect(result.refused)
        #expect(result.recipients.isEmpty)
        #expect(result.content.isEmpty)
    }

    @Test("an ordinary stored draft reaches every recipient and names no BCC recipient")
    func convertedOrdinaryDraftIsSent() async throws {
        let email = try Email(message: Message(emlData: Self.storedDraft(note: "note")))

        let result = try await Self.send(email)
        #expect(!result.refused)
        #expect(result.recipients == [Self.blind, "to@example.com"])
        #expect(result.content.contains("\r\nx-note: note\r\n"))
        #expect(result.content.contains("Body."))
        #expect(!result.content.contains(Self.blind))
    }
}
