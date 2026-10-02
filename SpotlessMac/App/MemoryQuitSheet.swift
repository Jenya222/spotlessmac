import SwiftUI

struct MemoryQuitSheet: View {
    var viewModel: MemoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch viewModel.quitState {
            case .idle:
                EmptyView()
            case .confirm(let group, let decision):
                title("Завершить \(group.displayName)?")
                switch decision {
                case .allowed:
                    Text("Будет закрыто приложение целиком (\(group.processes.count) проц.). Ожидается освободить примерно \(MemoryVerdict.format(group.footprint)). Приложение может попросить сохранить документы.")
                        .fixedSize(horizontal: false, vertical: true)
                    buttons(primary: "Завершить") { Task { await viewModel.confirmQuit() } }
                case .denied(let reason):
                    Text(reason).fixedSize(horizontal: false, vertical: true)
                    HStack { Spacer(); Button("Понятно") { viewModel.dismissQuit() }.keyboardShortcut(.defaultAction) }
                }
            case .quitting(let group):
                title("Завершаем \(group.displayName)…")
                ProgressView().frame(maxWidth: .infinity)
            case .stillRunning(let group):
                title("\(group.displayName) не закрылось")
                Text("Приложение не ответило за 5 секунд. Принудительное завершение закроет его сразу — несохранённые данные будут потеряны.")
                    .fixedSize(horizontal: false, vertical: true)
                buttons(primary: "Завершить принудительно", role: .destructive) { viewModel.confirmForceQuit() }
            case .finished(let message):
                title(message)
                Text("Изменения появятся в списке через пару секунд.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Готово") { viewModel.dismissQuit() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.title3.bold())
    }

    private func buttons(primary: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Отмена") { viewModel.dismissQuit() }.keyboardShortcut(.cancelAction)
            Button(primary, role: role, action: action).keyboardShortcut(.defaultAction)
        }
    }
}
