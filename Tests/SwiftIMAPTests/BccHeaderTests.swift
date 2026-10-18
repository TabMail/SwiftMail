import Foundation
import Testing
@testable import SwiftMail

/// A copy the sender keeps (a draft, a Sent copy) names its BCC recipients; a
/// message handed to SMTP never does (RFC 5322 section 3.6.3).
@Suite("Bcc header")
struct BccHeaderTests {
    static let email = Email(
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

    /// The unfolded body of every header field named `name` (any case), in order.
    static func fields(_ name: String, in content: String) -> [String] {
        let unfolded = headerSection(content).replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\r\n\t", with: " ")
        let prefix = name.lowercased() + ":"
        return unfolded.components(separatedBy: "\r\n")
            .filter { $0.lowercased().hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    /// A kept copy names each recipient only in the field it was given in: one
    /// field per role, so a BCC address never shows where others can see it.
    static func expectRoles(in content: String, to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress]) {
        for (name, addresses) in [("To", to), ("Cc", cc), ("Bcc", bcc)] {
            let expected = addresses.isEmpty ? [] : [addresses.map { $0.headerString() }.joined(separator: ", ")]
            #expect(fields(name, in: content) == expected, "\(name)")
        }
    }

    /// Goes through the content SMTPServer actually sends, with and without
    /// 8BITMIME, so a change anywhere on that path is caught.
    @Test("content prepared for an SMTP send names no BCC recipient", arguments: [[String](), ["8BITMIME"]])
    func sentContentHasNoBcc(capabilities: [String]) throws {
        let prepared = try SMTPServer.prepareEmailForSend(Self.email, capabilities: capabilities)
        let content = String(bytes: prepared.contentData, encoding: .utf8) ?? ""
        #expect(content.contains("Body text."))
        #expect(!content.contains("hidden@example.com"))
        #expect(!content.contains("second@example.com"))
        #expect(!Self.headerSection(content).lowercased().contains("bcc:"))
    }

    @Test("content built for a kept copy names every BCC recipient in one Bcc header")
    func keptContentNamesBcc() throws {
        let kept = Self.email.constructContent(includeBccHeader: true)
        let email = Self.email
        Self.expectRoles(in: kept, to: email.recipients, cc: email.ccRecipients, bcc: email.bccRecipients)
        let header = Self.headerSection(kept)
        let line = try #require(header.components(separatedBy: "\r\n").first { $0.hasPrefix("Bcc: ") })
        let expected = Self.email.bccRecipients.map { $0.headerString() }.joined(separator: ", ")
        #expect(line == "Bcc: \(expected)")
        // The display name is not ASCII, so it travels RFC 2047-encoded.
        #expect(!line.contains("ö"))
        #expect(line.contains("<hidden@example.com>"))
        #expect(line.contains("second@example.com"))
    }

    /// A draft may have BCC recipients only, with or without CC.
    @Test("a kept copy with no To recipient names its BCC recipients only in its Bcc header",
          arguments: [1, 2], [false, true])
    func keptCopyWithoutTo(bccCount: Int, withCc: Bool) {
        var email = Self.email
        email.recipients = []
        email.ccRecipients = withCc ? [EmailAddress(address: "cc@example.com")] : []
        email.bccRecipients = Array(Self.email.bccRecipients.prefix(bccCount))
        let kept = email.constructContent(includeBccHeader: true)
        Self.expectRoles(in: kept, to: [], cc: email.ccRecipients, bcc: email.bccRecipients)
        #expect(kept.contains("Body text."))
    }

    @Test("no Bcc header when there are no BCC recipients")
    func noBccRecipientsNoHeader() {
        var email = Self.email
        email.bccRecipients = []
        #expect(!Self.headerSection(email.constructContent(includeBccHeader: true)).lowercased().contains("bcc:"))
    }

    // MARK: - removingBccFields (sendDraft's SMTP copy)

    private static func strip(_ text: String) throws -> String {
        String(bytes: try IMAPServer.removingBccFields(from: Data(text.utf8)), encoding: .utf8) ?? ""
    }

    @Test("removes a Bcc field and its folded continuation lines, any case")
    func removesFoldedBcc() throws {
        let raw = "From: me@example.com\r\nBCC: one@example.com,\r\n two@example.com,\r\n\tthree@example.com\r\n"
            + "To: you@example.com\r\nSubject: Hi\r\n\r\nBody\r\n"
        #expect(try Self.strip(raw) == "From: me@example.com\r\nTo: you@example.com\r\nSubject: Hi\r\n\r\nBody\r\n")
    }

    @Test("removes every Bcc field, whatever whitespace comes before the colon",
          arguments: ["", " ", "\t", "  ", " \t "])
    func removesEveryBcc(whitespace: String) throws {
        let raw = "Bcc: a@example.com\r\nTo: you@example.com\r\nbcc\(whitespace): b@example.com\r\n\r\nBody\r\n"
        #expect(try Self.strip(raw) == "To: you@example.com\r\n\r\nBody\r\n")
    }

    @Test("keeps the body, even a body line that looks like a Bcc field")
    func keepsBody() throws {
        let raw = "To: you@example.com\r\n\r\nBcc: not-a-header@example.com\r\n"
        #expect(try Self.strip(raw) == raw)
    }

    @Test("keeps fields whose name only starts or ends with Bcc")
    func keepsSimilarNames() throws {
        let raw = "X-Bcc: a@example.com\r\nBcc-Note: b\r\nResent-To: c@example.com\r\n\r\nBody\r\n"
        #expect(try Self.strip(raw) == raw)
    }

    /// Resent-Bcc means what Bcc means (RFC 5322 section 3.6.6), and sendDraft
    /// does not send resent messages, so a draft carrying one is not sent.
    @Test("refuses a header with a Resent-Bcc field", arguments: ["Resent-Bcc", "resent-BCC", "Resent-Bcc \t"])
    func refusesResentBcc(name: String) {
        let raw = "To: you@example.com\r\n\(name): hidden@example.com\r\n\r\nBody\r\n"
        #expect(throws: IMAPError.self) { try Self.strip(raw) }
    }

    @Test("keeps a Resent-Bcc line in the body")
    func keepsResentBccInBody() throws {
        let raw = "To: you@example.com\r\n\r\nResent-Bcc: not-a-header@example.com\r\n"
        #expect(try Self.strip(raw) == raw)
    }

    @Test("keeps folded visible fields byte for byte, and a whitespace-only continuation is not the blank line")
    func keepsFoldedVisibleFields() throws {
        let raw = "To: a@example.com,\r\n\tb@example.com\r\nX-Note: n\r\n \r\nBcc: hidden@example.com,\r\n \r\n"
            + " second@example.com\r\nCc: c@example.com\r\n\r\nBody\r\n"
        let stripped = try Self.strip(raw)
        #expect(stripped
            == "To: a@example.com,\r\n\tb@example.com\r\nX-Note: n\r\n \r\nCc: c@example.com\r\n\r\nBody\r\n")
        #expect(!stripped.contains("hidden@example.com"))
        #expect(!stripped.contains("second@example.com"))
    }

    // MARK: - Blind-copy fields in additionalHeaders (SMTP send)

    @Test("an SMTP send refuses a blind-copy field given as an additional header",
          arguments: ["Bcc", "bcc", "Resent-Bcc", " RESENT-BCC "])
    func sendRefusesBlindAdditionalHeader(name: String) {
        var email = Self.email
        email.additionalHeaders = [name: "extra@example.com"]
        #expect(throws: SMTPError.self) { try SMTPServer.prepareEmailForSend(email, capabilities: []) }
    }

    @Test("an SMTP send keeps other additional headers")
    func sendKeepsOtherAdditionalHeaders() throws {
        var email = Self.email
        email.additionalHeaders = ["X-Bcc-Note": "n", "Resent-To": "resent@example.com"]
        let prepared = try SMTPServer.prepareEmailForSend(email, capabilities: [])
        let content = String(bytes: prepared.contentData, encoding: .utf8) ?? ""
        #expect(Self.fields("X-Bcc-Note", in: content) == ["n"])
        #expect(Self.fields("Resent-To", in: content) == ["resent@example.com"])
        #expect(!content.contains("hidden@example.com"))
    }

    @Test("keeps a line with no colon, and a header section with no blank line after it")
    func keepsMalformedLines() throws {
        #expect(try Self.strip("To: you@example.com\r\nbcc\r\nSubject: Hi\r\n\r\nBody")
            == "To: you@example.com\r\nbcc\r\nSubject: Hi\r\n\r\nBody")
        #expect(try Self.strip("To: you@example.com\r\nBcc: a@example.com") == "To: you@example.com\r\n")
    }

    /// Readers disagree on where a line with a lone carriage return ends, so a
    /// Bcc field could hide behind one. Such a header is refused, not guessed at.
    @Test("refuses a header with a carriage return that no line feed follows", arguments: [
        "To: you@example.com\r\n\rX-Note: odd\r\nBcc: a@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\rBcc: a@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\r\r\nBcc: a@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\nBcc: a@example.com\r"
    ])
    func refusesBareCRInHeader(raw: String) {
        #expect(throws: IMAPError.self) { try Self.strip(raw) }
    }

    @Test("keeps a lone carriage return in the body")
    func keepsBareCRInBody() throws {
        #expect(try Self.strip("To: you@example.com\r\nBcc: a@example.com\r\n\r\nBody\rmore\r\n")
            == "To: you@example.com\r\n\r\nBody\rmore\r\n")
    }

    @Test("handles bare LF line endings")
    func handlesBareLF() throws {
        let raw = "From: me@example.com\nBcc: one@example.com,\n two@example.com\nTo: you@example.com\n\nBody\n"
        #expect(try Self.strip(raw) == "From: me@example.com\nTo: you@example.com\n\nBody\n")
    }

    @Test("keeps bytes that are not UTF-8 unchanged")
    func keepsNonUTF8Bytes() throws {
        var raw = Data("Subject: caf".utf8)
        raw.append(0xE9)  // Latin-1 e-acute
        raw.append(contentsOf: Data("\r\nBcc: a@example.com\r\n\r\n".utf8))
        raw.append(0xFF)
        var expected = Data("Subject: caf".utf8)
        expected.append(0xE9)
        expected.append(contentsOf: Data("\r\n\r\n".utf8))
        expected.append(0xFF)
        #expect(try IMAPServer.removingBccFields(from: raw) == expected)
    }

    @Test("a kept copy loses exactly its Bcc header and nothing else")
    func keptCopyRoundTrip() throws {
        let kept = Self.email.constructContent(includeBccHeader: true)
        let bccLine = kept.components(separatedBy: "\r\n").first { $0.hasPrefix("Bcc: ") } ?? ""
        #expect(!bccLine.isEmpty)
        #expect(try Self.strip(kept) == kept.replacingOccurrences(of: bccLine + "\r\n", with: ""))
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
            let stored = String(bytes: appended, encoding: .utf8) ?? ""
            #expect(BccHeaderTests.fields("To", in: stored) == ["to@example.com"])
            #expect(BccHeaderTests.fields("Cc", in: stored).isEmpty)
            #expect(BccHeaderTests.fields("Bcc", in: stored) == ["Hidden <hidden@example.com>"])
            #expect(stored.contains("Draft body."))
        }

        @Test("sendEmail delivers to BCC recipients without naming them")
        func sendEmailKeepsBccOutOfTheDeliveredCopy() async throws {
            let smtp = SMTPCaptureServer()
            try await smtp.start()
            let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
            try await client.connect()
            _ = try await client.sendEmail(BccHeaderTests.email)
            try await client.disconnect()
            try await smtp.stop()

            #expect(smtp.recipients.sorted()
                == ["cc@example.com", "hidden@example.com", "second@example.com", "to@example.com"])
            let delivered = String(bytes: smtp.content, encoding: .utf8) ?? ""
            #expect(delivered.contains("Body text."))
            #expect(!delivered.contains("hidden@example.com"))
            #expect(!delivered.contains("second@example.com"))
        }

        @Test("sendEmail refuses a blind-copy additional header and sends nothing")
        func sendEmailRefusesBlindAdditionalHeader() async throws {
            var email = BccHeaderTests.email
            email.additionalHeaders = ["Resent-Bcc": "resent@example.com"]
            let smtp = SMTPCaptureServer()
            try await smtp.start()
            let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
            try await client.connect()
            await #expect(throws: SMTPError.self) { try await client.sendEmail(email) }
            try await client.disconnect()
            try await smtp.stop()
            #expect(smtp.recipients.isEmpty)
            #expect(smtp.content.isEmpty)
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
            let testServer = try await Self.runTestServer(seeding: draft) { server in
                let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
                try await client.connect()
                _ = try await server.sendDraft(uid: UID(1), via: client, from: "Drafts", to: "Sent")
                try await client.disconnect()
            }
            try await smtp.stop()
            #expect(testServer.appendedMessages.count == 1)
            let appended = try #require(testServer.appendedMessages.first)

            // The draft is retired only after its Sent copy is stored.
            let commands = testServer.commandLog.map { $0.uppercased() }
            let append = commands.firstIndex { $0.contains(" APPEND ") }
            let store = commands.firstIndex {
                $0.contains(" STORE ") && $0.contains("+FLAGS") && $0.contains("\\DELETED")
            }
            let expunge = commands.firstIndex { $0.contains("EXPUNGE") }
            #expect(append != nil && store != nil && expunge != nil)
            if let append, let store, let expunge {
                #expect(append < store && store < expunge)
            }

            #expect(smtp.recipients.sorted() == ["hidden@example.com", "to@example.com"])
            let delivered = String(bytes: smtp.content, encoding: .utf8) ?? ""
            #expect(delivered.contains("Draft body."))
            #expect(!delivered.contains("hidden@example.com"))
            let sentCopy = (String(bytes: appended, encoding: .utf8) ?? "")
                .components(separatedBy: "\r\n\r\n").first ?? ""
            #expect(sentCopy.components(separatedBy: "\r\n").contains("Bcc: Hidden <hidden@example.com>"))
        }

        /// A draft whose header holds a lone carriage return or a Resent-Bcc
        /// field is refused before anything reaches SMTP, and stays in the
        /// Drafts folder as it was.
        @Test("sendDraft refuses a draft it cannot send without disclosing a blind recipient",
              arguments: ["\rX-Note: odd", "Resent-Bcc: resent@example.com"])
        func sendDraftRefusesUnsafeHeader(line: String) async throws {
            let draft = "From: sender@example.com\r\nTo: to@example.com\r\n\(line)\r\n"
                + "Bcc: hidden@example.com\r\nSubject: Draft\r\nMessage-ID: <draft-cr@example.com>\r\n"
                + "\r\nDraft body.\r\n"
            let smtp = SMTPCaptureServer()
            try await smtp.start()
            let testServer = try await Self.runTestServer(seeding: draft) { server in
                let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
                try await client.connect()
                await #expect(throws: IMAPError.self) {
                    try await server.sendDraft(uid: UID(1), via: client, from: "Drafts", to: "Sent")
                }
                try await client.disconnect()
            }
            try await smtp.stop()

            #expect(smtp.recipients.isEmpty)
            #expect(smtp.content.isEmpty)
            #expect(testServer.appendedMessages.isEmpty)
            let commands = testServer.commandLog.map { $0.uppercased() }
            #expect(commands.contains { $0.contains("FETCH") })
            #expect(!commands.contains { $0.contains("STORE") || $0.contains("EXPUNGE") })
        }

        /// Runs `body` against an IMAP test server whose one mailbox holds
        /// `seeding` (when given), and returns the one message it APPENDed.
        private static func appendedMessage(
            seeding message: String? = nil,
            _ body: (IMAPServer) async throws -> Void
        ) async throws -> Data {
            let messages = try await runTestServer(seeding: message, body).appendedMessages
            #expect(messages.count == 1)
            return try #require(messages.first)
        }

        /// Runs `body` against an IMAP test server whose one mailbox holds
        /// `seeding` (when given), and returns the stopped server.
        private static func runTestServer(
            seeding message: String? = nil,
            _ body: (IMAPServer) async throws -> Void
        ) async throws -> IMAPTestServer {
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
            return testServer
        }
    }
#endif
