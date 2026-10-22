//
//  LlamaRuntime.swift
//  PocketAgent / Runtime
//
//  Четвёртый движок — llama.cpp (GGUF). Реализует тот же протокол ModelRuntime,
//  что и движки Google / Apple / работа по ключу, поэтому цикл агента и экраны
//  про него ничего не знают.
//
//  ⚠⚠⚠ СЧИТАЕТСЯ ТОЛЬКО ФОРК PRISMML, И ЭТО НЕ ПАРАНОЙЯ, А ФАКТ РАЗВЕДКИ.
//  Модель Bonsai 2 27B идёт в GGUF-квантовании PTQ1_0 (и PQ2_0), которого в СТОКОВОМ
//  llama.cpp НЕТ: стоковая сборка грузит файл молча и выдаёт мусор — ни ошибки,
//  ни падения, просто бессмысленные ответы. Поэтому весь C-код здесь стоит за
//  `#if canImport(LlamaBonsai)` и связывается ТОЛЬКО с shim-пакетом LlamaBonsai
//  (`@_exported import llama`), за которым стоит форк PrismML
//  (github.com/PrismML-Eng/llama.cpp). Стоковый бинарь, подменённый под наш shim,
//  дал бы ровно тот «тихий мусор» — поэтому формат файла дополнительно проверяем
//  своими руками ДО загрузки (`readGGUFHeader`), а после загрузки пишем в журнал
//  поля метаданных, чтобы «запустилось» и «работает» не путались ни в журнале,
//  ни в разборе поломки.
//
//  ⚠️ ГЛАВНОЕ РЕШЕНИЕ ПРОДУКТА ПОВТОРЯЕТ ДВИЖОК APPLE (Runtime/MLXRuntime.swift):
//  у этого движка НЕТ обработчика действий и НЕТ пути выполнить их самому.
//  Всё, что модель просит, доходит сюда текстом и уходит наверх как ModelTurn;
//  запись файла без карточки «до и после» и нажатия человека невозможна ПО
//  ПОСТРОЕНИЮ — здесь физически нет строчки, которая могла бы её сделать.
//
//  ⚠️ ШАБЛОН РАЗГОВОРА ВЁРСТАЕМ САМИ (ChatML + секция инструментов в стиле
//  Hermes/Qwen). Причина: через C-API llama.cpp Jinja-шаблон из GGUF сам не
//  применяется, а Bonsai 2 — переобученная Qwen3.8, то есть ChatML
//  (`<|im_start|>` / `<|im_end|>`) с вызовами действий в `<tool_call>{json}</tool_call>`.
//  Верстаем РОВНО то, что модель видела при обучении; имена инструментов и их
//  описания — те же ToolDeclaration, что уходят движку Apple: один контракт
//  имён на всё приложение.
//
//  ⚠️ МЫШЛЕНИЕ МОДЕЛИ ОБРЕЗАЕМ. Bonsai 2 унаследовала у Qwen3.8 режим «думания»
//  (`<think>…</think>`). Это строительные леса, а не ответ: человеку в ленту они
//  не нужны, а цикл агента принял бы их за финальный текст. Полный блок снимаем
//  до разбора вызовов; оборванный `<think>` без закрытия приравниваем к пустому
//  ходу — цикл сам попросит модель повторить (invalidTurnStreak).
//
//  ⚠️ БЛОКИРУЮЩИЕ ВЫЗОВЫ C-API УХОДЯТ В ОТДЕЛЬНУЮ ЗАДАЧУ. Загрузка весов и декод
//  занимают секунды-минуты; внутри актора они заблокировали бы его исполнитель,
//  и `cancelTurn()` не смог бы выполниться — флаг отмены просто некому было бы
//  выставить. Поэтому вся тяжёлая работа идёт в `Task.detached` и общается
//  с актором через `TurnBox` (замок + снимок значений), а сам актор на время
//  хода СПИТ на `await` — и нажатие «Стоп» доходит до цикла декода мгновенно.
//  Обратная сторона: пока ход идёт, освобождать веса НЕЛЬЗЯ (free() под живым
//  декодом — это use-after-free). Отложенная выгрузка — `pendingRelease`.
//
//  ⚠️ ПРОВЕРКА ЭТОГО ФАЙЛА ТОЛЬКО НА ЖИВОМ ТЕЛЕФОНЕ — как у движка Apple.
//  Реальный формат вызовов действий Bonsai 2 никем не подтверждён (замер
//  20.09.2026: «вызов инструментов совсем не работает» — issue #6 у вендора),
//  поэтому верстка и разбор ниже — обоснованная гипотеза, которую первый живой
//  прогон либо подтвердит, либо поправит.
//

import Foundation

#if canImport(LlamaBonsai)
import LlamaBonsai
#endif

public actor LlamaModelRuntime: ModelRuntime, ModelBackendDiagnostics, ModelRuntimeFactsProviding {

    /// Куда пишем события — тот же журнал, что у остальных движков:
    /// человек копирует его одной кнопкой и разбирает поломку по одинаковым строкам.
    private var journal: EngineJournal { EngineJournal.shared }

    // MARK: - Где лежит модель

    /// Файл GGUF, который движок должен поднять. Задаётся снаружи или берётся
    /// из выбора человека (`ModelSpec`) в `prepare()` — сверх выбора движок модель
    /// НЕ ИЩЕТ: подставить соседний файл вместо заказанного нельзя.
    private var modelFileURL: URL?

    /// Имя модели для человека и её размер — то, что показывает экран «О программе».
    private var modelDisplayName: String = "—"
    private var modelByteSize: Int64 = 0

    // MARK: - Состояние

    private var status: ModelRuntimeStatus = .idle
    private var statusListeners: [UUID: AsyncStream<ModelRuntimeStatus>.Continuation] = [:]

    private var systemPrompt: String = ""
    /// Системную инструкцию в разговор уже подставили (первым сообщением).
    private var didSendSystemPrompt = false

    /// Действия, объявленные этому разговору (уже отфильтрованные по нашим именам).
    /// Пустой список — законный случай: человек выключил действия, и верстать
    /// секцию инструментов нельзя, иначе модель будет звать то, чего ей не показывали.
    private var tools: [ToolDeclaration] = []

    /// Вся переписка разговора в порядке отправки — из неё верстается промпт.
    private var messages: [TurnMessage] = []

    /// Номер разговора. endSession() инкрементирует; ход, начатый в прежнем
    /// разговоре, по этому числу видит, что его история отменена, и не тащит
    /// результаты в новую жизнь (иначе endSession посреди хода «воскресил» бы
    /// старую переписку в момент завершения хода).
    private var sessionEpoch = 0

    #if canImport(LlamaBonsai)
    /// Весовые указатели llama.cpp. Живут до выгрузки.
    /// ⚠️ free() — ТОЛЬКО из `releaseWeights()`; под живым ходом он сам отложит
    /// освобождение (инвариант у его объявления — единственное место, где решается).
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    // Выборщик слов в их заголовке — НЕ непрозрачный указатель, а указатель на
    // структуру: Swift импортирует его иначе, чем model/ctx (проверено сборкой).
    private var smpl: UnsafeMutablePointer<llama_sampler>?
    #endif

    /// Реальный потолок памяти разговора (n_ctx), выделенный при загрузке.
    /// 0 — модель ещё не поднята. Отдаётся в `contextLimitTokens()` как есть.
    private var nCtx = 0

    /// Сколько токенов сейчас в KV-кэше (наш n_past): префикс промпта + сгенерированное.
    private var nPast = 0

    /// Промпт-текст, УЖЕ лежащий в KV-кэше. Следующий ход достраивает разговор
    /// только суффиксом — префикс (система + вся история) не пересчитывается
    /// на каждом шаге. Расхождение текста и кэша (отмена, сбой, новый разговор)
    /// обнуляет его: следующий ход честно пересчитывает всё с нуля.
    private var kvPromptText = ""

    private var isPreparing = false
    private var isGenerating = false

    /// Текущий ход прерван («Стоп», уход в фон, выгрузка).
    private var didCancelCurrentTurn = false

    /// Box идущего СЕЙЧАС хода. cancelTurn() дёргает его флаг — это единственная
    /// дорога, по которой «Стоп» доходит до цикла декода, работающего вне актора.
    private var liveBox: TurnBox?

    /// Система попросила освободить память, пока мы поднимали веса.
    private var unloadRequested = false

    /// Вес освободить ПРОСИЛИ, но ход ещё идёт — отпускаем сразу после его конца.
    private var pendingRelease = false

    /// Действий за прошлый ход было больше одного — при ответе на первый вызов
    /// сообщим модели отказом и про остальные, чтобы она не считала их выполненными.
    private var extraCallsLastTurn = 0

    /// На чём считает движок. Metal вшит в бинарный пакет (решение shim-шага),
    /// мы бэкенд НЕ выбираем — поэтому пишем честное имя, а не «GPU».
    public private(set) var activeBackendName: String = "—"

    /// Оценка KV-кэша на ОДИН токен, в килобайтах. Bonsai 2 27B: ~48 слоёв, GQA
    /// (8 KV-голов по 128) → K+V ≈ 4 КБ/токен/слой → ~196 КБ/токен. Берём 256 —
    /// с запасом, если у конкретной сборки голов/слоёв больше ожидания.
    /// ⚠️ Это ОЦЕНКА для выбора n_ctx ДО загрузки, а не замер.
    private static let kvKBPerToken = 256

    /// Границы скромного контекста. Потолок 8192 — чтобы даже на «пустом» телефоне
    /// не раздувать KV-кэш до гигабайт; пол 1024 — ниже этого разговор агента
    /// (система + секция инструментов + история) физически не помещается.
    private static let minCtxTokens = 1024
    private static let maxCtxTokens = 8192

    /// Запас сверх весов файла (МБ) при выборе n_ctx: буферы вычислений, сэмплер,
    /// сам процесс. Опора — живой замер владельца на Bonsai 1 (файл 3,9 ГБ →
    /// пик 5,2 ГБ: накладные ~1,3 ГБ); берём 1,5 ГБ с округлением вверх.
    private static let computeOverheadMB = 1536

    /// Сколько токенов за один llama_decode отдаём максимум — пиковый расход
    /// памяти на батч префила остаётся предсказуемым.
    private static let decodeBatchTokens = 256

    /// Запас токенов между занятым KV-кэшем и потолком — на конец сообщения
    /// (`<|im_end|>`) и округление батча.
    private static let ctxMarginTokens = 8

    public init(modelFileURL: URL? = nil) {
        self.modelFileURL = modelFileURL
        if let modelFileURL {
            self.modelDisplayName = modelFileURL.lastPathComponent
            self.modelByteSize = (try? FileManager.default.attributesOfItem(
                atPath: modelFileURL.path)[.size] as? Int64) ?? 0
        }
    }

    /// Сказать движку, с каким файлом работать. Смена файла сбрасывает загруженные
    /// веса: две модели сразу телефон не держит (то же правило, что у движка Apple).
    ///
    /// ⚠️ Под ЖИВЫМ ходом смена файла безопасна: освобождение идёт через
    /// `releaseWeights()`, а он под идущим ходом free() не зовёт — отменяет ход и
    /// откладывает освобождение до его конца. Подъехавший следом `prepare()` сам
    /// дождётся конца хода и поднимет уже новый файл (см. `prepareLlama`).
    public func use(modelFile url: URL, displayName: String? = nil, byteSize: Int64 = 0) async {
        if modelFileURL != url {
            journal.record(.engine, "Меняю GGUF-модель — прежнюю выгружаю из памяти")
            await releaseWeights()
        }
        modelFileURL = url
        modelDisplayName = displayName ?? url.lastPathComponent
        modelByteSize = byteSize
    }

    /// Сказать движку, какую модель из справочника он должен поднять, когда её файла
    /// у выбора человека ещё нет (человек выбрал модель из каталога, скачивание
    /// впереди). По образцу `MLXModelRuntime.use(pendingModel:)`.
    ///
    /// ⚠️ Без этого вызова выбор каталога до движка не доезжал бы вовсе: `prepare`
    /// выходил бы рано по «уже готов» и молча работал бы с ПРЕЖНИМ файлом — человек
    /// жал «Скачать», а приложение продолжало отвечать старой моделью.
    ///
    /// ⚠️ Параметр назван `descriptor`, а не `model`, не по вкусу: внутри актора
    /// `model` — указатели весов, и одноимённый параметр их затенял бы.
    public func use(pendingModel descriptor: ModelDescriptor) async {
        // Файлу другого вида здесь делать нечего: скачивание .litertlm — путь
        // движка Google, .mlx — путь движка Apple.
        guard ModelFileFormat.detect(fileName: descriptor.fileName) == .gguf else { return }
        // Уже работаем с файлом именно этой модели? Тогда ничего не трогаем: лишняя
        // выгрузка — лишние минуты загрузки того же самого.
        if let current = modelFileURL,
           current.lastPathComponent == descriptor.fileName,
           descriptor.byteSize <= 0 || ModelStorage.byteSize(of: current) == descriptor.byteSize {
            modelDisplayName = descriptor.displayName
            modelByteSize = descriptor.byteSize
            return
        }
        #if canImport(LlamaBonsai)
        if model != nil {
            journal.record(.engine, "Меняю GGUF-модель — прежнюю выгружаю из памяти")
            await releaseWeights()
        }
        #endif
        modelFileURL = nil
        modelDisplayName = descriptor.displayName
        modelByteSize = descriptor.byteSize
    }

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

    private func dropListener(_ id: UUID) {
        statusListeners[id] = nil
    }

    private func setStatus(_ newStatus: ModelRuntimeStatus) {
        guard newStatus != status else { return }
        status = newStatus
        for listener in statusListeners.values {
            listener.yield(newStatus)
        }
    }

    // MARK: - Подъём модели

    public func prepare() async throws {
        #if canImport(LlamaBonsai)
        try await prepareLlama()
        #else
        // Пакет в этой сборке не подключён. Это состояние сборки, а не поломка
        // модели — спокойная человеческая фраза, а не «повреждённый файл».
        throw PocketAgentError.generationFailed(Self.engineNotConnectedText)
        #endif
    }

    private static let engineNotConnectedText =
        "Движок для GGUF-моделей в этой сборке ещё не подключён. "
            + "Используйте модель другого формата."

    #if canImport(LlamaBonsai)
    private func prepareLlama() async throws {
        guard !isPreparing else { return }

        // ⚠️ ХОД ЕЩЁ СЧИТАЕТСЯ — СНАЧАЛА ДОЖДАТЬСЯ ЕГО КОНЦА. Отмена доходит до
        // цикла декода мгновенно, но это не «стоп-кран»: фоновая задача доскончивает
        // текущую итерацию, а ход завершается в акторе чуть позже. Грузить новые
        // веса до этого нельзя по двум причинам: «уже готов» вернул бы прежнюю
        // модель, а freeing старых весов под живым декодом — это use-after-free
        // (см. инвариант у `releaseWeights`). Ожидание — сон по 50 мс, за которые
        // актор успевает обработать конец хода; декод замечает отмену за один токен.
        var waits = 0
        while isGenerating {
            guard waits < 200 else {
                // Десять секунд — это уже не «доскончивается», а застряло. Честный
                // отказ лучше вечного ожидания.
                throw PocketAgentError.generationFailed(
                    "Предыдущий ответ всё ещё считается, и начать новую модель "
                        + "пока нельзя. Нажмите «Стоп» и попробуйте ещё раз.")
            }
            waits += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if case .ready = status, model != nil { return }

        isPreparing = true
        unloadRequested = false
        defer { isPreparing = false }

        journal.startStage(.prepare)
        journal.record(.engine, "Готовлю GGUF-модель (llama.cpp, форк PrismML)")

        do {
            let resolved = try await resolveModelFile()
            let url = resolved.url

            // Заголовок проверяем ДО передачи файла движку: чужой/битый файл не
            // должен доезжать до C-слоя, где ошибки англоязычные и невнятные.
            setStatus(.verifying)
            let header = try Self.readGGUFHeader(url)
            journal.record(.engine, "Проверяю файл модели",
                           detail: "файл: \(url.lastPathComponent) · "
                                 + "версия формата: \(header.version) · "
                                 + "размер: \(HumanFormat.bytes(modelByteSize))")

            // ⚠️ ПОЛНАЯ БЫСТРАЯ ПРОВЕРКА — ТА ЖЕ, ЧТО У ДВИЖКА GOOGLE ПЕРЕД КАЖДОЙ
            // ЗАГРУЗКОЙ (`LiteRTRuntime.prepare`). Наш заголовок выше читает метку
            // и версию; эта проверка добавляет счётчик весовых матриц (ноль — это
            // не модель), а у скачанного нами сверяет размер с эталоном байт в байт.
            // Стоит мгновение — ловит обрывок ДО минут загрузки весов.
            try ModelVerifier.quickCheck(url, model: resolved.descriptor)

            // Файл, скачанный нами и ещё не сверённый, доверяем только после полной
            // сверки суммы (см. пояснение у `verifyTrustedDownloadIfNeeded`). Она —
            // ПОСЛЕДНЕЙ из проверок не зря: это секунды чтения гигабайтов, и мусор
            // с кривым заголовком должен отсеяться мгновенной проверкой выше.
            try await verifyTrustedDownloadIfNeeded(url, descriptor: resolved.descriptor)

            let chosen = Self.chooseContextTokens(fileBytes: modelByteSize)

            // Гейт памяти — ДО минут загрузки, по той же дисциплине, что у движка
            // Google (`ensureEnoughMemoryForStep`): честный отказ сейчас лучше
            // молчаливого отстрела приложения системой на середине загрузки.
            // Расход считаем по ЕДИНОЙ физике этого движка (см.
            // `residentWeightsMB`): веса — весь файл, плюс память разговора под
            // выбранный контекст и запас на буферы вычислений.
            // Измерить память не удалось — гейт молчит: пугать выдуманным нельзя.
            let availableMB = MemoryGate.availableMemoryMB()
            if availableMB != Int.max {
                let requiredMB = Self.requiredMemoryMB(fileBytes: modelByteSize,
                                                       contextTokens: chosen)
                journal.record(.engine, "Смотрю, хватит ли памяти",
                               detail: "свободно: \(Self.freeMemoryText()) · "
                                     + "нужно: около \(requiredMB) МБ (веса + память "
                                     + "разговора + буферы вычислений)")
                // ⚠️ НЕ ОТКАЗЫВАЕМ, только предупреждаем (владелец 23.09.2026: «какого
                // хуя у нас лимит на память ваще стоит если мы его сняли»). Прикидка
                // считала весь файл резидентным, а веса отображаются с диска — Bonsai
                // с отказом «свободно 6107, нужно 7463» у него на деле грузится и
                // работает. Лимит памяти снят в кабинете Apple; судья — система,
                // а не наша прикидка.
                if availableMB < requiredMB {
                    journal.record(.engine, "Памяти по прикидке впритык — всё равно пробую",
                                   detail: "свободно \(availableMB) МБ · прикидка \(requiredMB) МБ")
                }
            }

            setStatus(.loading)
            journal.record(.engine, "Поднимаю модель",
                           detail: "файл: \(url.lastPathComponent) · "
                                 + "свободно памяти: \(Self.freeMemoryText()) · "
                                 + "прошу памяти разговора: \(chosen) (расчёт от свободной "
                                 + "памяти; веса читаются mmap-ом, не копируются)")

            // Загрузка весов — блокирующий вызов на десятки секунд: ждать его в
            // акторе нельзя (см. шапку файла), уводим в отдельную задачу.
            let path = url.path
            let wantedCtx = chosen
            let loaded = try await Task.detached(priority: .userInitiated) { () -> (OpaquePointer, OpaquePointer, Int) in
                var mparams = llama_model_default_params()
                // ⚠️ mmap ОБЯЗАТЕЛЕН, И ЭТО НЕ ОПТИМИЗАЦИЯ. Веса 5,95 ГБ при бюджете
                // процесса ~6 ГБ: без mmap загрузчик скопировал бы файл в память
                // целиком, и приложение умерло бы до первого ответа. mmap держит
                // страницы файла читаемыми по требованию — резидентной остаётся
                // только рабочая часть весов. У форка PrismML поля use_mmap/use_mlock
                // заменены одним режимом загрузки; MLOCK (держать всё в ОЗУ) нам
                // противопоказан — весам у нас живётся в плюс-минус 6 ГБ.
                mparams.load_mode = LLAMA_LOAD_MODE_MMAP

                guard let m = llama_model_load_from_file(path, mparams) else {
                    // ⚠️ Здесь две возможные вины, и честно назвать только одну нельзя:
                    // файл может быть битым, а может — память кончилась посреди чтения
                    // весов (mmap приносит страницы с диска по мере надобности, и на
                    // забитом телефоне он умирает так же, как на битом файле).
                    throw PocketAgentError.generationFailed(
                        "Не удалось запустить файл модели: либо файл повреждён, либо "
                            + "телефону не хватило памяти. Закройте другие приложения и "
                            + "попробуйте ещё раз; если ошибка повторяется — скачайте "
                            + "модель заново.")
                }

                var cparams = llama_context_default_params()
                cparams.n_ctx = UInt32(wantedCtx)
                cparams.n_batch = UInt32(LlamaModelRuntime.decodeBatchTokens)
                cparams.n_ubatch = UInt32(LlamaModelRuntime.decodeBatchTokens)
                guard let c = llama_init_from_model(m, cparams) else {
                    llama_model_free(m)
                    throw PocketAgentError.generationFailed(
                        "Файл модели прочитан, но памяти не хватило, чтобы модель "
                            + "заработала. Закройте другие приложения и попробуйте снова.")
                }
                return (m, c, wantedCtx)
            }.value

            // Пока грузились веса, система попросила освободить память. Отдаём
            // загруженное сразу и НЕ объявляем модель готовой — вернуть веса после
            // такой просьбы значит быть закрытым системой на следующем вздохе
            // (тот же урок, что у движка Apple).
            if unloadRequested {
                unloadRequested = false
                llama_free(loaded.1)
                llama_model_free(loaded.0)
                throw PocketAgentError.memoryPressureDuringLoad
            }

            model = loaded.0
            ctx = loaded.1
            nCtx = loaded.2
            nPast = 0
            kvPromptText = ""

            smpl = Self.makeSampler()

            // Что за модель перед нами — в журнал. Единственная улика, по которой
            // можно отличить «форк прочитал тернарный формат» от «стоковый бинарь
            // молча наврал»: у стока поля заголовка вразрез с файлом.
            let arch = Self.meta(loaded.0, key: "general.architecture") ?? "—"
            let quant = Self.meta(loaded.0, key: "general.file_type") ?? "—"
            journal.record(.engine, "Поля заголовка модели",
                           detail: "архитектура: \(arch) · квантование: \(quant) · "
                                 + "n_ctx: \(nCtx)")

            activeBackendName = "Metal"
            ContextSizeSettings.noteGranted(nCtx)

            journal.noteReady(modelName: modelDisplayName,
                              fileName: url.lastPathComponent,
                              fileSizeText: HumanFormat.bytes(modelByteSize),
                              backend: activeBackendName,
                              askedTokens: nCtx,
                              grantedTokens: nCtx,
                              chosenTokens: ContextSizeSettings.chosenTokens,
                              stepNumber: 0,
                              stepName: "движок llama.cpp",
                              freeMemoryMB: MemoryGate.availableMemoryMB())
            setStatus(.ready)
        } catch {
            await releaseWeights()
            let human = Self.humanMessage(error)
            journal.recordFailure(stage: "загрузка модели llama.cpp",
                                  human: human,
                                  technical: RuntimeJournal.technicalText(for: error))
            setStatus(.failed(message: human))
            throw error
        }
    }
    #endif

    /// Файл GGUF для работы: только явный выбор человека. Своего «поиска чего-нибудь
    /// годного» здесь нет намеренно — подставить соседний файл вместо заказанного
    /// значит запустить не ту модель, которую человек выбрал (урок ensureModelFile).
    /// Файла нет — качаем сами, если выбор человека это модель из справочника, которую
    /// приложение умеет скачать (та же дисциплина, что у движков Google и Apple, где
    /// скачивание живёт внутри подготовки).
    ///
    /// Вместе с файлом возвращается и описание модели, к которому он относится:
    /// быстрой проверке файла (`ModelVerifier.quickCheck`) нужен размер и происхождение
    /// ИМЕННО ЭТОЙ модели, а не «активной по умолчанию».
    private func resolveModelFile() async throws -> (url: URL, descriptor: ModelDescriptor) {
        if let url = modelFileURL, FileManager.default.fileExists(atPath: url.path) {
            // ⚠️ ПРИСТАВЛЕННЫЙ ФАЙЛ ГОДЕН, ТОЛЬКО ЕСЛИ ОН И ЕСТЬ НЫНЕШНИЙ ВЫБОР.
            // Приставленное живёт в движке с прошлого раза, а человек мог выбрать
            // ДРУГУЮ модель из каталога: проверка по факту существования молча
            // готовила бы старый файл под видом «скачивания» нового. Не тот файл —
            // забываем приставленное и идём дальше, к файлу выбора или скачиванию.
            if Self.attachedFileMatchesChoice(url) {
                modelByteSize = (try? FileManager.default.attributesOfItem(
                    atPath: url.path)[.size] as? Int64) ?? modelByteSize
                // Описание — ИМЕННО этого файла: быстрой проверке нужен размер
                // и происхождение той модели, что лежит на диске. Выбора нет —
                // файл приставлен напрямую движку, описываем его по нему самому.
                let descriptor = ModelSpec.choice?.descriptor
                    ?? ModelDescriptor.unknown(fileName: url.lastPathComponent,
                                               byteSize: ModelStorage.byteSize(of: url))
                return (url, descriptor)
            }
            journal.record(.engine, "Приставленный файл — не та модель, что выбрана сейчас; "
                                  + "ищу файл выбора",
                           detail: "приставлен: \(url.lastPathComponent) · "
                                 + "выбрана: \(ModelSpec.descriptor.displayName)")
            modelFileURL = nil
        }
        if let choice = ModelSpec.choice,
           let chosen = choice.fileURL,
           FileManager.default.fileExists(atPath: chosen.path),
           ModelFileFormat.detect(fileName: chosen.lastPathComponent) == .gguf {
            modelByteSize = ModelStorage.byteSize(of: chosen)
            return (chosen, choice.descriptor)
        }

        // ⚠️ РАНЬШЕ ЗДЕСЬ СРАЗУ БЫЛ ОТКАЗ «файл не найден», и кнопка «Скачать» на
        // карточке GGUF была мёртвой: человек жал её, а подготовка отвечала отказом.
        // Теперь — как у остальных движков: сначала ищем уже скачанное, потом качаем.
        let model = ModelSpec.descriptor
        guard ModelFileFormat.detect(fileName: model.fileName) == .gguf else {
            // Файл другого формата этому движку не положишь: скачивание .litertlm —
            // путь движка Google, и делать это отсюда нельзя.
            throw PocketAgentError.modelFileMissing
        }
        if let installed = ModelStorage.installedModelURL(for: model),
           ModelStorage.byteSize(of: installed) == model.byteSize {
            journal.record(.engine, "Беру уже установленную модель",
                           detail: "файл: \(installed.lastPathComponent) · "
                                 + "размер: \(HumanFormat.bytes(model.byteSize))")
            modelDisplayName = model.displayName
            modelByteSize = ModelStorage.byteSize(of: installed)
            return (installed, model)
        }
        guard ModelCatalog.canDownload(model) else {
            // Файла нет и скачать его неоткуда (человек принёс модель сам, у неё
            // нет ни адреса, ни контрольной суммы) — прежний честный отказ.
            throw PocketAgentError.modelFileMissing
        }
        let downloaded = try await downloadModelFile(model)
        return (downloaded, model)
    }

    /// Приставленный к движку файл — тот ли, что человек выбрал прямо сейчас?
    ///
    /// Сверяем по самому выбору: с приставленным файлом — по пути; модель из
    /// справочника без своего файла — по имени и точному размеру (две разные
    /// модели-каталога одним именем не бывают, а размер добивает совпадение).
    /// Выбора нет вовсе — против чего сверять? Приставленное и есть единственная
    /// инструкция, значит, годится.
    private static func attachedFileMatchesChoice(_ url: URL) -> Bool {
        guard let choice = ModelSpec.choice else { return true }
        if let chosen = choice.fileURL {
            return chosen.resolvingSymlinksInPath().standardizedFileURL.path
                == url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        // Выбор без своего файла — модель из справочника, которую ещё не скачали.
        return matchesDescriptor(url, choice.descriptor)
    }

    private static func matchesDescriptor(_ url: URL, _ descriptor: ModelDescriptor) -> Bool {
        guard url.lastPathComponent == descriptor.fileName,
              ModelFileFormat.detect(fileName: url.lastPathComponent) == .gguf else { return false }
        // Размер не знаем — сверить нечем, имени достаточно.
        guard descriptor.byteSize > 0 else { return true }
        return ModelStorage.byteSize(of: url) == descriptor.byteSize
    }

    /// Скачать файл GGUF из справочника и сверить его с эталоном.
    ///
    /// Порядок — как у движка Google: полоса загрузки в общих статусах (человек
    /// видит ход и может нажать «Стоп»), после скачивания — полный sha256. Сумма —
    /// единственный момент, когда стоит платить несколько секунд чтения почти шести
    /// гигабайт: раньше она у GGUF не сверялась НИ РАЗУ, и битая загрузка доезжала
    /// прямо до движка. Не сошлось — файл убираем сами: оставленный битый файл
    /// превращал бы совет «попробуйте ещё раз» в невыполнимый, каждая попытка
    /// упиралась бы в тот же мусор.
    private func downloadModelFile(_ model: ModelDescriptor) async throws -> URL {
        journal.record(.engine, "Файла нет на телефоне — скачиваю модель",
                       detail: "модель: \(model.displayName) · размер: \(model.humanSize)")
        setStatus(.downloading(progress: ModelDownloader.shared.lastProgress))

        // ⚠️ МАРКЕР СВЕРКИ СТИРАЕМ ДО ЗАГРУЗКИ, И ЭТО НЕ ДЕТАЛЬ. Файл сейчас будет
        // переписан, а маркер «содержимое сверено» относится к прежнему содержимому.
        // Останься он на месте и случись обрыв посреди загрузки — следующий запуск
        // поверил бы маркеру и поднял недокачанный файл как проверенный.
        if let destination = try? ModelStorage.fileURL(for: model) {
            try? FileManager.default.removeItem(at: Self.verifiedMarkerURL(for: destination))
        }

        let downloadedURL = try await ModelDownloader.shared.download(model) { [weak self] progress in
            Task { await self?.setStatus(.downloading(progress: progress)) }
        }

        // Пока качали, система попросила освободить память — тяжёлую загрузку весов
        // не начинаем. Вернуть веса после такой просьбы значит быть закрытым системой
        // на следующем вздохе (тот же урок, что у движка Apple).
        if unloadRequested {
            unloadRequested = false
            throw PocketAgentError.memoryPressureDuringLoad
        }

        setStatus(.verifying)
        let modelCopy = model
        do {
            try await Task.detached(priority: .userInitiated) {
                try ModelVerifier.verify(downloadedURL, model: modelCopy, checksum: .required)
            }.value
        } catch is CancellationError {
            // Человек ушёл с экрана или нажал «Стоп» — файл цел, трогать его нельзя:
            // докачка сохранена, следующая попытка продолжит с места обрыва.
            throw PocketAgentError.generationCancelled
        } catch {
            if let known = error as? PocketAgentError, case .generationCancelled = known {
                throw known
            }
            try? FileManager.default.removeItem(at: downloadedURL)
            ModelStorage.clearResumeData(for: modelCopy)
            ModelDownloadPlanStore.clear(modelID: modelCopy.id)
            journal.record(.failure, "Скачанный файл не прошёл проверку — убрал его",
                           detail: "модель: \(modelCopy.displayName) · "
                                 + "причина: \(RuntimeJournal.technicalText(for: error))")
            ModelDiscovery.refreshAndNotify()
            throw PocketAgentError.generationFailed(
                "Файл модели «\(modelCopy.displayName)» скачался с браком — "
                    + "я его убрал, чтобы не занимал место. Попробуйте скачать ещё раз.")
        }

        // Сверка сошлась — ставим маркер «содержимое проверено». Теперь файлу
        // доверяют с первого запуска, а не сверяют каждый раз заново; подробности
        // — у `verifyTrustedDownloadIfNeeded`.
        Self.writeVerifiedMarker(for: downloadedURL, sha256: modelCopy.sha256)

        // Скачанное закрепляем за выбором: со следующего запуска приложение возьмёт
        // именно этот файл, а не пойдёт качать заново (тот же приём, что у движка
        // Google). И перечитываем список файлов — иначе скачанное появится в нём
        // только после следующего запуска приложения.
        ModelSpec.select(modelCopy, fileURL: downloadedURL)
        ModelDiscovery.refreshAndNotify()
        modelFileURL = downloadedURL
        modelDisplayName = modelCopy.displayName
        modelByteSize = ModelStorage.byteSize(of: downloadedURL)
        return downloadedURL
    }

    // MARK: - Маркер «файл скачан и сверен»

    /// Файл, скачанный нами самими, доверяем только ПОСЛЕ сверки контрольной суммы —
    /// даже если скачивание закончилось вчера.
    ///
    /// ⚠️ ОТКУДА ДЫРА. Файл получает своё настоящее имя ещё ДО сверки (так устроен
    /// загрузчик, и менять его не надо), а сверка суммы — секунды чтения гигабайтов.
    /// Убей приложение эту секунду — и при следующем запуске файл выглядит уже
    /// установленным: размер совпадает, заголовок цел, а битая середина едет в
    /// движок как тихий мусор. Поэтому после успешной сверки рядом с файлом кладётся
    /// маркер, и доверие заслуживается ровно один раз:
    ///   • маркер на месте — файл уже сверяли, берём как есть;
    ///   • маркера нет (обрыв посреди сверки, прошлый брак) — сверяем сумму ПРЯМО
    ///     СЕЙЧАС, до минут загрузки весов; не сошлась — файл убираем сами.
    /// У принесённой человеком модели эталонной суммы нет — её содержимое было
    /// проверено при установке, и здесь оно не перевыряется (как и было).
    private func verifyTrustedDownloadIfNeeded(_ url: URL, descriptor: ModelDescriptor) async throws {
        guard !descriptor.sha256.isEmpty else { return }
        // Маркер живёт только у файлов в СВОЁМ хранилище: там лежит то, что качали
        // мы. Файл из «Файлов» человека могло проверить при установке — не мешаем.
        guard ModelStorage.location(of: url) == .appStorage else { return }
        let marker = Self.verifiedMarkerURL(for: url)
        if FileManager.default.fileExists(atPath: marker.path) { return }

        journal.record(.engine, "Файл скачан, но ещё не сверен — проверяю сумму",
                       detail: "файл: \(url.lastPathComponent) · это секунды чтения, "
                             + "потом пойдёт загрузка весов")
        setStatus(.verifying)
        do {
            try await Task.detached(priority: .userInitiated) {
                try ModelVerifier.verifyHash(url, model: descriptor)
            }.value
        } catch is CancellationError {
            throw PocketAgentError.generationCancelled
        } catch {
            if let known = error as? PocketAgentError, case .generationCancelled = known {
                throw known
            }
            // Сумма не сошлась: битый файл убираем сами — оставленный мусор
            // превращал бы совет «попробуйте ещё раз» в невыполнимый.
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: marker)
            ModelStorage.clearResumeData(for: descriptor)
            ModelDownloadPlanStore.clear(modelID: descriptor.id)
            journal.record(.failure, "Файл с диска не прошёл сверку суммы — убрал его",
                           detail: "модель: \(descriptor.displayName) · "
                                 + "причина: \(RuntimeJournal.technicalText(for: error))")
            ModelDiscovery.refreshAndNotify()
            throw PocketAgentError.generationFailed(
                "Файл модели «\(descriptor.displayName)» на телефоне оказался с браком "
                    + "(проверка целостности не сошлась) — я его убрал, чтобы не занимал "
                    + "место. Скачайте модель ещё раз.")
        }
        Self.writeVerifiedMarker(for: url, sha256: descriptor.sha256)
    }

    /// Маркер «содержимое сверено» рядом с самим файлом: то же имя, но с хвостом
    /// «.ok»; внутри — контрольная сумма, с которой сверяли.
    ///
    /// ⚠️ Имя БЕЗ «.gguf» внутри, и это не вкус. Поиск моделей показывает человеку
    /// всё, что рядом с моделями похоже на файл с «лишним хвостом в имени» — маркер
    /// с именем «модель.gguf.ok» выглядел бы в «Файлах» как сломанный файл. Наш
    /// маркер лежит во внутреннем хранилище приложения, куда «Файлы» не заглядывают.
    private static func verifiedMarkerURL(for modelFile: URL) -> URL {
        modelFile.deletingPathExtension().appendingPathExtension("ok")
    }

    private static func writeVerifiedMarker(for modelFile: URL, sha256: String) {
        guard !sha256.isEmpty else { return }
        let marker = verifiedMarkerURL(for: modelFile)
        try? Data(sha256.utf8).write(to: marker, options: .atomic)
    }

    // MARK: - Разговор

    public func beginSession(systemPrompt: String, tools: [ToolDeclaration]) async throws {
        self.systemPrompt = systemPrompt

        // Ровно фильтр движка Apple (`MLXToolSchemas.tools(matching:)`): неизвестное
        // имя молча пропускаем — описание под несуществующий исполнитель отдавать
        // модели нельзя, она позовёт его, а выполнить будет нечем.
        self.tools = tools.filter { ToolKind(rawValue: $0.name) != nil }

        // Новый разговор = чистая история. KV-кэш обнулится сам: промпт нового
        // разговора не начинается со старого `kvPromptText`, и префиксная проверка
        // в performTurn уведёт следующий ход на честный пересчёт с нуля.
        messages = []
        didSendSystemPrompt = false
        nPast = 0
        kvPromptText = ""
        extraCallsLastTurn = 0
        sessionEpoch += 1

        journal.record(.engine, "Начал разговор с GGUF-моделью",
                       detail: "действий в наборе: \(self.tools.count) · "
                             + "выполнять их сама модель не может — только просить · "
                             + "шаблон: ChatML, вызовы в <tool_call> (стиль Hermes/Qwen)")
    }

    public func send(userText: String) async throws -> ModelTurn {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PocketAgentError.generationFailed("Пустой запрос.")
        }
        // Человек начал новый ход сам — долг по лишним вызовам прошлого хода
        // сгорает: они относились к другому шагу.
        extraCallsLastTurn = 0
        appendSystemIfNeeded()
        messages.append(TurnMessage(role: .user, content: trimmed))
        return try await performTurn()
    }

    public func send(toolResult: ToolResult) async throws -> ModelTurn {
        // Ответ действия уходит тем же разговором (память вычислений сохраняется)
        // и при отказе человека тоже: модель обязана узнать, что действие НЕ
        // выполнено, иначе следующий шаг построит на выдумке.
        var content = Self.text(of: toolResult.payload)
        if extraCallsLastTurn > 0 {
            // Модель попросила несколько действий за ход — мы выполнили одно.
            // Молчать про остальные нельзя: она считает их сделанными.
            content += "\n" + Self.oneActionPerTurnNotice
            extraCallsLastTurn = 0
        }
        appendSystemIfNeeded()
        messages.append(TurnMessage(role: .toolResult, content: content))
        return try await performTurn()
    }

    /// Что отвечаем на лишние вызовы действий в одном ходе (текст — как у движка Apple).
    private static let oneActionPerTurnNotice =
        "За один ход выполняется ровно одно действие. Это действие не выполнено — "
            + "повтори его следующим ходом, если оно всё ещё нужно."

    /// Системную инструкцию подставляем первым сообщением РОВНО ОДИН раз
    /// (приём движка Apple: длинная инструкция, уезжающая с каждым ходом,
    /// съедает память разговора и путает модель).
    ///
    /// ⚠️ Пустая инструкция при включённых действиях — не повод молчать: секция
    /// инструментов верстается ВНУТРИ системного сообщения, и без сообщения модель
    /// не узнала бы, что у неё есть действия. Тогда первым сообщением едет
    /// мини-системное сообщение, состоящее из одной секции.
    private func appendSystemIfNeeded() {
        guard !didSendSystemPrompt else { return }
        guard !systemPrompt.isEmpty || !tools.isEmpty else { return }
        messages.append(TurnMessage(role: .system, content: systemPrompt))
        didSendSystemPrompt = true
    }

    /// Тело ответа действия строкой — та же дисциплина, что у движка Apple:
    /// простой текст как есть, остальное JSON-ом. Заворачивать одну строку в
    /// кавычки и скобки незачем — каждый лишний знак оплачивается контекстом.
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

    // MARK: - Верстка промпта

    /// Одно сообщение разговора в внутреннем виде.
    private struct TurnMessage {
        enum Role { case system, user, assistant, toolResult }
        let role: Role
        let content: String
    }

    /// Собрать весь промпт разговора: ChatML + секция инструментов + хвост
    /// `<|im_start|>assistant\n`, после которого модель пишет ответ.
    private func renderPrompt() -> String {
        var out = ""
        for message in messages {
            switch message.role {
            case .system:
                out += "<|im_start|>system\n" + message.content
                if !tools.isEmpty {
                    // Секция инструментов живёт ВНУТРИ системного сообщения, как в
                    // родном шаблоне Qwen3. Имена и описания — те же ToolDeclaration,
                    // что уходят движку Apple: один контракт имён на всё приложение.
                    // Инструкция может быть пустой (человек её не задал, а действия
                    // включены) — тогда сообщение и есть одна секция, без пустой
                    // строки-разделителя, которой некуда вести.
                    out += (message.content.isEmpty ? "" : "\n\n") + Self.toolsSection(tools)
                }
                out += Self.imEnd
            case .user:
                out += "<|im_start|>user\n" + message.content + Self.imEnd
            case .assistant:
                out += "<|im_start|>assistant\n" + message.content + Self.imEnd
            case .toolResult:
                // Ответ действия — от лица пользователя, обёрнутый в <tool_response>:
                // так его подаёт родной шаблон Qwen3/Hermes, от которого Bonsai
                // унаследовала разговор. Отступить от этой обёртки — самый дешёвый
                // способ сломать разбор вызовов, поэтому она не наша выдумка.
                out += "<|im_start|>user\n<tool_response>\n" + message.content
                    + "\n</tool_response>" + Self.imEnd
            }
        }
        // Хвост, открывающий ход модели. В истории его нет — он принадлежит только
        // текущей генерации, поэтому добавляется всегда последним.
        out += "<|im_start|>assistant\n"
        return out
    }

    private static let imEnd = "<|im_end|>\n"

    /// Секция инструментов в стиле Hermes/Qwen — то, что модель видела при обучении.
    /// ⚠️ Это НЕ «пример вызова в системном промпте» из правила SystemPrompt.swift:
    /// тот запрет про НАШИ инструкторские примеры (маленькая модель списывает их
    /// буквами), здесь — родная строительная форма самого шаблона разговора, без
    /// которой модель не узнает, что у неё есть действия. Движок Apple получает ту
    /// же секцию бесплатно из Jinja-шаблона модели; llama.cpp её не применяет —
    /// поэтому верстаем дословно.
    private static func toolsSection(_ declarations: [ToolDeclaration]) -> String {
        var specs = ""
        for declaration in declarations {
            var properties: [String: Any] = [:]
            var required: [String] = []
            for parameter in declaration.parameters {
                var field: [String: Any] = ["type": jsonType(of: parameter.type)]
                if !parameter.details.isEmpty {
                    field["description"] = parameter.details
                }
                properties[parameter.name] = field
                if parameter.isRequired {
                    required.append(parameter.name)
                }
            }
            let spec: [String: Any] = [
                "type": "function",
                "function": [
                    "name": declaration.name,
                    "description": declaration.details,
                    "parameters": [
                        "type": "object",
                        "properties": properties,
                        "required": required,
                    ],
                ],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                specs += (specs.isEmpty ? "" : "\n") + line
            }
        }
        return "# Tools\n\n"
            + "You may call one or more functions to assist with the user query.\n\n"
            + "You are provided with function signatures within <tools>...</tools> XML tags:\n"
            + "<tools>\n" + specs + "\n</tools>\n\n"
            + "For each function call, return a json object with function name and "
            + "arguments within <tool_call></tool_call> XML tags:\n"
            + "<tool_call>\n{\"name\": <function-name>, \"arguments\": <args-json-object>}\n"
            + "</tool_call>"
    }

    private static func jsonType(of type: ToolParameterType) -> String {
        switch type {
        case .string:  return "string"
        case .integer: return "integer"
        case .number:  return "number"
        case .boolean: return "boolean"
        }
    }

    // MARK: - Один ход

    private func performTurn() async throws -> ModelTurn {
        #if canImport(LlamaBonsai)
        guard let ctxValue = ctx, let smplValue = smpl, let modelValue = model else {
            throw PocketAgentError.runtimeNotReady
        }
        guard !isGenerating else {
            throw PocketAgentError.generationFailed("Предыдущий ответ ещё не готов.")
        }
        isGenerating = true
        didCancelCurrentTurn = false
        let epoch = sessionEpoch

        journal.startStage(.turn)

        let box = TurnBox()
        liveBox = box

        let rendered = renderPrompt()

        // Префикс уже в KV-кэше? Тогда декодируем только суффикс. Проверка по
        // тексту, а не по счетчику: после отмены или сбоя кэш мог остаться с чужим
        // хвостом, и доверять числу было бы опасно. Не сошлось — пересчёт с нуля.
        var suffix = rendered
        if !kvPromptText.isEmpty, rendered.hasPrefix(kvPromptText), nPast > 0 {
            suffix = String(rendered.dropFirst(kvPromptText.count))
        } else {
            // Кэш больше не соответствует тексту — чистим, иначе декод продолжил бы
            // разговор с чужого места и модель отвечала бы «из прошлого».
            // У форка очистка живёт в «памяти разговора»; true = стереть всё.
            llama_memory_clear(llama_get_memory(ctxValue), true)
            nPast = 0
        }

        // Снимок всего, что нужно фоновой задаче. Указатели валидны, пока актор
        // спит на await ниже: освобождение весов до конца хода заблокировано.
        do {
            try await Task.detached(priority: .userInitiated) { [box, ctxValue, smplValue, modelValue] in
                try LlamaModelRuntime.runTurn(box: box,
                                              ctx: ctxValue,
                                              smpl: smplValue,
                                              model: modelValue,
                                              promptSuffix: suffix,
                                              ctxLimit: LlamaModelRuntime.maxCtxLimit(ctxValue))
            }.value

            // endSession()/unload() могли прийти ПОКА ХОД ИДЕТ: историю они уже
            // стёрли — значит и результат хода принимать некуда.
            guard epoch == sessionEpoch else {
                nPast = 0
                kvPromptText = ""
                await finishTurn()
                throw PocketAgentError.sessionNotStarted
            }

            if didCancelCurrentTurn {
                throw PocketAgentError.generationCancelled
            }

            // Сырой ответ (с думанием — в истории он остаётся, как в родном шаблоне
            // Qwen) становится сообщением ассистента. Сырой, а не «снятый»: KV-кэш
            // хранит ровно эти токены, и префиксная проверка следующего хода сверяет
            // текст с кэшем.
            //
            // ⚠️ КЭШУ ВЕРИМ ТОЛЬКО С ПОМЕТКОЙ ИЗ ФОНОВОЙ ЗАДАЧИ. Она подтверждает, что
            // кэш досчитан ровно до конца сообщения (маркер `<|im_end|>` лежит там,
            // где его обещает верстка). Без пометки — ход кончился бюджетом без конца
            // сообщения, сорвался декод досчёта или дыра посреди ответа — текст и кэш
            // разошлись бы: следующий ход достроил бы разговор «с прошлого», и модель
            // отвечала бы из уже забытого места. Тогда кэш выбрасываем: следующий ход
            // пересчитает историю с нуля, уже согласованно.
            let raw = box.text
            messages.append(TurnMessage(role: .assistant, content: raw))
            if box.cacheConsistent {
                nPast = box.contextCells
                kvPromptText = renderPrompt()
            } else {
                nPast = 0
                kvPromptText = ""
            }

            // Лишние вызовы считаем по ответу БЕЗ думания: модель перемалывает
            // примеры вызовов прямо в `<think>`, и счёт по сырому тексту давал бы
            // ложные «выполнено не всё» после единственного честного вызова.
            let callCount = Self.stripThinking(raw).ranges(of: "<tool_call>").count
            extraCallsLastTurn = max(0, callCount - 1)

            journal.noteTurnFinished(engineTokens: nPast,
                                     limitTokens: nCtx,
                                     stepNumber: 0,
                                     stepName: "движок llama.cpp")

            await finishTurn()
            return interpret(raw: raw)
        } catch {
            // Отмена/сбой: KV-кэш мог остаться с недописанным хвостом генерации —
            // ему больше нет соответствия в тексте. Следующий ход честно
            // пересчитается с нуля (обнуление ниже), «тихого мусора» не будет.
            nPast = 0
            kvPromptText = ""
            // Вид ошибки разбираем ДО конца хода: finishTurn гасит флаг отмены,
            // и после него «Стоп» уже не отличить от поломки.
            let mapped = mapTurnError(error, box: box)
            await finishTurn()
            throw mapped
        }
        #else
        throw PocketAgentError.generationFailed(Self.engineNotConnectedText)
        #endif
    }

    /// Конец хода: снять флаг «генерируем» и выполнить отложенную выгрузку весов,
    /// если её попросили, пока ход шёл. releaseWeights() безопасен ровно потому,
    /// что к этому моменту фоновая задача декода уже завершена (await выше).
    private func finishTurn() async {
        isGenerating = false
        didCancelCurrentTurn = false
        liveBox = nil
        #if canImport(LlamaBonsai)
        if pendingRelease {
            pendingRelease = false
            await releaseWeights()
            setStatus(.idle)
        }
        #endif
    }

    private func mapTurnError(_ error: Error, box: TurnBox) -> Error {
        // Ход прервали мы сами — нажатие «Стоп» не должно выглядеть поломкой.
        if box.cancelled || didCancelCurrentTurn || error is CancellationError {
            return PocketAgentError.generationCancelled
        }
        // Разговор закрыли, ПОКА ход шёл, — это порядок жизни, а не поломка:
        // в журнале ошибкой ему не место.
        if let known = error as? PocketAgentError, case .sessionNotStarted = known {
            return known
        }
        journal.recordFailure(stage: "ход модели llama.cpp",
                              human: Self.humanMessage(error),
                              technical: RuntimeJournal.technicalText(for: error))
        if let known = error as? PocketAgentError { return known }
        return PocketAgentError.generationFailed(Self.humanMessage(error))
    }

    /// Снять с ответа блок «думания» и вернуть видимую часть.
    ///
    /// `<think>…</think>` — строительные леса Qwen3.8-наследников, а не ответ.
    /// Оборванный `<think>` (лимит токенов кончился посреди думания) приравниваем
    /// к пустому ходу: отдать сырую простыню думания человеку — хуже, чем попросить
    /// модель повторить (цикл сам держит invalidTurnStreak).
    static func stripThinking(_ raw: String) -> String {
        var text = raw
        if let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>") {
                // Думание до закрытия; ответ — всё, что после него.
                text = String(text[close.upperBound...])
            } else {
                // Закрытия нет: весь хвост — недодуманная мысль.
                text = String(text[..<open.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Превратить сырой ответ модели в ход агента.
    ///
    /// Порядок разбора: 1) вызовы действия в родных маркерах `<tool_call>{json}` —
    /// «нативный» формат Bonsai/Qwen; 2) всё остальное — общему текстовому разбору
    /// (`TextualToolCalls`), который знает и старый формат с метками
    /// `<|tool_call_start|>`, и одиночный вызов на весь ответ. Пустой ответ — НЕ
    /// ошибка: отдаётся как есть, цикл агента попросит повторить.
    private func interpret(raw: String) -> ModelTurn {
        let text = Self.stripThinking(raw)

        if text.isEmpty {
            journal.record(.turn, "Модель ответила пусто (или только думание)")
            return .text("")
        }
        journal.noteModelAnswerText(text)

        // ⚠️ ДЕЙСТВИЯ ВЫКЛЮЧЕНЫ — МАРКЕРЫ В ОТВЕТЕ ЭТО ПРОСТО ТЕКСТ. Человек убрал
        // действия кнопкой «Инструменты», модели про них не говорили, и `<tool_call>`
        // в её ответе — цитата или пример, а не просьба. Раньше ветки ниже глотали
        // такой ответ целиком в пустой ход: человек задал вопрос — а в ленте тишина.
        // Пустые ходы и разборы ниже работают ТОЛЬКО при включённых действиях.
        let actionsEnabled = !tools.isEmpty

        // 1. Нативные маркеры Bonsai/Qwen: <tool_call>{"name": …}</tool_call>.
        if let call = Self.firstJSONToolCall(in: text, known: tools.map(\.name)) {
            let invocation = ToolInvocation(rawName: call.name,
                                            callID: UUID().uuidString,
                                            arguments: call.arguments)
            // Считаем по тексту без думания: в `<think>` модель перебирает примеры
            // вызовов, и счёт по сырому сырью обещал бы лишние отказы.
            if text.ranges(of: "<tool_call>").count > 1 {
                journal.record(.turn, "Модель попросила несколько действий за ход; "
                                     + "выполняем первое, на остальные ответим отказом")
            }
            journal.record(.turn, "Модель позвала действие нативным маркером <tool_call>")
            journal.noteToolInvocation(invocation)
            return .toolRequest(invocation)
        }

        // 1а. Формат вызова узнан (<tool_call> с JSON внутри), а взять его в работу
        // нечем: имя действия неизвестно либо аргументы не читаются. Сырой JSON в ленту
        // человеку отдавать нельзя — это строительный текст для машины, а не ответ
        // (живой случай приёмки: модель звала действие, которого нет, и человек видел
        // простыню JSON вместо разговора). Отдаём пустой ход с пометкой «кривой
        // ответ»: цикл агента сам покажет «модель ответила непонятно» и попросит её
        // повторить — до двух попыток. Совсем нераспознанный текст идёт ниже как был.
        if actionsEnabled, let calledName = Self.firstShapedJSONToolCall(in: text) {
            let reason = tools.contains(where: { $0.name == calledName })
                ? "аргументы вызова не читаются"
                : "действия «\(calledName)» в наборе нет"
            journal.noteGarbledAnswer()
            journal.record(.turn, "Модель позвала действие, которое нельзя выполнить",
                           detail: "формат <tool_call> узнан · \(reason) · "
                                 + "человеку сырой JSON не показываем — просим повторить")
            return .text("")
        }

        // 2. Текстовый разбор: старые метки <|tool_call_start|>… и одиночный вызов
        //    на весь ответ. Разбор текста добавляет вызовы, а не права — карточка
        //    подтверждения впереди, как и раньше. При выключенных действиях не
        //    зовётся вовсе: там разбирать нечего, любые метки остаются текстом.
        if actionsEnabled,
           let parsed = TextualToolCalls.parse(text, known: tools.map(\.name)) {
            let invocation = ToolInvocation(rawName: parsed.name,
                                            callID: UUID().uuidString,
                                            arguments: parsed.arguments)
            journal.record(.turn,
                           "Модель позвала действие текстом, а не маркерами",
                           detail: "разобрано как \(parsed.name)")
            journal.noteToolInvocation(invocation)
            return .toolRequest(invocation)
        }

        // 1б. Вызов ОБОРВАН: маркер открыли, а закрытия нет — генерация обрезалась
        // посреди вызова (лимит хода, память, сбой). Это строительный кусок для
        // машины, а не ответ человеку: сырой `<tool_call>{…` в ленту отдавать
        // нельзя по той же причине, что и в 1а. Пустой ход с пометкой «кривой
        // ответ» — цикл попросит модель повторить. При выключенных действиях
        // открытый маркер — обычный текст, человек его и увидит.
        if actionsEnabled, text.contains("<tool_call>") {
            journal.noteGarbledAnswer()
            journal.record(.turn, "Модель начала вызов действия и оборвалась",
                           detail: "открыт <tool_call> без закрытия · человеку сырой кусок "
                                 + "не показываем — просим повторить")
            return .text("")
        }

        return .text(text)
    }

    /// Тело первого блока `<tool_call>…</tool_call>`, если он в ответе есть.
    /// nil — модель зов действие нативными маркерами вовсе.
    private static func firstToolCallBody(in text: String) -> String? {
        guard let open = text.range(of: "<tool_call>") else { return nil }
        let afterOpen = text[open.upperBound...]
        guard let close = afterOpen.range(of: "</tool_call>") else { return nil }
        return String(afterOpen[..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Имя из первого `<tool_call>{…}</tool_call>`, когда ФОРМАТ узнан: внутри
    /// корректный JSON-объект с полем «name» (строка). Имя может быть каким угодно —
    /// известность проверяет вызывающий. nil — формат не узнан (нет JSON, нет имени).
    static func firstShapedJSONToolCall(in text: String) -> String? {
        guard let body = firstToolCallBody(in: text),
              let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["name"] as? String else {
            return nil
        }
        return name
    }

    /// Первый `<tool_call>{…}</tool_call>` с известным именем действия.
    ///
    /// ⚠️ Принимаем оба варианта полей, какие пишут Qwen-наследники: «arguments»
    /// (штатный Qwen3) и «parameters» (часть моделей и серверов). Чужое имя
    /// действия не превращается ни во что — выдуманный вызов не выполнится.
    static func firstJSONToolCall(in text: String,
                                  known: [String]) -> (name: String, arguments: [String: String])? {
        guard let body = firstToolCallBody(in: text),
              let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["name"] as? String,
              known.contains(name) else {
            return nil
        }

        var args: Any? = object["arguments"] ?? object["parameters"]
        // Вариант «arguments прислали строкой, внутри которой JSON» — тоже бывает.
        if let asText = args as? String, let innerData = asText.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: innerData) {
            args = inner
        }
        // Поле отсутствует — законно (list_files без path). Не словарь и не отсутствует —
        // вызов не признаём: выдумывать аргументы за модель нельзя.
        guard args == nil || args is [String: Any] else { return nil }
        return (name, ToolInvocation.normalize(args as? [String: Any] ?? [:]))
    }

    // MARK: - Фоновая задача хода

    /// Обмен между актором и фоновой задачей декода. Всё под замком: текст и счётчик
    /// пишет задача, читает актор; флаг отмены наоборот. @unchecked Sendable —
    /// доступ только под замком, ровно как в EngineJournal.
    private final class TurnBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        private var _text = ""
        private var _contextCells = 0
        /// Кэш после этого хода соответствует тексту ответа ровно до конца
        /// сообщения (маркер `<|im_end|>` лежит в кэше, где обещает верстка).
        /// false по умолчанию: пока ход не доказал обратное, кэшу верить нельзя.
        private var _cacheConsistent = false

        var cancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return _cancelled
        }
        func cancel() {
            lock.lock(); _cancelled = true; lock.unlock()
        }
        func append(_ piece: String) {
            lock.lock(); _text += piece; lock.unlock()
        }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return _text
        }
        func setText(_ value: String) {
            lock.lock(); _text = value; lock.unlock()
        }
        var contextCells: Int {
            lock.lock(); defer { lock.unlock() }
            return _contextCells
        }
        func setContextCells(_ value: Int) {
            lock.lock(); _contextCells = value; lock.unlock()
        }
        var cacheConsistent: Bool {
            lock.lock(); defer { lock.unlock() }
            return _cacheConsistent
        }
        func setCacheConsistent(_ value: Bool) {
            lock.lock(); _cacheConsistent = value; lock.unlock()
        }
    }

    /// Весь блокирующий путь одного хода: префил суффикса → декод ответа →
    /// досчёт конца сообщения. Зовётся ТОЛЬКО из Task.detached. Указатели живы,
    /// потому что актор спит на await, а выгрузка весов отложена (`pendingRelease`).
    ///
    /// ⚠️ Имена C-функций — современного API llama.h (форк PrismML от 09.2026).
    /// Если shim-шаг найдёт расхождение (переименования KV-API в свежих версиях),
    /// правится ЗДЕСЬ, а не контракт протокола.
    #if canImport(LlamaBonsai)
    private static func runTurn(box: TurnBox,
                                ctx: OpaquePointer,
                                smpl: UnsafeMutablePointer<llama_sampler>,
                                model: OpaquePointer,
                                promptSuffix: String,
                                ctxLimit: Int) throws {
        llama_sampler_reset(smpl)
        let vocab = llama_model_get_vocab(model)

        // --- Префил суффикса промпта ---
        if !promptSuffix.isEmpty {
            let charCount = promptSuffix.utf8.count
            var tokens = [llama_token](repeating: 0, count: charCount + 1)
            // add_special=false: у ChatML-моделей нет BOS, спец-маркеры уже в тексте.
            // parse_special=true: сверстанные нами <|im_start|>… должны сесть в свои
            // спец-токены, а не в подпись из обычных слов — иначе шаблон разъезжается.
            let n = llama_tokenize(vocab, promptSuffix, Int32(charCount),
                                   &tokens, Int32(tokens.count), false, true)
            guard n >= 0 else {
                throw PocketAgentError.generationFailed(
                    "Разговор не помещается в память модели. Начните новую задачу — "
                        + "переписка станет короче, — или закройте другие приложения: "
                        + "тогда модель сможет держать больше памяти для разговора.")
            }
            tokens.removeSubrange(Int(n)..<tokens.count)

            var offset = 0
            while offset < tokens.count {
                if box.cancelled { return }
                let size = min(decodeBatchTokens, tokens.count - offset)
                let batch = llama_batch_get_one(&tokens[offset], Int32(size))
                if llama_decode(ctx, batch) != 0 {
                    throw PocketAgentError.generationFailed(
                        "Разговор не помещается в память модели. Начните новую задачу — "
                            + "переписка станет короче, — или закройте другие приложения: "
                            + "тогда модель сможет держать больше памяти для разговора.")
                }
                offset += size
            }
        }

        // --- Декод ответа ---
        // Бюджет генерации — от РЕАЛЬНОГО заполнения кэша после префила, с запасом
        // на конец сообщения и округление батча.
        let used = Self.usedCells(ctx)
        let budget = ctxLimit - used - ctxMarginTokens
        guard budget > 0 else {
            // ⚠️ Это место бьёт по ПЕРВОМУ ходу на малом разговоре: пол памяти —
            // 1024 токена, а инструкция и описания действий съедают её ещё до первого
            // слова. Совет «начните новую задачу» тут бессилен — разговор и так пуст.
            // Ведём к тому, что реально помогает: больше свободной памяти — больше
            // выделенный разговору объём.
            throw PocketAgentError.generationFailed(
                "Модели не хватило памяти даже на начало ответа. Закройте другие "
                    + "приложения — тогда разговор получит больше памяти, — и "
                    + "попробуйте ещё раз. Если разговор уже длинный, поможет "
                    + "и новая задача: переписка станет короче.")
        }

        // Стоп-маркеры текстом: eos-токен модель знает сама, но у ChatML-моделей
        // конец хода может приехать и подписью <|im_end|>/<|im_start|> без спец-токена.
        let stopMarkers = ["<|im_end|>", "<|im_start|>"]

        // Обрывок многобайтового токена: пока байты не сложились в валидный UTF-8,
        // копим их отдельно — иначе в тексте появятся подменные символы «�».
        var pendingBytes = Data()
        var sawStop = false
        // Стоп-маркер модель написала ТЕКСТОМ (обычными токенами, не спец-токеном):
        // его байты уже лежат в кэше — каждый выбранный токен декодируется сразу.
        var markerAlreadyInCache = false
        // Декод сорвался ПОСРЕДИ ответа: последний токен в кэш не лёг, значит кэш
        // короче текста — досчитывать поверх него маркер нельзя ни в каком виде.
        var cacheBrokenMidAnswer = false

        for _ in 0..<budget {
            if box.cancelled { return }

            let id = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, id) {
                sawStop = true
                break
            }

            var piece = [CChar](repeating: 0, count: 64)
            let written = llama_token_to_piece(vocab, id, &piece, Int32(piece.count), 0, true)
            if written > 0 {
                pendingBytes.append(contentsOf: piece[0..<Int(written)].map { UInt8(bitPattern: $0) })
                if let chunk = String(data: pendingBytes, encoding: .utf8) {
                    box.append(chunk)
                    pendingBytes.removeAll()
                } else if pendingBytes.count > 64 {
                    // Не сходится в UTF-8 слишком долго — модель пишет мусор.
                    // Отдаём как есть с заменой битого, текст не теряем целиком.
                    box.append(String(decoding: pendingBytes, as: UTF8.self))
                    pendingBytes.removeAll()
                }
            }

            llama_sampler_accept(smpl, id)
            var single = id
            if llama_decode(ctx, llama_batch_get_one(&single, 1)) != 0 {
                // Кэш кончился посреди ответа — честно обрываем, текст остаётся.
                // В кэше при этом НЕ хватает последнего токена: помечаем, чтобы
                // актор выбросил кэш целиком, а не достраивал поверх дыры.
                sawStop = true
                cacheBrokenMidAnswer = true
                break
            }
            box.setContextCells(Self.usedCells(ctx))

            // Маркер может разъехаться между токенами — ищем в накопленном тексте.
            let current = box.text
            if let cut = stopMarkers.compactMap({ current.range(of: $0)?.lowerBound }).min() {
                // Хвост после маркера ответом не считается. Сам маркер в кэш НЕ
                // досчитываем спец-токеном: модель написала его обычными токенами,
                // и они УЖЕ в кэше — добавка спец-токена поверх была бы задвоением
                // (кэш обещал бы один конец сообщения, а лежало бы два). Остаётся
                // дописать только перевод строки, которым верстка заканчивает
                // сообщение, — его в кэше нет (модель его не писала).
                box.setText(String(current[..<cut]))
                sawStop = true
                markerAlreadyInCache = true
                break
            }
        }
        box.setContextCells(Self.usedCells(ctx))
        if !pendingBytes.isEmpty {
            box.append(String(decoding: pendingBytes, as: UTF8.self))
            pendingBytes.removeAll()
        }

        // Досчитываем конец сообщения ассистента в кэш: без этого следующий ход
        // увидел бы историю без закрывающего маркера, и префиксная проверка сорвала
        // бы переиспользование кэша на КАЖДОМ шаге (полный пересчёт истории —
        // секунды на каждом ходу). При отмене (return выше) этого не делаем:
        // актор обнулит кэш сам.
        //
        // ⚠️ РЕЗУЛЬТАТ ДЕКОДА ПРОВЕРЯЕМ, И ЭТО НЕ ПЕДАНТИЗМ. Если досчёт не лёг
        // (кэш кончился), текст ответа обещает маркер, которого в кэше нет, —
        // следующий ход достроил бы разговор не с того места. Помечаем кэш
        // несогласованным: актор его выбросит, и следующий ход честно пересчитает
        // ответ вместе с маркером с нуля.
        //
        // ⚠️ Тот же смысл у обрыва по бюджету (sawStop == false) и у дыры посреди
        // ответа: текст и кэш расходятся — переиспользовать кэш нельзя.
        if sawStop, !cacheBrokenMidAnswer {
            let tail = markerAlreadyInCache ? "\n" : "<|im_end|>\n"
            let appended = Self.appendStopMarker(ctx: ctx, vocab: vocab, piece: tail)
            box.setContextCells(Self.usedCells(ctx))
            box.setCacheConsistent(appended)
        } else {
            box.setCacheConsistent(false)
        }
    }

    /// Досчитать в кэш хвост конца сообщения ассистента. Возвращает, лёг ли он:
    /// false — кэш обещает больше, чем в нём лежит.
    private static func appendStopMarker(ctx: OpaquePointer, vocab: OpaquePointer?,
                                         piece: String) -> Bool {
        var tokens = [llama_token](repeating: 0, count: 8)
        let n = llama_tokenize(vocab, piece, Int32(piece.utf8.count),
                               &tokens, Int32(tokens.count), false, true)
        guard n > 0 else { return false }
        var tail = Array(tokens[0..<Int(n)])
        return llama_decode(ctx, llama_batch_get_one(&tail, n)) == 0
    }

    /// Потолок, под который выделялся контекст (фактический n_ctx у указателя).
    private static func maxCtxLimit(_ ctx: OpaquePointer) -> Int {
        // n_ctx возвращает сама библиотека; хранить дубликат не нужно.
        Int(llama_n_ctx(ctx))
    }
    #endif

    // MARK: - Отмена и выгрузка

    public func cancelTurn() async {
        didCancelCurrentTurn = true
        // Флаг актора сам по себе до цикла декода не доходит: он крутится в
        // фоновой задаче и смотрит только в свой box. Дёргаем оба.
        liveBox?.cancel()
    }

    public func endSession() async {
        messages = []
        systemPrompt = ""
        tools = []
        didSendSystemPrompt = false
        nPast = 0
        kvPromptText = ""
        extraCallsLastTurn = 0
        sessionEpoch += 1
        // Веса при закрытии разговора НЕ выгружаем: модель остаётся загруженной
        // (контракт протокола — «закрыть разговор, оставив модель загруженной»),
        // а идущий ход сам доскончится и увидит смену номера разговора.
    }

    public func unload() async {
        #if canImport(LlamaBonsai)
        if isPreparing {
            // Идёт скачивание файла — прерываем его. Точка докачки сохраняется,
            // следующая попытка продолжит с места обрыва; держать загрузку ради
            // того, чтобы тут же выгрузить её результат, незачем.
            ModelDownloader.shared.pause()
        }
        if model != nil {
            journal.record(.engine, "GGUF-модель выгружается из памяти")
        }
        #endif
        // releaseWeights — единая горловина: под живым ходом он сам отменит ход и
        // отложит освобождение до его конца. Статус и имя бэкенда в этом случае
        // придут позже, вместе с `finishTurn` — обещать «простаиваем» раньше,
        // чем веса ушли, нельзя.
        let deferredUntilTurnEnd = isGenerating
        await releaseWeights()
        if !deferredUntilTurnEnd {
            setStatus(.idle)
        }
    }

    /// Освободить веса. ЕДИНСТВЕННАЯ ГОРЛОВИНА освобождения — free() не зовётся
    /// больше нигде.
    ///
    /// ⚠️ НЕПРОБИВАЕМЫЙ ИНВАРИАНТ: free() выполнится ТОЛЬКО когда `runTurn` не
    /// держит указатели. Фоновая задача декода получает model/ctx/smpl на вход и
    /// живёт, пока актор спит на `await` в `performTurn`; free() под ней — это
    /// use-after-free и крэш. Поэтому под живым ходом этот метод веса НЕ
    /// освобождает: он отменяет ход (флаг + фоновая задача через `liveBox`) и
    /// ставит `pendingRelease` — `finishTurn` отпустит веса сразу после конца хода,
    /// когда задача декода уже завершена. Тот же порядок, что у `unload()` и
    /// `handleMemoryWarning`, теперь работает для ВСЕХ, кто просит освобождения
    /// (включая `use(modelFile:)` посреди хода).
    private func releaseWeights() async {
        if isGenerating {
            didCancelCurrentTurn = true
            // Флаг актора сам по себе до цикла декода не доходит: он крутится в
            // фоновой задаче и смотрит только в свой box. Дёргаем оба.
            liveBox?.cancel()
            pendingRelease = true
            return
        }
        #if canImport(LlamaBonsai)
        if smpl != nil { llama_sampler_free(smpl!); smpl = nil }
        if ctx != nil { llama_free(ctx!); ctx = nil }
        if model != nil {
            journal.record(.engine, "GGUF-модель выгружена из памяти")
            llama_model_free(model!); model = nil
        }
        #endif
        nPast = 0
        kvPromptText = ""
        nCtx = 0
        // Имя бэкенда умирает вместе с весами — здесь, а не у каждого вызывающего:
        // иначе ранний выход «ход идёт» оставлял бы «Metal» при уже выгруженной модели.
        activeBackendName = "—"
    }

    // MARK: - Счётчики разговора

    /// Сколько занято в памяти разговора. Когда кэш жив — честный n_past библиотеки.
    ///
    /// ⚠️ ПОСЛЕ ОТМЕНЫ КЭШ СБРОШЕН, И ОТДАВАТЬ НОЛЬ НЕЛЬЗЯ. Цикл агента решает по
    /// этому числу, когда сворачивать разговор: ноль после каждого «Стопа» означал бы
    /// «места вагон» ровно тогда, когда разговор уже под потолком. Поэтому после
    /// сброса кэша отдаётся ОЦЕНКА того, сколько займёт СЛЕДУЮЩИЙ ход: он
    /// пересчитывает всю историю с нуля, и оценка строится по полной верстке
    /// разговора.
    /// ⚠️ Это ОЦЕНКА, не счётчик: грубое «примерно токен на 4 байта», взятое
    /// сверху, — для сворачивания запасливая цифра лучше точной в ноль.
    public func usedTokens() async -> Int? {
        #if canImport(LlamaBonsai)
        guard ctx != nil else { return nil }
        if nPast > 0 || messages.isEmpty { return nPast }
        return Self.estimatedTokens(of: renderPrompt())
        #else
        return nil
        #endif
    }

    /// Грубая оценка числа токенов по байтам текста: смешанная русско-английская
    /// речь у этого словаря — примерно токен на 4–5 байт, берём четыре (чуть сверху).
    private static func estimatedTokens(of text: String) -> Int {
        max(1, text.utf8.count / 4 + 1)
    }

    /// Потолок памяти разговора — ЧЕСТНЫЙ n_ctx, который мы посчитали от свободной
    /// памяти и реально выделили при загрузке (эталон честности — движок Apple:
    /// константа вместо выданного числа врёт человеку в счётчике). До загрузки
    /// отвечаем выбором человека как оценкой — разговору всё равно двигаться рано.
    public func contextLimitTokens() async -> Int {
        nCtx > 0 ? nCtx : ContextSizeSettings.chosenTokens
    }

    // MARK: - Жизненный цикл приложения

    public func handleEnteredBackground() async {
        await cancelTurn()
    }

    public func handleMemoryWarning() async {
        #if canImport(LlamaBonsai)
        journal.record(.engine, "Система попросила освободить память — выгружаю GGUF-модель",
                       detail: "свободно: \(Self.freeMemoryText()) · "
                             + "шла загрузка: \(isPreparing ? "да" : "нет") · "
                             + "шёл ход: \(isGenerating ? "да" : "нет")")
        if isPreparing {
            unloadRequested = true
            return
        }
        if isGenerating {
            // Ход идёт: releaseWeights сам не станет делать free() под ним —
            // отменит ход и отложит освобождение до его конца. Вернуть веса
            // сразу после такой просьбы системы — почти гарантированный отстрел
            // приложения (урок движка Apple).
            await releaseWeights()
            return
        }
        await releaseWeights()
        setStatus(.idle)
        #endif
    }

    // MARK: - Диагностика для «О программе»

    public func backendName() async -> String { activeBackendName }

    /// Ускорение здесь не отключается: подбора бэкенда нет, Metal вшит в пакет.
    public func isAccelerationDisabled() async -> Bool { false }

    public func enableAccelerationAgain() async {}

    public func runtimeFacts() async -> ModelRuntimeFacts {
        #if canImport(LlamaBonsai)
        let loaded = model != nil
        #else
        let loaded = false
        #endif
        return ModelRuntimeFacts(isLoaded: loaded,
                                 modelName: modelDisplayName,
                                 fileName: modelFileURL?.lastPathComponent ?? "—",
                                 byteSize: modelByteSize,
                                 backendName: activeBackendName)
    }

    // MARK: - Выбор размера контекста от памяти

    /// ЕДИНАЯ ФИЗИКА ПАМЯТИ ЭТОГО ДВИЖКА, одна на оба его решения — и на выбор
    /// размера разговора (`chooseContextTokens`), и на честный отказ до загрузки
    /// (`requiredMemoryMB`). Две разные арифметики в одной подготовке противоречили
    /// бы друг другу: гейт пустил бы то, что контекст потом задушил, — или наоборот.
    ///
    /// Веса считаются ПОЛНЫМ ФАЙЛОМ, и это не перестраховка, а замер: у владельца
    /// Bonsai 1 с файлом 3,9 ГБ пик процесса — 5,2 ГБ, то есть файл в памяти сидит
    /// ЦЕЛИКОМ плюс ~1,3 ГБ на всё остальное. mmap правда держит резидентной только
    /// рабочую часть, но у ПЛОТНОЙ модели в работе все слои — страницы файла
    /// перемалываются все, и «рабочая часть» на практике равна файлу.
    /// ⚠️ Правило `ModelFitRule` (доля 0,60) — про ДРУГОЕ: жёлтая пометка в списке
    /// моделей ДО установки, там своя дисциплина и свои оговорки. Здесь — физика
    /// живой загрузки, и она одна.
    private static func residentWeightsMB(fileBytes: Int64) -> Int {
        Int(max(0, fileBytes) / (1024 * 1024))
    }

    /// СКРОМНЫЙ n_ctx, посчитанный от os_proc_available_memory. Формула:
    ///
    ///   свободно (МБ) = MemoryGate.availableMemoryMB()
    ///   веса (МБ)     = размер файла целиком (см. `residentWeightsMB`)
    ///   запас (МБ)    = 1536 — буферы вычислений, сэмплер, процесс
    ///                   (живой замер владельца на Bonsai 1: файл 3,9 ГБ → пик 5,2 ГБ)
    ///   остаток (МБ)  = max(0, свободно − веса − запас)
    ///   n_ctx         = clamp(остаток × 1024 / 256, 1024, 8192)
    ///
    /// где 256 КБ/токен — консервативная оценка KV-кэша этой 27B-модели (см.
    /// `kvKBPerToken`). Итог режется ещё и выбором человека: просил меньше —
    /// работаем от его числа. Память измерить не удалось (Int.max) — честно
    /// признаём это и берём 4096: ни душим разговор, ни обещаем лишнего.
    private static func chooseContextTokens(fileBytes: Int64) -> Int {
        let available = MemoryGate.availableMemoryMB()
        let weightsMB = residentWeightsMB(fileBytes: fileBytes)
        let headroomMB: Int
        if available == Int.max {
            headroomMB = 4096
        } else {
            headroomMB = max(0, available - weightsMB - computeOverheadMB)
        }
        let estimated = headroomMB * 1024 / kvKBPerToken
        let clamped = min(max(estimated, minCtxTokens), maxCtxTokens)
        return min(clamped, max(minCtxTokens, ContextSizeSettings.chosenTokens))
    }

    /// Сколько памяти просить под загрузку GGUF: веса — весь файл (см.
    /// `residentWeightsMB`), плюс KV-кэш выбранного контекста и запас на буферы
    /// вычислений. Та же арифметика, что у выбора контекста, — иначе одно место
    /// считало бы, что памяти хватит, а второе резало бы разговор.
    /// ⚠️ Это РАСЧЁТ для честного отказа ДО загрузки, а не замер; живой замер здесь
    /// один — пик владельца на Bonsai 1, из которого взят запас на буферы.
    private static func requiredMemoryMB(fileBytes: Int64, contextTokens: Int) -> Int {
        let weightsMB = residentWeightsMB(fileBytes: fileBytes)
        let kvMB = contextTokens * kvKBPerToken / 1024
        return weightsMB + kvMB + computeOverheadMB
    }

    // MARK: - Заголовок GGUF (своими руками, до всякого C-слоя)

    /// Магия + версия формата. GGUF: 4 байта «GGUF» + uint32 LE версии.
    struct GGUFHeader {
        let version: UInt32
    }

    /// Кривой заголовок = мусор, который нельзя выдавать за ответ модели.
    /// Стоковый llama.cpp умеет грузить чужие/битые файлы молча — поэтому проверка
    /// СВОЯ, до передачи файла движку, с человеческим текстом ошибки.
    static func readGGUFHeader(_ url: URL) throws -> GGUFHeader {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw PocketAgentError.generationFailed(
                "Файл модели не открывается. Положите его заново через «Файлы».")
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else {
            throw PocketAgentError.generationFailed(
                "Файл модели пуст или обрывается в самом начале — он повреждён. "
                    + "Скачайте модель заново.")
        }
        guard head.prefix(4) == Data("GGUF".utf8) else {
            throw PocketAgentError.generationFailed(
                "Это не файл модели в формате GGUF — приложение такой файл не запустит. "
                    + "Проверьте, что скачали именно модель в формате GGUF.")
        }
        let version = head.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        }.littleEndian
        // v1 мёртв с 2023 года; читая его полями v2/v3, движок получает мусор,
        // который нельзя выдавать за ответ модели.
        guard version == 2 || version == 3 else {
            throw PocketAgentError.generationFailed(
                "Файл модели записан в формате GGUF версии \(version), которую движок "
                    + "не читает. Скачайте модель в стандартной версии (2 или 3).")
        }
        return GGUFHeader(version: version)
    }

    #if canImport(LlamaBonsai)
    /// Строковое поле метаданных GGUF после загрузки — для журнала.
    private static func meta(_ model: OpaquePointer, key: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let n = llama_model_meta_val_str(model, key, &buffer, buffer.count)
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Сколько позиций реально сидит в памяти разговора — честный счётчик
    /// библиотеки, а не наша оценка. У форка счётчик клеток заменён парой
    /// «взять память разговора → спросить наибольшую позицию» (пусто = −1 → 0).
    private static func usedCells(_ ctx: OpaquePointer) -> Int {
        Int(llama_memory_seq_pos_max(llama_get_memory(ctx), 0) + 1)
    }

    private static func makeSampler() -> UnsafeMutablePointer<llama_sampler>? {
        let params = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(params)
        // Те же настройки выбора слов, что у движка Apple: агенту нужна
        // предсказуемость, а не творчество; расходящиеся настройки = расходящееся
        // поведение между движками.
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.2))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
        return chain
    }
    #endif

    // MARK: - Мелочи

    /// Сколько памяти ещё можно занять, готовой строкой для журнала.
    private static func freeMemoryText() -> String {
        let megabytes = MemoryGate.availableMemoryMB()
        return megabytes == Int.max ? "неизвестно" : "\(megabytes) МБ"
    }

    /// Текст ошибки ПО-РУССКИ (та же дисциплина, что у движка Apple: английский
    /// оригинал чужой библиотеки на экран не проходит).
    private static func humanMessage(_ error: Error) -> String {
        if let known = error as? PocketAgentError {
            return known.errorDescription ?? SystemErrorText.russian(for: error)
        }
        return SystemErrorText.russian(for: error)
    }
}

// MARK: - Имя из задания

/// В задании движок назван LlamaRuntime, в коде — LlamaModelRuntime (ровно как у
/// движка Apple: MLXRuntime и MLXModelRuntime). Оставляем оба имени, чтобы сборка
/// не разъехалась из-за буквы.
public typealias LlamaRuntime = LlamaModelRuntime
