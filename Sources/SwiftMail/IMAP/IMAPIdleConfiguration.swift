import Foundation

/// Configuration for resilient IMAP IDLE sessions.
public struct IMAPIdleConfiguration: Sendable {
    /// RFC 2177 recommends re-issuing IDLE at least every 29 minutes.
    /// Default is 25 minutes for additional safety.
    public var renewalInterval: TimeInterval

    /// Interval between heartbeat checkpoints where DONE + NOOP + re-IDLE occurs.
    /// Default is 5 minutes.
    public var noopInterval: TimeInterval

    /// Timeout while waiting for IDLE to terminate after sending DONE.
    public var doneTimeout: TimeInterval

    /// Initial delay used before reconnecting after a connection failure.
    public var reconnectBaseDelay: TimeInterval

    /// Maximum delay for exponential reconnect backoff.
    public var reconnectMaxDelay: TimeInterval

    public init(
        renewalInterval: TimeInterval = 25 * 60,
        noopInterval: TimeInterval = 5 * 60,
        doneTimeout: TimeInterval = 15,
        reconnectBaseDelay: TimeInterval = 2,
        reconnectMaxDelay: TimeInterval = 30
    ) {
        self.renewalInterval = renewalInterval
        self.noopInterval = noopInterval
        self.doneTimeout = doneTimeout
        self.reconnectBaseDelay = reconnectBaseDelay
        self.reconnectMaxDelay = reconnectMaxDelay
    }

    /// Default production-ready values for resilient IDLE sessions.
    public static let `default` = IMAPIdleConfiguration()
}

extension IMAPIdleConfiguration {
    func validated() throws -> IMAPIdleConfiguration {
        guard renewalInterval > 0 else {
            throw IMAPError.invalidArgument("IDLE renewalInterval must be greater than 0 seconds")
        }
        guard noopInterval > 0 else {
            throw IMAPError.invalidArgument("IDLE noopInterval must be greater than 0 seconds")
        }
        guard doneTimeout > 0 else {
            throw IMAPError.invalidArgument("IDLE doneTimeout must be greater than 0 seconds")
        }
        guard reconnectBaseDelay >= 0 else {
            throw IMAPError.invalidArgument("IDLE reconnectBaseDelay cannot be negative")
        }
        guard reconnectMaxDelay >= reconnectBaseDelay else {
            throw IMAPError.invalidArgument("IDLE reconnectMaxDelay must be >= reconnectBaseDelay")
        }
        return self
    }
}
