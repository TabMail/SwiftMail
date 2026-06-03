// PipelinedCommandDispatcher.swift
// NIO channel handler that routes responses to multiple in-flight pipelined command handlers.
//
// IMAP RFC 3501 §5.5 allows clients to send multiple commands without waiting for responses.
// The server processes commands in order and sends tagged responses (A001 OK, A002 OK, etc.)
// so responses can be matched to commands by tag. Untagged responses (e.g., * FETCH data)
// carry no tag; they arrive in command order and are routed to the oldest command whose
// untagged response has not yet finished, advancing on each response's `.finish`. A server
// may stream data for several pipelined commands before sending any tagged OK (RFC 3501
// §5.5), so advancing only on the tagged OK would misdeliver a later command's data to an
// already-finished earlier handler and silently drop it.
//
// This handler sits in the NIO pipeline during a pipelined batch. It maintains an ordered
// registry of (tag → PipelinedHandler) and routes responses accordingly.

import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

final class PipelinedCommandDispatcher: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = Response
    typealias InboundOut = Response

    private let lock = NIOLock()

    /// Ordered list of (tag, handler, finishedUntagged) — insertion order matches send
    /// order. Untagged FETCH responses route to the oldest entry whose untagged response
    /// has not finished; `finishedUntagged` flips when that response's `.finish` arrives,
    /// so the next response routes to the next command (even if no tagged OK has arrived).
    private var entries: [(tag: String, handler: any PipelinedHandler, finishedUntagged: Bool)] = []

    private let logger = Logger(label: "com.cocoanetics.SwiftMail.PipelinedDispatcher")

    /// Register a handler for a command tag. Must be called in send order.
    func register(tag: String, handler: any PipelinedHandler) {
        lock.withLock {
            entries.append((tag: tag, handler: handler, finishedUntagged: false))
        }
    }

    // MARK: - ChannelInboundHandler

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)

        lock.withLock {
            switch response {
            case .tagged(let taggedResponse):
                // Route to the handler that owns this tag
                if let idx = entries.firstIndex(where: { $0.tag == taggedResponse.tag }) {
                    let handler = entries[idx].handler
                    handler.processTaggedResponse(taggedResponse)
                    entries.remove(at: idx)
                }

            case .fetch(let fetchResponse):
                // Untagged FETCH responses arrive in command (registration) order. Route to
                // the OLDEST command whose untagged response has not yet finished, and mark it
                // finished when its `.finish` arrives so the NEXT response goes to the NEXT
                // command. A server may emit untagged data for several pipelined commands
                // before any tagged OK (RFC 3501 §5.5); routing on `entries.first` and
                // advancing only on the tagged OK delivered a later part's bytes to an
                // already-finished earlier handler — which dropped them — leaving the later
                // part (e.g. a multipart message's text/html body) empty.
                if let idx = entries.firstIndex(where: { !$0.finishedUntagged }) {
                    entries[idx].handler.processFetchResponse(fetchResponse)
                    if case .finish = fetchResponse {
                        entries[idx].finishedUntagged = true
                    }
                }

            case .untagged(let payload):
                // BYE — server is terminating. Fail all pending handlers.
                if case .conditionalState(let status) = payload, case .bye(let text) = status {
                    let error = IMAPError.connectionFailed("Server terminated connection: \(text.text)")
                    for entry in entries {
                        entry.handler.fail(error)
                    }
                    entries.removeAll()
                }

            case .fatal(let text):
                let error = IMAPError.connectionFailed("Server fatal error: \(text.text)")
                for entry in entries {
                    entry.handler.fail(error)
                }
                entries.removeAll()

            default:
                break
            }
        }

        // Always forward to the next handler in the pipeline (UntaggedResponseBuffer)
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let error = IMAPError.connectionFailed("Connection closed during pipelined fetch")
        lock.withLock {
            for entry in entries {
                entry.handler.fail(error)
            }
            entries.removeAll()
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lock.withLock {
            for entry in entries {
                entry.handler.fail(error)
            }
            entries.removeAll()
        }
        context.fireErrorCaught(error)
    }

    /// Number of handlers still pending (for diagnostics).
    var pendingCount: Int {
        lock.withLock { entries.count }
    }
}
