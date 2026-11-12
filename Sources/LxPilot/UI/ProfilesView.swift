import SwiftUI
import AppKit

struct ProfilesView: View {
    @EnvironmentObject var state: AppState
    @State private var showingAdd = false
    @State private var updating: Set<UUID> = []

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Профили") {
                Button {
                    Task {
                        for profile in state.profiles where profile.url != nil { await update(profile) }
                    }
                } label: {
                    Label("Обновить все", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!state.profiles.contains(where: { $0.url != nil }) || !updating.isEmpty)
                Button {
                    showingAdd = true
                } label: {
                    Label("Добавить", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.top, 42)
            .padding(.bottom, 10)

            if state.profiles.isEmpty {
                EmptyHint(icon: "folder.badge.plus",
                          text: "Добавьте подписку по ссылке, вставьте ссылки vless:// или импортируйте готовый конфиг sing-box.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(state.profiles) { profile in
                            ProfileCard(profile: profile, isUpdating: updating.contains(profile.id)) {
                                Task { await update(profile) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 90)
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddProfileSheet()
                .environmentObject(state)
        }
    }

    @MainActor
    private func update(_ profile: Profile) async {
        updating.insert(profile.id)
        await state.updateProfile(profile)
        updating.remove(profile.id)
    }
}

struct ProfileCard: View {
    @EnvironmentObject var state: AppState
    let profile: Profile
    let isUpdating: Bool
    let onUpdate: () -> Void

    var body: some View {
        let selected = state.settings.selectedProfileID == profile.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? state.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(profile.url ?? "Локальный профиль")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isUpdating {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        if profile.url != nil {
                            Button("Обновить", action: onUpdate)
                        }
                        Button("Открыть конфиг в редакторе") {
                            NSWorkspace.shared.open(profile.fileURL)
                        }
                        Button("Показать в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([profile.fileURL])
                        }
                        Divider()
                        Button("Удалить", role: .destructive) {
                            state.deleteProfile(profile)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            if let total = profile.total, total > 0 {
                let used = (profile.upload ?? 0) + (profile.download ?? 0)
                ProgressView(value: min(Double(used) / Double(total), 1))
                Text("\(formatBytes(used)) из \(formatBytes(total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label("\(profile.nodeCount)", systemImage: "server.rack")
                Label(profile.updatedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                if let expire = profile.expire {
                    Label(expire.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .card(selected: selected)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await state.selectProfile(profile) }
        }
    }
}

struct AddProfileSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var text = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Новый профиль")
                .font(.system(size: 17, weight: .semibold))

            TextField("Название (необязательно)", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("URL подписки: https://…", text: $url)
                .textFieldStyle(.roundedBorder)

            Text("…или вставьте конфиг sing-box (JSON) либо ссылки vless:// / trojan:// / ss:// / hysteria2://, по одной в строке:")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 170)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                .disabled(!url.trimmingCharacters(in: .whitespaces).isEmpty)

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Из буфера обмена") {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
                            url = trimmed
                        } else {
                            text = pasted
                        }
                    }
                }
                Button("Из файла…") { pickFile() }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Добавить") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || (url.trimmingCharacters(in: .whitespaces).isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let fileURL = panel.url,
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        text = content
        url = ""
        if name.isEmpty { name = fileURL.deletingPathExtension().lastPathComponent }
    }

    private func add() {
        working = true
        failure = nil
        let urlValue = url.trimmingCharacters(in: .whitespaces)
        let nameValue = name
        let textValue = text
        Task { @MainActor in
            do {
                try await state.addProfile(name: nameValue, url: urlValue.isEmpty ? nil : urlValue, text: textValue)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            working = false
        }
    }
}
