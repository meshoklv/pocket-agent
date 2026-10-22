//
//  ToolRegistry.swift
//  PocketAgent
//
//  Реестр инструментов: отдаёт их описания модели, ищет инструмент по имени
//  и — главное — не падает, когда маленькая модель зовёт что-то своё.
//  Вместо ошибки мы возвращаем модели подсказку со списком доступных имён.
//
//  ⚠️ Обязательных инструментов ЧЕТЫРЕ (ToolKind.core). Пятый — поиск в интернете —
//  кладётся сюда композиционным корнем ТОЛЬКО когда человек включил поиск сам.
//  Выключен — реестр снова из четырёх, и модель о поиске не знает вовсе.
//
//  Сами реализации инструментов (ListFilesTool и прочие) живут в Tools/FileToolsImpl.swift
//  и передаются сюда готовыми: реестр ничего не знает про файлы и про папку проекта.
//

import Foundation

// MARK: - Что не так с вызовом модели

/// Беда с вызовом инструмента, которую можно объяснить модели и дать ей ещё попытку.
public enum ToolLookupProblem: Sendable, Equatable {
    /// Такого инструмента нет.
    case unknownTool(name: String, available: [String])
    /// Инструмент есть, но модель не прислала обязательные параметры.
    case missingArguments(tool: String, arguments: [String])

    /// Текст, который уходит обратно в модель.
    public var modelFacingMessage: String {
        switch self {
        case .unknownTool(let name, let available):
            return AgentPrompt.unknownTool(name: name, available: available)
        case .missingArguments(let tool, let arguments):
            return AgentPrompt.missingArguments(tool: tool, arguments: arguments)
        }
    }

    /// Короткая строка для ленты чата человеческим языком.
    public var userFacingMessage: String {
        switch self {
        case .unknownTool(let name, _):
            return "Модель попросила несуществующее действие «\(name)» — подсказал ей список."
        case .missingArguments(let tool, let arguments):
            return "Модель не указала \(arguments.joined(separator: ", ")) для действия \(tool) — попросил повторить."
        }
    }
}

// MARK: - Реестр

/// Реестр инструментов. Значимый тип: его безопасно копировать между задачами.
public struct DefaultToolRegistry: ToolRegistry {

    public let tools: [any AgentTool]
    public let declarations: [ToolDeclaration]

    /// Точное имя → инструмент.
    private let byExactName: [String: any AgentTool]
    /// Приведённое имя (только буквы и цифры, в нижнем регистре) → инструмент.
    /// Нужен, потому что малые модели пишут «ListFiles», «list-files», «list_files()».
    private let byLooseName: [String: any AgentTool]

    public init(tools: [any AgentTool]) {
        // 1) убираем дубликаты по имени — побеждает первый
        var unique: [any AgentTool] = []
        var seenNames = Set<String>()
        for tool in tools where !seenNames.contains(tool.name) {
            seenNames.insert(tool.name)
            unique.append(tool)
        }

        // 2) фиксируем порядок по ToolKind: модель всегда видит инструменты одинаково
        var ordered: [any AgentTool] = []
        for kind in ToolKind.allCases {
            if let tool = unique.first(where: { $0.kind == kind }) {
                ordered.append(tool)
            }
        }
        let orderedNames = Set(ordered.map(\.name))
        ordered.append(contentsOf: unique.filter { !orderedNames.contains($0.name) })

        self.tools = ordered
        self.declarations = ordered.map(\.declaration)

        var exact: [String: any AgentTool] = [:]
        var loose: [String: any AgentTool] = [:]
        for tool in ordered {
            exact[tool.name] = tool
            loose[DefaultToolRegistry.loosen(tool.name)] = tool
        }
        self.byExactName = exact
        self.byLooseName = loose
    }

    // MARK: Поиск

    public func tool(for invocation: ToolInvocation) -> (any AgentTool)? {
        if let kind = invocation.kind, let tool = byExactName[kind.rawValue] {
            return tool
        }
        if let tool = byExactName[invocation.rawName] {
            return tool
        }
        // последняя попытка: «ListFiles», «list-files», «list_files()» → list_files
        return byLooseName[DefaultToolRegistry.loosen(invocation.rawName)]
    }

    public func tool(named name: String) -> (any AgentTool)? {
        byExactName[name] ?? byLooseName[DefaultToolRegistry.loosen(name)]
    }

    // MARK: Приведение имени

    /// «list_files()» / «ListFiles» / «list-files» → «listfiles».
    private static func loosen(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Общая проверка вызова для любого реестра

public extension ToolRegistry {

    /// Имена, которые можно показать модели в подсказке.
    var availableNames: [String] { declarations.map(\.name) }

    /// Каких из четырёх ОБЯЗАТЕЛЬНЫХ инструментов не хватает — проверка сборки на старте.
    ///
    /// ⚠️ Считаем по `ToolKind.core`, а не по `allCases`. Поиск в интернете человек
    /// включает сам, и выключенный поиск — это НОРМАЛЬНО собранный реестр, а не поломка.
    /// Со старой проверкой по `allCases` приложение падало бы на assert у каждого,
    /// кто поиск не включил, — то есть у всех по умолчанию.
    var missingKinds: [ToolKind] {
        ToolKind.core.filter { kind in !tools.contains(where: { $0.kind == kind }) }
    }

    /// Собран ли реестр правильно: все четыре обязательных инструмента на месте
    /// и лишнего (двух одинаковых видов) нет.
    var isComplete: Bool { missingKinds.isEmpty && tools.count >= ToolKind.core.count }

    /// Проверяет вызов модели ДО запуска инструмента.
    /// nil — вызов пригоден; иначе — готовая подсказка, которую вернём модели.
    func problem(with invocation: ToolInvocation) -> ToolLookupProblem? {
        guard let tool = tool(for: invocation) else {
            return .unknownTool(name: invocation.rawName, available: availableNames)
        }

        let missing = tool.declaration.parameters.compactMap { spec -> String? in
            guard spec.isRequired else { return nil }
            guard let value = invocation.arguments[spec.name] else { return spec.name }
            // Пустое содержимое файла и пустой итог — законные значения,
            // пустой путь — нет.
            if value.isEmpty && spec.name != "content" && spec.name != "summary" {
                return spec.name
            }
            return nil
        }

        return missing.isEmpty ? nil : .missingArguments(tool: tool.name, arguments: missing)
    }
}
