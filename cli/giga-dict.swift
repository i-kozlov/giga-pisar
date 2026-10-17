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
      remove ФРАЗА                          убрать вариант из всех правил; опустевшее правило уходит целиком
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
            url = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
            args.removeFirst(2)
        }
        guard let command = args.first else { print(usage); exit(0) }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "path":
                guard rest.isEmpty else { fail("path без аргументов") }
                print(url.path)
            case "list":
                guard rest.isEmpty else { fail("list без аргументов; --file пишется до команды") }
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
                try DictionaryStore.update(url, read: read) { dictionary in try add(&dictionary, variants, replacement, note) }
            case "remove":
                guard rest.count == 1 else { fail("remove принимает одну фразу") }
                try DictionaryStore.update(url, read: read) { dictionary in try remove(&dictionary, rest[0]) }
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

    /// Новые варианты дописываются к правилу с той же заменой и той же заметкой,
    /// иначе — новое правило: заметка не теряется.
    static func add(_ dictionary: inout ReplacementDictionary, _ variants: [String],
                    _ replacement: String, _ note: String?) throws {
        var fresh: [String] = []
        for variant in variants {
            let key = ReplacementDictionary.key(variant)
            if let rule = dictionary.rules.first(where: { $0.variants.contains { ReplacementDictionary.key($0) == key } }) {
                guard rule.replacement == replacement else {
                    throw DictionaryError("«\(variant)» уже заменяется на «\(rule.replacement)»; сначала remove")
                }
                let unchanged = note.map { $0 != rule.note ? "; заметка не изменена" : "" } ?? ""
                self.note("«\(variant)» → «\(replacement)» уже есть\(unchanged)")
            } else if !fresh.contains(where: { ReplacementDictionary.key($0) == key }) {
                fresh.append(variant)
            }
        }
        guard !fresh.isEmpty else { return }
        if let i = dictionary.rules.firstIndex(where: { $0.replacement == replacement && $0.note == note }) {
            dictionary.rules[i].variants += fresh
        } else {
            dictionary.rules.append(DictionaryRule(variants: fresh, replacement: replacement, note: note))
        }
        try dictionary.validate()
    }

    /// Убирает вариант из всех правил: одинаковый вариант с одной заменой может стоять в нескольких.
    static func remove(_ dictionary: inout ReplacementDictionary, _ variant: String) throws {
        let key = ReplacementDictionary.key(variant)
        let before = dictionary.rules
        for i in dictionary.rules.indices {
            dictionary.rules[i].variants.removeAll { ReplacementDictionary.key($0) == key }
        }
        guard dictionary.rules != before else { throw DictionaryError("«\(variant)» в словаре нет") }
        dictionary.rules.removeAll { $0.variants.isEmpty }
    }
}
