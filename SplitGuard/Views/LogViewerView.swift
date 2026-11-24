import SwiftUI

struct LogViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = LogViewerViewModel()
    @State private var exportedLogFile: ExportFileItem?
    @State private var exportAlert: AlertItem?
    @State private var isExporting = false

    private var isExportDisabled: Bool {
        isExporting || (viewModel.isLogUnavailable && viewModel.entries.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: String(localized: "log.title", defaultValue: "Log"),
                enableSwipeBack: true,
                leading: {
                    BrutalistBackButton {
                        dismiss()
                    }
                },
                trailing: {
                    BrutalistIconButton(
                        systemImage: "square.and.arrow.up",
                        accessibilityLabelText: "Export log",
                        fill: SGColor.popYellow,
                        foreground: SGColor.inkOnPop,
                        action: exportLog
                    )
                    .disabled(isExportDisabled)
                }
            )

            searchFilterBar

            Group {
                if viewModel.isLoading {
                    VStack(spacing: SGSpacing.small) {
                        ProgressView()
                            .tint(SGColor.textPrimary)
                        Text("LOADING LOG…")
                            .font(SGTypography.displayCompact)
                            .foregroundStyle(SGColor.textPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SGColor.surfacePrimary.ignoresSafeArea())
                } else if viewModel.isLogUnavailable {
                    BrutalistUnavailableCard(
                        title: "Log Unavailable",
                        message: "The shared tunnel log file could not be opened.",
                        systemImage: "doc.text.magnifyingglass",
                        accent: SGColor.popRed
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SGColor.surfacePrimary.ignoresSafeArea())
                } else if viewModel.entries.isEmpty {
                    BrutalistUnavailableCard(
                        title: "No Log Entries Yet",
                        message: "Tunnel and app activity will appear here.",
                        systemImage: "text.alignleft",
                        accent: SGColor.popYellow
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SGColor.surfacePrimary.ignoresSafeArea())
                } else {
                    logEntriesList
                }
            }
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            viewModel.startPolling()
        }
        .onDisappear {
            viewModel.stopPolling()
        }
        .sheet(item: $exportedLogFile) { item in
            ActivityShareSheet(activityItems: [item.url]) {
                try? FileManager.default.removeItem(at: item.url)
                exportedLogFile = nil
            }
        }
        .alert(
            exportAlert?.title ?? "",
            isPresented: Binding(
                get: { exportAlert != nil },
                set: { if !$0 { exportAlert = nil } }
            )
        ) {
            Button(String(localized: "action.ok", defaultValue: "OK"), role: .cancel) {
                exportAlert = nil
            }
        } message: {
            Text(exportAlert?.message ?? "")
        }
    }

    private var searchFilterBar: some View {
        HStack(spacing: SGSpacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(SGColor.textSecondary)

            TextField("Filter log…", text: $viewModel.searchText)
                .font(SGTypography.monoCompact)
                .foregroundStyle(SGColor.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(SGColor.inkOnPop)
                        .frame(width: 24, height: 24)
                        .background(SGColor.popYellow)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, SGSpacing.small)
        .padding(.vertical, 8)
        .background(SGColor.surfaceCard)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.regular))
        .padding(.horizontal, SGSpacing.medium)
        .padding(.vertical, SGSpacing.xSmall)
        .background(SGColor.surfacePrimary)
    }

    private var logEntriesList: some View {
        ScrollViewReader { proxy in
            List(viewModel.filteredEntries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.timestamp)
                        .font(SGTypography.metricLabel.monospaced())
                        .foregroundStyle(SGColor.textSecondary)
                    Text(entry.message)
                        .font(SGTypography.monoCompact)
                        .foregroundStyle(SGColor.textPrimary)
                        .textSelection(.enabled)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                .listRowBackground(SGColor.surfaceCard)
                .id(entry.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(SGColor.surfacePrimary.ignoresSafeArea())
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
