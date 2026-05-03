// RecordingHost.swift — Actor singleton that orchestrates recording lifecycle and HAR export.
// E2ERecordingTest drives this via APIProvider.shared.

import Foundation
import NetworkRecorder

/// Singleton that starts/stops recording and exports the captured HAR file.
///
/// The host wraps `APIProvider.shared.session` so callers never manipulate the session directly.
@MainActor
final class RecordingHost {
    static let shared = RecordingHost()

    private let session: RecordingSession

    init() {
        self.session = APIProvider.shared.session
    }

    /// Transitions the session to `.recording` state.
    func startRecording() async {
        await session.startRecording()
    }

    /// Transitions the session to `.stopped` state.
    func stopRecording() async {
        await session.stopRecording()
    }

    /// Exports the current session snapshot to a `.har` file.
    ///
    /// - Returns: URL of the written file (inside the simulator's tmp directory).
    /// - Note: T7 QA retrieves this path from the printed `HAR_PATH=` line in test output.
    func exportHAR() async throws -> URL {
        let exporter = HARExporter()
        return try await exporter.exportToFile(session: session)
    }
}
