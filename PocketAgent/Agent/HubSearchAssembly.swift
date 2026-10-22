//
//  HubSearchAssembly.swift
//  PocketAgent
//
//  Мост между поиском по справочнику Hugging Face (Runtime) и экраном поиска (UI).
//
//  ⚠️ ЭТО ПРОДОЛЖЕНИЕ КОМПОЗИЦИОННОГО КОРНЯ, и живёт оно здесь по той же причине,
//  что и перевод «описание модели → строка списка» в AgentAssembly.swift: экран
//  поиска не знает ни про справочник, ни про хранилище, ни про описание модели —
//  он получает ГОТОВЫЕ строки. А Runtime ничего не знает про строки списка.
//  Единственное место, где им позволено встретиться, — здесь.
//
//  Отдельным файлом, а не строчками в AgentAssembly.swift: над тем файлом работают
//  и другие правки, а весь поиск целиком — одна законченная тема.
//

import Foundation

// MARK: - Что мы собираемся скачать

/// Найденные модели с их точными размерами и контрольными суммами.
///
/// ⚠️ ЗАЧЕМ ХРАНИТЬ. Экран поиска работает со строками и опознавателями — описания
/// модели у него нет и быть не должно. Когда человек нажимает «Скачать», нам нужно
/// вернуть описание обратно: адрес репозитория, закреплённую версию, точный размер
/// и сумму. Собирать его заново по строке экрана значило бы гадать.
private final class HubDownloadPlans: @unchecked Sendable {

    static let shared = HubDownloadPlans()

    /// Сколько описаний держим. Человек ищет несколько раз подряд, и прошлые находки
    /// стоит помнить: он мог вернуться к предыдущему списку.
    ///
    /// ⚠️ ЧИСЛО СЧИТАЕТСЯ ОТ ФАЙЛОВ, А НЕ ОТ МОДЕЛЕЙ, и прежние двести были МАЛЫ.
    /// На странице двадцать моделей, а файлов внутри модели бывает до восьми — то есть
    /// одна страница это уже до ста шестидесяти описаний. Двух нажатий «Показать ещё»
    /// хватало, чтобы перевалить за предел. Тысяча — это шесть страниц подряд, и стоит
    /// она копейки: описание модели это несколько строк текста и два числа.
    private static let limit = 1000

    private let lock = NSLock()
    private var plans: [String: ModelDescriptor] = [:]
    /// В каком порядке описания появлялись — чтобы выбрасывать САМОЕ СТАРОЕ, а не всё.
    private var order: [String] = []

    private init() {}

    func remember(_ descriptor: ModelDescriptor) {
        lock.lock()
        defer { lock.unlock() }

        // ⚠️ ЗДЕСЬ БЫЛО `plans.removeAll()`, И ЭТО ЛОМАЛО КНОПКУ У ЖИВЫХ СТРОК.
        // Переполнение стирало ВСЁ разом — включая описания тех моделей, что прямо сейчас
        // стоят у человека на экране. Он листал список, нажимал «Скачать» на строке из
        // начала — и получал «эта модель потерялась из виду» на совершенно живой модели.
        // Теперь уходит только самое старое, а то, что человек видит, остаётся на месте.
        if plans[descriptor.id] == nil {
            order.append(descriptor.id)
        }
        plans[descriptor.id] = descriptor
        while order.count > Self.limit {
            plans[order.removeFirst()] = nil
        }
    }

    func descriptor(for id: String) -> ModelDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return plans[id]
    }
}

// MARK: - Мост

extension AgentAssembly {

    // MARK: Поиск

    /// Найти модели по словам человека и сразу разложить их в строки экрана.
    ///
    /// ⚠️ ОТДАЁМ СТРАНИЦУ, А НЕ ВЕСЬ СПИСОК. Раньше отсюда уходило ровно десять строк —
    /// и это было всё, что человек мог увидеть, сколько бы моделей ни лежало в
    /// справочнике на самом деле (а их там 245 только в нашем формате, проверено
    /// живым запросом 10.08.2026). Молчаливый обрыв списка — ровно то, на что
    /// пожаловался владелец. Теперь вместе со страницей возвращается способ дотянуть
    /// следующую, и он либо есть, либо его нет — второе и означает «это весь список».
    ///
    /// ⚠️ `nonisolated`: разбор ответа и подсчёт пометок к главному потоку отношения
    /// не имеют, а держать его занятым, пока считается страница моделей, незачем.
    nonisolated static func searchHub(query: HubQuery,
                                      scope: HubSearchScope,
                                      sort: HubSortOption = .downloads,
                                      limit: Int = HuggingFaceSearch.resultLimit) async throws -> HubSearchPage {
        try await hubPage(query: query, scope: scope, sort: sort, limit: limit, from: nil)
    }

    /// Одна страница + замыкание за следующей.
    ///
    /// ⚠️ Продолжение приходит ЗАМЫКАНИЕМ внутри самой страницы, а не отдельной меткой,
    /// которую экран должен где-то хранить и потом правильно вернуть. Экран поиска
    /// про адреса и метки справочника не знает вовсе — он просто спрашивает «а дальше
    /// есть?» и, если есть, зовёт. Метка, гуляющая через весь слой показа, — это
    /// приглашение однажды подставить её не к тому списку.
    private nonisolated static func hubPage(query: HubQuery,
                                            scope: HubSearchScope,
                                            sort: HubSortOption,
                                            limit: Int,
                                            from cursor: HubCursor?) async throws -> HubSearchPage {
        let page = try await HuggingFaceSearch.searchPage(query: query.text,
                                                          format: filter(for: scope),
                                                          sort: order(for: sort),
                                                          limit: limit,
                                                          section: section(for: query.section),
                                                          after: cursor)
        // Память и место на диске спрашиваем ОДИН раз на всю страницу: обе цифры
        // за секунду не меняются, а лезть за ними на каждую строку — десятки
        // обращений к системе на один поиск.
        let memoryMB = MemoryGate.availableMemoryMB()
        let freeBytes = ModelStorage.availableBytes()
        let rows = page.repos.map {
            repoOption(for: $0, availableMemoryMB: memoryMB, freeDiskBytes: freeBytes)
        }

        var more: (@Sendable () async throws -> HubSearchPage)?
        if let next = page.next {
            more = {
                try await hubPage(query: query, scope: scope, sort: sort, limit: limit, from: next)
            }
        }
        return HubSearchPage(repos: rows,
                             more: more,
                             runChecks: await runChecks(for: page.repos))
    }

    /// Приговор «запустится ли» сразу для ВСЕЙ страницы находок.
    ///
    /// ⚠️⚠️ РАДИ ЧЕГО (ROADMAP, 12.8). Владелец скачал 800 МБ и узнал, что модель
    /// не запускается, только в конце: «по итогу тупо потратил своё время». Пометка
    /// должна стоять у всех находок СРАЗУ, пока он листает, а не открываться той,
    /// кого он раскроет.
    ///
    /// ⚠️ И ЭТО НЕ СТОИТ НИ ОДНОГО ЗАПРОСА. Устройство модели приезжает вместе
    /// со списком (`HuggingFaceSearch.wantsConfig`), а спрашиваем мы про него
    /// саму библиотеку Apple — она живёт в приложении, в сеть не ходит и помнит
    /// прошлые ответы.
    ///
    /// ⚠️ Молчит справочник (`modelType == nil`) — приговора нет вовсе, и строка
    /// выглядит как раньше. Такую модель проверит запасной путь на самом экране.
    /// Отказать человеку из-за собственной неудачи мы права не имеем.
    private nonisolated static func runChecks(for repos: [HubRepo]) async -> [String: HubRunCheck] {
        var checks: [String: HubRunCheck] = [:]
        for repo in repos {
            guard let declared = repo.modelType, !declared.isEmpty else { continue }
            switch await MLXArchitectures.liveVerdict(forModelType: declared) {
            case .runnable:
                checks[repo.id] = .willRun
            case .notRunnable(let known):
                checks[repo.id] = .wontRun(
                    HubRunRefusal(short: MLXArchitectures.shortText(forModelType: known),
                                  full: MLXArchitectures.humanText(forModelType: known)))
            case .unknown:
                continue
            }
        }
        return checks
    }

    private nonisolated static func filter(for scope: HubSearchScope) -> HubFormatFilter {
        switch scope {
        case .thisApp: return .litertlm
        case .gguf:    return .gguf
        case .mlx:     return .mlx
        }
    }

    /// Раздел, который выбрал человек, → правило отбора для справочника.
    ///
    /// ⚠️ Перевод живёт ЗДЕСЬ по той же причине, что и остальные: экран знает только
    /// свои пять кнопок и ничего не знает ни про имена выкладывающих, ни про слова,
    /// по которым такие сборки узнают.
    private nonisolated static func section(for option: HubSectionOption) -> HubSection {
        switch option {
        case .all:          return .all
        case .frontier:     return .frontier
        case .experimental: return .experimental
        case .uncensored:   return .uncensored
        case .distills:     return .distills
        }
    }

    /// Порядок, который выбрал человек, → слово, которое понимает справочник.
    ///
    /// ⚠️ Перевод живёт ЗДЕСЬ, а не на экране, ровно по той же причине, что и перевод
    /// вида файлов выше: экран знает только свои переключатели и ничего не знает про то,
    /// какими словами их называет чужой сервер.
    private nonisolated static func order(for sort: HubSortOption) -> HubSortOrder {
        switch sort {
        case .trending:  return .trending
        case .likes:     return .likes
        case .downloads: return .downloads
        case .fresh:     return .fresh
        }
    }

    // MARK: Перевод «находка → строка экрана»

    private nonisolated static func repoOption(for repo: HubRepo,
                                               availableMemoryMB: Int,
                                               freeDiskBytes: Int64) -> HubRepoOption {
        let files = repo.files.map {
            fileOption(for: $0,
                       repo: repo,
                       availableMemoryMB: availableMemoryMB,
                       freeDiskBytes: freeDiskBytes)
        }

        // Пометка всей модели — это лучшее, что среди её файлов есть. Так человек
        // с одного взгляда видит, есть ли тут вообще что брать.
        // ⚠️ При равных пометках оставляем ПЕРВЫЙ файл: список отсортирован от лёгких
        // к тяжёлым, и «лучшим» должен считаться тот, что легче.
        let best = files.reduce(HubFileOption?.none) { current, file in
            guard let current else { return file }
            return rank(file.badge) > rank(current.badge) ? file : current
        }

        return HubRepoOption(
            id: repo.id,
            name: repo.name,
            authorText: authorText(for: repo),
            statsText: statsText(for: repo),
            badge: best?.badge ?? .notYet,
            badgeTitle: best?.badgeTitle ?? "Пока не запустим",
            noteText: repo.isGated
                ? "Закрытый репозиторий: файлы отдают только тем, кто принял условия "
                    + "на сайте. Приложение так скачать не может — файл придётся принести самому."
                : nil,
            files: files,
            pageURL: repo.pageURL,
            // Модель картинок узнаём по имени репозитория и файлов и по слову
            // справочника (ROADMAP §23). Строка экрана тогда ведёт в «Картинки».
            imageKind: ImageModelRegistry.recognize(repoID: repo.id,
                                                    fileNames: repo.files.map(\.fileName),
                                                    pipelineTag: repo.pipelineTag)
        )
    }

    private nonisolated static func fileOption(for file: HubFile,
                                               repo: HubRepo,
                                               availableMemoryMB: Int,
                                               freeDiskBytes: Int64) -> HubFileOption {

        // ⚠️ У модели-папки вид определяется не расширением (его нет вовсе), а составом,
        // и память считается по правилу движка Apple. Спроси мы про неё как про файл —
        // получили бы «пока не запустим» на модели, которую приложение как раз запускает.
        let fit = file.isFolder
            ? ModelFitRule.fit(folderName: file.fileName,
                               totalBytes: file.byteSize,
                               availableMemoryMB: availableMemoryMB)
            : ModelFitRule.fit(fileName: file.fileName,
                               fileBytes: file.byteSize,
                               availableMemoryMB: availableMemoryMB)
        let descriptor = hubDescriptor(repo: repo, file: file)
        HubDownloadPlans.shared.remember(descriptor)

        // ⚠️ ЗДЕСЬ БЫЛО ПЯТЬ ЗАПРЕТОВ, А ОСТАЛОСЬ ДВА — И ЭТО ГЛАВНАЯ ПРАВКА.
        // Приложение гасило кнопку всякий раз, когда САМО считало загрузку неразумной:
        // нет контрольной суммы, файл не того вида, вряд ли хватит памяти. Владелец
        // прочитал одну такую отговорку и ответил прямо: «И что? А если я хочу скачать?»
        // Он прав, и так же записано в замысле проекта: предупреждение, а не запрет.
        //
        // Отказ остаётся ровно там, где нажатие всё равно ничего не даст:
        //   • закрытый репозиторий — файл не отдадут, пока человек не примет условия
        //     на сайте, и сделать это можно только там, а не отсюда;
        //   • не хватает места на телефоне — записывать некуда.
        // Всё прочее — строка предупреждения рядом с ЖИВОЙ кнопкой. Решает человек.
        var blockReason: String?
        if repo.isGated {
            blockReason = "Скачать отсюда нельзя: сначала надо принять условия на сайте."
        } else if freeDiskBytes > 0, freeDiskBytes < Int64(Double(file.byteSize) * 1.2) {
            blockReason = "На телефоне не хватит места: файл весит \(HumanFormat.bytes(file.byteSize)), "
                + "а свободно \(HumanFormat.bytes(freeDiskBytes))."
        }

        return HubFileOption(
            id: descriptor.id,
            fileName: file.fileName,
            // Точный вес и вид файла нужны отбору на странице находок: по весу она
            // раскладывает «лёгкие сверху», по виду — отбирает формат. Разобрать
            // и то, и другое на самом экране нельзя: у папки Apple нет расширения,
            // а размер там показан уже словами («3,8 ГБ»).
            byteSize: file.byteSize,
            sizeText: HumanFormat.bytes(file.byteSize),
            format: file.isFolder ? .mlx : ModelFileFormat.detect(fileName: file.fileName),
            badge: badge(for: fit.level),
            badgeTitle: fit.title,
            fitDetail: fit.detail,
            memoryNote: fit.memoryNote,
            partsNote: partsNote(for: file),
            canDownload: blockReason == nil,
            blockReason: blockReason,
            warningText: blockReason == nil ? warningText(for: file, fit: fit) : nil
        )
    }

    /// Одна строка «на что идёте» рядом с живой кнопкой «Скачать».
    ///
    /// ⚠️ БЕЗ НОТАЦИЙ И БЕЗ УГОВОРОВ. Человек уже решил, что хочет попробовать; наше
    /// дело — назвать риск и замолчать. Поэтому здесь короткие утверждения, а не
    /// «мы не рекомендуем» и не «вы уверены?».
    ///
    /// ⚠️ Больше двух поводов подряд не пишем: третья строка мелким шрифтом под кнопкой
    /// на телефоне уже не читается, а самое важное — первое.
    private nonisolated static func warningText(for file: HubFile, fit: ModelFit) -> String? {
        var reasons: [String] = []

        // Вид папки определяется её составом, а не расширением: у папки его нет.
        let format = file.isFolder ? ModelFileFormat.mlx : ModelFileFormat.detect(fileName: file.fileName)
        // ⚠️ Сюда GGUF больше не попадает: он запускается отдельным движком, и бейдж
        // «пока не запустим» у таких файлов снят. Остался совсем незнакомый вид файла.
        if !format.canRunToday {
            reasons.append("Открыть такой файл приложение пока не умеет — скачать можно, "
                           + "запустить нельзя.")
        } else if fit.level == .impossible {
            reasons.append("На iPhone этот файл не работает — он собран под другое железо.")
        }

        // ⚠️ У папки общей суммы не бывает — она даётся файлу, а их тут десяток.
        // Ругаться на её отсутствие значило бы пугать человека тем, чего не бывает
        // ни у одной модели Apple. Сверять при этом есть чем: у каждого крупного файла
        // сумма своя, и приходит она вместе с составом.
        if file.sha256.isEmpty, !file.isFolder {
            reasons.append("У файла нет контрольной суммы: сверить его после загрузки "
                           + "будет не с чем, ручаться за содержимое некому.")
        }

        guard !reasons.isEmpty else { return nil }
        return reasons.prefix(2).joined(separator: " ")
    }

    /// «набор из 3 файлов» — когда веса разложены по частям (так устроен MLX).
    /// nil — обычный один файл, объяснять нечего.
    private nonisolated static func partsNote(for file: HubFile) -> String? {
        guard file.partCount > 1 else { return nil }
        let word = HumanFormat.plural(file.partCount, "файла", "файлов", "файлов")
        return "набор из \(file.partCount) \(word)"
    }

    private nonisolated static func badge(for level: ModelFit.Level) -> HubFitBadge {
        switch level {
        case .ready:      return .ready
        case .tight:      return .tight
        case .notYet:     return .notYet
        case .impossible: return .impossible
        }
    }

    /// Чем больше — тем лучше пометка. Нужен, чтобы выбрать лучший файл в наборе.
    private nonisolated static func rank(_ badge: HubFitBadge) -> Int {
        switch badge {
        case .ready:      return 3
        case .tight:      return 2
        case .notYet:     return 1
        case .impossible: return 0
        }
    }

    // MARK: Описание модели из находки

    /// Собрать описание модели по тому, что отдал справочник.
    ///
    /// ⚠️ `origin: .catalog` тут не хвастовство. Это значит ровно одно: у нас есть
    /// контрольная сумма ОТ ТОГО, КТО ВЫЛОЖИЛ ФАЙЛ, и после загрузки мы сверим файл
    /// с ней побайтово. Без этой пометки загрузчик отказывается качать вовсе — и он прав:
    /// качать гигабайты, которые нечем проверить, приложение не должно.
    /// При этом «проверено нами» мы нигде не пишем: модель незнакомая, и в списке
    /// на экране подготовки она так и помечена.
    nonisolated static func hubDescriptor(repo: HubRepo, file: HubFile) -> ModelDescriptor {
        // Модель Apple лежит папкой, и скачать её — значит скачать каждый файл из состава.
        // Состав уже пришёл вместе с находкой, второй раз к справочнику не идём.
        if file.isFolder {
            return folderDescriptor(repo: repo, file: file)
        }
        let hardware = ModelCatalog.hardware(forFileName: file.fileName)
        return ModelDescriptor(
            id: hubID(repoID: repo.id, fileName: file.fileName),
            displayName: ModelCatalog.humanName(forFileName: file.fileName),
            repoID: repo.id,
            repoCommit: repo.commit,
            fileName: file.fileName,
            byteSize: file.byteSize,
            sha256: file.sha256,
            summary: "Нашли во встроенном поиске. Приложение её не проверяло: "
                + "условия использования — у того, кто выложил файл.",
            hardware: hardware,
            origin: .catalog,
            isForPhone: hardware.isUsableOnIPhone,
            license: "смотрите на странице модели",
            isRecommended: false
        )
    }

    /// Описание модели Apple, найденной поиском: на телефоне она станет ПАПКОЙ.
    ///
    /// ⚠️ Имя папки — имя репозитория, и это не украшение. По нему приложение потом
    /// узнаёт свою же скачанную модель среди прочих папок в «Файлах», и по нему же
    /// человек понимает, что за модель он скачал.
    ///
    /// ⚠️ Общей контрольной суммы у папки нет и быть не может: сумма даётся файлу,
    /// а тут их десять. Поэтому `sha256` пуст, а сверять есть чем — у каждого крупного
    /// файла сумма своя, и она уехала в состав.
    private nonisolated static func folderDescriptor(repo: HubRepo, file: HubFile) -> ModelDescriptor {
        let parts = file.parts.map {
            ModelFolderFile(name: $0.path, byteSize: $0.byteSize, sha256: $0.sha256)
        }
        let count = file.partCount
        let word = HumanFormat.plural(count, "файла", "файлов", "файлов")
        return ModelDescriptor(
            id: hubID(repoID: repo.id, fileName: file.fileName),
            displayName: ModelCatalog.humanName(forFileName: file.fileName),
            repoID: repo.id,
            repoCommit: repo.commit,
            fileName: repo.name,
            byteSize: file.byteSize,
            sha256: "",
            summary: "Модель для движка Apple: на телефон приезжает папкой из \(count) \(word). "
                + "Нашли во встроенном поиске, приложение её не проверяло: "
                + "условия использования — у того, кто выложил модель.",
            hardware: .universal,
            origin: .catalog,
            license: "смотрите на странице модели",
            isRecommended: false,
            folderFiles: parts
        )
    }

    /// Опознаватель найденной модели.
    ///
    /// ⚠️ Только безопасные для имени файла знаки: по этому опознавателю хранилище
    /// называет служебный файл с точкой докачки. Косая черта из адреса репозитория
    /// увела бы его в несуществующую папку, и докачка после обрыва пропала бы.
    /// ⚠️ И длину держим в узде: имя файла в системе не бывает длиннее 255 знаков.
    /// Обрезаем ХВОСТОМ, а не началом: в конце стоит имя файла, а именно оно и отличает
    /// две сборки одной модели друг от друга («…-Q1_0.gguf» и «…-Q4_1.gguf»).
    nonisolated static func hubID(repoID: String, fileName: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let lower = (repoID + "-" + fileName).lowercased()
        let cleaned = String(lower.map { allowed.contains($0) ? $0 : "-" })
        let short = cleaned.count > 120 ? String(cleaned.suffix(120)) : cleaned
        return "hub-" + short
    }

    // MARK: Начать загрузку найденной модели

    /// Человек нажал «Скачать» на найденной модели.
    ///
    /// Дальше всё идёт ОБЫЧНЫМ путём: выбранная модель запоминается, а качает её тот же
    /// загрузчик, что и модели из нашего списка, — с проверкой размера, суммы, места
    /// на диске, паузой и продолжением после обрыва. Своего пути загрузки здесь нет
    /// и быть не должно: второй загрузчик — это второй набор ошибок.
    ///
    /// ⚠️⚠️ ВОЗВРАЩАЕТ ОТВЕТ, И ЭТО ОБЯЗАТЕЛЬНО. Раньше отсюда ничего не возвращалось,
    /// а единственный отказ уходил в общее окно ошибки — которое человек, уже уехавший
    /// на другую вкладку закрывшимся поиском, мог и не увидеть. Нажатие без ответа —
    /// это то самое молчание, на которое пожаловался владелец.
    @MainActor
    static func startHubDownload(_ option: HubFileOption, app: AppViewModel) -> HubDownloadStart {
        guard let descriptor = HubDownloadPlans.shared.descriptor(for: option.id) else {
            return .refused("Приложение потеряло из виду, откуда брать этот файл. "
                            + "Закройте поиск, откройте заново и попробуйте ещё раз.")
        }

        // ⚠️ Спрашиваем загрузчик ЗАРАНЕЕ, а не после перехода на другую вкладку: у него
        // есть один вид отказа, который человеку надо назвать сразу — «взять этот файл
        // неоткуда» (нет адреса или неизвестен размер). Узнавать об этом на экране,
        // где ничего не происходит, — та же загадка, только другими словами.
        if let reason = ModelDownloader.refusalReason(for: descriptor) {
            return .refused(reason)
        }

        // Место на телефоне спрашиваем ещё раз, живьём: список мог быть собран полчаса
        // назад, и с тех пор человек успел снять кино.
        //
        // ⚠️ Нулевой ответ — это «померить не вышло», а НЕ «места нет». Отказывать по нему
        // нельзя: человек прочитал бы «свободно 0 Б» на телефоне с половиной пустого диска
        // и справедливо счёл бы это поломкой. Не смогли померить — пропускаем, а нехватку
        // поймает сам загрузчик и назовёт своими словами.
        let freeBytes = ModelStorage.availableBytes()
        if freeBytes > 0, freeBytes < Int64(Double(descriptor.byteSize) * 1.2) {
            return .refused("На телефоне не хватит места: файл весит "
                            + "\(HumanFormat.bytes(descriptor.byteSize)), а свободно "
                            + "\(HumanFormat.bytes(freeBytes)). "
                            + "Освободите место и попробуйте снова.")
        }

        // ⚠️ Занятость спрашиваем ДО того, как что-либо записать. Скажи мы про неё позже —
        // выбор активной модели уже был бы подменён, и человек, получив отказ, остался бы
        // с приложением, которое считает рабочей ту модель, что он так и не скачал.
        //
        // И говорим ЗДЕСЬ, на экране поиска, где палец: общее окно ошибки не годится —
        // поиск в этот момент закрывается, и окно, всплывающее посреди его исчезновения,
        // система вправе просто не показать. Отказ снова оказался бы молчаливым.
        guard !app.isModelWorkInProgress else {
            return .refused("Сейчас уже качается другая модель. Остановите её на вкладке "
                            + "«Модели» — и возвращайтесь за этой.")
        }

        // Сначала говорим движку, ЧТО качать, и только потом просим начать:
        // подготовка модели смотрит именно на этот выбор.
        ModelSpec.select(descriptor, fileURL: nil)
        app.downloadModelFromHub(hubOption(for: descriptor))
        return .started
    }

    /// Строка для экрана подготовки: пока идёт загрузка, там должны быть имя и размер
    /// ИМЕННО ЭТОЙ модели, а не советуемой из нашего списка.
    private nonisolated static func hubOption(for model: ModelDescriptor) -> ModelOption {
        ModelOption(id: model.id,
                    displayName: model.displayName,
                    fileName: model.fileName,
                    byteSize: model.byteSize,
                    sizeText: model.humanSize,
                    origin: .catalog,
                    isRecommended: false,
                    // Модель нам незнакома, и врать про это не нужно: сумму мы сверим,
                    // но живьём её никто не запускал.
                    isKnown: false,
                    summary: model.summary,
                    caveat: nil,
                    // У модели Apple память считается своим правилом — чужой замер
                    // с файлов Google к ней не приложишь (см. `folderMemoryVerdict`).
                    memory: model.isFolderModel
                        ? folderMemoryVerdict(folderName: model.fileName,
                                              totalBytes: model.byteSize,
                                              availableMemoryMB: MemoryGate.availableMemoryMB())
                        : memoryVerdict(for: model, availableMemoryMB: MemoryGate.availableMemoryMB()),
                    canDownload: true,
                    requiresGPU: model.hardware == .gpuOnly,
                    locationText: "нашли в интернете",
                    pageURL: model.pageURL)
    }

    // MARK: Числа человеческим языком

    /// «Выложил litert-community · обновлена вчера».
    ///
    /// ⚠️ СВЕЖЕСТЬ СТОИТ ИМЕННО ЗДЕСЬ, А НЕ ОТДЕЛЬНОЙ СТРОКОЙ, и это не мелочь.
    /// В строке находки уже четыре строки текста; пятая ради одной даты превратила бы
    /// список на телефоне в простыню. А знать её надо: в порядке «Новые» наверх выходят
    /// вчерашние выкладки, среди которых полно чужих проб пера, и отличить их от живой
    /// модели человек может только по дате рядом с именем выложившего.
    private nonisolated static func authorText(for repo: HubRepo) -> String {
        var parts: [String] = []
        if !repo.author.isEmpty {
            parts.append("Выложил \(repo.author)")
        }
        if let freshness = freshnessText(for: repo.lastModified) {
            parts.append(freshness)
        }
        return parts.joined(separator: " · ")
    }

    /// «обновлена сегодня», «обновлена 3 дня назад», «обновлена 2 года назад».
    /// nil — даты нет, и выдумывать её нельзя.
    ///
    /// ⚠️ Считаем в сутках и переводим в месяцы и годы сами, а не системным
    /// «относительным» форматировщиком: тот берёт язык из настроек телефона, и на
    /// нерусском устройстве посреди русской строки появилось бы «3 days ago».
    private nonisolated static func freshnessText(for date: Date?) -> String? {
        guard let date else { return nil }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days <= 0 { return "обновлена сегодня" }
        if days == 1 { return "обновлена вчера" }
        if days < 30 {
            return "обновлена \(days) \(HumanFormat.plural(days, "день", "дня", "дней")) назад"
        }
        if days < 365 {
            let months = max(1, days / 30)
            return "обновлена \(months) \(HumanFormat.plural(months, "месяц", "месяца", "месяцев")) назад"
        }
        let years = max(1, days / 365)
        return "обновлена \(years) \(HumanFormat.plural(years, "год", "года", "лет")) назад"
    }

    /// «2,7 млн скачиваний · 388 лайков · 3 файла · от 328 МБ».
    ///
    /// ⚠️ ВЕС ЗДЕСЬ ОБЯЗАТЕЛЕН, и вот почему он появился. Строка модели в списке свёрнута:
    /// размеры файлов лежат внутри, и увидеть их можно было только раскрыв строку. То есть
    /// человек, листающий десяток находок на телефоне, не мог ответить на первый же свой
    /// вопрос — «сколько это весит» — не открыв каждую по очереди. Теперь самое лёгкое,
    /// что в модели есть, видно сразу.
    ///
    /// Именно «от», а не точный размер: в одной модели файлов бывает восемь, сжатых
    /// по-разному, и один размер за всю модель был бы неправдой. Берём первый файл —
    /// список приходит отсортированным от лёгких к тяжёлым.
    private nonisolated static func statsText(for repo: HubRepo) -> String {
        var parts: [String] = []
        if repo.downloads > 0 {
            parts.append(downloadsText(repo.downloads))
        }
        // Лайки — вторая мера того же самого, но с другой стороны: скачивают часто
        // «за компанию», а отмечают то, что реально понравилось. Порядок «Нравятся»
        // без этой цифры на экране был бы необъяснимым.
        if repo.likes > 0 {
            parts.append("\(repo.likes) \(HumanFormat.plural(repo.likes, "лайк", "лайка", "лайков"))")
        }
        let count = repo.files.count
        let word = HumanFormat.plural(count, "файл", "файла", "файлов")
        parts.append("\(count) \(word)")
        if let lightest = repo.files.first, lightest.byteSize > 0 {
            // Один файл — «от» ни к чему: это и есть его вес.
            parts.append(count > 1
                         ? "от \(HumanFormat.bytes(lightest.byteSize))"
                         : HumanFormat.bytes(lightest.byteSize))
        }
        return parts.joined(separator: " · ")
    }

    /// Сколько раз модель скачали. Точное число в миллионах человеку не нужно —
    /// ему нужно понять, живая модель или её выложили и забыли.
    nonisolated static func downloadsText(_ count: Int) -> String {
        if count >= 1_000_000 {
            return "\(shortNumber(Double(count) / 1_000_000)) млн скачиваний"
        }
        if count >= 10_000 {
            return "\(count / 1000) тыс. скачиваний"
        }
        let word = HumanFormat.plural(count, "скачивание", "скачивания", "скачиваний")
        return "\(count) \(word)"
    }

    /// Одна цифра после запятой, и та только когда она что-то значит: «2,7» и «14».
    /// ⚠️ Запятую ставим сами: `String(format:)` без локали печатает точку на любом
    /// устройстве — ровно на это мы и рассчитываем.
    private nonisolated static func shortNumber(_ value: Double) -> String {
        var text = String(format: value < 10 ? "%.1f" : "%.0f", value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text.replacingOccurrences(of: ".", with: ",")
    }
}
