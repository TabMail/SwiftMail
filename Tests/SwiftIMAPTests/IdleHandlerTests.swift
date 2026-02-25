import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

struct IdleHandlerTests {
    @Test
    func testIdleStartedKeepsHandlerActiveUntilTaggedOK() async throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        try await channel.pipeline.addHandler(IMAPClientHandler())

        var continuationRef: AsyncStream<IMAPServerEvent>.Continuation?
        _ = AsyncStream<IMAPServerEvent> { continuation in
            continuationRef = continuation
        }

        guard let continuation = continuationRef else {
            Issue.record("Failed to create IDLE test stream continuation")
            return
        }

        let promise = channel.eventLoop.makePromise(of: Void.self)
        let handler = IdleHandler(commandTag: "A001", promise: promise, continuation: continuation)
        try await channel.pipeline.addHandler(handler)

        let idleStart = TaggedCommand(tag: "A001", command: .idleStart)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(idleStart)))

        guard var idleCommandLine = try channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound IDLE command")
            return
        }
        #expect(idleCommandLine.readString(length: idleCommandLine.readableBytes) == "A001 IDLE\r\n")

        var idleConfirmation = channel.allocator.buffer(capacity: 0)
        idleConfirmation.writeString("+ idling\r\n")
        try channel.writeInbound(idleConfirmation)

        #expect(!handler.isCompleted)
        #expect(handler.hasEnteredIdleState)

        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.idleDone))

        guard var doneLine = try channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound DONE command")
            return
        }
        #expect(doneLine.readString(length: doneLine.readableBytes) == "DONE\r\n")

        var taggedOK = channel.allocator.buffer(capacity: 0)
        taggedOK.writeString("A001 OK Idle terminated\r\n")
        try channel.writeInbound(taggedOK)

        try await promise.futureResult.get()
        #expect(handler.isCompleted)
    }
}
