// APIProvider.swift — Shared MoyaProvider wired with the NetworkRecorder plugin.

import Moya
import NetworkRecorder

/// Singleton Moya provider with the recorder plugin installed.
///
/// `session` is exposed so `RecordingHost` can drive start/stop/export
/// without reaching through the provider internals.
@MainActor
class APIProvider {
    static let shared = APIProvider()

    let session = RecordingSession()

    private(set) lazy var provider: MoyaProvider<APITarget> = {
        let plugin = MoyaRecorderPlugin(session: session)
        return MoyaProvider<APITarget>(plugins: [plugin])
    }()

    private init() {}
}
