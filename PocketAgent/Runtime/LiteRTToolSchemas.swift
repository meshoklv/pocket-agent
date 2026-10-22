//
//  LiteRTToolSchemas.swift
//  PocketAgent / Runtime
//
//  Структуры LiteRTLM.Tool — ТОЛЬКО ради генерации JSON-схемы для модели.
//  Четыре обязательных плюс поиск, который человек включает сам.
//
//  ⚠️ Это НЕ те инструменты, что делают работу. Настоящие живут в Tools/FileToolsImpl.swift.
//  Фреймворк создаёт эти структуры пустым init() и заполняет через JSONDecoder,
//  поэтому передать в них ссылку на выбранную папку невозможно. Но при
//  automaticToolCalling: false метод run() не вызывается НИКОГДА — здесь он есть
//  только потому, что этого требует протокол, и он честно бросает ошибку.
//
//  Имена берутся из ToolKind.rawValue, чтобы не разъехаться с модулем Agent.
//  Имена уже в snake_case, поэтому автоконвертация camelCase→snake_case
//  (включена во фреймворке по умолчанию) их не меняет.
//
//  ⚠️ ФОРМА ЗАПИСИ @ToolParam ЗДЕСЬ ОДНА НА ВСЕ ЧЕТЫРЕ СХЕМЫ — БЕЗ ЗНАЧЕНИЯ ПО УМОЛЧАНИЮ:
//      @ToolParam(description: …) var path: String
//  Обязательный параметр объявляется так, необязательный — через Optional (`String?`).
//
//  ⚠️ ПОЧЕМУ ЭТО ВАЖНО, А НЕ ПРИДИРКА К СТИЛЮ. Обёртка считает параметр обязательным
//  ровно по двум признакам (Vendor/LiteRTLM/Sources/LiteRTLM/Tool.swift, isRequired):
//  тип не Optional И значения по умолчанию не было. Прежняя запись « = "" » давала
//  hasDefaultValue = true, и в JSON-схеме массив required оставался ПУСТЫМ — модели
//  никто не говорил, что путь и содержимое обязательны. Модель на 2 млрд параметров
//  и так теряет аргументы; каждый такой ход — потраченное время и шаг к пределу
//  неверных ходов.
//
//  Пустой init() при этом корректен: у ToolParam есть init(wrappedValue: Value? = nil,
//  description:), то есть значение просто не задано. Метод run() здесь не вызывается
//  никогда (automaticToolCalling: false), а разбор аргументов модели делает наш
//  собственный реестр инструментов — эти структуры нужны ТОЛЬКО для getSchema().
//
//  Тексты описаний берутся из ToolTexts (Contracts.swift) — тот же самый текст уходит
//  в реализации инструментов, поэтому модель и наши проверки читают одно и то же.
//
//  💰 СКОЛЬКО ЭТО СТОИТ. Замер 09.08.2026: собран ровно тот JSON, который отдаёт модели
//  ToolManager (Vendor/LiteRTLM), и посчитан алгоритмом приложения (estimateTokens).
//  Четыре действия — 385 токенов, с включённым поиском — 452 (до сокращения текстов
//  было 518 и 595). Из этих 385 сами описания занимают 143, а 242 — обвязка схемы:
//  "type", "nullable", "required", имена полей и скобки. Обвязку урезать нельзя,
//  её формат разбирает библиотека Google; дешеветь может только содержимое описаний.
//  Поэтому здесь всё правило одно: каждое лишнее слово оплачивается КАЖДЫЙ ход,
//  а при сворачивании разговора — заново.
//
//  ⚠️ ПУСТОЕ ОПИСАНИЕ — ЭТО ТОЖЕ РЕШЕНИЕ, А НЕ ЗАБЫТОЕ ПОЛЕ. Обёртка (ToolParam.
//  getFullSchema) кладёт ключ "description" в схему, только если строка непустая.
//  Значит пустой текст в ToolTexts убирает из схемы и сам ключ — это дешевле всего.
//  Само поле при этом в схеме ОСТАЁТСЯ, и модель по-прежнему может его назвать.
//

import Foundation
import LiteRTLM

// MARK: - list_files

struct LiteRTListFilesTool: Tool {
    static let name = ToolKind.listFiles.rawValue
    static let description = ToolTexts.listFiles

    /// ⚠️ Единственный НЕОБЯЗАТЕЛЬНЫЙ параметр во всех четырёх схемах: без пути
    /// список берётся от корня проекта. Optional — это и есть способ сказать обёртке
    /// «не клади его в required».
    @ToolParam(description: ToolTexts.listFilesPath)
    var path: String?

    // TODO(API): проверить на сборке, что явный init() не мешает синтезу Decodable.
    // Он нужен потому, что протокол Tool требует ровно init() без аргументов.
    init() {}

    func run() async throws -> Any {
        throw PocketAgentError.unknownTool(Self.name)
    }
}

// MARK: - read_file

struct LiteRTReadFileTool: Tool {
    static let name = ToolKind.readFile.rawValue
    static let description = ToolTexts.readFile

    @ToolParam(description: ToolTexts.readFilePath)
    var path: String

    /// ⚠️ БЕЗ ЭТИХ ДВУХ ПОЛЕЙ В СХЕМЕ ЧТЕНИЕ СТРАНИЦАМИ НЕ РАБОТАЕТ ВООБЩЕ.
    /// Модель видит ровно ту схему, которую собирает отсюда фреймворк, — тексты в
    /// описаниях и в системной инструкции ей не помогут назвать поле, которого в схеме
    /// нет. А при ограниченной выдаче (движок держит ответ в рамках схемы) она его
    /// и физически не выпишет. Ровно так уже было с экраном выбора моделей: код готов,
    /// а мост не подключён — и работа мертва.
    ///
    /// ⚠️ И ровно поэтому поля остались, а их ОПИСАНИЯ с 09.08.2026 пустые (ToolTexts.
    /// readFileFromLine/readFileToLine = ""). Поле в схеме — обязательно, слова про
    /// него — нет: имя и целый тип говорят то же самое, номера строк модель видит
    /// в ответе чтения, а ошибка здесь стоит лишь чтения с начала файла.
    @ToolParam(description: ToolTexts.readFileFromLine)
    var fromLine: Int?

    @ToolParam(description: ToolTexts.readFileToLine)
    var toLine: Int?

    init() {}

    func run() async throws -> Any {
        throw PocketAgentError.unknownTool(Self.name)
    }
}

// MARK: - write_file

struct LiteRTWriteFileTool: Tool {
    static let name = ToolKind.writeFile.rawValue
    static let description = ToolTexts.writeFile

    @ToolParam(description: ToolTexts.writeFilePath)
    var path: String

    @ToolParam(description: ToolTexts.writeFileContent)
    var content: String

    /// Те же два поля, что и у чтения, и намеренно с теми же именами: номера строк
    /// приходят к модели в ответе чтения и этими же номерами возвращаются в правку.
    /// Необязательные — без них content по-прежнему означает весь файл целиком.
    ///
    /// ⚠️ А вот описания здесь, в отличие от чтения, ОСТАВЛЕНЫ. Пропуск поля у чтения
    /// значит «с начала файла» — не страшно; пропуск здесь значит «переписать файл
    /// целиком». Про такую цену умолчания модель обязана быть предупреждена, и эти
    /// два коротких предложения — самая дешёвая страховка во всей схеме.
    @ToolParam(description: ToolTexts.writeFileFromLine)
    var fromLine: Int?

    @ToolParam(description: ToolTexts.writeFileToLine)
    var toLine: Int?

    init() {}

    func run() async throws -> Any {
        throw PocketAgentError.unknownTool(Self.name)
    }
}

// MARK: - finish

struct LiteRTFinishTool: Tool {
    static let name = ToolKind.finish.rawValue
    static let description = ToolTexts.finish

    @ToolParam(description: ToolTexts.finishSummary)
    var summary: String

    init() {}

    func run() async throws -> Any {
        throw PocketAgentError.unknownTool(Self.name)
    }
}

// MARK: - web_search

/// ⚠️ ЭТА СХЕМА УХОДИТ МОДЕЛИ НЕ ВСЕГДА, И В ЭТОМ ВЕСЬ СМЫСЛ.
/// Схемы собираются по объявлениям, которые прислал реестр (`tools(matching:)`),
/// а поиск попадает в реестр только когда человек его включил. Выключен —
/// этой схемы модель не видит, и действий у неё снова четыре.
///
/// Поле ровно одно: чем короче схема, тем реже маленькая модель теряет параметр.
struct LiteRTWebSearchTool: Tool {
    static let name = ToolKind.webSearch.rawValue
    static let description = ToolTexts.webSearch

    @ToolParam(description: ToolTexts.webSearchQuery)
    var query: String

    init() {}

    func run() async throws -> Any {
        throw PocketAgentError.unknownTool(Self.name)
    }
}

// MARK: - Набор схем

enum LiteRTToolSchemas {

    /// Схемы четырёх обязательных действий.
    ///
    /// ⚠️ Поиска здесь НЕТ намеренно. Это запасной набор «на случай, если объявлений
    /// не прислали», и молча выпустить модель в интернет он права не имеет:
    /// разрешение даёт человек переключателем, а не запасная ветка кода.
    static var all: [any Tool] {
        [LiteRTListFilesTool(), LiteRTReadFileTool(), LiteRTWriteFileTool(), LiteRTFinishTool()]
    }

    /// Соответствие «вид инструмента → схема».
    static func schema(for kind: ToolKind) -> any Tool {
        switch kind {
        case .listFiles: return LiteRTListFilesTool()
        case .readFile:  return LiteRTReadFileTool()
        case .writeFile: return LiteRTWriteFileTool()
        case .finish:    return LiteRTFinishTool()
        case .webSearch: return LiteRTWebSearchTool()
        }
    }

    /// Отдаём модели ровно те инструменты, которые объявил модуль Agent.
    /// Неизвестное имя молча пропускаем — лучше меньше инструментов, чем схема,
    /// под которую в приложении нет исполнителя.
    ///
    /// ⚠️⚠️ ПУСТОЙ СПИСОК ОЗНАЧАЕТ «НИ ОДНОГО ДЕЙСТВИЯ», А НЕ «ВСЕ». Раньше здесь стояло
    /// `guard !declarations.isEmpty else { return all }` — запасной набор на случай
    /// неправильно собранного реестра. С кнопкой «Инструменты» в чате пустой список стал
    /// законным и означает ровно обратное: человек выключил действия, и модели не должно
    /// уйти ни одного описания (это те самые 385 токенов). Оставь мы запасной набор —
    /// разговорный режим молча отправлял бы модели все четыре действия, то есть не работал
    /// бы вовсе, а проверить это по экрану невозможно.
    /// Реестр от ошибки сборки защищён своей проверкой — `ToolRegistry.isComplete`.
    static func tools(matching declarations: [ToolDeclaration]) -> [any Tool] {
        return declarations.compactMap { declaration in
            guard let kind = ToolKind(rawValue: declaration.name) else { return nil }
            return schema(for: kind)
        }
    }

    /// Тексты описаний и здесь, и в реализациях инструментов берутся из ToolTexts,
    /// поэтому разойтись они больше не могут. Проверка оставлена как сторож:
    /// если кто-то снова впишет текст руками, в отладочной сборке это сразу видно.
    static func warnIfOutOfSync(with declarations: [ToolDeclaration]) {
        #if DEBUG
        for declaration in declarations {
            guard let kind = ToolKind(rawValue: declaration.name) else {
                print("[LiteRTToolSchemas] Инструмент «\(declaration.name)» модели не отдаётся: нет схемы.")
                continue
            }
            let schemaDetails: String
            switch kind {
            case .listFiles: schemaDetails = LiteRTListFilesTool.description
            case .readFile:  schemaDetails = LiteRTReadFileTool.description
            case .writeFile: schemaDetails = LiteRTWriteFileTool.description
            case .finish:    schemaDetails = LiteRTFinishTool.description
            case .webSearch: schemaDetails = LiteRTWebSearchTool.description
            }
            if schemaDetails != declaration.details {
                print("[LiteRTToolSchemas] Описание «\(declaration.name)» разошлось со схемой для модели.")
            }
        }
        #endif
    }
}
