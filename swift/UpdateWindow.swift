// Окно хода обновления, как у «Обновления ПО» в macOS: полоска, что
// сейчас делаем, кнопка «Отменить». Раньше единственным признаком жизни
// была надпись «↓ 43%» у значка в строке меню, а на маках с чёлкой значок
// в этот момент прячется за ней: человек жал «Обновить», ничего не видел
// и жал снова. Окно от чёлки не зависит. Закрыть его крестиком можно,
// скачивание продолжается; остановить — только кнопкой.
//
// С 3.9.11 оно же и предлагает обновление: «Вышла версия X», что нового,
// «Позже» / «Обновить». Раньше пункт меню с красной точкой сразу качал,
// и список изменений человек не видел вовсе. Список остаётся на виду и
// пока качается; длинный прокручивается внутри рамки.

import AppKit

final class UpdateWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var title = NSTextField(labelWithString: "")
    private var status = NSTextField(labelWithString: "")
    private var bar = NSProgressIndicator()
    private let notesSlot = NSStackView()   // «Что нового», пусто — спрятан
    private var cancelButton = NSButton()
    private var laterButton = NSButton()
    private var updateButton = NSButton()
    /// Что делать по «Отменить»; nil — отменять уже нечего (кнопка прячется).
    var onCancel: (() -> Void)?
    private var onUpdate: (() -> Void)?

    private let columnWidth: CGFloat = 340
    private let maxNotesHeight: CGFloat = 170

    /// Предложение обновиться: что нового и «Позже» / «Обновить».
    func offer(version: String, current: String, notes: [String], onUpdate: @escaping () -> Void) {
        if window == nil { build() }
        self.onUpdate = onUpdate
        title.stringValue = L("Вышла версия \(version)", "Version \(version) is out")
        status.stringValue = L("У тебя \(current)", "You have \(current)")
        bar.isHidden = true
        setNotes(version: version, lines: notes)
        laterButton.isHidden = false
        updateButton.isHidden = false
        cancelButton.isHidden = true
        present()
    }

    /// Ход обновления. notes: nil — оставить список, какой был.
    func show(version: String, notes: [String]? = nil) {
        if window == nil { build() } // build() hides the notes slot, so it goes first
        if let notes { setNotes(version: version, lines: notes) }
        show(title: L("Обновление до версии \(version)", "Updating to version \(version)"))
    }

    /// То же окно для любой долгой загрузки (модель распознавания).
    func show(title text: String) {
        if window == nil { build() }
        title.stringValue = text
        bar.isHidden = false
        laterButton.isHidden = true
        updateButton.isHidden = true
        cancelButton.isHidden = onCancel == nil
        present()
    }

    func hide() { window?.orderOut(nil) }

    /// Скачивание: полоска с процентами.
    func downloading(percent: Int) {
        status.stringValue = L("Скачиваю… \(percent)%", "Downloading… \(percent)%")
        bar.isIndeterminate = false
        bar.doubleValue = Double(percent)
    }

    /// Этап без процентов: проверка подписи, перезапуск, ожидание конца диктовки.
    func busy(_ text: String) {
        status.stringValue = text
        bar.isIndeterminate = true
        bar.startAnimation(nil)
    }

    private func present() {
        guard let w = window, let root = w.contentView else { return }
        root.layoutSubtreeIfNeeded()
        w.setContentSize(root.fittingSize)
        NSApp.activate(ignoringOtherApps: true)
        if !w.isVisible { w.center() }
        w.makeKeyAndOrderFront(nil)
    }

    /// Плашка «Что нового» в рамке с прокруткой: короткая — ровно по себе,
    /// длинная упирается в maxNotesHeight и листается, кнопки не уезжают.
    private func setNotes(version: String, lines: [String]) {
        notesSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let box = whatsNewView(version: version, notes: lines, width: columnWidth) as? NSBox else {
            notesSlot.isHidden = true
            return
        }
        notesSlot.isHidden = false
        // подложку рисует рамка прокрутки, иначе она уезжала бы вместе с текстом
        box.fillColor = .clear
        box.translatesAutoresizingMaskIntoConstraints = true
        let doc = FlippedView(frame: box.frame)
        doc.addSubview(box)

        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay // обычная полоса отъела бы ширину у текста
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: columnWidth),
            scroll.heightAnchor.constraint(equalToConstant: min(box.frame.height, maxNotesHeight)),
        ])
        notesSlot.addArrangedSubview(scroll)
    }

    private func build() {
        // Раскладка как у «Обновления ПО»: значок слева, справа колонка —
        // заголовок, статус, полоска, что нового, кнопки по правому краю.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .boldSystemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        notesSlot.orientation = .vertical
        notesSlot.isHidden = true
        cancelButton = NSButton(title: L("Отменить", "Cancel"), target: self, action: #selector(cancel))
        laterButton = NSButton(title: L("Позже", "Later"), target: self, action: #selector(later))
        laterButton.keyEquivalent = "\u{1b}"
        updateButton = NSButton(title: L("Обновить", "Update"), target: self, action: #selector(update))
        updateButton.keyEquivalent = "\r"
        for b in [cancelButton, laterButton, updateButton] {
            b.bezelStyle = .rounded
            b.controlSize = .regular
        }
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.setViews([laterButton, updateButton, cancelButton], in: .trailing)

        let column = NSStackView(views: [title, status, bar, notesSlot, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setCustomSpacing(4, after: title)
        column.setCustomSpacing(10, after: status)
        column.setCustomSpacing(12, after: bar)
        column.setCustomSpacing(14, after: notesSlot)

        for v in [icon, column] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let side: CGFloat = 20
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: side),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),

            column.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -side),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: side + 2),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            column.widthAnchor.constraint(equalToConstant: columnWidth),
            root.bottomAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor, constant: side),

            title.widthAnchor.constraint(equalTo: column.widthAnchor),
            status.widthAnchor.constraint(equalTo: column.widthAnchor),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        let w = NSWindow(contentRect: root.frame,
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("Обновление", "Update")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = root
        window = w
    }

    @objc private func cancel() {
        onCancel?()
        hide()
    }

    @objc private func later() { hide() }

    @objc private func update() {
        let go = onUpdate
        onUpdate = nil
        go?()
    }

    // крестик — только спрятать, дело продолжается
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
}

/// Документ прокрутки, растущий сверху вниз: короткий список прижат к верху.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
