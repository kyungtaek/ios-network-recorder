// SampleAppApp.swift — SwiftUI entry point for SampleApp.
// Includes a share sheet (UIActivityViewController) for exporting HAR files.

import SwiftUI
import UIKit

@main
struct SampleAppApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// UIViewControllerRepresentable wrapper around UIActivityViewController.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ContentView: View {
    @State private var isExporting = false
    @State private var harURL: URL?
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("SampleApp")
            Button("Export HAR") {
                Task {
                    do {
                        let url = try await RecordingHost.shared.exportHAR()
                        harURL = url
                        isExporting = true
                    } catch {
                        exportError = error.localizedDescription
                    }
                }
            }
            if let err = exportError {
                Text(err).foregroundColor(.red).font(.caption)
            }
        }
        .sheet(isPresented: $isExporting) {
            if let url = harURL {
                ShareSheet(items: [url])
            }
        }
    }
}
