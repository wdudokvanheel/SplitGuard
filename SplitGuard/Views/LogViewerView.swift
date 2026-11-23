import SwiftUI

struct LogViewerView: View {
    @State private var viewModel = LogViewerViewModel()
    @State private var exportedLogFile: ExportFileItem?
    @State private var exportAlert: AlertItem?
    @State private var isExporting = false

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading log…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SGColor.surfacePrimary)
            } else if viewModel.isLogUnavailable {
                ContentUnavailableView(
                    "Log Unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("The shared tunnel log file could not be opened.")
                )
            } else if viewModel.entries.isEmpty {
                ContentUnavailableView(
                    "No Log Entries Yet",
                    systemImage: "text.alignleft",
                    description: Text("Tunnel and app activity will appear here.")
                )
            } else {
                logEntriesList
            }
        }
        .navigationTitle(tr("logViewTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "Filter log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportLog()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(isExporting || (viewModel.isLogUnavailable && viewModel.entries.isEmpty))
                .accessibilityLabel("Export log")
            }
        }
        .onAppear {
            viewModel.startPolling()
        }
        .onDisappear {
            viewModel.stopPolling()
        }
        .sheet(item: $exportedLogFile) { item in
            ActivityShareSheet(activityItems: [item.url]) {
                _ = FileManager.deleteFile(at: item.url)
                exportedLogFile = nil
            }
        }
        .alert(
            exportAlert?.title ?? "",
            isPresented: Binding(
                get: { exportAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        exportAlert = nil
                    }
                }
            )
        ) {
            Button(tr("actionOK"), role: .cancel) {
                exportAlert = nil
            }
        } message: {
            Text(exportAlert?.message ?? "")
        }
    }

    private var logEntriesList: some View {
        ScrollViewReader { proxy in
            List(viewModel.filteredEntries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.timestamp)
                        .font(SGTypography.metricLabel.monospaced())
                        .foregroundStyle(SGColor.textSecondary)
                    Text(entry.message)
                        .font(SGTypography.monoCompact)
                        .foregroundStyle(SGColor.textPrimary)
                        .textSelection(.enabled)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: viewModel.entries.count) { _, _ in
                guard viewModel.searchText.isEmpty, let lastID = viewModel.entries.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private func exportLog() {
        isExporting = true
        viewModel.exportLogFile { result in
            isExporting = false
            switch result {
            case .success(let url):
                exportedLogFile = ExportFileItem(url: url)
            case .failure(let alert):
                exportAlert = alert
            }
        }
    }
}
