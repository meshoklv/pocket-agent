//
//  RemoteRuntime.swift
//  PocketAgent / Runtime
//
//  ТРЕТИЙ движок — работа с моделью ПО СЕТИ, по ключу человека. Реализует тот же протокол
//  ModelRuntime, что движки Google и Apple (Contracts.swift), поэтому цикл агента и экраны
//  про него ничего не знают. Образец устройства — MLXRuntime.swift: третий движок обязан
//  лечь так же, как лёг второй.
//
//  ⚠️⚠️ ЭТО ЕДИНСТВЕННОЕ МЕСТО ВО ВСЁМ ПРИЛОЖЕНИИ, ОТКУДА НАРУЖУ УХОДЯТ ФАЙЛЫ ЧЕЛОВЕКА.
//  Всё остальное приложение обещает обратное, и обещание это настоящее: местные движки
//  не умеют выходить в сеть вовсе. Поэтому здесь действуют три правила, и ни одно из них
//  не «на всякий случай»:
//    1. Движок включается ТОЛЬКО по явному решению человека (`RemoteAccessSettings.isEnabled`,
//       выключено по умолчанию), и до первого запроса он читает экран, где прямым текстом
//       написано, что именно и кому уходит.
//    2. Работа без интернета не меняется ни в чём. Выключил — приложение снова целиком
//       в телефоне, и ни одна строка отсюда не исполняется.
//    3. Ключ человека не попадает ни в журнал, ни в текст ошибки, ни в адрес запроса —
//       см. `scrubbed(_:)` и объяснение у поля `apiKey`.
//
//  ⚠️ МОДЕЛЬ НЕ ИМЕЕТ ПРАВА НИЧЕГО ВЫПОЛНЯТЬ САМА — И ЗДЕСЬ ЭТО ВЫРАЖЕНО ТЕМ ЖЕ, ЧЕМ
//  У ДВИЖКА APPLE: ОТСУТСТВИЕМ КОДА. Мы отправляем описания действий и разбираем `tool_calls`
//  из ответа, превращая их в наш `ToolInvocation`. Исполнителей действий у движка нет вовсе:
//  они живут в цикле агента и включаются ПОСЛЕ нажатия человека. Ни одной ветки, которая
//  что-то делает с файлом, в этом файле нет и быть не должно.
//
//  ⚠️ ПОЧЕМУ ОТВЕТ ЦЕЛИКОМ, А НЕ ПО ЧАСТЯМ. Ответ по частям («stream») здесь возможен,
//  но не нужен и вреден: наш ход заканчивается либо просьбой о действии, либо текстом,
//  а просьба о действии в потоке приходит по кусочкам — имя действия отдельно, аргументы
//  по буквам, — и собирать её обратно значит завести свой разборщик там, где поставщик
//  и так отдаёт готовое. Разборщик, собранный по кусочкам, ошибается молча: половина
//  аргумента теряется, и человек видит карточку «записать файл» с обрезанным содержимым.
//  Цена решения — человек видит ответ целиком, а не по словам; за это отвечает щедрый
//  предел ожидания (`requestTimeout`) и честная надпись «думает» в чате.
//
//  ⚠️ ПАМЯТЬ РАЗГОВОРА ЗДЕСЬ НАША СОБСТВЕННАЯ, В ОТЛИЧИЕ ОТ ОБОИХ МЕСТНЫХ ДВИЖКОВ.
//  У Google и Apple разговор живёт внутри библиотеки, и мы шлём только новое сообщение.
//  По сети всё наоборот: поставщик не помнит ничего, и каждый ход мы обязаны отправить
//  ВЕСЬ разговор заново. Отсюда два следствия, которые стоит помнить: (а) чем длиннее
//  задача, тем дороже каждый следующий ход; (б) сообщение с просьбой о действии обязано
//  вернуться поставщику ДОСЛОВНО таким, каким пришло, — иначе он ответит отказом.
//

import Foundation

public actor RemoteModelRuntime: ModelRuntime, ModelBackendDiagnostics, ModelRuntimeFactsProviding {

    /// Тот же журнал, что у местных движков: разбирать поломку надо по одинаковым строкам.
    private var journal: EngineJournal { EngineJournal.shared }

    // MARK: - Настройки, снятые при подготовке
    //
    // ⚠️ Снимаем их ОДИН РАЗ, при подготовке, а не читаем на каждый ход. Человек может
    // сменить модель или поставщика прямо посреди задачи; продолжать начатый разговор
    // с другой моделью — значит послать ей чужую переписку и чужие вызовы действий.
    // Смена настроек проходит через подготовку заново (EngineRouter), и там же
    // разговор начинается с чистого листа.

    private var provider: RemoteProvider = RemoteProviderDirectory.openRouter
    private var baseURL: String = ""
    private var modelID: String = ""

    /// Ключ человека в памяти процесса — ровно на время работы.
    ///
    /// ⚠️ ЕГО ЕДИНСТВЕННОЕ ЗАКОННОЕ МЕСТО — ЗАГОЛОВОК ЗАПРОСА. Ни `print`, ни журнал,
    /// ни текст ошибки, ни адрес его не видят. Всё, что уходит в журнал из этого файла,
    /// проходит через `scrubbed(_:)`: если ключ каким-то образом окажется в чужом тексте
    /// (например, поставщик вернул его в сообщении об ошибке), он будет вырезан.
    private var apiKey: String?

    // MARK: - Разговор

    /// Один ход разговора в том виде, в каком он уйдёт поставщику.
    ///
    /// ⚠️ `toolCalls` хранится ДОСЛОВНО так, как прислал поставщик. Пересобрать его
    /// «по-своему» нельзя: имена полей, порядковый номер вызова и вид аргументов
    /// поставщик сверяет со своим же ответом, и малейшее расхождение — отказ на весь ход.
    private struct StoredMessage {
        var role: String
        var content: String?
        var toolCalls: [[String: Any]]?
        var toolCallID: String?

        var json: [String: Any] {
            var out: [String: Any] = ["role": role]
            // ⚠️ Пустое содержимое у сообщения с вызовами действий — не забывчивость:
            // часть поставщиков отвергает сообщение помощника вовсе без поля `content`.
            out["content"] = content ?? ""
            if let toolCalls, !toolCalls.isEmpty { out["tool_calls"] = toolCalls }
            if let toolCallID, !toolCallID.isEmpty { out["tool_call_id"] = toolCallID }
            return out
        }
    }

    private var messages: [StoredMessage] = []
    private var toolSchemas: [[String: Any]] = []

    private var status: ModelRuntimeStatus = .idle
    private var statusListeners: [UUID: AsyncStream<ModelRuntimeStatus>.Continuation] = [:]

    private var isGenerating = false
    private var didCancelCurrentTurn = false

    /// Запрос, который идёт прямо сейчас. Нужен ровно для отмены: человек нажал «Стоп» —
    /// соединение обязано оборваться, а не висеть, тратя его деньги и его время.
    private var inFlight: Task<(Data, URLResponse), Error>?

    /// Вызовы действий, которые модель попросила СВЕРХ первого.
    ///
    /// ⚠️ Здесь это не вежливость, как у движка Apple, а ТРЕБОВАНИЕ ПОСТАВЩИКА: на каждый
    /// вызов из сообщения помощника обязан прийти ответ с тем же номером. Пропусти один —
    /// и следующий запрос вернётся отказом «незакрытый вызов действия», причём отказ этот
    /// человек увидит как загадочную поломку посреди работы.
    private var unansweredCallIDs: [String] = []

    /// Сколько слов-кусочков заняли запрос и ответ на последнем ходе. Это и есть занятое
    /// место разговора: поставщик считает его сам и присылает в каждом ответе.
    private var lastPromptTokens = 0
    private var lastAnswerTokens = 0
    private var didReceiveUsage = false

    public init() {}

    // MARK: - Статус

    public func currentStatus() async -> ModelRuntimeStatus { status }

    public func statusStream() async -> AsyncStream<ModelRuntimeStatus> {
        let (stream, continuation) = AsyncStream<ModelRuntimeStatus>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let id = UUID()
        statusListeners[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropListener(id) }
        }
        return stream
    }

    private func dropListener(_ id: UUID) { statusListeners[id] = nil }

    private func setStatus(_ newStatus: ModelRuntimeStatus) {
        guard newStatus != status else { return }
        status = newStatus
        for listener in statusListeners.values { listener.yield(newStatus) }
    }

    // MARK: - Подготовка

    /// Здесь нет ни скачивания, ни загрузки весов — «подготовка» для работы по сети это
    /// проверка того, что человек всё указал.
    ///
    /// ⚠️ СЕТИ ЗДЕСЬ НЕ КАСАЕМСЯ НАМЕРЕННО. Проверять ключ запросом на этом шаге значило бы
    /// вешать открытие приложения на чужой сервер: в самолёте человек ждал бы отката
    /// по пределу ожидания и видел бы поломку там, где он ничего не просил. Ключ
    /// проверяется на экране настройки, кнопкой, — то есть тогда, когда человек этого ждёт.
    public func prepare() async throws {
        journal.startStage(.prepare)

        guard RemoteAccessSettings.isEnabled else {
            throw PocketAgentError.remoteNotConfigured("Работа по ключу выключена.")
        }
        if let missing = RemoteAccessSettings.missingPartText {
            let error = PocketAgentError.remoteNotConfigured(missing)
            journal.recordFailure(stage: "подготовка работы по ключу",
                                  human: error.errorDescription ?? missing,
                                  technical: "не хватает настройки")
            setStatus(.failed(message: error.errorDescription ?? missing))
            throw error
        }

        setStatus(.verifying)

        provider = RemoteAccessSettings.provider
        baseURL = RemoteAccessSettings.effectiveBaseURL
        modelID = RemoteAccessSettings.modelID
        apiKey = RemoteKeyStore.key(for: provider.id)

        guard apiKey != nil else {
            let error = PocketAgentError.remoteNotConfigured("Не введён ключ доступа.")
            setStatus(.failed(message: error.errorDescription ?? ""))
            throw error
        }

        // Предел трат уже выбран — работать нечем. Говорим об этом СЕЙЧАС, а не первым
        // ходом: человек должен узнать это до того, как напишет задачу.
        if RemoteSpend.isOverLimit {
            let error = PocketAgentError.remoteSpendLimitReached(spentMicros: RemoteSpend.spentMicros,
                                                                 limitMicros: RemoteSpend.limitMicros)
            journal.record(.failure, "Предел трат достигнут — работать по ключу нечем",
                           detail: RemoteSpend.statusText)
            setStatus(.failed(message: error.errorDescription ?? ""))
            throw error
        }

        journal.noteReady(modelName: modelID,
                          fileName: provider.displayName,
                          fileSizeText: "по сети, файла нет",
                          backend: activeBackendName,
                          // Памяти разговора мы ни у кого не просим: она не наша,
                          // и просить её не у кого — честное «ничего».
                          askedTokens: nil,
                          grantedTokens: Self.remoteContextCeiling,
                          chosenTokens: ContextSizeSettings.chosenTokens,
                          stepNumber: 0,
                          stepName: "работа по ключу",
                          freeMemoryMB: MemoryGate.availableMemoryMB())
        journal.record(.engine, "Работа по ключу: \(provider.displayName), модель \(modelID)",
                       detail: "адрес: \(baseURL) · " + RemoteSpend.statusText
                             + " · файлы и задачи с этого момента уходят поставщику")
        // ⚠️ Предупреждаем ДО первого хода, а не после. Счёт деньгами присылает только
        // OpenRouter: у остальных без цены, введённой человеком, потраченное не растёт —
        // то есть предел трат не наступит никогда, сколько бы ходов ни прошло.
        if !RemoteAccessSettings.canCountMoney {
            journal.record(.failure, "Предел трат работать не будет: считать не из чего",
                           detail: "поставщик «\(provider.displayName)» стоимость не сообщает, "
                                 + "а цена модели руками не вписана · "
                                 + "вписать её можно во вкладке «Модели» → «Работа по ключу»")
        }
        setStatus(.ready)
    }

    // MARK: - Разговор

    public func beginSession(systemPrompt: String, tools: [ToolDeclaration]) async throws {
        guard apiKey != nil else { throw PocketAgentError.runtimeNotReady }

        messages = []
        unansweredCallIDs = []
        lastPromptTokens = 0
        lastAnswerTokens = 0
        didReceiveUsage = false

        if !systemPrompt.isEmpty {
            messages.append(StoredMessage(role: "system", content: systemPrompt))
        }
        toolSchemas = RemoteToolSchemas.tools(matching: tools)

        journal.record(.engine, "Начал разговор по ключу",
                       detail: "действий в наборе: \(toolSchemas.count) · "
                             + "выполнять их сама модель не может — только просить · "
                             + "поставщик: \(provider.displayName) · модель: \(modelID)")
    }

    public func send(userText: String) async throws -> ModelTurn {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PocketAgentError.generationFailed("Пустой запрос.")
        }
        // ⚠️ ЗДЕСЬ ЛЕЖИТ ГРАБЛЯ, КОТОРОЙ У МЕСТНЫХ ДВИЖКОВ НЕТ ВООБЩЕ. Прошлый ход мог
        // кончиться просьбой о действии, на которую ответа не было: человек нажал
        // «Отклонить» и сразу написал новое, задача закончилась словом `finish`, ход
        // оборвали. Местным движкам на это всё равно, а поставщик отвергает ВЕСЬ запрос,
        // в котором у вызова действия нет ответа, — и человек видит загадочную поломку
        // на ровном месте. Поэтому не выбрасываем незакрытые вызовы, а честно закрываем их.
        closeUnansweredCalls()
        messages.append(StoredMessage(role: "user", content: trimmed))
        return try await performTurn()
    }

    public func send(toolResult: ToolResult) async throws -> ModelTurn {
        // Ответ уходит модели и при отказе человека: она обязана узнать, что действие
        // не выполнено, иначе следующий шаг она построит на выдумке.
        //
        // ⚠️ НОМЕР ВЫЗОВА СВЕРЯЕМ СО СПИСКОМ, А НЕ БЕРЁМ НА ВЕРУ. Ответ с чужим или пустым
        // номером поставщик отвергает целиком, а настоящий вызов при этом остаётся
        // незакрытым — то есть один кривой номер ломает разговор насовсем. Пустой номер
        // сюда прийти может: цикл агента отвечает и на вызовы, разобранные не до конца.
        var answeredID = toolResult.callID
        if answeredID.isEmpty || !unansweredCallIDs.contains(answeredID) {
            answeredID = unansweredCallIDs.first ?? ""
        }

        if answeredID.isEmpty {
            // Отвечать не на что: незакрытых вызовов нет вовсе. Такой ответ поставщик
            // не примет (сообщение с ролью «ответ действия» без номера — ошибка),
            // поэтому отдаём его обычным сообщением. Модель прочитает то же самое.
            messages.append(StoredMessage(role: "user",
                                          content: "Итог действия: " + Self.text(of: toolResult.payload)))
            return try await performTurn()
        }

        messages.append(StoredMessage(role: "tool",
                                      content: Self.text(of: toolResult.payload),
                                      toolCallID: answeredID))

        // Отказы на лишние вызовы уходят тем же ходом. Это не вежливость — без них
        // поставщик отвергнет весь запрос (см. объяснение у `unansweredCallIDs`).
        for skipped in unansweredCallIDs where skipped != answeredID {
            messages.append(StoredMessage(role: "tool",
                                          content: Self.oneActionPerTurnNotice,
                                          toolCallID: skipped))
        }
        unansweredCallIDs = []

        return try await performTurn()
    }

    /// Закрыть все вызовы действий, оставшиеся без ответа, отказом.
    /// Пусто — ничего и не делаем: лишних сообщений в разговоре быть не должно,
    /// каждое из них человек оплачивает на КАЖДОМ следующем ходе.
    private func closeUnansweredCalls() {
        guard !unansweredCallIDs.isEmpty else { return }
        for callID in unansweredCallIDs {
            messages.append(StoredMessage(role: "tool",
                                          content: Self.notDoneNotice,
                                          toolCallID: callID))
        }
        unansweredCallIDs = []
    }

    /// Что отвечаем на вызов, до которого дело так и не дошло.
    private static let notDoneNotice =
        "Это действие не выполнено — человек его не подтвердил или задача пошла дальше."

    private static let oneActionPerTurnNotice =
        "За один ход выполняется ровно одно действие. Это действие не выполнено — "
        + "повтори его следующим ходом, если оно всё ещё нужно."

    /// Тело ответа действия — строкой для модели. Устроено так же, как у движка Apple:
    /// простой текст уходит как есть, список и набор полей — как JSON.
    private static func text(of payload: ToolPayload) -> String {
        if case .text(let value) = payload { return value }
        let object = payload.jsonObject
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return payload.plainText
    }

    // MARK: - Один ход

    private func performTurn() async throws -> ModelTurn {
        guard let key = apiKey else { throw PocketAgentError.sessionNotStarted }
        guard !isGenerating else {
            throw PocketAgentError.generationFailed("Предыдущий ответ ещё не готов.")
        }

        // ⚠️ ПРЕДЕЛ ТРАТ ПРОВЕРЯЕТСЯ ПЕРЕД КАЖДЫМ ЗАПРОСОМ, А НЕ ПОСЛЕ. Проверка «после»
        // означала бы, что последний запрос всё равно ушёл и деньги всё равно списаны.
        if RemoteSpend.isOverLimit {
            let error = PocketAgentError.remoteSpendLimitReached(spentMicros: RemoteSpend.spentMicros,
                                                                 limitMicros: RemoteSpend.limitMicros)
            journal.record(.failure, "Ход не отправлен: достигнут предел трат",
                           detail: RemoteSpend.statusText)
            throw error
        }

        isGenerating = true
        didCancelCurrentTurn = false
        defer { isGenerating = false; inFlight = nil }

        journal.startStage(.turn)

        let body = requestBody()
        let data = try await sendWithRetries(body: body, key: key)

        if didCancelCurrentTurn {
            didCancelCurrentTurn = false
            throw PocketAgentError.generationCancelled
        }

        return try interpret(data)
    }

    /// Тело запроса — общепринятого вида, тот же у всех поставщиков.
    private func requestBody() -> [String: Any] {
        var body: [String: Any] = [
            "model": modelID,
            "messages": messages.map(\.json),
            // Те же числа, что у местных движков: агенту нужна предсказуемость,
            // а не творчество. Разъедься они — поведение движков разошлось бы.
            "temperature": 0.2,
            "top_p": 0.95,
            "stream": false
        ]
        if !toolSchemas.isEmpty {
            body["tools"] = toolSchemas
            // Именно `auto`: модель вправе ответить и словами. Почему — в шапке
            // RemoteToolSchemas.swift.
            body["tool_choice"] = "auto"
        }
        if provider.reportsCost {
            // Просим прислать стоимость запроса деньгами. Понимает это не всякий
            // поставщик, поэтому просим только у того, про кого это известно, —
            // лишнее поле часть служб считает ошибкой и отвечает отказом на весь запрос.
            body["usage"] = ["include": true]
        }
        return body
    }

    // MARK: - Сеть

    /// Своя сессия: без кэша и без печенья, с щедрым пределом ожидания.
    ///
    /// ⚠️ ПРЕДЕЛ ОЖИДАНИЯ ЗДЕСЬ НАМЕРЕННО БОЛЬШОЙ. Это не загрузка картинки: модель
    /// думает над задачей десятки секунд, и обрыв «по таймауту» на сороковой секунде
    /// означал бы, что деньги человека потрачены, а ответ выброшен.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = true
        // ⚠️ Имя типа впереди обязательно: это замыкание, а не тело метода, — свой же
        // статический сосед здесь коротким именем не виден.
        config.timeoutIntervalForRequest = RemoteModelRuntime.requestTimeout
        config.timeoutIntervalForResource = RemoteModelRuntime.requestTimeout * 2
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    private static let requestTimeout: TimeInterval = 120

    /// Сколько раз повторяем неудачный запрос. Три попытки всего.
    ///
    /// ⚠️ ПОВТОРЯЕМ ДАЛЕКО НЕ ВСЁ. Обрыв связи, «слишком часто» и поломка на стороне
    /// поставщика — да: это ничего не стоит и почти всегда помогает. Отказ по ключу
    /// или по деньгам — никогда: повтор не изменит ответа, а человек лишние секунды
    /// смотрел бы в крутящийся кружок вместо объяснения.
    private static let maxAttempts = 3

    private func sendWithRetries(body: [String: Any], key: String) async throws -> Data {
        var lastError: Error = PocketAgentError.remoteRequestFailed(
            "Не удалось отправить запрос. Проверьте связь и повторите."
        )

        for attempt in 1...Self.maxAttempts {
            if didCancelCurrentTurn || Task.isCancelled {
                throw PocketAgentError.generationCancelled
            }
            do {
                return try await sendOnce(body: body, key: key, attempt: attempt)
            } catch let error as PocketAgentError {
                // Наши разобранные отказы: часть из них повторять бессмысленно.
                guard Self.isWorthRetrying(error) else { throw error }
                lastError = error
            } catch is CancellationError {
                throw PocketAgentError.generationCancelled
            } catch let error as URLError {
                if error.code == .cancelled { throw PocketAgentError.generationCancelled }
                lastError = PocketAgentError.remoteRequestFailed(SystemErrorText.russian(for: error))
            } catch {
                lastError = PocketAgentError.remoteRequestFailed(SystemErrorText.russian(for: error))
            }

            guard attempt < Self.maxAttempts else { break }
            let pause = UInt64(attempt) * 1_500_000_000  // 1,5 с, затем 3 с
            journal.record(.note, "Повторяю запрос к поставщику (попытка \(attempt + 1) из \(Self.maxAttempts))",
                           detail: scrubbed(SystemErrorText.russian(for: lastError)))
            try? await Task.sleep(nanoseconds: pause)
        }

        journal.recordFailure(stage: "ход по ключу",
                              human: SystemErrorText.russian(for: lastError),
                              technical: scrubbed(RuntimeJournal.technicalText(for: lastError)))
        throw lastError
    }

    private static func isWorthRetrying(_ error: PocketAgentError) -> Bool {
        switch error {
        case .remoteBusy, .remoteServerBroken:
            return true
        case .remoteRequestFailed:
            return true
        default:
            // Ключ не принят, предел трат, кривой адрес, отказ по существу запроса —
            // повтор ничего не изменит.
            return false
        }
    }

    /// Одна попытка: собрать запрос, отправить, разобрать код ответа.
    private func sendOnce(body: [String: Any], key: String, attempt: Int) async throws -> Data {
        guard let url = URL(string: baseURL + "/chat/completions") else {
            throw PocketAgentError.remoteBadAddress(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ⚠️ ВОТ ЕДИНСТВЕННОЕ МЕСТО, ГДЕ КЛЮЧ ПОКИДАЕТ ЗАЩИЩЁННОЕ ХРАНИЛИЩЕ.
        // Заголовок, и только заголовок: в адресе ключа нет и быть не может — адрес
        // попадает и в системный журнал телефона, и в текст почти любой сетевой ошибки.
        let auth = provider.auth.header(for: key)
        request.setValue(auth.value, forHTTPHeaderField: auth.name)
        for (name, value) in provider.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        // Запрос идёт отдельной задачей — иначе его нечем отменить: «Стоп» человека
        // обязан оборвать соединение, а не ждать ответа, за который уже заплачено.
        let task = Task { try await Self.session.data(for: request) }
        inFlight = task
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await task.value
        } catch {
            if didCancelCurrentTurn { throw PocketAgentError.generationCancelled }
            throw error
        }
        inFlight = nil

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { return data }

        // Разбираем отказ: поставщики кладут человеческую причину в `error.message`.
        let reason = Self.errorMessage(in: data)
        journal.record(.failure, "Поставщик отказал (\(code)), попытка \(attempt)",
                       detail: scrubbed(reason ?? "тело ответа пустое"))

        switch code {
        case 401, 403:
            throw PocketAgentError.remoteKeyRejected
        case 402:
            throw PocketAgentError.remoteOutOfFunds
        case 404:
            throw PocketAgentError.remoteModelUnknown(modelID)
        case 429:
            throw PocketAgentError.remoteBusy
        case 500...599:
            throw PocketAgentError.remoteServerBroken
        default:
            throw PocketAgentError.remoteRequestFailed(
                "Поставщик отказался выполнять запрос" + (reason.map { ": \(scrubbed($0))" } ?? ".")
            )
        }
    }

    /// Человеческая причина отказа из ответа поставщика. Формы разные, поэтому
    /// смотрим по очереди все известные.
    private static func errorMessage(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(400), encoding: .utf8)
        }
        if let error = root["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            if let message = error["msg"] as? String { return message }
        }
        if let message = root["message"] as? String { return message }
        return String(data: data.prefix(400), encoding: .utf8)
    }

    // MARK: - Разбор ответа

    private func interpret(_ data: Data) throws -> ModelTurn {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PocketAgentError.remoteRequestFailed(
                "Поставщик прислал ответ, который не удалось разобрать. Повторите ход."
            )
        }

        noteUsage(root["usage"] as? [String: Any])

        let choices = root["choices"] as? [[String: Any]] ?? []
        guard let message = choices.first?["message"] as? [String: Any] else {
            journal.record(.turn, "Поставщик ответил без единого варианта ответа")
            return .text("")
        }

        let text = (message["content"] as? String) ?? ""
        var rawCalls = message["tool_calls"] as? [[String: Any]] ?? []

        // ⚠️ Номер вызова бывает пустым — а ответ на действие без номера поставщик
        // не примет. Проставляем свой и запоминаем сообщение помощника УЖЕ С НИМ:
        // тогда и наш ответ, и его вызов ссылаются на одно и то же.
        for index in rawCalls.indices {
            let id = rawCalls[index]["id"] as? String ?? ""
            if id.isEmpty { rawCalls[index]["id"] = "call_\(UUID().uuidString.prefix(8))" }
        }

        if rawCalls.isEmpty {
            messages.append(StoredMessage(role: "assistant", content: text))
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                journal.record(.turn, "Модель ответила пусто")
            } else {
                journal.noteModelAnswerText(clean)
            }
            return .text(clean)
        }

        // Сообщение помощника возвращается поставщику дословно — вместе со всеми вызовами,
        // включая те, которые мы выполнять не станем.
        messages.append(StoredMessage(role: "assistant", content: text, toolCalls: rawCalls))

        // Берём ТОЛЬКО первый вызов: один шаг — одно подтверждение. Остальные обязаны
        // получить ответ следующим ходом (иначе поставщик отвергнет весь запрос).
        unansweredCallIDs = rawCalls.compactMap { $0["id"] as? String }

        let first = rawCalls[0]
        let function = first["function"] as? [String: Any] ?? [:]
        let name = function["name"] as? String ?? ""
        let callID = first["id"] as? String ?? ""

        let invocation = ToolInvocation(rawName: name,
                                        callID: callID,
                                        // ⚠️ Аргументы приходят СТРОКОЙ с JSON внутри —
                                        // так устроен общепринятый вид ответа. Разбираем
                                        // её и отдаём в ЕДИНСТВЕННУЮ точку приведения
                                        // к строкам из Contracts.swift — ту же самую,
                                        // что работает для обоих местных движков.
                                        rawArguments: Self.arguments(in: function))
        journal.noteToolInvocation(invocation, concurrentCalls: rawCalls.count)
        return .toolRequest(invocation)
    }

    /// Разбор аргументов действия.
    ///
    /// ⚠️ Кривой JSON здесь НЕ ошибка хода. Модель, особенно недорогая, регулярно шлёт
    /// оборванную строку аргументов. Уроним ход — человек увидит поломку; отдадим пустые
    /// аргументы — цикл агента честно ответит модели «не хватает параметра», и она
    /// повторит вызов. Второе дешевле для всех.
    private static func arguments(in function: [String: Any]) -> [String: Any] {
        if let object = function["arguments"] as? [String: Any] { return object }
        guard let text = function["arguments"] as? String,
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return parsed
    }

    // MARK: - Деньги

    /// Записать, во что обошёлся ход.
    ///
    /// ⚠️ ДВА РАЗНЫХ ЧИСЛА, И ПУТАТЬ ИХ НЕЛЬЗЯ. Если поставщик прислал СТОИМОСТЬ —
    /// это счёт, и мы кладём его как есть. Если не прислал — считаем сами по числу
    /// слов-кусочков и цене модели, и помечаем сумму как прикидку: на экране человек
    /// увидит «потрачено примерно». Выдать прикидку за счёт — то же самое, что соврать
    /// про деньги.
    private func noteUsage(_ usage: [String: Any]?) {
        guard let usage else {
            // ⚠️ ХОД БЕЗ ОТЧЁТА — ЭТО НЕ «БЕСПЛАТНЫЙ ХОД». Раньше здесь не росло ничего:
            // ни деньги, ни пометка, — и человек после десятка платных ходов видел
            // «Потрачено 0,00 $» и был уверен, что предел трат его бережёт. Считать
            // деньги тут не из чего (числа слов-кусочков поставщик не прислал), но
            // молчать нельзя: помечаем ход как непосчитанный, экран это покажет.
            RemoteSpend.noteUncountedTurn()
            journal.record(.turn, "Ход по ключу закончен, но в деньги не посчитан",
                           detail: "поставщик не прислал ни счёта, ни числа слов-кусочков · "
                                 + "предел трат на этот ход не подействовал · "
                                 + RemoteSpend.statusText)
            journal.noteTurnFinished(engineTokens: nil,
                                     limitTokens: Self.remoteContextCeiling,
                                     stepNumber: 0,
                                     stepName: "работа по ключу")
            return
        }

        lastPromptTokens = (usage["prompt_tokens"] as? Int) ?? (usage["input_tokens"] as? Int) ?? 0
        lastAnswerTokens = (usage["completion_tokens"] as? Int) ?? (usage["output_tokens"] as? Int) ?? 0
        didReceiveUsage = lastPromptTokens > 0 || lastAnswerTokens > 0

        var costText = "поставщик цену не сообщил"

        if let cost = Self.dollars(usage["cost"]) ?? Self.dollars((usage["cost_details"] as? [String: Any])?["upstream_inference_cost"]) {
            let micros = Int((cost * 1_000_000).rounded())
            RemoteSpend.add(micros: micros, isEstimate: false)
            costText = "стоил \(RemoteSpend.money(micros)) (счёт поставщика)"
        } else if let micros = estimatedMicros() {
            RemoteSpend.add(micros: micros, isEstimate: true)
            costText = "стоил примерно \(RemoteSpend.money(micros)) (наша прикидка по токенам)"
        } else {
            // Ни счёта, ни цены. Молчать нельзя: предел трат на этот ход не подействовал,
            // и человек обязан это видеть — и в журнале, и на экране.
            RemoteSpend.noteUncountedTurn()
            costText = "цену узнать не у кого — ни поставщик, ни человек её не назвали"
        }

        journal.record(.turn, "Ход по ключу закончен",
                       detail: "слов-кусочков: запрос \(lastPromptTokens), ответ \(lastAnswerTokens) · "
                             + costText + " · " + RemoteSpend.statusText)

        if RemoteSpend.isOverLimit {
            journal.record(.failure, "Предел трат достигнут — следующий ход не пойдёт",
                           detail: RemoteSpend.statusText
                                 + " · поднять предел можно во вкладке «Модели» → «Работа по ключу»")
        }
    }

    /// Прикидка стоимости по числу слов-кусочков и цене модели.
    /// nil — цены нет ни от поставщика, ни от человека, и выдумывать её мы не будем.
    private func estimatedMicros() -> Int? {
        let promptPrice = RemoteAccessSettings.manualPromptPricePerMillion
        let answerPrice = RemoteAccessSettings.manualAnswerPricePerMillion
        guard promptPrice > 0 || answerPrice > 0 else { return nil }

        let dollars = Double(lastPromptTokens) / 1_000_000 * promptPrice
                    + Double(lastAnswerTokens) / 1_000_000 * answerPrice
        return max(0, Int((dollars * 1_000_000).rounded()))
    }

    /// Стоимость приходит то числом, то строкой.
    private static func dollars(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let text = raw as? String { return Double(text) }
        return nil
    }

    // MARK: - Отмена и завершение

    public func cancelTurn() async {
        didCancelCurrentTurn = true
        // Обрываем соединение, а не ждём ответа: человек нажал «Стоп», и продолжать
        // тратить его деньги на ответ, который никто не увидит, незачем.
        inFlight?.cancel()
        inFlight = nil
    }

    public func endSession() async {
        messages = []
        toolSchemas = []
        unansweredCallIDs = []
        lastPromptTokens = 0
        lastAnswerTokens = 0
        didReceiveUsage = false
        isGenerating = false
    }

    /// «Выгрузить из памяти» здесь означает забыть разговор и ключ: весов в памяти нет.
    public func unload() async {
        if apiKey != nil {
            journal.record(.engine, "Работа по ключу остановлена",
                           detail: "разговор забыт, ключ убран из памяти · " + RemoteSpend.statusText)
        }
        inFlight?.cancel()
        inFlight = nil
        await endSession()
        // Ключ в памяти процесса не держим дольше нужного: понадобится — прочитаем
        // из защищённого хранилища заново.
        apiKey = nil
        setStatus(.idle)
    }

    public func usedTokens() async -> Int? {
        // ⚠️ nil, пока поставщик не прислал ни одного отчёта, — и это ВАЖНО.
        // Цикл агента спрашивает занятое сразу после начала разговора, чтобы замерить
        // цену служебной шапки. Ответь мы нулём — он записал бы «шапка бесплатна»,
        // хотя на самом деле мы её просто ещё не отправляли.
        didReceiveUsage ? lastPromptTokens + lastAnswerTokens : nil
    }

    /// Потолок памяти разговора для работы по сети.
    ///
    /// ⚠️ ЧЕСТНО: НАСТОЯЩЕГО ОКНА МОДЕЛИ МЫ НЕ ЗНАЕМ. Поставщик его сообщает не всегда,
    /// а у разных моделей одного поставщика оно разное — от восьми тысяч до миллиона.
    /// Взять большое число и ошибиться значит получить отказ посреди задачи; взять
    /// маленькое — сворачивать разговор чаще, чем нужно.
    ///
    /// Берём 32 000 — столько же, сколько человек может выбрать для местной модели.
    /// Здесь у этого числа есть и второй смысл, денежный: по сети ВЕСЬ разговор уходит
    /// заново каждым ходом, поэтому длина разговора — это прямая цена задачи. Потолок,
    /// после которого приложение сворачивает переписку, работает заодно и как защита
    /// кошелька, а не только памяти.
    static let remoteContextCeiling = 32_000

    public func contextLimitTokens() async -> Int { Self.remoteContextCeiling }

    // MARK: - Жизнь приложения

    /// Приложение ушло в фон. ⚠️ В отличие от местных движков, обрывать ход ЗДЕСЬ НЕЛЬЗЯ
    /// было бы соблазнительно — но нельзя и обратное: незавершённый сетевой запрос система
    /// всё равно оборвёт, а деньги за него уже списаны. Поэтому ведём себя как остальные:
    /// прекращаем ход, чтобы не показать человеку ответ на задачу, о которой он забыл.
    public func handleEnteredBackground() async {
        await cancelTurn()
    }

    /// Память нам не нужна: весов в телефоне нет. Разговор бросать не станем — он занимает
    /// килобайты, а его потеря стоит человеку денег на восстановление.
    public func handleMemoryWarning() async {}

    // MARK: - Диагностика

    /// На чём считает модель. Не видеочип и не процессор — чужой сервер, и говорить
    /// об этом надо прямо: «GPU» здесь было бы враньём, а «—» — умолчанием.
    public private(set) var activeBackendName: String = "по сети"

    public func backendName() async -> String { activeBackendName }
    public func isAccelerationDisabled() async -> Bool { false }
    public func enableAccelerationAgain() async {}

    public func runtimeFacts() async -> ModelRuntimeFacts {
        ModelRuntimeFacts(isLoaded: apiKey != nil,
                          modelName: modelID.isEmpty ? "—" : modelID,
                          fileName: provider.displayName,
                          // Файла нет вовсе — ноль здесь означает «размер неизвестен»,
                          // и экран честно не показывает никакого размера.
                          byteSize: 0,
                          backendName: activeBackendName)
    }

    // MARK: - Защита ключа

    /// Вырезать ключ из любого текста, который собирается в журнал.
    ///
    /// ⚠️ ЗАЧЕМ ЭТО, ЕСЛИ КЛЮЧ И ТАК НИКУДА НЕ ПИШЕТСЯ. Затем, что в журнал уходят чужие
    /// тексты: сообщение об ошибке от поставщика и разбор системной ошибки. Поставщик
    /// вправе вернуть в тексте отказа что угодно, включая присланный ему ключ («invalid
    /// api key: sk-…»). Журнал у нас пишет всё подряд и уходит в буфер обмена одной
    /// кнопкой — то есть такой текст уехал бы вместе с ним. Здесь ключ вырезается
    /// независимо от того, кто и как его туда положил.
    private func scrubbed(_ text: String) -> String {
        guard let key = apiKey, key.count >= 8 else { return text }
        var out = text.replacingOccurrences(of: key, with: "«ключ скрыт»")
        // Часть служб возвращает ключ обрезанным («sk-or-v1-abcd…»). Вырезаем и начало.
        let head = String(key.prefix(12))
        if head.count >= 8 {
            out = out.replacingOccurrences(of: head, with: "«ключ скрыт»")
        }
        return out
    }
}

// MARK: - Имя из задания

/// В задании движок назван RemoteRuntime, в коде — RemoteModelRuntime (ровно как у двух
/// прежних: LiteRTRuntime/LiteRTModelRuntime и MLXRuntime/MLXModelRuntime).
public typealias RemoteRuntime = RemoteModelRuntime
