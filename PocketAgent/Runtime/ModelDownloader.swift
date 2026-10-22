//
//  ModelDownloader.swift
//  PocketAgent / Runtime
//
//  Загрузка файла модели (от 600 МБ до 4 ГБ) с Hugging Face.
//
//  Особенности, из-за которых код выглядит именно так:
//  • Фоновая URLSession работает ТОЛЬКО через делегата — варианты
//    downloadTask(completionHandler:) на background-конфигурации запрещены.
//  • Файл из didFinishDownloadingTo живёт до выхода из метода — переносим синхронно.
//  • После обрыва сохраняем resumeData на диск, чтобы не качать гигабайты заново
//    даже после перезапуска приложения.
//  • Мобильная сеть РАЗРЕШЕНА. Раньше здесь стояло «только Wi-Fi» — это было
//    лишнее ограничение: у владельца безлимитный мобильный интернет, и смысл
//    приложения ровно в том, чтобы снимать ограничения, а не выдумывать свои.
//    Кому надо иначе — выключит загрузку по мобильной сети в настройках системы.
//  • Токен Hugging Face НЕ нужен: репозиторий Gemma 4 открыт (Apache 2.0).
//
//  ⚠️ ДВА СПОСОБА КАЧАТЬ, И ОБА ЖИВУТ ЗДЕСЬ.
//
//  1. ОБЫЧНЫЙ (одна задача на весь файл) — то, что работало всегда. Он остаётся
//     запасным путём и включается сам, если что-то пошло не так: сервер не умеет
//     отдавать файл по частям, замер не удался, есть сохранённая точка обрыва.
//  2. ПО КУСКАМ В НЕСКОЛЬКО ПОТОКОВ — новый быстрый путь. Файл делится на куски,
//     несколько из них качаются одновременно, каждый пишется в собираемый файл
//     по своему смещению. Живой замер 09.08.2026: один поток 1,30 МБ/с, три — 1,85,
//     шесть — 1,97. Сколько потоков и какого размера куски — теперь настройка
//     (`laneCount`, `chunkMegabytes`), а не намертво вбитые числа.
//
//  ⚠️ ЗАСТРЯВШИЙ ХВОСТ — ГЛАВНАЯ ПОЛОМКА, ОТ КОТОРОЙ ЛЕЧИТ ЭТОТ ФАЙЛ. У владельца
//  загрузка встала на 68 кусках из 76 и не двигалась часами. Причина устройства,
//  а не случая: новые куски раздавались ТОЛЬКО в ответ на завершение предыдущего
//  (`didCompleteWithError` → `fillLanes`). Задача, которая молча повисла и не
//  завершается, обрывала эту цепочку целиком — и раздавать куски становилось некому.
//  Ждать её было бесполезно: каждой задаче отводилась НЕДЕЛЯ (`timeoutIntervalForResource`).
//  Теперь у кусков свой короткий срок, за живыми задачами присматривает сторож
//  (`watchdogTick`), и он же добирает пустые дорожки, что бы ни случилось с событиями.
//
//  ⚠️ ФОНОВАЯ ЗАГРУЗКА СОХРАНЕНА ЦЕЛИКОМ, И ЭТО ГЛАВНОЕ. Куски — это обычные задачи
//  ТОЙ ЖЕ фоновой сессии, поэтому они точно так же продолжаются при свёрнутом и
//  закрытом приложении, а система будит нас, когда кусок докачался. Что уже собрано,
//  записано на диск (см. ModelDownloadPlan) — значит, переживает и перезапуск, и
//  выгрузку приложения из памяти. Каждая задача помечена своим номером куска
//  (`taskDescription`), поэтому после пробуждения мы узнаём её обратно.
//
//  ⚠️ ЗАЩИТА ОТ ЧУЖОГО СЕРВЕРА. Файл, скачанный НЕ с официального адреса, принимается
//  только после полной сверки контрольной суммы; не сошлась — файл удаляется, зеркало
//  заносится в чёрный список, человеку говорится правда. Без эталонной суммы зеркала
//  не используются вовсе (см. ModelSources.swift).
//

import Foundation

public final class ModelDownloader: NSObject, @unchecked Sendable {

    public static let shared = ModelDownloader()

    /// Идентификатор главной фоновой сессии. Меняется только вместе с логикой загрузки.
    /// Не private: AppDelegate сверяет по нему, ради какой сессии система разбудила приложение.
    ///
    /// ⚠️ ИМЯ ОСТАВЛЕНО ПРЕЖНИМ НАМЕРЕННО. У владельца прямо сейчас может докачиваться
    /// файл в сессии с этим именем; поменяй имя — и система отдаст те гигабайты никому.
    public static let sessionIdentifier = "app.pocketagent.model-download"

    /// Имена всех фоновых сессий: главная плюс по одной на каждую дополнительную дорожку.
    ///
    /// ⚠️ ПОЧЕМУ СЕССИЙ НЕСКОЛЬКО, А НЕ ОДНА С НЕСКОЛЬКИМИ ЗАДАЧАМИ. Это не украшение,
    /// а единственный способ получить обещанную скорость. Сервер отвечает по HTTP/2,
    /// а в нём все запросы ОДНОЙ сессии идут по ОДНОМУ соединению — Apple прямо так и
    /// пишет: настройка «сколько соединений на узел» считает соединения, а не запросы.
    /// Живой замер 09.08.2026 показал цену вопроса ровно: три куска по одному
    /// соединению — 1,23 МБ/с (то есть ничем не лучше одного потока), те же три куска
    /// по трём отдельным соединениям — 1,97 МБ/с. Своё соединение появляется у каждой
    /// сессии, поэтому дорожек столько же, сколько сессий.
    ///
    /// ⚠️ ИМЁН ВСЕГДА СТОЛЬКО, СКОЛЬКО ДОРОЖЕК МОЖЕТ БЫТЬ, А НЕ СКОЛЬКО ВЫБРАНО СЕЙЧАС.
    /// Человек может убавить число потоков посреди загрузки — и куски, начатые на
    /// убранной дорожке, продолжают качаться в системе. Не назови мы её имя, система
    /// разбудила бы приложение ради сессии, о которой оно не знает, и те мегабайты
    /// пропали бы впустую.
    public static let sessionIdentifiers: [String] = {
        var names = [ModelDownloader.sessionIdentifier]
        var lane = 1
        while lane <= ModelDownloader.maxLanes {
            names.append("\(ModelDownloader.sessionIdentifier).\(lane)")
            lane += 1
        }
        return names
    }()

    /// Наша ли это фоновая сессия. Зовёт AppDelegate при пробуждении приложения.
    public static func handles(sessionIdentifier identifier: String) -> Bool {
        sessionIdentifiers.contains(identifier)
    }

    /// Обработчик, который система передаёт при пробуждении приложения ради главной
    /// фоновой сессии. Для остальных сессий есть `setBackgroundCompletionHandler(_:for:)`.
    public var backgroundCompletionHandler: (() -> Void)? {
        get { lock.withLock { self.backgroundHandlers[Self.sessionIdentifier] } }
        set { setBackgroundCompletionHandler(newValue, for: Self.sessionIdentifier) }
    }

    /// Запомнить обработчик для конкретной фоновой сессии.
    /// Вызвать его обязаны мы — иначе система решит, что приложение зависло.
    public func setBackgroundCompletionHandler(_ handler: (() -> Void)?, for identifier: String) {
        lock.withLock {
            if let handler {
                self.backgroundHandlers[identifier] = handler
            } else {
                self.backgroundHandlers.removeValue(forKey: identifier)
            }
        }
    }

    /// Разрешить сотовую сеть.
    public static var allowsCellularAccess = true

    // MARK: - Настройки многопоточной загрузки

    /// Больше стольких потоков не бывает. Число не настройка, а обещание системе:
    /// имена фоновых сессий считаются отсюда и меняться не должны никогда.
    public static let maxLanes = 6

    /// Что предлагаем человеку на выбор.
    public static let laneChoices: [Int] = [1, 2, 3, 4, 6]
    public static let chunkChoicesMegabytes: [Int] = [8, 16, 32, 64]

    private static let lanesKey = "download.lanes"
    private static let chunkKey = "download.chunkMegabytes"

    /// Сколько кусков тянем одновременно.
    ///
    /// ⚠️ ЧИСЛО ПОДБИРАЕТСЯ ЗАМЕРОМ, А НЕ ВКУСОМ, И ПОТОМУ ОНО НАСТРОЙКА. 09.08.2026,
    /// живой файл Gemma 4 E2B с Hugging Face: 1 поток — 1,30 МБ/с, 2 — 1,60, 3 — 1,85,
    /// 4 — 1,77, 6 — 1,97. Разброс между тремя и шестью — в пределах дрожания связи,
    /// поэтому «три» были не выводом, а догадкой. По умолчанию берём четыре: это
    /// середина измеренного, а цена ошибки теперь мала — дорожки добираются на ходу.
    /// Проверять придётся на живом телефоне, замером «было → стало» (см. `speedNow`).
    public static var laneCount: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: lanesKey)
            guard saved > 0 else { return 4 }
            return min(maxLanes, max(1, saved))
        }
        set { UserDefaults.standard.set(min(maxLanes, max(1, newValue)), forKey: lanesKey) }
    }

    /// Размер одного куска в мегабайтах.
    ///
    /// ⚠️ ЭТО ЦЕНА ОДНОЙ НЕУДАЧИ. Оборвался кусок — теряем его целиком, а не весь файл.
    /// Было 32 МБ, стало 16: файл на 2,55 ГБ делится на 160 кусков вместо 76, дорожки
    /// перетасовываются вдвое чаще (значит, отставший поток тормозит хвост вдвое меньше),
    /// а лишние обращения к серверу стоят копейки — соединение между кусками не рвётся,
    /// это один запрос примерно на треть секунды, около 12 секунд за всю загрузку.
    public static var chunkMegabytes: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: chunkKey)
            guard saved > 0 else { return 16 }
            return min(256, max(4, saved))
        }
        set { UserDefaults.standard.set(min(256, max(4, newValue)), forKey: chunkKey) }
    }

    static var chunkBytes: Int64 { Int64(chunkMegabytes) * 1024 * 1024 }

    /// Сколько раз пробуем один и тот же кусок, прежде чем сдаться.
    /// Счётчик обнуляется, как только кусок доехал: связь дёргается, и одна неудача
    /// час назад не должна засчитываться против удачи сейчас.
    static let maxChunkAttempts = 6

    /// Как часто сторож смотрит, живы ли куски.
    private static let watchdogTickSeconds: Double = 15
    /// Кусок, в который за это время не прилетело НИ ОДНОГО байта, считаем мёртвым
    /// и снимаем. Потеряем не больше одного куска, а стоящая намертво задача стоит
    /// всей загрузки — ровно это и случилось у владельца на 68 кусках из 76.
    private static let chunkStallSeconds: Double = 75

    // MARK: - Прямой адрес и смена источника

    /// Прямая ссылка вместе с тем, к чему она относится: чужому файлу или другому
    /// источнику она не годится, а перепутать их — значит качать не то и не оттуда.
    struct DirectLink {
        let modelID: String
        let sourceID: String
        let resolved: ResolvedSourceURL
    }

    /// Как часто вообще можно переспрашивать «а нет ли источника быстрее».
    /// Чаще незачем: каждая такая проверка — это настоящий обмен с сервером.
    private static let sourceRecheckSeconds: Double = 60

    /// До какой доли файла переезд ещё имеет смысл.
    ///
    /// ⚠️ В КОНЦЕ ЗАГРУЗКИ ПЕРЕЕЗЖАТЬ НЕЛЬЗЯ. Осталась треть — выигрыш от нового
    /// источника уже меньше, чем цена разгона новых соединений, зато лишний повод
    /// для обрыва создаётся настоящий.
    private static let sourceRecheckUntilFraction = 2.0 / 3.0

    /// Насколько живая скорость должна просесть против лучшего за заход, чтобы
    /// вообще идти проверять другие источники. Мелкие качели — это связь, а не источник.
    private static let sourceSagFraction = 0.5

    /// Сколько раз за одну загрузку разрешено переспрашивать источники по скорости.
    /// Отказы источника этот запас не тратят — там переезд нужен всегда.
    private static let maxSourceChecks = 3

    // MARK: - Внутреннее состояние (всё под замком)

    /// Как часто проверяем свободное место по ходу загрузки (байт скачано между проверками).
    private static let spaceCheckStepBytes: Int64 = 64 * 1024 * 1024
    /// Сколько места оставляем системе сверх недокачанного остатка.
    private static let spaceReserveBytes: Int64 = 200 * 1024 * 1024

    private let lock = NSLock()
    private var waiters: [CheckedContinuation<URL, Error>] = []
    private var progressHandlers: [UUID: @Sendable (Double) -> Void] = [:]
    private var currentModel: ModelDescriptor?
    private var finishedFileResult: Result<URL, Error>?
    private var isStarting = false
    /// На каком объёме скачанного в последний раз смотрели свободное место.
    private var lastSpaceCheckBytes: Int64 = 0
    /// Почему мы сами сняли задачу. Нужно, чтобы человек увидел настоящую причину,
    /// а не общее «Загрузка остановлена».
    private var pendingFailure: PocketAgentError?

    /// План сборки из кусков. nil — качаем обычным одним потоком.
    private var plan: ModelDownloadPlan?
    /// Прямая ссылка на сеть доставки — та, что получается после перенаправления.
    ///
    /// ⚠️ ТОЛЬКО В ПАМЯТИ, НА ДИСК ЕЁ КЛАСТЬ НЕЛЬЗЯ. Подпись живёт около часа, а файл
    /// на 2 ГБ по слабой связи едет дольше: сохранённая в план ссылка протухла бы
    /// раньше, чем понадобилась, и продолжение загрузки после перезапуска приложения
    /// упёрлось бы в отказ. В плане на диске лежит обычный адрес, он вечный.
    private var directLink: DirectLink?
    /// Ссылку уже переспрашиваем — второй раз незачем.
    private var isResolvingLink = false
    /// Переезд на другой источник уже идёт.
    private var isSwitchingSource = false
    /// Когда в последний раз проверяли, нет ли источника побыстрее.
    private var lastSourceCheckAt: Date?
    /// Сколько таких проверок осталось на этот заход.
    private var sourceChecksLeft = 0
    /// Замер живой скорости: когда снимали, сколько было скачано, что вышло и что было
    /// лучшим за заход. По просадке относительно лучшего и видно, что источник сдал.
    private var lastSpeedSampleAt: Date?
    private var lastSpeedSampleBytes: Int64 = 0
    private var lastRecentBytesPerSecond: Double = 0
    private var bestRecentBytesPerSecond: Double = 0
    /// Сколько байт скачал каждый живой кусок прямо сейчас.
    private var chunkWritten: [Int: Int64] = [:]
    /// Сколько раз мы уже пробовали этот кусок.
    private var chunkAttempts: [Int: Int] = [:]
    /// Источники, которыми больше не пользуемся (например, зеркало с несошедшейся суммой).
    private var blockedSources: Set<String> = []
    /// Мы сами снимаем задачи и ждём, что отмены придут, — их не надо считать за обрыв.
    private var isStopping = false
    /// Что показать человеку про источник: «качаю с официального сайта в 4 потока».
    private var sourceNoteText = ""
    /// Обработчики, которые система дала при пробуждении, — по одному на сессию.
    private var backgroundHandlers: [String: () -> Void] = [:]
    /// Когда в кусок в последний раз прилетали байты. По этому и видно зависшую задачу.
    private var chunkTouchedAt: [Int: Date] = [:]
    /// Сторож зависшей загрузки. Живёт, пока человек ждёт файл.
    private var watchdog: DispatchSourceTimer?
    /// Начало нынешнего захода загрузки и сколько байт с тех пор реально прилетело
    /// из сети. Нужно ровно для честного ответа на вопрос «а стало ли быстрее».
    private var runStartedAt: Date?
    private var runArrivedBytes: Int64 = 0
    /// ⚠️ ВРЕМЯ СЧИТАЕМ ТОЛЬКО ПОКА БАЙТЫ ИДУТ, А НЕ ПО ЧАСАМ НА СТЕНЕ. Иначе час на
    /// паузе или час без связи делил бы прилетевшее на пустоту: честные 2,3 МБ/с
    /// превращались в 0,3 МБ/с, и такая цифра уезжала в итог загрузки.
    private var runActiveSeconds: Double = 0
    private var runLastByteAt: Date?
    /// С какими настройками шёл ЭТОТ заход. Спрашивать текущие нельзя: человек может
    /// сменить число потоков посреди загрузки, и замер отрапортовал бы новое число
    /// про старую работу.
    private var runLanes = 0
    private var runChunkMegabytes = 0
    /// Тот же замер, но на всю папку-модель Apple: она качается по файлу, и каждый файл
    /// заканчивается своим `finishAll`. Без этого «Прошлая загрузка» показывала цифру
    /// последнего мелкого описания под именем всей модели: «5 ГБ» превращались в «41 МБ».
    private var folderRunStartedAt: Date?
    private var folderArrivedBytes: Int64 = 0
    private var folderActiveSeconds: Double = 0
    private var folderLanes = 0
    private var folderChunkMegabytes = 0

    /// Очередь сторожа — отдельная, чтобы он не мешал разбирать события загрузки.
    private let watchdogQueue = DispatchQueue(label: "app.pocketagent.model-download.watchdog")

    /// Последний известный прогресс 0…1 — чтобы экран не начинал с нуля после возврата.
    public private(set) var lastProgress: Double = 0

    private override init() {
        super.init()
    }

    /// Очередь, на которой приходят ВСЕ события ВСЕХ сессий.
    ///
    /// ⚠️ ОДНА НА ВСЕХ И СТРОГО ПО ОЧЕРЕДИ — это то, что удерживает сложность в узде.
    /// Сессий несколько, и если у каждой будет своя очередь, два куска смогут доехать
    /// ровно одновременно: два потока полезут править один и тот же план сборки и
    /// один и тот же файл. Общая очередь на одно дело за раз возвращает нас к тому же
    /// простому порядку, что был при единственной сессии.
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "app.pocketagent.model-download.events"
        return queue
    }()

    /// Все фоновые сессии: первая — главная (в ней качается целый файл), остальные —
    /// дорожки для кусков. Разные сессии = разные соединения = настоящая скорость.
    private lazy var sessions: [URLSession] = {
        Self.sessionIdentifiers.enumerated().map { position, identifier -> URLSession in
            let config = URLSessionConfiguration.background(withIdentifier: identifier)
            config.sessionSendsLaunchEvents = true          // разбудить приложение, когда докачается
            config.isDiscretionary = false                  // не откладывать «до удобного момента»
            config.allowsCellularAccess = Self.allowsCellularAccess
            config.allowsExpensiveNetworkAccess = Self.allowsCellularAccess
            // ⚠️ Режим экономии трафика загрузку больше не отменяет. Человек нажал
            // «Скачать модель» — это его согласие; выдумывать за него запрет незачем,
            // и раньше такой запрет просто ронял загрузку без внятной причины.
            config.allowsConstrainedNetworkAccess = true
            config.httpMaximumConnectionsPerHost = 1
            if position == 0 {
                // Главная сессия тянет ВЕСЬ файл одной задачей: на плохой связи это
                // законно занимает сутки, и обрывать её по сроку нельзя.
                config.timeoutIntervalForResource = 7 * 24 * 3600
            } else {
                // ⚠️ А ВОТ КУСКУ НЕДЕЛЯ НЕ НУЖНА, И ИМЕННО ЭТО ПОДВЕШИВАЛО ЗАГРУЗКУ.
                // Кусок в 16 МБ, который не доехал за полчаса, не «медленный», а мёртвый:
                // это меньше 10 КБ/с. Пока срок был недельный, такая задача честно
                // числилась живой и занимала дорожку, а хвост файла не брал никто.
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = max(15 * 60, Double(Self.chunkMegabytes) * 30)
            }
            // Фоновая сессия обязана иметь делегата.
            return URLSession(configuration: config, delegate: self, delegateQueue: self.delegateQueue)
        }
    }()

    /// Главная сессия: в ней живёт обычная загрузка целого файла — ровно как раньше.
    private var primarySession: URLSession { sessions[0] }

    /// Сессия дорожки: у каждой своя, потому что скорость даёт число РАЗНЫХ соединений,
    /// а соединение у сессии одно. Дорожка 0 — это сессия «…​.1», главную под куски
    /// не занимаем: у неё свои сроки, рассчитанные на загрузку целого файла.
    private func session(forLane lane: Int) -> URLSession {
        let list = sessions
        let position = min(max(1, lane + 1), list.count - 1)
        return list[position]
    }

    /// Задачи загрузки, разложенные ПО ДОРОЖКАМ: `result[i]` — задачи `sessions[i]`.
    ///
    /// ⚠️ ЗАЧЕМ ЗНАТЬ ДОРОЖКУ, А НЕ ПРОСТО СПИСОК. Скорость даёт не число кусков,
    /// а число РАЗНЫХ соединений, а соединение у нас одно на сессию. Значит, прежде
    /// чем занять дорожку новым куском, надо видеть, не занята ли она уже. Пока задачи
    /// сваливались в общий список, этого было не видно — см. пояснение у `fillLanes`.
    ///
    /// Результат приходит на общую очередь событий — как и все остальные отклики.
    private func downloadTasksByLane(_ completion: @escaping ([[URLSessionDownloadTask]]) -> Void) {
        let list = sessions
        guard !list.isEmpty else {
            completion([])
            return
        }
        let box = NSLock()
        var collected = [[URLSessionDownloadTask]](repeating: [], count: list.count)
        var left = list.count

        for (lane, item) in list.enumerated() {
            item.getTasksWithCompletionHandler { _, _, downloads in
                box.lock()
                collected[lane] = downloads
                left -= 1
                let finished = left == 0
                let snapshot = collected
                box.unlock()
                if finished { completion(snapshot) }
            }
        }
    }

    /// Задачи загрузки из ВСЕХ сессий разом — когда дорожка не важна.
    private func allDownloadTasks(_ completion: @escaping ([URLSessionDownloadTask]) -> Void) {
        downloadTasksByLane { lanes in
            completion(lanes.flatMap { $0 })
        }
    }

    // MARK: - Публичный API

    /// Поднять фоновую сессию, ничего не начиная.
    ///
    /// ⚠️ БЕЗ ЭТОГО ФОНОВАЯ ЗАГРУЗКА ТЕРЯЛАСЬ ЦЕЛИКОМ. Когда гигабайты докачиваются при
    /// закрытом приложении, система будит процесс и передаёт обработчик в AppDelegate.
    /// Но сессия у нас ленивая: пока её никто не тронул, объекта нет, делегат не подключён —
    /// значит, не приходит ни `didFinishDownloadingTo` (файл из временной папки НЕ переезжает
    /// в Application Support и система его выбрасывает), ни `urlSessionDidFinishEvents`.
    /// Человек открывал приложение и видел снова 0 % и кнопку «Скачать модель».
    /// AppDelegate обязан позвать это ПЕРЕД тем, как положить обработчик.
    public func activateSession() {
        // ⚠️ Поднимаем ВСЕ сессии, а не только ту, ради которой нас разбудили: куски
        // одной загрузки лежат в разных сессиях, и не поднятая сессия — это молча
        // потерянный кусок.
        _ = sessions
    }

    /// Идёт ли загрузка прямо сейчас.
    public var isDownloading: Bool {
        lock.lock(); defer { lock.unlock() }
        return !waiters.isEmpty || isStarting
    }

    /// Одна честная строка про то, откуда и как качаем. nil — сказать пока нечего.
    /// Экран показывает её рядом со скоростью; выбор источника делает приложение само.
    public var sourceNote: String? {
        lock.lock(); defer { lock.unlock() }
        return sourceNoteText.isEmpty ? nil : sourceNoteText
    }

    /// Откуда качаем прямо сейчас — одним словом площадки: «с Hugging Face»,
    /// «с зеркала ModelScope». nil — загрузка ещё не выбрала источник.
    ///
    /// Нужно экрану картинок: там на полную строку `sourceNote` места нет,
    /// а вопрос владельца был ровно «с какого хоста качаю».
    public var sourceName: String? {
        lock.lock(); defer { lock.unlock() }
        guard !sourceNoteText.isEmpty else { return nil }
        // Обычная загрузка одним потоком идёт без плана и всегда с официального адреса.
        return plan?.sourceName ?? ModelSourceCatalog.official.humanName
    }

    /// Скачать модель. Возвращает путь к готовому файлу.
    /// Если файл уже на месте и нужного размера — возвращает сразу, ничего не качая.
    /// Отмена задачи Swift ставит загрузку на паузу с сохранением прогресса.
    @discardableResult
    public func download(_ model: ModelDescriptor,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {

        // ⚠️ ЗДЕСЬ НЕЛЬЗЯ ОТДАВАТЬ «ЛЮБУЮ ГОДНУЮ МОДЕЛЬ С ТЕЛЕФОНА». Такая проверка тут
        // стояла и молча подменяла заказ: человек выбирал в списке Gemma 4 E4B, жал
        // «Скачать», а получал лежавшую рядом Gemma 3 1B — и надпись «готово, 100 %».
        // Проверять «есть ли вообще что запускать» — не дело загрузчика: это делает
        // подготовка модели (LiteRTRuntime.ensureModelFile) ещё до обращения сюда.
        // Здесь проверяем ТОЛЬКО файл ИМЕННО ЗАПРОШЕННОЙ модели.
        if let installed = ModelStorage.installedModelURL(for: model),
           ModelStorage.byteSize(of: installed) == model.byteSize {
            onProgress(1.0)
            return installed
        }

        // ⚠️ ЗДЕСЬ СТОЯЛ ЗАПРЕТ, И ЭТО БЫЛ БРАК. Раньше любая модель без контрольной
        // суммы получала отказ «загрузка отключена» — приложение решало за человека,
        // что ему нельзя. Владелец на это и указал: «А если я хочу скачать?» Правило
        // проекта — предупреждение, а не запрет: человек видит
        // честную оговорку рядом с кнопкой и решает сам.
        //
        // ⚠️ Отсутствие суммы при этом НЕ означает, что порчу мы не заметим. Размер
        // скачанного сверяется всегда (см. `didFinishDownloadingTo` и сборку из кусков),
        // а содержимое разбирается перед запуском — обрезанный или чужой файл поймают.
        // Не проверить нечем только одно: подменил ли кто-то содержимое целиком.
        //
        // Остаётся отказ там, где качать НЕ ПОЛУЧИТСЯ ФИЗИЧЕСКИ: не из чего собрать
        // адрес файла или неизвестен его размер (тогда нечем мерить ни место на диске,
        // ни готовность).
        if let blocker = Self.downloadBlocker(model) {
            throw PocketAgentError.generationFailed(blocker)
        }

        guard ModelStorage.hasEnoughFreeSpace(for: model) else {
            throw PocketAgentError.notEnoughDiskSpace
        }

        // Убедимся, что папка есть и исключена из резервной копии, ДО начала загрузки.
        _ = try ModelStorage.modelsDirectory()

        let handlerID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                self.lock.lock()
                self.waiters.append(continuation)
                self.progressHandlers[handlerID] = onProgress
                self.currentModel = model
                self.isStarting = true
                // Новая попытка — старые «мы сами всё останавливаем» больше не действуют.
                self.isStopping = false
                self.pendingFailure = nil
                self.lock.unlock()

                Task { await self.startIfNeeded(model) }
            }
        } onCancel: {
            self.pause()
        }
    }

    // MARK: - Модель, которая лежит папкой (формат Apple)

    /// Скачать модель Apple: не один файл, а всю её папку.
    ///
    /// ⚠️ ВТОРОГО ЗАГРУЗЧИКА ЗДЕСЬ НЕТ, И ЭТО ГЛАВНОЕ. Каждый файл папки качает тот же
    /// `download(_:onProgress:)`, что и модель Google, — со всеми его свойствами разом:
    /// куски в несколько потоков, продолжение при свёрнутом и закрытом приложении,
    /// докачка после обрыва (у каждого файла своя), проверка размера, отказ от зеркала
    /// с несошедшейся суммой. Заведи мы тут свой путь загрузки — чинить обрывы пришлось бы
    /// в двух местах, и второе всегда отставало бы.
    ///
    /// ⚠️ ЧЕЛОВЕК ВИДИТ ОДНУ ПОЛОСУ НА ВСЮ МОДЕЛЬ, а не десять по очереди: ход считается
    /// в байтах от общего веса папки, поэтому мелкие описания честно занимают в ней
    /// сотые доли процента, а веса — почти всё.
    ///
    /// ⚠️ ПОРЯДОК ЗАГРУЗКИ — ОТ МЕЛКИХ К КРУПНЫМ, И ЭТО НЕ СЛУЧАЙНОСТЬ. Оборвётся всё
    /// на весах — в папке уже лежат устройство модели, словарь и шаблон разговора,
    /// и проверка честно скажет: «не хватает файла весов». Качай мы наоборот, отчёт
    /// после обрыва был бы «не хватает восьми файлов» — правда, но бесполезная.
    ///
    /// ⚠️ ОБОРВАЛОСЬ — ПАПКА НЕ УДАЛЯЕТСЯ. Она остаётся под именем «…import»: моделью
    /// приложение её не считает (в списке не появится), в занятое место засчитывает,
    /// а следующее нажатие «Продолжить» докачивает недостающее, а не начинает сначала.
    ///
    /// - Returns: путь к готовой папке модели.
    @discardableResult
    public func downloadFolder(_ model: ModelDescriptor,
                               onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {

        let files = model.folderFileList
        guard !files.isEmpty else {
            throw PocketAgentError.generationFailed(
                "Не знаю, из каких файлов состоит модель «\(model.displayName)» — "
                + "скачать её нечем. Найдите её через поиск моделей ещё раз."
            )
        }
        guard !model.repoID.isEmpty, model.repoCommit != "main" else {
            throw PocketAgentError.generationFailed(
                "Не знаю, откуда брать файлы модели «\(model.displayName)». Выберите другую."
            )
        }

        let finalURL = try ModelFolderDownload.finalFolderURL(for: model)
        // Папка уже собрана и полна — качать нечего. Проверяем именно СОСТАВОМ:
        // размер папки такое не ловит (пропавший файл описания её почти не сдвинет).
        if (try? MLXModelFolder.inspect(finalURL)) != nil {
            onProgress(1.0)
            return finalURL
        }

        let temporaryURL = try ModelFolderDownload.temporaryFolderURL(for: model)
        try Self.makeFolder(at: temporaryURL)

        let total = files.reduce(Int64(0)) { $0 + $1.byteSize }
        try Self.ensureSpaceForFolder(model: model, files: files, inside: temporaryURL, total: total)

        // ⚠️ ЗАМЕР ВЕДЁМ НА ВСЮ ПАПКУ, А НЕ НА КАЖДЫЙ ФАЙЛ. Иначе итог загрузки — это
        // цифра последнего скачанного описания на 40 КБ, подписанная именем модели
        // на пять гигабайт. Пока метка стоит, отдельные файлы в итог не пишутся.
        lock.withLock {
            self.folderRunStartedAt = Date()
            self.folderArrivedBytes = 0
            self.folderActiveSeconds = 0
            self.folderLanes = Self.laneCount
            self.folderChunkMegabytes = Self.chunkMegabytes
        }
        defer { lock.withLock { self.folderRunStartedAt = nil } }

        // Мелочь вперёд, веса последними — см. пояснение выше.
        let ordered = files.sorted { $0.byteSize < $1.byteSize }
        var completed: Int64 = 0

        for file in ordered {
            let part = ModelFolderDownload.partDescriptor(of: model, file: file)
            let doneBefore = completed
            let fileBytes = file.byteSize

            _ = try await download(part) { fraction in
                guard total > 0 else { return }
                let inFile = Int64(Double(fileBytes) * max(0, min(1, fraction)))
                onProgress(min(1.0, Double(doneBefore + inFile) / Double(total)))
            }

            completed += fileBytes
            if total > 0 { onProgress(min(1.0, Double(completed) / Double(total))) }
        }

        // ⚠️ ПРОВЕРЯЕМ ПО СОСТАВУ, А НЕ ПО ОДНОМУ ЧИСЛУ, И ПАПКУ ПРИ ЭТОМ НЕ ТРОГАЕМ.
        // Общий размер тут бесполезен: пропавшее описание на 6 КБ его не сдвинет.
        // Сначала сверяем со своим же списком — он точный, с размером каждого файла,
        // поэтому может назвать недостающее ПОИМЁННО. Удалять скачанное нельзя:
        // человек нажмёт «Продолжить», и докачается только то, чего не хватает.
        let missing = files.filter {
            ModelStorage.byteSize(of: temporaryURL.appendingPathComponent($0.name)) != $0.byteSize
        }
        if !missing.isEmpty {
            let names = missing.prefix(3).map(\.name).joined(separator: ", ")
            let tail = missing.count > 3 ? " и ещё \(missing.count - 3)" : ""
            let word = HumanFormat.plural(missing.count, "файла", "файлов", "файлов")
            throw PocketAgentError.generationFailed(
                "Модель «\(model.displayName)» скачалась не целиком: не хватает "
                + "\(missing.count) \(word) — \(names)\(tail). Скачанное сохранено: "
                + "нажмите «Продолжить», и докачается только недостающее."
            )
        }

        // Второй заслон — общая проверка состава, та же, что и у папки, принесённой
        // человеком через «Файлы» (`MLXModelFolder`). Своей второй проверки здесь нет
        // намеренно: разойдись они однажды — и загрузчик принимал бы папку, которую
        // движок не берёт.
        do {
            _ = try MLXModelFolder.inspect(temporaryURL)
        } catch {
            throw PocketAgentError.generationFailed(
                "Все файлы модели «\(model.displayName)» скачаны, но собрать из них модель "
                + "не выходит: \(SystemErrorText.russian(for: error)) Скачанное сохранено — "
                + "если повтор не поможет, удалите его и начните заново."
            )
        }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: finalURL)
        }
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            throw PocketAgentError.writeFailed(path: model.fileName,
                                               reason: SystemErrorText.russian(for: error))
        }
        try? ModelStorage.excludeFromBackup(finalURL)
        // Служебные остатки докачки после удачной сборки не нужны никому.
        discardFolderParts(of: model)
        rememberFolderRunSpeed(of: model)
        onProgress(1.0)
        return finalURL
    }

    /// Завести папку под сборку и вывести её из резервной копии: гигабайты весов
    /// в iCloud не нужны никому.
    private static func makeFolder(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                // На этом месте лежит ФАЙЛ с таким именем — сборке некуда деваться.
                throw PocketAgentError.writeFailed(path: url.lastPathComponent,
                                                   reason: "здесь уже лежит файл с таким именем")
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? ModelStorage.excludeFromBackup(url)
        } catch {
            throw PocketAgentError.writeFailed(path: url.lastPathComponent,
                                               reason: SystemErrorText.russian(for: error))
        }
    }

    /// Хватит ли места на телефоне под ВСЮ папку.
    ///
    /// ⚠️ СЧИТАЕМ ТО, ЧЕГО ЕЩЁ НЕТ. Половина папки могла приехать в прошлый раз, и требовать
    /// место под неё второй раз — значит отказать человеку на ровном месте.
    ///
    /// ⚠️ И ГОВОРИМ ЦИФРАМИ. «Не хватает места» без чисел человек прочитать не может:
    /// непонятно, освобождать ему сто мегабайт или три гигабайта.
    private static func ensureSpaceForFolder(model: ModelDescriptor,
                                             files: [ModelFolderFile],
                                             inside folder: URL,
                                             total: Int64) throws {
        var alreadyHere: Int64 = 0
        for file in files {
            let path = folder.appendingPathComponent(file.name)
            let size = ModelStorage.byteSize(of: path)
            if size == file.byteSize { alreadyHere += size }
        }

        let needed = max(0, total - alreadyHere)
        let free = ModelStorage.availableBytes()
        // Ноль означает «узнать не удалось» — пугать выдуманной цифрой не будем.
        guard free > 0 else { return }
        // Пятая часть сверху — ровно тот же запас, что просит загрузка одного файла
        // (`ModelStorage.hasEnoughFreeSpace`). Возьми мы здесь запас меньше — человек
        // получил бы наш подробный отказ с цифрами не первым, а вторым: сначала сработал
        // бы общий «не хватает места на телефоне», в котором никаких цифр нет.
        guard free < Int64(Double(needed) * 1.2) else { return }

        var text = "Модели «\(model.displayName)» нужно \(HumanFormat.bytes(needed)), "
            + "а свободно \(HumanFormat.bytes(free))."
        if alreadyHere > 0 {
            text += " \(HumanFormat.bytes(alreadyHere)) уже скачано — это место занято "
                + "недособранной моделью, его можно освободить кнопкой «Удалить скачанное»."
        }
        text += " Освободите место и попробуйте снова."
        throw PocketAgentError.generationFailed(text)
    }

    /// Убрать служебные остатки загрузки папки: точки докачки и недособранные куски
    /// по каждому её файлу. Саму папку не трогает.
    ///
    /// ⚠️ Без этого недокачанный кусок весов (до 32 МБ) и собираемый файл (до гигабайтов)
    /// оставались бы лежать в хранилище невидимками: в списке моделей их нет, в занятом
    /// месте они не считаются, удалить их человеку нечем.
    public func discardFolderParts(of model: ModelDescriptor) {
        for file in model.folderFileList {
            let part = ModelFolderDownload.partDescriptor(of: model, file: file)
            ModelDownloadPlanStore.clear(modelID: part.id)
            ModelStorage.clearResumeData(for: part)
        }
    }

    /// Сколько из папки-модели уже лежит на телефоне, долей 0…1.
    ///
    /// ⚠️ НУЖНО РОВНО ДЛЯ ПЕРВОГО КАДРА ПОЛОСЫ ЗАГРУЗКИ. Вернувшись к прерванной
    /// загрузке, человек должен увидеть своё место, а не ноль и не чужое число:
    /// общий `lastProgress` помнит долю ПОСЛЕДНЕГО скачанного файла, и после мелкого
    /// описания это честные «100 %», которые к папке отношения не имеют.
    public func folderProgress(for model: ModelDescriptor) -> Double {
        let files = model.folderFileList
        let total = files.reduce(Int64(0)) { $0 + $1.byteSize }
        guard total > 0, let folder = try? ModelFolderDownload.temporaryFolderURL(for: model) else {
            return 0
        }
        var done: Int64 = 0
        for file in files {
            let size = ModelStorage.byteSize(of: folder.appendingPathComponent(file.name))
            if size == file.byteSize { done += size }
        }
        return min(1.0, Double(done) / Double(total))
    }

    /// Сколько уже приехало из папки-модели: и собранное в папке, и то, что лежит
    /// в недособранных кусках.
    private func folderOccupiedBytes(for model: ModelDescriptor) -> Int64 {
        var total: Int64 = 0
        if let ready = try? ModelFolderDownload.finalFolderURL(for: model) {
            total += ModelStorage.byteSize(of: ready)
        }
        if let temporary = try? ModelFolderDownload.temporaryFolderURL(for: model) {
            total += ModelStorage.byteSize(of: temporary)
        }
        for file in model.folderFileList {
            let part = ModelFolderDownload.partDescriptor(of: model, file: file)
            total += ModelDownloadPlanStore.downloadedBytes(modelID: part.id)
        }
        return total
    }

    /// Пауза с сохранением точки обрыва. Загрузку можно продолжить позже.
    public func pause() {
        // Сборка из кусков: план на диске уже помнит всё готовое, ничего не потеряется.
        if lock.withLock({ self.plan }) != nil {
            stopAllChunks()
            return
        }

        let model = lock.withLock { currentModel }
        // self в замыкании нужен ровно затем, чтобы отпустить ожидающих.
        allDownloadTasks { [weak self] downloads in
            guard let task = downloads.first(where: { $0.state == .running || $0.state == .suspended }) else {
                // ⚠️ Живой задачи ещё нет — она создаётся отдельной Task через мгновение
                // после постановки ожидающего в очередь. Раньше мы здесь просто выходили,
                // и ожидание повисало НАВСЕГДА: подготовка модели больше не заканчивалась,
                // кнопка «Скачать модель» переставала отвечать до перезапуска приложения.
                self?.finishAll(with: .failure(PocketAgentError.downloadStopped))
                return
            }
            task.cancel(byProducingResumeData: { data in
                if let data, let model {
                    ModelStorage.saveResumeData(data, for: model)
                }
            })
        }
    }

    /// Полная отмена: снимает задачу и выбрасывает данные для докачки.
    /// Это же зовёт кнопка «Удалить скачанное» на экране подготовки — без неё
    /// недокачанные гигабайты оставались занимать место, и убрать их было нечем.
    public func cancelAndDiscard(_ model: ModelDescriptor) {
        // План убираем ПЕРВЫМ — и в памяти, и с диска. Тогда отмены кусков придут уже
        // «в никуда» и не будут приняты ни за обрыв связи, ни за повод что-то продолжать.
        //
        // ⚠️ Убираем и план ТОЙ модели, которую качали на самом деле. Кнопка отмены
        // приходит с описанием выбранной модели, а качаться могла соседняя — и тогда
        // её план пережил бы отмену, куски перезапустились бы сами, и «Отмена»
        // на глазах у человека ничего бы не отменила.
        let live = lock.withLock { () -> ModelDownloadPlan? in
            let value = self.plan
            self.plan = nil
            self.chunkWritten.removeAll()
            self.chunkAttempts.removeAll()
            self.lastSpaceCheckBytes = 0
            return value
        }
        ModelDownloadPlanStore.clear(modelID: model.id)
        if let live, live.modelID != model.id {
            ModelDownloadPlanStore.clear(modelID: live.modelID)
        }
        ModelStorage.clearResumeData(for: model)

        // ⚠️ У модели-папки отменять надо ВОСЕМЬ загрузок, а не одну: каждый её файл
        // качается своим заказом, и у каждого своя точка докачки. Убираем и недособранную
        // папку целиком — иначе «Отмена» оставила бы гигабайты, которых человек не видит.
        if model.isFolderModel {
            discardFolderParts(of: model)
            if let temporary = try? ModelFolderDownload.temporaryFolderURL(for: model) {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        allDownloadTasks { downloads in
            downloads.forEach { $0.cancel() }
        }
        finishAll(with: .failure(PocketAgentError.generationCancelled))
    }

    /// Сколько занимает уже скачанное: готовый файл либо то, что успела собрать
    /// многопоточная загрузка.
    public func occupiedBytes(for model: ModelDescriptor) -> Int64 {
        // У папки-модели «скачанное» складывается из трёх мест сразу, и показать надо всё.
        if model.isFolderModel { return folderOccupiedBytes(for: model) }
        let ready = ModelStorage.downloadedBytes(for: model)
        if ready > 0 { return ready }
        return ModelDownloadPlanStore.downloadedBytes(modelID: model.id)
    }

    /// Есть ли что удалять: скачанный файл, точка докачки или начатая сборка из кусков.
    public func hasSomethingToDelete(_ model: ModelDescriptor) -> Bool {
        if model.isFolderModel { return folderOccupiedBytes(for: model) > 0 }
        return ModelStorage.downloadedBytes(for: model) > 0
            || ModelStorage.loadResumeData(for: model) != nil
            || ModelDownloadPlanStore.load(modelID: model.id) != nil
    }

    /// Удалить скачанную модель с устройства.
    public func deleteDownloadedModel(_ model: ModelDescriptor) throws {
        guard !isDownloading else {
            throw PocketAgentError.writeFailed(path: model.fileName,
                                               reason: "Идёт загрузка, сначала остановите её.")
        }
        try ModelStorage.removeDownloadedModel(model)
        ModelDownloadPlanStore.clear(modelID: model.id)
        if model.isFolderModel {
            discardFolderParts(of: model)
            if let temporary = try? ModelFolderDownload.temporaryFolderURL(for: model) {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
    }

    // MARK: - Запуск

    private func startIfNeeded(_ model: ModelDescriptor) async {
        defer { lock.withLock { self.isStarting = false } }

        // Не плодим вторую задачу: после перезапуска приложения фоновая
        // загрузка могла остаться живой в системе.
        let alive = await existingTasks()
        if !alive.isEmpty {
            if lock.withLock({ self.plan }) == nil,
               let saved = ModelDownloadPlanStore.load(modelID: model.id), saved.matches(model) {
                adoptPlan(saved)
            }

            // ⚠️ Кусок без плана — сирота от прошлой отменённой сборки. Оставить его
            // жить нельзя: он честно докачается, но приехать ему будет некуда, а мы
            // всё это время будем считать, что загрузка идёт. Экран замер бы намертво.
            let hasPlan = lock.withLock { self.plan } != nil
            var somethingUsefulIsRunning = false
            for task in alive {
                if Self.chunkIndex(of: task) != nil, !hasPlan {
                    task.cancel()
                    continue
                }
                somethingUsefulIsRunning = true
                if task.state == .suspended { task.resume() }
            }
            if somethingUsefulIsRunning {
                // ⚠️ РАНЬШЕ ЗДЕСЬ ПРОСТО ВЫХОДИЛИ, И ЭТО БЫЛА ТИХАЯ ПОТЕРЯ ПОТОКОВ.
                // Жива одна задача из трёх — значит, две дорожки пустуют, и занять их
                // было некому: новые куски раздавались только в ответ на завершение
                // предыдущего. Один повисший кусок останавливал загрузку целиком.
                // Теперь досыпаем куски на свободные дорожки сразу и включаем сторожа.
                if hasPlan {
                    fillLanes()
                    startWatchdog()
                }
                return
            }
        }

        // Незаконченная сборка из кусков — продолжаем её. Собранное не теряется.
        if let saved = ModelDownloadPlanStore.load(modelID: model.id) {
            if saved.matches(model) {
                adoptPlan(saved)
                fillLanes()
                return
            }
            // План от другой модели — это мусор, а не наша сборка.
            ModelDownloadPlanStore.clear(modelID: saved.modelID)
        }

        // Точка обрыва обычной загрузки — это уже скачанные гигабайты, их не бросаем.
        //
        // ⚠️ НО НЕ ЛЮБОЙ ЦЕНОЙ, И ВОТ ПОЧЕМУ. Точка обрыва бывает только у загрузки
        // ОДНИМ потоком, и продолжается она тоже одним. То есть один давний обрыв
        // навсегда сажал остаток файла на один поток: скачал человек триста мегабайт
        // из пяти гигабайт, потерял связь — и все оставшиеся четыре с половиной
        // гигабайта поедут втрое медленнее, причём молча и до самого конца.
        //
        // Считаем честно. Продолжить одним потоком — это оставшаяся доля файла на
        // обычной скорости. Начать заново в несколько потоков — это весь файл на скорости,
        // умноженной на их число.
        // Второе выгоднее, пока скачано меньше двух третей. Поэтому: скачано много —
        // бережём; скачано мало — выбрасываем и начинаем быстро.
        //
        // Не смогли выяснить, сколько там скачано, — ничего не выдумываем и
        // продолжаем как раньше.
        if let resumeData = ModelStorage.loadResumeData(for: model) {
            let already = Self.bytesInside(resumeData: resumeData)
            let worthKeeping = already == nil
                || model.byteSize <= 0
                || Double(already!) >= Double(model.byteSize) * 2.0 / 3.0
            if worthKeeping {
                startClassicDownload(model, resumeData: resumeData)
                return
            }
            ModelStorage.clearResumeData(for: model)
        }

        // ⚠️ МЕЛКИЙ ФАЙЛ ЗАМЕРОМ ИСТОЧНИКОВ НЕ МУЧАЕМ. Кусок у нас 32 МБ, а описание
        // модели весит килобайты — делить там нечего, и весь замер ушёл бы впустую.
        // Для моделей Google это условие не срабатывает никогда (их файлы — гигабайты),
        // а вот у папки Apple мелких файлов сразу восемь, и восемь замеров подряд —
        // это несколько лишних секунд ожидания на ровном месте.
        if model.byteSize <= Self.chunkBytes {
            startClassicDownload(model, resumeData: nil)
            return
        }

        // Новая загрузка: замеряем источники маленьким куском и берём самый быстрый.
        // ⚠️ Замер ничего не обещает человеку: не получилось — молча берём официальный
        // адрес. Показывать ошибку замера человеку незачем.
        let blocked = lock.withLock { self.blockedSources }
        let measurement = await ModelSourceProbe.chooseFastest(for: model,
                                                              allowsCellular: Self.allowsCellularAccess,
                                                              blocked: blocked)

        if let measurement,
           measurement.supportsRanges,
           Self.sizeAgrees(measurement, model: model),
           Self.mayUse(measurement.source, for: model) {
            // ⚠️ ПРЯМОЙ АДРЕС, ДОБЫТЫЙ ЗАМЕРОМ, ЗАБИРАЕМ С СОБОЙ. Он получен один раз
            // и годится на все куски: каждый кусок иначе платит за перенаправление
            // 1,2–3,2 секунды, а кусков около сотни.
            startMultipartDownload(model,
                                   source: measurement.source,
                                   resolved: measurement.resolved,
                                   choiceNote: measurement.choiceNote)
            return
        }

        // ⚠️ НЕУДАВШИЙСЯ ЗАМЕР БОЛЬШЕ НЕ ОТБИРАЕТ ДВА ПОТОКА ИЗ ТРЁХ. Раньше любая
        // осечка разведки — оборванный ответ, слабая связь, отказ на пару секунд —
        // означала, что все оставшиеся гигабайты поедут ОДНИМ потоком. Цена осечки
        // выходила в десятки минут, а причины человек не видел никогда.
        //
        // Так осторожничать незачем: официальный адрес мы знаем сами и знаем, что он
        // отдаёт файл по частям. А если сервер вдруг ответит на просьбу о куске целым
        // файлом, это видно на первых килобайтах — тогда многопоточность сворачивается
        // сама (`promisedTooMuch` и `fallBackToSingleStream`), ничего лишнего не скачав.
        // Зеркал это послабление НЕ касается: чужой сервер без удавшейся разведки
        // не берём, там осторожность оправдана.
        if measurement == nil, !blocked.contains(ModelSourceCatalog.official.id) {
            startMultipartDownload(model, source: ModelSourceCatalog.official)
            return
        }

        startClassicDownload(model, resumeData: nil)
    }

    /// Сколько байт уже лежит в точке обрыва. nil — выяснить не удалось.
    ///
    /// ⚠️ Точка обрыва — это запись самой системы, и её внутреннее устройство Apple
    /// не описывает. Но это обычный список свойств, и число скачанного лежит в нём
    /// под понятным именем. Читаем его ОСТОРОЖНО и только чтобы решить, стоит ли
    /// продолжать одним потоком: не разобрали — просто продолжаем, как продолжали
    /// всегда. Ошибиться тут нечем, лишнего мы не делаем.
    private static func bytesInside(resumeData: Data) -> Int64? {
        guard let plist = try? PropertyListSerialization.propertyList(from: resumeData,
                                                                     options: [],
                                                                     format: nil),
              let fields = plist as? [String: Any] else {
            return nil
        }
        guard let value = fields["NSURLSessionResumeBytesReceived"] as? NSNumber else {
            return nil
        }
        let bytes = value.int64Value
        return bytes > 0 ? bytes : nil
    }

    /// Что мешает скачать эту модель НАСОВСЕМ. nil — качать можно.
    ///
    /// ⚠️ ЗДЕСЬ ТОЛЬКО ТО, ЧТО ДЕЛАЕТ ЗАГРУЗКУ НЕВОЗМОЖНОЙ, а не то, что кажется нам
    /// неразумным. «Нет контрольной суммы», «вряд ли хватит памяти», «мы такой файл
    /// пока не запускаем» — это поводы предупредить, и предупреждение человек видит
    /// на экране рядом с кнопкой. Решает он.
    ///
    /// Место на диске проверяется отдельно, следующей же строкой: там нужен свой
    /// понятный отказ с цифрами.
    ///
    /// ⚠️ ОТКРЫТ НАРУЖУ НАМЕРЕННО. Тот же вопрос задаёт экран поиска ДО того, как увести
    /// человека на вкладку «Модели»: узнать «эту модель взять неоткуда» на том экране,
    /// где палец только что нажал кнопку, — это ответ, а узнать через переход на другой
    /// экран — это уже загадка.
    public static func refusalReason(for model: ModelDescriptor) -> String? {
        downloadBlocker(model)
    }

    private static func downloadBlocker(_ model: ModelDescriptor) -> String? {
        if model.repoID.isEmpty || model.fileName.isEmpty {
            return "Не знаю, откуда брать файл модели «\(model.displayName)» — "
                + "у неё не записан адрес. Выберите другую."
        }
        if model.byteSize <= 0 {
            return "Не знаю, сколько весит файл модели «\(model.displayName)», "
                + "поэтому не могу ни проверить место на телефоне, ни показать ход загрузки."
        }
        return nil
    }

    /// Сходится ли размер файла у источника с тем, что записано в справочнике.
    ///
    /// Сервер мог размер и не назвать. Официальному в этом случае верим справочнику:
    /// цифра там снята с его же API и сверяется контрольной суммой после загрузки.
    /// Зеркалу не верим: не назвал размер — значит, режем куски вслепую, а это уже
    /// не «быстрее», а «неизвестно что».
    private static func sizeAgrees(_ measurement: ModelSourceMeasurement,
                                   model: ModelDescriptor) -> Bool {
        if measurement.declaredTotalBytes == model.byteSize { return true }
        return measurement.declaredTotalBytes == 0 && measurement.source.isOfficial
    }

    /// Можно ли вообще брать этот источник для этой модели.
    /// Зеркало — только когда есть с чем сверять скачанное. Это не обсуждается.
    private static func mayUse(_ source: ModelSource, for model: ModelDescriptor) -> Bool {
        if source.isOfficial { return true }
        return !model.sha256.isEmpty
    }

    private func existingTasks() async -> [URLSessionDownloadTask] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[URLSessionDownloadTask], Never>) in
            allDownloadTasks { downloads in
                let alive = downloads.filter { $0.state == .running || $0.state == .suspended }
                continuation.resume(returning: alive)
            }
        }
    }

    // MARK: Обычная загрузка — одна задача на весь файл

    private func startClassicDownload(_ model: ModelDescriptor, resumeData: Data?) {
        // Целый файл всегда качает ГЛАВНАЯ сессия — ровно та же, что и до всех этих
        // правок. Значит, докачка старых загрузок продолжается как ни в чём не бывало.
        let task: URLSessionDownloadTask
        if let resumeData {
            task = primarySession.downloadTask(withResumeData: resumeData)
            ModelStorage.clearResumeData(for: model)
        } else {
            var request = URLRequest(url: model.downloadURL)
            request.setValue("PocketAgent/1.0", forHTTPHeaderField: "User-Agent")
            task = primarySession.downloadTask(with: request)
        }
        task.taskDescription = Self.wholeFileTag + model.id
        // Подсказка системе о размере — помогает планировщику фоновых загрузок.
        task.countOfBytesClientExpectsToReceive = model.byteSize
        task.resume()

        lock.withLock {
            self.sourceNoteText = "качаю \(ModelSourceCatalog.official.humanName)"
            // Обычная загрузка — это один поток и никаких кусков.
            self.beginRunLocked(lanes: 1, chunkMegabytes: 0)
        }
    }

    // MARK: Загрузка кусками

    /// - Parameters:
    ///   - resolved: прямой адрес сети доставки, если замер успел его добыть.
    ///     Живёт только в памяти — в план на диск идёт обычный адрес.
    ///   - choiceNote: почему выбрали именно этот источник, человеческими словами.
    private func startMultipartDownload(_ model: ModelDescriptor,
                                        source: ModelSource,
                                        resolved: ResolvedSourceURL? = nil,
                                        choiceNote: String? = nil) {
        guard let url = source.url(for: model) else {
            startClassicDownload(model, resumeData: nil)
            return
        }

        let fresh = ModelDownloadPlan(modelID: model.id,
                                      fileName: model.fileName,
                                      totalBytes: model.byteSize,
                                      chunkBytes: Self.chunkBytes,
                                      sourceID: source.id,
                                      sourceName: source.humanName,
                                      isOfficialSource: source.isOfficial,
                                      urlString: url.absoluteString,
                                      doneChunks: [])

        // Мелкий файл дробить незачем — обычная загрузка проще и надёжнее.
        guard fresh.chunkCount > 1 else {
            startClassicDownload(model, resumeData: nil)
            return
        }

        // Начинаем с чистого листа: остатки прошлой сборки нам не родня.
        ModelDownloadPlanStore.clear(modelID: model.id)
        ModelDownloadPlanStore.save(fresh)

        lock.withLock {
            self.plan = fresh
            self.chunkWritten.removeAll()
            self.chunkAttempts.removeAll()
            self.lastSpaceCheckBytes = 0
            self.sourceNoteText = Self.note(for: fresh, choice: choiceNote)
            self.directLink = resolved.map {
                DirectLink(modelID: fresh.modelID, sourceID: source.id, resolved: $0)
            }
            self.sourceChecksLeft = Self.maxSourceChecks
            self.lastSourceCheckAt = Date()
            self.lastSpeedSampleAt = nil
            self.lastSpeedSampleBytes = 0
            self.lastRecentBytesPerSecond = 0
            self.bestRecentBytesPerSecond = 0
        }
        // Прямого адреса ещё нет (замер не успел) — идём за ним сразу: первые куски
        // поедут по обычному адресу, а дальше уже без лишнего перенаправления.
        if resolved == nil { refreshDirectLink(for: fresh) }
        fillLanes()
    }

    /// Взять в работу план, найденный на диске (продолжение после перезапуска).
    private func adoptPlan(_ plan: ModelDownloadPlan) {
        let progress = plan.totalBytes > 0
            ? min(1.0, Double(plan.doneBytes) / Double(plan.totalBytes))
            : 0
        lock.withLock {
            self.plan = plan
            self.chunkAttempts.removeAll()
            self.sourceNoteText = Self.note(for: plan)
            self.sourceChecksLeft = Self.maxSourceChecks
            self.lastSourceCheckAt = Date()
            self.lastSpeedSampleAt = nil
            self.lastSpeedSampleBytes = 0
            self.lastRecentBytesPerSecond = 0
            self.bestRecentBytesPerSecond = 0
        }
        // Продолжение прерванной загрузки: прямой адрес в плане не хранится (подпись
        // протухает), поэтому берём его заново — иначе весь остаток файла снова платил
        // бы за перенаправление на каждом куске.
        refreshDirectLink(for: plan)
        reportProgress(progress)
    }

    /// Занять свободные дорожки следующими кусками.
    ///
    /// ⚠️ Что сейчас качается, спрашиваем У САМОЙ СЕССИИ, а не у своей памяти: после
    /// перезапуска приложения задачи живут в системе, а наша память пуста. Иначе
    /// один и тот же кусок качался бы дважды.
    private func fillLanes() {
        downloadTasksByLane { [weak self] lanes in
            guard let self else { return }
            guard let plan = self.lock.withLock({ self.plan }) else { return }
            // ⚠️ ПОКА ИДЁТ ПЕРЕЕЗД НА ДРУГОЙ ИСТОЧНИК — НОВЫХ КУСКОВ НЕ РАЗДАЁМ. Иначе
            // они уйдут на старый адрес, который прямо сейчас и отказывает, и на каждый
            // отказ мы будем заводить следующий такой же. Переезд занимает секунды,
            // а сторож всё равно вернётся сюда через свой тик — загрузка не встанет.
            guard !self.lock.withLock({ self.isSwitchingSource }) else { return }
            let laneCount = Self.laneCount

            // Живые задачи по номеру куска: у одного куска их может быть две — это догон.
            var liveTasks: [Int: [URLSessionDownloadTask]] = [:]
            // Сколько кусков уже качает каждая дорожка.
            var busy = [Int](repeating: 0, count: laneCount)
            var runningCount = 0

            for (position, tasks) in lanes.enumerated() {
                for task in tasks where task.state == .running || task.state == .suspended {
                    guard let index = Self.chunkIndex(of: task) else { continue }
                    // ⚠️ Кусок ЧУЖОЙ модели — сирота от прошлой, отменённой сборки.
                    // Раньше мы считали его своим: он занимал дорожку, держал «свой»
                    // номер куска незанятым и в довершение всего дописывал чужие байты
                    // в наш собираемый файл. Такие снимаем сразу.
                    guard Self.chunkModelID(of: task) == plan.modelID else {
                        task.cancel()
                        continue
                    }
                    liveTasks[index, default: []].append(task)
                    runningCount += 1
                    // Позиция 0 — главная сессия. Куска там быть не должно, но он мог
                    // остаться от прошлой версии приложения: место в общем счёте занимает,
                    // а дорожкой не считается.
                    let lane = position - 1
                    if lane >= 0, lane < laneCount { busy[lane] += 1 }
                    if task.state == .suspended { task.resume() }
                }
            }

            let live = Set(liveTasks.keys)
            let pending = plan.pendingChunks().filter { !live.contains($0) }
            if live.isEmpty, pending.isEmpty {
                self.finalizeAssembledFile()
                return
            }

            // ⚠️ ЗДЕСЬ ЖИЛА ТИХАЯ ПОТЕРЯ СКОРОСТИ. Раньше дорожка выбиралась по НОМЕРУ
            // куска (номер поделить на три). Пока куски приходили строго по очереди,
            // это совпадало с «каждому свою дорожку». Но приходят они вразнобой — и тогда
            // два, а то и три куска садились на одну дорожку, то есть в одно соединение,
            // где идут друг за другом, а не разом. Теперь дорожку выбираем по занятости:
            // сначала пустые, потом наименее загруженные.
            var free = laneCount - runningCount
            for index in pending {
                guard free > 0, let lane = Self.leastBusyLane(busy) else { break }
                busy[lane] += 1
                self.startChunk(index: index, plan: plan, lane: lane)
                free -= 1
            }

            // ДОГОН ОТСТАВШЕГО. Куски кончились, а дорожки освободились — значит, весь
            // хвост файла тянет один поток, пока остальные смотрят. Ставим тот же кусок
            // второй раз на свободную дорожку и берём то, что доедет первым; опоздавшую
            // задачу снимаем. Лишнего трафика тут не больше одного куска на дорожку,
            // и только в самом конце загрузки.
            guard free > 0 else { return }
            let laggards = liveTasks
                .filter { $0.value.count == 1 }
                .sorted { $0.value[0].countOfBytesReceived < $1.value[0].countOfBytesReceived }
            for (index, _) in laggards {
                guard free > 0, let lane = Self.leastBusyLane(busy) else { break }
                busy[lane] += 1
                self.startChunk(index: index, plan: plan, lane: lane)
                free -= 1
            }
        }
    }

    /// Самая свободная дорожка. nil — дорожек нет вовсе (такого быть не должно).
    private static func leastBusyLane(_ busy: [Int]) -> Int? {
        busy.indices.min(by: { busy[$0] < busy[$1] })
    }

    private func startChunk(index: Int, plan: ModelDownloadPlan, lane: Int) {
        guard let url = chunkURL(for: plan) else {
            lock.withLock {
                self.pendingFailure = .generationFailed("Не удалось разобрать адрес загрузки.")
            }
            stopAllChunks()
            return
        }

        var request = URLRequest(url: url)
        request.setValue("PocketAgent/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(plan.rangeHeader(for: index), forHTTPHeaderField: "Range")

        // Своя сессия на дорожку — это и есть отдельное соединение, ради которого
        // всё затевалось (см. пояснение у sessionIdentifiers).
        //
        // ⚠️ СЕССИЮ НЕ ПЕРЕСОЗДАЁМ НИКОГДА — она заводится один раз на весь запуск
        // приложения. Поэтому соединение с сервером живёт между кусками: следующий
        // кусок уходит по уже открытому и прогретому каналу, без нового рукопожатия.
        let task = session(forLane: lane).downloadTask(with: request)
        // ⚠️ Метку ставим ДО resume: именно по ней мы узнаём кусок после того, как
        // система закроет и заново запустит приложение.
        task.taskDescription = Self.chunkTag + "\(plan.modelID)|\(index)"
        task.countOfBytesClientExpectsToReceive = plan.length(of: index)
        // Размер куска берём ИЗ ПЛАНА, а не из настройки: план мог начаться, когда
        // настройка была другой, и куски у него до конца останутся прежними.
        let chunkMegabytes = max(1, Int(plan.chunkBytes / (1024 * 1024)))
        lock.withLock {
            self.chunkTouchedAt[index] = Date()
            self.beginRunLocked(lanes: Self.laneCount, chunkMegabytes: chunkMegabytes)
        }
        task.resume()
        startWatchdog()
    }

    // MARK: Прямой адрес сети доставки

    /// По какому адресу просить кусок.
    ///
    /// ⚠️ ЗАЧЕМ ЗДЕСЬ ВООБЩЕ ВЫБОР. Обычный адрес официального сайта — это не файл,
    /// а перенаправление на сеть доставки, и платит за него КАЖДЫЙ кусок: живой замер
    /// 10.08.2026 дал 2,59 секунды до первого байта против 1,39 напрямую, у зеркала
    /// 5,05 против 1,90. На сотне кусков это минуты чистого ожидания. Прямой адрес
    /// берётся один раз и годится на все куски.
    ///
    /// Ссылки нет или она вот-вот протухнет — берём обычный адрес (загрузка не должна
    /// ждать) и тут же идём за новой ссылкой: она пригодится следующему куску.
    private func chunkURL(for plan: ModelDownloadPlan) -> URL? {
        let now = Date()
        let direct = lock.withLock { () -> URL? in
            guard let link = self.directLink,
                  link.modelID == plan.modelID,
                  link.sourceID == plan.sourceID,
                  link.resolved.isFresh(at: now) else { return nil }
            return link.resolved.url
        }
        if let direct { return direct }
        refreshDirectLink(for: plan)
        return URL(string: plan.urlString)
    }

    /// Сходить за прямым адресом. Ничего не ждём: ответ ляжет в память и достанется
    /// следующему куску.
    private func refreshDirectLink(for plan: ModelDownloadPlan) {
        let model = lock.withLock { self.currentModel }
        guard let model, model.id == plan.modelID,
              let source = ModelSourceCatalog.source(withID: plan.sourceID) else { return }

        let mayGo = lock.withLock { () -> Bool in
            guard !self.isResolvingLink else { return false }
            self.isResolvingLink = true
            return true
        }
        guard mayGo else { return }

        Task { [weak self] in
            let fresh = await ModelSourceProbe.resolve(source,
                                                       model: model,
                                                       allowsCellular: Self.allowsCellularAccess)
            guard let self else { return }
            let took = self.lock.withLock { () -> Bool in
                self.isResolvingLink = false
                guard let fresh else { return false }
                // План мог за это время переехать на другой источник — тогда ссылка
                // уже не наша, и подставлять её никуда нельзя.
                guard let live = self.plan,
                      live.modelID == plan.modelID,
                      live.sourceID == plan.sourceID else { return false }
                self.directLink = DirectLink(modelID: plan.modelID,
                                             sourceID: plan.sourceID,
                                             resolved: fresh)
                return fresh.url.absoluteString != plan.urlString
            }
            // ⚠️ ОДНА СТРОКА В ЖУРНАЛ — ЭТО ЕДИНСТВЕННЫЙ СПОСОБ ПРОВЕРИТЬ ФАКТОМ, что
            // куски пошли напрямую. Журнал владелец умеет присылать с телефона, а по
            // экрану отличить прямой адрес от обычного нельзя никак.
            if took {
                EngineJournal.shared.record(.note,
                    "Взял прямой адрес — куски пойдут без лишнего перенаправления")
            }
        }
    }

    /// Забыть прямую ссылку и сразу пойти за новой (её подпись протухла).
    private func forgetDirectLink() {
        let plan = lock.withLock { () -> ModelDownloadPlan? in
            self.directLink = nil
            return self.plan
        }
        guard let plan else { return }
        refreshDirectLink(for: plan)
    }

    // MARK: - Сторож: загрузка обязана двигаться

    /// Включить сторожа. Он смотрит раз в несколько секунд, живы ли куски, снимает
    /// повисшие и добирает пустые дорожки.
    ///
    /// ⚠️ ЗАЧЕМ ОН НУЖЕН, ХОТЯ ВСЁ И ТАК СОБЫТИЙНОЕ. Раньше следующий кусок начинался
    /// ТОЛЬКО в ответ на завершение предыдущего. Одно потерянное событие — и раздавать
    /// куски становилось некому: у владельца загрузка так и встала на 68 из 76 и стояла
    /// часами. Сторож делает цепочку неразрывной: даже если не придёт ни одного события,
    /// свободные дорожки всё равно получат работу.
    ///
    /// ⚠️ Пока приложение спит, сторож не тикает — код спящего приложения не выполняется
    /// вовсе. Зато он срабатывает сразу, как человек открыл приложение: вместо «стоит
    /// часами» получается «дёрнулось и поехало за несколько секунд».
    private func startWatchdog() {
        let needsStart = lock.withLock { () -> Bool in
            guard self.watchdog == nil else { return false }
            let timer = DispatchSource.makeTimerSource(queue: self.watchdogQueue)
            self.watchdog = timer
            return true
        }
        guard needsStart, let timer = lock.withLock({ self.watchdog }) else { return }
        timer.schedule(deadline: .now() + Self.watchdogTickSeconds,
                       repeating: Self.watchdogTickSeconds)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
    }

    private func stopWatchdog() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            let value = self.watchdog
            self.watchdog = nil
            return value
        }
        timer?.cancel()
    }

    private func watchdogTick() {
        // Сторож нужен, только пока человек ждёт файл и пока есть что собирать.
        let alive = lock.withLock { () -> Bool in
            self.plan != nil && !self.waiters.isEmpty && !self.isStopping
        }
        guard alive else {
            stopWatchdog()
            return
        }

        // Заодно смотрим, не сдал ли источник: это тот же вопрос «загрузка двигается?»,
        // только не про одну задачу, а про весь адрес целиком.
        considerFasterSource()

        downloadTasksByLane { [weak self] lanes in
            guard let self else { return }
            let now = Date()
            var running = 0
            var stalled: [(Int, URLSessionDownloadTask)] = []

            for tasks in lanes {
                for task in tasks where task.state == .running || task.state == .suspended {
                    guard let index = Self.chunkIndex(of: task) else { continue }
                    running += 1
                    // ⚠️ Про задачу, пережившую перезапуск приложения, мы ничего не знаем:
                    // в памяти её отметки нет. Заводим отсчёт прямо сейчас, иначе такая
                    // задача считалась бы вечно живой — и именно она подвешивала бы всё.
                    let touched = self.lock.withLock { () -> Date in
                        if let value = self.chunkTouchedAt[index] { return value }
                        self.chunkTouchedAt[index] = now
                        return now
                    }
                    if now.timeIntervalSince(touched) > Self.chunkStallSeconds {
                        stalled.append((index, task))
                    }
                }
            }

            for (index, task) in stalled {
                EngineJournal.shared.record(.note,
                    "Кусок \(index) молчит больше минуты — снимаю и беру заново")
                // Снимаем задачу: обрыв разберёт обычный путь и сам возьмёт кусок снова.
                self.lock.withLock { self.chunkTouchedAt[index] = now }
                task.cancel()
            }

            if running < Self.laneCount { self.fillLanes() }
        }
    }

    /// Снять все куски. Собранное на диске остаётся — «Продолжить» подхватит его.
    private func stopAllChunks() {
        lock.withLock { self.isStopping = true }
        allDownloadTasks { [weak self] downloads in
            guard let self else { return }
            let chunks = downloads.filter { Self.chunkIndex(of: $0) != nil }
            guard !chunks.isEmpty else {
                // Снимать нечего — иначе ожидание повисло бы навсегда.
                let reason = self.lock.withLock { self.pendingFailure } ?? PocketAgentError.downloadStopped
                self.finishAll(with: .failure(reason))
                return
            }
            chunks.forEach { $0.cancel() }
        }
    }

    /// Сервер не понял просьбу «отдай кусок» — уходим на обычную одну загрузку.
    private func fallBackToSingleStream() {
        let model = lock.withLock { self.currentModel }
        // План убираем первым — тогда отмены кусков придут «в никуда».
        lock.withLock {
            self.plan = nil
            self.chunkWritten.removeAll()
            self.chunkAttempts.removeAll()
            self.lastSpaceCheckBytes = 0
            // Прямая ссылка была нужна только кускам — обычная загрузка идёт по своему
            // адресу, и держать чужую подпись в памяти незачем.
            self.directLink = nil
        }
        if let model {
            ModelDownloadPlanStore.clear(modelID: model.id)
        }
        allDownloadTasks { [weak self] downloads in
            guard let self else { return }
            for task in downloads where Self.chunkIndex(of: task) != nil {
                task.cancel()
            }
            guard let model else {
                self.finishAll(with: .failure(PocketAgentError.modelFileMissing))
                return
            }
            self.startClassicDownload(model, resumeData: nil)
        }
    }

    /// Переехать на другой источник, сохранив всё, что уже собрано.
    ///
    /// ⚠️ ДОРОГА В ОБЕ СТОРОНЫ, И ЭТО ГЛАВНОЕ ЗДЕСЬ. Раньше уходили только с зеркала
    /// на официальный сайт. Значит, если тормозил или отказывал именно официальный сайт
    /// (а из России это обычное дело), человек досиживал на нём до конца, хотя живое
    /// зеркало было рядом. Теперь уходим в любую сторону.
    ///
    /// Скачанное не теряется: границы кусков считаются от начала файла и от источника
    /// не зависят, меняется только адрес, откуда брать оставшиеся.
    @discardableResult
    private func applySwitch(to measurement: ModelSourceMeasurement,
                             model: ModelDescriptor) -> Bool {
        guard measurement.supportsRanges,
              Self.sizeAgrees(measurement, model: model),
              Self.mayUse(measurement.source, for: model),
              let canonical = measurement.source.url(for: model),
              let current = lock.withLock({ self.plan }),
              current.sourceID != measurement.source.id else { return false }

        // ⚠️ В ПЛАН НА ДИСК — ОБЫЧНЫЙ АДРЕС. Подписанная ссылка живёт час, а файл едет
        // дольше: сохрани мы её, продолжение загрузки упёрлось бы в отказ.
        let moved = current.switchingSource(to: measurement.source,
                                            urlString: canonical.absoluteString)
        ModelDownloadPlanStore.save(moved)
        lock.withLock {
            self.plan = moved
            self.chunkAttempts.removeAll()
            self.sourceNoteText = Self.note(for: moved, choice: measurement.choiceNote)
            self.directLink = measurement.resolved.map {
                DirectLink(modelID: moved.modelID, sourceID: measurement.source.id, resolved: $0)
            }
            self.lastSourceCheckAt = Date()
            // На новом источнике скорость считаем с чистого листа: старое «лучшее»
            // относилось к другому серверу и сравнивать с ним нечестно.
            self.lastSpeedSampleAt = nil
            self.lastSpeedSampleBytes = 0
            self.lastRecentBytesPerSecond = 0
            self.bestRecentBytesPerSecond = 0
        }
        EngineJournal.shared.record(.note, "Меняю источник загрузки — теперь \(moved.sourceName)")
        fillLanes()
        return true
    }

    /// Нынешний источник не отдаёт кусок совсем. Пробуем уехать на другой.
    ///
    /// Возвращает true, если переезд начат: тогда ошибку человеку показывать рано —
    /// загрузка продолжится с другого адреса. false — ехать некуда.
    private func beginSourceSwitchAfterFailure(reason: PocketAgentError) -> Bool {
        let snapshot = lock.withLock { () -> (ModelDownloadPlan?, ModelDescriptor?, Set<String>, Bool) in
            (self.plan, self.currentModel, self.blockedSources, self.isSwitchingSource)
        }
        guard let plan = snapshot.0, let model = snapshot.1 else { return false }
        // Переезд уже идёт — второй заводить незачем, а хоронить загрузку тем более.
        if snapshot.3 { return true }
        guard let current = ModelSourceCatalog.source(withID: plan.sourceID) else { return false }

        var blocked = snapshot.2
        blocked.insert(current.id)
        guard !ModelSourceCatalog.alternatives(to: current, for: model, blocked: blocked).isEmpty else {
            return false
        }

        lock.withLock {
            self.isSwitchingSource = true
            // Этот источник кусок не отдал — больше его в этот заход не берём.
            self.blockedSources.insert(current.id)
        }

        let allowsCellular = Self.allowsCellularAccess
        Task { [weak self] in
            let found = await ModelSourceProbe.betterAlternative(than: current,
                                                                 beating: 0,
                                                                 for: model,
                                                                 allowsCellular: allowsCellular,
                                                                 blocked: blocked)
            guard let self else { return }
            self.lock.withLock { self.isSwitchingSource = false }
            if let found, self.applySwitch(to: found, model: model) { return }
            // Ехать оказалось некуда — говорим человеку правду, как и раньше.
            self.lock.withLock { self.pendingFailure = reason }
            self.stopAllChunks()
        }
        return true
    }

    /// Не пора ли уехать на источник побыстрее — по живой скорости, а не по ошибкам.
    ///
    /// Зовётся сторожем. Смотрим редко и только в первых двух третях файла: переезд
    /// в конце уже не окупится, а лишний повод для обрыва создаст.
    private func considerFasterSource() {
        let now = Date()
        let live = sampleLiveSpeed(at: now)

        let ready = lock.withLock { () -> (ModelDownloadPlan, ModelDescriptor, Set<String>)? in
            guard !self.isSwitchingSource, self.sourceChecksLeft > 0,
                  let plan = self.plan, let model = self.currentModel,
                  plan.totalBytes > 0 else { return nil }
            // Осталась треть файла или меньше — не трогаем.
            guard Double(plan.doneBytes) < Double(plan.totalBytes) * Self.sourceRecheckUntilFraction else {
                return nil
            }
            if let last = self.lastSourceCheckAt,
               now.timeIntervalSince(last) < Self.sourceRecheckSeconds { return nil }
            // Скорость должна ПРОСЕСТЬ. Идёт как шла — трогать нечего.
            guard self.bestRecentBytesPerSecond > 0,
                  live < self.bestRecentBytesPerSecond * Self.sourceSagFraction else { return nil }
            self.lastSourceCheckAt = now
            self.sourceChecksLeft -= 1
            self.isSwitchingSource = true
            return (plan, model, self.blockedSources)
        }
        guard let ready else { return }
        guard let current = ModelSourceCatalog.source(withID: ready.0.sourceID) else {
            lock.withLock { self.isSwitchingSource = false }
            return
        }

        let allowsCellular = Self.allowsCellularAccess
        Task { [weak self] in
            let found = await ModelSourceProbe.betterAlternative(than: current,
                                                                 beating: live,
                                                                 for: ready.1,
                                                                 allowsCellular: allowsCellular,
                                                                 blocked: ready.2)
            guard let self else { return }
            self.lock.withLock { self.isSwitchingSource = false }
            guard let found else { return }
            self.applySwitch(to: found, model: ready.1)
        }
    }

    /// Сколько байт в секунду реально приезжает ПРЯМО СЕЙЧАС — за последний тик сторожа.
    ///
    /// ⚠️ Считаем по свежему отрезку, а не за весь заход: средняя за час не покажет,
    /// что источник сдал пять минут назад. Лучшее за заход при этом медленно оседает —
    /// иначе одна удачная минута навсегда сделала бы всё остальное «просадкой».
    private func sampleLiveSpeed(at now: Date) -> Double {
        return lock.withLock { () -> Double in
            let arrived = self.runArrivedBytes
            guard let since = self.lastSpeedSampleAt else {
                self.lastSpeedSampleAt = now
                self.lastSpeedSampleBytes = arrived
                return 0
            }
            let seconds = now.timeIntervalSince(since)
            guard seconds >= 1 else { return self.lastRecentBytesPerSecond }
            let value = Double(max(0, arrived - self.lastSpeedSampleBytes)) / seconds
            self.lastSpeedSampleAt = now
            self.lastSpeedSampleBytes = arrived
            self.lastRecentBytesPerSecond = value
            self.bestRecentBytesPerSecond = max(value, self.bestRecentBytesPerSecond * 0.9)
            return value
        }
    }

    /// Сложить готовый файл из собранного и отдать его наверх.
    private func finalizeAssembledFile() {
        let snapshot = lock.withLock { () -> (ModelDownloadPlan?, ModelDescriptor?) in
            (self.plan, self.currentModel)
        }
        guard let plan = snapshot.0, let model = snapshot.1, plan.isComplete else { return }

        do {
            let partial = try ModelDownloadPlanStore.partialURL(for: plan.modelID)
            let size = ModelStorage.byteSize(of: partial)
            guard size == plan.totalBytes else {
                throw PocketAgentError.modelFileCorrupted
            }

            // ⚠️ ЧУЖОЙ СЕРВЕР — ТОЛЬКО ПОСЛЕ ПОЛНОЙ СВЕРКИ СУММЫ. Не сошлась — файл
            // удаляем, зеркало больше не используем и говорим человеку правду.
            // (Файл с официального адреса сверяет подготовка модели сразу после загрузки —
            // считать 2,6 ГБ дважды незачем.)
            if !plan.isOfficialSource {
                guard !model.sha256.isEmpty else { throw PocketAgentError.modelFileCorrupted }
                let hex = try ModelVerifier.checksum(partial, expectedBytes: size)
                if hex.caseInsensitiveCompare(model.sha256) != .orderedSame {
                    try? FileManager.default.removeItem(at: partial)
                    ModelDownloadPlanStore.clear(modelID: plan.modelID)
                    lock.withLock {
                        self.blockedSources.insert(plan.sourceID)
                        self.plan = nil
                        self.chunkWritten.removeAll()
                        self.chunkAttempts.removeAll()
                        self.sourceNoteText = ""
                    }
                    finishAll(with: .failure(PocketAgentError.generationFailed(
                        "Файл, скачанный \(plan.sourceName), отличается от эталонного — я его "
                        + "удалил и больше этим источником не пользуюсь. Нажмите «Продолжить»: "
                        + "скачаю заново с Hugging Face."
                    )))
                    return
                }
            }

            let destination = try ModelStorage.fileURL(for: model)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            try? ModelStorage.excludeFromBackup(destination)
            ModelDownloadPlanStore.clear(modelID: plan.modelID)
            ModelStorage.clearResumeData(for: model)

            rememberRunSpeed(of: model)
            lock.withLock {
                self.plan = nil
                self.chunkWritten.removeAll()
                self.chunkAttempts.removeAll()
            }
            reportProgress(1.0)
            finishAll(with: .success(destination))
        } catch {
            finishAll(with: .failure(
                PocketAgentError.writeFailed(path: model.fileName,
                                             reason: SystemErrorText.russian(for: error))
            ))
        }
    }

    // MARK: Метки задач

    /// Начало метки куска: «chunk|<модель>|<номер>».
    private static let chunkTag = "chunk|"
    /// Начало метки обычной загрузки целого файла.
    private static let wholeFileTag = "whole|"

    /// Номер куска, если это задача куска. nil — обычная загрузка целого файла.
    private static func chunkIndex(of task: URLSessionTask) -> Int? {
        guard let parts = chunkTagParts(of: task) else { return nil }
        return Int(parts[2])
    }

    /// Какой модели принадлежит кусок.
    private static func chunkModelID(of task: URLSessionTask) -> String? {
        guard let parts = chunkTagParts(of: task) else { return nil }
        return String(parts[1])
    }

    private static func chunkTagParts(of task: URLSessionTask) -> [Substring]? {
        guard let text = task.taskDescription, text.hasPrefix(chunkTag) else { return nil }
        let parts = text.split(separator: "|")
        guard parts.count == 3 else { return nil }
        return parts
    }

    /// Честная строка про источник — человеческими словами, без техники.
    ///
    /// - Parameter choice: почему выбрали именно его («вдвое быстрее зеркала»).
    ///   Есть что сказать — говорим это вместо общего «так быстрее»: человеку полезнее
    ///   знать, что выбор не случайный. Нечего — строка ровно та же, что была.
    private static func note(for plan: ModelDownloadPlan, choice: String? = nil) -> String {
        let word = HumanFormat.plural(laneCount, "поток", "потока", "потоков")
        if let choice, !choice.isEmpty {
            return "качаю \(plan.sourceName) в \(laneCount) \(word) — \(choice)"
        }
        if plan.isOfficialSource {
            return "качаю \(plan.sourceName) сразу в \(laneCount) \(word) — так быстрее"
        }
        return "качаю \(plan.sourceName) в \(laneCount) \(word) — файл потом сверю с эталоном"
    }

    // MARK: - Завершение

    private func finishAll(with result: Result<URL, Error>) {
        stopWatchdog()
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        progressHandlers.removeAll()
        finishedFileResult = nil
        // Заход кончился — следующий начнёт свой отсчёт скорости с нуля. Но если идёт
        // папка-модель, её файлы качаются по очереди, и здесь заканчивается только ОДИН
        // из них: складываем его в общий счёт папки, иначе итог покажет цифру последнего
        // мелкого описания вместо всей модели.
        if folderRunStartedAt != nil {
            folderArrivedBytes += runArrivedBytes
            folderActiveSeconds += runActiveSeconds
        }
        runStartedAt = nil
        runArrivedBytes = 0
        runActiveSeconds = 0
        runLastByteAt = nil
        chunkTouchedAt.removeAll()
        // Прямая ссылка живёт только в памяти и только на время загрузки.
        directLink = nil
        lastSourceCheckAt = nil
        sourceChecksLeft = 0
        lastSpeedSampleAt = nil
        lastSpeedSampleBytes = 0
        lastRecentBytesPerSecond = 0
        bestRecentBytesPerSecond = 0
        // ⚠️ Флаг обязан сниматься здесь тоже: иначе после отмены «до старта»
        // повторный запуск считает, что загрузка уже идёт, и не начинает её.
        isStarting = false
        pendingFailure = nil
        lastSpaceCheckBytes = 0
        lock.unlock()

        for continuation in pending {
            continuation.resume(with: result)
        }
    }

    // MARK: - Замер скорости: «стало быстрее» надо доказывать, а не заявлять

    /// Сколько байт прилетело из сети за нынешний заход и с какой скоростью.
    ///
    /// ⚠️ СЧИТАЕМ ТОЛЬКО ТО, ЧТО РЕАЛЬНО ПРИЛЕТЕЛО СЕЙЧАС. Уже лежавшее на диске
    /// (докачка, собранные раньше куски) в счёт не идёт — иначе продолжение загрузки
    /// показывало бы сказочные цифры и любое сравнение «было → стало» теряло смысл.
    public var speedNow: ModelDownloadSpeed? {
        lock.withLock { self.runSpeedLocked() }
    }

    /// Разрыв больше этого считаем простоем: пауза, потеря связи, сон телефона.
    /// Такие промежутки во время загрузки не засчитываются.
    private static let idleGapSeconds: Double = 5

    private func runSpeedLocked() -> ModelDownloadSpeed? {
        guard runStartedAt != nil, runArrivedBytes > 0 else { return nil }
        var seconds = runActiveSeconds
        // Хвост: время от последнего байта до «сейчас», но только если байты идут
        // прямо сейчас, а не кончились час назад.
        if let last = runLastByteAt {
            let gap = Date().timeIntervalSince(last)
            if gap > 0, gap <= Self.idleGapSeconds { seconds += gap }
        }
        guard seconds > 0.5 else { return nil }
        return ModelDownloadSpeed(arrivedBytes: runArrivedBytes,
                                  seconds: seconds,
                                  lanes: runLanes,
                                  chunkMegabytes: runChunkMegabytes,
                                  diskBytesPerSecond: ModelDownloadPlanStore.writeSpeedBytesPerSecond)
    }

    /// Начать отсчёт нового захода. Настройки запоминаем СРАЗУ: сменит человек число
    /// потоков посреди работы — замер всё равно расскажет про то, как качалось на самом деле.
    private func beginRunLocked(lanes: Int, chunkMegabytes: Int) {
        guard runStartedAt == nil else { return }
        runStartedAt = Date()
        runArrivedBytes = 0
        runActiveSeconds = 0
        runLastByteAt = nil
        runLanes = lanes
        runChunkMegabytes = chunkMegabytes
    }

    /// Прилетели байты: копим объём и чистое время.
    private func noteArrivedLocked(_ bytes: Int64) {
        guard bytes > 0 else { return }
        runArrivedBytes += bytes
        let now = Date()
        if let last = runLastByteAt {
            let gap = now.timeIntervalSince(last)
            if gap > 0, gap <= Self.idleGapSeconds { runActiveSeconds += gap }
        }
        runLastByteAt = now
    }

    /// Итог ПРОШЛОЙ доехавшей загрузки одной строкой — то, что можно показать человеку
    /// и с чем сравнивать следующий замер. Живёт между запусками приложения.
    public static var lastRunLine: String? {
        get { UserDefaults.standard.string(forKey: lastRunKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastRunKey) }
    }

    private static let lastRunKey = "download.lastRunLine"

    /// Записать итог удавшейся загрузки: и в память приложения, и в журнал движка —
    /// журнал владелец умеет присылать с телефона, и по нему цифры можно проверить.
    private func rememberRunSpeed(of model: ModelDescriptor) {
        // ⚠️ ИДЁТ ПАПКА-МОДЕЛЬ — МОЛЧИМ. Её файлы качаются по очереди, и сюда попадает
        // каждый из них по отдельности. Раньше «Прошлая загрузка» из-за этого показывала
        // «41 МБ за 6 с» под именем модели на 5 ГБ: цифра последнего мелкого описания.
        // Итог по всей папке пишет `rememberFolderRunSpeed`.
        guard lock.withLock({ self.folderRunStartedAt }) == nil else { return }
        guard let speed = speedNow else { return }
        remember(speed, of: model)
    }

    /// Итог по ВСЕЙ папке-модели: сложенные байты и чистое время всех её файлов.
    private func rememberFolderRunSpeed(of model: ModelDescriptor) {
        let snapshot = lock.withLock { () -> (Int64, Double, Int, Int) in
            (self.folderArrivedBytes, self.folderActiveSeconds,
             self.folderLanes, self.folderChunkMegabytes)
        }
        guard snapshot.0 > 0, snapshot.1 > 0.5 else { return }
        remember(ModelDownloadSpeed(arrivedBytes: snapshot.0,
                                    seconds: snapshot.1,
                                    lanes: snapshot.2,
                                    chunkMegabytes: snapshot.3,
                                    diskBytesPerSecond: ModelDownloadPlanStore.writeSpeedBytesPerSecond),
                 of: model)
    }

    private func remember(_ speed: ModelDownloadSpeed, of model: ModelDescriptor) {
        let line = "\(model.displayName): \(speed.humanLine)"
        Self.lastRunLine = line
        EngineJournal.shared.record(.note, "Загрузка доехала — \(line)")
    }

    // MARK: - Место на диске по ходу загрузки

    /// Проверяет свободное место примерно раз в 64 МБ скачанного.
    ///
    /// ⚠️ ЗАЧЕМ. Раньше место проверялось ОДИН раз, перед стартом. Если оно кончалось
    /// на середине (человек параллельно снимает фото, система качает обновление),
    /// загрузка падала на системной ошибке, недокачанные гигабайты оставались занимать
    /// место, а повторная попытка упиралась в «не хватает места» — и убрать мусор
    /// из приложения было нечем. Теперь останавливаемся заранее, сохраняем точку докачки
    /// и честно говорим, сколько осталось свободного места.
    private func checkFreeSpace(written: Int64, total: Int64, task: URLSessionDownloadTask) {
        guard shouldCheckSpace(written: written) else { return }
        guard let free = missingSpace(written: written, total: total) else { return }

        let model = lock.withLock { () -> ModelDescriptor? in
            pendingFailure = .diskSpaceRanOutWhileDownloading(freeBytes: free)
            return currentModel
        }

        task.cancel(byProducingResumeData: { data in
            if let data, let model {
                ModelStorage.saveResumeData(data, for: model)
            }
        })
    }

    /// То же самое для сборки из кусков: там точку докачки хранит план, поэтому
    /// достаточно снять живые куски.
    private func checkFreeSpaceForChunks(written: Int64, total: Int64) {
        guard shouldCheckSpace(written: written) else { return }
        guard let free = missingSpace(written: written, total: total) else { return }
        lock.withLock {
            self.pendingFailure = .diskSpaceRanOutWhileDownloading(freeBytes: free)
        }
        stopAllChunks()
    }

    private func shouldCheckSpace(written: Int64) -> Bool {
        return lock.withLock { () -> Bool in
            guard written - self.lastSpaceCheckBytes >= Self.spaceCheckStepBytes else { return false }
            self.lastSpaceCheckBytes = written
            return true
        }
    }

    /// Сколько свободно, если места уже не хватает. nil — всё в порядке
    /// (или узнать не получилось: пугать человека выдуманной цифрой не будем).
    private func missingSpace(written: Int64, total: Int64) -> Int64? {
        let remaining = max(0, total - written)
        let free = ModelStorage.availableBytes()
        guard free > 0, free < remaining + Self.spaceReserveBytes else { return nil }
        return free
    }

    private func reportProgress(_ value: Double) {
        lock.lock()
        lastProgress = value
        let handlers = Array(progressHandlers.values)
        lock.unlock()

        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            handlers.forEach { $0(value) }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloader: URLSessionDownloadDelegate {

    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {

        if let index = Self.chunkIndex(of: downloadTask) {

            // ⚠️ РАННЯЯ ПРОВЕРКА, И ОНА ВАЖНЕЕ, ЧЕМ КАЖЕТСЯ. Сервер может пропустить
            // просьбу «отдай только кусок» мимо ушей и начать отдавать файл целиком.
            // Если ждать конца загрузки, чтобы это заметить, в телефон приедут лишние
            // гигабайты по мобильной сети — по одному лишнему файлу на каждый поток.
            // Обещанный размер виден на первых килобайтах: он обязан совпасть с длиной
            // куска. Не совпал — сворачиваем многопоточность и качаем как раньше.
            let promisedTooMuch = lock.withLock { () -> Bool in
                guard totalBytesExpectedToWrite > 0, let plan = self.plan else { return false }
                return totalBytesExpectedToWrite > plan.length(of: index) + 1024
            }
            if promisedTooMuch {
                fallBackToSingleStream()
                return
            }

            let snapshot = lock.withLock { () -> (Double, Int64, Int64)? in
                // Кусок жив — сторожу это и надо знать.
                self.chunkTouchedAt[index] = Date()
                self.noteArrivedLocked(bytesWritten)
                // ⚠️ Берём БОЛЬШЕЕ, а не последнее: на догоне один и тот же кусок тянут
                // две задачи, и та, что начала позже, иначе «откатывала» бы полосу назад.
                self.chunkWritten[index] = max(self.chunkWritten[index] ?? 0, totalBytesWritten)
                guard let plan = self.plan, plan.totalBytes > 0 else { return nil }
                var live: Int64 = 0
                for value in self.chunkWritten.values { live += value }
                let done = min(plan.totalBytes, plan.doneBytes + live)
                return (Double(done) / Double(plan.totalBytes), done, plan.totalBytes)
            }
            guard let snapshot else { return }
            reportProgress(min(1.0, snapshot.0))
            checkFreeSpaceForChunks(written: snapshot.1, total: snapshot.2)
            return
        }

        lock.withLock { self.noteArrivedLocked(bytesWritten) }
        let expected = lock.withLock { currentModel?.byteSize } ?? ModelSpec.expectedBytes
        // CDN после редиректа может не прислать длину — тогда берём известный размер.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        guard total > 0 else { return }
        reportProgress(min(1.0, Double(totalBytesWritten) / Double(total)))
        checkFreeSpace(written: totalBytesWritten, total: total, task: downloadTask)
    }

    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {

        if let index = Self.chunkIndex(of: downloadTask) {
            handleChunkFinished(index: index, task: downloadTask, location: location)
            return
        }

        // Ответ мог оказаться страницей ошибки, а не файлом.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            lock.withLock {
                finishedFileResult = .failure(
                    PocketAgentError.generationFailed("Сервер ответил кодом \(http.statusCode).")
                )
            }
            return
        }

        let model = lock.withLock { currentModel } ?? ModelSpec.descriptor

        // ⚠️ ПОСЛЕДНЯЯ ЗАЩИТА ОТ ПОДМЕНЫ ЦЕЛОГО ФАЙЛА КУСКОМ. Сюда попадает всё, что
        // мы не узнали как кусок. Если метка задачи почему-то потерялась (система
        // пересоздала задачу, пока приложение было закрыто), кусок в 32 МБ лёг бы
        // на место модели, и человек получил бы «повреждённый файл» вместо загрузки.
        // Сверка размера это ловит: файл не того размера мы просто не принимаем.
        //
        // ⚠️ ПО КОДУ ОТВЕТА ЭТО ПРОВЕРЯТЬ НЕЛЬЗЯ. Докачка с точки обрыва — тоже просьба
        // «отдай кусок», и сервер отвечает на неё кодом 206. Отсекать 206 здесь значило бы
        // сломать докачку начисто: каждая продолженная загрузка объявлялась бы порчей.
        let arrived = ModelStorage.byteSize(of: location)
        if model.byteSize > 0, arrived > 0, arrived != model.byteSize {
            lock.withLock {
                finishedFileResult = .failure(PocketAgentError.modelFileCorrupted)
            }
            return
        }

        do {
            let destination = try ModelStorage.fileURL(for: model)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            // Файл живёт только до выхода из этого метода — переносим синхронно.
            try FileManager.default.moveItem(at: location, to: destination)
            try? ModelStorage.excludeFromBackup(destination)
            ModelStorage.clearResumeData(for: model)

            rememberRunSpeed(of: model)
            lock.withLock { finishedFileResult = .success(destination) }
        } catch {
            // Записать не вышло — почти всегда это кончившееся место.
            // Точку докачки в этом случае держать смысла нет: файл уже скачан целиком.
            ModelStorage.clearResumeData(for: model)
            lock.withLock {
                finishedFileResult = .failure(
                    PocketAgentError.writeFailed(path: model.fileName,
                                                 reason: SystemErrorText.russian(for: error))
                )
            }
        }
    }

    /// Сервер перенаправляет нас на свою сеть доставки — это происходит с каждым куском.
    ///
    /// ⚠️ ЗАЧЕМ МЫ ВООБЩЕ В ЭТО ЛЕЗЕМ. При перенаправлении система собирает новый запрос,
    /// и просьба «отдай только этот кусок» может в нём не сохраниться. Тогда с той стороны
    /// поедет ВЕСЬ файл — на каждый из трёх кусков по целому файлу, по мобильной сети.
    /// Поэтому просьбу возвращаем на место, если её потеряли. Если она уцелела —
    /// не трогаем ничего.
    ///
    /// ⚠️ Обычную загрузку целого файла здесь не трогаем НИ ПРИ КАКИХ УСЛОВИЯХ: докачка
    /// с точки обрыва подставляет свою собственную просьбу о куске, и вмешаться в неё —
    /// значит сломать докачку.
    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {

        guard let index = Self.chunkIndex(of: task),
              request.value(forHTTPHeaderField: "Range") == nil,
              let plan = livePlan(for: task) else {
            completionHandler(request)
            return
        }
        var restored = request
        restored.setValue(plan.rangeHeader(for: index), forHTTPHeaderField: "Range")
        completionHandler(restored)
    }

    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           didCompleteWithError error: Error?) {

        if let index = Self.chunkIndex(of: task) {
            handleChunkCompleted(index: index, task: task, error: error)
            return
        }

        if let error = error as NSError? {
            // Сохраняем точку обрыва, чтобы не качать всё заново.
            if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               let model = lock.withLock({ currentModel }) {
                ModelStorage.saveResumeData(resumeData, for: model)
            }

            if error.code == NSURLErrorCancelled {
                // Задачу сняли мы сами — назовём человеку настоящую причину
                // («кончилось место»), а не общее «загрузка остановлена».
                let reason = lock.withLock { pendingFailure } ?? PocketAgentError.downloadStopped
                finishAll(with: .failure(reason))
            } else {
                // Системный текст ошибки приходит на языке ТЕЛЕФОНА — наружу его не пускаем.
                finishAll(with: .failure(
                    PocketAgentError.generationFailed(SystemErrorText.russian(for: error))
                ))
            }
            return
        }

        let result = lock.withLock { finishedFileResult }
        finishAll(with: result ?? .failure(PocketAgentError.modelFileMissing))
    }

    /// Все фоновые события этой сессии доставлены — можно отпускать систему.
    ///
    /// ⚠️ Обработчик у каждой сессии СВОЙ: система будит приложение ради конкретной
    /// сессии и ждёт ответа именно по ней. Позвать чужой обработчик — значит оставить
    /// свой невызванным, а за это система считает приложение зависшим.
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? Self.sessionIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let handler = self.lock.withLock { () -> (() -> Void)? in
                self.backgroundHandlers.removeValue(forKey: identifier)
            }
            handler?()
        }
    }
}

// MARK: - Куски: приход и обрыв

private extension ModelDownloader {

    /// План, к которому относится этот кусок.
    ///
    /// ⚠️ ЗДЕСЬ ЖИЛА БЫ ПОТЕРЯ ЦЕЛОГО КУСКА. Система умеет закрыть приложение и поднять
    /// его заново ровно в тот миг, когда кусок докачался. В новом запуске память пуста:
    /// плана в ней нет, и кусок молча улетел бы в мусор, а загрузка топталась бы на месте.
    /// Поэтому, если в памяти плана нет, читаем его с диска по метке самой задачи —
    /// и заодно вспоминаем, какую модель качали.
    ///
    /// nil — плана нет и на диске, то есть многопоточную загрузку мы уже свернули сами
    /// (человек отменил, файл собран, ушли на обычную загрузку). Такие поздние отклики
    /// надо просто пропустить.
    func livePlan(for task: URLSessionTask) -> ModelDownloadPlan? {
        if let live = lock.withLock({ self.plan }) { return live }

        guard let modelID = Self.chunkModelID(of: task),
              let saved = ModelDownloadPlanStore.load(modelID: modelID) else { return nil }

        let model = ModelCatalog.model(withID: modelID)
        lock.withLock {
            self.plan = saved
            if self.currentModel == nil { self.currentModel = model }
            self.sourceNoteText = Self.note(for: saved)
        }
        return saved
    }

    /// Кусок доехал: проверяем, записываем в собираемый файл, берём следующий.
    func handleChunkFinished(index: Int, task: URLSessionDownloadTask, location: URL) {
        guard let plan = livePlan(for: task) else { return }
        // Кусок от другой модели — не наш; собирать по нему нельзя ни в коем случае.
        guard Self.chunkModelID(of: task) == plan.modelID else { return }
        // Этот кусок уже собран: значит, это опоздавший двойник с догона. Просто уходим —
        // временный файл система уберёт сама.
        guard !plan.doneChunks.contains(index) else { return }

        if let http = task.response as? HTTPURLResponse {
            if http.statusCode == 200 {
                // Сервер не понял просьбу «отдай кусок» и шлёт файл целиком.
                // Многопоточность отменяем и качаем как раньше — одной задачей.
                fallBackToSingleStream()
                return
            }
            // ⚠️ 401 И 403 — ЭТО ПРОТУХШАЯ ПОДПИСЬ, А НЕ СМЕРТЬ ИСТОЧНИКА. Прямая ссылка
            // на сеть доставки живёт около часа, а файл на 2 ГБ по слабой связи едет
            // дольше. Раньше такой ответ ронял всю загрузку с ошибкой «сервер ответил
            // кодом 403» — теперь берём ссылку заново и повторяем этот же кусок.
            if http.statusCode == 401 || http.statusCode == 403 {
                forgetDirectLink()
                // Кусок остался несобранным: общий путь возьмёт его заново, уже по
                // свежему адресу. Попытку считаем, чтобы не крутиться вечно, если
                // источник отказывает по-настоящему.
                if registerChunkAttempt(index: index) { return }

                let reason = PocketAgentError.generationFailed(
                    "Больше не получается качать \(plan.sourceName) — попробуйте позже."
                )
                if beginSourceSwitchAfterFailure(reason: reason) { return }
                lock.withLock { self.pendingFailure = reason }
                stopAllChunks()
                return
            }

            guard http.statusCode == 206 else {
                lock.withLock {
                    self.pendingFailure = .generationFailed("Сервер ответил кодом \(http.statusCode).")
                }
                stopAllChunks()
                return
            }
        }

        // Кусок пришёл не той длины — принимать такое нельзя, файл собрался бы кривым.
        let arrived = ModelStorage.byteSize(of: location)
        guard arrived == plan.length(of: index) else {
            if !registerChunkAttempt(index: index) {
                lock.withLock {
                    self.pendingFailure = .generationFailed(
                        "Сервер отдаёт файл кусками не той длины — собрать модель из них нельзя."
                    )
                }
                stopAllChunks()
            }
            // Кусок остался несобранным: следующая дорожка возьмёт его заново.
            return
        }

        do {
            // ⚠️ ЧИТАЕМ ПРЯМО ИЗ ВРЕМЕННОГО ФАЙЛА СИСТЕМЫ, БЕЗ ПЕРЕКЛАДЫВАНИЯ. Раньше
            // кусок сначала переносился в нашу папку, и только потом писался в собираемый
            // файл. Перенос между разными хранилищами — это не переименование, а ПОЛНАЯ
            // копия: каждый кусок проходил через диск лишний раз. Читать его здесь
            // безопасно: временный файл живёт до выхода из этого метода, а пишем мы
            // синхронно.
            let partial = try ModelDownloadPlanStore.partialURL(for: plan.modelID)
            try ModelDownloadPlanStore.write(chunkAt: location,
                                             into: partial,
                                             offset: plan.offset(of: index))

            let updated = lock.withLock { () -> ModelDownloadPlan? in
                guard var value = self.plan else { return nil }
                value.markDone(index)
                self.plan = value
                self.chunkWritten.removeValue(forKey: index)
                self.chunkTouchedAt.removeValue(forKey: index)
                // Кусок доехал — прошлые неудачи по нему больше не в счёт.
                self.chunkAttempts.removeValue(forKey: index)
                return value
            }
            guard let updated else { return }
            ModelDownloadPlanStore.save(updated)
            // Двойник с догона теперь только зря жжёт трафик — снимаем его.
            cancelTwins(ofChunk: index, keeping: task)

            if updated.totalBytes > 0 {
                reportProgress(min(1.0, Double(updated.doneBytes) / Double(updated.totalBytes)))
            }
            if updated.isComplete {
                finalizeAssembledFile()
            }
        } catch {
            lock.withLock {
                self.pendingFailure = .writeFailed(path: plan.fileName,
                                                   reason: SystemErrorText.russian(for: error))
            }
            stopAllChunks()
        }
    }

    /// Снять другие задачи того же куска — тех самых двойников, которых ставит догон.
    func cancelTwins(ofChunk index: Int, keeping winner: URLSessionTask) {
        allDownloadTasks { tasks in
            for task in tasks where Self.chunkIndex(of: task) == index {
                guard task !== winner else { continue }
                task.cancel()
            }
        }
    }

    /// Задача куска закончилась — успехом или обрывом.
    func handleChunkCompleted(index: Int, task: URLSessionTask, error: Error?) {
        lock.withLock { _ = self.chunkWritten.removeValue(forKey: index) }

        // Плана нет ни в памяти, ни на диске — значит, многопоточную загрузку мы уже
        // свернули сами. Такие отклики не событие, а эхо.
        guard let plan = livePlan(for: task) else { return }

        // Кусок уже собран (это опоздавший двойник с догона или снятый нами двойник) —
        // неудачей это считать нельзя, просто берём следующую работу.
        if plan.doneChunks.contains(index) {
            fillLanes()
            return
        }

        if lock.withLock({ self.isStopping }) {
            let reason = lock.withLock { self.pendingFailure } ?? PocketAgentError.downloadStopped
            finishAll(with: .failure(reason))
            return
        }

        guard let error = error as NSError? else {
            // Успех уже разобран выше — просто берём следующий кусок.
            fillLanes()
            return
        }

        // Обрыв или отказ сервера: пробуем этот кусок ещё раз, уже собранное цело.
        if registerChunkAttempt(index: index) {
            fillLanes()
            return
        }

        // Кусок не даётся совсем. Уходим на другой источник, сохраняя собранное, —
        // в любую сторону: и с зеркала на официальный сайт, и с официального сайта
        // на зеркало. Ехать некуда — честно говорим человеку, что связь оборвалась.
        //
        // ⚠️ ОСТАЛЬНЫЕ КУСКИ ПРИ ЭТОМ ТОЖЕ СНИМАЕМ, И ЭТО НЕ МЕЛОЧЬ. Раньше мы просто
        // отвечали человеку ошибкой, а две другие дорожки продолжали качать в пустоту:
        // полосы на экране уже нет, отменить их нечем, трафик идёт. Собранное на диске
        // цело, «Продолжить» подхватит его.
        let reason: PocketAgentError = error.code == NSURLErrorCancelled
            ? .downloadStopped
            : .generationFailed(SystemErrorText.russian(for: error))
        if beginSourceSwitchAfterFailure(reason: reason) { return }
        lock.withLock { self.pendingFailure = reason }
        stopAllChunks()
    }

    /// Засчитать попытку. false — попытки кончились.
    func registerChunkAttempt(index: Int) -> Bool {
        return lock.withLock { () -> Bool in
            let value = (self.chunkAttempts[index] ?? 0) + 1
            self.chunkAttempts[index] = value
            return value < Self.maxChunkAttempts
        }
    }
}
