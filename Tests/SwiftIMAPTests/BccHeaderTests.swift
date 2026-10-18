import Foundation
import Testing
@testable import SwiftMail

/// A copy the sender keeps (a draft, a Sent copy) names its BCC recipients; a
/// message handed to SMTP never does (RFC 5322 section 3.6.3).
@Suite("Bcc header")
struct BccHeaderTests {
    private static let email = Email(
        sender: EmailAddress(address: "sender@example.com"),
        recipients: [EmailAddress(address: "to@example.com")],
        ccRecipients: [EmailAddress(address: "cc@example.com")],
        bccRecipients: [
            EmailAddress(name: "Jörg Hidden", address: "hidden@example.com"),
            EmailAddress(address: "second@example.com")
        ],
        subject: "Bcc test",
        textBody: "Body text."
    )

    private static func headerSection(_ content: String) -> String {
        String(content[..<(content.range(of: "\r\n\r\n")?.lowerBound ?? content.endIndex)])
    }

    @Test("content built for SMTP names no BCC recipient")
    func sentContentHasNoBcc() {
        let content = Self.email.constructContent()
        #expect(!content.contains("hidden@example.com"))
        #expect(!content.contains("second@example.com"))
        #expect(!Self.headerSection(content).lowercased().contains("bcc:"))
    }

    @Test("content built for a kept copy names every BCC recipient in one Bcc header")
    func keptContentNamesBcc() throws {
        let header = Self.headerSection(Self.email.constructContent(includeBccHeader: true))
        let line = try #require(header.components(separatedBy: "\r\n").first { $0.hasPrefix("Bcc: ") })
        let expected = Self.email.bccRecipients.map { $0.headerString() }.joined(separator: ", ")
        #expect(line == "Bcc: \(expected)")
        // The display name is not ASCII, so it travels RFC 2047-encoded.
        #expect(!line.contains("ö"))
        #expect(line.contains("<hidden@example.com>"))
        #expect(line.contains("second@example.com"))
    }

    @Test("no Bcc header when there are no BCC recipients")
    func noBccRecipientsNoHeader() {
        var email = Self.email
        email.bccRecipients = []
        #expect(!Self.headerSection(email.constructContent(includeBccHeader: true)).lowercased().contains("bcc:"))
    }

    // MARK: - removingBccFields (sendDraft's SMTP copy)

    private static func strip(_ text: String) -> String {
        String(bytes: IMAPServer.removingBccFields(from: Data(text.utf8)), encoding: .utf8) ?? ""
    }

    @Test("removes a Bcc field and its folded continuation lines, any case")
    func removesFoldedBcc() {
        let raw = "From: me@example.com\r\nBCC: one@example.com,\r\n two@example.com,\r\n\tthree@example.com\r\n"
            + "To: you@example.com\r\nSubject: Hi\r\n\r\nBody\r\n"
        #expect(Self.strip(raw) == "From: me@example.com\r\nTo: you@example.com\r\nSubject: Hi\r\n\r\nBody\r\n")
    }

    @Test("removes every Bcc field, including one written with a space before the colon")
    func removesEveryBcc() {
        let raw = "Bcc: a@example.com\r\nTo: you@example.com\r\nbcc : b@example.com\r\n\r\nBody\r\n"
        #expect(Self.strip(raw) == "To: you@example.com\r\n\r\nBody\r\n")
    }

    @Test("keeps the body, even a body line that looks like a Bcc field")
    func keepsBody() {
        let raw = "To: you@example.com\r\n\r\nBcc: not-a-header@example.com\r\n"
        #expect(Self.strip(raw) == raw)
    }

    @Test("keeps fields whose name only starts or ends with Bcc")
    func keepsSimilarNames() {
        let raw = "X-Bcc: a@example.com\r\nBcc-Note: b\r\nResent-Bcc: c@example.com\r\n\r\nBody\r\n"
        #expect(Self.strip(raw) == raw)
    }

    @Test("keeps a line with no colon, and a header section with no blank line after it")
    func keepsMalformedLines() {
        #expect(Self.strip("To: you@example.com\r\nbcc\r\nSubject: Hi\r\n\r\nBody")
            == "To: you@example.com\r\nbcc\r\nSubject: Hi\r\n\r\nBody")
        #expect(Self.strip("To: you@example.com\r\nBcc: a@example.com") == "To: you@example.com\r\n")
    }

    @Test("handles bare LF line endings")
    func handlesBareLF() {
        let raw = "From: me@example.com\nBcc: one@example.com,\n two@example.com\nTo: you@example.com\n\nBody\n"
        #expect(Self.strip(raw) == "From: me@example.com\nTo: you@example.com\n\nBody\n")
    }

    @Test("keeps bytes that are not UTF-8 unchanged")
    func keepsNonUTF8Bytes() {
        var raw = Data("Subject: caf".utf8)
        raw.append(0xE9)  // Latin-1 e-acute
        raw.append(contentsOf: Data("\r\nBcc: a@example.com\r\n\r\n".utf8))
        raw.append(0xFF)
        var expected = Data("Subject: caf".utf8)
        expected.append(0xE9)
        expected.append(contentsOf: Data("\r\n\r\n".utf8))
        expected.append(0xFF)
        #expect(IMAPServer.removingBccFields(from: raw) == expected)
    }

    @Test("a kept copy loses exactly its Bcc header and nothing else")
    func keptCopyRoundTrip() {
        let kept = Self.email.constructContent(includeBccHeader: true)
        let bccLine = kept.components(separatedBy: "\r\n").first { $0.hasPrefix("Bcc: ") } ?? ""
        #expect(!bccLine.isEmpty)
        #expect(Self.strip(kept) == kept.replacingOccurrences(of: bccLine + "\r\n", with: ""))
    }
}

#if os(macOS)
    @Suite("Bcc header over IMAP and SMTP", .serialized, .timeLimit(.minutes(1)))
    struct BccAppendTests {
        @Test("a draft created over IMAP names its BCC recipients")
        func createDraftWritesBcc() async throws {
            let appended = try await Self.appendedMessage { server in
                let email = Email(
                    sender: EmailAddress(address: "sender@example.com"),
                    recipients: [EmailAddress(address: "to@example.com")],
                    bccRecipients: [EmailAddress(name: "Hidden", address: "hidden@example.com")],
                    subject: "Draft with Bcc",
                    textBody: "Draft body."
                )
                try await server.createDraft(from: email, in: "Drafts")
            }
            let header = (String(bytes: appended, encoding: .utf8) ?? "")
                .components(separatedBy: "\r\n\r\n").first ?? ""
            #expect(header.components(separatedBy: "\r\n").contains("Bcc: Hidden <hidden@example.com>"))
        }

        /// Sending a draft that names BCC recipients delivers to them, sends no
        /// one a copy that names them, and files a Sent copy that does.
        @Test("sendDraft delivers to BCC recipients without naming them, and the Sent copy names them")
        func sendDraftKeepsBccOutOfTheDeliveredCopy() async throws {
            let draft = [
                "From: sender@example.com",
                "To: to@example.com",
                "Bcc: Hidden <hidden@example.com>",
                "Subject: Draft with Bcc",
                "Message-ID: <draft-bcc@example.com>",
                "",
                "Draft body.",
                ""
            ].joined(separator: "\r\n")
            let smtp = SMTPCaptureServer()
            try await smtp.start()
            let appended = try await Self.appendedMessage(seeding: draft) { server in
                let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
                try await client.connect()
                _ = try await server.sendDraft(uid: UID(1), via: client, from: "Drafts", to: "Sent")
                try await client.disconnect()
            }
            try await smtp.stop()

            #expect(smtp.recipients.sorted() == ["hidden@example.com", "to@example.com"])
            let delivered = String(bytes: smtp.content, encoding: .utf8) ?? ""
            #expect(delivered.contains("Draft body."))
            #expect(!delivered.contains("hidden@example.com"))
            let sentCopy = (String(bytes: appended, encoding: .utf8) ?? "")
                .components(separatedBy: "\r\n\r\n").first ?? ""
            #expect(sentCopy.components(separatedBy: "\r\n").contains("Bcc: Hidden <hidden@example.com>"))
        }

        /// Runs `body` against an IMAP test server whose one mailbox holds
        /// `seeding` (when given), and returns the one message it APPENDed.
        private static func appendedMessage(
            seeding message: String? = nil,
            _ body: (IMAPServer) async throws -> Void
        ) async throws -> Data {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("new"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            if let message {
                try Data(message.utf8).write(to: maildir.appendingPathComponent("cur/1.eml"))
            }

            let testServer = try IMAPTestServer(maildirURL: maildir)
            try testServer.start()
            try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "testuser", password: "testpass")
                try await body(server)
                try await server.disconnect()
            }
            let messages = testServer.appendedMessages
            #expect(messages.count == 1)
            return try #require(messages.first)
        }
    }
#endif
