import AppKit
import SwiftUI

struct DockerCleanupView: View {
    var viewModel: DockerCleanupViewModel
    var licenseManager: LicenseManager

    @Environment(\.askAssistant) private var askAssistant
    @State private var searchText = ""
    @State private var confirmationSelection: DockerCleanupSelection?
    @State private var showActivation = false

    private var filteredResources: [DockerResource] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.resources }
        return viewModel.resources.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleKinds: [DockerResourceKind] {
        DockerResourceKind.allCases.filter { kind in
            filteredResources.contains { $0.kind == kind }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.dashboardBackground.opacity(0.38))
        .task {
            if viewModel.availability == .checking, !viewModel.isScanning {
                await viewModel.scan()
            }
        }
        .sheet(item: $confirmationSelection) { selection in
            DockerCleanupConfirmationSheet(
                selection: selection,
                onCancel: { confirmationSelection = nil },
                onConfirm: { volumeAcknowledged in
                    confirmationSelection = nil
                    performCleanup(selection, volumeAcknowledged: volumeAcknowledged)
                }
            )
        }
        .sheet(isPresented: $showActivation) {
            ActivationView(licenseManager: licenseManager) {
                showActivation = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.12, green: 0.46, blue: 0.86), Color(red: 0.06, green: 0.68, blue: 0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Docker")
                    .font(.title2.bold())
                Text("Контейнеры, образы, кеш сборки и volumes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await viewModel.scan() }
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isScanning || viewModel.isDeleting)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.availability {
        case .checking:
            ProgressView("Проверяем Docker…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cliMissing:
            unavailableCard(
                icon: "shippingbox",
                title: "Docker не установлен",
                message: "Установите Docker Desktop, затем вернитесь и запустите проверку.",
                buttonTitle: "Открыть сайт Docker",
                action: openDockerWebsite
            )
        case .daemonUnavailable(let message):
            unavailableCard(
                icon: "power",
                title: "Docker Desktop не запущен",
                message: message,
                buttonTitle: "Запустить Docker Desktop",
                action: launchDockerDesktop
            )
        case .ready(let serverVersion):
            readyContent(serverVersion: serverVersion)
        }
    }

    private func readyContent(serverVersion: String?) -> some View {
        VStack(spacing: 0) {
            summary(serverVersion: serverVersion)
            VStack(alignment: .leading, spacing: 5) {
                if let endpoint = viewModel.endpoint { Text("Подключение: " + endpoint).font(.caption).textSelection(.enabled) }
                if let bytes = viewModel.storageSummary.virtualDiskAllocatedBytes {
                    Text("Виртуальный диск на Mac: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                }
                if let bytes = viewModel.storageSummary.engineReclaimableBytes {
                    Text("Оценка Docker для неиспользуемых ресурсов: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                } else { Text("Оценка освобождаемого объёма недоступна") }
                Text("Размеры образов могут включать общие слои. Удаление ресурсов не гарантирует мгновенное уменьшение виртуального диска.")
                if let report = viewModel.storageSummary.report {
                    Text("Удалено ресурсов: \(report.successfulItems). " + report.measurementDescription)
                    Text("Изменение свободного места зависит также от других процессов.")
                }
            }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
            if viewModel.resources.isEmpty {
                ContentUnavailableView(
                    "Docker уже чист",
                    systemImage: "checkmark.seal",
                    description: Text("Остановленных и неиспользуемых ресурсов не найдено.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultList
                Divider()
                footer
            }
        }
    }

    private func summary(serverVersion: String?) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ByteCountFormatter.string(
                    fromByteCount: viewModel.selectedKnownBytes,
                    countStyle: .file
                ))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("сумма размеров выбранных ресурсов")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(viewModel.resources.count)")
                    .font(.title2.bold())
                Text("кандидатов · \(serverVersion.map { "Docker \($0)" } ?? "Docker готов")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TextField("Поиск по имени или ID", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var resultList: some View {
        List {
            ForEach(visibleKinds) { kind in
                Section {
                    ForEach(filteredResources.filter { $0.kind == kind }, id: \.listID) { resource in
                        DockerResourceRow(
                            resource: resource,
                            disabled: viewModel.isScanning || viewModel.isDeleting,
                            onToggle: { viewModel.toggle(resource) },
                            onAsk: askAssistant.map { (action: AskAssistantAction) -> () -> Void in
                                { action(AssistantSnapshotBuilder.focus(for: resource)) }
                            }
                        )
                    }
                } header: {
                    categoryHeader(kind)
                }
            }
        }
        .listStyle(.inset)
    }

    private func categoryHeader(_ kind: DockerResourceKind) -> some View {
        let resources = filteredResources.filter { $0.kind == kind }
        let bytes = resources.compactMap(\.size).reduce(0, +)
        return HStack {
            Text(kind.displayName)
            if kind == .volume {
                Text("ОСОБЫЙ РИСК")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.red)
            }
            Spacer()
            if bytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .monospacedDigit()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let failure = viewModel.failures.first {
                Label(failure.reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Label("Проверьте выбранные ресурсы. Тома могут содержать базы данных.", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                requestCleanup()
            } label: {
                if viewModel.isDeleting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Очистить выбранное · \(ByteCountFormatter.string(fromByteCount: viewModel.selectedKnownBytes, countStyle: .file))")
                }
            }
            .buttonStyle(.borderedProminentHand)
            .disabled(viewModel.selectedResources.isEmpty || viewModel.isScanning || viewModel.isDeleting)
        }
        .padding(20)
    }

    private func unavailableCard(
        icon: String,
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminentHand)
                Button("Проверить снова") {
                    Task { await viewModel.scan() }
                }
                .buttonStyle(.borderedHand)
            }
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func requestCleanup() {
        guard licenseManager.canClean else {
            showActivation = true
            return
        }
        confirmationSelection = viewModel.makeCleanupSnapshot()
    }

    private func performCleanup(
        _ selection: DockerCleanupSelection,
        volumeAcknowledged: Bool
    ) {
        Task {
            let result = await viewModel.deleteConfirmed(
                selection,
                volumeAcknowledged: volumeAcknowledged,
                canClean: licenseManager.canClean,
                recordSuccessfulClean: {
                    if !licenseManager.isActivated {
                        licenseManager.recordClean()
                    }
                }
            )
            if case .licenseRequired = result {
                showActivation = true
            }
        }
    }

    private func launchDockerDesktop() {
        NSWorkspace.shared.open(URL(filePath: "/Applications/Docker.app", directoryHint: .isDirectory))
    }

    private func openDockerWebsite() {
        guard let url = URL(string: "https://www.docker.com/products/docker-desktop/") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct DockerResourceRow: View {
    let resource: DockerResource
    let disabled: Bool
    let onToggle: () -> Void
    var onAsk: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: resource.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17))
                    .foregroundStyle(selectionColor)
            }
            .buttonStyle(.plainHand)
            .disabled(disabled)
            .accessibilityLabel(resource.isSelected ? "Исключить из очистки" : "Добавить в очистку")

            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(resource.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    riskBadge
                }
                Text(resource.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(resource.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            if let date = resource.lastUsedAt ?? resource.createdAt {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let onAsk { AskAssistantButton(action: onAsk) }

            Text(resource.formattedSize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !disabled else { return }
            onToggle()
        }
        .pointingHandCursor()
        .askAssistantMenu(onAsk)
    }

    private var selectionColor: Color {
        if resource.isSelected {
            return resource.risk == .dataLoss ? .red : .accentColor
        }
        return .secondary
    }

    private var icon: String {
        switch resource.kind {
        case .buildCache: "hammer.fill"
        case .image: "square.3.layers.3d"
        case .container: "shippingbox.fill"
        case .volume: "externaldrive.fill"
        }
    }

    private var iconColor: Color {
        switch resource.risk {
        case .rebuildable: Color.accentColor
        case .review: Theme.warningOrange
        case .dataLoss: .red
        }
    }

    @ViewBuilder
    private var riskBadge: some View {
        switch resource.risk {
        case .rebuildable:
            Text("ВОССТАНОВИМО")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.healthGreenText)
        case .review:
            Text("ПРОВЕРЬТЕ")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.warningOrange)
        case .dataLoss:
            Text("ДАННЫЕ")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.red)
        }
    }
}

private struct DockerCleanupConfirmationSheet: View {
    let selection: DockerCleanupSelection
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void

    @State private var volumeWarningStep = false
    @State private var volumeConfirmation = ""

    private var totalKnownBytes: Int64 {
        selection.resources.compactMap(\.size).reduce(0, +)
    }

    private var volumeResources: [DockerResource] {
        selection.resources.filter { $0.kind == .volume }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if volumeWarningStep {
                volumeWarning
            } else {
                targetPreview
            }
        }
        .padding(20)
        .frame(minWidth: 680, idealWidth: 720, minHeight: 460, idealHeight: 540)
    }

    private var targetPreview: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Text("Проверка Docker-очистки")
                    .font(.title2.bold())
                Text("Будет обработано \(selection.resources.count) ресурсов · известный размер \(ByteCountFormatter.string(fromByteCount: totalKnownBytes, countStyle: .file)).")
                    .foregroundStyle(.secondary)
            }

            resourceList(selection.resources)

            HStack {
                Label("Каждая команда использует указанный ниже ID.", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(selection.containsVolumes ? "Продолжить" : "Удалить ресурсы", role: .destructive) {
                    if selection.containsVolumes {
                        volumeWarningStep = true
                    } else {
                        onConfirm(false)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var volumeWarning: some View {
        Group {
            VStack(alignment: .leading, spacing: 7) {
                Label("Volumes могут содержать базы данных", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.red)
                Text("Docker не сможет восстановить их содержимое. Проверьте имена и введите УДАЛИТЬ для продолжения.")
                    .foregroundStyle(.secondary)
            }

            resourceList(volumeResources)

            TextField("УДАЛИТЬ", text: $volumeConfirmation)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Назад") { volumeWarningStep = false }
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Удалить вместе с volumes", role: .destructive) {
                    onConfirm(true)
                }
                .disabled(volumeConfirmation != "УДАЛИТЬ")
            }
        }
    }

    private func resourceList(_ resources: [DockerResource]) -> some View {
        List(resources, id: \.listID) { resource in
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(resource.name)
                        .font(.callout.weight(.medium))
                    Text(resource.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(resource.formattedSize)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
        .listStyle(.inset)
    }
}

extension DockerCleanupSelection: Identifiable {
    var id: String {
        resources.map { "\($0.kind.rawValue):\($0.id)" }.joined(separator: "|")
    }
}

private extension DockerResource {
    var listID: String { "\(kind.rawValue):\(id)" }
}
