import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Send Draft Orchestration

extension IMAPServer {
    /// Send a draft message via SMTP and move it to the Sent folder.
    ///
    /// This method orchestrates the full send-draft workflow:
    /// 1. Resolves the drafts and sent mailboxes via special-use attributes (or throws if not found).
    /// 2. Selects the draft mailbox and fetches the raw message + envelope info.
    /// 3. Sends the raw message via the provided ``SMTPServer``, without its `Bcc` header.
    ///    A draft whose header holds a carriage return without a line feed is
    ///    not sent.
    /// 4. Appends the message, `Bcc` header included, to the Sent folder with the `\Seen` flag and current date.
    /// 5. Marks the draft as `\Deleted` and expunges it (UID EXPUNGE when available).
    ///
    /// - Parameters:
    ///   - draftUID: UID of the draft message.
    ///   - smtp: A connected and authenticated ``SMTPServer``.
    ///   - draftMailbox: Source mailbox path. If `nil`, uses ``draftsFolder`` (throws if unavailable).
    ///   - sentMailbox: Destination mailbox path. If `nil`, uses ``sentFolder`` (throws if unavailable).
    /// - Returns: The UID of the message in the Sent folder, if the server supports UIDPLUS.
    /// - Throws: ``UndefinedFolderError`` if drafts/sent folders cannot be resolved and no explicit path is provided;
    ///   ``IMAPError/invalidArgument(_:)`` if the draft cannot be sent as stored, which leaves it in place.
    @discardableResult
    public func sendDraft(
        uid draftUID: UID,
        via smtp: SMTPServer,
        from draftMailbox: String? = nil,
        to sentMailbox: String? = nil
    ) async throws -> UID? {
        // 1. Resolve mailbox paths via special-use attributes (or use explicit overrides)
        let resolvedDraftMailbox = try draftMailbox ?? draftsFolder.name
        let resolvedSentMailbox = try sentMailbox ?? sentFolder.name

        // 2. Select the drafts mailbox
        try await selectMailbox(resolvedDraftMailbox)

        // 3. Fetch raw message and envelope info
        let rawMessageData = try await fetchRawMessage(identifier: draftUID)

        guard let messageInfo = try await fetchMessageInfo(for: draftUID) else {
            throw IMAPError.fetchFailed("Could not fetch message info for draft UID \(draftUID.value)")
        }

        // 4. Extract sender and recipients from the envelope
        let (sender, recipients) = try Self.sendDraftAddresses(from: messageInfo)

        // 5. Send via SMTP. BCC recipients are envelope recipients only: the
        // draft names them in a Bcc header, which must not reach the people
        // the message is delivered to (RFC 5322 section 3.6.3).
        try await smtp.sendRawMessage(Self.removingBccFields(from: rawMessageData), from: sender, to: recipients)

        // 6. Append to Sent folder with \Seen flag.
        let appendResult = try await appendDraftToSent(rawMessageData: rawMessageData, mailbox: resolvedSentMailbox)

        // 7. Delete the draft and expunge
        try await deleteAndExpungeDraft(draftUID: draftUID)

        return appendResult.firstUID
    }

    // MARK: - Send Draft Helpers

    /// The sender and recipients of a draft, read from its envelope info.
    ///
    /// Each field may name several addresses and groups; group members are
    /// recipients like any other. The draft is rejected rather than sent to
    /// fewer people than it names when a recipient field holds text that is
    /// not an address.
    static func sendDraftAddresses(
        from messageInfo: MessageInfo
    ) throws -> (sender: EmailAddress, recipients: [EmailAddress]) {
        guard !messageInfo.fromAddresses.isEmpty else {
            throw IMAPError.invalidArgument("Draft has no sender address")
        }
        guard let sender = messageInfo.fromAddresses.mailboxes.first else {
            throw IMAPError.invalidArgument("Draft has invalid sender address")
        }

        let entries = messageInfo.toAddresses + messageInfo.ccAddresses + messageInfo.bccAddresses
        guard !entries.isEmpty else {
            throw IMAPError.invalidArgument("Draft has no recipients")
        }

        if case .invalid(let text) = entries.first(where: \.isInvalid) {
            throw IMAPError.invalidArgument("Draft has an invalid recipient address: \(text)")
        }

        let recipients = entries.mailboxes
        guard !recipients.isEmpty else {
            throw IMAPError.invalidArgument("Draft has no valid recipient addresses")
        }

        return (sender, recipients)
    }

    /// The message with every `Bcc` field removed from its header section,
    /// folded continuation lines included. The body and every other byte are
    /// kept as they are, so a message in any charset survives unchanged.
    ///
    /// - Throws: ``IMAPError/invalidArgument(_:)`` when the header section
    ///   holds a carriage return that is not followed by a line feed. Readers
    ///   disagree on where such a line ends, so a `Bcc` field could hide behind
    ///   it; the draft is not sent and stays as it is.
    static func removingBccFields(from message: Data) throws -> Data {
        let bytes = [UInt8](message)
        let lineFeed: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var dropping = false
        var lineStart = 0
        while lineStart < bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: lineFeed).map { $0 + 1 } ?? bytes.count
            let line = bytes[lineStart..<lineEnd]
            // The line without its LF or CRLF ending.
            var content = line
            if content.last == lineFeed {
                content = content.dropLast()
                if content.last == carriageReturn { content = content.dropLast() }
            }
            if content.contains(carriageReturn) {
                throw IMAPError.invalidArgument("Draft header has a carriage return without a line feed")
            }
            if content.isEmpty {
                // The blank line ends the header section; the rest is the body.
                output.append(contentsOf: bytes[lineStart...])
                break
            }
            if let first = content.first, first == 0x20 || first == 0x09 {
                // A folded continuation belongs to the field above it.
            } else {
                dropping = Self.isBccField(content)
            }
            if !dropping {
                output.append(contentsOf: line)
            }
            lineStart = lineEnd
        }
        return Data(output)
    }

    private static func isBccField(_ line: ArraySlice<UInt8>) -> Bool {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { return false }
        var name = line[line.startIndex..<colon]
        while let last = name.last, last == 0x20 || last == 0x09 {
            name = name.dropLast()
        }
        // ASCII case folding: `| 0x20` maps only `B`/`b` to `b` and `C`/`c` to `c`.
        return name.map { $0 | 0x20 } == Array("bcc".utf8)
    }

    /// Append the raw draft message to the Sent mailbox with the `\Seen` flag.
    private func appendDraftToSent(rawMessageData: Data, mailbox: String) async throws -> AppendResult {
        // Raw messages may include non-UTF-8 bytes (Latin-1 etc.) that we still need to
        // preserve verbatim; lossy decoding keeps replacement chars rather than
        // dropping the message entirely.
        var rawMessageString = rawMessageData.lossyUTF8String
        rawMessageString = canonicalizeCRLF(rawMessageString)
        if !rawMessageString.hasSuffix("\r\n") {
            rawMessageString.append("\r\n")
        }

        return try await append(
            rawMessage: rawMessageString,
            to: mailbox,
            flags: [.seen],
            internalDate: Date()
        )
    }

    /// Mark the draft message as deleted and expunge it.
    private func deleteAndExpungeDraft(draftUID: UID) async throws {
        let draftUIDSet = UIDSet(draftUID)
        try await store(flags: [.deleted], on: draftUIDSet, operation: .add)

        if supportsUIDPlus {
            try await expunge(messages: draftUIDSet)
        } else {
            try await expunge()
        }
    }
}
