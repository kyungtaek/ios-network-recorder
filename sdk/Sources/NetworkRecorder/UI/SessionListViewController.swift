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

        let detailView = SessionDetailView(item: item, store: store) { [weak self] entry in
            self?.pushEntryDetail(for: entry)
        }
        let host = UIHostingController(rootView: detailView)
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

    private func pushEntryDetail(for entry: HAREntry) {
        let vc = EntryDetailViewController(entry: entry)
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: - EntryDetailViewController

@MainActor
final class EntryDetailViewController: UIViewController {
    private let entry: HAREntry

    init(entry: HAREntry) {
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
        let comps = URLComponents(string: entry.request.url)
        title = comps?.path.isEmpty == false ? comps!.path : entry.request.url
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: EntryDetailView(entry: entry))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
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
    let onSelectEntry: (HAREntry) -> Void

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
                                Button {
                                    onSelectEntry(entries[i])
                                } label: {
                                    EntryRowView(entry: entries[i])
                                }
                                .buttonStyle(.plain)
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

// MARK: - EntryDetailView

@MainActor
private struct EntryDetailView: View {
    let entry: HAREntry

    private var urlComponents: URLComponents? {
        URLComponents(string: entry.request.url)
    }

    var body: some View {
        List {
            overviewSection
            urlSection
            if !entry.request.queryString.isEmpty { querySection }
            requestHeadersSection
            if entry.request.postData != nil { requestBodySection }
            responseHeadersSection
            responseBodySection
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Sections

    private var overviewSection: some View {
        Section("Overview") {
            HStack(spacing: 10) {
                Text(entry.request.method)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))

                Spacer()

                let status = entry.response.status
                Text(status == 0 ? "ERR" : "\(status)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(statusColor)
                + Text("  \(entry.response.statusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Duration") {
                Text(String(format: "%.0f ms", entry.time))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var urlSection: some View {
        Section("URL") {
            if let comps = urlComponents {
                LabeledContent("Host") {
                    Text(comps.host ?? "—")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Path") {
                    Text(comps.path.isEmpty ? "/" : comps.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let scheme = comps.scheme {
                    LabeledContent("Scheme") {
                        Text(scheme)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Full URL") {
                Text(entry.request.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
    }

    private var querySection: some View {
        Section("Query Parameters") {
            ForEach(Array(entry.request.queryString.enumerated()), id: \.offset) { _, param in
                LabeledContent(param.name) {
                    Text(param.value)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
    }

    private var requestHeadersSection: some View {
        Section("Request Headers (\(entry.request.headers.count))") {
            if entry.request.headers.isEmpty {
                Text("(없음)").foregroundStyle(.tertiary)
            } else {
                ForEach(Array(entry.request.headers.enumerated()), id: \.offset) { _, h in
                    HeaderRowView(name: h.name, value: h.value)
                }
            }
        }
    }

    private var requestBodySection: some View {
        Section("Request Body") {
            if let postData = entry.request.postData {
                LabeledContent("MIME Type", value: postData.mimeType)
                if let params = postData.params, !params.isEmpty {
                    ForEach(Array(params.enumerated()), id: \.offset) { _, p in
                        LabeledContent(p.name) {
                            Text(p.value ?? "—").foregroundStyle(.secondary)
                        }
                    }
                } else if let text = postData.text {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var responseHeadersSection: some View {
        Section("Response Headers (\(entry.response.headers.count))") {
            if entry.response.headers.isEmpty {
                Text("(없음)").foregroundStyle(.tertiary)
            } else {
                ForEach(Array(entry.response.headers.enumerated()), id: \.offset) { _, h in
                    HeaderRowView(name: h.name, value: h.value)
                }
            }
        }
    }

    private var responseBodySection: some View {
        Section("Response Body") {
            LabeledContent("MIME Type", value: entry.response.content.mimeType)
            if let text = entry.response.content.text {
                if entry.response.content.encoding == "base64" {
                    Label("Binary data (base64)", systemImage: "doc.binary")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("(empty)").foregroundStyle(.tertiary)
            }
        }
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

// MARK: - HeaderRowView

@MainActor
private struct HeaderRowView: View {
    let name: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption.bold())
                .foregroundStyle(.primary)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - EntryRowView

@MainActor
private struct EntryRowView: View {
    let entry: HAREntry

    private var urlComponents: URLComponents? {
        URLComponents(string: entry.request.url)
    }
    private var displayHost: String {
        urlComponents?.host ?? entry.request.url
    }
    private var displayPath: String {
        let path = urlComponents?.path ?? ""
        return path.isEmpty ? "/" : path
    }

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
                        .foregroundStyle(.accentColor)
                    Text(displayPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(displayHost)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(String(format: "%.0f ms", entry.time))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
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
