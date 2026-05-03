// SessionListViewController.swift — UIViewController for browsing and exporting recording sessions.

#if canImport(UIKit)
import UIKit
import SwiftUI

/// A UIViewController that lists all persisted recording sessions.
///
/// Embed in a `UINavigationController` for the best experience:
/// ```swift
/// let vc = SessionListViewController()
/// let nav = UINavigationController(rootViewController: vc)
/// present(nav, animated: true)
/// ```
@MainActor
public final class SessionListViewController: UIViewController {
    private let store: SessionStore

    public init(store: SessionStore = .shared) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "Recordings"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: SessionListView(store: store))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        if presentingViewController != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(dismiss(_:))
            )
        }
    }

    @objc private func dismiss(_ sender: Any) {
        dismiss(animated: true)
    }
}

// MARK: - SwiftUI implementation

@MainActor
private struct SessionListView: View {
    let store: SessionStore

    @State private var items: [SessionListItem] = []
    @State private var isLoading = false
    @State private var exportItem: ExportItem?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Start a recording session to capture network traffic.")
                )
            } else {
                List {
                    ForEach(items, id: \.meta.id) { item in
                        SessionRowView(item: item)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task { await export(id: item.meta.id) }
                                } label: {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await delete(id: item.meta.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Recordings")
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $exportItem) { item in
            ShareActivityView(url: item.url)
                .ignoresSafeArea()
        }
        .task { await loadSessions() }
        .refreshable { await loadSessions() }
    }

    // MARK: - Actions

    private func loadSessions() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await store.listSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export(id: String) async {
        do {
            let url = try await store.exportSession(id: id)
            exportItem = ExportItem(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(id: String) async {
        do {
            try await store.deleteSession(id: id)
            await loadSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row view

@MainActor
private struct SessionRowView: View {
    let item: SessionListItem

    var body: some View {
        HStack(spacing: 12) {
            // Recording indicator
            ZStack {
                Circle()
                    .fill(item.isCurrentSession ? Color.red.opacity(0.12) : Color.secondary.opacity(0.1))
                    .frame(width: 40, height: 40)
                Image(systemName: item.isCurrentSession ? "record.circle.fill" : "waveform")
                    .foregroundStyle(item.isCurrentSession ? .red : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.meta.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.weight(.semibold))
                    if item.isCurrentSession {
                        Text("CURRENT")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.red, in: Capsule())
                    }
                }
                HStack(spacing: 10) {
                    Label("\(item.meta.entryCount)", systemImage: "arrow.up.arrow.down")
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("Updated " + item.meta.lastUpdatedAt.formatted(.relative(presentation: .named)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Share sheet wrapper

@MainActor
private struct ShareActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Helpers

private struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

#endif
