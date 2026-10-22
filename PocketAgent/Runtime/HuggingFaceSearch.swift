//
//  HuggingFaceSearch.swift
//  PocketAgent / Runtime
//
//  Поиск моделей прямо в приложении по открытому справочнику Hugging Face.
//
//  ⚠️ ЧТО ОТСЮДА УХОДИТ НАРУЖУ: только то, что человек напечатал в строке поиска,
//  и ничего больше. Ни файлов, ни задач, ни разговоров, ни опознавателя телефона —
//  это чтение чужого открытого справочника, а не отправка наших данных.
//  Вход и токен не нужны: всё, что мы просим, отдаётся всем (проверено живыми
//  запросами 09.08.2026).
//
//  ⚠️ ПОИСК ИДЁТ В ДВА ЗАХОДА, И ВТОРОЙ — НЕ ПРИХОТЬ. Справочник ищет по НАЧАЛУ слова:
//  на «gemma» он не отдаёт ни одной сборки «supergemma», хотя буквы те же и стоят рядом.
//  Из-за этого владелец не смог найти свою модель ВООБЩЕ. Поэтому, когда слова справочника
//  кончаются, мы перебираем имена сами и оставляем те, где напечатанное встречается любым
//  куском. Подробности и живые числа — у `HubScanPhase`.
//
//  Два обращения на одну модель, и оба дешёвые:
//   1) список — что вообще нашлось по словам человека, сколько у модели скачиваний
//      и закрыт ли репозиторий согласием с лицензией;
//   2) перечень файлов на закреплённой версии — с ТОЧНЫМИ размерами и контрольными
//      суммами, БЕЗ скачивания самих файлов.
//
//  ⚠️ Версия репозитория берётся из ответа и закрепляется в ссылке на скачивание.
//  Без этого «main» уехал бы под приложением, и проверенная контрольная сумма
//  перестала бы сходиться с файлом.
//
//  ⚠️ Частоту запросов беречь: для тех, кто без входа, у Hugging Face свои пределы.
//  Поэтому поиск ждёт, пока человек допечатает, а не дёргается на каждую букву
//  (задержку держит экран поиска).
//

import Foundation

// MARK: - Что нам отдаёт справочник

/// Один файл внутри репозитория модели.
public struct HubFile: Sendable, Equatable {

    /// Путь внутри репозитория («Bonsai-27B-Q1_0.gguf» или «весы/model.safetensors»).
    public let path: String
    /// Точный размер в байтах.
    public let byteSize: Int64
    /// Контрольная сумма sha256 из хранилища больших файлов.
    /// Пусто — сумму не дали (обычно у мелких файлов, которые нам и не нужны).
    public let sha256: String
    /// Сколько файлов свёрнуто в эту строку. 1 — обычный файл.
    /// Больше — набор из нескольких файлов, посчитанный вместе (так устроен MLX).
    public let partCount: Int

    /// Из чего состоит набор, если это модель-папка (MLX). Пусто — обычный один файл.
    ///
    /// ⚠️ ЗАЧЕМ ХРАНИТЬ ВЕСЬ СПИСОК, А НЕ ТОЛЬКО ЧИСЛО ФАЙЛОВ. Скачать папку — значит
    /// скачать каждый её файл по отдельности, и список нужен ровно для этого: без него
    /// пришлось бы идти к справочнику ВТОРОЙ раз, уже после нажатия «Скачать», и человек
    /// ждал бы у неподвижной полосы. Один запрос за состав уже сделан — грех его терять.
    public let parts: [HubFile]

    /// Это модель-папка: скачивать надо весь набор целиком.
    public var isFolder: Bool { !parts.isEmpty }

    public init(path: String,
                byteSize: Int64,
                sha256: String,
                partCount: Int = 1,
                parts: [HubFile] = []) {
        self.path = path
        self.byteSize = byteSize
        self.sha256 = sha256
        self.partCount = partCount
        self.parts = parts
    }

    /// Имя файла без папок — его человек и увидит.
    public var fileName: String {
        (path as NSString).lastPathComponent
    }
}

/// Одна модель из справочника.
public struct HubRepo: Sendable, Equatable, Identifiable {

    /// Опознаватель вида «prism-ml/Bonsai-27B-gguf». Он же адрес страницы.
    public let id: String
    /// Закреплённая версия репозитория — та, для которой посчитаны размеры и суммы.
    public let commit: String
    public let downloads: Int
    public let likes: Int
    /// Когда репозиторий последний раз меняли. nil — справочник даты не дал.
    /// Нужна ровно затем, чтобы человек видел, свежая находка или ей два года.
    public let lastModified: Date?
    /// Репозиторий закрыт: сначала надо принять условия на сайте.
    /// ⚠️ Видно ЗАРАНЕЕ — можно честно погасить кнопку, а не ловить отказ после нажатия.
    public let isGated: Bool
    /// Устройство модели («qwen3_5_mtp») — техническое слово ТОЛЬКО для проверки
    /// «запустит ли движок». Человеку оно не показывается нигде.
    ///
    /// ⚠️ ПРИХОДИТ ВМЕСТЕ СО СПИСКОМ И НЕ СТОИТ НИ ОДНОГО ЛИШНЕГО ЗАПРОСА —
    /// подробности у `listURL`. nil — справочник его не дал; тогда проверять
    /// придётся отдельно, по описанию модели (`MLXArchitectures.verdict(forRepo:)`).
    public let modelType: String?
    /// Файлы нужного вида, от лёгких к тяжёлым.
    public let files: [HubFile]
    /// Для чего модель по словам справочника: «text-to-image», «text-generation».
    /// nil — не сказал.
    public let pipelineTag: String?

    public init(id: String,
                commit: String,
                downloads: Int,
                likes: Int,
                lastModified: Date? = nil,
                isGated: Bool,
                modelType: String? = nil,
                files: [HubFile],
                pipelineTag: String? = nil) {
        self.pipelineTag = pipelineTag
        self.id = id
        self.commit = commit
        self.downloads = downloads
        self.likes = likes
        self.lastModified = lastModified
        self.isGated = isGated
        self.modelType = modelType
        self.files = files
    }

    /// Кто выложил.
    public var author: String {
        guard let slash = id.firstIndex(of: "/") else { return "" }
        return String(id[id.startIndex..<slash])
    }

    /// Имя самой модели, без имени выложившего.
    public var name: String {
        guard let slash = id.firstIndex(of: "/") else { return id }
        return String(id[id.index(after: slash)...])
    }

    public var pageURL: URL? {
        URL(string: "https://huggingface.co/\(id)")
    }
}

/// Что именно ищем. Совпадает с отбором по виду файла на самом Hugging Face.
public enum HubFormatFilter: String, Sendable, Equatable, CaseIterable {
    case litertlm = "litert-lm"
    case gguf = "gguf"
    case mlx = "mlx"

    /// Какой вид файлов забирать из репозитория.
    public var fileFormat: ModelFileFormat {
        switch self {
        case .litertlm: return .litertlm
        case .gguf:     return .gguf
        case .mlx:      return .mlx
        }
    }
}

/// Раздел: отбор не по виду файла, а по сути модели.
///
/// ⚠️ ЧИСЛА НИЖЕ СНЯТЫ ЖИВЫМ ЗАПРОСОМ 10.08.2026 по всему формату `litert-lm`
/// (246 моделей) и приведены затем, чтобы следующий не гадал, много ли там всего.
///
/// ⚠️ И ГЛАВНОЕ ПРО ЧЕСТНОСТЬ ОТБОРА. Ни «сила» модели, ни наличие цензуры в коротком
/// ответе справочника не записаны — там есть только имя репозитория и имя выложившего.
/// Значит, отбираем по приметам, а не по существу, и человеку об этом говорим прямо
/// на экране. Прикидываться, что мы измерили силу модели, нельзя.
public enum HubSection: String, Sendable, Equatable, CaseIterable {

    /// Всё подряд.
    case all
    /// Свежее из основного канала: там первыми появляются новые семейства.
    /// 68 из 246 — 66 у `litert-community` и 2 у `google`.
    case frontier
    /// Чужие самоделки: всё, что выложил не основной канал. 178 из 246.
    case experimental
    /// Сборки со снятыми ограничениями. 6 из 246.
    case uncensored
    /// Маленькие модели, обученные повторять ответы больших. 5 из 246.
    case distills

    /// Кто считается основным каналом.
    /// ⚠️ `litert-community` — канал команды самого движка, `google` — авторы Gemma.
    /// Всё остальное на Hugging Face выкладывают обычные люди.
    private static let coreAuthors: Set<String> = ["litert-community", "google"]

    /// Приметы снятых ограничений в названии.
    /// ⚠️ Слова взяты не с потолка: именно так помечают такие сборки сами выкладывающие.
    /// `abliterated` — не опечатка, это устоявшееся название приёма.
    private static let uncensoredWords = [
        "uncensored", "abliterated", "unaligned", "unfiltered", "dolphin", "heretic", "nsfw"
    ]

    /// Слово, которое имеет смысл подмешать в строку поиска, чтобы справочник отсеял
    /// лишнее ещё на своей стороне. nil — такого слова нет, отбираем сами.
    var searchWord: String? {
        // ⚠️ Только для дистиллятов: у них одно общее слово, и справочник по нему
        // отбирает точно. У «без цензуры» слов сразу семь, а искать сразу по нескольким
        // справочник не умеет — по одному слову мы бы потеряли остальные шесть.
        self == .distills ? "distill" : nil
    }

    /// Сколько ИМЁН просить у справочника за раз — не путать с числом показанных строк.
    ///
    /// ⚠️ Для разделов просим сразу сотню, и это НЕ расточительство. Сотня имён стоит
    /// ОДИН дешёвый запрос, а дорогое — поход за размерами файлов — делается только
    /// для тех, кто прошёл отбор и попал на экран; лишние отобранные не пропадают,
    /// а ждут своей очереди в закладке. Просить по двадцать значило бы заставить
    /// человека нажимать «Показать ещё» тринадцать раз ради шести моделей
    /// «без цензуры», раскиданных по всему справочнику.
    func scanBatch(pageLimit: Int) -> Int {
        // Без отбора просим ровно столько, сколько покажем: перебирать нечего.
        needsOwnFilter ? 100 : pageLimit
    }

    /// Подходит ли модель под этот раздел.
    func matches(repoID: String) -> Bool {
        let lower = repoID.lowercased()
        let author = String(lower.split(separator: "/").first ?? "")
        switch self {
        case .all:
            return true
        case .frontier:
            return Self.coreAuthors.contains(author)
        case .experimental:
            return !Self.coreAuthors.contains(author)
        case .uncensored:
            return Self.uncensoredWords.contains { lower.contains($0) }
        case .distills:
            // ⚠️ «distil» с одной «л» ловит и `Distill`, и `Distilled`, и `Distil`.
            return lower.contains("distil")
        }
    }

    /// Нужно ли перебирать список самим. Для «всего подряд» — нет, и лишней работы не будет.
    var needsOwnFilter: Bool { self != .all }
}

/// В каком порядке справочник отдаёт список.
///
/// ⚠️ ЗНАЧЕНИЯ ПРОВЕРЕНЫ ЖИВЫМ ЗАПРОСОМ 09.08.2026, И ПРИДУМЫВАТЬ СВОИ НЕЛЬЗЯ.
/// Справочник принимает ровно `downloads`, `likes`, `trendingScore`, `lastModified`
/// и `createdAt`; на любое другое слово (пробовали `popularity`) он отвечает отказом 400,
/// и список не приходит ВООБЩЕ — то есть опечатка здесь гасит весь экран, а не портит
/// порядок строк.
///
/// ⚠️ Порядок всегда «сверху лучшее» (`direction=-1`). Обратного порядка человеку никто
/// не заказывал, а лишний переключатель на экране — это ещё один способ запутаться.
public enum HubSortOrder: String, Sendable, Equatable, CaseIterable {

    /// Что обсуждают прямо сейчас.
    case trending
    /// Что людям больше всего понравилось за всё время.
    case likes
    /// Что чаще всего скачивают.
    case downloads
    /// Что выложили или обновили последним.
    case fresh

    /// Слово, которое понимает справочник.
    var apiValue: String {
        switch self {
        case .trending:  return "trendingScore"
        case .likes:     return "likes"
        case .downloads: return "downloads"
        case .fresh:     return "lastModified"
        }
    }
}

/// Одна страница списка.
///
/// ⚠️ ЗАЧЕМ СТРАНИЦЫ, А НЕ ВЕСЬ СПИСОК СРАЗУ. Справочник отдаёт список кусками и
/// приделывает к ответу готовый адрес следующего куска (заголовок `Link … rel="next"`).
/// В формате `litert-lm` таких моделей 245 (проверено живым запросом 10.08.2026,
/// листанием по этому же адресу). Тянуть все 245 в одном заходе нельзя: на каждую
/// модель идёт ещё один запрос за размерами её файлов — телефон и чужой сервер этого
/// не заслужили. Поэтому берём по странице и даём человеку долистать.
public struct HubPage: Sendable {

    public let repos: [HubRepo]
    /// С чего продолжить. nil — дальше ничего нет, список кончился.
    public let next: HubCursor?

    public init(repos: [HubRepo], next: HubCursor?) {
        self.repos = repos
        self.next = next
    }
}

/// Где именно мы сейчас ищем — и это ДВА РАЗНЫХ ЗАХОДА, а не один.
///
/// ⚠️⚠️ ЗАЧЕМ ВТОРОЙ ЗАХОД. ЖИВОЙ ПРОМАХ, ИЗ-ЗА КОТОРОГО ОН И ПОЯВИЛСЯ (10.08.2026).
/// Владелец искал модель `typomonster/supergemma4-e4b-abliterated-litert-lm` и не нашёл
/// её вовсе. Причина не в нас и не в отборе: **справочник Hugging Face ищет по НАЧАЛУ
/// слова, а не по любому его куску**. Проверено живыми запросами по всему виду `litert-lm`:
///   • «supergemma» → 2 модели, нужная среди них;
///   • «super»      → те же 2, нужная есть (это начало слова);
///   • «gemma»      → 100 моделей, и ни одной с «supergemma» в имени.
/// То есть человек, напечатавший самое естественное слово «gemma», НИКОГДА не увидит
/// ни одной сборки «supergemma» — она молча выпадает из списка, и приложение об этом
/// даже не заикается.
///
/// Поэтому после того, как слова справочника кончились, мы делаем свой заход: перебираем
/// имена этого вида файлов и оставляем те, где напечатанное встречается ЛЮБЫМ куском.
/// Заход дешёвый и ограниченный — только имена, по сотне за запрос, и не больше
/// `maxScansPerPage` запросов на нажатие.
fileprivate enum HubScanPhase: Sendable {

    /// Спрашиваем справочник его же словами (быстро, но только по началу слова).
    case words(URL?)
    /// Перебираем имена сами и сверяем ЧАСТЬ слова.
    case parts(URL?)
}

/// Закладка «мы остановились здесь». Снаружи в неё заглядывать не нужно и нельзя:
/// её просто возвращают обратно, чтобы получить продолжение.
///
/// ⚠️ ВНУТРИ НЕ ТОЛЬКО АДРЕС, НО И НЕДОКАЗАННЫЙ ОСТАТОК, и это не усложнение ради
/// красоты. В разделах мы отбираем строки сами, уже после ответа справочника, и
/// сотня присланных имён превращается то в пятьдесят подходящих, то в четыре.
/// Показать все пятьдесят разом нельзя — за каждой пойдёт отдельный запрос
/// за размерами файлов. Обрезать лишние тоже нельзя: адрес продолжения указывает
/// на СЛЕДУЮЩУЮ сотню, и обрезанные пропали бы навсегда — то самое молчаливое
/// исчезновение моделей, с которого всё и началось. Поэтому остаток едет с закладкой
/// и показывается первым же следующим нажатием.
public struct HubCursor: Sendable {

    /// Какой заход идёт и на каком он адресе.
    ///
    /// ⚠️ Храним готовый адрес целиком, а не одну метку внутри него. В этом адресе уже
    /// сидят и вид файлов, и порядок, и слова поиска; собирать его заново по кусочкам —
    /// это ровно тот случай, когда одна забытая часть тихо меняет список под человеком.
    fileprivate let phase: HubScanPhase
    /// Отобранные, но ещё не показанные — их черёд наступит следующим нажатием.
    fileprivate let carried: [HuggingFaceSearch.SearchItem]
    /// Кого человек уже видел в этом поиске.
    ///
    /// ⚠️ Без этого списка второй заход показал бы по второму разу всё, что уже приехало
    /// первым: он идёт по ВСЕМУ виду файлов и обязательно наткнётся на прежние находки.
    fileprivate let shownIDs: Set<String>
}

/// Почему поиск не получился — сразу человеческими словами.
public enum HubSearchError: Error, LocalizedError, Equatable {

    /// Интернета нет вовсе.
    case noInternet
    /// Справочник ответил отказом.
    case refused(Int)
    /// Ответ пришёл, но разобрать его не вышло.
    case badAnswer

    public var errorDescription: String? {
        switch self {
        case .noInternet:
            return "Нет интернета — поиск моделей без него не работает. "
                + "Модель, которая уже лежит на телефоне, работает и без сети."
        case .refused(let code):
            if code == 429 {
                return "Справочник моделей просит подождать — слишком много запросов подряд. "
                    + "Попробуйте через минуту."
            }
            return "Справочник моделей сейчас не отвечает. Попробуйте позже."
        case .badAnswer:
            return "Справочник ответил непонятно — прочитать список не получилось."
        }
    }
}

// MARK: - Сам поиск

public enum HuggingFaceSearch {

    /// Сколько моделей приносим за ОДИН заход. Не «сколько их всего» — остальные
    /// человек долистывает кнопкой, список больше не обрывается молча.
    ///
    /// ⚠️ Двадцать, а не сто: на каждую строку идёт отдельный запрос за размерами её
    /// файлов, и сотня строк — это сотня обращений на одно нажатие.
    public static let resultLimit = 20

    /// Сколько запросов за файлами держим в воздухе одновременно.
    ///
    /// ⚠️ Без этого предела страница из двадцати моделей била бы по чужому серверу
    /// двадцатью одновременными запросами, и он вправе ответить «слишком часто».
    /// Шесть — заметно быстрее, чем по одному, и никого не злит.
    private static let parallelTreeRequests = 6

    /// Сколько раз за ОДНО нажатие разрешаем сходить к справочнику за именами.
    ///
    /// ⚠️ Предел нужен потому, что в узком разделе подходящих может не быть вовсе:
    /// без него одно нажатие перелистало бы весь справочник до конца. Пять обращений
    /// по сотне имён — это пятьсот просмотренных моделей за нажатие, больше, чем есть
    /// во всём нашем виде файлов (246 на 10.08.2026). Не набралось — человек увидит
    /// честное «показано столько-то» и кнопку, чтобы продолжить.
    private static let maxScansPerPage = 5

    /// Сколько имён просим за раз во ВТОРОМ заходе — том, где часть слова сверяем сами.
    ///
    /// ⚠️ Сотня, и это не жадность: сверка идёт по одному имени, размеры файлов при этом
    /// не запрашиваются вовсе. Пять таких запросов — пятьсот просмотренных имён за нажатие,
    /// то есть весь вид `litert-lm` целиком (246 моделей на 10.08.2026) и с запасом.
    private static let partScanBatch = 100

    /// Сколько файлов показываем внутри одной модели. У наборов GGUF их бывают десятки
    /// (одна и та же модель, сжатая по-разному) — весь список только мешает выбрать.
    public static let filesPerRepoLimit = 8

    /// Своя сессия: без кэша и без печенья.
    /// ⚠️ Общий `URLSession.shared` тут не годится — он живёт вместе с загрузкой модели,
    /// а нам нужны короткие запросы с быстрым отказом.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    /// Найти модели по словам человека — одной страницей.
    /// Пустая строка — не ошибка: тогда покажем весь список в выбранном порядке.
    ///
    /// - Parameters:
    ///   - sort: в каком порядке спрашивать список;
    ///   - limit: сколько строк просить за один заход. Каждая строка — это ещё одно
    ///     обращение за размерами файлов, поэтому на экране, где список идёт довеском,
    ///     их берут меньше, чем на самом поиске;
    ///   - section: раздел — отбор по сути модели, а не по виду файла;
    ///   - after: закладка с прошлого раза. nil — начинаем список сначала.
    public static func searchPage(query: String,
                                  format: HubFormatFilter,
                                  sort: HubSortOrder = .downloads,
                                  limit: Int = resultLimit,
                                  section: HubSection = .all,
                                  after cursor: HubCursor? = nil) async throws -> HubPage {

        let rows = max(1, limit)
        // Напечатанное в нижнем регистре — им же во втором заходе сверяем часть имени.
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var carried = cursor?.carried ?? []
        var shownIDs = cursor?.shownIDs ?? []
        var phase = try cursor?.phase
            ?? .words(listURL(query: query,
                              format: format,
                              sort: sort,
                              limit: section.scanBatch(pageLimit: rows),
                              section: section))
        var scans = 0

        // Набираем ровно на одну страницу показа. Отбор режет сотню имён то до
        // пятидесяти, то до четырёх, поэтому за одним нажатием иногда стоит несколько
        // обращений к справочнику — но они дешёвые, а дорогие походы за размерами
        // файлов идут только по тем, кого человек сейчас увидит.
        scan: while carried.count < rows, scans < maxScansPerPage {
            switch phase {
            case .words(let url):
                guard let url else {
                    // Слова справочника кончились. Дальше — наш перебор по ЧАСТИ имени,
                    // и только если человек что-то напечатал: на пустой строке справочник
                    // и так отдаёт всё подряд, второй заход показал бы то же самое.
                    guard !needle.isEmpty else { break scan }
                    phase = .parts(try listURL(query: "",
                                               format: format,
                                               sort: sort,
                                               limit: partScanBatch,
                                               section: .all))
                    continue scan
                }
                scans += 1
                let answer = try await listPage(url)
                collect(answer.items,
                        into: &carried,
                        shownIDs: &shownIDs,
                        section: section,
                        needle: nil)
                phase = .words(answer.nextURL)

            case .parts(let url):
                guard let url else { break scan }
                scans += 1
                let answer = try await listPage(url)
                collect(answer.items,
                        into: &carried,
                        shownIDs: &shownIDs,
                        section: section,
                        needle: needle)
                phase = .parts(answer.nextURL)
            }
        }

        let shown = Array(carried.prefix(rows))
        // ⚠️ Остаток НЕ выбрасываем: адрес продолжения указывает уже на следующую сотню,
        // и обрезанные здесь модели исчезли бы из списка навсегда.
        let rest = Array(carried.dropFirst(rows))
        let repos = await withFiles(shown, format: format)

        return HubPage(repos: repos,
                       next: hasMore(phase: phase, rest: rest, needle: needle)
                           ? HubCursor(phase: phase, carried: rest, shownIDs: shownIDs)
                           : nil)
    }

    /// Сложить в набранное всё, что прошло отбор, и запомнить, что человек это уже видел.
    ///
    /// - Parameter needle: часть имени, которую надо найти. nil — сверять не нужно
    ///   (первый заход: там отбирал сам справочник).
    private static func collect(_ items: [SearchItem],
                                into carried: inout [SearchItem],
                                shownIDs: inout Set<String>,
                                section: HubSection,
                                needle: String?) {
        for item in items {
            // ⚠️ Второй заход идёт по ВСЕМУ виду файлов и обязательно наткнётся на то,
            // что уже приехало первым списком. Без этой проверки те же модели приехали бы
            // по второму разу — человек читает это как поломку.
            guard !shownIDs.contains(item.id) else { continue }
            if let needle, !needle.isEmpty, !item.id.lowercased().contains(needle) { continue }
            guard !section.needsOwnFilter || section.matches(repoID: item.id) else { continue }
            shownIDs.insert(item.id)
            carried.append(item)
        }
    }

    /// Есть ли что показать дальше — от этого зависит, будет ли внизу кнопка «Показать ещё».
    ///
    /// ⚠️ Пустые слова справочника ЕЩЁ НЕ КОНЕЦ СПИСКА, если человек что-то напечатал:
    /// впереди второй заход по части имени. Ответь мы здесь «это всё» — и владелец снова
    /// не увидел бы свою модель, ровно как в промахе, ради которого второй заход и сделан.
    private static func hasMore(phase: HubScanPhase, rest: [SearchItem], needle: String) -> Bool {
        if !rest.isEmpty { return true }
        switch phase {
        case .words(let url): return url != nil || !needle.isEmpty
        case .parts(let url): return url != nil
        }
    }

    // MARK: Шаг 1 — список моделей

    /// ⚠️ `fileprivate`, а не `private`: закладка `HubCursor` возит недоказанный остаток
    /// именно этих значений. Наружу они всё равно не видны — поле в закладке закрытое.
    fileprivate struct SearchItem: Decodable, Sendable {
        let id: String
        let sha: String?
        let gated: GatedFlag?
        let downloads: Int?
        let likes: Int?
        let lastModified: String?
        /// «text-to-image» и т.п. — по нему поиск узнаёт модели картинок.
        /// ⚠️ Имя поля как в ответе справочника: разбор идёт без таблицы ключей.
        let pipeline_tag: String?
        /// Описание модели, если мы его просили. Берём отсюда одно поле —
        /// устройство модели; остальное разбору не нужно и молча пропускается.
        let config: ConfigBlock?
    }

    /// Кусочек описания модели из ответа справочника.
    fileprivate struct ConfigBlock: Decodable, Sendable {
        let modelType: String?

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
        }
    }

    /// Разбор даты из ответа справочника: «2026-08-07T22:23:05.000Z».
    ///
    /// ⚠️ Доли секунды в ответе есть, и без явного разрешения на них разбор молча
    /// возвращает пустоту — а вместе с ней пропадает вся строка про свежесть.
    /// Второй разборщик, без долей, оставлен на случай, если справочник их не пришлёт.
    private static func date(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFraction.date(from: text) { return parsed }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Признак закрытого репозитория приходит то `false`, то строкой («auto», «manual»).
    /// ⚠️ Разбирать это надо руками: обычное чтение «то булево, то строка» падает,
    /// и весь поиск оставался бы без результатов из-за одного поля.
    /// ⚠️ `fileprivate` заодно с `SearchItem`, внутри которого лежит: закрытое поле
    /// не может быть менее закрытым, чем его собственный тип.
    fileprivate struct GatedFlag: Decodable, Sendable {
        let isClosed: Bool

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {
                isClosed = flag
                return
            }
            if let text = try? single.decode(String.self) {
                isClosed = !text.isEmpty && text.lowercased() != "false"
                return
            }
            isClosed = false
        }
    }

    /// Просить ли у справочника описание модели вместе со списком.
    ///
    /// ⚠️⚠️ РАДИ ЧЕГО ЭТО ВООБЩЕ ЕСТЬ. Владелец скачал 800 МБ и узнал,
    /// что модель не запускается, только в конце. Устройство модели лежит в её описании,
    /// и справочник умеет отдавать описание ПРЯМО В СПИСКЕ — значит пометка «не
    /// запустится» может стоять у всех находок сразу, без единого лишнего обращения.
    ///
    /// ⚠️ ЖИВЫЕ ЧИСЛА, СНЯТЫЕ 10.08.2026, чтобы следующий не гадал, дорого ли это:
    ///   • страница из 20 моделей без описаний — 4,5 КБ, с описаниями — 124 КБ
    ///     (справочник отдаёт описание уже подрезанным, около 6 КБ на модель);
    ///   • путь «сходить за описанием к каждой» — это 20 отдельных обращений, и весит
    ///     он БОЛЬШЕ: одно только описание `DeepSeek-V4-Flash` тянет 126 КБ, потому что
    ///     в нём расписан каждый слой. То есть один запрос со списком дешевле двадцати
    ///     запросов по отдельности, а не дороже.
    ///   • попросить у справочника одно поле («config.model_type») нельзя — отвечает
    ///     отказом 400. Либо описание целиком, либо ничего.
    ///
    /// ⚠️ И ТОЛЬКО ДЛЯ МОДЕЛЕЙ APPLE. У файлов Google и GGUF устройство модели никто
    /// не проверяет (`MLXArchitectures` — про движок Apple), и платить за описания
    /// трафиком человека там не за что.
    private static func wantsConfig(_ format: HubFormatFilter) -> Bool {
        format == .mlx
    }

    private static func listURL(query: String,
                                format: HubFormatFilter,
                                sort: HubSortOrder,
                                limit: Int,
                                section: HubSection) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "huggingface.co"
        parts.path = "/api/models"

        var items = [
            URLQueryItem(name: "filter", value: format.rawValue),
            URLQueryItem(name: "limit", value: String(max(1, limit))),
            // Порядок выбирает человек переключателем на экране.
            URLQueryItem(name: "sort", value: sort.apiValue),
            URLQueryItem(name: "direction", value: "-1"),
            // Просим ровно те поля, которые показываем. Без этого списка справочник
            // не отдаёт ни признак закрытого репозитория, ни версию, ни дату правки.
            URLQueryItem(name: "expand[]", value: "sha"),
            URLQueryItem(name: "expand[]", value: "gated"),
            URLQueryItem(name: "expand[]", value: "downloads"),
            URLQueryItem(name: "expand[]", value: "likes"),
            URLQueryItem(name: "expand[]", value: "lastModified"),
            // Одно короткое слово на модель («text-to-image»): по нему модели картинок
            // помечаются «для картинок» и не ставятся как модель для разговора.
            URLQueryItem(name: "expand[]", value: "pipeline_tag")
        ]

        // Описание модели — только там, где по нему есть что решать (см. `wantsConfig`).
        if wantsConfig(format) {
            items.append(URLQueryItem(name: "expand[]", value: "config"))
        }

        // Слова человека и слово раздела уходят ОДНОЙ строкой поиска: справочник
        // сам ищет по всем словам сразу, и просить его дважды не нужно.
        // ⚠️ Отбор на нашей стороне при этом остаётся: справочник ищет с допуском
        // и подмешивает в выдачу похожее, а человек выбирал раздел.
        var words = [query.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let word = section.searchWord { words.append(word) }
        let search = words.filter { !$0.isEmpty }.joined(separator: " ")
        if !search.isEmpty {
            items.insert(URLQueryItem(name: "search", value: search), at: 0)
        }
        parts.queryItems = items

        guard let url = parts.url else { throw HubSearchError.badAnswer }
        return url
    }

    /// Одна страница списка + адрес следующей.
    private static func listPage(_ url: URL) async throws -> (items: [SearchItem], nextURL: URL?) {
        let answer = try await load(url)
        do {
            let items = try JSONDecoder().decode([SearchItem].self, from: answer.data)
            return (items, nextPageURL(from: answer.response))
        } catch {
            throw HubSearchError.badAnswer
        }
    }

    /// Достать адрес следующей страницы из заголовка `Link`.
    ///
    /// ⚠️ Заголовок выглядит так: `<https://…&cursor=…>; rel="next"`, и другого способа
    /// узнать про продолжение списка у справочника нет — общего числа моделей он
    /// не сообщает вовсе (проверено 10.08.2026: заголовка с итогом в ответе нет).
    /// Поэтому «показано столько-то из стольких-то» мы честно не пишем: второе число
    /// пришлось бы выдумать.
    private static func nextPageURL(from response: HTTPURLResponse) -> URL? {
        guard let header = response.value(forHTTPHeaderField: "Link") else { return nil }
        // Ссылок в заголовке может быть несколько через запятую — нам нужна «next».
        for piece in header.components(separatedBy: ",") {
            guard piece.contains("rel=\"next\""),
                  let open = piece.firstIndex(of: "<"),
                  let close = piece.firstIndex(of: ">"),
                  open < close else { continue }
            let address = String(piece[piece.index(after: open)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(string: address)
        }
        return nil
    }

    // MARK: Шаг 2 — файлы с размерами и суммами

    private struct TreeEntry: Decodable, Sendable {
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?

        struct LFS: Decodable, Sendable {
            let oid: String?
            let size: Int64?
        }
    }

    /// Дособрать по каждой найденной модели перечень её файлов.
    ///
    /// ⚠️ Запросы идут ПАРАЛЛЕЛЬНО, но порядок сохраняется исходный: справочник уже
    /// отсортировал список так, как попросил человек, и переставлять его по тому,
    /// кто первым ответил, нельзя — переключатель порядка перестал бы что-либо значить.
    /// Модель, у которой ни одного подходящего файла не нашлось, в список не попадает:
    /// показывать строку, с которой ничего нельзя сделать, — обман.
    ///
    /// ⚠️ И в воздухе одновременно держим не больше `parallelTreeRequests` запросов:
    /// страница выросла до двадцати моделей, а двадцать одновременных обращений
    /// к чужому серверу — верный способ получить в ответ «слишком часто».
    private static func withFiles(_ items: [SearchItem], format: HubFormatFilter) async -> [HubRepo] {
        // ⚠️ Собранное складываем ВНУТРИ группы и возвращаем наружу целиком, а не
        // дописываем в переменную снаружи: так ни один разбор ответа не пересекается
        // с другим, и спорить о том, кто кому что меняет, не приходится.
        let ready = await withTaskGroup(of: HubRepo?.self,
                                        returning: [String: HubRepo].self) { group in
            var collected: [String: HubRepo] = [:]
            var next = 0

            // Сначала наполняем «окно», дальше на каждый пришедший ответ запускаем
            // ровно один следующий запрос — так число запросов в полёте не растёт.
            while next < items.count, next < parallelTreeRequests {
                let item = items[next]
                group.addTask { await repo(for: item, format: format) }
                next += 1
            }

            while let result = await group.next() {
                if let result = result {
                    collected[result.id] = result
                }
                if next < items.count {
                    let item = items[next]
                    group.addTask { await repo(for: item, format: format) }
                    next += 1
                }
            }
            return collected
        }

        return items.compactMap { ready[$0.id] }
    }

    private static func repo(for item: SearchItem, format: HubFormatFilter) async -> HubRepo? {
        guard let commit = item.sha, !commit.isEmpty else { return nil }

        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "huggingface.co"
        parts.path = "/api/models/\(item.id)/tree/\(commit)"
        parts.queryItems = [URLQueryItem(name: "recursive", value: "true")]

        guard let url = parts.url,
              let answer = try? await load(url),
              let entries = try? JSONDecoder().decode([TreeEntry].self, from: answer.data) else {
            return nil
        }

        let files = pickFiles(from: entries, format: format, repoName: (item.id as NSString).lastPathComponent)
        guard !files.isEmpty else { return nil }

        return HubRepo(id: item.id,
                       commit: commit,
                       downloads: item.downloads ?? 0,
                       likes: item.likes ?? 0,
                       lastModified: date(from: item.lastModified),
                       isGated: item.gated?.isClosed ?? false,
                       modelType: item.config?.modelType,
                       files: files,
                       pipelineTag: item.pipeline_tag)
    }

    /// Отобрать из всего репозитория то, что имеет смысл предлагать.
    /// ⚠️ Скрытый: разбор ответа справочника наружу не показываем — снаружи видны
    /// только готовые значения (`HubRepo`, `HubFile`).
    private static func pickFiles(from entries: [TreeEntry],
                                  format: HubFormatFilter,
                                  repoName: String) -> [HubFile] {

        // Модель Apple — это ПАПКА, и собирается она по своим правилам: не по расширению
        // одного файла, а по составу целиком.
        if format == .mlx {
            return folderFiles(from: entries, repoName: repoName)
        }

        let wanted = entries.filter { entry in
            entry.type == "file"
                && (entry.size ?? 0) > 0
                && ModelFileFormat.detect(fileName: entry.path) == format.fileFormat
                // Файлы-довески («глаза» модели для картинок) сами по себе не работают,
                // и предлагать их как модель — значит обещать несбыточное.
                && !entry.path.lowercased().contains("mmproj")
        }
        guard !wanted.isEmpty else { return [] }

        return wanted
            .map { entry in
                HubFile(path: entry.path,
                        byteSize: entry.lfs?.size ?? entry.size ?? 0,
                        sha256: entry.lfs?.oid ?? "")
            }
            // От лёгких к тяжёлым: на телефоне первым делом смотрят на самое лёгкое.
            .sorted { $0.byteSize < $1.byteSize }
            .prefix(filesPerRepoLimit)
            .map { $0 }
    }

    /// Собрать модель Apple: не файл, а весь состав её папки.
    ///
    /// ⚠️ БЕРЁМ ТЕ ЖЕ ФАЙЛЫ, ЧТО И ЗАГРУЗЧИК САМОЙ APPLE: `*.safetensors`, `*.json`,
    /// `*.jinja` (`MLXLMCommon/ModelFactory.swift`). Не «все файлы репозитория»: там
    /// лежат ещё описания, картинки и словари для чужих движков — движку Apple они
    /// не нужны, а мобильный трафик за них платит человек.
    ///
    /// ⚠️ ТОЛЬКО ВЕРХНИЙ УРОВЕНЬ. В одном репозитории бывает несколько сборок по папкам;
    /// модель Apple при этом плоская. Смешай мы их — скачали бы две модели в одну папку.
    ///
    /// ⚠️ И ГЛАВНОЕ: НЕТ ПОЛНОГО СОСТАВА — НЕТ И СТРОКИ В СПИСКЕ. Без устройства модели
    /// (`config.json`), словаря (`tokenizer.json`) или самих весов модель не запустится
    /// вообще. Показать такую строку с живой кнопкой «Скачать» — значит пообещать
    /// человеку гигабайты, из которых ничего не соберётся.
    private static func folderFiles(from entries: [TreeEntry], repoName: String) -> [HubFile] {
        let allowedExtensions: Set<String> = ["safetensors", "json", "jinja"]

        let parts = entries.compactMap { entry -> HubFile? in
            guard entry.type == "file", !entry.path.contains("/") else { return nil }
            let size = entry.lfs?.size ?? entry.size ?? 0
            guard size > 0 else { return nil }
            guard allowedExtensions.contains((entry.path as NSString).pathExtension.lowercased()) else {
                return nil
            }
            return HubFile(path: entry.path, byteSize: size, sha256: entry.lfs?.oid ?? "")
        }

        let names = Set(parts.map { $0.path.lowercased() })
        let hasWeights = parts.contains { ($0.path as NSString).pathExtension.lowercased() == "safetensors" }
        guard hasWeights,
              names.contains(MLXModelFolder.configFileName),
              names.contains(MLXModelFolder.tokenizerFileName) else {
            return []
        }

        let total = parts.reduce(Int64(0)) { $0 + $1.byteSize }
        // Одна строка на всю модель: человеку важен общий вес, а не то, что внутри
        // десять файлов. Сколько их — скажет отдельная пометка «набор из 10 файлов».
        return [HubFile(path: repoName,
                        byteSize: total,
                        sha256: "",
                        partCount: parts.count,
                        parts: parts.sorted { $0.byteSize < $1.byteSize })]
    }

    // MARK: Сеть

    /// ⚠️ Возвращаем и тело, и сам ответ: адрес следующей страницы приходит ЗАГОЛОВКОМ,
    /// а не полем внутри тела. Отбросить ответ здесь — значит потерять продолжение списка.
    private static func load(_ url: URL) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // ⚠️ Ответ забираем ОДНОЙ переменной, а не разбираем сразу на две: раскладывать
        // пару по двум заранее объявленным постоянным внутри do — способ поспорить
        // с компилятором на ровном месте, а собрать проект здесь нечем.
        let answer: (Data, URLResponse)
        do {
            answer = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .networkConnectionLost, .cannotConnectToHost:
                throw HubSearchError.noInternet
            default:
                throw HubSearchError.refused(0)
            }
        }

        guard let http = answer.1 as? HTTPURLResponse else { throw HubSearchError.badAnswer }
        guard http.statusCode == 200 else { throw HubSearchError.refused(http.statusCode) }
        return (answer.0, http)
    }
}
