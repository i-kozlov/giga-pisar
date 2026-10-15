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
              version.doubleValue == Double(Self.version) else {
            throw DictionaryError("version должен быть \(Self.version)")
        }
        guard let list = root["rules"] as? [Any] else { throw DictionaryError("rules должен быть массивом") }
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
        return data
    }

    private static func onlyKeys(_ obj: [String: Any], _ allowed: Set<String>, at: String) throws {
        if let extra = obj.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw DictionaryError("\(at): неизвестное поле \(extra)")
        }
    }

    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    // MARK: проверка

    /// Ключ варианта: NFC, без краевых пробелов, без учёта регистра.
    static func key(_ variant: String) -> String {
        folded(normalizedVariant(variant))
    }

    static func normalizedVariant(_ variant: String) -> String {
        variant.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func folded(_ s: String) -> String {
        s.folding(options: .caseInsensitive, locale: nil)
    }

    func validate() throws {
        guard rules.count <= Self.maxRules else { throw DictionaryError("правил больше \(Self.maxRules)") }
        var seen: [String: String] = [:]
        for (i, rule) in rules.enumerated() {
            let at = "правило \(i + 1)"
            guard !rule.variants.isEmpty else { throw DictionaryError("\(at): нет ни одного варианта") }
            guard !rule.replacement.isEmpty else { throw DictionaryError("\(at): пустая замена") }
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
            let startsWord: Bool
            let endsWord: Bool
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
                if let entry = match(at: i, chars: chars, keys: keys) {
                    out += entry.replacement
                    i += entry.pattern.count
                } else {
                    out.append(chars[i])
                    i += 1
                }
            }
            return out
        }

        private func match(at i: Int, chars: [Character], keys: [String]) -> Entry? {
            guard let candidates = byFirst[keys[i]] else { return nil }
            for entry in candidates {
                let end = i + entry.pattern.count
                guard end <= chars.count, Array(keys[i..<end]) == entry.pattern else { continue }
                if entry.startsWord, i > 0, isWord(chars[i - 1]) { continue }
                if entry.endsWord, end < chars.count, isWord(chars[end]) { continue }
                return entry
            }
            return nil
        }
    }

    /// Граница слова: буквы и цифры (со знаками над ними) — часть слова,
    /// всё остальное, включая _ - + #, — граница.
    fileprivate static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    func compile() -> Compiled {
        var byFirst: [String: [Compiled.Entry]] = [:]
        var used = Set<String>()
        for rule in rules {
            for variant in rule.variants {
                let key = Self.key(variant)
                guard used.insert(key).inserted else { continue }
                let chars = Array(Self.normalizedVariant(variant))
                guard let first = chars.first, let last = chars.last else { continue }
                let pattern = chars.map { Self.folded(String($0)) }
                let entry = Compiled.Entry(pattern: pattern, replacement: rule.replacement,
                                           startsWord: Self.isWordChar(first), endsWord: Self.isWordChar(last))
                byFirst[pattern[0], default: []].append(entry)
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
