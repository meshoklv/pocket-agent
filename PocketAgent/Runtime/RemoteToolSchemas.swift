//
//  RemoteToolSchemas.swift
//  PocketAgent / Runtime
//
//  Описания действий для работы по ключу — в том виде, в каком их понимает
//  общепринятый вид запроса (тот, что у OpenAI: список `tools`, а в ответе `tool_calls`).
//
//  ⚠️ ПОЧЕМУ ОТДЕЛЬНЫЙ ФАЙЛ, А НЕ ПОВТОРНОЕ ИСПОЛЬЗОВАНИЕ MLXToolSchemas.
//  Форма словаря там ТА ЖЕ САМАЯ — и это не совпадение: Apple собирает описание ровно
//  по общепринятому образцу. Но тот файл отдаёт `ToolSpec` из библиотеки Apple, то есть
//  тянет чужую библиотеку в код, который к ней отношения не имеет. Работа по сети обязана
//  собираться и работать, даже если движок Apple из приложения когда-нибудь выпадет.
//  Здесь простые словари, которые понимает обычный сборщик JSON.
//
//  ⚠️ ДЕЙСТВИЙ ЧЕТЫРЕ. Пятое (поиск в интернете) появляется, только когда человек сам
//  включил поиск, — и приходит оно сюда тем же путём, что и к местным движкам:
//  списком объявлений от модуля Agent. Своего списка «а вот ещё есть» здесь нет.
//
//  ⚠️ ГЛАВНОЕ, ЧЕГО ЗДЕСЬ НЕТ: `tool_choice: "required"` и прочих способов ЗАСТАВИТЬ
//  модель звать действия. Мы просим `auto` — то есть модель вправе ответить и словами.
//  Это не мягкотелость: наш цикл показывает человеку карточку на КАЖДОЕ действие,
//  и модель, загнанная в «только действия», начинает звать их вхолостую.
//

import Foundation

enum RemoteToolSchemas {

    /// Описание одного действия. Форма — общепринятая: «type: function», внутри имя,
    /// пояснение и разбор полей, отдельным списком — какие поля обязательны.
    static func schema(for declaration: ToolDeclaration) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []

        for parameter in declaration.parameters {
            var field: [String: Any] = ["type": jsonType(of: parameter.type)]
            // Пустое пояснение не кладём вовсе: каждый лишний знак описания оплачивается
            // деньгами человека в КАЖДОМ запросе — здесь это уже не образное выражение.
            if !parameter.details.isEmpty {
                field["description"] = parameter.details
            }
            properties[parameter.name] = field
            if parameter.isRequired { required.append(parameter.name) }
        }

        return [
            "type": "function",
            "function": [
                "name": declaration.name,
                "description": declaration.details,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    private static func jsonType(of type: ToolParameterType) -> String {
        switch type {
        case .string:  return "string"
        case .integer: return "integer"
        case .number:  return "number"
        case .boolean: return "boolean"
        }
    }

    /// Что отдаём модели: ровно те действия, которые объявил модуль Agent.
    ///
    /// Неизвестное имя молча пропускаем — лучше меньше действий, чем описание, под
    /// которое в приложении нет исполнителя: модель позовёт его, а выполнить будет нечем.
    static func tools(matching declarations: [ToolDeclaration]) -> [[String: Any]] {
        declarations.compactMap { declaration in
            guard ToolKind(rawValue: declaration.name) != nil else { return nil }
            return schema(for: declaration)
        }
    }
}
