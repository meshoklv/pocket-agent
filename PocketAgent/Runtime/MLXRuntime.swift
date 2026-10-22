//
//  MLXRuntime.swift
//  PocketAgent / Runtime
//
//  Второй движок — от Apple (MLX). Реализует тот же протокол ModelRuntime, что и движок
//  Google (Contracts.swift), поэтому цикл агента и экраны про него ничего не знают.
//
//  ⚠️ ГЛАВНОЕ РЕШЕНИЕ ПРОДУКТА ВЫРАЖЕНО ЗДЕСЬ ОТСУТСТВИЕМ КОДА, А НЕ ЕГО НАЛИЧИЕМ.
//  Разговор создаётся СО списком действий, но БЕЗ обработчика действий (`toolDispatch`).
//  У Apple это не флажок, который можно забыть выставить, а устройство: в ChatSession.swift
//  (тег 3.31.4, строка 760) стоит условие «пришёл вызов действия И задан обработчик» —
//  и только тогда библиотека выполняет действие сама. Обработчика мы не передаём никогда,
//  поэтому вызов уходит наружу нам (там же, строка 762), мы показываем человеку карточку
//  и ждём нажатия. Дыры нет по построению — забывать нечего.
//
//  Это надёжнее, чем у движка Google: там запрет выражен полем `automaticToolCalling`,
//  которое надо не забыть выставить и мимо которого утекает потоковый режим.
//
//  ⛔ ДОПИСЫВАТЬ СЮДА `toolDispatch:` НЕЛЬЗЯ НИ ПРИ КАКИХ ОБСТОЯТЕЛЬСТВАХ. Это одна
//  строка, и она отдаёт файлы человека модели без единого подтверждения — то есть
//  отменяет весь продукт.
//
//  ⚠️ ПОЧЕМУ ЭТОТ ФАЙЛ ЗАМЕТНО ПРОЩЕ, ЧЕМ LiteRTRuntime.swift. Там половина объёма —
//  перебор настроек: модель Google на телефоне владельца молчала, и приложение подбирало
//  рабочую настройку само. Здесь такой беды пока НЕ НАБЛЮДАЛОСЬ ни разу, и заводить
//  лечение от ненаблюдавшейся болезни — значит на выдумку потратить и код, и минуты
//  человека. Понадобится — добавим по живому разбору, как добавляли там.
//
//  ⚠️ ПРОВЕРИТЬ ЭТОТ ФАЙЛ МОЖНО ТОЛЬКО НА ЖИВОМ ТЕЛЕФОНЕ. Движок Apple на симуляторе
//  не считает вообще — авторы пишут прямо: симулятор не даёт нужного семейства Metal.
//  Приложение там соберётся и запустится, но модель не поднимется никогда. Значит ни
//  одна облачная проверка не скажет, работает ли это; скажет только iPhone владельца.
//
//  ⚠️ ИМЕНА ПИШУТСЯ ПОЛНОСТЬЮ, С НАЗВАНИЕМ БИБЛИОТЕКИ ВПЕРЕДИ (MLXLMCommon.Tokenizer,
//  Tokenizers.Tokenizer). У Apple и у токенизатора совпадают имена сразу нескольких
//  типов — Tokenizer, ToolSpec, Message, TokenizerError. Без приставки сборка падает
//  на «ambiguous use of…», и падает не там, где ошибка.
//

import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers

public actor MLXModelRuntime: ModelRuntime, ModelBackendDiagnostics, ModelRuntimeFactsProviding {

    /// Куда пишем события: подъём модели, каждый ход, каждая ошибка.
    /// Тот же журнал, что у движка Google, — человек копирует его одной кнопкой,
    /// и разбирать поломку надо по одинаковым строкам, а не по двум разным.
    private var journal: EngineJournal { EngineJournal.shared }

    // MARK: - Где лежит модель

    /// Папка модели Apple. Именно ПАПКА, а не файл: у Apple модель — это восемь файлов
    /// рядом (веса, устройство модели, словарь, шаблон разговора), и без мелких из них
    /// она не запускается вовсе.
    ///
    /// ⚠️ Движок сам её НЕ ИЩЕТ, и это нарочно. Поиск, проверка состава и подсчёт размера —
    /// работа совсем другого куска приложения (шаг 4 плана, `MLXModelFolder.swift`), и он
    /// делается параллельно. Здесь папку просто задают снаружи: так два куска работы
    /// не спорят за одни и те же файлы.
    private var modelDirectory: URL?

    /// Модель, которую человек выбрал, но её папки на телефоне ещё нет — надо скачать.
    /// nil — качать нечего: папка либо уже на месте, либо человек ничего не выбирал.
    private var pendingModel: ModelDescriptor?

    /// Имя модели для человека и её размер — то, что показывает экран «О программе».
    /// Пока папку не задали, честно пусто: выдумывать имя незагруженной модели нельзя.
    private var modelDisplayName: String = "—"
    private var modelByteSize: Int64 = 0

    // MARK: - Состояние

    /// Загруженные веса. Живут до `unload()`.
    private var container: ModelContainer?

    /// Разговор с накопленной памятью. У Apple он же держит и кэш вычислений,
    /// поэтому новый разговор — это новый объект, а не сброс поля.
    private var session: ChatSession?

    private var status: ModelRuntimeStatus = .idle
    private var statusListeners: [UUID: AsyncStream<ModelRuntimeStatus>.Continuation] = [:]

    private var systemPrompt: String = ""

    /// Системную инструкцию этому разговору уже отправляли.
    ///
    /// ⚠️ ЗАЧЕМ ФЛАГ, А НЕ ПОЛЕ `instructions` У РАЗГОВОРА. У Apple поле `instructions`
    /// подставляется в КАЖДЫЙ ход (ChatSession.swift, строки 592–594: системное сообщение
    /// добавляется в начало сообщений безусловно, независимо от того, есть уже память
    /// разговора или нет). Для чата на два вопроса это незаметно, а у нас ход за ходом
    /// идёт вся задача — и длинная инструкция уезжала бы модели по десятому разу,
    /// съедая память разговора и путая модель на 2 млрд параметров. Поэтому поле
    /// `instructions` оставляем пустым, а инструкцию отправляем сами — ровно один раз,
    /// первым сообщением разговора.
    private var didSendSystemPrompt = false

    private var isPreparing = false
    private var isGenerating = false

    /// Текущий ход прерван человеком («Стоп») или уходом в фон.
    private var didCancelCurrentTurn = false

    /// Система попросила освободить память, пока мы поднимали веса.
    /// Та же защита, что и у движка Google: вернуть веса обратно сразу после такой
    /// просьбы — почти гарантированный отстрел приложения системой.
    private var unloadRequested = false

    /// Вызовы действий, которые модель попросила СВЕРХ первого.
    ///
    /// ⚠️ Мы выполняем ровно одно действие за ход — это продуктовое решение, а не
    /// ограничение движка. Но остальные вызовы обязаны получить ответ: иначе модель
    /// считает их выполненными и следующий шаг строит на том, чего не было.
    /// Храним только номера вызовов: больше для ответа ничего и не нужно. Номер у Apple
    /// может отсутствовать вовсе (`ToolCall.id` — необязательный), поэтому и здесь он
    /// необязательный: пустого номера в ответе просто не будет.
    private var unansweredCallIDs: [String?] = []

    /// Сколько слов-кусочков разговор съел по счёту САМОГО движка.
    ///
    /// ⚠️ Считаем сами и складываем по ходам. У Apple нет вопроса «сколько занято» —
    /// есть только отчёт о каждом ходе: сколько кусочков было во входе и сколько
    /// он написал. Память разговора у Apple не сбрасывается между ходами, поэтому
    /// сумма этих чисел и есть занятое. Число НАШЕ, и в журнале оно так и названо.
    private var accountedTokens = 0

    /// На чём считает движок.
    ///
    /// ⚠️ ЗДЕСЬ НЕ ПОДБОР, КАК У ДВИЖКА GOOGLE, А ПРОСТО ФАКТ: мы НЕ выбираем расчёт
    /// вообще, а берём тот, что у библиотеки Apple стоит по умолчанию, — видеочип.
    /// Расчёт на процессоре у неё существует (`MLX.Device.cpu`), но мы его не включаем
    /// и не пробовали: языковая модель на нём на телефоне — вещь непроверенная, и выдавать
    /// «работает» за факт мы не будем. Понадобится запасной путь — заведём по живому
    /// разбору, а не заранее.
    public private(set) var activeBackendName: String = "—"

    /// - Parameter modelDirectory: папка модели Apple. Можно не задавать сейчас —
    ///   человек выберет модель позже, и папку подставят через `use(modelDirectory:)`.
    public init(modelDirectory: URL? = nil) {
        self.modelDirectory = modelDirectory
        if let modelDirectory {
            self.modelDisplayName = modelDirectory.lastPathComponent
        }
    }

    /// Сказать движку, с какой папкой работать.
    ///
    /// ⚠️ Смена папки ВЫГРУЖАЕТ прежние веса, и это обязательно: две модели одновременно
    /// в памяти телефона не помещаются, а система в таком случае закрывает приложение
    /// молча — человек видит просто исчезнувшее приложение и не понимает, что случилось.
    public func use(modelDirectory url: URL, displayName: String? = nil, byteSize: Int64 = 0) async {
        if modelDirectory != url, container != nil {
            journal.record(.engine, "Меняю модель — прежнюю выгружаю из памяти")
            await unload()
        }
        modelDirectory = url
        pendingModel = nil
        modelDisplayName = displayName ?? url.lastPathComponent
        modelByteSize = byteSize
    }

    /// Сказать движку, какую модель он должен поднять, когда её папки на телефоне
    /// ещё НЕТ: она известна по описанию, но её надо скачать.
    ///
    /// ⚠️ Загрузку начинает `prepare()`, а не этот вызов: человек мог просто ткнуть
    /// в строку списка, чтобы почитать про модель, — качать гигабайты по касанию нельзя.
    public func use(pendingModel model: ModelDescriptor) async {
        guard model.isFolderModel else { return }
        // Та же защита, что и при смене папки: две модели в памяти телефона не помещаются.
        if container != nil {
            journal.record(.engine, "Меняю модель — прежнюю выгружаю из памяти")
            await unload()
        }
        modelDirectory = nil
        pendingModel = model
        modelDisplayName = model.displayName
        modelByteSize = model.byteSize
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
        if case .ready = status, container != nil { return }
        guard !isPreparing else { return }

        isPreparing = true
        unloadRequested = false
        defer { isPreparing = false }

        journal.startStage(.prepare)
        journal.record(.engine, "Готовлю модель Apple к работе")

        do {
            // Папки может ещё не быть на телефоне — тогда её сначала скачивают.
            let directory = try await ensureModelFolder()

            // Проверка состава папки — чужая, общая на всё приложение (`MLXModelFolder`).
            //
            // ⚠️ СВОЕЙ ПРОВЕРКИ ЗДЕСЬ НЕТ НАМЕРЕННО. Две разные проверки «годная ли это
            // папка» однажды разошлись бы, и получилось бы худшее: список моделей показывает
            // папку годной, а движок её не берёт — человеку не за что зацепиться. Пусть
            // ответ будет один и тот же, из одного места.
            setStatus(.verifying)
            let report = try MLXModelFolder.inspect(directory)

            // ⚠️ ВТОРАЯ ЗАСТАВА (первая стоит до загрузки, см. `ensureModelFolder`).
            // Сюда приходят папки, которые никто не качал: человек принёс их через
            // «Файлы» или скачал в прошлый раз. Спрашиваем движок, умеет ли он такое
            // устройство, ДО того, как отдать ему папку: иначе библиотека ответит
            // по-английски («Unsupported model type: …»), и это увидит человек.
            try await refuseIfEngineCannotRun(folderReport: report)

            // ⚠️ ОПИСАНИЕ БЕРЁМ ОТ САМОЙ ПАПКИ, А НЕ ОТ ТОГО, ЧТО НАМ СКАЗАЛИ ПРИ ВЫБОРЕ.
            // Папку могли заменить под тем же именем — и тогда на экране «О программе»
            // висело бы имя и размер чужой модели. Ровно на этом уже обжигались с движком
            // Google: описание, снятое при запуске приложения, объявляло свежепоставленный
            // файл повреждённым.
            let described = MLXModelFolder.descriptor(for: report)
            modelDisplayName = described.displayName
            modelByteSize = described.byteSize

            // Без шаблона разговора модель не узнает, что у неё есть действия, — она сможет
            // только разговаривать. Молчать об этом нельзя: человек решит, что сломан агент,
            // а на самом деле у него просто не та сборка модели.
            if !report.hasChatTemplate {
                journal.record(.failure,
                               "В этой модели нет шаблона разговора — с файлами она работать не сможет, "
                             + "только разговаривать",
                               detail: "папка: \(report.folderName) · "
                                     + "нужна сборка модели, обученная разговору (с пометкой «it»)")
            }

            setStatus(.loading)
            journal.record(.engine, "Поднимаю модель",
                           detail: "папка: \(directory.lastPathComponent) · "
                                 + "свободно памяти: \(Self.freeMemoryText())")

            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: MLXTokenizerLoader()
            )

            // Пока грузились веса, система попросила освободить память. Отдаём загруженное
            // сразу и НЕ объявляем модель готовой: вернуть веса обратно после такой просьбы
            // почти всегда значит быть закрытым системой на следующем вздохе.
            if unloadRequested {
                unloadRequested = false
                throw PocketAgentError.memoryPressureDuringLoad
            }

            container = loaded
            activeBackendName = "GPU"
            accountedTokens = 0

            journal.noteReady(modelName: modelDisplayName,
                              fileName: directory.lastPathComponent,
                              fileSizeText: HumanFormat.bytes(modelByteSize),
                              backend: activeBackendName,
                              // Движок Apple память разговора не выделяет заранее и потолка
                              // ей не ставит — просить нечего, поэтому здесь честное «ничего».
                              askedTokens: nil,
                              grantedTokens: ContextSizeSettings.chosenTokens,
                              chosenTokens: ContextSizeSettings.chosenTokens,
                              stepNumber: 0,
                              stepName: "движок Apple",
                              freeMemoryMB: MemoryGate.availableMemoryMB())
            setStatus(.ready)
        } catch {
            container = nil
            session = nil
            let human = Self.humanMessage(error)
            journal.recordFailure(stage: "загрузка модели Apple",
                                  human: human,
                                  technical: RuntimeJournal.technicalText(for: error))
            setStatus(.failed(message: human))
            throw error
        }
    }

    // MARK: - Где взять папку модели

    /// Папка модели, готовая к загрузке весов. Нет на телефоне — скачиваем.
    ///
    /// ⚠️ ЭТО БЛИЗНЕЦ `ensureModelFile()` У ДВИЖКА GOOGLE, и намеренно: человек нажимает
    /// одну и ту же кнопку «Скачать», а какого вида окажется модель — файл или папка —
    /// его не касается вовсе. Разница ровно одна: там качается один файл, здесь — список
    /// файлов с общим ходом загрузки (`ModelDownloader.downloadFolder`).
    private func ensureModelFolder() async throws -> URL {
        // 1. Папку уже задали снаружи (человек положил её через «Файлы» или скачал раньше).
        if let directory = modelDirectory,
           FileManager.default.fileExists(atPath: directory.path) {
            return directory
        }

        guard let wanted = pendingModel, wanted.isFolderModel else {
            throw PocketAgentError.modelFileMissing
        }

        // 2. Модель могли скачать в прошлый раз — тогда качать нечего.
        if let ready = try? ModelFolderDownload.finalFolderURL(for: wanted),
           (try? MLXModelFolder.inspect(ready)) != nil {
            journal.record(.engine, "Беру модель Apple, которая уже лежит на телефоне",
                           detail: "папка: \(ready.lastPathComponent) · "
                                 + "размер: \(HumanFormat.bytes(ModelStorage.byteSize(of: ready)))")
            adopt(folder: ready, model: wanted)
            return ready
        }

        // 3. ⚠️ ГЛАВНАЯ ЗАСТАВА: ДО ПЕРВОГО ГИГАБАЙТА. Спрашиваем у справочника одно
        // маленькое описание модели (килобайты) и сверяем устройство с тем, что движок
        // Apple вообще умеет. Не умеет — отказываем здесь, не потратив ни минуты
        // человека. Ради этого весь заход и делался (ROADMAP, 12.8).
        try await refuseIfEngineCannotRun(pendingModel: wanted)

        // 4. Качаем. Ход загрузки уходит на экран одной полосой на всю модель —
        // человеку незачем считать, какой из десяти файлов сейчас едет.
        journal.record(.engine, "Модели Apple нет на телефоне — скачиваю её папку",
                       detail: "модель: \(wanted.displayName) · "
                             + "файлов: \(wanted.folderFileList.count) · "
                             + "всего: \(HumanFormat.bytes(wanted.byteSize))")
        // Первым кадром показываем СВОЁ место, а не общий счётчик загрузчика: он помнит
        // долю последнего скачанного файла, и после мелкого описания это были бы «100 %».
        setStatus(.downloading(progress: ModelDownloader.shared.folderProgress(for: wanted)))

        let folder = try await ModelDownloader.shared.downloadFolder(wanted) { [weak self] progress in
            Task { await self?.setStatus(.downloading(progress: progress)) }
        }

        journal.record(.engine, "Папка модели Apple скачана целиком",
                       detail: "папка: \(folder.lastPathComponent) · "
                             + "размер: \(HumanFormat.bytes(ModelStorage.byteSize(of: folder)))")
        adopt(folder: folder, model: wanted)
        return folder
    }

    // MARK: - Запустится ли эта модель вообще

    /// Проверить ДО загрузки: умеет ли движок Apple модели такого устройства.
    ///
    /// ⚠️ ЗАЧЕМ ЭТО ЗДЕСЬ, А НЕ В ЗАГРУЗЧИКЕ. Загрузчик занят байтами и не знает ничего
    /// про то, что умеет движок; движок знает, но раньше узнавал последним — уже после
    /// того, как гигабайты приехали. Владелец 10.08 потратил своё время ровно на этом.
    ///
    /// ⚠️ ОТКАЗ ТОЛЬКО ПО ЧЁТКОМУ ОТВЕТУ. Не достучались до справочника, нет связи,
    /// описание не прочиталось — качаем как раньше и честно пишем в журнал «не проверяли».
    /// Запрещать человеку из-за собственной неудачи мы права не имеем.
    private func refuseIfEngineCannotRun(pendingModel model: ModelDescriptor) async throws {
        guard !model.repoID.isEmpty else {
            journal.record(.engine, "Устройство модели проверить не по чему — качаю как есть",
                           detail: "модель: \(model.displayName) · откуда её брать, приложение не знает")
            return
        }

        let verdict = await MLXArchitectures.verdict(forRepo: model.repoID, revision: model.repoCommit)
        switch verdict {
        case .runnable(let type):
            journal.record(.engine, "Устройство модели проверено до загрузки — движок Apple такую поднимает",
                           detail: "устройство: \(type) · проверено по описанию модели, "
                                 + "весом в килобайты")
        case .unknown:
            journal.record(.engine, "Устройство модели узнать не удалось — качаю как есть",
                           detail: "модель: \(model.displayName) · описание не отдали "
                                 + "(нет связи или закрытый репозиторий)")
        case .notRunnable(let type):
            throw deadEnd(modelID: model.id, modelName: model.displayName, modelType: type,
                          stage: "проверка устройства модели до загрузки")
        }
    }

    /// То же самое для папки, которая уже лежит на телефоне.
    private func refuseIfEngineCannotRun(folderReport report: MLXFolderReport) async throws {
        guard let type = report.modelType else {
            journal.record(.engine, "В описании модели не сказано, как она устроена — пробую поднять как есть",
                           detail: "папка: \(report.folderName)")
            return
        }
        let verdict = await MLXArchitectures.liveVerdict(forModelType: type)
        if case .notRunnable = verdict {
            throw deadEnd(modelID: MLXModelFolder.descriptor(for: report).id,
                          modelName: report.folderName,
                          modelType: type,
                          stage: "проверка устройства модели перед подъёмом")
        }
    }

    /// Один и тот же отказ на оба случая: записать в журнал, запомнить тупик, вернуть
    /// человеческую ошибку.
    ///
    /// ⚠️ ТУПИК ЗАПОМИНАЕМ НАРОЧНО. Без этого экран подготовки покажет обычное
    /// «Загрузка прервалась… Продолжить» — кнопку, которая ничего не изменит, сколько
    /// её ни жми. Именно на неё владелец и нажимал.
    private func deadEnd(modelID: String,
                         modelName: String,
                         modelType: String,
                         stage: String) -> Error {
        let error = MLXArchitectureError.engineCannotRun(modelName: modelName, modelType: modelType)
        let human = error.errorDescription ?? MLXArchitectures.notRunnableHeadline
        journal.recordFailure(stage: stage,
                              human: human,
                              // Английское слово устройства живёт ТОЛЬКО здесь, в журнале.
                              technical: "model_type: \(modelType) — нет в LLMTypeRegistry "
                                       + "(mlx-swift-lm \(MLXArchitectures.snapshotLibraryVersion)); "
                                       + "модель: \(modelName)")
        ModelDeadEnds.shared.mark(modelID: modelID, reason: human)
        return error
    }

    /// Закрепить скачанную папку за выбором человека: со следующего запуска приложение
    /// возьмёт именно её и качать больше ничего не будет.
    private func adopt(folder: URL, model: ModelDescriptor) {
        modelDirectory = folder
        pendingModel = nil
        ModelSpec.select(model, fileURL: folder)
    }

    // MARK: - Разговор

    public func beginSession(systemPrompt: String, tools: [ToolDeclaration]) async throws {
        guard let container else { throw PocketAgentError.runtimeNotReady }

        self.systemPrompt = systemPrompt
        MLXToolSchemas.warnIfOutOfSync(with: tools)

        // Прежний разговор отпускаем ДО создания нового: вместе с ним освобождается
        // и его память вычислений, а она измеряется сотнями мегабайт.
        session = nil
        unansweredCallIDs = []
        didSendSystemPrompt = false
        accountedTokens = 0

        let specs = MLXToolSchemas.tools(matching: tools)

        // ⚠️ ВОТ ЭТИ ДВЕ СТРОКИ И ЕСТЬ ВЕСЬ ПРОДУКТ: `tools` передаём, `toolDispatch` — НЕТ.
        // Пока обработчик не задан, библиотека не имеет права выполнить ни одного действия —
        // она только сообщает нам, что модель его попросила. Дальше человек жмёт кнопку.
        // Подробнее — в шапке файла, там же ссылка на строку чужой библиотеки.
        session = ChatSession(
            container,
            // Пусто намеренно — инструкцию отправляем первым сообщением сами,
            // см. объяснение у `didSendSystemPrompt`.
            instructions: nil,
            generateParameters: Self.generateParameters,
            tools: specs
        )

        journal.record(.engine, "Начал разговор с моделью Apple",
                       detail: "действий в наборе: \(specs.count) · "
                             + "выполнять их сама модель не может — только просить · "
                             + "выбор слов: наш строгий")
    }

    /// Настройки выбора слов. Агенту нужна предсказуемость, а не творчество —
    /// числа те же, что у движка Google, чтобы поведение не расходилось между движками.
    private static let generateParameters = GenerateParameters(
        temperature: 0.2,
        topP: 0.95,
        topK: 40
    )

    public func send(userText: String) async throws -> ModelTurn {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PocketAgentError.generationFailed("Пустой запрос.")
        }
        // Человек начал новый ход сам — отвечать на отброшенные вызовы прошлого хода
        // уже некуда: их номера относятся к другому шагу.
        unansweredCallIDs = []

        var messages: [Chat.Message] = []
        if !didSendSystemPrompt, !systemPrompt.isEmpty {
            messages.append(.system(systemPrompt))
            didSendSystemPrompt = true
        }
        messages.append(.user(trimmed))
        return try await performTurn(messages)
    }

    public func send(toolResult: ToolResult) async throws -> ModelTurn {
        // Ответ действия уходит модели тем же путём и при отказе человека: модель обязана
        // узнать, что действие не выполнено, иначе следующий шаг она построит на выдумке.
        //
        // ⚠️ Уходит ЧЕРЕЗ ТОТ ЖЕ РАЗГОВОР, а не через новый: у Apple ответ действия —
        // это обычное сообщение с ролью «ответ действия» (Chat.swift:87), и продолжение
        // разговора им сохраняет всю накопленную память (ChatSession.swift:460, там прямо
        // написано: используйте это, чтобы не пересобирать разговор заново). Собери мы
        // разговор заново — телефон пересчитал бы всю переписку с нуля на каждом шаге.
        var messages: [Chat.Message] = [
            .tool(Self.text(of: toolResult.payload), id: toolResult.callID.isEmpty ? nil : toolResult.callID)
        ]

        // Отказы на лишние вызовы уходят вместе с настоящим ответом — одним ходом,
        // чтобы у модели не осталось ни одного вызова без ответа.
        for skippedID in unansweredCallIDs {
            messages.append(.tool(Self.oneActionPerTurnNotice, id: skippedID))
        }
        unansweredCallIDs = []

        return try await performTurn(messages)
    }

    /// Что отвечаем на лишние вызовы действий в одном ходе.
    private static let oneActionPerTurnNotice =
        "За один ход выполняется ровно одно действие. Это действие не выполнено — "
        + "повтори его следующим ходом, если оно всё ещё нужно."

    /// Тело ответа действия — строкой для модели.
    ///
    /// ⚠️ Список и набор полей отдаём как JSON, а простой текст — как есть. Заворачивать
    /// одну строку в кавычки и скобки незачем: каждый лишний знак оплачивается памятью
    /// разговора, а модель на 2 млрд параметров читает обычный текст лучше, чем JSON.
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

    /// Один ход разговора: отправили — получили либо просьбу о действии, либо текст.
    ///
    /// ⚠️ ПОЧЕМУ ЗДЕСЬ ОТВЕТ ПО ЧАСТЯМ, ХОТЯ У ДВИЖКА GOOGLE ТАКОЙ ПУТЬ ЗАПРЕЩЁН.
    /// Там ответ по частям игнорирует запрет самовольного выполнения действий и выполняет
    /// их сам — потому он и вынесен из цикла агента. Здесь всё наоборот: `streamDetails` —
    /// ЕДИНСТВЕННЫЙ путь, по которому просьба о действии доходит до нас (ChatSession.swift,
    /// строка 762). Обычный `respond(to:)` отдаёт только собранный текст, и просьбы
    /// о действиях в нём теряются молча — а молча потерянное действие это худшее,
    /// что может случиться с агентом: он «отвечает», не сделав ничего.
    private func performTurn(_ messages: [Chat.Message]) async throws -> ModelTurn {
        guard let session else { throw PocketAgentError.sessionNotStarted }
        guard !isGenerating else {
            throw PocketAgentError.generationFailed("Предыдущий ответ ещё не готов.")
        }

        isGenerating = true
        didCancelCurrentTurn = false
        defer { isGenerating = false }

        // Засечка хода — самая ценная улика журнала: «ответила пусто за 0,00 с»
        // и «думала 14 с и ответила пусто» лечатся совершенно по-разному.
        journal.startStage(.turn)

        var text = ""
        var calls: [ToolCall] = []
        var promptTokens = 0
        var generatedTokens = 0

        do {
            for try await item in session.streamDetails(to: messages) {
                // Человек нажал «Стоп» или приложение ушло в фон. Выходим из перебора —
                // и вместе с ним библиотека сама прекращает счёт: поток, у которого
                // никто больше не забирает куски, отменяет свою работу.
                if didCancelCurrentTurn || Task.isCancelled { break }

                switch item {
                case .chunk(let piece):
                    text += piece
                case .toolCall(let call):
                    // ⚠️ ЗДЕСЬ ДЕЙСТВИЕ ТОЛЬКО ЗАПИСЫВАЕТСЯ, И БОЛЬШЕ НИЧЕГО. Выполнить
                    // его отсюда нельзя даже случайно: исполнителей у движка нет вовсе,
                    // они живут в цикле агента и включаются после нажатия человека.
                    calls.append(call)
                case .info(let info):
                    promptTokens = info.promptTokenCount
                    generatedTokens = info.generationTokenCount
                }
            }
        } catch {
            // Ход прервали мы сами. Без этой проверки нажатие «Стоп» выглядело бы
            // для человека поломкой: он возвращался из мессенджера и видел «Не получилось».
            if didCancelCurrentTurn || error is CancellationError {
                didCancelCurrentTurn = false
                throw PocketAgentError.generationCancelled
            }
            journal.recordFailure(stage: "ход модели Apple",
                                  human: Self.humanMessage(error),
                                  technical: RuntimeJournal.technicalText(for: error))
            throw Self.mapGenerationError(error)
        }

        if didCancelCurrentTurn {
            didCancelCurrentTurn = false
            throw PocketAgentError.generationCancelled
        }

        accountedTokens += promptTokens + generatedTokens
        journal.noteTurnFinished(engineTokens: accountedTokens,
                                 limitTokens: ContextSizeSettings.chosenTokens,
                                 stepNumber: 0,
                                 stepName: "движок Apple")

        return interpret(text: text, calls: calls)
    }

    /// Превратить ответ модели в ход агента: заявка на действие или текст.
    private func interpret(text: String, calls: [ToolCall]) -> ModelTurn {
        if let call = calls.first {
            // Берём ТОЛЬКО первый вызов: один шаг — одно подтверждение. Остальные
            // запоминаем, чтобы следующим сообщением честно ответить на них отказом,
            // а не делать вид, что их не было.
            unansweredCallIDs = calls.dropFirst().map(\.id)
            #if DEBUG
            if !unansweredCallIDs.isEmpty {
                print("[MLXRuntime] Модель попросила \(calls.count) действий за ход; "
                    + "выполняем первое, на остальные отвечаем отказом.")
            }
            #endif

            // ⚠️ Аргументы приходят разобранными по видам значений (строка, целое,
            // дробное, да/нет, список, набор полей). Разворачиваем их в обычные значения
            // и отдаём в ЕДИНСТВЕННУЮ точку приведения к строкам из Contracts.swift —
            // ту же самую, что работает для движка Google. Своего приведения здесь нет
            // намеренно: два разных приведения однажды разошлись бы, и «да» от одного
            // движка стало бы единицей от другого.
            let invocation = ToolInvocation(rawName: call.function.name,
                                            callID: call.id ?? "",
                                            rawArguments: call.function.arguments.mapValues(\.anyValue))
            journal.noteToolInvocation(invocation, concurrentCalls: calls.count)
            return .toolRequest(invocation)
        }

        // ⚠️ Пустой ответ — НЕ ошибка. Модель на 2 млрд параметров регулярно отдаёт пустой
        // ход после длинного ответа действия. Цикл агента просто попросит её повторить.
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            journal.record(.turn, "Модель ответила пусто")
        } else {
            journal.noteModelAnswerText(clean)
        }
        return .text(clean)
    }

    // MARK: - Отмена и выгрузка

    public func cancelTurn() async {
        // Актор впускает этот вызов, пока ход ждёт ответа: сам ход стоит на `await`.
        // Флага достаточно — перебор кусков выйдет на ближайшем из них, а брошенный
        // поток библиотека отменяет сама.
        didCancelCurrentTurn = true
    }

    public func endSession() async {
        unansweredCallIDs = []
        session = nil
        systemPrompt = ""
        didSendSystemPrompt = false
        accountedTokens = 0
        isGenerating = false
    }

    public func unload() async {
        // Явного «закрыть» у движка Apple нет — веса освобождаются, когда умирает
        // последняя ссылка. Поэтому выгрузка это обнуление ссылок, и порядок важен:
        // сначала разговор (он держит память вычислений), потом сами веса.
        if container != nil {
            journal.record(.engine, "Модель Apple выгружена из памяти")
        }
        unansweredCallIDs = []
        session = nil
        container = nil
        isGenerating = false
        didSendSystemPrompt = false
        accountedTokens = 0
        activeBackendName = "—"
        setStatus(.idle)
    }

    public func usedTokens() async -> Int? {
        session == nil ? nil : accountedTokens
    }

    /// Потолок памяти разговора.
    ///
    /// ⚠️ У движка Apple потолка НЕТ — он не выделяет память разговора заранее и не режет
    /// её на заданном числе, в отличие от движка Google с его 4 096. Спрашивать «сколько
    /// дали» здесь не у кого. Поэтому отдаём выбор человека со страницы «О программе»:
    /// это и есть то число, в которое цикл агента укладывает разговор. Показать вместо
    /// него константу значило бы соврать человеку в счётчике, ради которого он и заведён.
    public func contextLimitTokens() async -> Int { ContextSizeSettings.chosenTokens }

    // MARK: - Жизненный цикл приложения

    /// Приложение уходит в фон: генерацию всё равно прервёт система — прерываем сами
    /// и аккуратно. Имя метода то же, что у движка Google: сборщик приложения зовёт его
    /// не глядя на то, какой движок сейчас работает.
    public func handleEnteredBackground() async {
        await cancelTurn()
    }

    /// Система жалуется на память: выгружаем веса целиком. Разговор при этом теряется —
    /// иначе нас закроют совсем, и человек не поймёт, почему приложение исчезло.
    public func handleMemoryWarning() async {
        journal.record(.engine, "Система попросила освободить память — выгружаю модель Apple",
                       detail: "свободно: \(Self.freeMemoryText()) · "
                             + "шла загрузка: \(isPreparing ? "да" : "нет")")
        if isPreparing { unloadRequested = true }
        await unload()
    }

    // MARK: - Диагностика для «О программе»

    /// На чём считает модель. У движка Apple это всегда видеочип — мы его не выбираем,
    /// он у библиотеки стоит по умолчанию (см. объяснение у `activeBackendName`).
    public func backendName() async -> String { activeBackendName }

    /// Ускорение у этого движка мы никогда не отключаем: подбора расчёта здесь нет,
    /// а значит нет и запрета, который надо было бы снимать.
    public func isAccelerationDisabled() async -> Bool { false }

    /// Кнопка «Попробовать ускорение заново» для этого движка ничего не значит:
    /// отключать было нечего. Молча ничего не делаем — врать кнопкой хуже, чем молчать.
    public func enableAccelerationAgain() async {}

    public func runtimeFacts() async -> ModelRuntimeFacts {
        ModelRuntimeFacts(isLoaded: container != nil,
                          modelName: modelDisplayName,
                          fileName: modelDirectory?.lastPathComponent ?? "—",
                          byteSize: modelByteSize,
                          backendName: activeBackendName)
    }

    // MARK: - Мелочи

    /// Сколько памяти ещё можно занять, готовой строкой для журнала.
    /// На части устройств система отвечает «не знаю» — печатать двадцатизначное число
    /// значит подсунуть человеку выдуманный факт, поэтому так и пишем: неизвестно.
    private static func freeMemoryText() -> String {
        let megabytes = MemoryGate.availableMemoryMB()
        return megabytes == Int.max ? "неизвестно" : "\(megabytes) МБ"
    }

    private static func mapGenerationError(_ error: Error) -> Error {
        if error is CancellationError { return PocketAgentError.generationCancelled }
        if let known = error as? PocketAgentError { return known }
        return PocketAgentError.generationFailed(humanMessage(error))
    }

    /// Текст ошибки ПО-РУССКИ.
    ///
    /// ⚠️ У библиотеки Apple все тексты английские («Model configuration … has not been
    /// resolved», «No KV cache is available»), и подставлять их прямо в русскую фразу
    /// нельзя — человек прочитает набор чужих слов и не поймёт ни что случилось,
    /// ни что делать. Здесь разбираем то, что можем узнать по виду ошибки, а точный
    /// английский оригинал уходит в журнал отдельной технической строкой.
    private static func humanMessage(_ error: Error) -> String {
        if let known = error as? PocketAgentError {
            return known.errorDescription ?? SystemErrorText.russian(for: error)
        }
        if error is MLXLMCommon.ModelConfiguration.DirectoryError {
            return "Папка модели не найдена. Положите её заново через «Файлы»."
        }
        // ⚠️ ИМЕННО ЭТА ВЕТКА ЗАКРЫВАЕТ ЖАЛОБУ ВЛАДЕЛЬЦА. Библиотека отвечает
        // английской строкой («Unsupported model type: qwen3_5_mtp»), и раньше она
        // доезжала прямо на экран. Теперь до этого места дело почти не доходит —
        // устройство модели проверяется до загрузки, — но если библиотека откажет
        // по-своему, человек всё равно прочитает объяснение, а не чужие слова.
        if let factory = error as? MLXLMCommon.ModelFactoryError {
            switch factory {
            case .unsupportedModelType(let type):
                return MLXArchitectures.humanText(forModelType: type)
            case .unsupportedProcessorType, .noModelFactoryAvailable:
                return MLXArchitectures.notRunnableHeadline
                    + " Приложение поднимает модели других семейств: Gemma, Qwen, Llama, "
                    + "Mistral, Phi, GLM и близкие к ним."
            case .configurationFileError, .configurationDecodingError, .invalidConfiguration:
                return "Описание модели в её папке не читается — скорее всего, папка скопирована "
                    + "не целиком. Скачайте модель заново."
            }
        }
        if let tokenizerError = error as? Tokenizers.TokenizerError {
            switch tokenizerError {
            case .missingConfig, .missingVocab, .malformedVocab:
                return "В папке модели не хватает словаря или он повреждён. Скачайте модель заново."
            case .missingChatTemplate:
                return "В этой модели нет шаблона разговора — работать с файлами она не сможет. "
                     + "Нужна модель с пометкой «it» (обученная разговору)."
            default:
                return "Словарь модели не подошёл. Скачайте модель заново."
            }
        }
        return SystemErrorText.russian(for: error)
    }
}

// MARK: - Словарь модели

/// Переходник между словарём из чужой библиотеки и тем, каким его хочет видеть Apple.
///
/// ⚠️ ЗАЧЕМ ОН ВООБЩЕ НУЖЕН — ЭТО ПОПРАВКА К РАЗВЕДКЕ. В плане написано, что разбор
/// текста у Apple «весь свой, внутри». По факту (тег 3.31.4) MLXLMCommon объявляет
/// только ПРОТОКОЛ словаря, а готовой реализации в нужных нам продуктах нет ни одной.
/// У Apple она лежит отдельным продуктом и представляет собой макрос, разворачивающийся
/// ровно в этот переходник. Макрос мы не берём: он тянет за собой разбор синтаксиса Swift
/// и плагин компилятора — лишние минуты каждой облачной сборки ради сорока строк,
/// которые проще написать и видеть глазами.
///
/// ⚠️ Каждое имя типа написано полностью. У двух библиотек совпадают имена Tokenizer,
/// ToolSpec, Message и TokenizerError — без приставки сборка падает с «ambiguous use of».
struct MLXTokenizerLoader: MLXLMCommon.TokenizerLoader {

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return Bridge(upstream)
    }

    private struct Bridge: MLXLMCommon.Tokenizer {
        private let upstream: any Tokenizers.Tokenizer

        init(_ upstream: any Tokenizers.Tokenizer) {
            self.upstream = upstream
        }

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
        }

        // ⚠️ Имена методов у двух библиотек разные: у Apple `tokenIds`, у словаря `tokens`.
        // Это не описка и не вольность — так у них и написано.
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }

        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }

        /// ⚠️ ВОТ ЗДЕСЬ И ПРОХОДИТ СПИСОК ДЕЙСТВИЙ. Шаблон разговора берётся из самой
        /// модели (файл рядом с весами), и действия подставляются в него ЭТИМ вызовом.
        /// Потеряй мы здесь `tools` — модель просто не узнала бы, что у неё есть руки,
        /// и принялась бы пересказывать действия словами вместо того, чтобы их звать.
        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            do {
                return try upstream.applyChatTemplate(messages: messages,
                                                      tools: tools,
                                                      additionalContext: additionalContext)
            } catch Tokenizers.TokenizerError.missingChatTemplate {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
        }
    }
}

// MARK: - Имя из задания

/// В задании модуль назван MLXRuntime, в коде — MLXModelRuntime (ровно как у движка
/// Google: LiteRTRuntime и LiteRTModelRuntime). Оставляем оба имени, чтобы сборка
/// не разъехалась из-за буквы.
public typealias MLXRuntime = MLXModelRuntime
