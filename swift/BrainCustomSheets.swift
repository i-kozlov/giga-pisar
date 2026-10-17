// Settings → Brain: the person's own instruction and own menu items.
// Both are optional; untouched, everything works as before, and
// "Restore Standard" brings the standard back.

import SwiftUI

private func sys(_ c: NSColor) -> Color { Color(nsColor: c) }

struct PromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = Brain.customPrompt ?? Brain.standardPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Инструкция для Мозга", "Instruction for the Brain"))
                .font(.system(size: 14, weight: .semibold))
            Text(L("Что Мозг делает с надиктованным текстом. В конец Писарь сам добавит команду: то, что ты сказал после «Писарь, …», или пункт менюшки.",
                   "What the Brain does with dictated text. Pisar appends the command itself: what you said after “Pisar, …” or the menu item."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack {
                Button(L("Вернуть стандартную", "Restore Standard")) { text = Brain.standardPrompt }
                    .disabled(text == Brain.standardPrompt)
                Spacer()
                Button(L("Отменить", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Сохранить", "Save")) {
                    Brain.customPrompt = text
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct ChipsSheet: View {
    private struct Item: Identifiable, Equatable {
        let id = UUID()
        var chip: Chips.Chip
    }

    @Environment(\.dismiss) private var dismiss
    @State private var items = Chips.all.map { Item(chip: $0) }
    /// The hint about unfinished items waits for the first Save.
    @State private var triedSave = false

    private var filled: [Chips.Chip] {
        items.map(\.chip)
            .map { Chips.Chip(title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines), icon: $0.icon,
                              command: $0.command.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.title.isEmpty || !$0.command.isEmpty }
    }
    private var unfinished: Bool { filled.contains { $0.title.isEmpty || $0.command.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Пункты менюшки", "Menu Items"))
                .font(.system(size: 14, weight: .semibold))
            Text(L("Название видно в менюшке, а «что сделать» Мозг получает как команду, будто ты сказал «Писарь, …». Номер пункта по порядку, до девяти.",
                   "The name shows in the menu, and the Brain gets “what to do” as a command, as if you said “Pisar, …”. Items are numbered in order, up to nine."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        row(i, item)
                    }
                }
            }
            .frame(height: 260)

            HStack {
                Button {
                    items.append(Item(chip: Chips.Chip(title: "", command: "")))
                } label: { Label(L("Добавить пункт", "Add Item"), systemImage: "plus") }
                    .disabled(items.count >= Chips.maxCount)
                Button(L("Вернуть стандартные", "Restore Standard")) {
                    items = Chips.standard.map { Item(chip: $0) }
                }
                .disabled(items.map(\.chip) == Chips.standard)
                Spacer()
            }
            if triedSave, unfinished {
                Text(L("Заполни у каждого пункта и название, и что сделать.",
                       "Fill in both the name and what to do for every item."))
                    .font(.callout).foregroundStyle(sys(.systemRed))
            }
            HStack {
                Spacer()
                Button(L("Отменить", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Сохранить", "Save")) {
                    triedSave = true
                    guard !unfinished else { return }
                    Chips.all = filled
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(filled.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func row(_ i: Int, _ item: Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(i + 1)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 4)
            VStack(spacing: 4) {
                TextField(L("Название, например «Деловое письмо»", "Name, e.g. “Formal email”"),
                          text: binding(item).title)
                    .textFieldStyle(.roundedBorder)
                TextField(L("Что сделать, например «перепиши вежливо и официально»",
                            "What to do, e.g. “rewrite politely and formally”"),
                          text: binding(item).command)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(spacing: 2) {
                Button { move(i, -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(i == 0)
                Button { move(i, +1) } label: { Image(systemName: "chevron.down") }
                    .disabled(i == items.count - 1)
            }
            .buttonStyle(.borderless)
            Button { items.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(L("Убрать пункт", "Remove the item"))
                .padding(.top, 4)
        }
    }

    private func binding(_ item: Item) -> Binding<Chips.Chip> {
        Binding(get: { items.first { $0.id == item.id }?.chip ?? item.chip },
                set: { v in if let k = items.firstIndex(where: { $0.id == item.id }) { items[k].chip = v } })
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard items.indices.contains(i), items.indices.contains(j) else { return }
        items.swapAt(i, j)
    }
}
