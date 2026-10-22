//
//  DemoScenario.swift
//  PocketAgent / Demo
//
//  Содержимое демонстрации: папка, переписка и та самая правка, которую агент
//  предлагает применить. Всё лежит в памяти — ни одного обращения к диску, к сети
//  и к движку модели здесь нет и быть не должно.
//
//  ЧТО ПОКАЗЫВАЕМ. Человек просит добавить в начало README короткое описание проекта.
//  Агент делает ровно то, что делает и в бою: сначала читает файл (это шаг без
//  подтверждения), потом предлагает запись и останавливается до нажатия кнопки.
//
//  ⚠️ Тексты, которыми подписаны шаги, НЕ выдуманы заново: они собираются теми же
//  функциями, что и в бою (AgentPrompt.actionTitle, ToolTextFormat.head/humanSize),
//  а дифф строит настоящий DiffBuilder по паре «текст до / текст после».
//  Поэтому на снимке видно ровно то, что человек увидит на своём телефоне.
//

// ⚠️ ВЕСЬ ФАЙЛ — ТОЛЬКО ОТЛАДОЧНАЯ СБОРКА.
// Демонстрационный режим нужен ради снимков экранов на симуляторе, и в сборку
// для магазина ему попадать незачем: там это мёртвый код и выдуманные тексты.
// Конвейер снимков собирает конфигурацию Debug, поэтому съёмке скобки не мешают.
#if DEBUG

import Foundation

enum DemoScenario {

    // MARK: - Папка проекта

    /// Папка, которая как будто уже выбрана. Путь взят типичный для «Файлов» —
    /// папка в iCloud Drive; именно он показывается на экране выбора папки.
    static let folder = ProjectFolder(
        url: URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Проекты/notes-app",
                 isDirectory: true),
        bookmark: Data(),
        displayName: "notes-app",
        adoptedAt: Date(timeIntervalSinceNow: -6 * 24 * 3600)
    )

    /// Сколько «свободно на телефоне» на экране загрузки модели.
    /// Число фиксированное: настоящее свободное место симулятора — это место на
    /// диске сборочной машины, оно скачет от запуска к запуску и может внезапно
    /// показать красную карточку «места может не хватить» прямо на снимке.
    static let freeBytes: Int64 = 18_900_000_000

    /// Про модель рассказываем ПРАВДУ из каталога — те же строки, что и в бою.
    /// Свойство вычисляемое: сборка ModelInfo живёт в композиционном корне,
    /// а он привязан к главному потоку.
    @MainActor
    static var modelInfo: ModelInfo {
        AgentAssembly.modelInfo(for: ModelSpec.descriptor)
    }

    /// Блок «Модель на телефоне» для снимка страницы «О программе».
    /// Цифра — размер файла модели плюс небольшой служебный кэш движка: примерно столько же,
    /// сколько человек увидит на настоящем телефоне. Кнопка удаления в демонстрации
    /// намеренно ничего не делает — файлов здесь нет.
    static var modelStorage: ModelStorageBinding {
        ModelStorageBinding(installedBytes: ModelSpec.expectedBytes + 96 * 1024 * 1024,
                            isDeleting: false,
                            freedBytes: nil,
                            delete: { })
    }

    // MARK: - Файл, который правим

    static let readmePath = "README.md"

    /// Как README выглядит сейчас.
    static let readmeBefore = """
    # notes-app

    ## Установка

    1. Склонируйте репозиторий.
    2. Выполните `npm install`.
    3. Запустите `npm run dev`.

    ## Возможности

    - Заметки хранятся на устройстве, без облака.
    - Поиск по тексту и по тегам.
    - Тёмная тема.
    - TODO: написать описание проекта
    - TODO: приложить скриншоты

    ## Разработка

    Тесты: `npm test`.
    Сборка: `npm run build`.

    ## Лицензия

    MIT

    """

    /// Что предлагает записать агент: две строки описания сразу после заголовка
    /// и оба пункта TODO убраны — они как раз про это описание и просили.
    /// Отсюда на карточке и зелёное, и красное: +3 строки, −2 строки.
    static let readmeAfter = """
    # notes-app

    Блокнот для быстрых заметок: всё хранится прямо на устройстве.
    Ни учётной записи, ни синхронизации — работает и без интернета.

    ## Установка

    1. Склонируйте репозиторий.
    2. Выполните `npm install`.
    3. Запустите `npm run dev`.

    ## Возможности

    - Заметки хранятся на устройстве, без облака.
    - Поиск по тексту и по тегам.
    - Тёмная тема.

    ## Разработка

    Тесты: `npm test`.
    Сборка: `npm run build`.

    ## Лицензия

    MIT

    """

    /// Настоящий построчный дифф, посчитанный боевым DiffBuilder.
    ///
    /// ⚠️ `context: 6` вместо обычных трёх — намеренно. Между добавленным описанием
    /// и убранными пунктами TODO лежит 11 неизменённых строк: при контексте в три
    /// строки они разошлись бы на два отдельных куска, а при шести — склеиваются
    /// в один, и на карточке видно то, ради чего сворачивание вообще сделано:
    /// строку «ещё 11 строк без изменений».
    static let diff: FileDiff = DiffBuilder.build(
        relativePath: readmePath,
        oldText: readmeBefore,
        newText: readmeAfter,
        baseModificationDate: Date(timeIntervalSinceNow: -2 * 3600),
        context: 6
    )

    // MARK: - Шаги агента

    /// Чтение файла — шаг, который в бою выполняется без подтверждения.
    static let readInvocation = ToolInvocation(
        rawName: ToolKind.readFile.rawValue,
        callID: "demo-read-1",
        arguments: ["path": readmePath]
    )

    /// Запись файла — единственный шаг, который ждёт человека.
    static let writeInvocation = ToolInvocation(
        rawName: ToolKind.writeFile.rawValue,
        callID: "demo-write-1",
        arguments: ["path": readmePath, "content": readmeAfter]
    )

    /// Карточка, которая ждёт «Применить» или «Отклонить».
    /// Создаётся ОДИН раз за запуск: у карточки должен быть устойчивый
    /// опознавательный знак, иначе интерфейс считает её новой при каждой перерисовке.
    static let pendingAction = PendingAction(
        invocation: writeInvocation,
        preview: .diff(diff),
        title: AgentPrompt.actionTitle(for: writeInvocation, kind: .writeFile)
    )

    // MARK: - Реплики

    static let userTask = "Добавь в начало README короткое описание проекта — двух предложений хватит."

    /// Подпись шага чтения — той же функцией, что и в бою («Читаю файл README.md»).
    static let readAnnouncement = AgentPrompt.actionTitle(for: readInvocation, kind: .readFile)

    /// Компактный результат чтения — собран ровно так же, как его собирает
    /// настоящий инструмент read_file: сколько строк, сколько весит и начало текста.
    static let readSummary: String = """
    Прочитан \(readmePath) — \(DiffBuilder.splitLines(readmeBefore).count) строк, \
    \(ToolTextFormat.humanSize(readmeBefore.utf8.count))
    \(ToolTextFormat.head(readmeBefore, lines: 5, characters: 300))
    """

    /// Итог применённой записи — тем же текстом, что и настоящий инструмент write_file.
    static let appliedSummary = "Изменён \(readmePath) (+\(diff.addedCount) −\(diff.removedCount))"

    /// Чем агент отчитывается, когда закончил задачу.
    static let finishSummary = "Добавил в начало README.md короткое описание проекта и убрал оба пункта TODO."

    /// Что агент отвечает на «Отклонить».
    static let rejectionReply = "Хорошо, README не трогаю. Скажите, что поправить в описании, — предложу другой вариант."

    // MARK: - Стартовое состояние ленты

    /// Лента и состояние, с которыми открывается рабочий экран.
    ///
    /// Экранов два, и разница между ними только в длине ленты:
    /// • `chat` — вся переписка: задача человека, шаг чтения, его результат и карточка;
    /// • `approval` — оставлена одна задача человека, чтобы карточка правки поместилась
    ///   на экран телефона целиком, вместе с диффом и обеими кнопками.
    static func startingSnapshot(for screen: DemoScreen) -> AgentSnapshot {
        let messages: [ChatMessage]
        switch screen {
        case .approval:
            messages = [ChatMessage(author: .user, text: userTask)]
        // Экраны площадки переписку не показывают вовсе, но лента у них всё равно
        // должна быть непустой: человек попадает на площадку из работающего чата.
        case .chat, .model, .folder, .about,
             .playgroundList, .playgroundScene, .playgroundGame, .playgroundBroken:
            messages = [
                ChatMessage(author: .user, text: userTask),
                ChatMessage(author: .agent, text: readAnnouncement),
                ChatMessage(author: .tool, text: readSummary)
            ]
        }

        // Два шага уже потрачены: чтение файла и предложенная запись.
        return AgentSnapshot(state: .awaitingApproval(pendingAction),
                             messages: messages,
                             stepsUsed: 2,
                             folder: folder)
    }
}

#endif
