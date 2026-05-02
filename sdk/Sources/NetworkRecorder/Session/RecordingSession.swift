// RecordingSession.swift — Actor that owns the recorded HAR entries.

import Foundation

/// An actor that manages a network recording session.
///
/// The session owns the `entries` array (actor-isolated) and a `PendingStore`
/// (`nonisolated let`) that the plugin accesses synchronously from Moya callbacks.
public actor RecordingSession {
    private var entries: [HAREntry] = []
    private var _state: RecordingState = .idle
    private let creator: HARCreator

    /// Synchronous, NSLock-protected store for in-flight request correlations.
    /// `nonisolated` so plugin callbacks can access it without crossing the actor boundary.
    nonisolated let pending = PendingStore()

    public init(
        creatorName: String = "ios-network-recorder",
        creatorVersion: String = "0.1.0"
    ) {
        self.creator = HARCreator(name: creatorName, version: creatorVersion)
    }

    // MARK: - State transitions

    /// Returns the current recording state.
    public func state() -> RecordingState { _state }

    /// Transitions: idle/stopped/paused → recording.
    public func startRecording() {
        guard _state == .idle || _state == .stopped || _state == .paused else { return }
        _state = .recording
    }

    /// Transitions: recording → paused.
    public func pauseRecording() {
        guard _state == .recording else { return }
        _state = .paused
    }

    /// Alias for `startRecording()`. Transitions paused → recording.
    public func resumeRecording() {
        startRecording()
    }

    /// Transitions: recording/paused → stopped.
    public func stopRecording() {
        guard _state == .recording || _state == .paused else { return }
        _state = .stopped
    }

    /// Clears all entries and pending store, resets state to idle.
    public func reset() {
        entries.removeAll()
        pending.reset()
        _state = .idle
    }

    // MARK: - Entry management

    /// Appends an entry. Only succeeds when state == .recording.
    /// Defense-in-depth against entries arriving after a pause/stop.
    public func append(_ entry: HAREntry) {
        guard _state == .recording else { return }
        entries.append(entry)
    }

    /// Returns a sorted copy of the entries, sorted by `startedDateTime` ascending.
    /// Sorting compensates for Task-hop reordering on concurrent responses.
    public func snapshot() -> [HAREntry] {
        entries.sorted { $0.startedDateTime < $1.startedDateTime }
    }

    /// Builds a `HARDocument` from the current snapshot. Used by `HARExporter`.
    public func makeDocument() -> HARDocument {
        HARDocument(
            log: HARLog(version: "1.2", creator: creator, entries: snapshot())
        )
    }
}
