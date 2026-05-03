// SessionListViewController.swift — UIViewController for browsing and exporting recording sessions.

#if canImport(UIKit)
import UIKit
import SwiftUI

// MARK: - SessionListViewController

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
    private let model: SessionListModel

    public init(store: SessionStore = .shared) {
        self.store = store
        self.model = SessionListModel(store: store)
        super.init(nibName: nil, bundle: nil)
        title = "Recordings"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupNavigationBar()
        embedListView()
    }

    // MARK: - Setup

    private func setupNavigationBar() {
        let isModal = navigationController?.presentingViewController != nil
                   || presentingViewController != nil
        if isModal {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "닫기",
                style: .plain,
                target: self,
                action: #selector(dismissSelf)
            )
        }

        let removeAll = UIBarButtonItem(
            title: "Remove All",
            style: .plain,
            target: self,
            action: #selector(confirmRemoveAll)
        )
        removeAll.tintColor = .systemRed
        navigationItem.rightBarButtonItem = removeAll
    }

    private func embedListView() {
        let listView = SessionListView(model: model) { [weak self] item in
            self?.pushDetail(for: item)
        }
        let host = UIHostingController(rootView: listView)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    // MARK: - Actions

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }

    @objc private func confirmRemoveAll() {
        let alert = UIAlertController(
            title: "Remove All Sessions",
            message: "All recording sessions will be permanently deleted.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Remove All", style: .destructive) { [weak self] _ in
            Task { await self?.model.deleteAll() }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }

    private func pushDetail(for item: SessionListItem) {
        let vc = SessionDetailViewController(item: item, store: store)
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: - SessionDetailViewController

@MainActor
final class SessionDetailViewController: UIViewController {
    private let item: SessionListItem
    private let store: SessionStore

    init(item: SessionListItem, store: SessionStore) {
        self.item = item
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = item.meta.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            style: .plain,
            target: self,
            action: #selector(shareSession)
        )

        let host = UIHostingController(rootView: SessionDetailView(item: item, store: store))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    @objc private func shareSession() {
        Task {
            do {
                let url = try await store.exportSession(id: item.meta.id)
                let shareVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                shareVC.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
                present(shareVC, animated: true)
            } catch {
                let alert = UIAlertController(title: "Export Failed", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
private final class SessionListModel: ObservableObject {
    @Published private(set) var items: [SessionListItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await store.listSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAll() async {
        do {
            try await store.deleteAllSessions()
            items = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: String) async {
        do {
            try await store.deleteSession(id: id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func export(id: String) async throws -> URL {
        try await store.exportSession(id: id)
    }
}

// MARK: - SessionListView

@MainActor
private struct SessionListView: View {
    @ObservedObject var model: SessionListModel
    let onSelect: (SessionListItem) -> Void

    @State private var exportItem: ExportItem?

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Start a recording session to capture network traffic.")
                )
            } else {
                List {
                    ForEach(model.items, id: \.meta.id) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            SessionRowView(item: item)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task {
                                    do {
                                        let url = try await model.export(id: item.meta.id)
                                        exportItem = ExportItem(url: url)
                                    } catch {
                                        model.errorMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await model.delete(id: item.meta.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $exportItem) { item in
            ShareActivityView(url: item.url)
                .ignoresSafeArea()
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}

// MARK: - SessionDetailView

@MainActor
private struct SessionDetailView: View {
    let item: SessionListItem
    let store: SessionStore

    @State private var entries: [HAREntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Session Info") {
                        LabeledContent("Started") {
                            Text(item.meta.startedAt.formatted(date: .complete, time: .standard))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Last Updated") {
                            Text(item.meta.lastUpdatedAt.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Requests", value: "\(item.meta.entryCount)")
                        if item.isCurrentSession {
                            Label("Current Session", systemImage: "record.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }

                    if !entries.isEmpty {
                        Section("Requests (\(entries.count))") {
                            ForEach(entries.indices, id: \.self) { i in
                                EntryRowView(entry: entries[i])
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await loadEntries() }
    }

    private func loadEntries() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await store.loadEntries(id: item.meta.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - EntryRowView

@MainActor
private struct EntryRowView: View {
    let entry: HAREntry

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.response.status == 0 ? "ERR" : "\(entry.response.status)")
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(statusColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .frame(minWidth: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.request.method)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(entry.request.url)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(String(format: "%.0f ms", entry.time))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch entry.response.status {
        case 200..<300: .green
        case 300..<400: .orange
        case 400..<600: .red
        default: .secondary
        }
    }
}

// MARK: - SessionRowView

@MainActor
private struct SessionRowView: View {
    let item: SessionListItem

    var body: some View {
        HStack(spacing: 12) {
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

// MARK: - ShareActivityView

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
