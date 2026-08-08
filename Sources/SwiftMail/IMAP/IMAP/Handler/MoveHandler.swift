// MoveHandler.swift
// Handler for IMAP MOVE command

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP MOVE command.
///
/// Extracts the `COPYUID` response code from the tagged OK when the server includes one
/// (RFC 6851 §3.3). Returns `nil` when the server omits `COPYUID`.
final class MoveHandler: BaseIMAPCommandHandler<CopyUID?>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = CopyUID?

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)

        do {
            succeedWithResult(try extractCopyUID(from: response))
        } catch {
            // The tagged OK is authority that MOVE completed. A malformed
            // optional COPYUID makes only the address mapping unusable; turning
            // it into command failure would make a durable caller retry an
            // already-committed move.
            succeedWithResult(nil)
        }
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.moveFailed(String(describing: response.state)))
    }
}

private extension MoveHandler {
    func extractCopyUID(from response: TaggedResponse) throws -> CopyUID? {
        guard case .ok(let text) = response.state,
              let code = text.code,
              case .uidCopy(let data) = code
        else {
            return nil
        }
        return try CopyUID(nio: data)
    }
}
