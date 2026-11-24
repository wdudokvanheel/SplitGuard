#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

struct DebugVerificationWizardView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TunnelStore

    @Bindable private var model = DebugVerificationWizardModel.shared
    @State private var showStepJumper = false
    @State private var showFileImporter = false
    @State private var activeModal: WizardModal?

    private enum WizardModal: Identifiable {
        case qrScanner
        case pasteConfig
        case createTunnel
        case editTunnel(Tunnel)
        case tunnelDetail(Tunnel)
        case logViewer
        case shareFile(URL)
        case shareText(String)

        var id: String {
            switch self {
            case .qrScanner: return "qr"
            case .pasteConfig: return "paste"
            case .createTunnel: return "create"
            case .editTunnel(let tunnel): return "edit-\(tunnel.id)"
            case .tunnelDetail(let tunnel): return "detail-\(tunnel.id)"
            case .logViewer: return "log"
            case .shareFile(let url): return "share-file-\(url.lastPathComponent)"
            case .shareText: return "share-text"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: model.currentStep.shortTitle,
                subtitle: "STEP \(model.currentStepIndex + 1) OF \(model.stepCount)",
                enableSwipeBack: true,
                leading: {
                    BrutalistBackButton {
                        dismiss()
                    }
                },
                trailing: {
                    BrutalistHeaderButton(
                        title: "Steps",
                        systemImage: "list.bullet",
                        fill: SGColor.popYellow,
                        foreground: SGColor.inkOnPop
                    ) {
                        showStepJumper = true
                    }
                }
            )

            progressStrip

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: SGSpacing.medium) {
                        Color.clear.frame(height: 0).id("wizard-top")
                        currentStepContent
                    }
                    .padding(.horizontal, SGSpacing.medium)
                    .padding(.top, SGSpacing.medium)
                    .padding(.bottom, SGSpacing.xxLarge)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(SGColor.surfacePrimary.ignoresSafeArea())
                .onChange(of: model.currentStepIndex) { _, _ in
                    proxy.scrollTo("wizard-top", anchor: .top)
                }
            }

            bottomNavigationBar
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showStepJumper) {
            WizardStepJumperSheet(model: model)
        }
        .sheet(item: $activeModal) { modal in
            modalContent(for: modal)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: UTType.splitGuardImportTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await store.importFiles(from: urls) }
            case .failure(let error):
                store.presentAlert(title: "Unable to import from file", message: error.localizedDescription)
            }
        }
    }

    private var progressStrip: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(SGColor.surfaceElevated)
                Rectangle()
                    .fill(SGColor.popGreen)
                    .frame(width: max(8, proxy.size.width * model.progressFraction))
            }
        }
        .frame(height: 8)
        .overlay(
            Rectangle()
                .frame(height: SGBorder.thin)
                .foregroundStyle(SGColor.borderInk),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private var currentStepContent: some View {
        switch model.currentStep {
        case .automatedDiagnostics:
            DebugAutomatedChecksPage(model: model, store: store)
        case .manual(let stepID):
            DebugManualStepPage(model: model, stepID: stepID, store: store, onAction: handleAction)
        case .summary:
            DebugVerificationSummaryPage(model: model, onAction: handleAction)
        }
    }

    private var bottomNavigationBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(SGColor.borderInk)
                .frame(height: SGBorder.regular)

            HStack(spacing: SGSpacing.small) {
                Button {
                    model.goBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.black))
                        Text("BACK")
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, SGSpacing.medium)
                }
                .buttonStyle(
                    BrutalistButtonStyle(
                        fill: SGColor.surfaceCard,
                        foreground: SGColor.textPrimary,
                        borderWidth: SGBorder.regular,
                        shadowOffset: SGShadow.small,
                        fullWidth: true
                    )
                )
                .disabled(!model.canGoBack)

                Button {
                    model.goNext()
                } label: {
                    HStack(spacing: 4) {
                        Text(model.currentStepIndex == model.stepCount - 2 ? "SUMMARY" : "NEXT")
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.black))
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, SGSpacing.medium)
                }
                .buttonStyle(
                    BrutalistButtonStyle(
                        fill: SGColor.popYellow,
                        foreground: SGColor.inkOnPop,
                        borderWidth: SGBorder.regular,
                        shadowOffset: SGShadow.small,
                        fullWidth: true,
                        showGrain: true
                    )
                )
                .disabled(!model.canGoNext)
            }
            .padding(.horizontal, SGSpacing.medium)
            .padding(.vertical, SGSpacing.small)
            .background(SGColor.surfacePrimary)
        }
    }

    private func handleAction(_ action: DebugWizardAction) {
        switch action {
        case .openFileImporter:
            showFileImporter = true
        case .openQRScanner:
            activeModal = .qrScanner
        case .openPasteConfig:
            activeModal = .pasteConfig
        case .openCreateTunnel:
            activeModal = .createTunnel
        case .openEditTunnel(let tunnel):
            activeModal = .editTunnel(tunnel)
        case .openTunnelDetail(let tunnel):
            activeModal = .tunnelDetail(tunnel)
        case .openLogViewer:
            activeModal = .logViewer
        case .shareFile(let url):
            activeModal = .shareFile(url)
        case .shareText(let text):
            activeModal = .shareText(text)
        }
    }

    @ViewBuilder
    private func modalContent(for modal: WizardModal) -> some View {
        switch modal {
        case .qrScanner:
            QRScannerView(
                store: store,
                onSwitchToPaste: { activeModal = .pasteConfig },
                onCompleted: { activeModal = nil }
            )
        case .pasteConfig:
            PasteConfigSheet(store: store) { activeModal = nil }
        case .createTunnel:
            NavigationStack {
                TunnelEditorView(store: store) { _ in activeModal = nil }
            }
        case .editTunnel(let tunnel):
            NavigationStack {
                TunnelEditorView(store: store, tunnel: tunnel) { _ in activeModal = nil }
            }
        case .tunnelDetail(let tunnel):
            WizardTunnelDetailSheet(store: store, tunnel: tunnel) { activeModal = nil }
        case .logViewer:
            LogViewerView()
        case .shareFile(let url):
            ActivityShareSheet(activityItems: [url]) { activeModal = nil }
        case .shareText(let text):
            ActivityShareSheet(activityItems: [text]) { activeModal = nil }
        }
    }
}

private struct WizardTunnelDetailSheet: View {
    let store: TunnelStore
    let tunnel: Tunnel
    let onClose: () -> Void
    @State private var showEditor = false

    var body: some View {
        NavigationStack {
            TunnelDetailView(
                store: store,
                tunnel: tunnel,
                onEdit: { showEditor = true },
                onDeleted: onClose
            )
            .navigationDestination(isPresented: $showEditor) {
                TunnelEditorView(store: store, tunnel: tunnel)
            }
        }
    }
}

private struct WizardStepJumperSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: DebugVerificationWizardModel

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: "Wizard Steps",
                subtitle: "Jump to any page",
                trailing: {
                    BrutalistHeaderButton(
                        title: "Done",
                        fill: SGColor.popYellow,
                        foreground: SGColor.inkOnPop
                    ) {
                        dismiss()
                    }
                }
            )

            ScrollView {
                VStack(spacing: SGSpacing.xSmall) {
                    ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                        Button {
                            model.jumpTo(stepIndex: index)
                            dismiss()
                        } label: {
                            HStack(spacing: SGSpacing.small) {
                                Text("\(index + 1)")
                                    .font(SGTypography.metricValue)
                                    .foregroundStyle(SGColor.inkOnPop)
                                    .frame(width: 28, height: 28)
                                    .background(index == model.currentStepIndex ? SGColor.popYellow : SGColor.surfaceElevated)
                                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))

                                Text(step.shortTitle)
                                    .font(SGTypography.subheadline.weight(.bold))
                                    .foregroundStyle(SGColor.textPrimary)

                                Spacer()

                                stepBadge(for: step)
                            }
                            .padding(SGSpacing.small)
                            .background(index == model.currentStepIndex ? SGColor.surfaceElevated : SGColor.surfaceCard)
                            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(SGSpacing.medium)
            }
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
    }

    @ViewBuilder
    private func stepBadge(for step: WizardStep) -> some View {
        switch step {
        case .automatedDiagnostics:
            SGStatusBadge(
                title: "\(model.automatedPassCount)/\(model.automatedResults.count)",
                color: model.automatedFailCount > 0 ? SGColor.popRed : SGColor.popGreen,
                isInactive: model.automatedPassCount == 0 && model.automatedFailCount == 0
            )
        case .manual(let stepID):
            let verdict = model.record(for: stepID).verdict
            let color: Color = {
                switch verdict {
                case .pending: return SGColor.surfaceElevated
                case .passed: return SGColor.popGreen
                case .failed: return SGColor.popRed
                case .skipped: return SGColor.popYellow
                }
            }()
            SGStatusBadge(title: verdict.title, color: color, isInactive: verdict == .pending)
        case .summary:
            SGStatusBadge(title: "Report", color: SGColor.popBlue)
        }
    }
}
#endif
