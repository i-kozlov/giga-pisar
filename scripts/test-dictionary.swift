import Foundation

// Standalone checks of swift/Dictionary.swift: file format and replacement semantics.
@main struct DictionaryTests {
    static func dict(_ rules: [([String], String)]) -> ReplacementDictionary.Compiled {
        let d = ReplacementDictionary(rules: rules.map { DictionaryRule(variants: $0.0, replacement: $0.1) })
        do { try d.validate() } catch { fatalError("valid fixture rejected: \(error)") }
        return d.compile()
    }

    static func expect(_ got: String, _ want: String, _ what: String) {
        precondition(got == want, "\(what): got «\(got)», want «\(want)»")
    }

    static func rejects(_ json: String, _ what: String) {
        do {
            _ = try ReplacementDictionary.decode(Data(json.utf8))
            fatalError("\(what): accepted")
        } catch is DictionaryError {
        } catch { fatalError("\(what): unexpected \(error)") }
    }

    static func main() {
        // Cyrillic and Latin, case-insensitive, replacement keeps its own case.
        let d = dict([(["опен эй ай", "open ai"], "OpenAI"), (["кодекс"], "Codex")])
        expect(d.apply("Спроси Опен Эй Ай и кодекс."), "Спроси OpenAI и Codex.", "basic")
        expect(d.apply("OPEN AI"), "OpenAI", "upper case")
        // Word boundaries: no match inside a longer word.
        expect(d.apply("кодексы и кодекс"), "кодексы и Codex", "boundary")
        expect(d.apply("перекодекс"), "перекодекс", "prefix boundary")
        print("PASS cyrillic/latin, case-insensitive, word boundaries")

        // Decomposed input (й as и + combining breve) matches a precomposed variant.
        let y = dict([(["йод"], "Iodine")])
        expect(y.apply("и\u{0306}од есть"), "Iodine есть", "NFC input")
        let yo = dict([(["ёлка"], "Tree")])
        expect(yo.apply("елка"), "елка", "ё and е are different letters")
        print("PASS NFC, ё stays distinct from е")

        // Longest match at a position wins; replacement output is never rescanned.
        let o = dict([(["гига"], "Giga"), (["гига писарь"], "Гига Писарь")])
        expect(o.apply("гига писарь и гига"), "Гига Писарь и Giga", "longest first")
        let c = dict([(["кот"], "собака"), (["собака"], "волк")])
        expect(c.apply("кот и собака"), "собака и волк", "no cascade")
        let swap = dict([(["а1"], "б1"), (["б1"], "а1")])
        expect(swap.apply("а1 б1"), "б1 а1", "swap without cycle")
        print("PASS longest match, no cascades")

        // Replacement is literal; symbols at the edges are not word characters.
        let lit = dict([(["доллар один"], "$1 \\0")])
        expect(lit.apply("доллар один"), "$1 \\0", "literal $ and backslash")
        let cpp = dict([(["си плюс плюс"], "C++"), (["C#"], "C♯")])
        expect(cpp.apply("на си плюс плюс и C#."), "на C++ и C♯.", "C++ and C#")
        let snake = dict([(["foo"], "bar")])
        expect(snake.apply("foo_bar foo-bar foobar"), "bar_bar bar-bar foobar", "underscore and hyphen are boundaries")
        print("PASS literal replacement, C++/C#, _ and - boundaries")

        // Pisar address: the dictionary may create or remove it; that is accepted behaviour.
        let p = dict([(["пихарь"], "писарь")])
        expect(p.apply("текст, пихарь исправь"), "текст, писарь исправь", "creates address")
        expect(p.apply("наш пихарь сегодня занят"), "наш писарь сегодня занят", "address in the middle")
        let q = dict([(["писарь"], "помощник")])
        expect(q.apply("текст, писарь исправь"), "текст, помощник исправь", "removes address")
        print("PASS Pisar address created and removed as configured")

        // File format: JSON5 comments and trailing commas, strict schema.
        let json5 = """
        // словарь
        {version: 1, rules: [
          {variants: ['опен эй ай', "open ai",], replacement: "OpenAI", note: "компания",},
        ],}
        """
        do {
            let file = try ReplacementDictionary.decode(Data(json5.utf8))
            precondition(file.rules == [DictionaryRule(variants: ["опен эй ай", "open ai"], replacement: "OpenAI", note: "компания")])
            let again = try ReplacementDictionary.decode(try file.encode())
            precondition(again == file, "encode/decode round trip")
        } catch { fatalError("JSON5 rejected: \(error)") }
        rejects(#"{"version": 2, "rules": []}"#, "unknown version")
        rejects(#"{"version": true, "rules": []}"#, "bool version")
        rejects(#"{"version": 1, "rules": [], "extra": 1}"#, "unknown root key")
        rejects(#"{"version": 1, "rules": [{"variants": ["a"], "replacement": "b", "x": 1}]}"#, "unknown rule key")
        rejects(#"{"version": 1, "rules": [{"variants": [], "replacement": "b"}]}"#, "no variants")
        rejects(#"{"version": 1, "rules": [{"variants": ["  "], "replacement": "b"}]}"#, "blank variant")
        rejects(#"{"version": 1, "rules": [{"variants": ["a"], "replacement": ""}]}"#, "empty replacement")
        rejects(#"{"version": 1, "rules": [{"variants": ["a"], "replacement": "b", "note": null}]}"#, "null note")
        rejects(#"{"version": 1, "rules": [{"variants": [1], "replacement": "b"}]}"#, "number variant")
        rejects(#"{"version": 1, "rules": [{"variants": ["Кот"], "replacement": "b"}, {"variants": ["кот"], "replacement": "c"}]}"#,
                "same variant, different replacements")
        do {
            let same = try ReplacementDictionary.decode(Data(#"{"version": 1, "rules": [{"variants": ["Кот"], "replacement": "b"}, {"variants": ["кот"], "replacement": "b"}]}"#.utf8))
            expect(same.compile().apply("кот"), "b", "duplicate with same replacement")
        } catch { fatalError("duplicate with same replacement rejected: \(error)") }
        let leading = ReplacementDictionary(rules: [DictionaryRule(variants: ["x"], replacement: " y ")])
        expect(leading.compile().apply("x"), " y ", "replacement is not trimmed")
        print("PASS JSON5 input, strict schema, round trip")
    }
}
