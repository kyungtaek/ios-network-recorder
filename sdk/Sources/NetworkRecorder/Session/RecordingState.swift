// RecordingState.swift — State machine for a recording session.

/// The current state of a `RecordingSession`.
public enum RecordingState: Equatable, Sendable {
    case idle
    case recording
    case paused
    case stopped
}
