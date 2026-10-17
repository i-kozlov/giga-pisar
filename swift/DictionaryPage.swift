// Settings → Dictionary: the replacement table, a probe line and the
// "new word" sheet with ready case forms. Same file that giga-dict edits.

import AppKit
import SwiftUI

private func sys(_ c: NSColor) -> Color { Color(nsColor: c) }

/// Ask to open the "new word" sheet, possibly with a word picked from a dictation.
struct AddWordRequest: Identifiable {
    let id = UUID()
    let heard: String
}

/// Rows of the dictionary file as the table shows them. Edits are saved
/// half a second after the last keystroke; an unfinished row is not saved.
final class DictionaryEditor: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var heard: String
        var write: String
        var note: String?
    }

    @Published var rows: [Row] = [] {
        didSet { if !loading && rows != oldValue { scheduleSave() } }
    }
    /// Why the last change was not saved, or why the file cannot be read.
    @Published var problem: String?
    /// The file is broken: we show it and never overwrite it.
    @Published var broken = false
    @Published var adding: AddWordRequest?

    let url = DictionaryStore.defaultURL
    private var loading = false
    private var saveWork: DispatchWorkItem?

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "dictionaryEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dictionaryEnabled") }
    }

    static func load(_ url: URL) throws -> ReplacementDictionary {
        guard let data = try DictionaryStore.read(url) else { return ReplacementDictionary() }
        return try ReplacementDictionary.decode(data)
    }

    /// Pick up edits made in the Terminal while the window was closed.
    func reload() {
        saveWork?.cancel()
        loading = true
        defer { loading = false }
        do {
            let d = try Self.load(url)
            rows = d.rules.map { Row(heard: $0.variants.joined(separator: ", "), write: $0.replacement, note: $0.note) }
            broken = false
            problem = nil
        } catch {
            rows = []
            broken = true
            problem = L("Файл словаря не читается, поэтому Писарь его не трогает: \(error)",
                        "The dictionary file cannot be read, so Pisar leaves it alone: \(error)")
        }
    }

    /// The table as a dictionary; throws on an unfinished or wrong row.
    func built(_ rows: [Row]? = nil) throws -> ReplacementDictionary {
        var d = ReplacementDictionary()
        for row in rows ?? self.rows {
            let variants = row.heard.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let write = row.write.trimmingCharacters(in: .whitespaces)
            if variants.isEmpty && write.isEmpty { continue }
            guard !variants.isEmpty, !write.isEmpty else {
                throw DictionaryError(L("заполни обе колонки", "fill in both columns"))
            }
            d.rules.append(DictionaryRule(variants: variants, replacement: write, note: row.note))
        }
        try d.validate()
        return d
    }

    /// What the probe line shows: the valid part of the table, applied.
    func preview(_ text: String) -> String {
        let d = (try? built()) ?? ReplacementDictionary()
        return d.compile().apply(text)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @discardableResult
    func save() -> Bool {
        guard !broken else { return false }
        do {
            let d = try built()
            try DictionaryStore.update(url, read: Self.load) { $0 = d }
            problem = nil
            return true
        } catch {
            problem = L("Не сохранено: \(error)", "Not saved: \(error)")
            return false
        }
    }

    /// The new word plus the forms left ticked. Returns why it was refused.
    func add(heard: String, write: String, forms: [(heard: String, write: String)]) -> String? {
        let heard = heard.trimmingCharacters(in: .whitespaces)
        let write = write.trimmingCharacters(in: .whitespaces)
        var fresh = [Row(heard: ([heard] + forms.filter { $0.write == write }.map(\.heard)).joined(separator: ", "),
                         write: write)]
        // A declined replacement («Александра») gets its own row per form.
        for (h, w) in forms where w != write { fresh.append(Row(heard: h, write: w)) }
        do { _ = try built(rows + fresh) } catch { return "\(error)" }
        saveWork?.cancel()
        loading = true
        rows += fresh
        loading = false
        return save() ? nil : problem
    }

    func remove(_ id: Row.ID?) {
        rows.removeAll { $0.id == id }
    }
}

// MARK: page

struct DictionaryPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        DictionaryPageBody(model: model, editor: model.dictionary)
    }
}

private struct DictionaryPageBody: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var editor: DictionaryEditor
    @State private var selection: DictionaryEditor.Row.ID?
    @State private var probe = ""

    var body: some View {
        let on = DictionaryEditor.enabled
        VStack(spacing: 18) {
            SettingsCard {
                SettingsRow(icon: "checkmark", color: sys(.systemGreen),
                            title: L("Исправлять слова по словарю", "Fix Words by the Dictionary")) {
                    Toggle("", isOn: Binding(get: { DictionaryEditor.enabled },
                                             set: { v in model.act { DictionaryEditor.enabled = v } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }

            if editor.broken {
                brokenCard
            } else {
                words.disabled(!on).opacity(on ? 1 : 0.5)
                probeGroup.disabled(!on).opacity(on ? 1 : 0.5)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("Словарь можно править и из Терминала:", "You can also edit the dictionary from the Terminal:"))
                Text("\"/Applications/Giga Pisar.app/Contents/MacOS/giga-dict\" add --variant \"гит хаб\" --replacement GitHub")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .onAppear { editor.reload() }
        .sheet(item: $editor.adding) { request in
            AddWordSheet(editor: editor, heard: request.heard)
        }
    }

    private var words: some View {
        SettingsGroup(L("Слова: \(editor.rows.count)", "Words: \(editor.rows.count)"), trailing: {
            HStack(spacing: 4) {
                Button { editor.adding = AddWordRequest(heard: "") } label: { Image(systemName: "plus") }
                    .help(L("Добавить слово", "Add a word"))
                Button { editor.remove(selection); selection = nil } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help(L("Убрать выбранное", "Remove the selected word"))
            }
            .buttonStyle(.borderless)
        }, footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let problem = editor.problem {
                    Text(problem).foregroundStyle(sys(.systemRed))
                }
                Text(L("Слева то, что Писарь слышит, справа то, как это писать. Несколько вариантов можно через запятую. Пробелы и дефисы внутри слова не важны: «гит хаб» найдёт и «гитхаб», и «гит-хаб».",
                       "On the left is what Pisar hears, on the right how to write it. Several variants go comma-separated. Spaces and hyphens inside do not matter: «гит хаб» also finds «гитхаб» and «гит-хаб»."))
                Text(L("Слово можно взять прямо из последних диктовок: выдели его, щёлкни правой кнопкой и выбери «Добавить в словарь…».",
                       "You can take a word right from recent dictations: select it, right-click and choose Add to Dictionary…"))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }) {
            if editor.rows.isEmpty {
                Text(L("Пока пусто. Нажми «+», чтобы добавить первое слово.", "Empty so far. Press + to add the first word."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Table(of: Binding<DictionaryEditor.Row>.self, selection: $selection) {
                    TableColumn(L("Писарь слышит", "Pisar hears")) { $row in
                        TextField("", text: $row.heard).textFieldStyle(.plain)
                    }
                    TableColumn(L("Писать так", "Write as")) { $row in
                        TextField("", text: $row.write).textFieldStyle(.plain)
                    }
                } rows: {
                    ForEach($editor.rows) { TableRow($0) }
                }
                .scrollContentBackground(.hidden)
                .frame(height: 190)
            }
        }
    }

    private var probeGroup: some View {
        SettingsGroup(L("Проверить", "Try")) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L("Впиши фразу так, как её слышит Писарь", "Type a phrase the way Pisar hears it"), text: $probe)
                    .textFieldStyle(.roundedBorder)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                    Text(probe.isEmpty ? " " : editor.preview(probe))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private var brokenCard: some View {
        SettingsCard {
            SettingsRow(icon: "exclamationmark.triangle.fill", color: sys(.systemOrange),
                        title: L("Словарь не читается", "The dictionary cannot be read"),
                        subtitle: editor.problem) {
                HStack(spacing: 6) {
                    Button(L("Показать файл", "Show File")) {
                        NSWorkspace.shared.activateFileViewerSelecting([editor.url])
                    }
                    Button(L("Проверить снова", "Check Again")) { editor.reload() }
                }
            }
        }
    }
}

// MARK: new word

private struct AddWordSheet: View {
    @ObservedObject var editor: DictionaryEditor
    @Environment(\.dismiss) private var dismiss
    @State var heard: String
    @State private var write = ""
    @State private var unticked: Set<String> = []
    @State private var problem: String?

    init(editor: DictionaryEditor, heard: String) {
        self.editor = editor
        _heard = State(initialValue: heard)
    }

    private var forms: [(heard: String, write: String)] {
        guard !heard.trimmingCharacters(in: .whitespaces).isEmpty,
              !write.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return WordForms.suggest(heard: heard, write: write)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Новое слово в словаре", "New Word in the Dictionary"))
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Писарь слышит", "Pisar hears")).font(.callout).foregroundStyle(.secondary)
                TextField(L("например, гит хаб", "e.g. гит хаб"), text: $heard).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Писать так", "Write as")).font(.callout).foregroundStyle(.secondary)
                TextField(L("например, GitHub", "e.g. GitHub"), text: $write).textFieldStyle(.roundedBorder)
            }
            if !forms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Заменять и в других формах:", "Also replace other forms:"))
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(forms, id: \.heard) { form in
                        Toggle(isOn: Binding(get: { !unticked.contains(form.heard) },
                                             set: { on in if on { unticked.remove(form.heard) } else { unticked.insert(form.heard) } })) {
                            Text("\(form.heard) → \(form.write)")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(sys(.systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("Отменить", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Добавить", "Add")) {
                    let chosen = forms.filter { !unticked.contains($0.heard) }
                    if let refused = editor.add(heard: heard, write: write, forms: chosen) {
                        problem = refused
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || write.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
