//
//  TextualToolCalls.swift
//  PocketAgent / Runtime
//
//  Разбор вызова действия, который модель написала ТЕКСТОМ, а не отдала библиотеке.
//
//  ⚠️ ЗАЧЕМ ЭТО ПОЯВИЛОСЬ (07.09.2026, замер на телефоне владельца).
//  Модель LFM2.5-2.6B в нашем родном формате `.litertlm` набрала 4 балла из 26,
//  и разбор показал, что дело не в её уме: она честно и правильно звала нужные
//  действия, но своим собственным письмом —
//
//      <|tool_call_start|>[read_file(path='README.md')]<|tool_call_end|>
//
//  Библиотека Google такой записи не понимает и отдаёт её нам как обычный текст.
//  Приложение видело «модель ответила словами»: ноль вызовов, ноль шагов, провал
//  задачи. То есть моделью нельзя было пользоваться из-за одного лишь несовпадения
//  письма — при полностью верном поведении самой модели.
//
//  ⚠️ ЧЕМ ЭТО НЕ ЯВЛЯЕТСЯ. Это НЕ отмена правила «не показывать модели синтаксис
//  вызова» (`SystemPrompt.swift`). Правило про ИНСТРУКЦИЮ: примеров вызова мы
//  по-прежнему не пишем, потому что маленькая модель их списывает буквами. Здесь же
//  мы ничего не показываем — мы ЧИТАЕМ то, что модель написала сама.
//
//  ⚠️ ПОЧЕМУ ЭТО НЕ ДЫРА В ЯДРЕ ПРОДУКТА. Разобранный отсюда вызов идёт ровно той же
//  дорогой, что и любой другой: запись по-прежнему показывается человеку карточкой
//  «до и после» и ждёт нажатия «Применить». Разбор текста добавляет вызовы, а не
//  права.
//
//  ⚠️ ГДЕ ГРАНИЦА ОСТОРОЖНОСТИ. Признать вызовом чужую прозу — значит выполнить то,
//  чего человек не просил. Поэтому берём только три заведомо машинных случая:
//    1) есть служебные метки `<|tool_call_start|>` … `<|tool_call_end|>` — такого
//       в человеческом ответе не бывает никогда;
//    2) есть XML-маркеры `<tool_call>` … `</tool_call>` с JSON внутри (стиль
//       Hermes/Qwen — его пишут Qwen-наследники, в том числе Bonsai 2 под новым
//       движком llama.cpp, 20.09.2026) — и здесь тоже служебные маркеры, которых
//       в человеческом ответе не бывает;
//    3) ВЕСЬ ответ целиком — это ровно один вызов известного нам действия.
//  Имя действия обязано быть из тех, что мы сами объявили: выдуманное имя не
//  превращается ни во что.
//

import Foundation

enum TextualToolCalls {

    private static let startMarker = "<|tool_call_start|>"
    private static let endMarker = "<|tool_call_end|>"
    private static let jsonOpenMarker = "<tool_call>"
    private static let jsonCloseMarker = "</tool_call>"

    /// Попробовать прочитать в тексте модели вызов действия.
    /// - Parameters:
    ///   - text: то, что модель ответила словами.
    ///   - known: имена действий, которые мы ей объявили. ⚠️ ПУСТОЙ СПИСОК — ДЕЙСТВИЯ
    ///     ВЫКЛЮЧЕНЫ: разбор всегда отвечает «вызова нет», и любые маркеры в тексте
    ///     остаются текстом. Для движка Google это прежнее поведение «как до фичи»:
    ///     человек убрал действия кнопкой «Инструменты», модель про них не объявляли,
    ///     и её цитата-пример не превращается в настоящий вызов.
    /// - Returns: имя и аргументы первого вызова, либо nil.
    static func parse(_ text: String, known: [String]) -> (name: String, arguments: [String: String])? {
        // ДЕЙСТВИЙ НЕТ — РАЗБИРАТЬ НЕЧЕГО, и это первая строка не зря: от неё
        // зависит, что цитата вызова в выключенном разговоре доедет до человека
        // текстом, а не выполнится.
        guard !known.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Со служебными метками — самый надёжный случай.
        if let start = trimmed.range(of: startMarker) {
            let afterStart = trimmed[start.upperBound...]
            let body = afterStart.range(of: endMarker).map { String(afterStart[..<$0.lowerBound]) }
                ?? String(afterStart)
            return parseCallList(body, known: known)
        }

        // 2. XML-маркеры с JSON внутри — стиль Hermes/Qwen (Qwen3 и его наследники,
        // включая Bonsai 2). Тот же уровень доверия, что и метки выше: в прозе
        // человека таких маркеров не бывает. Внутри принимаем оба варианта имени
        // поля аргументов — «arguments» (штатный Qwen3) и «parameters» (пишет
        // часть моделей и серверов).
        if let open = trimmed.range(of: jsonOpenMarker) {
            let afterOpen = trimmed[open.upperBound...]
            if let close = afterOpen.range(of: jsonCloseMarker) {
                let body = String(afterOpen[..<close.lowerBound])
                return parseJSONCall(body, known: known)
            }
            // Открыли и не закрыли — вызовом не признаём: это недописанный кусок,
            // а не действие (модель обрежут на лимите — цикл сам попросит повторить).
            return nil
        }

        // 3. Без меток — только если ВЕСЬ ответ и есть один вызов. Кусок вызова
        // посреди прозы намеренно не берём: это уже догадка, а не чтение.
        return parseCallList(trimmed, known: known)
    }

    /// Разобрать JSON-тело одного вызова: {"name": …, "arguments": {…}}
    /// либо {"name": …, "parameters": {…}}.
    ///
    /// ⚠️ Приведение значений к строкам — единственной точкой из Contracts.swift
    /// (`ToolInvocation.normalize`): два разных приведения однажды разошлись бы,
    /// и «да» от одной ветки стало бы единицей от другой.
    private static func parseJSONCall(_ raw: String,
                                      known: [String]) -> (name: String, arguments: [String: String])? {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["name"] as? String,
              known.contains(name) else {
            return nil
        }

        var args: Any? = object["arguments"] ?? object["parameters"]
        // Вариант «аргументы прислали СТРОКОЙ, внутри которой JSON» — тоже бывает
        // у Qwen-наследников; разворачиваем, иначе честный вызов пропал бы зря.
        if let asText = args as? String, let innerData = asText.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: innerData) {
            args = inner
        }
        // Поле отсутствует — законно (у list_files путь необязателен).
        // Не словарь и не отсутствует — вызов не признаём: выдумывать аргументы
        // за модель нельзя.
        guard args == nil || args is [String: Any] else { return nil }
        return (name, ToolInvocation.normalize(args as? [String: Any] ?? [:]))
    }

    /// Разобрать «[имя(аргументы), имя2(…)]» либо «имя(аргументы)».
    private static func parseCallList(_ raw: String, known: [String]) -> (name: String, arguments: [String: String])? {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("[") { body.removeFirst() }
        if body.hasSuffix("]") { body.removeLast() }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // Имя — до первой открывающей скобки.
        guard let parenIndex = body.firstIndex(of: "(") else { return nil }
        let name = String(body[body.startIndex..<parenIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard known.contains(name) else { return nil }

        // Аргументы — до ПАРНОЙ закрывающей скобки, с учётом кавычек: в content
        // модели ничто не мешает прислать и скобку, и точку с запятой.
        guard let argumentsText = balancedParenthesesContent(of: body, openAt: parenIndex) else {
            return nil
        }
        return (name, parseArguments(argumentsText))
    }

    /// Текст внутри скобок, открывшихся на `openAt`, с учётом вложенности и кавычек.
    private static func balancedParenthesesContent(of text: String, openAt: String.Index) -> String? {
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = openAt
        var out = ""

        while index < text.endIndex {
            let character = text[index]

            if escaped {
                out.append(character)
                escaped = false
                index = text.index(after: index)
                continue
            }
            if character == "\\", quote != nil {
                out.append(character)
                escaped = true
                index = text.index(after: index)
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
                out.append(character)
                index = text.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                out.append(character)
                index = text.index(after: index)
                continue
            }
            if character == "(" {
                depth += 1
                if depth > 1 { out.append(character) }
                index = text.index(after: index)
                continue
            }
            if character == ")" {
                depth -= 1
                if depth == 0 { return out }
                out.append(character)
                index = text.index(after: index)
                continue
            }
            out.append(character)
            index = text.index(after: index)
        }
        return nil
    }

    /// «path='README.md', from_line=3» → словарь. Значения приводим к строкам:
    /// дальше по цепочке `ToolInvocation` всё равно работает со строками.
    private static func parseArguments(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for piece in splitTopLevelCommas(text) {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[piece.startIndex..<equals])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(piece[piece.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            result[key] = unquote(&value)
        }
        return result
    }

    /// Снять кавычки и развернуть экранированные символы внутри них.
    private static func unquote(_ value: inout String) -> String {
        guard let first = value.first, first == "'" || first == "\"", value.count >= 2,
              value.last == first
        else { return value }

        var inner = String(value.dropFirst().dropLast())
        // Разворачиваем то, что модель обязана была экранировать внутри кавычек.
        // Порядок важен: обратный слэш последним, иначе он съест собственные замены.
        inner = inner.replacingOccurrences(of: "\\n", with: "\n")
        inner = inner.replacingOccurrences(of: "\\t", with: "\t")
        inner = inner.replacingOccurrences(of: "\\\"", with: "\"")
        inner = inner.replacingOccurrences(of: "\\'", with: "'")
        inner = inner.replacingOccurrences(of: "\\\\", with: "\\")
        return inner
    }

    /// Разбить по запятым, которые НЕ внутри кавычек и не внутри скобок.
    private static func splitTopLevelCommas(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false

        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != nil {
                current.append(character)
                escaped = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                current.append(character)
            case "(", "[", "{":
                depth += 1
                current.append(character)
            case ")", "]", "}":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(current)
        }
        return parts
    }
}
