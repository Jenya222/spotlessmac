import AppKit
import SwiftUI

struct AgentStorageView: View {
    @Bindable var viewModel: AgentStorageViewModel
    var licenseManager: LicenseManager
    @State private var selection: AgentStorageSelection?
    @State private var showActivation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.isScanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Проверяем папки, Git и занятое место…")
                    Spacer()
                    Button("Отменить") { viewModel.cancelScan() }
                }.padding()
            }
            AgentStorageSummary(report: viewModel.report, agentFilter: $viewModel.agentFilter)
            controls
            if let message = viewModel.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 8)
            }
            results
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if !viewModel.hasScanned { viewModel.startScan() } }
        .sheet(item: $selection) { snapshot in
            AgentStorageConfirmation(selection: snapshot, onCancel: { selection = nil }) {
                selection = nil
                Task {
                    let result = await viewModel.deleteConfirmed(snapshot, canClean: licenseManager.canClean) {
                        if !licenseManager.isActivated { licenseManager.recordClean() }
                    }
                    if result == .licenseRequired { showActivation = true }
                }
            }
        }
        .sheet(isPresented: $showActivation) {
            ActivationView(licenseManager: licenseManager) { showActivation = false }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.person.crop")
                .font(.system(size: 25)).foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("ИИ-агенты").font(.title2.bold())
                Text("Рабочие папки, временные данные и кэши").foregroundStyle(.secondary)
            }
            Spacer()
            Button { viewModel.startScan() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                .disabled(viewModel.isBusy)
        }.padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 16)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Поиск по агенту или пути", text: $viewModel.query).textFieldStyle(.roundedBorder)
                Picker("Статус", selection: $viewModel.statusFilter) {
                    Text("Все статусы").tag(nil as AgentStorageStatus?)
                    ForEach(AgentStorageStatus.allCases) { Text($0.title).tag(Optional($0)) }
                }.labelsHidden().frame(width: 200)
                Button { chooseRoot() } label: { Label("Добавить папку", systemImage: "folder.badge.plus") }
                    .disabled(viewModel.isBusy)
            }
            DisclosureGroup("Где ищем и что проверяем") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Известные папки Codex, Claude и Cursor; worktrees в папках проектов (до 5 уровней). Добавленные папки — только для просмотра. Символические ссылки не обходятся.")
                    Text("Git распознаётся по метаданным, включая вложенные репозитории. Изменения, remote и незапушенные коммиты не проверяются: все Git-папки защищены.")
                    Text("Источники: ~/.codex/worktrees, ~/.codex/tmp, ~/.cursor/worktrees, ~/.claude/worktrees, ~/.claude/debug, ~/.claude/projects и известные кэши Claude/Cursor.")
                    ForEach(viewModel.extraRoots, id: \.path) { root in
                        HStack {
                            Text(root.path).textSelection(.enabled)
                            Spacer()
                            Button("Убрать из списка") { viewModel.removeRoot(root) }
                                .disabled(viewModel.isBusy).help("Прекратить наблюдение за папкой; файлы сохранятся")
                        }
                    }
                    ForEach(Array(viewModel.report.warnings.prefix(8)), id: \.self) { Text($0).foregroundStyle(.orange) }
                    if viewModel.report.warnings.count > 8 { Text("И ещё предупреждений: \(viewModel.report.warnings.count - 8)") }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }.font(.caption)
            if !viewModel.report.warnings.isEmpty {
                Label("Не все источники проверены: \(viewModel.report.warnings.count). Подробности выше.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(.horizontal, 24).padding(.bottom, 12)
    }

    @ViewBuilder private var results: some View {
        if viewModel.isDeleting {
            ProgressView("Повторная проверка и перемещение в Корзину…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.visibleItems.isEmpty {
            ContentUnavailableView(viewModel.hasScanned ? "Папок по этим условиям нет" : "Данные ИИ-агентов",
                systemImage: "folder.badge.questionmark",
                description: Text(viewModel.hasScanned ? "Измените фильтр или добавьте папку, в которой агент создаёт рабочие данные." : "Результаты появятся после сканирования известных источников."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(viewModel.visibleItems) { item in
                AgentStorageRow(item: item, selected: viewModel.selectedIDs.contains(item.id), disabled: viewModel.isBusy,
                                failure: viewModel.failures.first { $0.item.id == item.scanItem.id }?.reason,
                                onToggle: { viewModel.toggle(item) })
            }.listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Выбрать доступные") { viewModel.selectVisibleCandidates() }
                .disabled(viewModel.isBusy || !viewModel.visibleItems.contains { $0.status == .cleanable })
            Button("Снять выбор") { viewModel.clearSelection() }.disabled(viewModel.isBusy || viewModel.selectedIDs.isEmpty)
            Spacer()
            Text("\(viewModel.selectedIDs.count) · \(agentBytes(viewModel.selectedBytes))").monospacedDigit()
            Button("В Корзину…", role: .destructive) {
                if licenseManager.canClean { selection = viewModel.makeSelection() }
                else { showActivation = true }
            }.disabled(viewModel.isBusy || viewModel.selectedIDs.isEmpty)
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Выберите отдельную папку рабочих данных агента. Она будет добавлена для анализа без разрешения на удаление."
        panel.prompt = "Добавить"
        panel.begin { response in
            if response == .OK, let url = panel.url { viewModel.addRoot(url) }
        }
    }
}

private struct AgentStorageSummary: View {
    let report: AgentStorageReport
    @Binding var agentFilter: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 36) {
                metric(agentBytes(report.totalBytes), "найдено на диске")
                metric(agentBytes(report.cleanableBytes), "доступно для очистки")
                metric("\(report.items.count)", "объектов")
                Spacer()
                if agentFilter != nil { Button("Все агенты") { agentFilter = nil } }
            }
            if !report.items.isEmpty {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(report.totals) { total in
                        Button { agentFilter = agentFilter == total.agent ? nil : total.agent } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(total.agent).fontWeight(agentFilter == total.agent ? .bold : .medium)
                                    Spacer()
                                    Text(agentBytes(total.bytes)).foregroundStyle(.secondary)
                                }.font(.caption)
                                ProgressView(value: Double(total.bytes), total: Double(max(1, report.totalBytes)))
                                    .tint(agentFilter == nil || agentFilter == total.agent ? Color.accentColor : Color.gray)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(total.agent): \(agentBytes(total.bytes)), объектов: \(total.count). Фильтр")
                    }
                }
            }
            if report.items.contains(where: { !$0.isComplete }) {
                Text("Размеры неполностью прочитанных папок — нижняя оценка.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
    private func metric(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AgentStorageRow: View {
    @State private var showsDetails = false
    let item: AgentStorageItem
    let selected: Bool
    let disabled: Bool
    let failure: String?
    let onToggle: () -> Void

    private var color: Color {
        switch item.status {
        case .cleanable: .green
        case .protected: .blue
        case .recent: .secondary
        case .review: .orange
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Выбрать \(item.path.lastPathComponent)", isOn: Binding(get: { selected }, set: { _ in onToggle() }))
                .labelsHidden().toggleStyle(.checkbox).disabled(disabled || item.status != .cleanable)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.path.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(item.agent + " · " + item.kind.title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text((item.isComplete ? "" : "≥ ") + agentBytes(item.bytes)).font(.headline).monospacedDigit()
                }
                Text(item.path.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle).textSelection(.enabled).help(item.path.path)
                HStack(spacing: 12) {
                    Label(item.status.title, systemImage: item.status == .cleanable ? "checkmark.circle" : item.hasGit ? "lock.shield" : "info.circle")
                        .foregroundStyle(color)
                    if let date = item.modifiedAt { Text("Изменено \(date.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([item.path]) }
                        .help("Показать \(item.path.path) в Finder")
                }.font(.caption)
                Button {
                    showsDetails.toggle()
                } label: {
                    Label("Причина и рекомендация", systemImage: showsDetails ? "chevron.down" : "chevron.right")
                }.buttonStyle(.plain).font(.caption).accessibilityValue(showsDetails ? "Развёрнуто" : "Свёрнуто")
                if showsDetails {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.reason)
                        Text(item.recommendation)
                    }.font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }
        }.padding(.vertical, 7)
    }
}

private struct AgentStorageConfirmation: View {
    let selection: AgentStorageSelection
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var closedAgents = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Переместить в Корзину?").font(.title2.bold())
            Text("Объектов: \(selection.items.count) · \(agentBytes(selection.bytes)). Проверьте каждый путь. Место освободится после очистки Корзины.")
                .foregroundStyle(.secondary)
            List(selection.items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(item.agent).bold(); Spacer(); Text(agentBytes(item.bytes)) }
                    Text(item.path.path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }.frame(minHeight: 180, maxHeight: 320)
            Toggle("Агенты и связанные задачи закрыты", isOn: $closedAgents)
            Text("Перед очисткой приложение повторно проверит папки и активность инструментов.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Переместить в Корзину", role: .destructive, action: onConfirm).disabled(!closedAgents)
            }
        }.padding(24).frame(width: 620)
    }
}

private func agentBytes(_ value: Int64) -> String {
    value == 0 ? "0 Б" : ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
