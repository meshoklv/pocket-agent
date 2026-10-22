//
//  EngineDiagnostics.swift
//  PocketAgent / Runtime
//
//  Журнал для разбора поломок: кольцевой буфер событий, метки времени, шапка со сборкой
//  и действующими настройками, ограничение длины строки и короткий дубль в системный
//  лог телефона.
//
//  ЗАЧЕМ ЭТОТ ФАЙЛ ПОЯВИЛСЯ. 09.08.2026 у владельца выбранный размер памяти разговора
//  вернулся с 32 000 на 4 096, и по журналу НЕ УДАЛОСЬ объяснить, кто это сделал: в строках
//  не было ни пары «попросили → дали», ни причины отступления, ни места в коде, откуда его
//  позвали, ни настроек, действовавших в тот момент. Разбирать такое без телефона в руках
//  нечем. Здесь собрано всё, чего не хватило.
//
//  ⚠️ ГЛАВНОЕ ПРАВИЛО УСТРОЙСТВА: ОДНО СОБЫТИЕ — ОДНА СТРОКА В МЕСТЕ ВЫЗОВА.
//  Движок (LiteRTRuntime) правится отдельно и другим человеком, поэтому здесь нет ничего,
//  что требовало бы заводить в нём переменные, свойства или помощники. Всё, что нужно
//  событию, — либо приходит параметрами, либо считается тут. Время операций тоже: журнал
//  сам держит именованные секундомеры (`startStage`), и в движке это одна строка на старте.
//
//  ⚠️ 09.08.2026 — ПОЛНОТА ЖУРНАЛА ВКЛЮЧЕНА ПО ПРЯМОМУ РЕШЕНИЮ ВЛАДЕЛЬЦА, И ЭТО НЕ ОГОВОРКА.
//  Раньше здесь стоял фильтр приватности: он вырезал из журнала пути, текст задачи, ответы
//  модели и содержимое файлов — «на всякий случай», потому что журнал целиком уходит в буфер
//  обмена кнопкой «Скопировать всё». Из-за этого разбор упирался в стену: жалоба «модель
//  ответила неразборчиво» была в журнале и оставалась без единой подробности, ЧТО именно
//  она ответила. Владелец решил иначе — прямо и явно: продукт закрытый, приложение личное,
//  без этих данных поломку не разобрать. Значит журнал должен нести их, а не прятать.
//  Единственное, что здесь осталось от прежнего фильтра, — `EngineJournalGuard`: он больше
//  НИЧЕГО не прячет, а только режет СЛИШКОМ длинную строку и всегда честно говорит,
//  сколько срезано, — иначе один длинный ответ модели или содержимое большого файла
//  раздули бы журнал в нечитаемый ком.
//
//  ⚠️ ЖУРНАЛ НЕ ДОЛЖЕН СТОИТЬ ПАМЯТИ И ВРЕМЕНИ. Хранилище — кольцевой буфер RuntimeJournal
//  (последние `capacity` событий, только в памяти). Пишем СОБЫТИЯМИ, а не токенами: один ход
//  модели — одна строка. Длина каждой строки ограничена `EngineJournalGuard.limit`, иначе
//  разбор ответа модели или содержимого файла на несколько килобайт раздул бы журнал в разы.
//
//  ⚠️ ДУБЛЬ В СИСТЕМНЫЙ ЛОГ iOS — КОРОЧЕ, ЧЕМ САМ ЖУРНАЛ, И ЭТО ОСОЗНАННОЕ РЕШЕНИЕ, А НЕ
//  ПОЛОВИНЧАТОСТЬ. Каждое событие уходит ещё и в `Logger` (os_log) уровнем `notice` — этот
//  уровень система кладёт на диск, и журнал снимается с телефона проводом (Console.app или
//  `log collect`) БЕЗ УЧАСТИЯ владельца и без нажатой им кнопки «Скопировать всё» — снять
//  его может кто угодно, у кого на компьютере есть доступ к телефону. Полный текст задачи,
//  ответа модели и куска файла в системный лог поэтому НЕ идёт — туда пишется короткая
//  версия строки (`systemLogLimit`), а целиком то же событие остаётся только в журнале
//  приложения: он живёт лишь в памяти процесса и уходит наружу только явным нажатием.
//  Строки помечены `privacy: .public` намеренно: без пометки система пишет «<private>»,
//  и снятый лог оказался бы пустым.
//

import Foundation
import os

// MARK: - Ограничитель длины строки

/// Единственное, что теперь стоит между событием и журналом: не прячет содержимое,
/// а только не даёт одной длинной строке раздуть журнал в нечитаемый ком.
///
/// ⚠️ ДО 09.08.2026 ЗДЕСЬ БЫЛ ФИЛЬТР ПРИВАТНОСТИ (назывался `EnginePrivacy`): резал любую
/// строку длиннее 600 знаков и вдобавок вырезал всё похожее на путь внутри папки человека.
/// По прямому решению владельца (продукт закрытый, личный, без полноты журнала поломку
/// не разобрать) фильтр снят целиком: путь файла, номера строк, текст задачи, ответ
/// модели и содержимое прочитанного куска файла теперь идут в журнал как есть.
/// Осталась только защита от нечитаемости — вот она.
public enum EngineJournalGuard {

    /// Сколько знаков оставляем от одной строки журнала приложения.
    ///
    /// ⚠️ Было 600 — хватало на текст ошибки библиотеки, но НЕ хватало ни на страницу
    /// файла (страница — от 700 токенов, это 1,4–2,8 КБ; на большой памяти разговора
    /// она в разы больше, см. `AgentLimits.readPageTokens(forCeiling:)`),
    /// ни тем более на полный ответ модели или записываемое содержимое файла. 4000 знаков
    /// берёт с запасом самую длинную обычную страницу и оставляет разбор читаемым; события
    /// длиннее (например, запись целого большого файла) режутся явно, а не молча —
    /// см. `limited(_:)`.
    public static let limit = 4000

    /// Обрезает строку, если она длиннее лимита, и ЯВНО говорит, сколько срезано —
    /// а не молчит и не подсовывает многоточие без цифр.
    public static func limited(_ text: String) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
            + "\n… показаны первые \(limit) знаков из \(text.count) (обрезано)"
    }
}

// MARK: - Секундомер

/// Сколько заняла операция.
///
/// ⚠️ Ради этого и заведён: ход, посчитанный за 0,00 с, однажды доказал, что модель
/// не считала вовсе, а разговор был мёртв. Без замера это выглядело как «ответила пусто».
public struct EngineClock {

    private let startedAt = Date()

    public init() {}

    public var seconds: Double { Date().timeIntervalSince(startedAt) }

    public var text: String { EngineClock.text(seconds) }

    /// «0,00 с», «2,4 с», «14 с» — с запятой, как везде в приложении.
    /// ⚠️ Считаем сами, без системного форматировщика: тот берёт разделитель из настроек
    /// телефона и на англоязычном устройстве написал бы «0.00» — та же беда, из-за которой
    /// в проекте заведён `HumanFormat`.
    public static func text(_ seconds: Double) -> String {
        let value: String
        if seconds < 10 {
            value = String(format: "%.2f", seconds)
        } else if seconds < 100 {
            value = String(format: "%.1f", seconds)
        } else {
            value = String(format: "%.0f", seconds)
        }
        return value.replacingOccurrences(of: ".", with: ",") + " с"
    }
}

/// Что именно мы засекаем. Имя нужно, чтобы одновременно шли несколько замеров:
/// вся подготовка идёт дольше, чем каждая отдельная попытка внутри неё.
public enum EngineStage: String, Sendable {
    /// Вся подготовка модели: от проверки файла до готовности.
    case prepare
    /// Одна попытка создать движок (видеочип или процессор).
    case engineAttempt
    /// Один ход разговора.
    case turn
    /// Одна ступенька перебора настроек.
    case ladderStep
}

// MARK: - Журнал

/// Воронка, через которую движок пишет события.
///
/// ⚠️ ИМЕНА ТРЁХ МЕТОДОВ (`record`, `recordFailure`, `noteGarbledAnswer`) НАМЕРЕННО СОВПАДАЮТ
/// С `RuntimeJournal`. Это сделано ради одной строки: в LiteRTRuntime.swift есть свойство
/// `private var journal: RuntimeJournal { RuntimeJournal.shared }` — заменив в нём один тип
/// на `EngineJournal`, все прежние события файла разом получают фильтр приватности,
/// ограничение длины и дубль в системный лог. Ни одно место вызова при этом не меняется.
public final class EngineJournal: @unchecked Sendable {

    public static let shared = EngineJournal()

    /// Куда дублируем. Категория одна: снимать лог удобнее одним фильтром
    /// `log stream --predicate 'subsystem == "pocket-agent"'`.
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "pocket-agent",
                             category: "engine")

    /// Начала засечённых операций. Замок — потому что журнал зовут и из актора движка,
    /// и с главного потока.
    private let lock = NSLock()
    private var stageStarts: [EngineStage: Date] = [:]

    public init() {}

    // MARK: Основа — совместимость с RuntimeJournal

    public func record(_ kind: RuntimeEventKind, _ text: String, detail: String? = nil) {
        let safeText = EngineJournalGuard.limited(text)
        let safeDetail = detail.map(EngineJournalGuard.limited)
        RuntimeJournal.shared.record(kind, safeText, detail: safeDetail)
        mirror(kind: kind, text: safeText, detail: safeDetail)
    }

    public func recordFailure(stage: String, human: String, technical: String) {
        let safeHuman = EngineJournalGuard.limited(human)
        let safeTechnical = EngineJournalGuard.limited(technical)
        RuntimeJournal.shared.recordFailure(stage: EngineJournalGuard.limited(stage),
                                            human: safeHuman,
                                            technical: safeTechnical)
        // ⚠️ В системный лог — короткая версия, см. `systemLogText` и объяснение в шапке
        // файла: полный текст остаётся только в журнале приложения.
        //
        // ⚠️ СТРОКА СОБИРАЕТСЯ ЗАРАНЕЕ, А НЕ СКЛЕИВАЕТСЯ ПЛЮСОМ ПРЯМО В ВЫЗОВЕ.
        // Аргумент os_log — не обычная строка, а особая заготовка с подстановками,
        // и склеить две такие заготовки нельзя: сборка падает. Поэтому текст готовим
        // сами и подставляем ОДНИМ куском.
        let line = "[Ошибка · \(stage)] \(Self.systemLogText(safeHuman))"
                 + " — \(Self.systemLogText(safeTechnical))"
        log.error("\(line, privacy: .public)")
    }

    public func noteGarbledAnswer() {
        RuntimeJournal.shared.noteGarbledAnswer()
    }

    /// Уровень `notice` выбран намеренно: он единственный из дешёвых, который система
    /// сохраняет на диск, — значит лог можно снять с телефона ПОСЛЕ поломки, а не только
    /// смотреть вживую. `error` оставлен ошибкам, чтобы их было видно фильтром.
    ///
    /// ⚠️ ЗДЕСЬ, А НЕ В `record()`, ОБРЕЗАЕМ ОТДЕЛЬНО ДЛЯ СИСТЕМНОГО ЛОГА — см. объяснение
    /// в шапке файла. `record()` кладёт в `RuntimeJournal` (и в буфер обмена по кнопке)
    /// текст ДО 4000 знаков, а в os_log из него уходит короткая версия: системный лог
    /// снимается с телефона проводом кем угодно с доступом к компьютеру, а не только
    /// владельцем по его собственному нажатию «Скопировать всё».
    private func mirror(kind: RuntimeEventKind, text: String, detail: String?) {
        let line = detail.map { "\(text) — \($0)" } ?? text
        let short = Self.systemLogText(line)
        if kind == .failure {
            log.error("[\(kind.title, privacy: .public)] \(short, privacy: .public)")
        } else {
            log.notice("[\(kind.title, privacy: .public)] \(short, privacy: .public)")
        }
    }

    /// Сколько знаков уходит в системный лог телефона — заметно короче, чем в журнал
    /// приложения (`EngineJournalGuard.limit`), и это осознанно: полный текст задачи,
    /// ответа модели и куска файла системному логу не нужен, там важно только
    /// ЧТО произошло, а разбор по существу — в самом журнале приложения.
    private static let systemLogLimit = 300

    private static func systemLogText(_ text: String) -> String {
        guard text.count > systemLogLimit else { return text }
        return String(text.prefix(systemLogLimit)) + "… (полностью — в журнале приложения)"
    }

    // MARK: Секундомеры

    /// Засечь начало операции. Единственная строка в движке, которая сама ничего не пишет
    /// в журнал: время появится в строке о результате.
    public func startStage(_ stage: EngineStage) {
        lock.lock()
        stageStarts[stage] = Date()
        lock.unlock()
    }

    /// Сколько прошло с засечки. Засечки не было — «время неизвестно»: выдумывать ноль
    /// нельзя, ровно нулевое время само по себе является уликой.
    private func elapsedText(_ stage: EngineStage) -> String {
        lock.lock()
        let started = stageStarts[stage]
        lock.unlock()
        guard let started else { return "время неизвестно" }
        return EngineClock.text(Date().timeIntervalSince(started))
    }

    // MARK: Подъём модели

    /// Одна попытка создать движок. Заодно засекает время этой попытки.
    ///
    /// ⚠️ ПАРА «ПОПРОСИЛИ — ВЫБРАНО ЧЕЛОВЕКОМ» ЗДЕСЬ ОБЯЗАТЕЛЬНА. Это разные числа:
    /// на ступеньке «размер из самой модели» мы не просим НИЧЕГО, а на странице «О программе»
    /// у человека при этом написано его число. Ровно из этого расхождения выросла жалоба
    /// «поставил 32 000, получаю 4 096».
    public func noteLoadAttempt(fileName: String,
                                fileSizeText: String,
                                backend: String,
                                askedTokens: Int?,
                                chosenTokens: Int,
                                freeMemoryMB: Int,
                                needMemoryMB: Int,
                                stepNumber: Int,
                                stepName: String,
                                executors: Bool) {
        startStage(.engineAttempt)
        record(.backend, "Пробую поднять модель на \(backend)",
               detail: "файл: \(fileName) · размер: \(fileSizeText) · "
                     + "ступенька: \(Self.stepText(stepNumber, stepName)) · "
                     + "прошу память разговора: \(Self.tokensText(askedTokens)) · "
                     + "выбор человека: \(ContextSizeSettings.text(chosenTokens)) · "
                     + "свободно: \(Self.memoryText(freeMemoryMB)) · нужно: \(needMemoryMB) МБ · "
                     + "картинки и звук: \(executors ? "да" : "нет")")
    }

    /// Движок поднялся. Пара «просил — дали» здесь главная: её расхождение и означает,
    /// что выбор человека кто-то отменил по дороге.
    public func noteLoadResult(backend: String,
                               askedTokens: Int?,
                               grantedTokens: Int,
                               chosenTokens: Int,
                               freeMemoryMB: Int) {
        let mismatch = grantedTokens < chosenTokens
        record(.backend, "Модель считает на \(backend)",
               detail: "просил: \(Self.tokensText(askedTokens)) · "
                     + "дали: \(ContextSizeSettings.text(grantedTokens)) · "
                     + "выбор человека: \(ContextSizeSettings.text(chosenTokens))"
                     + (mismatch ? " ⚠️ выбор человека сейчас НЕ действует" : "") + " · "
                     + "свободно после загрузки: \(Self.memoryText(freeMemoryMB)) · "
                     + "попытка заняла: \(elapsedText(.engineAttempt))")
    }

    /// Попытка не удалась. Числа повторяются намеренно: строка неудачи должна читаться
    /// сама по себе, без поиска строки выше.
    public func noteLoadFailed(backend: String,
                               askedTokens: Int?,
                               freeMemoryMB: Int,
                               error: Error) {
        record(.failure, "Поднять модель на \(backend) не удалось",
               detail: "попытка заняла: \(elapsedText(.engineAttempt)) · "
                     + "просил память разговора: \(Self.tokensText(askedTokens)) · "
                     + "свободно: \(Self.memoryText(freeMemoryMB)) · "
                     + RuntimeJournal.technicalText(for: error))
    }

    /// Модель готова. Итоговая строка всей подготовки.
    public func noteReady(modelName: String,
                          fileName: String,
                          fileSizeText: String,
                          backend: String,
                          askedTokens: Int?,
                          grantedTokens: Int,
                          chosenTokens: Int,
                          stepNumber: Int,
                          stepName: String,
                          freeMemoryMB: Int) {
        record(.engine, "Модель загружена и готова",
               detail: "модель: \(modelName) · файл: \(fileName) · размер: \(fileSizeText) · "
                     + "расчёт: \(backend) · ступенька: \(Self.stepText(stepNumber, stepName)) · "
                     + "просили памяти разговора: \(Self.tokensText(askedTokens)) · "
                     + "дали: \(ContextSizeSettings.text(grantedTokens)) · "
                     + "выбор человека: \(ContextSizeSettings.text(chosenTokens)) · "
                     + "свободно: \(Self.memoryText(freeMemoryMB)) · "
                     + "вся подготовка заняла: \(elapsedText(.prepare))")
    }

    // MARK: Перебор настроек

    /// Откуда взялась ступенька, с которой поднимаем модель.
    public enum StepOrigin: String, Sendable {
        /// Обычный запуск, ничего не подбирали.
        case fresh
        /// Взята из памяти: на ней эта модель однажды ответила.
        case remembered
        /// Мы прямо сейчас идём по лесенке и пробуем её.
        case climbing

        var text: String {
            switch self {
            case .fresh:      return "обычная, ничего не подбирали"
            case .remembered: return "запомнена: на ней эта модель уже отвечала"
            case .climbing:   return "проба на перебор настроек"
            }
        }
    }

    /// Какая ступенька взята, откуда она взялась и что именно поменяла.
    ///
    /// ⚠️ ГЛАВНОЕ ЗДЕСЬ — ПОСЛЕДНЯЯ СТРОКА ПРО ВЫБОР ЧЕЛОВЕКА. Ступеньки накопительные,
    /// и начиная с «размер памяти разговора — из самой модели» размер не задаётся ВООБЩЕ:
    /// движок отдаёт свои 4 096, а на странице «О программе» у человека по-прежнему написано
    /// его число. Ровно так родилась жалоба «поставил 32 000, а получаю 4 096». Ступенька,
    /// которая молча отменяет выбор, обязана называть это вслух.
    ///
    /// - Parameters:
    ///   - askedTokens: что эта ступенька просит у движка. nil — не просит ничего.
    ///   - toolsOn: отдаём ли модели список действий. Выключены — агент умеет только
    ///     разговаривать, и это половина приложения.
    ///   - memoryKey: под каким ключом эта модель помнит свои ступеньки. Нужен потому,
    ///     что в ключ входят и размер памяти разговора, и номер сборки: без него
    ///     из журнала не понять, почему запомненный опыт вдруг перестал применяться
    ///     (или, наоборот, применился к другому размеру).
    public func noteLadderStep(number: Int,
                               name: String,
                               origin: StepOrigin,
                               askedTokens: Int?,
                               toolsOn: Bool,
                               chosenTokens: Int,
                               memoryKey: String) {
        var detail = "откуда: \(origin.text) · что поменяно: \(name) · "
                   + "действия модели: \(toolsOn ? "есть" : "ОТКЛЮЧЕНЫ ⚠️") · "
                   + "просит памяти разговора: \(Self.tokensText(askedTokens)) · "
                   + "выбор человека: \(ContextSizeSettings.text(chosenTokens)) · "
                   + "ключ памяти: \(memoryKey)"
        if askedTokens == nil, chosenTokens > AgentLimits.contextTokenBudget {
            detail += " · ⚠️ выбранные человеком \(ContextSizeSettings.text(chosenTokens)) "
                    + "на этой ступеньке НЕ действуют"
        }
        record(.engine, "Ступенька настроек: \(Self.stepText(number, name))", detail: detail)
    }

    /// Чем кончилась проба ступеньки на переборе. Время берётся с засечки `.ladderStep`.
    ///
    /// ⚠️ ВРЕМЯ ЗДЕСЬ — НЕ УКРАШЕНИЕ. Проба, уложившаяся в сотые доли секунды, означает,
    /// что движок даже не считал: разговор был мёртв, и ступенька «не помогла» вовсе
    /// не потому, что настройка плохая. Без замера это неотличимо от честной неудачи.
    public func noteLadderOutcome(number: Int, name: String, answered: Bool, note: String? = nil) {
        var detail = "проба заняла: \(elapsedText(.ladderStep))"
        if let note { detail += " · \(note)" }
        record(.turn,
               (answered ? "Настройка помогла: " : "Не помогло: ") + Self.stepText(number, name),
               detail: detail)
    }

    /// Проба ступеньки кончилась ошибкой — то есть настройка не подошла движку.
    public func noteLadderFailed(number: Int, name: String, error: Error) {
        record(.failure, "Настройка не подошла: \(Self.stepText(number, name))",
               detail: "проба заняла: \(elapsedText(.ladderStep)) · "
                     + RuntimeJournal.technicalText(for: error))
    }

    // MARK: Отступление

    /// Кто-то уменьшил выбранный человеком размер памяти разговора.
    ///
    /// ⚠️ САМОЕ ВАЖНОЕ СОБЫТИЕ ЖУРНАЛА. Отступление переписывает настройку человека
    /// НАСОВСЕМ, и если оно проходит молча, человек видит только «настройка сама сбросилась».
    /// Поэтому пишем всё сразу: было → стало, причину, место в коде (подставляется само),
    /// не человек ли только что нажал «Стоп», и — фактом, а не обещанием — что лежит
    /// в настройках ПОСЛЕ записи.
    ///
    /// - Parameters:
    ///   - stoppedByPerson: ход перед этим оборвал человек («Стоп» или уход в фон).
    ///     Тогда пустой ответ модели ничего не доказывает, и отступление, скорее всего, ошибка.
    ///   - calledFrom: место в коде, попросившее отступить.
    ///
    /// ⚠️ ПРО `calledFrom` И ПОЧЕМУ ЗДЕСЬ НЕТ `#function`. Отступление зовут из четырёх
    /// разных мест, но само событие пишется в одном — в `retreatToSafeContext`. Значит
    /// `#function` по умолчанию назвал бы ВСЕГДА его самого, то есть выдал бы за факт
    /// бесполезную правду. Пока параметр не передают, место не печатается вовсе, а кто
    /// позвал — видно по `reason`: у всех четырёх мест он разный.
    public func noteRetreat(from asked: Int,
                            to safe: Int,
                            reason: String,
                            stoppedByPerson: Bool,
                            abortsInARow: Int = 0,
                            calledFrom: String? = nil) {
        let nowChosen = ContextSizeSettings.chosenTokens
        let complaint = UserDefaults.standard.integer(forKey: ContextSizeSettings.retreatKey)
        record(.failure,
               "Память разговора уменьшена: \(ContextSizeSettings.text(asked)) → "
             + "\(ContextSizeSettings.text(safe))",
               detail: "причина: \(reason) · "
                     + (calledFrom.map { "позвали из: \($0) · " } ?? "")
                     + (abortsInARow > 0 ? "обрывов подряд к этому моменту: \(abortsInARow) · " : "")
                     + "человек перед этим останавливал ход: \(stoppedByPerson ? "ДА ⚠️" : "нет") · "
                     + "в настройках теперь: \(ContextSizeSettings.text(nowChosen)) · "
                     + "отметка «не получилось»: "
                     + (complaint > 0 ? ContextSizeSettings.text(complaint) : "нет") + " · "
                     + "поднять обратно — одно касание в «О программе»")
    }

    // MARK: Задача, действия модели и их итоги
    //
    // ⚠️ ЭТА ГРУППА МЕТОДОВ ПОЯВИЛАСЬ 09.08.2026 ВМЕСТЕ С ОТКАЗОМ ОТ ФИЛЬТРА ПРИВАТНОСТИ.
    // Раньше их не было: журнал знал, ЧТО модель делает («попросила действие»), но не знал,
    // ЧТО именно она попросила и что получила в ответ, — а без этого половина разборов
    // упиралась в «а что там на самом деле произошло». Вызовы из LiteRTRuntime.swift
    // и AgentEngine.swift этот агент не правил (не его файлы) — точные места указаны
    // в описании ниже для того, кто зашивает вызовы.

    /// Человек поставил новую задачу — её текст целиком.
    ///
    /// ⚠️ ЗОВЁТСЯ ИЗ AgentEngine.submit(task:). До 09.08.2026 текста задачи в журнале
    /// не было вовсе: по прямому решению владельца это снято — без текста задачи нельзя
    /// понять, ПОЧЕМУ модель сделала то, что сделала.
    public func noteTaskSubmitted(_ text: String) {
        record(.note, "Человек поставил задачу", detail: text)
    }

    /// Модель попросила действие — с настоящими параметрами, а не только их числом.
    ///
    /// ⚠️ ЗОВЁТСЯ ИЗ LiteRTRuntime.interpret() ВМЕСТО прежней строки «параметров: N».
    /// Путь файла и номера строк — ровно то, без чего нельзя понять, какое место модель
    /// тронула и почему правка легла не туда. Аргументы без типизированного смысла
    /// (на случай будущих инструментов) идут следом парами «имя: значение»; содержимое —
    /// последним параметром: оно самое длинное и первым уходит под нож `EngineJournalGuard`,
    /// а путь и номера строк должны пережить обрезку.
    public func noteToolInvocation(_ invocation: ToolInvocation, concurrentCalls: Int = 1) {
        var parts: [String] = []
        if !invocation.path.isEmpty { parts.append("путь: \(invocation.path)") }
        if invocation.mentionsLineRange {
            parts.append("строки: \(invocation.rawFromLine ?? "—")–\(invocation.rawToLine ?? "—")")
        }
        if !invocation.query.isEmpty { parts.append("запрос: \(invocation.query)") }
        // «summary» — параметр инструмента finish: чем модель сама объясняет, что сделала.
        if !invocation.summary.isEmpty { parts.append("итог от модели: \(invocation.summary)") }
        for (key, value) in Self.otherArguments(of: invocation) {
            parts.append("\(key): \(value)")
        }
        if concurrentCalls > 1 {
            parts.append("действий за ход: \(concurrentCalls), выполняем первое")
        }
        // Содержимое — последним: см. предупреждение выше про обрезку.
        if let content = invocation.content {
            parts.append("содержимое (\(content.count) зн.): \(content)")
        }
        record(.turn, "Модель попросила действие: \(invocation.rawName)",
               detail: parts.joined(separator: " · "))
    }

    /// Аргументы, для которых у `ToolInvocation` нет именованного доступа. Известные имена
    /// и их синонимы перечислены здесь же, чтобы одно и то же значение не показать дважды —
    /// синонимы номеров строк и поискового запроса `ToolInvocation` уже разбирает сам.
    private static let knownArgumentNames: Set<String> = [
        "path", "content", "summary",
        "query", "q", "search", "text", "question", "запрос",
        "from_line", "start_line", "line", "from", "first_line",
        "to_line", "end_line", "to", "last_line"
    ]

    private static func otherArguments(of invocation: ToolInvocation) -> [(String, String)] {
        invocation.arguments
            .filter { !knownArgumentNames.contains($0.key) }
            .sorted { $0.key < $1.key }
    }

    /// Что вернул инструмент — и человеку, и модели.
    ///
    /// ⚠️ ЗОВЁТСЯ ИЗ AgentEngine.record(_:for:diff:) — единственного места, где итог любого
    /// действия оседает в ленте. До 09.08.2026 итог инструмента в журнал не попадал вовсе.
    /// `userSummary` — то же самое, что видит человек в ленте (включая наши отписки вроде
    /// «Это место уже читал, показываю дальше»); `payload.plainText` — то, что ЦЕЛИКОМ
    /// ушло модели, включая содержимое прочитанного куска файла.
    public func noteToolResult(_ result: ToolResult) {
        let outcome: String
        switch result.outcome {
        case .success:        outcome = "выполнено"
        case .failed:          outcome = "не выполнено"
        case .rejectedByUser:  outcome = "отклонено человеком"
        }
        record(.turn, "Инструмент \(result.toolName) — \(outcome)",
               detail: "человеку показано: \(result.userSummary) · "
                     + "модели ушло: \(result.payload.plainText)")
    }

    /// Модель ответила текстом — сам текст целиком, а не только его длина.
    ///
    /// ⚠️ ЗОВЁТСЯ ИЗ LiteRTRuntime.interpret() ВМЕСТО прежней строки «длина ответа: N знаков».
    public func noteModelAnswerText(_ text: String) {
        record(.turn, "Модель ответила текстом", detail: text)
    }

    // MARK: Ход разговора

    /// Итог одного хода: время и занятая память разговора по мнению ДВИЖКА.
    /// - Parameter engineTokens: nil — движок не сказал, сколько занято.
    public func noteTurnFinished(engineTokens: Int?,
                                 limitTokens: Int,
                                 stepNumber: Int,
                                 stepName: String) {
        let used = engineTokens.map { ContextSizeSettings.text($0) } ?? "не сказал"
        record(.turn, "Ход закончен за \(elapsedText(.turn))",
               detail: "занято памяти разговора (по движку): \(used) "
                     + "из \(ContextSizeSettings.text(limitTokens)) · "
                     + "ступенька: \(Self.stepText(stepNumber, stepName))")
    }

    /// Наша собственная оценка занятого места — она намеренно завышена и потому расходится
    /// с числом движка. Расхождение и есть улика: по нему видно, когда приложение свернуло
    /// разговор раньше, чем было нужно.
    ///
    /// ⚠️ ЗОВЁТСЯ ИЗ ЦИКЛА АГЕНТА (AgentEngine): только он знает свою оценку.
    public func noteContextEstimate(ourTokens: Int, engineTokens: Int?, limitTokens: Int) {
        let engine = engineTokens.map { ContextSizeSettings.text($0) } ?? "не сказал"
        record(.turn, "Сколько занято памяти разговора",
               detail: "по нашей оценке: \(ContextSizeSettings.text(ourTokens)) · "
                     + "по движку: \(engine) · потолок: \(ContextSizeSettings.text(limitTokens))")
    }

    /// Разговор свернули: что унесли с собой, а что осталось за бортом.
    ///
    /// ⚠️ ЗОВЁТСЯ ИЗ ЦИКЛА АГЕНТА (AgentEngine) — сворачивание живёт там.
    /// В журнал идут ТОЛЬКО числа: ни одной строки самой переписки.
    public func noteCompaction(reason: String,
                               beforeTokens: Int,
                               afterTokens: Int,
                               carriedEntries: Int,
                               droppedEntries: Int) {
        record(.engine, "Свернул память разговора",
               detail: "причина: \(reason) · было: \(ContextSizeSettings.text(beforeTokens)) · "
                     + "стало: \(ContextSizeSettings.text(afterTokens)) · "
                     + "унесли записей: \(carriedEntries) · оставили за бортом: \(droppedEntries)")
    }

    // MARK: Мелочи

    /// «ступенька №5 «другой расчёт…»» — номер и название рядом.
    /// ⚠️ Считается ЗДЕСЬ, чтобы движку не заводить своего помощника: правки в нём идут
    /// параллельно, и лишняя строка там — лишний повод для столкновения.
    static func stepText(_ number: Int, _ name: String) -> String {
        "№\(number) «\(name)»"
    }

    static func tokensText(_ tokens: Int?) -> String {
        guard let tokens else { return "не просил, размер берёт сама модель" }
        return ContextSizeSettings.text(tokens)
    }

    /// ⚠️ `Int.max` от MemoryGate означает «система не знает», а не «памяти бесконечно».
    /// Печатать двадцатизначное число — значит подсунуть человеку выдуманный факт.
    static func memoryText(_ megabytes: Int) -> String {
        megabytes == Int.max ? "неизвестно" : "\(megabytes) МБ"
    }
}

// MARK: - Шапка журнала: сборка, система и действующие настройки

/// Что было верно в момент снятия журнала. Считается на месте, в памяти не живёт:
/// настройки человек меняет прямо во время работы, и хранить их копию — значит однажды
/// показать устаревшую.
public enum EngineDiagnostics {

    /// Строки шапки: версия, сборка, система, память, настройки, память перебора.
    public static func headerLines() -> [String] {
        var lines: [String] = []

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("Приложение: версия \(version), сборка \(build)")
        lines.append("Система: iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")

        let free = MemoryGate.availableMemoryMB()
        lines.append("Память телефона: \(MemoryGate.physicalMemoryMB()) МБ · "
                     + "свободно сейчас: \(EngineJournal.memoryText(free))")

        lines.append(contentsOf: settingsLines())
        lines.append(contentsOf: rememberedLines())
        return lines
    }

    /// Настройки, действующие ПРЯМО СЕЙЧАС. Без них журнал читается вслепую: непонятно,
    /// что человек вообще выбирал и что из этого приложение переписало само.
    public static func settingsLines() -> [String] {
        var lines: [String] = []
        lines.append("Память разговора выбрана: "
                     + ContextSizeSettings.text(ContextSizeSettings.chosenTokens)
                     + " (безопасное дно: \(ContextSizeSettings.text(AgentLimits.contextTokenBudget)))")

        let complaint = UserDefaults.standard.integer(forKey: ContextSizeSettings.retreatKey)
        lines.append("Отметка «не получилось»: "
                     + (complaint > 0
                        ? "приложение отступало с " + ContextSizeSettings.text(complaint)
                        : "нет"))

        lines.append("Поиск в интернете: " + (WebSearchSettings.isEnabled ? "включён" : "выключен"))
        return lines
    }

    /// Что приложение запомнило про перебор настроек и про видеочип.
    ///
    /// ⚠️ ЧИТАЕМ НАСТРОЙКИ ПО ОБЩЕЙ ПРИСТАВКЕ, А НЕ ПО ТОЧНЫМ КЛЮЧАМ ДВИЖКА, И ЭТО НАРОЧНО.
    /// Точные ключи и названия ступенек живут в LiteRTRuntime и меняются вместе с лесенкой;
    /// копия тех же строк здесь разъехалась бы при первой же правке, и человек читал бы
    /// в журнале вчерашнюю правду. Поэтому показываем то, что реально лежит на диске, —
    /// пусть номером ступеньки, зато без вранья. Название ступеньки при этом всё равно
    /// попадает в журнал: его пишет событие «Ступенька настроек» при подъёме модели.
    ///
    /// ⚠️ Зовётся ТОЛЬКО когда человек открыл страницу журнала: перебирать все настройки
    /// приложения в рабочем цикле незачем.
    public static func rememberedLines() -> [String] {
        let prefix = "pocketagent.runtime."
        var lines: [String] = []

        for (key, value) in UserDefaults.standard.dictionaryRepresentation().sorted(by: { $0.key < $1.key })
        where key.hasPrefix(prefix) {
            let short = String(key.dropFirst(prefix.count))
            lines.append("Запомнено: \(short) = \(describe(value))")
        }

        if lines.isEmpty { lines.append("Про перебор настроек пока ничего не запомнено") }
        return lines
    }

    /// ⚠️ Значение печатаем КАК ЕСТЬ, без попыток угадать его смысл. Настройки хранят
    /// числа и признаки одним и тем же типом, и «умное» толкование однажды показало бы
    /// запомненную ступеньку №1 как «да» — выдуманный факт вместо настоящего числа.
    private static func describe(_ value: Any) -> String {
        if let list = value as? [Int] {
            return list.map(String.init).joined(separator: ", ")
        }
        return String(describing: value)
    }

    /// Полный текст для кнопки «Скопировать всё»: шапка + всё, что собрал экран.
    ///
    /// ⚠️ Шапка идёт ПЕРВОЙ, потому что читают её первой: по версии сборки сразу видно,
    /// на чём снят журнал, — иначе разбор начинается с вопроса «а какая это сборка».
    public static func fullReport(appendingBody body: String) -> String {
        (headerLines() + ["", body]).joined(separator: "\n")
    }
}
