import SwiftUI

struct ContentView: View {
    @State private var viewModel = ScanViewModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !viewModel.deletionFailures.isEmpty {
                failureBanner
                Divider()
            }
            if let error = viewModel.scanError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.callout)
                    Spacer()
                }
                .padding(10)
                .background(.red.opacity(0.1))
                .foregroundStyle(.red)
                Divider()
            }
            resultsList
            Divider()
            statusBar
        }
        .frame(minWidth: 640, minHeight: 440)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("MacLeaner")
                .font(.title2.bold())

            Spacer()

            if viewModel.hasSelection {
                Text(viewModel.formattedTotalSize)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .transition(.opacity)
            }

            Button("Очистить выбранное") {
                Task { await viewModel.delete() }
            }
            .disabled(!viewModel.hasSelection || viewModel.isDeleting || viewModel.isScanning)

            if viewModel.isScanning || viewModel.isDeleting {
                ProgressView().controlSize(.small)
            }

            Button("Сканировать") {
                Task { await viewModel.scan() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isScanning || viewModel.isDeleting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.default, value: viewModel.hasSelection)
    }

    // MARK: - Results list

    private var resultsList: some View {
        List(viewModel.items) { item in
            ScanItemRow(item: item) {
                viewModel.toggleSelection(item)
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.items.isEmpty && !viewModel.isScanning {
                ContentUnavailableView(
                    "Нажмите «Сканировать»",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("Будут найдены кеши и другие ненужные файлы")
                )
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            Text("\(viewModel.items.count) элементов")
                .foregroundStyle(.secondary)
            Spacer()
            if viewModel.hasSelection {
                Button("Снять выделение") { viewModel.selectNone() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            } else if !viewModel.items.isEmpty {
                Button("Выбрать все") { viewModel.selectAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Failure banner

    private var failureBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "\(viewModel.deletionFailures.count) файлов не удалось переместить в Корзину",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.bold())
            ForEach(viewModel.deletionFailures, id: \.item.id) { failure in
                HStack(alignment: .top, spacing: 4) {
                    Text("·")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failure.item.path.lastPathComponent).bold()
                        Text(failure.reason).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
        .foregroundStyle(.orange)
    }
}

// MARK: - Row

private struct ScanItemRow: View {
    let item: ScanItem
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .imageScale(.large)
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.gray)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.path.lastPathComponent)
                    .lineLimit(1)
                Text(item.path.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.formattedSize)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}
