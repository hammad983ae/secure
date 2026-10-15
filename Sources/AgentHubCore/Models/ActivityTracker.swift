import Foundation

/// Infers a terminal agent's status from its output stream.
///
/// Terminal agents don't report "I'm waiting for you" in a standard way, so the
/// hub uses a heuristic: output flowing means running; silence for `idleAfter`
/// seconds means the agent is probably waiting for input; process exit decides
/// done vs failed. Time is passed in so the logic is testable.
public struct ActivityTracker: Sendable {
    public var idleAfter: TimeInterval
    public private(set) var status: SessionStatus = .running
    public private(set) var lastOutput: Date

    public init(idleAfter: TimeInterval = 4, now: Date = Date()) {
        self.idleAfter = idleAfter
        self.lastOutput = now
    }

    /// Record output. Returns the new status if it changed.
    @discardableResult
    public mutating func outputReceived(at now: Date) -> SessionStatus? {
        guard !isFinished else { return nil }
        lastOutput = now
        return transition(to: .running)
    }

    /// Call periodically. Returns the new status if it changed.
    @discardableResult
    public mutating func tick(at now: Date) -> SessionStatus? {
        guard !isFinished, status == .running else { return nil }
        guard now.timeIntervalSince(lastOutput) >= idleAfter else { return nil }
        return transition(to: .needsInput)
    }

    /// Record process exit. A nil exit code (killed by signal) counts as failure.
    @discardableResult
    public mutating func processExited(code: Int32?) -> SessionStatus? {
        transition(to: code == 0 ? .done : .failed)
    }

    /// Mark the session busy again after the user sends it input.
    @discardableResult
    public mutating func inputSent(at now: Date) -> SessionStatus? {
        guard !isFinished else { return nil }
        lastOutput = now
        return transition(to: .running)
    }

    public var isFinished: Bool { status == .done || status == .failed }

    private mutating func transition(to new: SessionStatus) -> SessionStatus? {
        guard new != status else { return nil }
        status = new
        return new
    }
}
