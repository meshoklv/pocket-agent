//
//  DemoEnvironment.swift
//  PocketAgent / Demo
//
//  Два заглушённых источника, без которых корневой экран не пустит дальше подготовки:
//  движок модели и владелец папки проекта.
//
//  DemoRuntime говорит «модель готова» (или «качаю 46 %», если снимаем экран загрузки)
//  и не трогает ни файл модели, ни сеть. DemoFolderStore говорит «папка уже выбрана»
//  и не трогает ни закладок, ни файловой системы.
//
//  Оба типа реализуют те же протоколы из Contracts.swift, что и боевые LiteRTModelRuntime
//  и ProjectRoot, поэтому подмена происходит целиком в сборке демонстрации,
//  а экраны и AppViewModel остаются нетронутыми.
//

// ⚠️ ВЕСЬ ФАЙЛ — ТОЛЬКО ОТЛАДОЧНАЯ СБОРКА.
// Демонстрационный режим нужен ради снимков экранов на симуляторе, и в сборку
// для магазина ему попадать незачем: там это мёртвый код и выдуманные тексты.
// Конвейер снимков собирает конфигурацию Debug, поэтому съёмке скобки не мешают.
#if DEBUG

import Foundation

// MARK: - Движок модели

/// Движок, которого нет: отдаёт одно и то же состояние и молчит на все просьбы.
///
/// ⚠️ Класс намеренно неизменяемый — единственное хранимое свойство объявлено `let`.
/// Так он честно безопасен для передачи между потоками, и никакой блокировки не нужно.
final class DemoRuntime: ModelRuntime {

    private let status: ModelRuntimeStatus

    init(status: ModelRuntimeStatus) {
        self.status = status
    }

    func currentStatus() async -> ModelRuntimeStatus { status }

    /// Одно значение и конец потока: состояние в демонстрации не меняется.
    func statusStream() async -> AsyncStream<ModelRuntimeStatus> {
        let value = status
        return AsyncStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }

    /// Ничего не качаем и не загружаем — состояние остаётся тем же.
    func prepare() async throws {}

    func beginSession(systemPrompt: String, tools: [ToolDeclaration]) async throws {}

    /// В демонстрации ходы делает DemoAgent, до движка дело не доходит вообще.
    func send(userText: String) async throws -> ModelTurn { .text("") }
    func send(toolResult: ToolResult) async throws -> ModelTurn { .text("") }

    func cancelTurn() async {}
    func endSession() async {}
    func unload() async {}
    func usedTokens() async -> Int? { nil }
}

// MARK: - Папка проекта

/// Папка, которая «уже выбрана». Ни закладок, ни доступа к файлам.
@MainActor
final class DemoFolderStore: ProjectFolderStore {

    private(set) var current: ProjectFolder?

    init(folder: ProjectFolder?) {
        self.current = folder
    }

    /// Если на снимке кто-то всё же откроет системное окно выбора и что-то выберет —
    /// просто запоминаем выбранное, ничего не открывая.
    @discardableResult
    func adopt(pickedURL: URL) throws -> ProjectFolder {
        let folder = ProjectFolder(url: pickedURL,
                                   bookmark: Data(),
                                   displayName: pickedURL.lastPathComponent)
        current = folder
        return folder
    }

    @discardableResult
    func restore() -> ProjectFolder? { current }

    @discardableResult
    func resumeAccess() -> FolderResume {
        guard let current else { return .lost }
        return .same(current)
    }

    func release() {}

    func forget() { current = nil }

    /// Сюда попасть нельзя: сессию агента в демонстрации собирает DemoAgent,
    /// и рабочая папка ему не нужна. Если вызов всё же случился — это ошибка сборки
    /// демонстрации, и молчать о ней нельзя.
    func makeWorkspace() throws -> any FileWorkspace {
        throw PocketAgentError.noProjectFolder
    }
}

#endif
