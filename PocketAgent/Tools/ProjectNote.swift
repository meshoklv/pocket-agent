//
//  ProjectNote.swift
//  PocketAgent
//
//  Заметка о проекте — файл AGENTS.md в корне выбранной папки. Помощник перечитывает
//  её перед каждой задачей и получает знание о проекте, не тратя на это ходы.
//
//  ⚠️ ЗАЧЕМ ЭТОТ ФАЙЛ ВООБЩЕ ПОЯВИЛСЯ. Чтение заметки в приложении было с самого начала
//  (AgentEngine.refreshProjectNote), но человеку про неё НИГДЕ не говорили. То есть
//  завести её мог только тот, кто читал наш код, — а значит, никто. Здесь лежит вторая
//  половина дела: показать заметку человеку и дать её написать.
//
//  ⚠️ ЗАПИСЬ ЗДЕСЬ НЕ БЫВАЕТ МОЛЧАЛИВОЙ. `plan` только считает дифф и ничего не трогает,
//  `save` вызывается ровно из одного места — кнопки «Применить» на карточке подтверждения
//  (UI/ProjectNoteSheet.swift). Ровно тот же порядок, что и у записи файла моделью,
//  и у переноса файла человеком (Tools/FileDropbox.swift).
//
//  ⚠️ СВОЕЙ ДВЕРИ К ДИСКУ ТУТ НЕТ. Вся работа идёт через `SecurityScopedWorkspace` —
//  тот самый рабочий стол, которым пользуются четыре инструмента модели. Значит и
//  проверка пути, и запрет служебных папок, и сверка «файл изменился снаружи» здесь
//  ровно те же. Заводить рядом второй путь к файлам было бы опаснее любой экономии.
//

import Foundation

/// Что сейчас лежит в заметке о проекте.
///
/// Три состояния вместо `String?` нарочно: «заметки нет» и «заметка есть, но открыть
/// её здесь нельзя» — разные новости для человека, и молчать про вторую нечестно.
public enum ProjectNoteState: Sendable, Equatable {
    /// Файла нет — заметку можно создать.
    case missing
    /// Текст заметки (может быть пустым, если файл пуст).
    case text(String)
    /// Файл есть, но открыть его здесь нельзя — причина по-русски.
    case unreadable(String)
}

public enum ProjectNote {

    /// Имя файла берём у промпта, а не переписываем строкой: два имени разъехались бы
    /// при первой же правке, и приложение стало бы показывать не тот файл, который читает.
    public static var fileName: String { AgentPrompt.projectNoteFileName }

    /// Заготовка для первой заметки.
    ///
    /// ⚠️ Нарочно короткая. Заметка целиком уходит модели в системную инструкцию и стоит
    /// до 300 токенов из 4096 — это десятая часть всей её памяти. Длинная «красивая»
    /// заготовка съела бы место, ради которого заметка и заводится.
    public static let template = """
    # О проекте

    Что это:

    Как устроено:

    Чего не трогать:
    """

    // MARK: - Прочитать

    /// Что лежит в заметке прямо сейчас. Ничего не меняет.
    /// ⚠️ Работа с диском: звать вне главного потока (файл может лежать в iCloud).
    public static func read(root: URL) -> ProjectNoteState {
        guard let url = try? SafePath.resolveForReading(fileName, root: root) else {
            return .missing
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard CoordinatedFileIO.isRegularFile(url) else {
            return .unreadable("это не обычный файл")
        }
        // Тот же предел, что и у диффа: больше этого файл не читается и не правится
        // нигде в приложении.
        let size = CoordinatedFileIO.byteSize(of: url) ?? 0
        guard size <= AgentLimits.maxFileBytes else {
            return .unreadable("заметка больше \(AgentLimits.maxFileBytes / 1024) КБ")
        }
        guard let data = try? CoordinatedFileIO.readData(at: url, limit: AgentLimits.maxFileBytes) else {
            return .unreadable("файл не прочитался")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unreadable("файл не читается как текст")
        }
        return .text(text)
    }

    // MARK: - Посмотреть, что изменится

    /// Дифф «было → станет». Диска не касается ничем, кроме чтения.
    /// ⚠️ Работа с диском: звать вне главного потока.
    public static func plan(text: String, root: URL) throws -> FileDiff {
        try SecurityScopedWorkspace(root: root).diff(relativePath: fileName, newText: text)
    }

    // MARK: - Записать (только по нажатию человека)

    /// Записать ровно тот текст, который человеку показали диффом.
    ///
    /// ⚠️ Условия записи берутся ИЗ САМОГО ДИФФА (`writeExpectation`): пока человек читал
    /// карточку, файл мог поменять другой редактор или Working Copy. Тогда запись честно
    /// не состоится — вместо тихой затирки чужой правки.
    /// ⚠️ Работа с диском: звать вне главного потока.
    public static func save(_ diff: FileDiff, root: URL) throws {
        try SecurityScopedWorkspace(root: root).write(relativePath: diff.relativePath,
                                                      newText: diff.newText,
                                                      expecting: diff.writeExpectation)
    }
}
