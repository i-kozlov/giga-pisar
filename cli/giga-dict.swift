// giga-dict: словарь замен Гига Писаря из командной строки.
// Собирается build.sh вместе с swift/Dictionary.swift и лежит в бандле:
// "/Applications/Giga Pisar.app/Contents/MacOS/giga-dict".

import Foundation

@main struct GigaDict {
    static let usage = """
    giga-dict [--file ПУТЬ] КОМАНДА

      path                                  где лежит словарь
      list                                  все правила
      add --variant ФРАЗА [--variant ФРАЗА…] --replacement ЗАМЕНА [--note ЗАМЕТКА]
                                            добавить; вариант с той же заменой — ничего не делает,
                                            с другой — ошибка
      remove ФРАЗА                          убрать один вариант; опустевшее правило уходит целиком
      test ТЕКСТ                            что получится после замен

    Варианты сравниваются без учёта регистра и только целыми словами;
    замена вставляется как написана. Файл — JSON, читается с комментариями JSON5,
    но add и remove перезаписывают его обычным JSON без комментариев.
    """

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        var url = DictionaryStore.defaultURL
        if args.first == "--file" {
            guard args.count >= 2 else { fail("после --file нужен путь") }
            url = URL(fileURLWithPath: args[1])
            args.removeFirst(2)
        }
        guard let command = args.first else { print(usage); exit(0) }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "path":
                print(url.path)
            case "list":
                let dictionary = try read(url)
                for (i, rule) in dictionary.rules.enumerated() {
                    let note = rule.note.map { "  # \($0)" } ?? ""
                    print("\(i + 1). \(rule.variants.joined(separator: ", ")) → \(rule.replacement)\(note)")
                }
            case "test":
                guard rest.count == 1 else { fail("test принимает один текст в кавычках") }
                print(try read(url).compile().apply(rest[0]))
            case "add":
                let (variants, replacement, note) = try parseAdd(rest)
                try update(url) { dictionary in try add(&dictionary, variants, replacement, note) }
            case "remove":
                guard rest.count == 1 else { fail("remove принимает одну фразу") }
                try update(url) { dictionary in try remove(&dictionary, rest[0]) }
            case "-h", "--help", "help":
                print(usage)
            default:
                fail("неизвестная команда \(command)\n\n\(usage)")
            }
        } catch {
            fail(String(describing: error))
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("giga-dict: \(message)\n".utf8))
        exit(1)
    }

    static func note(_ message: String) {
        FileHandle.standardError.write(Data("giga-dict: \(message)\n".utf8))
    }

    // MARK: файл

    /// Нет файла — пустой словарь. Битый — ошибка: ни читать дальше, ни перезаписывать.
    static func read(_ url: URL) throws -> ReplacementDictionary {
        guard let data = try DictionaryStore.read(url) else { return ReplacementDictionary() }
        do { return try ReplacementDictionary.decode(data) } catch {
            throw DictionaryError("\(url.path): \(error) — исправь файл руками, giga-dict его не перезапишет")
        }
    }

    /// Чтение, правка и запись под блокировкой: два параллельных add не теряют друг друга.
    static func update(_ url: URL, _ change: (inout ReplacementDictionary) throws -> Void) throws {
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
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        do {
            try data.write(to: temp)
            guard rename(temp.path, url.path) == 0 else {
                throw DictionaryError("не записать \(url.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    // MARK: команды

    static func parseAdd(_ args: [String]) throws -> ([String], String, String?) {
        var variants: [String] = [], replacement: String?, note: String?
        var i = 0
        while i < args.count {
            guard i + 1 < args.count else { throw DictionaryError("у \(args[i]) нет значения") }
            switch args[i] {
            case "--variant": variants.append(args[i + 1])
            case "--replacement":
                guard replacement == nil else { throw DictionaryError("--replacement указан дважды") }
                replacement = args[i + 1]
            case "--note":
                guard note == nil else { throw DictionaryError("--note указан дважды") }
                note = args[i + 1]
            default: throw DictionaryError("неизвестный ключ \(args[i])")
            }
            i += 2
        }
        guard !variants.isEmpty else { throw DictionaryError("нужен хотя бы один --variant") }
        guard let replacement else { throw DictionaryError("нужен --replacement") }
        return (variants, replacement, note)
    }

    /// Новые варианты дописываются к правилу с той же заменой, иначе — новое правило.
    static func add(_ dictionary: inout ReplacementDictionary, _ variants: [String],
                    _ replacement: String, _ note: String?) throws {
        var fresh: [String] = []
        for variant in variants {
            let key = ReplacementDictionary.key(variant)
            if let rule = dictionary.rules.first(where: { $0.variants.contains { ReplacementDictionary.key($0) == key } }) {
                guard rule.replacement == replacement else {
                    throw DictionaryError("«\(variant)» уже заменяется на «\(rule.replacement)»; сначала remove")
                }
                self.note("«\(variant)» → «\(replacement)» уже есть")
            } else if !fresh.contains(where: { ReplacementDictionary.key($0) == key }) {
                fresh.append(variant)
            }
        }
        guard !fresh.isEmpty else { return }
        if let i = dictionary.rules.firstIndex(where: { $0.replacement == replacement }) {
            dictionary.rules[i].variants += fresh
            if dictionary.rules[i].note == nil { dictionary.rules[i].note = note }
        } else {
            dictionary.rules.append(DictionaryRule(variants: fresh, replacement: replacement, note: note))
        }
        try dictionary.validate()
    }

    static func remove(_ dictionary: inout ReplacementDictionary, _ variant: String) throws {
        let key = ReplacementDictionary.key(variant)
        guard let i = dictionary.rules.firstIndex(where: { $0.variants.contains { ReplacementDictionary.key($0) == key } })
        else { throw DictionaryError("«\(variant)» в словаре нет") }
        dictionary.rules[i].variants.removeAll { ReplacementDictionary.key($0) == key }
        if dictionary.rules[i].variants.isEmpty { dictionary.rules.remove(at: i) }
    }
}
