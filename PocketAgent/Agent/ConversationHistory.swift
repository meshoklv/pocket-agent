//
//  ConversationHistory.swift
//  PocketAgent
//
//  Память разговора: что модель уже видела и во что это обошлось.
//
//  Зачем это нужно, если контекст модели 32k, а движок даёт лишь несколько тысяч токенов:
//  KV-кэш разговора конечен, и когда он кончается — генерация просто ломается.
//  Поэтому мы считаем длину сами, заранее, и заранее же выбрасываем лишнее.
//
//  ⚠️ «Несколько тысяч» — не одно число: движок пробует увеличенное окно и умеет отступить
//  к безопасному. Поэтому потолок пересказа здесь не константа, а то, что сказал живой
//  движок (`setTokenBudget`); формула общая для всех порогов и лежит в AgentLimits.
//
//  ⚠️ ГЛАВНОЕ, РАДИ ЧЕГО ЭТОТ ФАЙЛ ПЕРЕПИСАН (живой случай 09.08.2026).
//  Агент создал файл на 221 строку, человек попросил заменить эмодзи на иконки.
//  Модель честно листала файл страницами: 1–66, 67–106, снова 1–66 — и КАЖДАЯ
//  прочитанная страница осталась в памяти разговора целиком. Окно кончилось,
//  человек получил «Извините, у меня проблемы с чтением всего файла».
//  Три копии одного файла в памяти — это не работа, это мусор.
//
//  Отсюда два понятия, которых здесь раньше не было:
//    • ТЕМА записи (`Topic`) — про какой файл или папку она была. Только зная тему,
//      можно понять, что запись УСТАРЕЛА: прочитали ту же (или другую) страницу того же
//      файла — прежняя копия больше не нужна, но место занимает.
//    • ДВЕ ЦЕНЫ у записи. `tokens` — во что она обойдётся, если разговор придётся
//      начать заново; `modelTokens` — сколько она заняла в кэше движка, когда уходила
//      модели. Раньше считалась только первая, и наш счётчик показывал «место есть»
//      ровно тогда, когда у движка его уже не было.
//
//  Что здесь НЕ происходит: лента, которую видит человек, не трогается вовсе.
//  Она живёт в AgentSession.snapshot.messages и остаётся полной. Ужимается только то,
//  что уходит МОДЕЛИ.
//
//  Сама история — значимый тип без ссылок: её безопасно копировать и хранить.
//  Токены считаются оценкой (точного токенизатора у нас на руках нет),
//  поэтому бюджет берём с запасом.
//

import Foundation

public struct ConversationHistory: Sendable, Equatable {

    // MARK: - Запись

    public enum Role: String, Sendable, Equatable, Codable {
        case system
        case user
        case model
        case tool
    }

    /// О чём была запись. Нужно ровно затем, чтобы понимать, что уже устарело.
    ///
    /// ⚠️ Без темы история — плоский список строк, и страница файла, прочитанная три хода
    /// назад, ничем не отличается от задачи человека. А отличие принципиальное: задача
    /// нужна до конца работы, старая страница — только до следующего чтения того же файла.
    public enum Topic: Sendable, Equatable, Codable {
        /// Обычная запись: задача человека, ответ модели, служебная подсказка.
        case plain
        /// Кусок файла, показанный модели. `lines` — «1–66», пусто — файл целиком.
        case fileRead(path: String, lines: String)
        /// Содержимое папки.
        case folderList(path: String)
        /// Предложенная моделью запись файла (весь новый текст — самый дорогой ход).
        case fileWrite(path: String, lines: String)
        /// Выжимка нескольких свёрнутых ходов.
        case digest
        /// Неудачная попытка: кривой вызов модели и ответ об ошибке.
        ///
        /// ⚠️ ЗАЧЕМ ОТДЕЛЬНАЯ ТЕМА. Провал в памяти разговора вреден дважды. Во-первых,
        /// он дорогой: «вызов write_file(content=…)» плюс полный текст ошибки — это
        /// сотня-другая токенов, а два-три провала подряд съедают половину окна в 4096.
        /// Во-вторых — и это хуже — модель на 2 млрд параметров, видя свой прежний
        /// кривой вызов дословно, ПОВТОРЯЕТ его: для неё это образец собственного ответа.
        /// Поэтому дословной остаётся только ПОСЛЕДНЯЯ попытка, прежние сворачиваются
        /// в пометку «этот путь не сработал» — модель помнит, что так не вышло,
        /// но образца перед глазами больше нет.
        ///
        /// `what` — что именно пробовали («write_file README.md»), чтобы след остался
        /// осмысленным, а не безликим «была ошибка».
        case failedAttempt(what: String)
    }

    public struct Entry: Sendable, Equatable, Identifiable, Codable {
        public let id: UUID
        public let role: Role
        /// Текст, который поедет модели, если разговор придётся начать заново.
        public private(set) var text: String
        /// Оценка длины `text` в токенах.
        public private(set) var tokens: Int
        /// Сколько токенов запись заняла В КЭШЕ ДВИЖКА, когда уходила модели.
        ///
        /// ⚠️ ЭТО НЕ ТО ЖЕ, ЧТО `tokens`, и путать их нельзя. В историю мы кладём короткий
        /// след («read_file: показаны строки 1–66 из 221»), а движку уходило полное тело
        /// ответа — целая страница файла, в десять раз длиннее. Раньше считался только
        /// след, поэтому обрезка включалась после того, как модель уже упёрлась.
        public private(set) var modelTokens: Int
        public private(set) var topic: Topic
        /// Содержимое устарело и заменено коротким следом.
        public private(set) var isCollapsed: Bool
        public let createdAt: Date

        public init(id: UUID = UUID(),
                    role: Role,
                    text: String,
                    topic: Topic = .plain,
                    modelTokens: Int? = nil,
                    createdAt: Date = Date()) {
            self.id = id
            self.role = role
            self.text = text
            self.tokens = ConversationHistory.estimateTokens(text)
            // Цена у движка не может быть меньше нашего же следа: если её не назвали,
            // считаем, что записи стоила ровно столько, сколько в ней написано.
            self.modelTokens = max(modelTokens ?? 0, self.tokens)
            self.topic = topic
            self.isCollapsed = false
            self.createdAt = createdAt
        }

        /// Заменить содержимое коротким следом.
        ///
        /// ⚠️ `modelTokens` при этом НЕ уменьшается, и это не оплошность: из живого кэша
        /// движка старый текст не вынуть никаким способом — там он лежит до конца
        /// разговора. Разница между двумя ценами и есть то, что освободит перезапуск.
        mutating func collapse(to trace: String) {
            let traceTokens = ConversationHistory.estimateTokens(trace)
            guard !isCollapsed, traceTokens < tokens else { return }
            text = trace
            tokens = traceTokens
            isCollapsed = true
        }

        /// Разговор начат заново: в кэше движка теперь лежит ровно то, что мы переслали.
        mutating func rebase() {
            modelTokens = tokens
        }

        /// Переназначить тему записи.
        ///
        /// ⚠️ Нужно ровно для одного случая: провалившейся попытки. В момент, когда
        /// модель зовёт действие, мы ещё не знаем, что оно не выполнится, — узнаём это
        /// ходом позже. Значит тему приходится ставить задним числом, иначе провал
        /// не отличить от обычного хода и свернуть его будет нечем.
        mutating func retag(_ newTopic: Topic) {
            topic = newTopic
        }
    }

    // MARK: - Что лежит в папке

    /// Снимок последнего просмотра папки: только имена, без размеров и дат.
    ///
    /// ⚠️ Это ПАМЯТЬ О ТОМ, ЧТО ВИДЕЛИ, а не правда о диске прямо сейчас: пока шёл
    /// разговор, файл могли создать из другого приложения. Поэтому и в карточке
    /// это поле называется «видел в папке», а не «в папке лежит».
    public struct FolderSnapshot: Sendable, Equatable, Codable {
        /// Путь от корня проекта. Пусто — сам корень.
        public let path: String
        /// Имена, которые уносим в новый разговор.
        public let names: [String]
        /// Сколько записей было показано модели всего — чтобы честно сказать «и ещё N».
        public let total: Int

        public init(path: String, names: [String], total: Int) {
            self.path = path
            self.names = names
            self.total = total
        }
    }

    // MARK: - Настройки

    /// Сколько токенов разговора считаем потолком, пока движок не сказал своё число.
    /// Держим разговор заметно короче окна: остаток нужен на ответ модели.
    ///
    /// ⚠️ Это потолок ПЕРЕСКАЗА — того, что поедет в новый разговор. Кэш живого разговора
    /// меряется отдельно (`engineTokens` и настоящий счётчик движка).
    ///
    /// ⚠️ ЧИСЛО БОЛЬШЕ НЕ ВПИСАНО РУКАМИ. Раньше здесь стояло 2600 — посчитанное от 4096,
    /// то есть от предположения, что окно всегда одно. Теперь окно бывает разным (движок
    /// пробует увеличенное и умеет отступить), поэтому берём ту же формулу, что и остальные
    /// пороги, а живое число приходит от движка через `setTokenBudget`.
    public static let defaultTokenBudget =
        AgentLimits.contextRestartThreshold(forCeiling: AgentLimits.contextTokenBudget)

    /// Накладные расходы на служебную обёртку одного сообщения.
    private static let perMessageOverhead = 4

    /// Длина выжимки из свёрнутых ходов (символы). Больше — и выжимка перестаёт быть выжимкой.
    private static let digestCharacterBudget = 420

    private static let digestPrefix = "Раньше в этом разговоре: "

    /// Потолок пересказа. ⚠️ ПЕРЕМЕННАЯ, А НЕ КОНСТАНТА: настоящее окно известно только
    /// после того, как поднялся движок (он пробует увеличенное и умеет отступить),
    /// а лента заводится раньше — ещё до первого запуска модели. Меняется одним
    /// методом `setTokenBudget`, снаружи только читается.
    public private(set) var tokenBudget: Int
    /// Столько последних сообщений не выбрасываем никогда.
    public let minRecentEntries: Int

    // MARK: - Состояние

    public private(set) var entries: [Entry] = []
    /// Сколько сообщений уже выброшено (для честного сообщения человеку).
    public private(set) var droppedEntries: Int = 0
    public private(set) var droppedTokens: Int = 0
    /// Сколько ходов свёрнуто в выжимку — они не потеряны, а пересказаны одной строкой.
    public private(set) var foldedEntries: Int = 0
    /// Имена файлов из последнего просмотра папки.
    ///
    /// ⚠️ ЗАЧЕМ ХРАНИТЬ ИХ ОТДЕЛЬНО ОТ ЛЕНТЫ. В памяти разговора от просмотра папки
    /// остаётся строка «list_files: Найдено: 8 записей» — сами имена туда не кладутся
    /// никогда (они дорогие). При сворачивании разговора имена теряются совсем, и модель
    /// первым же ходом зовёт list_files заново: 300…600 токенов на восстановление того,
    /// что мы только что выбросили. Двадцать имён в карточке-переносе стоят 60…80.
    public private(set) var folderSnapshot: FolderSnapshot?
    /// Запись, с которой началась текущая задача. См. `currentTaskIndex`.
    private var taskEntryID: UUID?

    // MARK: - Создание

    public init(systemPrompt: String,
                tokenBudget: Int = ConversationHistory.defaultTokenBudget,
                minRecentEntries: Int = 4) {
        self.tokenBudget = max(400, tokenBudget)
        self.minRecentEntries = max(2, minRecentEntries)
        self.entries = [Entry(role: .system, text: systemPrompt)]
    }

    /// Движок сказал, какое окно он выдал на самом деле, — пересчитываем потолок пересказа.
    ///
    /// ⚠️ Нижняя граница та же, что в создании (400 токенов): пересказ короче этого
    /// перестаёт быть пересказом, и разговор сворачивался бы вечно, ничего не унося.
    /// Сворачивать прямо здесь ничего не надо: `needsCompaction` посмотрит на новый
    /// потолок при первом же следующем ходе — а сворачивать посреди чужого шага опаснее,
    /// чем подождать один ход.
    public mutating func setTokenBudget(_ value: Int) {
        tokenBudget = max(400, value)
    }

    // MARK: - Наполнение

    /// Добавить запись. `topic` — про что она, `modelTokens` — во сколько она обошлась
    /// движку на самом деле (для ответов инструментов это длина ПОЛНОГО тела, а не следа).
    public mutating func append(role: Role,
                                text: String,
                                topic: Topic = .plain,
                                modelTokens: Int? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Свежая запись делает бесполезными прежние про то же самое — схлопываем их
        // ДО добавления, чтобы не задеть саму новую запись.
        collapseSuperseded(by: topic)
        entries.append(Entry(role: role, text: trimmed, topic: topic, modelTokens: modelTokens))
    }

    /// Человек поставил НОВУЮ задачу: добавить его фразу и запомнить, что работа теперь про неё.
    ///
    /// ⚠️ ЗАЧЕМ ОТДЕЛЬНЫЙ ВЫЗОВ, А НЕ ПРОСТО `append(role: .user…)`. Разговор живёт дольше
    /// одной задачи: он чистится только кнопкой «Новая задача», а просьбы просто копятся.
    /// Без отметки «вот текущая задача» и защита от выбрасывания, и поле «Просили:»
    /// в карточке-переносе цеплялись за самую первую фразу разговора — то есть за работу,
    /// сделанную полчаса назад. Ответ на вопрос модели («да», «нет») задачу НЕ меняет
    /// и сюда не идёт: он часть той же задачи.
    public mutating func appendTask(_ text: String, modelTokens: Int? = nil) {
        let before = entries.count
        append(role: .user, text: text, modelTokens: modelTokens)
        // Пустую фразу append не добавляет — тогда и отмечать нечего.
        guard entries.count > before else { return }
        taskEntryID = entries.last?.id
    }

    /// Заменить системную инструкцию (например, после смены папки проекта).
    public mutating func setSystemPrompt(_ prompt: String) {
        let entry = Entry(role: .system, text: prompt)
        if let index = entries.firstIndex(where: { $0.role == .system }) {
            entries[index] = entry
        } else {
            entries.insert(entry, at: 0)
        }
    }

    /// Полный сброс: остаётся только системная инструкция.
    public mutating func reset(systemPrompt: String? = nil) {
        let prompt = systemPrompt ?? entries.first(where: { $0.role == .system })?.text ?? ""
        entries = [Entry(role: .system, text: prompt)]
        droppedEntries = 0
        droppedTokens = 0
        foldedEntries = 0
        // Записей больше нет — значит и отметка о текущей задаче указывает в пустоту.
        taskEntryID = nil
        // ⚠️ Снимок папки живёт ровно столько же, сколько разговор. Пережить сброс он
        // не имеет права: папку проекта могли сменить, и тогда карточка-перенос
        // рассказывала бы модели про чужой проект.
        folderSnapshot = nil
    }

    /// Модель посмотрела папку — запоминаем ИМЕНА, чтобы не обходить её второй раз.
    ///
    /// `lines` — ровно то, что ушло модели (`list_files` отдаёт строки с именами;
    /// у папок в конце косая черта). Оговорки инструмента начинаются с «⚠️» — это
    /// не имена, и в карточку они не идут.
    ///
    /// ⚠️ И ОТМЕТКА ПУСТОЙ ПАПКИ — ТОЖЕ НЕ ИМЯ. У пустой папки список состоит из одной
    /// строки «(пусто)», и она попадала в снимок как обычное имя файла: после сворачивания
    /// разговора карточка сообщала модели «видел в корне проекта: (пусто)», а та шла
    /// читать несуществующий файл с таким именем. Пустой список — это отсутствие снимка,
    /// а не снимок с одним придуманным файлом.
    public mutating func noteFolderListing(path: String, lines: [String]) {
        let names = lines
            .filter { !$0.hasPrefix("⚠️") && $0 != ToolTexts.emptyFolderLine }
            .map { Self.shorten($0, to: Self.folderNameCharacters) }
        guard !names.isEmpty else {
            folderSnapshot = nil
            return
        }
        folderSnapshot = FolderSnapshot(path: path,
                                        names: Array(names.prefix(Self.folderSnapshotNames)),
                                        total: names.count)
    }

    // MARK: - Что устарело

    /// Пришла свежая запись — всё, что она делает бесполезным, схлопываем в след.
    ///
    /// Правило одно и то же для чтения и для списка папки: в памяти остаётся ПОСЛЕДНИЙ
    /// результат, предыдущие превращаются в строку «(ранее читал …)». Модель должна
    /// понимать, что она это уже видела, но не платить за содержимое дважды.
    private mutating func collapseSuperseded(by topic: Topic) {
        switch topic {
        case .fileRead(let path, _):
            collapseReads(of: path, fileChanged: false)
        case .folderList(let path):
            for index in entries.indices {
                guard case .folderList(let previous) = entries[index].topic, previous == path else { continue }
                entries[index].collapse(to: Self.listTrace(path: path))
            }
        case .fileWrite, .plain, .digest, .failedAttempt:
            // Провалы схлопываются не «по приходу похожей записи», а по факту исхода —
            // см. noteAttemptFailed / noteAttemptSucceeded. Здесь делать нечего.
            break
        }
    }

    private mutating func collapseReads(of path: String, fileChanged: Bool) {
        for index in entries.indices {
            guard case .fileRead(let previous, let lines) = entries[index].topic, previous == path else { continue }
            entries[index].collapse(to: Self.readTrace(path: path, lines: lines, fileChanged: fileChanged))
        }
    }

    /// Запись файла применена: новый текст уже на диске, держать его в разговоре незачем.
    ///
    /// Схлопываем сразу две вещи: предложение модели (весь новый текст файла — самый
    /// длинный ход, какой она вообще делает) и прежние чтения этого файла — они теперь
    /// не просто лишние, а ВРУТ: на диске лежит уже другое.
    public mutating func noteWriteApplied(path: String, lines: String) {
        for index in entries.indices {
            guard case .fileWrite(let previous, _) = entries[index].topic, previous == path else { continue }
            entries[index].collapse(to: Self.writeTrace(path: path, lines: lines))
        }
        collapseReads(of: path, fileChanged: true)
    }

    /// Человек отклонил запись: содержимое, от которого отказались, в памяти не держим.
    public mutating func noteWriteRejected(path: String) {
        for index in entries.indices {
            guard case .fileWrite(let previous, _) = entries[index].topic, previous == path else { continue }
            entries[index].collapse(to: Self.rejectedWriteTrace(path: path))
        }
    }

    // MARK: - Провальные попытки

    /// Действие не выполнилось. Прежние провалы схлопываем, текущий помечаем.
    ///
    /// ⚠️ ПОРЯДОК ЗДЕСЬ — ВСЁ. Сначала сворачиваем то, что уже помечено провалом,
    /// и только потом помечаем свежую пару «вызов + ошибка». Сделай наоборот —
    /// свернётся и текущая попытка, а её модель обязана видеть дословно: иначе она
    /// не поймёт, что именно сейчас не так, и пойдёт по третьему кругу.
    ///
    /// Итог: в памяти разговора дословна ровно ОДНА последняя неудача, всё,
    /// что было до неё, — строчка «(этот путь не сработал)».
    ///
    /// Помечаем две записи: сам вызов модели и ответ об ошибке. Вызов берём, только
    /// если он стоит НЕПОСРЕДСТВЕННО перед ошибкой, — иначе легко зацепить чужой,
    /// вполне удачный ход (так бывает, когда модель ответила пустотой и ошибка
    /// пришла не от вызова, а от нашего же напоминания).
    public mutating func noteAttemptFailed(what: String) {
        collapseFailedAttempts()

        guard let resultIndex = entries.lastIndex(where: { $0.role == .tool }) else { return }
        entries[resultIndex].retag(.failedAttempt(what: what))

        let callIndex = resultIndex - 1
        if callIndex > 0, entries[callIndex].role == .model {
            entries[callIndex].retag(.failedAttempt(what: what))
        }
    }

    /// Действие наконец удалось — держать прежние неудачи дословно больше незачем.
    public mutating func noteAttemptSucceeded() {
        collapseFailedAttempts()
    }

    /// Свернуть все помеченные провалом записи в короткие следы.
    private mutating func collapseFailedAttempts() {
        for index in entries.indices {
            guard case .failedAttempt(let what) = entries[index].topic else { continue }
            let trace = entries[index].role == .model
                ? Self.failedCallTrace(what: what)
                : Self.failedResultTrace
            entries[index].collapse(to: trace)
        }
    }

    // MARK: - Следы схлопнутых записей

    static func readTrace(path: String, lines: String, fileChanged: Bool) -> String {
        let what = lines.isEmpty ? "файл \(path)" : "строки \(lines) файла \(path)"
        return fileChanged
            ? "(ранее читал \(what) — файл с тех пор изменён)"
            : "(ранее читал \(what))"
    }

    static func listTrace(path: String) -> String {
        "(ранее смотрел \(path.isEmpty ? "корень проекта" : "папку \(path)"))"
    }

    /// След от кривого вызова: что пробовали, без самого вызова.
    static func failedCallTrace(what: String) -> String {
        what.isEmpty ? "(была неудачная попытка)" : "(пробовал \(what) — не вышло)"
    }

    /// След от текста ошибки. Нарочно безликий: подробности прошлой неудачи
    /// модели не нужны, а место занимают.
    static let failedResultTrace = "(этот путь не сработал)"

    static func writeTrace(path: String, lines: String) -> String {
        lines.isEmpty
            ? "\(appliedWritePrefix) файл \(path))"
            : "\(appliedWritePrefix) строки \(lines) файла \(path))"
    }

    static func rejectedWriteTrace(path: String) -> String {
        "\(rejectedWritePrefix) \(path) — человек отклонил)"
    }

    /// ⚠️ ПРИСТАВКИ ВЫНЕСЕНЫ В КОНСТАНТЫ НЕ РАДИ КРАСОТЫ. По ним карточка-перенос
    /// отличает «запись применена» от «человек отклонил»: тема записи (`fileWrite`)
    /// у обоих случаев одна и та же, а исход — противоположный. Написать в карточке
    /// «записал файл», который человек отклонил, — это соврать модели о состоянии диска,
    /// и она продолжит работу по несуществующей правке.
    private static let appliedWritePrefix = "(записал"
    private static let rejectedWritePrefix = "(предлагал записать"

    // MARK: - Длина

    /// Сколько займёт разговор, если начать его заново, — то есть цена пересказа.
    public var estimatedTokens: Int {
        entries.reduce(0) { $0 + $1.tokens + ConversationHistory.perMessageOverhead }
    }

    /// Наша оценка того, сколько занято в кэше движка ПРЯМО СЕЙЧАС.
    /// Настоящий счётчик один — `ModelRuntime.usedTokens()`; это запасной,
    /// на случай когда движок не ответил.
    public var engineTokens: Int {
        entries.reduce(0) { $0 + $1.modelTokens + ConversationHistory.perMessageOverhead }
    }

    /// Сколько освободит перезапуск разговора: устаревшие копии страниц и отклонённые
    /// правки, которые в кэше движка лежат целиком, а в пересказ поедут одной строкой.
    ///
    /// ⚠️ ПОСЛЕДНИЙ РЕЗУЛЬТАТ ИНСТРУМЕНТА ИЗ ЭТОГО СЧЁТА ИСКЛЮЧЁН, и это не мелочь.
    /// При перезапуске он уходит модели ДОСЛОВНО — иначе она продолжит работу вслепую,
    /// не увидев того, ради чего звала действие. Значит на нём мы не экономим ни токена,
    /// и считать его выгодой — врать самим себе: агент сворачивал бы разговор ради
    /// свободного места, которого не появится.
    public var reclaimableTokens: Int {
        let lastToolIndex = entries.lastIndex(where: { $0.role == .tool })
        var total = 0
        for index in entries.indices where index != lastToolIndex {
            total += entries[index].modelTokens - entries[index].tokens
        }
        return max(0, total)
    }

    public var needsCompaction: Bool { estimatedTokens > tokenBudget }

    /// Доля занятого бюджета 0…1 — можно показывать полоской в интерфейсе.
    public var fill: Double {
        min(1.0, Double(estimatedTokens) / Double(tokenBudget))
    }

    // MARK: - Вытеснение

    /// Ужимает пересказ ступенями: от самого дешёвого к самому болезненному.
    /// Возвращает true, если что-то изменилось.
    ///
    /// ⚠️ Порядок ступеней взят с обкатанного чужого приложения того же класса
    /// (Gemma с инструментами на iPhone) и подогнан под наши понятия:
    ///   1. Результат уже выполненного действия → короткая сводка. Он самый длинный
    ///      и самый бесполезный: работа по нему уже сделана.
    ///   2. Длинный ответ модели → обрезать до 240 знаков с многоточием.
    ///   3. Самые старые ходы → одна выжимка («читал README; правил main.swift»).
    ///   4. И только потом — выбрасывать совсем.
    /// У нас третья ступень мягче, чем у них (они на этом месте просто выбрасывают
    /// самый старый ответ модели): выжимка стоит 15–25 токенов на ход и сохраняет
    /// главное — что делали и чем кончилось. Раньше здесь была ТОЛЬКО четвёртая
    /// ступень, и человек видел «старые сообщения убраны из памяти модели» — то есть
    /// агент молча забывал, что уже делал, и начинал ходить по кругу.
    @discardableResult
    public mutating func compact() -> Bool {
        guard needsCompaction else { return false }
        let target = Int(Double(tokenBudget) * 0.7)
        var didChange = false

        while estimatedTokens > target, collapseOldestToolResult() {
            didChange = true
        }
        while estimatedTokens > target, shortenOldestModelAnswer() {
            didChange = true
        }
        while estimatedTokens > target, foldOldestTurns() {
            didChange = true
        }
        while estimatedTokens > target, let index = firstDroppableIndex() {
            let entry = entries.remove(at: index)
            droppedEntries += 1
            droppedTokens += entry.tokens
            didChange = true
        }
        return didChange
    }

    /// Разговор с движком начат заново: в кэше теперь лежит ровно то, что мы переслали,
    /// а не вся прежняя переписка. Обнуляем разницу, иначе агент будет считать, что
    /// освобождать есть что, и перезапускаться по кругу.
    public mutating func rebaseAfterRestart() {
        for index in entries.indices {
            entries[index].rebase()
        }
    }

    /// Ступень 1: самый старый ещё не сжатый результат действия → короткая сводка.
    /// false — сжимать больше нечего.
    private mutating func collapseOldestToolResult() -> Bool {
        for index in droppableIndexes() where entries[index].role == .tool {
            guard !entries[index].isCollapsed else { continue }
            let before = entries[index].tokens
            entries[index].collapse(to: Self.shorten(entries[index].text,
                                                     to: Self.toolResultTraceCharacters))
            if entries[index].tokens < before { return true }
        }
        return false
    }

    /// Ступень 2: самый старый длинный ответ модели → обрезка до порога.
    ///
    /// ⚠️ Порог маленький нарочно: длинные рассуждения модели в памяти бесполезны,
    /// а места занимают как страница файла. Первые две-три фразы несут всё, что нужно.
    private mutating func shortenOldestModelAnswer() -> Bool {
        for index in droppableIndexes() where entries[index].role == .model {
            guard !entries[index].isCollapsed,
                  entries[index].text.count > Self.modelAnswerCharacters else { continue }
            let before = entries[index].tokens
            entries[index].collapse(to: Self.shorten(entries[index].text,
                                                     to: Self.modelAnswerCharacters))
            if entries[index].tokens < before { return true }
        }
        return false
    }

    /// До скольких знаков ужимаем сводку выполненного действия.
    private static let toolResultTraceCharacters = 60
    /// Длиннее этого ответ модели в памяти не держим.
    private static let modelAnswerCharacters = 240

    /// Свернуть самые старые ходы в одну выжимку. false — сворачивать больше нечего.
    private mutating func foldOldestTurns() -> Bool {
        let candidates = droppableIndexes()
        // Один ход сворачивать бессмысленно: выжимка выйдет не короче него самого.
        guard candidates.count >= 2 else { return false }

        // Берём половину самых старых: так свежая часть разговора остаётся дословной,
        // а выжимка не съедает всё разом.
        let take = max(2, candidates.count / 2)
        let indexes = Array(candidates.prefix(take))

        var clauses: [String] = []
        for index in indexes {
            let entry = entries[index]
            if case .digest = entry.topic {
                // Прежнюю выжимку вливаем в новую, без её приставки.
                let body = entry.text
                    .replacingOccurrences(of: Self.digestPrefix, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                if !body.isEmpty { clauses.append(body) }
                continue
            }
            if let clause = Self.clause(for: entry) { clauses.append(clause) }
        }

        // ⚠️ Цену у движка переносим в выжимку целиком. Свёрнутые ходы из кэша движка
        // никуда не делись — они там до конца разговора; забудь мы их цену, счётчик
        // занятого места соврал бы в меньшую сторону ровно тогда, когда места мало.
        let foldedModelTokens = indexes.reduce(0) { $0 + entries[$1].modelTokens }
        let digest = Entry(role: .system,
                           text: Self.digestText(clauses),
                           topic: .digest,
                           modelTokens: foldedModelTokens)
        for index in indexes.reversed() {
            entries.remove(at: index)
        }
        entries.insert(digest, at: indexes[0])
        foldedEntries += indexes.count
        return true
    }

    /// Индексы записей, которые можно свернуть или выбросить.
    /// Не трогаем: системную инструкцию, первую фразу человека, последний результат
    /// инструмента, незакрытый вопрос модели и хвост разговора.
    private func droppableIndexes() -> [Int] {
        let protectedTail = entries.count - minRecentEntries
        guard protectedTail > 1 else { return [] }
        let lastToolIndex = entries.lastIndex(where: { $0.role == .tool })
        let question = openQuestionIndex
        let task = currentTaskIndex
        return (1..<protectedTail).filter { $0 != lastToolIndex && $0 != question && $0 != task }
    }

    /// Фраза человека, с которой началась ТЕКУЩАЯ задача, — то, ради чего идёт работа.
    ///
    /// ⚠️ ЕЁ НЕЛЬЗЯ НИ ВЫБРОСИТЬ, НИ СВЕРНУТЬ В ВЫЖИМКУ, И ЭТО ГЛАВНЫЙ ДЕФЕКТ, КОТОРЫЙ
    /// ЗДЕСЬ ЧИНИТСЯ. Ужимание идёт от самых старых записей к новым, а самая старая
    /// запись разговора — как раз задача человека. То есть при нехватке места первой
    /// терялась именно она, и после сворачивания помощник переспрашивал про уже
    /// названное. Защита стоит несколько десятков токенов, потеря — всей работы.
    ///
    /// ⚠️ И ЭТО ИМЕННО ТЕКУЩАЯ ЗАДАЧА, А НЕ ПЕРВАЯ ФРАЗА РАЗГОВОРА. Разговор чистится
    /// только кнопкой «Новая задача», а каждая следующая просьба просто дописывается
    /// в него. Пока здесь стояла «первая запись человека», выходило так: человек просил
    /// «создай README», потом «перепиши LICENSE», посреди второй задачи память
    /// сворачивалась — и карточка-перенос говорила модели «Просили: создай README»,
    /// тогда как строка «Цель:» в инструкции говорила про LICENSE. Две противоречащие
    /// цели одновременно, и маленькая модель честно выбирала не ту.
    ///
    /// Запасной путь (первая фраза человека) остаётся на случай, когда задачу никто
    /// не отметил: разговор, восстановленный из старой записи, лучше защитить хоть как-то.
    private var currentTaskIndex: Int? {
        if let taskEntryID, let index = entries.lastIndex(where: { $0.id == taskEntryID }) {
            return index
        }
        return entries.firstIndex(where: { $0.role == .user })
    }

    /// Незакрытый вопрос модели человеку: спросила и ждёт ответа.
    ///
    /// ⚠️ ВЫБРАСЫВАТЬ ЕГО НЕЛЬЗЯ НИ ПРИ КАКОЙ НЕХВАТКЕ МЕСТА. Человек отвечает на
    /// вопрос одним словом («первый», «да»), и если самого вопроса в памяти уже нет,
    /// это слово прилетает в пустоту: модель не знает, к чему оно, и разговор
    /// рассыпается. Освободить пару десятков токенов такой ценой — плохая сделка.
    /// Модель задала вопрос и ждёт ответа человека.
    ///
    /// ⚠️ Наружу это нужно ровно для одного решения: следующая фраза человека — ответ
    /// на вопрос, а не новая задача и не болтовня. Без этого голое «да» посреди работы
    /// приложение считало разговором, обнуляло цель и выключало защиту от застревания.
    public var isAwaitingAnswer: Bool { openQuestionIndex != nil }

    private var openQuestionIndex: Int? {
        guard let index = entries.lastIndex(where: { $0.role == .model }),
              entries[index].text.hasSuffix("?") else { return nil }
        // Человек уже ответил — вопрос закрыт, держать его особо незачем.
        if let answered = entries.lastIndex(where: { $0.role == .user }), answered > index {
            return nil
        }
        return index
    }

    private func firstDroppableIndex() -> Int? {
        droppableIndexes().first
    }

    /// Одна строка выжимки: что было в этом ходе. Содержимое файлов сюда не попадает никогда.
    private static func clause(for entry: Entry) -> String? {
        switch entry.topic {
        case .fileRead(let path, let lines):
            return lines.isEmpty ? "читал \(path)" : "читал \(path) (\(lines))"
        case .folderList(let path):
            return "смотрел \(path.isEmpty ? "корень проекта" : path)"
        case .fileWrite(let path, _):
            return "правил \(path)"
        case .digest:
            return nil
        case .failedAttempt(let what):
            // Пара «вызов + ошибка» дала бы в выжимке две строки об одном и том же,
            // поэтому от ответа об ошибке не берём ничего: всё сказано строкой вызова.
            guard entry.role == .model else { return nil }
            return what.isEmpty ? "попытка не удалась" : "\(what) — не вышло"
        case .plain:
            switch entry.role {
            case .user:   return "человек просил: " + shorten(entry.text, to: 90)
            case .model:  return "агент: " + shorten(entry.text, to: 70)
            case .tool:   return "итог: " + shorten(entry.text, to: 70)
            case .system: return nil
            }
        }
    }

    private static func digestText(_ clauses: [String]) -> String {
        var body = ""
        for clause in clauses {
            let next = body.isEmpty ? clause : body + "; " + clause
            guard next.count <= digestCharacterBudget else { break }
            body = next
        }
        if body.isEmpty { body = "несколько шагов" }
        return digestPrefix + body + "."
    }

    // MARK: - Карточка-перенос в новый разговор

    /// Что уносит с собой модель, когда разговор приходится начать заново.
    ///
    /// ⚠️ ЭТО КАРТОЧКА С ПОСТОЯННЫМИ ПОЛЯМИ, А НЕ ХРОНОЛОГИЧЕСКИЙ ПЕРЕСКАЗ, И РАЗНИЦА
    /// ТУТ ПРИНЦИПИАЛЬНАЯ. Прежний пересказ шёл по ленте от новых записей к старым
    /// и обрывался, когда кончался бюджет знаков, — то есть за одно и то же место
    /// соревновались вещи совершенно разной ценности: болтовня модели трёхминутной
    /// давности вытесняла первую фразу человека, саму задачу. Плюс из ленты выпадал
    /// список файлов, и модель первым же ходом звала list_files заново.
    ///
    /// Здесь у каждого поля своё место и свой предел, а задача не режется никогда.
    /// Карточку целиком ведёт приложение — модель её не пишет и испортить не может,
    /// ровно как строку «сейчас делаю».
    ///
    /// `dropLastToolEntry` — не пересказывать последний результат инструмента: его
    /// отправляют отдельно и дословно, чтобы модель продолжила работу с места.
    /// `goalAlreadyStated` — задача, которая уже стоит строкой «Цель:» в системной
    /// инструкции: платить за неё второй раз незачем.
    public func handoffCard(maxCharacters: Int = 900,
                            dropLastToolEntry: Bool = false,
                            goalAlreadyStated: String = "") -> String {
        var budget = maxCharacters

        // Хвост считаем ПЕРВЫМ: всё, что в него попало, в другие поля уже не идёт —
        // иначе одна и та же фраза уехала бы в новый разговор дважды.
        let tailIndexes = tailEntryIndexes(dropLastToolEntry: dropLastToolEntry)

        // 1. ЗАДАЧА — вне конкурса за бюджет. Не влезло остальное — режется остальное.
        var task = ""
        if let index = currentTaskIndex,
           !tailIndexes.contains(index),
           !Self.sameRequest(entries[index].text, goalAlreadyStated) {
            task = "Просили: " + Self.shorten(entries[index].text, to: Self.cardTaskCharacters)
            budget -= task.count
        }

        // 2. ХВОСТ — две последние реплики дословно: с них модель продолжает разговор.
        var tail: [String] = []
        for index in tailIndexes {
            guard budget > Self.cardMinFieldCharacters else { break }
            let line = Self.tailLine(entries[index])
            guard !line.isEmpty else { continue }
            let cut = Self.shorten(line, to: min(Self.cardTailCharacters, budget))
            budget -= cut.count
            tail.append(cut)
        }

        // 3. НЕЗАКРЫТЫЙ ВОПРОС — если он не попал в хвост. Человек отвечает на него
        // одним словом, и без самого вопроса это слово прилетит в пустоту.
        var question = ""
        if let index = openQuestionIndex,
           !tailIndexes.contains(index),
           budget > Self.cardMinFieldCharacters {
            question = "Ждёт ответа: "
                + Self.shorten(entries[index].text, to: min(Self.cardQuestionCharacters, budget))
            budget -= question.count
        }

        // 4. ЧТО ВИДЕЛИ В ПАПКЕ — вместо повторного обхода за 300…600 токенов.
        var folder = ""
        if let snapshot = folderSnapshot, budget > Self.cardMinFieldCharacters {
            folder = Self.folderLine(snapshot, limit: min(Self.cardFolderCharacters, budget))
            budget -= folder.count
        }

        // 5. ЧТО УЖЕ СДЕЛАНО — по следам записей и чтений, без содержимого файлов.
        var done = ""
        let clauses = doneClauses(skipping: tailIndexes,
                                  folderShown: folder.isEmpty ? nil : folderSnapshot?.path)
        if !clauses.isEmpty, budget > Self.cardMinFieldCharacters {
            done = "Сделано: "
                + Self.shorten(clauses.joined(separator: "; "),
                               to: min(Self.cardDoneCharacters, budget))
            budget -= done.count
        }

        // Порядок на выходе — не порядок дележа бюджета: модель читает сверху вниз,
        // и первой должна увидеть задачу, а последним — то, на чём остановились.
        let head = [task, done, folder, question].filter { !$0.isEmpty }
        return (head + tail).joined(separator: "\n")
    }

    /// Пределы полей карточки в знаках. Сумма нарочно больше общего бюджета: поля
    /// делят его по очереди, и хвостовым достаётся то, что осталось.
    private static let cardTaskCharacters = 200
    private static let cardTailCharacters = 160
    private static let cardQuestionCharacters = 140
    private static let cardFolderCharacters = 260
    private static let cardDoneCharacters = 220
    /// Короче этого поле бессмысленно: останется приставка и обрывок слова.
    private static let cardMinFieldCharacters = 40
    /// Сколько имён файлов уносим в новый разговор и до скольких знаков режем каждое.
    private static let folderSnapshotNames = 20
    private static let folderNameCharacters = 40
    /// Сколько дел помещаем в поле «Сделано». Больше — и оно само станет лентой.
    private static let doneClausesLimit = 6

    /// Две последние осмысленные записи разговора, по возрастанию индекса.
    /// Системные записи в хвост не идут: инструкция уходит отдельно и целиком.
    private func tailEntryIndexes(dropLastToolEntry: Bool) -> [Int] {
        let skipIndex = dropLastToolEntry ? entries.lastIndex(where: { $0.role == .tool }) : nil
        var found: [Int] = []
        for index in entries.indices.reversed() {
            guard index != skipIndex, entries[index].role != .system else { continue }
            found.append(index)
            if found.count == 2 { break }
        }
        return found.reversed()
    }

    private static func tailLine(_ entry: Entry) -> String {
        switch entry.role {
        case .user:   return "человек: " + entry.text
        case .model:  return "агент: " + entry.text
        case .tool:   return "результат: " + entry.text
        case .system: return ""
        }
    }

    private static func folderLine(_ snapshot: FolderSnapshot, limit: Int) -> String {
        // ⚠️ «Видел», а не «лежит»: снимок сделан когда-то раньше, и за это время файл
        // могли создать из другого приложения. Врать модели о состоянии диска нельзя.
        let head = snapshot.path.isEmpty
            ? "Видел в корне проекта: "
            : "Видел в папке \(snapshot.path): "

        var shown: [String] = []
        var used = head.count
        for name in snapshot.names {
            // Имена не рвём посреди слова: обрывок имени модель попробует прочитать
            // как настоящий путь и получит отказ.
            guard used + name.count + 2 <= limit else { break }
            used += name.count + 2
            shown.append(name)
        }
        guard !shown.isEmpty else { return "" }

        var line = head + shown.joined(separator: ", ")
        let hidden = snapshot.total - shown.count
        if hidden > 0 { line += " и ещё \(hidden)" }
        return line
    }

    /// Что уже сделано — по одной короткой фразе на дело, в порядке появления.
    /// Содержимое файлов сюда не попадает никогда.
    ///
    /// `folderShown` — папка, чьи имена уже уехали отдельным полем: писать про неё
    /// второй раз «смотрел корень проекта» незачем.
    private func doneClauses(skipping tailIndexes: [Int], folderShown: String?) -> [String] {
        var order: [String] = []
        var byKey: [String: String] = [:]

        for index in entries.indices where !tailIndexes.contains(index) {
            if case .folderList(let path) = entries[index].topic, path == folderShown { continue }
            guard let (key, clause) = Self.doneClause(for: entries[index]) else { continue }
            // Ключ один на файл: три чтения одного и того же README дают одну строку,
            // а не три. Побеждает последнее — оно и описывает нынешнее состояние дел.
            if byKey[key] == nil { order.append(key) }
            byKey[key] = clause
        }

        return order.suffix(Self.doneClausesLimit).compactMap { byKey[$0] }
    }

    /// Одно дело: ключ (чтобы не повторяться) и фраза для карточки.
    private static func doneClause(for entry: Entry) -> (key: String, clause: String)? {
        switch entry.topic {
        case .fileWrite(let path, _):
            // ⚠️ Исход записи различаем по следу, а не по теме: тема у применённой
            // и у отклонённой правки одна и та же (см. приставки выше).
            if entry.text.hasPrefix(appliedWritePrefix) {
                return ("write:" + path, "записал \(path)")
            }
            if entry.text.hasPrefix(rejectedWritePrefix) {
                return ("write:" + path, "правку \(path) человек отклонил")
            }
            return ("write:" + path, "предлагал записать \(path)")
        case .fileRead(let path, let lines):
            return ("read:" + path, lines.isEmpty ? "читал \(path)" : "читал \(path) (\(lines))")
        case .folderList(let path):
            // Сюда доходят только те папки, чьи имена в карточку НЕ уехали (папку из
            // снимка отбрасывает doneClauses): про неё сказано подробнее и другим полем.
            return ("list:" + path, "смотрел \(path.isEmpty ? "корень проекта" : path)")
        case .digest:
            // Выжимка уже собрана из таких же фраз — вливаем её как есть, без приставки.
            let body = entry.text
                .replacingOccurrences(of: digestPrefix, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            guard !body.isEmpty else { return nil }
            return ("digest:" + entry.id.uuidString, body)
        case .failedAttempt(let what):
            // Из пары «кривой вызов + ошибка» берём только вызов: об одном и том же.
            guard entry.role == .model, !what.isEmpty else { return nil }
            return ("fail:" + what, "\(what) — не вышло")
        case .plain:
            // Болтовня в карточку не идёт вовсе: ради этого она и заведена.
            return nil
        }
    }

    /// Та же самая просьба человека, что уже стоит в системной инструкции.
    private static func sameRequest(_ left: String, _ right: String) -> Bool {
        let a = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    // MARK: - Оценка длины

    /// Грубая оценка: латиница ~4 символа на токен, кириллица ~2.
    /// Специально завышаем, чтобы упереться в свой предел раньше, чем в предел движка.
    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var asciiCount = 0
        var otherCount = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { asciiCount += 1 } else { otherCount += 1 }
        }
        let estimate = Double(asciiCount) / 4.0 + Double(otherCount) / 2.0
        return max(1, Int(estimate.rounded(.up)))
    }

    /// Обрезка длинного текста с многоточием — для пересказа.
    static func shorten(_ text: String, to limit: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}
