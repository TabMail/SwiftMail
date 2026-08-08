import Foundation
import NIOIMAPCore
import Testing
@testable import SwiftMail

#if os(macOS)
    @Suite("Atomic-only UID MOVE", .serialized, .timeLimit(.minutes(1)))
    struct AtomicMoveTests {
        @Test("MOVE with UIDPLUS emits one UID MOVE and returns COPYUID")
        func moveWithUIDPlus() async throws {
            try await withServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE", "UIDPLUS"]) { server, testServer in
                let result = try await server.moveAtomically(
                    messages: UIDSet(UID(1)), to: "Archive")
                let copyUID = try #require(result)
                #expect(copyUID.destinationUIDValidity == UIDValidity(2))
                #expect(copyUID.mapping.map(\.source.value) == [1])
                #expect(copyUID.mapping.map(\.destination.value) == [101])
                assertOnlyAtomicMoveWasEmitted(testServer.commandLog)
            }
        }

        @Test("MOVE without UIDPLUS still emits UID MOVE and returns no mapping")
        func moveWithoutUIDPlus() async throws {
            try await withServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE"]) { server, testServer in
                let result = try await server.moveAtomically(
                    messages: UIDSet(UID(1)), to: "Archive")
                #expect(result == nil)
                assertOnlyAtomicMoveWasEmitted(testServer.commandLog)
            }
        }

        @Test("Named connection exposes the same atomic-only UID MOVE contract")
        func namedConnectionMoveWithoutUIDPlus() async throws {
            try await withServer(capabilities: ["IMAP4rev1", "AUTH=PLAIN", "MOVE"]) { server, testServer in
                let named = try await server.connection(named: "atomic-move")
                _ = try await named.selectMailbox("INBOX")

                let result = try await named.moveAtomically(
                    messages: UIDSet(UID(1)), to: "Archive")

                #expect(result == nil)
                assertOnlyAtomicMoveWasEmitted(testServer.commandLog)
            }
        }

        @Test("No MOVE capability refuses before any transport command")
        func noMoveRefusesBeforeTransport() async {
            let server = SwiftMail.IMAPServer(host: "127.0.0.1", port: 1, useTLS: false)
            await server.primaryConnection.replaceCapabilitiesForTesting([])
            do {
                _ = try await server.moveAtomically(messages: UIDSet(UID(1)), to: "Archive")
                Issue.record("Expected commandNotSupported")
            } catch let error as IMAPError {
                guard case .commandNotSupported = error else {
                    Issue.record("Expected commandNotSupported, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected IMAPError.commandNotSupported, got \(error)")
            }
        }

        private func withServer(
            capabilities: [String],
            body: (SwiftMail.IMAPServer, IMAPTestServer) async throws -> Void
        ) async throws {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            let curDir = maildir.appendingPathComponent("cur")
            try FileManager.default.createDirectory(at: curDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let sample = """
            From: Sender <sender@example.com>\r
            To: Recipient <recipient@example.com>\r
            Subject: Atomic move\r
            Date: Thu, 01 Jan 2026 00:00:00 +0000\r
            Message-ID: <atomic@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Body.\r
            """
            try #require(sample.data(using: .utf8)).write(to: curDir.appendingPathComponent("1.eml"))

            let testServer = try IMAPTestServer(
                username: "u", password: "p", advertisedCapabilities: capabilities,
                maildirURL: maildir)
            try testServer.start()
            try await testServer.run {
                let server = SwiftMail.IMAPServer(
                    host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "u", password: "p")
                _ = try await server.selectMailbox("INBOX")
                try await body(server, testServer)
                try await server.disconnect()
            }
        }

        private func assertOnlyAtomicMoveWasEmitted(_ commands: [String]) {
            let upper = commands.map { $0.uppercased() }
            #expect(upper.filter { $0.contains(" UID MOVE ") }.count == 1)
            #expect(upper.allSatisfy { !$0.contains(" UID COPY ") })
            #expect(upper.allSatisfy { !$0.contains(" UID STORE ") })
            #expect(upper.allSatisfy { !$0.contains("UID EXPUNGE") })
            #expect(upper.allSatisfy { !$0.contains(" EXPUNGE") })
        }
    }
#endif
