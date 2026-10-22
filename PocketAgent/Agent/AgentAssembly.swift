//
//  AgentAssembly.swift
//  PocketAgent
//
//  Композиционный корень — ЕДИНСТВЕННОЕ место, где модули знают друг о друге.
//  Здесь и только здесь встречаются:
//    Runtime (движки: LiteRTModelRuntime, MLXModelRuntime, LlamaModelRuntime)
//    + Tools (ProjectRoot, SecurityScopedWorkspace)
//    + Agent (DefaultToolRegistry, AgentSession) + UI (AppViewModel).
//
//  ⚠️ ДВИЖКОВ ТЕПЕРЬ ЧЕТЫРЕ, И ВЫБОР МЕЖДУ НИМИ ЖИВЁТ ЗДЕСЬ (EngineRouter в конце
//  файла). Больше нигде в приложении имена движков не встречаются: экраны и цикл
//  агента по-прежнему знают только протокол ModelRuntime.
//
//  Всё остальное общается через протоколы из Contracts.swift.
//
//  Цепочка, которую собирает этот файл:
//    UI (AppViewModel) → AgentSession → DefaultToolRegistry → четыре инструмента
//    → SecurityScopedWorkspace → SafePath → диск.
//  Запись файла живёт в конце цепочки и включается ТОЛЬКО через approve().
//
//  ⚠️ Отсюда же — и единственная дверь наружу: пятый инструмент (поиск в интернете)
//  попадает в реестр ТОЛЬКО когда человек включил поиск сам. Выключен — модель
//  о существовании интернета не знает, и позвать его нечем.
//

import Foundation

@MainActor
final class AgentAssembly: ObservableObject {

    // MARK: - Долгоживущие части

    /// Движок модели. Один на всё приложение: веса грузятся один раз за запуск.
    ///
    /// ⚠️ Тип здесь НАРОЧНО протокольный, а не «движок Google». За ним стоит `EngineRouter`,
    /// который сам решает, чьей моделью работать — Google или Apple, — по виду активной
    /// модели. Напиши тут конкретный движок обратно — и второй снова станет мёртвым кодом.
    let runtime: any ModelRuntime

    /// Владелец выбранной папки. Тоже один — доступ к папке в приложении ровно один.
    let folderStore: ProjectRoot

    /// Показанные человеку диффы. Общий на приложение: карточку строит preview(),
    /// а пишет на диск execute() — без записи в этом хранилище записи не будет вообще.
    private let pendingDiffs: PendingDiffStore

    /// То, что видят экраны.
    let viewModel: AppViewModel

    // MARK: - Сборка

    init() {
        // Не «движок Google», а тот, кто выбирает движок по активной модели.
        // Для файла .litertlm он ведёт себя ровно как раньше — тем же путём,
        // с той же лесенкой настроек и тем же журналом.
        let runtime = EngineRouter()
        let folderStore = ProjectRoot.shared
        let pendingDiffs = PendingDiffStore()

        self.runtime = runtime
        self.folderStore = folderStore
        self.pendingDiffs = pendingDiffs

        // Фабрику собираем из готовых значений, а не из self, — иначе замыкание
        // и сборка держали бы друг друга, и ни одна из них не освободилась бы.
        self.viewModel = AppViewModel(
            runtime: runtime,
            folderStore: folderStore,
            // Экраны получают ГОТОВЫЕ строки про модель и не знают ни про каталог,
            // ни про хранилище: это единственное место, где они встречаются.
            modelInfo: AgentAssembly.modelInfo(for: ModelSpec.descriptor),
            freeBytesProvider: { ModelStorage.availableBytes() },
            // Сколько занимает установленная модель и как её убрать — тоже замыканиями:
            // интерфейс про хранилище не знает и знать не должен.
            installedBytesProvider: { ModelInstallation.occupiedBytes(for: ModelSpec.descriptor) },
            deleteModelAction: { try ModelInstallation.remove(model: ModelSpec.descriptor) },
            // Установка из уже скачанного файла. Работа долгая и синхронная — интерфейс
            // зовёт это замыкание из отдельной задачи, а не с главного потока.
            //
            // ⚠️ Модель НЕ навязываем (model: nil): что это за файл, решает сам файл.
            // Подставь сюда активную модель — и человек с годной Gemma другого размера
            // снова упёрся бы в сверку с чужим эталоном, ради ухода от которой всё и делалось.
            importModelAction: { url, onProgress in
                try ModelImporter.install(from: url,
                                          model: nil,
                                          onProgress: onProgress)
            },
            // Пауза загрузки: система сохраняет точку обрыва, поэтому продолжение
            // качает с неё, а не сначала. Отдельного «продолжить» у загрузчика нет —
            // им служит обычная подготовка модели, она подхватывает сохранённую точку.
            pauseDownloadAction: { ModelDownloader.shared.pause() },
            resumeDownloadAction: {},
            // Полная отмена: снимает фоновую задачу и выбрасывает точку докачки —
            // только после неё удаление скачанного не упирается в «идёт загрузка».
            cancelDownloadAction: { ModelDownloader.shared.cancelAndDiscard(ModelSpec.descriptor) },

            // MARK: Список моделей, поиск на телефоне и выбор
            //
            // ⚠️ Пять замыканий ниже — это ВЕСЬ мост между экраном выбора модели и
            // справочником с хранилищем. Не передать их — и экран остаётся с одной
            // запасной строкой: список не появляется, карточка «Нашли модель» всегда
            // пустая, кнопка «Использовать эту модель» ничего не делает. Ровно так
            // и было: код поиска в Runtime работал, а в интерфейсе был мёртв.

            // Что приложение знает и что из этого умеет скачать само.
            catalogProvider: {
                let memoryMB = MemoryGate.availableMemoryMB()
                // Сначала то, что приложение умеет скачать: именно первая строка
                // выбирается по умолчанию, и кнопка «Скачать» обязана быть рабочей.
                // Остальные модели человек приносит файлом сам — они идут следом.
                let phone = ModelCatalog.forPhone
                let ordered = phone.filter { ModelCatalog.canDownload($0) }
                    + phone.filter { !ModelCatalog.canDownload($0) }
                // ⚠️ Одна и та же модель бывает в справочнике дважды — под разными именами
                // файла (её так выложили). Справочнику это нужно, чтобы узнавать файл как
                // ни назови; человеку в списке две одинаковые строки «Gemma 3 1B» —
                // повод решить, что приложение сломалось. Оставляем первую.
                var shown = Set<String>()
                return ordered
                    .filter { shown.insert($0.displayName).inserted }
                    .map { AgentAssembly.catalogOption(for: $0, availableMemoryMB: memoryMB) }
            },
            // Что УЖЕ лежит на телефоне: в папке человека в «Файлах», внутри приложения
            // или вшито в саму сборку. Обход папок — работа с диском, зовётся вне
            // главного потока.
            //
            // ⚠️ Возвращаем ОТЧЁТ, а не просто список. Экран обязан уметь ответить человеку
            // на вопрос «оно вообще ищет?»: где смотрели, сколько нашли, что отвергли
            // и почему. Раньше пустая папка и сломанный поиск выглядели на экране
            // совершенно одинаково — то есть никак.
            scanForModelsAction: {
                let memoryMB = MemoryGate.availableMemoryMB()
                let scan = ModelDiscovery.rescanDetailed()

                // Предлагать «использовать» можно только то, что запустится прямо сейчас.
                let usable = scan.files
                    .filter { $0.isUsable }
                    .map { AgentAssembly.foundOption(for: $0, availableMemoryMB: memoryMB) }

                // Файл модели нашли, но взять не можем — человек обязан узнать причину,
                // а не остаться с пустым экраном.
                let blocked = scan.files
                    .filter { !$0.isUsable }
                    .map { AgentAssembly.rejectedOption(for: $0) }

                let strangers = scan.rejected.map { AgentAssembly.rejectedOption(for: $0) }

                return ModelScanSnapshot(found: usable,
                                         rejected: blocked + strangers,
                                         places: scan.places,
                                         finishedAt: scan.finishedAt)
            },
            // Человек ткнул в строку списка. Ничего не копируем и не качаем —
            // только запоминаем, с чем работать дальше.
            selectModelAction: { option in
                // Обхода папок здесь быть не должно: касание строки приходит с главного
                // потока, и человек ждёт мгновенной реакции, а не подвисания.
                if let file = AgentAssembly.discoveredFile(withID: option.id,
                                                           rescanIfNeeded: false) {
                    // ⚠️ Папку с моделью Apple активной НЕ делаем, пока её нечем запускать:
                    // движок Google, получив вместо файла папку, ответит безликой ошибкой,
                    // а работающая модель человека при этом перестанет быть активной.
                    // Почему так и когда снимется — `MLXModelFolder.isEngineWired`.
                    guard !file.isFolder || MLXModelFolder.isEngineWired else { return }
                    ModelSpec.select(file.descriptor, fileURL: file.url)
                    return
                }
                if let model = ModelCatalog.model(withID: option.id) {
                    ModelSpec.select(model, fileURL: nil)
                }
            },
            // «Использовать эту модель» на карточке найденного файла.
            // Копирования здесь нет: файл и так внутри приложения.
            useModelAction: { option in
                guard let file = AgentAssembly.discoveredFile(withID: option.id) else {
                    // Файл исчез, пока человек читал карточку.
                    throw PocketAgentError.modelFileMissing
                }
                // Модель, вшитую в сборку, двигать нечем и незачем — её достаточно
                // объявить активной.
                guard file.location != .bundle else {
                    ModelSpec.select(file.descriptor, fileURL: file.url)
                    ModelDiscovery.refreshAndNotify()
                    return
                }
                try ModelImporter.adopt(fileAt: file.url)
            },
            // Заглянуть в выбранный файл ДО копирования гигабайтов.
            inspectFileAction: { url in
                AgentAssembly.inspection(of: url)
            },
            // Чем помечена активная модель: путём файла внутри приложения (так же
            // называются строки найденного) или опознавателем из справочника.
            activeModelIDProvider: {
                if let path = ModelSpec.choice?.relativePath, !path.isEmpty {
                    return path
                }
                return ModelSpec.choice?.descriptor.id
            },
            makeAgent: { [runtime, folderStore, pendingDiffs] in
                try AgentAssembly.makeSession(runtime: runtime,
                                              folderStore: folderStore,
                                              pendingDiffs: pendingDiffs)
            }
        )
    }

    // MARK: - Что рассказать про модель

    /// Перевод описания модели из каталога Runtime в узкий тип из Contracts,
    /// который знает интерфейс. Переименуют поле каталога — правка будет ЗДЕСЬ,
    /// а не сразу в двух экранах.
    static func modelInfo(for model: ModelDescriptor) -> ModelInfo {
        ModelInfo(displayName: model.displayName,
                  license: model.license,
                  byteSize: model.byteSize,
                  sizeText: model.humanSize,
                  fileName: model.fileName,
                  versionText: String(model.repoCommit.prefix(7)),
                  pageURL: model.pageURL)
    }

    // MARK: - Перевод «описание модели → строка списка»
    //
    // ⚠️ ВСЁ ЭТО ЖИВЁТ ЗДЕСЬ И ТОЛЬКО ЗДЕСЬ. Экран не знает ни про справочник, ни про
    // хранилище, ни про то, где лежат файлы; Runtime не знает про строки списка.
    // Композиционный корень — единственное место, где им позволено встретиться.
    //
    // ⚠️ `nonisolated` обязателен: замыкания выше зовутся из фоновой задачи (обход папок —
    // работа с диском), а сама сборка живёт на главном потоке.

    /// Строка списка для модели из справочника.
    /// ⚠️ Имена разведены (`catalogOption` / `foundOption`) намеренно: одинаковое имя
    /// с разными типами читается тут хуже, чем два прямых названия.
    nonisolated static func catalogOption(for model: ModelDescriptor,
                                          availableMemoryMB: Int) -> ModelOption {
        let canDownload = ModelCatalog.canDownload(model)
        return ModelOption(
            id: model.id,
            displayName: model.displayName,
            fileName: model.fileName,
            byteSize: model.byteSize,
            sizeText: model.humanSize,
            origin: .catalog,
            isRecommended: model.isRecommended,
            isKnown: model.isKnown,
            summary: model.summary,
            caveat: nil,
            // ⚠️ У модели Apple память считается ПО-СВОЕМУ, и это не придирка. Мерки
            // в `ModelMemoryRule` сняты Google с его файлов на живом телефоне; движок
            // Apple мы не мерили ни разу. Приложи мы чужой замер к папке — выдали бы
            // догадку за измерение ровно там, где человек решает, качать ли гигабайты.
            memory: model.isFolderModel
                ? folderMemoryVerdict(folderName: model.fileName,
                                      totalBytes: model.byteSize,
                                      availableMemoryMB: availableMemoryMB)
                : memoryVerdict(for: model, availableMemoryMB: availableMemoryMB),
            canDownload: canDownload,
            requiresGPU: model.hardware == .gpuOnly,
            // Закрытые репозитории Google приложение скачать не может (экрана согласия
            // с лицензией у него нет) — про такие честно говорим, что файл нужен свой.
            locationText: canDownload ? "можно скачать" : "нужен готовый файл",
            pageURL: model.pageURL
        )
    }

    /// Строка списка для файла, который УЖЕ лежит на телефоне.
    /// Опознаватель строки — путь внутри приложения: он переживает и перезапуск,
    /// и переустановку, в отличие от полного пути.
    nonisolated static func foundOption(for file: DiscoveredModelFile,
                                        availableMemoryMB: Int) -> ModelOption {
        let kind: ModelSourceKind
        switch file.location {
        case .bundle:               kind = .bundled
        case .appStorage:           kind = .installed
        case .documents, .inbox:    kind = .foundInAppFolder
        }

        return ModelOption(
            id: file.relativePath,
            displayName: file.displayName,
            fileName: file.fileName,
            byteSize: file.byteSize,
            sizeText: file.sizeText,
            origin: kind,
            isRecommended: false,
            isKnown: file.isKnownToCatalog,
            summary: file.descriptor.summary,
            // Сначала то, что мешает запустить файл, потом первая честная оговорка.
            caveat: file.problem ?? file.warnings.first,
            // ⚠️ У модели Apple память считается ПО-СВОЕМУ. Мерки в `ModelMemoryRule`
            // сняты с файлов Google на живом телефоне и к движку Apple отношения не имеют:
            // приложить их к папке значило бы выдать чужой замер за свой.
            memory: file.isFolder
                ? folderMemoryVerdict(for: file, availableMemoryMB: availableMemoryMB)
                : memoryVerdict(for: file.descriptor, availableMemoryMB: availableMemoryMB),
            // Файл уже на телефоне — качать нечего.
            canDownload: false,
            requiresGPU: file.descriptor.hardware == .gpuOnly,
            // ⚠️ Вложенную папку называем прямо. Владелец перенёс к нам папку целиком,
            // и модель оказалась через две папки от верха: без этой строки человек видит
            // «в вашей папке в Файлах» и не понимает, о каком из своих файлов речь.
            locationText: AgentAssembly.placeText(for: file),
            subfolderText: file.subfolderNote,
            pageURL: file.descriptor.pageURL
        )
    }

    /// Где лежит файл, одной строкой: место плюс вложенные папки, если они есть.
    nonisolated static func placeText(for file: DiscoveredModelFile) -> String {
        guard let note = file.subfolderNote, !note.isEmpty else { return file.location.humanPlace }
        return "\(file.location.humanPlace) → \(note)"
    }

    /// Строка «вижу, но взять не могу» для файла, который РАЗОБРАН как модель,
    /// но запустить его сейчас нельзя: он ещё копируется, остался в облаке, обрезан
    /// или это сборка для браузера. Причину пишет не этот файл, а сам разбор.
    nonisolated static func rejectedOption(for file: DiscoveredModelFile) -> RejectedModelOption {
        let reason: String
        if file.isCloudPlaceholder {
            reason = "Файл пока хранится в iCloud и на телефон не скачан. Я попросил систему "
                + "его скачать: откройте «Файлы» и дождитесь, пока рядом с ним пропадёт "
                + "значок облака."
        } else {
            reason = file.problem ?? "Взять этот файл в работу сейчас не получается."
        }
        return RejectedModelOption(id: file.relativePath,
                                   fileName: file.fileName,
                                   sizeText: file.byteSize > 0 ? file.sizeText : nil,
                                   reason: reason)
    }

    /// То же самое для файла, который моделью не является вовсе.
    nonisolated static func rejectedOption(for file: RejectedModelFile) -> RejectedModelOption {
        RejectedModelOption(id: file.relativePath,
                            fileName: file.fileName,
                            sizeText: file.sizeText,
                            reason: file.reason)
    }

    /// Хватит ли памяти — ПРЕДУПРЕЖДЕНИЕМ, а не запретом.
    ///
    /// ⚠️ Текст сочиняет `ModelMemoryRule`, здесь только решается, насколько всё плохо.
    /// Разбирать готовую фразу словами было бы враньём при первой же её правке, поэтому
    /// тяжесть считаем по тем же порогам, что и сам текст.
    nonisolated static func memoryVerdict(for model: ModelDescriptor,
                                          availableMemoryMB: Int) -> ModelMemoryVerdict {
        // ⚠️ У GGUF СВОЯ ФИЗИКА ПАМЯТИ — ЗНАЧИТ, И МЕРКА СВОЯ. Правило `ModelMemoryRule`
        // снято с замеров движка Google, у которого есть выбор «видеочип или процессор»
        // и от которого зависит порог. У llama-движка такого выбора нет — Metal всегда,
        // — и «памяти хватит только без ускорения, пойдёт на процессоре» здесь ложь,
        // как и порог «треть файла» (для Bonsai это около 1985 МБ вместо реальных
        // 3,4+ ГБ). Считаем по `ModelFitRule`: у него честные тексты для GGUF, те же,
        // что человек видит в списке моделей.
        if ModelFileFormat.detect(fileName: model.fileName) == .gguf {
            return fitRuleVerdict(ModelFitRule.fit(fileName: model.fileName,
                                                   fileBytes: model.byteSize,
                                                   availableMemoryMB: availableMemoryMB))
        }
        // Int.max — «узнать не удалось» (симулятор, macOS). Пугать выдуманным нельзя.
        guard availableMemoryMB > 0, availableMemoryMB != Int.max else { return .unknown }
        guard let warning = ModelMemoryRule.warning(for: model,
                                                    availableMemoryMB: availableMemoryMB) else {
            return .fits
        }
        // Сборке только для видеочипа отступать некуда: не хватило ему — не запустится вовсе.
        let hardFloor = model.hardware == .gpuOnly
            ? model.gpuMemoryRequirementMB
            : model.cpuMemoryRequirementMB
        return availableMemoryMB < hardFloor ? .tooBig(warning) : .tight(warning)
    }

    /// То же самое для модели, которая лежит ПАПКОЙ (формат Apple).
    ///
    /// ⚠️ ЧЕСТНО: ЭТО РАСЧЁТ, А НЕ ЗАМЕР. Движок Apple мы не мерили ни разу — ни на одном
    /// телефоне, ни на одной модели. Число берётся долей от суммарного веса папки
    /// (`ModelFitRule`), и человеку так и написано: «оценка — такие файлы мы ещё
    /// не запускали». Подставлять сюда мерку, снятую с моделей Google, нельзя:
    /// это был бы чужой замер, выданный за наш.
    nonisolated static func folderMemoryVerdict(for file: DiscoveredModelFile,
                                                availableMemoryMB: Int) -> ModelMemoryVerdict {
        folderMemoryVerdict(folderName: file.fileName,
                            totalBytes: file.byteSize,
                            availableMemoryMB: availableMemoryMB)
    }

    /// То же самое, но по имени и весу папки — для модели Apple, которую ещё не скачали
    /// (её на телефоне нет вовсе, а сказать про память надо ДО загрузки гигабайтов).
    nonisolated static func folderMemoryVerdict(folderName: String,
                                                totalBytes: Int64,
                                                availableMemoryMB: Int) -> ModelMemoryVerdict {
        fitRuleVerdict(ModelFitRule.fit(folderName: folderName,
                                        totalBytes: totalBytes,
                                        availableMemoryMB: availableMemoryMB))
    }

    /// Перевод расчёта `ModelFitRule` в пометку для экрана. Общий для GGUF и папок
    /// Apple: у обоих движков своя физика памяти, и обе считает `ModelFitRule`.
    nonisolated static func fitRuleVerdict(_ fit: ModelFit) -> ModelMemoryVerdict {
        let text = [fit.detail, fit.memoryNote].compactMap { $0 }.joined(separator: " ")
        switch fit.level {
        case .ready:      return .fits
        case .tight:      return .tight(text)
        case .impossible: return .tooBig(text)
        case .notYet:     return .unknown
        }
    }

    /// Найти уже опознанный файл по опознавателю строки списка.
    /// Кэш поиска берём готовым; пуст — значит поиска ещё не было, тогда ищем.
    ///
    /// - Parameter rescanIfNeeded: ⚠️ `false` обязателен там, где вызов идёт С ГЛАВНОГО
    ///   ПОТОКА (нажатие на строку списка). Когда моделей на телефоне ноль, кэш пуст
    ///   ВСЕГДА — и с `true` каждое касание строки запускало бы полный обход папок прямо
    ///   в момент отрисовки, то есть подвисание ровно у того человека, у которого и так
    ///   ничего не нашлось.
    nonisolated static func discoveredFile(withID id: String,
                                           rescanIfNeeded: Bool = true) -> DiscoveredModelFile? {
        let cached = ModelDiscovery.cached
        let list = (cached.isEmpty && rescanIfNeeded) ? ModelDiscovery.rescan() : cached
        return list.first { $0.relativePath == id }
    }

    /// Что сказать человеку про выбранный им файл ДО того, как копировать гигабайты.
    ///
    /// ⚠️ Отказ здесь бывает ТОЛЬКО на явном мусоре: не тот формат, обрывок, сборка для
    /// браузера. Незнакомая, но рабочая модель проходит с честным предупреждением —
    /// именно за отказ годному файлу («весит 3,66 ГБ, а нужен ровно 2,01 ГБ») владелец
    /// и написал жалобу.
    nonisolated static func inspection(of url: URL) -> ModelInspection? {
        // ⚠️ ФАЙЛ ИЗ «ФАЙЛОВ» ЛЕЖИТ ВНЕ ПЕСОЧНИЦЫ, И БЕЗ ЭТОГО ЗАПРОСА ЕГО ПРОСТО НЕТ.
        // Система пускает к выбранному файлу только по явному запросу доступа. Установка
        // (`ModelImporter.install`) его делает — а этот шаг «сначала загляни внутрь»,
        // добавленный перед ней, не делал. Итог: заглядывание не находило файл и отвечало
        // «файл не найден, возможно его переименовали», до установки дело не доходило
        // ВООБЩЕ НИКОГДА — отвергался любой файл, включая совершенно годный.
        // Файлу внутри контейнера запрос не нужен и не вредит: там он просто вернёт false.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        do {
            let report = try ModelVerifier.inspect(url)

            if report.isKnownModel {
                return ModelInspection(
                    isUsable: true,
                    isKnown: true,
                    title: report.displayName,
                    detail: report.warnings.first ?? "Файл проверен: \(report.headline)."
                )
            }

            // Папка с моделью Apple: состав правильный, но сказать про неё надо своё —
            // «формат файла правильный» про папку из восьми файлов звучит неправдой.
            if report.isFolder {
                var folderDetail = "Это \(report.headline) — модель для движка Apple, "
                    + "папка из нескольких файлов. Всё нужное внутри есть."
                let notes = report.warnings.prefix(2).joined(separator: "\n\n")
                if !notes.isEmpty { folderDetail += "\n\n" + notes }
                // ⚠️ `isUsable` здесь про «папку можно ПОСТАВИТЬ», а не про «её можно
                // запустить прямо сейчас». Отказывать в установке нельзя: состав папки
                // правильный, и решение — за человеком. Про то, что движок Apple ещё
                // подключается, он читает первой же строкой ниже.
                return ModelInspection(isUsable: true,
                                       isKnown: false,
                                       title: "Модель для движка Apple",
                                       detail: folderDetail)
            }

            // Первая оговорка у незнакомого файла — это всегда «модель нам незнакома»,
            // и она уже сказана заголовком. Повторять её в подробностях незачем.
            var detail = "Это \(report.headline). Такую модель приложение не знает: "
                + "поручиться за неё нельзя, но формат файла правильный, и запустить её можно."
            let extra = report.warnings.dropFirst().prefix(2).joined(separator: "\n\n")
            if !extra.isEmpty {
                detail += "\n\n" + extra
            }

            return ModelInspection(isUsable: true,
                                   isKnown: false,
                                   title: "Модель нам незнакома",
                                   detail: detail)

        } catch let error as MLXFolderError {
            // Папку разобрали и увидели, чего в ней не хватает, — текст уже написан
            // человеческим языком, своими словами его пересказывать незачем.
            return ModelInspection(
                isUsable: false,
                isKnown: false,
                title: "Эта папка не подойдёт",
                detail: error.errorDescription ?? "В папке не хватает файлов модели."
            )

        } catch let error as ModelFileError {
            // У сверщика уже готов текст: что не так и что с этим делать.
            //
            // ⚠️ ЗАГОЛОВОК ВЫБИРАЕТСЯ, А НЕ ПРИБИТ ГВОЗДЁМ. Два случая — «файл ещё
            // не выгружен из облака» и «в папке несколько моделей» — это НЕ отказ:
            // файл совершенно годный, просто его пока нет на телефоне или надо
            // сказать, какой именно брать. Заголовок «Этот файл не подойдёт» в этих
            // случаях прямо врёт и заводит человека в тупик.
            let title: String
            switch error {
            case .stillInCloud:        title = "Модель ещё в облаке"
            case .severalInsideFolder: title = "В папке несколько моделей"
            // Недоделанная установка — это НАШ обрывок, а не негодный файл человека.
            // «Этот файл не подойдёт» тут ругает его за то, что сделали мы сами.
            case .unfinishedImport:    title = "Установка оборвалась"
            default:                   title = "Этот файл не подойдёт"
            }
            return ModelInspection(
                isUsable: false,
                isKnown: false,
                title: title,
                detail: error.errorDescription ?? "Файл не похож на модель."
            )
        } catch {
            // Заглянуть не смогли — диагноз не выдумываем. Интерфейс на nil просто
            // переходит к обычной установке.
            return nil
        }
    }

    // MARK: - Сессия под текущую папку

    /// Собирает сессию агента поверх ТЕКУЩЕЙ папки.
    /// Зовётся заново при каждой смене папки: инструменты держат рабочую папку внутри себя,
    /// поэтому переиспользовать старую сессию после смены проекта нельзя.
    static func makeSession(runtime: any ModelRuntime,
                            folderStore: any ProjectFolderStore,
                            pendingDiffs: PendingDiffStore) throws -> any AgentControlling {

        // Папка сменилась — предпросмотры от прошлого проекта больше не действительны.
        pendingDiffs.clear()

        // ⚠️ РАЗГОВОР БЕЗ ДЕЙСТВИЙ: РЕЕСТР ПУСТ, И ЭТО НЕ ПОЛОМКА, А РЕЖИМ.
        // Человек выключил действия кнопкой «Инструменты» в чате — значит модели не уходит
        // НИ ОДНОГО описания действия (честный замер того самого JSON: 385 токенов,
        // ROADMAP раздел 4). Это не уговор с моделью «не трогай файлы», а отсутствие самой
        // возможности: звать ей нечего, ровно как с поиском в интернете ниже.
        //
        // ⚠️ И рабочую папку тут не открываем: доступ к чужим файлам ради разговора,
        // в котором к ним не притронутся, — это ровно то, чего продукт обещает не делать.
        guard AgentToolsSettings.isEnabled else {
            return AgentSession(runtime: runtime,
                                registry: DefaultToolRegistry(tools: []),
                                folder: folderStore.current)
        }

        let workspace = try folderStore.makeWorkspace()

        // Четыре обязательных действия — всегда.
        var tools = FileTools.makeAll(workspace: workspace, pendingDiffs: pendingDiffs)

        // ⚠️ ЕДИНСТВЕННАЯ ДВЕРЬ В ИНТЕРНЕТ ДЛЯ АГЕНТА, И ОНА ОТКРЫВАЕТСЯ ТОЛЬКО ОТСЮДА.
        // Пока человек не включил поиск, инструмента нет ни в реестре, ни в схеме,
        // которую видит модель, — то есть про интернет она не знает ВООБЩЕ и позвать
        // его не может даже случайно. Это и есть выполнение обещания «ничего не уходит
        // в сеть»: не уговор с моделью, а отсутствие самой возможности.
        //
        // ⚠️ Сессия собирается на весь разговор, поэтому переключатель, тронутый
        // посреди задачи, подействует со следующей задачи (или после смены папки).
        // Второй предохранитель стоит в самом инструменте: выключенный поиск
        // отказывается идти в сеть, даже если остался в реестре с прошлой сборки.
        if WebSearchSettings.isEnabled {
            tools.append(WebSearchTool())
        }

        let registry = DefaultToolRegistry(tools: tools)

        // Реестр обязан быть полным: без finish модель не сможет закончить задачу,
        // без write_file — сделать работу. Собрано неправильно = ошибка сборки, не рантайма.
        assert(registry.isComplete,
               "Реестр инструментов неполный, не хватает: \(registry.missingKinds.map(\.rawValue))")

        // ⚠️ Рабочая папка и хранилище показанных диффов уходят в сессию ради ОДНОГО:
        // кнопки «Вернуть, как было». Возврат обязан идти той же дорогой, что и любая
        // другая запись — тот же дифф, то же хранилище, тот же write_file со сверкой
        // содержимого. Собери мы возврату свой путь к диску — у продукта стало бы две
        // двери в файлы человека вместо одной, и обещание «без нажатия ничего
        // не записывается» пришлось бы стеречь в двух местах.
        return AgentSession(runtime: runtime,
                            registry: registry,
                            folder: folderStore.current,
                            workspace: workspace,
                            pendingDiffs: pendingDiffs)
    }

    /// Собрать сессию для текущей папки (удобный вызов снаружи).
    func makeAgent() throws -> any AgentControlling {
        try AgentAssembly.makeSession(runtime: runtime,
                                      folderStore: folderStore,
                                      pendingDiffs: pendingDiffs)
    }

    // MARK: - Жизненный цикл

    /// Приложение уходит в фон: прерываем генерацию и отпускаем папку.
    /// Не отпустить папку = утечка системного ресурса, после которой приложение
    /// перестаёт открывать любые папки до перезапуска.
    /// ⚠️ Показанные диффы здесь НЕ чистим: человек мог свернуть приложение
    /// прямо над карточкой, и после возврата «Применить» обязана сработать.
    ///
    /// ⚠️ ГЕНЕРАЦИЮ ГАСИТ АГЕНТ, А НЕ ДВИЖОК НАПРЯМУЮ. Прямая отмена в движке шла мимо
    /// машины состояний: номер хода не сдвигался, прерванный ответ возвращался ошибкой
    /// движка, и агент показывал «Не получилось» — хотя человек всего лишь переключился
    /// в мессенджер. Задача при этом терялась. Здесь мы просим об этом интерфейс: он
    /// держит сессию агента и заодно сохраняет переписку.
    func handleEnteredBackground() {
        viewModel.cancelForBackground()
        let runtime = self.runtime
        Task { await runtime.handleEnteredBackground() }
    }

    /// Система пожаловалась на память — выгружаем веса целиком.
    func handleMemoryPressure() {
        let runtime = self.runtime
        Task { await runtime.handleMemoryWarning() }
    }
}

// MARK: - Выбор движка по виду активной модели

/// Кто на самом деле разговаривает с моделью: движок Google или движок Apple.
///
/// ⚠️ ЗАЧЕМ ЭТА ПРОСЛОЙКА ВООБЩЕ НУЖНА. Экран держит движок ОДНИМ значением на всё время
/// своей жизни (`AppViewModel.runtime` — константа) и подписывается на его состояние
/// ровно один раз, при первом появлении. Подменить у него движок на ходу нечем. Поэтому
/// движок, который экран видит, — всегда один и тот же объект, а вот внутри него
/// переключается настоящий исполнитель. Человеку это заметно только тем, что его папка
/// с моделью Apple теперь запускается.
///
/// ⚠️⚠️ ГЛАВНОЕ ПРАВИЛО ЭТОГО ФАЙЛА: ДВА ДВИЖКА НИКОГДА НЕ ДЕРЖАТ ВЕСА ОДНОВРЕМЕННО.
/// Модель весит гигабайты, и телефон, увидев две сразу, закрывает приложение молча —
/// человек видит просто исчезнувшее приложение и не понимает, что случилось. Поэтому
/// переключение устроено так: сначала прежний движок закрывает разговор и выгружает
/// веса, и только ПОСЛЕ этого новый начинает грузить свои (`select(_:)` ниже — там
/// `unload()` стоит до `prepare()`, и порядок этих двух строк менять нельзя).
///
/// ⚠️ Для файлов Google путь остался ПРЕЖНИМ, вызов в вызов: та же лесенка подбора
/// настроек, то же отступление по памяти, тот же журнал. Эта прослойка ничего не
/// упрощает и ничего не решает за движок — она только выбирает, кого позвать.
actor EngineRouter: ModelRuntime, ModelBackendDiagnostics, ModelRuntimeFactsProviding {

    /// Чья модель сейчас работает.
    enum Engine: String {
        /// Один файл `.litertlm` — движок Google (LiteRT-LM).
        case google
        /// Папка с весами `.safetensors` — движок Apple (MLX).
        case apple
        /// Один файл `.gguf` — движок llama.cpp (форк PrismML; стоковый бинарь
        /// тернарный формат Bonsai молча портит — см. Runtime/LlamaRuntime.swift).
        case llama
        /// Ни того, ни другого: модель считает не телефон, а поставщик по ключу человека.
        case remote

        /// Как называть движок в журнале. По-русски: журнал читает человек.
        var humanName: String {
            switch self {
            case .google: return "движок Google"
            case .apple:  return "движок Apple"
            case .llama:  return "движок llama.cpp"
            case .remote: return "работа по ключу"
            }
        }
    }

    // MARK: Сами движки
    //
    // ⚠️ Оба создаются сразу, и это ничего не стоит: создание движка — это несколько полей,
    // веса же появляются только в prepare(). Зато не нужен «а вдруг он ещё не создан»
    // в каждом вызове.

    private let google = LiteRTModelRuntime()
    /// Движок Apple. `MLXRuntime` и `MLXModelRuntime` — одно и то же: сам движок объявляет
    /// оба имени, чтобы сборка не разъезжалась из-за буквы (`Runtime/MLXRuntime.swift`).
    private let apple = MLXRuntime()
    /// Движок llama.cpp (GGUF). Создаётся ВСЕГДА, независимо от того, подключён ли
    /// shim-пакет LlamaBonsai: без пакета это просто актор-обёртка, чей prepare()
    /// отдаёт внятное «движок ещё не подключён» — сборка остаётся зелёной, а человек
    /// при выборе GGUF читает честное объяснение вместо падения.
    /// `LlamaRuntime` и `LlamaModelRuntime` — одно и то же (приём как у Apple-движка).
    private let llama = LlamaRuntime()
    /// Работа по ключу человека. Весов в телефоне не держит вовсе — значит и создание
    /// его не стоит ничего, и памяти он не занимает, пока человек его не включил.
    private let remote = RemoteRuntime()

    /// Кто работает прямо сейчас.
    private var active: Engine

    private var current: any ModelRuntime {
        switch active {
        case .google: return google
        case .apple:  return apple
        case .llama:  return llama
        case .remote: return remote
        }
    }

    private var currentDiagnostics: any ModelBackendDiagnostics {
        switch active {
        case .google: return google
        case .apple:  return apple
        case .llama:  return llama
        case .remote: return remote
        }
    }

    private var currentFacts: any ModelRuntimeFactsProviding {
        switch active {
        case .google: return google
        case .apple:  return apple
        case .llama:  return llama
        case .remote: return remote
        }
    }

    init() {
        // ⚠️ Спрашиваем ПРИ СОЗДАНИИ, а не ждём первой подготовки: выбор человека пережил
        // перезапуск приложения, и если это папка Apple — экран обязан с первого кадра
        // показывать состояние того движка, который её и поднимет.
        active = Self.engineForActiveModel()
    }

    // MARK: - Кого звать

    /// Какой движок нужен активной модели.
    ///
    /// ⚠️ Своего опознания вида модели здесь НЕТ намеренно. Вопрос «папка ли это модели
    /// Apple» задаётся ровно в одном месте на всё приложение (`ModelFileFormat.detect`,
    /// а внутри — `MLXModelFolder`). Заведи мы тут третий способ узнавания — он однажды
    /// разошёлся бы с первыми двумя, и получилось бы худшее: список показывает модель
    /// годной, а запускать её идёт не тот движок.
    /// ⚠️ РАБОТА ПО КЛЮЧУ СПРАШИВАЕТСЯ ПЕРВОЙ, И ЭТО НЕ «ОНА ГЛАВНЕЕ». Она включается
    /// ТОЛЬКО руками человека (по умолчанию выключена), а выбранный файл модели при этом
    /// никуда не девается: выключил переключатель — вернулся ровно к своей модели
    /// в телефоне, ничего не переустанавливая. Спроси мы про файл раньше, человек с
    /// установленной моделью не смог бы включить работу по сети вовсе.
    static func engineForActiveModel() -> Engine {
        if RemoteAccessSettings.isEnabled { return .remote }
        if activeModelFolderURL() != nil { return .apple }
        // ⚠️ GGUF — ОДИНОЧНЫЙ ФАЙЛ `.gguf`, движок llama.cpp. Опознание ТОЛЬКО через
        // `ModelFileFormat.detect(fileName:)` — тот же единственный на всё приложение
        // способ, что и для остальных видов; второго способа заводить нельзя.
        // До пакетного шага движок ещё не подключён — тогда он сам вежливо откажет.
        if ModelFileFormat.detect(fileName: ModelSpec.descriptor.fileName) == .gguf {
            return .llama
        }
        // ⚠️ И ВТОРОЙ СЛУЧАЙ — МОДЕЛЬ APPLE, КОТОРУЮ ЕЩЁ НЕ СКАЧАЛИ. Папки на телефоне
        // нет, спрашивать у диска нечего, но по описанию видно, что это набор файлов
        // Apple. Без этой строки нажатие «Скачать» на модели Apple уходило бы движку
        // Google — он полез бы за одним файлом с расширением, которого у неё нет.
        return ModelSpec.descriptor.isFolderModel ? .apple : .google
    }

    /// Папка активной модели Apple. nil — активна не папка, а файл (или не выбрано ничего).
    static func activeModelFolderURL() -> URL? {
        guard let path = ModelSpec.choice?.relativePath, !path.isEmpty else { return nil }
        let url = ModelStorage.url(forContainerRelativePath: path)
        guard ModelFileFormat.detect(folderAt: url) == .mlx else { return nil }
        return url
    }

    /// Переключиться на другой движок, отдав память прежнего.
    ///
    /// ⛔ ПОРЯДОК СТРОК ЗДЕСЬ — ЭТО И ЕСТЬ ЗАЩИТА ОТ МОЛЧАЛИВОГО ЗАКРЫТИЯ ПРИЛОЖЕНИЯ.
    /// Сначала прежний движок отпускает разговор (в нём тоже сотни мегабайт), потом
    /// выгружает веса, и лишь затем меняется `active` — то есть новый движок физически
    /// не может начать грузиться раньше, чем старый освободил память.
    private func select(_ wanted: Engine) async {
        guard wanted != active else { return }

        EngineJournal.shared.record(
            .engine,
            "Меняю движок: \(active.humanName) → \(wanted.humanName)",
            detail: "прежнюю модель выгружаю из памяти ДО загрузки новой — "
                  + "две модели сразу телефон не выдержит"
        )

        let previous = current
        await previous.endSession()
        await previous.unload()

        active = wanted
        // Состояние теперь рассказывает другой движок — переподписываемся, иначе экран
        // навсегда остался бы на состоянии прежнего.
        startForwarding()
    }

    // MARK: - Состояние

    private var listeners: [UUID: AsyncStream<ModelRuntimeStatus>.Continuation] = [:]
    private var forwardTask: Task<Void, Never>?

    func currentStatus() async -> ModelRuntimeStatus {
        await current.currentStatus()
    }

    /// ⚠️ ПОТОК СВОЙ, А НЕ ЧУЖОЙ, И ЭТО ГЛАВНАЯ ТОНКОСТЬ ВСЕГО ФАЙЛА. Экран подписывается
    /// на состояние ОДИН раз за запуск. Отдай мы ему поток движка Google — после перехода
    /// на модель Apple он до конца работы слушал бы молчащий движок: полоса загрузки
    /// не двигалась бы, а «Модель готова» не наступило бы никогда.
    func statusStream() async -> AsyncStream<ModelRuntimeStatus> {
        let (stream, continuation) = AsyncStream<ModelRuntimeStatus>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let id = UUID()
        listeners[id] = continuation
        // Первым делом — то, что происходит прямо сейчас: экран не должен ждать
        // следующей перемены, чтобы узнать, что модель уже готова.
        let statusNow = await current.currentStatus()
        continuation.yield(statusNow)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropListener(id) }
        }
        if forwardTask == nil { startForwarding() }
        return stream
    }

    private func dropListener(_ id: UUID) {
        listeners[id] = nil
    }

    /// Пересказывать состояние того движка, который работает сейчас.
    private func startForwarding() {
        forwardTask?.cancel()
        let engine = current
        forwardTask = Task { [weak self] in
            let stream = await engine.statusStream()
            for await status in stream {
                if Task.isCancelled { return }
                await self?.deliver(status)
            }
        }
    }

    private func deliver(_ status: ModelRuntimeStatus) {
        for listener in listeners.values {
            listener.yield(status)
        }
    }

    // MARK: - Подъём модели

    /// ⚠️ ВЫБОР ДВИЖКА ДЕЛАЕТСЯ ЗДЕСЬ, А НЕ ПРИ ЗАПУСКЕ ПРИЛОЖЕНИЯ. Человек меняет модель
    /// на ходу, и любой такой путь — «Использовать эту модель», установка из «Файлов»,
    /// скачивание — заканчивается этим самым вызовом. Спроси мы про модель один раз
    /// на старте, и после смены модели работал бы прежний движок.
    func prepare() async throws {
        await select(Self.engineForActiveModel())

        if active == .apple {
            let choice = ModelSpec.choice
            if let folder = Self.activeModelFolderURL() {
                // Внутри `use` стоит ВТОРАЯ проверка того же правила: сменилась папка —
                // прежние веса выгружаются до загрузки новых. Здесь она не лишняя, а нужна
                // для случая «модель Apple сменили на другую модель Apple»: движок тот же,
                // переключения не было, а память освободить всё равно обязаны.
                await apple.use(modelDirectory: folder,
                                displayName: choice?.descriptor.displayName,
                                byteSize: choice?.descriptor.byteSize ?? 0)
            } else if ModelSpec.descriptor.isFolderModel {
                // Модель выбрана, но её папки на телефоне ещё нет — движок скачает её сам,
                // ровно как движок Google качает свой файл.
                await apple.use(pendingModel: ModelSpec.descriptor)
            } else {
                // Папка исчезла, пока человек ходил по экранам.
                throw PocketAgentError.modelFileMissing
            }
        }

        if active == .llama {
            // ⚠️ Тот же случай, что «Apple сменили на другую Apple»: выбор сменился
            // с GGUF на другой GGUF, переключения движка не было, а сказать движку
            // про новый файл обязаны ЗДЕСЬ — `use` при смене файла сам выгружает
            // прежние веса до загрузки новых. Без этого `prepare` вышел бы рано
            // по «уже готов» и работал бы со старой моделью.
            if let choice = ModelSpec.choice,
               let file = choice.fileURL,
               ModelFileFormat.detect(fileName: file.lastPathComponent) == .gguf {
                await llama.use(modelFile: file,
                                displayName: choice.descriptor.displayName,
                                byteSize: choice.descriptor.byteSize)
            } else if ModelFileFormat.detect(fileName: ModelSpec.descriptor.fileName) == .gguf {
                // ⚠️ ВЫБОР БЕЗ СВОЕГО ФАЙЛА — МОДЕЛЬ ИЗ КАТАЛОГА, КОТОРУЮ ЕЩЁ НЕ СКАЧАЛИ.
                // По образцу apple-ветки выше: движку говорится, какую модель поднимать,
                // и скачивание начинается внутри его подготовки. Без этой строки выбор
                // каталога до движка не доезжал бы вовсе: он продолжал бы держать
                // приставленный прежний файл — человек жал «Скачать» у одной модели,
                // а приложение молча готовило другую.
                await llama.use(pendingModel: ModelSpec.descriptor)
            }
        }

        try await current.prepare()
    }

    // MARK: - Разговор (всё это просто уходит работающему движку)

    func beginSession(systemPrompt: String, tools: [ToolDeclaration]) async throws {
        try await current.beginSession(systemPrompt: systemPrompt, tools: tools)
    }

    func send(userText: String) async throws -> ModelTurn {
        try await current.send(userText: userText)
    }

    func send(toolResult: ToolResult) async throws -> ModelTurn {
        try await current.send(toolResult: toolResult)
    }

    func cancelTurn() async {
        await current.cancelTurn()
    }

    func endSession() async {
        await current.endSession()
    }

    /// Освободить память.
    ///
    /// ⚠️ Просим ВСЕ движка, хотя веса может держать только один. Этот вызов приходит,
    /// когда модель удалили с телефона, — то есть в момент, когда важно не «кто именно
    /// держит», а «чтобы не держал никто». Молчащему движку лишняя выгрузка ничего
    /// не стоит и в журнал не пишется: все проверяют, есть ли что выгружать.
    func unload() async {
        await google.unload()
        await apple.unload()
        await llama.unload()
        // У работы по ключу весов нет, но есть разговор и ключ в памяти процесса —
        // их тоже надо отпустить.
        await remote.unload()
    }

    func usedTokens() async -> Int? {
        await current.usedTokens()
    }

    func contextLimitTokens() async -> Int {
        await current.contextLimitTokens()
    }

    // MARK: - Жизнь приложения

    /// ⚠️ Зовём ТОЛЬКО работающий движок, в отличие от `unload()`. Молчащий движок весов
    /// не держит, а вот в журнал он написал бы «выгружаю модель» — и человек, читающий
    /// журнал после закрытия приложения, увидел бы две выгрузки там, где была одна.
    func handleEnteredBackground() async {
        await current.handleEnteredBackground()
    }

    func handleMemoryWarning() async {
        await current.handleMemoryWarning()
    }

    // MARK: - Диагностика для «О программе»

    func backendName() async -> String {
        await currentDiagnostics.backendName()
    }

    func isAccelerationDisabled() async -> Bool {
        await currentDiagnostics.isAccelerationDisabled()
    }

    func enableAccelerationAgain() async {
        await currentDiagnostics.enableAccelerationAgain()
    }

    func runtimeFacts() async -> ModelRuntimeFacts {
        await currentFacts.runtimeFacts()
    }
}
