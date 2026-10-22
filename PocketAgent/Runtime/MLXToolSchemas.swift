//
//  MLXToolSchemas.swift
//  PocketAgent / Runtime
//
//  Описания четырёх действий в том виде, в каком их понимает движок Apple.
//  Близнец LiteRTToolSchemas.swift — но устроен принципиально иначе, и это стоит
//  объяснить, потому что разница как раз в том месте, где раньше ломалось.
//
//  ⚠️ У ДВИЖКА GOOGLE ОПИСАНИЕ ДЕЙСТВИЯ — ЭТО ТИП, У APPLE — ПРОСТО НАБОР ПОЛЕЙ.
//  Google требует объявить структуру со свойствами и обёртками; из-за этого описания
//  там ПРИХОДИТСЯ дублировать руками, и они уже расходились с настоящими инструментами
//  (ровно поэтому в том файле живёт сторож «схема не разъехалась»). У Apple же
//  описание — обычный словарь (ToolSpec, Tool.swift:5), и его можно собрать прямо
//  из объявления, которое прислал модуль Agent. Тогда разойтись просто НЕЧЕМУ:
//  и модель, и наши проверки читают буквально одну и ту же строку.
//
//  ⚠️ ПОЧЕМУ ЧЕТЫРЕ ЗАПАСНЫХ ОПИСАНИЯ ВСЁ-ТАКИ ЗАПИСАНЫ РУКАМИ. Они нужны на один
//  случай: объявлений не прислали вовсе. Отдать модели пустой набор — значит получить
//  помощника, который умеет только разговаривать, и человек об этом не узнает.
//  Заодно эти четыре и есть мерка для сторожа: разъехались они с настоящими
//  инструментами — в отладочной сборке это сразу видно в выводе.
//
//  ⚠️ ПОИСКА В ЗАПАСНОМ НАБОРЕ НЕТ НАМЕРЕННО. Разрешение выйти в интернет даёт человек
//  переключателем, а не запасная ветка кода. Выключен поиск — действий у модели четыре.
//
//  Тексты берутся из ToolTexts (Contracts.swift) — те же самые, что уходят в реализации
//  инструментов. Каждое лишнее слово здесь оплачивается КАЖДЫЙ ход, поэтому они такие
//  короткие; удлинять их «для понятности» нельзя.
//

import Foundation
import MLXLMCommon

enum MLXToolSchemas {

    // MARK: - Сборка описания

    /// Описание одного действия в виде, который понимает движок Apple.
    ///
    /// ⚠️ ФОРМА СЛОВАРЯ ЗДЕСЬ НЕ НАША ВЫДУМКА — она снята с того, как Apple собирает
    /// описание сама (Tool.swift, строки 43–55): «type: function», внутри «function»
    /// с именем, пояснением и разбором полей, и отдельным списком — какие поля
    /// обязательны. Отойти от этой формы значит отдать модели описание, которое
    /// шаблон разговора не разберёт, и действий у неё не окажется вовсе.
    static func spec(name: String, details: String, parameters: [ToolParameterSpec]) -> ToolSpec {
        var properties: [String: any Sendable] = [:]
        var required: [String] = []

        for parameter in parameters {
            var field: [String: any Sendable] = ["type": jsonType(of: parameter.type)]
            // ⚠️ Пустое пояснение — это тоже решение, а не забытое поле: у чтения
            // пояснений к номерам строк нет намеренно (см. ToolTexts). Пустую строку
            // в описание не кладём вовсе — иначе платим за ключ, который ничего не говорит.
            if !parameter.details.isEmpty {
                field["description"] = parameter.details
            }
            properties[parameter.name] = field
            if parameter.isRequired {
                required.append(parameter.name)
            }
        }

        return [
            "type": "function",
            "function": [
                "name": name,
                "description": details,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }

    /// Наши виды значений — словами, которые понимает описание.
    private static func jsonType(of type: ToolParameterType) -> String {
        switch type {
        case .string:  return "string"
        case .integer: return "integer"
        case .number:  return "number"
        case .boolean: return "boolean"
        }
    }

    static func spec(for declaration: ToolDeclaration) -> ToolSpec {
        spec(name: declaration.name, details: declaration.details, parameters: declaration.parameters)
    }

    // MARK: - Что отдаём модели

    /// Отдаём модели ровно те действия, которые объявил модуль Agent.
    ///
    /// Неизвестное имя молча пропускаем — лучше меньше действий, чем описание, под
    /// которое в приложении нет исполнителя: модель позовёт его, а выполнить будет нечем.
    ///
    /// ⚠️⚠️ ПУСТОЙ СПИСОК ОЗНАЧАЕТ «НИ ОДНОГО ДЕЙСТВИЯ», А НЕ «ВСЕ ЧЕТЫРЕ». Раньше здесь
    /// стоял запасной набор (`return core`) на случай неправильно собранного реестра.
    /// С кнопкой «Инструменты» в чате пустой список стал законным и означает обратное:
    /// человек выключил действия, и модели не должно уйти ни одного описания. Со старым
    /// запасным набором разговорный режим отправлял бы все четыре действия — то есть
    /// не работал бы, и заметить это со стороны было бы нечем.
    static func tools(matching declarations: [ToolDeclaration]) -> [ToolSpec] {
        return declarations.compactMap { declaration in
            guard ToolKind(rawValue: declaration.name) != nil else { return nil }
            return spec(for: declaration)
        }
    }

    // MARK: - Запасной набор и сторож

    /// Четыре обязательных действия. Без них агент неработоспособен: не осмотрится,
    /// не прочитает, не сделает работу и не сможет сказать, что закончил.
    static var core: [ToolSpec] {
        coreDeclarations.map(spec(for:))
    }

    /// Те же четыре — но объявлениями, чтобы сторож ниже мог сравнить их с настоящими.
    ///
    /// ⚠️ Поля повторяют реализации инструментов один в один, включая необязательные
    /// номера строк. Без них чтение страницами и правка по строкам не работают ВООБЩЕ:
    /// модель видит ровно то описание, которое мы отдали, и поле, которого в описании
    /// нет, она не назовёт — даже если попросить её словами.
    private static let coreDeclarations: [ToolDeclaration] = [
        ToolDeclaration(
            name: ToolKind.listFiles.rawValue,
            details: ToolTexts.listFiles,
            parameters: [
                ToolParameterSpec(name: "path", details: ToolTexts.listFilesPath,
                                  type: .string, isRequired: false)
            ]),
        ToolDeclaration(
            name: ToolKind.readFile.rawValue,
            details: ToolTexts.readFile,
            parameters: [
                ToolParameterSpec(name: "path", details: ToolTexts.readFilePath,
                                  type: .string, isRequired: true),
                ToolParameterSpec(name: "from_line", details: ToolTexts.readFileFromLine,
                                  type: .integer, isRequired: false),
                ToolParameterSpec(name: "to_line", details: ToolTexts.readFileToLine,
                                  type: .integer, isRequired: false)
            ]),
        ToolDeclaration(
            name: ToolKind.writeFile.rawValue,
            details: ToolTexts.writeFile,
            parameters: [
                ToolParameterSpec(name: "path", details: ToolTexts.writeFilePath,
                                  type: .string, isRequired: true),
                ToolParameterSpec(name: "content", details: ToolTexts.writeFileContent,
                                  type: .string, isRequired: true),
                ToolParameterSpec(name: "from_line", details: ToolTexts.writeFileFromLine,
                                  type: .integer, isRequired: false),
                ToolParameterSpec(name: "to_line", details: ToolTexts.writeFileToLine,
                                  type: .integer, isRequired: false)
            ]),
        ToolDeclaration(
            name: ToolKind.finish.rawValue,
            details: ToolTexts.finish,
            parameters: [
                ToolParameterSpec(name: "summary", details: ToolTexts.finishSummary,
                                  type: .string, isRequired: true)
            ])
    ]

    /// Сторож: запасной набор не должен расходиться с настоящими инструментами.
    ///
    /// ⚠️ ЗАЧЕМ ОН НУЖЕН, ЕСЛИ ОПИСАНИЯ И ТАК СОБИРАЮТСЯ ИЗ ОБЪЯВЛЕНИЙ. Затем, что
    /// запасной набор выше — единственное место во всём движке Apple, где имена полей
    /// написаны РУКАМИ. Появится у чтения пятое поле, переименуется `content` — и здесь
    /// об этом никто не узнает, а всплывёт это только в тот день, когда объявлений
    /// не прислали и в дело пошёл запасной набор. Разбирать такое по чужому телефону —
    /// худший из возможных разборов, поэтому расхождение видно сразу в отладочной сборке.
    static func warnIfOutOfSync(with declarations: [ToolDeclaration]) {
        #if DEBUG
        let mine = Dictionary(uniqueKeysWithValues: coreDeclarations.map { ($0.name, $0) })
        for declaration in declarations {
            guard ToolKind(rawValue: declaration.name) != nil else {
                print("[MLXToolSchemas] Действие «\(declaration.name)» модели не отдаётся: такого у нас нет.")
                continue
            }
            // Поиск в запасном наборе не лежит намеренно — сравнивать его не с чем.
            guard let spare = mine[declaration.name] else { continue }

            if spare.details != declaration.details {
                print("[MLXToolSchemas] Пояснение «\(declaration.name)» разошлось с запасным набором.")
            }
            let spareFields = spare.parameters.map { "\($0.name):\($0.type.rawValue):\($0.isRequired)" }.sorted()
            let realFields = declaration.parameters.map { "\($0.name):\($0.type.rawValue):\($0.isRequired)" }.sorted()
            if spareFields != realFields {
                print("[MLXToolSchemas] Поля «\(declaration.name)» разошлись с запасным набором: "
                    + "у нас \(spareFields), на самом деле \(realFields).")
            }
        }
        #endif
    }
}
