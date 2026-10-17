// Словарь замен: что распознаётся не так → как это писать.
// Общее ядро для приложения и giga-dict: формат файла, проверка и замена.
// Только Foundation.

import Foundation

struct DictionaryRule: Equatable {
    var variants: [String]
    var replacement: String
    var note: String?
}

struct DictionaryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct ReplacementDictionary: Equatable {
    static let version = 1
    static let maxFileBytes = 1 << 20
    static let maxRules = 5000
    static let maxVariants = 20000
    static let maxNoteLength = 1000
    static let maxVariantLength = 200
    static let maxReplacementLength = 1000

    var rules: [DictionaryRule] = []

    // MARK: файл

    /// JSON, читается с послаблениями JSON5: комментарии, висячие запятые.
    static func decode(_ data: Data) throws -> ReplacementDictionary {
        guard data.count <= maxFileBytes else {
            throw DictionaryError("файл больше \(maxFileBytes) байт")
        }
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        } catch {
            throw DictionaryError("не JSON: \(error.localizedDescription)")
        }
        guard let root = any as? [String: Any] else { throw DictionaryError("в корне должен быть объект") }
        try onlyKeys(root, ["version", "rules"], at: "корень")
        guard let version = root["version"] as? NSNumber, !isBool(version),
              !CFNumberIsFloatType(version), version.intValue == Self.version else {
            throw DictionaryError("version должен быть \(Self.version)")
        }
        guard let list = root["rules"] as? [Any] else { throw DictionaryError("rules должен быть массивом") }
        guard list.count <= maxRules else { throw DictionaryError("правил больше \(maxRules)") }
        var rules: [DictionaryRule] = []
        for (i, item) in list.enumerated() {
            let at = "правило \(i + 1)"
            guard let obj = item as? [String: Any] else { throw DictionaryError("\(at): должно быть объектом") }
            try onlyKeys(obj, ["variants", "replacement", "note"], at: at)
            guard let variants = obj["variants"] as? [Any] else {
                throw DictionaryError("\(at): variants должен быть массивом строк")
            }
            let strings = try variants.map { v -> String in
                guard let s = v as? String else { throw DictionaryError("\(at): variants должен быть массивом строк") }
                return s
            }
            guard let replacement = obj["replacement"] as? String else {
                throw DictionaryError("\(at): replacement должен быть строкой")
            }
            var note: String?
            if let raw = obj["note"] {
                guard let s = raw as? String else { throw DictionaryError("\(at): note должен быть строкой") }
                note = s
            }
            rules.append(DictionaryRule(variants: strings, replacement: replacement, note: note))
        }
        let dictionary = ReplacementDictionary(rules: rules)
        try dictionary.validate()
        return dictionary
    }

    func encode() throws -> Data {
        try validate()
        let list: [[String: Any]] = rules.map { rule in
            var obj: [String: Any] = ["variants": rule.variants, "replacement": rule.replacement]
            if let note = rule.note { obj["note"] = note }
            return obj
        }
        let root: [String: Any] = ["version": Self.version, "rules": list]
        var data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        guard data.count <= Self.maxFileBytes else {
            throw DictionaryError("словарь не помещается в \(Self.maxFileBytes) байт")
        }
        return data
    }

    private static func onlyKeys(_ obj: [String: Any], _ allowed: Set<String>, at: String) throws {
        if let extra = obj.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw DictionaryError("\(at): неизвестное поле \(extra)")
        }
    }

    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    // MARK: проверка

    /// Ключ варианта: NFC, без краевых пробелов, каждый знак без учёта
    /// регистра. Сравнение по знакам, как в apply: «ß» и «ss» — разные.
    static func key(_ variant: String) -> String {
        pattern(normalizedVariant(variant)).joined(separator: "\u{1F}")
    }

    /// A run of spaces or hyphens inside a variant becomes one `gap`: in the
    /// text it matches any run of them or nothing at all, so «гит хаб» also
    /// catches «гитхаб» and «гит-хаб». Text without a gap in the variant
    /// stays strict: «кот» never matches «к от».
    fileprivate static let gap = "\u{1F}gap"

    fileprivate static func isGapChar(_ c: Character) -> Bool {
        c.isWhitespace || "-‐‑".contains(c)
    }

    fileprivate static func pattern(_ s: String) -> [String] {
        var out: [String] = []
        for c in s {
            if isGapChar(c) {
                if let last = out.last, last != gap { out.append(gap) }
            } else {
                out.append(folded(String(c)))
            }
        }
        if out.last == gap { out.removeLast() }
        return out
    }

    // MARK: reserved word and unsafe characters

    /// «Писарь» calls the Brain. The dictionary must neither create nor eat it,
    /// otherwise an ordinary phrase turns into a command or commands stop working.
    static func mentionsReserved(_ s: String) -> Bool {
        s.range(of: "(?<![\\p{L}\\p{N}])п[еиэ]сар", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Line breaks and other control characters would act as Enter in a terminal.
    static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            [.control, .lineSeparator, .paragraphSeparator, .format].contains($0.properties.generalCategory)
        }
    }

    static func normalizedVariant(_ variant: String) -> String {
        variant.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func folded(_ s: String) -> String {
        s.folding(options: .caseInsensitive, locale: nil)
    }

    func validate() throws {
        guard rules.count <= Self.maxRules else { throw DictionaryError("правил больше \(Self.maxRules)") }
        guard rules.reduce(0, { $0 + $1.variants.count }) <= Self.maxVariants else {
            throw DictionaryError("вариантов больше \(Self.maxVariants)")
        }
        var seen: [String: String] = [:]
        for (i, rule) in rules.enumerated() {
            let at = "правило \(i + 1)"
            guard !rule.variants.isEmpty else { throw DictionaryError("\(at): нет ни одного варианта") }
            guard (rule.note?.count ?? 0) <= Self.maxNoteLength else {
                throw DictionaryError("\(at): заметка длиннее \(Self.maxNoteLength) знаков")
            }
            guard !rule.replacement.isEmpty else { throw DictionaryError("\(at): пустая замена") }
            guard !Self.hasControl(rule.replacement), !rule.variants.contains(where: Self.hasControl) else {
                throw DictionaryError("\(at): переносы строк и служебные символы в словаре нельзя")
            }
            guard !Self.mentionsReserved(rule.replacement), !rule.variants.contains(where: Self.mentionsReserved) else {
                throw DictionaryError("\(at): слово «Писарь» занято, им вызывают Мозг. Словарь его не меняет")
            }
            guard rule.replacement.count <= Self.maxReplacementLength else {
                throw DictionaryError("\(at): замена длиннее \(Self.maxReplacementLength) знаков")
            }
            for variant in rule.variants {
                let normalized = Self.normalizedVariant(variant)
                guard !normalized.isEmpty else { throw DictionaryError("\(at): пустой вариант") }
                guard normalized.count <= Self.maxVariantLength else {
                    throw DictionaryError("\(at): вариант длиннее \(Self.maxVariantLength) знаков")
                }
                let key = Self.key(variant)
                if let other = seen[key], other != rule.replacement {
                    throw DictionaryError("вариант «\(normalized)» заменяется и на «\(other)», и на «\(rule.replacement)»")
                }
                seen[key] = rule.replacement
            }
        }
    }

    // MARK: замена

    /// Готовый к применению снимок правил.
    struct Compiled {
        fileprivate struct Entry {
            let pattern: [String]    // вариант по знакам, каждый без учёта регистра
            let replacement: String
        }
        fileprivate let byFirst: [String: [Entry]]

        /// Один проход по тексту: в каждом месте берётся самый длинный
        /// подходящий вариант (при равной длине — тот, что выше в файле),
        /// подставленная замена заново не просматривается.
        func apply(_ text: String) -> String {
            guard !byFirst.isEmpty else { return text }
            let chars = Array(text.precomposedStringWithCanonicalMapping)
            let keys = chars.map { ReplacementDictionary.folded(String($0)) }
            var out = ""
            var i = 0
            while i < chars.count {
                if let (entry, end) = match(at: i, chars: chars, keys: keys) {
                    out += entry.replacement
                    i = end
                } else {
                    out.append(chars[i])
                    i += 1
                }
            }
            return out
        }

        private func match(at i: Int, chars: [Character], keys: [String]) -> (Entry, Int)? {
            guard let candidates = byFirst[keys[i]] else { return nil }
            for entry in candidates {
                guard let end = end(of: entry.pattern, at: i, chars: chars, keys: keys) else { continue }
                if i > 0, isWord(chars[i - 1]) { continue }
                if end < chars.count, isWord(chars[end]) { continue }
                return (entry, end)
            }
            return nil
        }

        /// Where the variant ends in the text, or nil if it is not here.
        private func end(of pattern: [String], at start: Int, chars: [Character], keys: [String]) -> Int? {
            var j = start
            for element in pattern {
                if element == ReplacementDictionary.gap {
                    while j < chars.count, ReplacementDictionary.isGapChar(chars[j]) { j += 1 }
                } else {
                    guard j < chars.count, keys[j] == element else { return nil }
                    j += 1
                }
            }
            return j
        }
    }

    /// Вариант заменяется, только если рядом с ним нет буквы, цифры или
    /// диакритического знака: «C++» в «C++17» не трогаем. _ - + # и прочее — граница.
    fileprivate static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c.unicodeScalars.allSatisfy {
            [.nonspacingMark, .spacingMark, .enclosingMark].contains($0.properties.generalCategory)
        }
    }

    func compile() -> Compiled {
        var byFirst: [String: [Compiled.Entry]] = [:]
        var used = Set<String>()
        for rule in rules {
            // validate() refuses these; a rule that slipped in anyway still never runs.
            if Self.hasControl(rule.replacement) || Self.mentionsReserved(rule.replacement) { continue }
            for variant in rule.variants where !Self.hasControl(variant) && !Self.mentionsReserved(variant) {
                let key = Self.key(variant)
                guard used.insert(key).inserted else { continue }
                let pattern = Self.pattern(Self.normalizedVariant(variant))
                guard let first = pattern.first else { continue }
                byFirst[first, default: []].append(Compiled.Entry(pattern: pattern, replacement: rule.replacement))
            }
        }
        for (k, list) in byFirst {
            byFirst[k] = list.enumerated().sorted { a, b in
                if a.element.pattern.count != b.element.pattern.count {
                    return a.element.pattern.count > b.element.pattern.count
                }
                return a.offset < b.offset
            }.map(\.element)
        }
        return Compiled(byFirst: byFirst)
    }
}

private func isWord(_ c: Character) -> Bool { ReplacementDictionary.isWordChar(c) }

/// Словарь на диске. Перечитывает файл на каждой диктовке, разбирает только
/// изменившиеся байты; битый файл не отменяет последний исправный снимок.
/// Не потокобезопасен: владелец держит его на одной очереди.
final class DictionaryStore {
    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Giga Pisar/dictionary.json")
    }

    let url: URL
    private(set) var compiled = ReplacementDictionary().compile()
    private var goodBytes: Data?
    private var brokenBytes: Data?
    private var reported: String?

    init(url: URL = DictionaryStore.defaultURL) { self.url = url }

    /// Байты словаря, не больше maxFileBytes + 1; nil — файла нет.
    /// Только обычный файл: FIFO или устройство подвесили бы чтение.
    static func read(_ url: URL) throws -> Data? {
        let type: FileAttributeType?
        do {
            type = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.type] as? FileAttributeType
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        guard type == .typeRegular else { throw DictionaryError("\(url.path) — не обычный файл") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: ReplacementDictionary.maxFileBytes + 1) ?? Data()
    }

    /// Чтение, правка и запись под блокировкой: два параллельных add не теряют друг друга.
    static func update(_ url: URL, read: (URL) throws -> ReplacementDictionary,
                       _ change: (inout ReplacementDictionary) throws -> Void) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockPath = dir.appendingPathComponent(".\(url.lastPathComponent).lock").path
        let lock = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw DictionaryError("не открыть \(lockPath): \(String(cString: strerror(errno)))") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw DictionaryError("не взять блокировку \(lockPath)") }
        defer { flock(lock, LOCK_UN) }

        if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            throw DictionaryError("\(url.path) — символическая ссылка; giga-dict её не перезаписывает")
        }
        var dictionary = try read(url)
        let before = dictionary
        try change(&dictionary)
        guard dictionary != before else { return }
        let data = try dictionary.encode()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .withoutOverwriting)
            guard rename(temp.path, url.path) == 0 else {
                throw DictionaryError("не записать \(url.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Снимок правил для этой диктовки и описание поломки, если она новая.
    func refresh() -> (compiled: ReplacementDictionary.Compiled, problem: String?) {
        let bytes: Data
        do {
            guard let data = try Self.read(url) else {
                compiled = ReplacementDictionary().compile()
                goodBytes = nil; brokenBytes = nil; reported = nil
                return (compiled, nil)
            }
            bytes = data
        } catch {
            return (compiled, report("не читается: \(error)"))
        }
        if bytes == goodBytes {
            brokenBytes = nil; reported = nil // поломка кончилась: следующую покажем снова
            return (compiled, nil)
        }
        if bytes == brokenBytes { return (compiled, nil) }
        do {
            compiled = try ReplacementDictionary.decode(bytes).compile()
            goodBytes = bytes; brokenBytes = nil; reported = nil
            return (compiled, nil)
        } catch {
            brokenBytes = bytes
            reported = String(describing: error)
            return (compiled, reported)
        }
    }

    private func report(_ problem: String) -> String? {
        guard problem != reported else { return nil }
        reported = problem
        return problem
    }
}
