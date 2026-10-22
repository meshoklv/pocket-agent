//
//  ModelSources.swift
//  PocketAgent / Runtime
//
//  ОТКУДА качать модель и КАК выбрать самый быстрый адрес.
//
//  Зачем это вообще появилось: файлы моделей весят от 600 МБ до 4 ГБ, а качают их
//  по мобильной сети. Каждый мегабайт в секунду — это минуты ожидания, поэтому перед
//  началом загрузки приложение само пробует все известные адреса маленьким кусочком
//  и берёт тот, что ответил быстрее.
//
//  ⚠️ ЧТО ПОКАЗАЛА ЖИВАЯ РАЗВЕДКА 09.08.2026 (проверено запросами, а не по памяти).
//    • huggingface.co отвечает перенаправлением на свою сеть доставки
//      (us.aws.cdn.hf.co), отдаёт файл по частям (Accept-Ranges: bytes) и сообщает
//      точный размер — 2 588 147 712 байт для Gemma 4 E2B, ровно как в справочнике;
//    • hf-mirror.com — самое известное зеркало — САМ отвечает перенаправлением
//      обратно на huggingface.co (проверено на двух разных репозиториях). То есть
//      это больше не зеркало, а лишний крюк: качать через него медленнее, а доверия
//      к чужому серверу требуется больше;
//    • aifasthub.com (AI快站) отвечает отказом 403;
//    • подписанные адреса самой сети доставки (cdn-lfs*.hf.co) без подписи отвечают
//      403, а подпись живёт всего час — зашивать такой адрес в приложение нельзя.
//
//  ⚠️ ПОВТОРНАЯ РАЗВЕДКА 10.08.2026 ОПРОВЕРГЛА ОДИН ИЗ ПУНКТОВ ВЫШЕ. Тогда записали,
//  что «ModelScope этих репозиториев у себя не держит — отвечает 404». Это неверно:
//  проверяли не тот адрес. У ModelScope СВОЯ нумерация версий, и по чужому номеру
//  версии Hugging Face он честно отвечает 404 — а по своему слову «master» отдаёт
//  файл. Живая проверка 10.08.2026:
//    • .../models/litert-community/gemma-4-E2B-it-litert-lm/resolve/master/
//      gemma-4-E2B-it.litertlm → 206, отдаёт по частям, размер тот же
//      2 588 147 712 байт;
//    • 4 МБ, взятые с середины файла (со смещения 1 000 000 000), дали ПОБАЙТОВО
//      ту же контрольную сумму, что и такие же 4 МБ с Hugging Face;
//    • ModelScope сам называет эталонную сумму файла в заголовке X-Linked-Etag,
//      и она совпала с суммой из нашего справочника;
//    • на месте оказались все четыре нужных нам репозитория (E2B, E4B, 3n E2B, 3n E4B).
//  Поэтому зеркало ОДНО и оно настоящее. Кому оно нужно: ModelScope — китайский,
//  из России и Азии он часто ближе и быстрее, а Hugging Face там временами недоступен.
//
//  ⚠️ ПОЧЕМУ HEAD БОЛЬШЕ НЕ СПРАШИВАЕМ. Старый замер начинался с вопроса «одни только
//  заголовки» (HEAD). ModelScope на такой вопрос отвечает пустой страницей: ни размера,
//  ни признака «умею отдавать по частям». Замер делал вывод «не умеет» — и единственное
//  живое зеркало отбрасывалось, ни разу не будучи опробованным. Теперь спрашиваем
//  сразу кусок и смотрим на ответ (см. `measure`).
//
//  ⚠️⚠️ РАЗВЕДКА 10.08.2026 (вечер): ЗАМЕР МЕРИЛ НЕ ТО, И ВЫБОР БЫЛ ПОЧТИ ЖРЕБИЕМ.
//  Замерено из контейнера (свой канал, не телефон владельца), файл E2B-gpu, 2,01 ГБ:
//    • честная скорость на куске 8 МБ: официальный сайт 2,55–4,41 МБ/с, зеркало
//      1,29–1,74 МБ/с — то есть разница у них РАЗА в два;
//    • а старый замер давал 0,04–0,09 МБ/с ОБОИМ. Причина: он делил четверть мегабайта
//      на ПОЛНОЕ время запроса, а в этом времени 2,5–5,8 секунды — ожидание первого
//      байта. Мерилась задержка, а не скорость, и оба источника выходили одинаковыми
//      с точностью до шума. Выбор «кто быстрее» был подбрасыванием монетки.
//    • и стоил этот замер 6,7–12,8 секунды на источник, потому что делал ДВА запроса
//      подряд там, где хватает одного.
//  Теперь: один запрос, время считается ОТ ПЕРВОГО БАЙТА, начало (разгон соединения)
//  выбрасывается, чтение идёт по бюджету времени. Замер 3,1–5,2 секунды на источник
//  (идут они одновременно) и разницу между источниками уже видит.
//
//  ⚠️ ЧЕСТНО ПРО ГРАНИЦЫ ЗАМЕРА. Проба тянет выбор в сторону того, кто быстрее
//  РАЗГОНЯЕТСЯ, а не того, кто быстрее везёт: у официального сайта разгон медленный,
//  но дальше он держит 2,7–4,4 МБ/с; у зеркала разгон мгновенный, а держит оно
//  1,2–1,4 МБ/с. На куске в три мегабайта проба уже попадает в пятую часть от правды,
//  но одна запнувшаяся секунда всё равно портит число. Поэтому решают ДВЕ вещи:
//  проба отсеивает мёртвых и ловит только КРУПНУЮ разницу (`clearWinMargin`), а
//  настоящий судья — сама загрузка: она мерит живую скорость и, если та просела,
//  зовёт `betterAlternative` и уходит на второго, не теряя скачанного.
//
//  ⚠️ ПЕРЕНАПРАВЛЕНИЕ СТОИТ ДОРОГО, И ЕГО МОЖНО ПЛАТИТЬ ОДИН РАЗ. Оба источника на
//  каждый запрос отвечают перенаправлением на свою сеть доставки, и это не бесплатно
//  (замер 10.08.2026, первый байт куска):
//    • официальный сайт: через перенаправление 2,59 с, прямо с сети доставки 1,39 с;
//    • зеркало: через перенаправление 5,05 с, прямо 1,90 с.
//  На 76 кусках это 91 и 239 секунд ЧИСТОГО ОЖИДАНИЯ соответственно. Подписанная
//  ссылка сети доставки годится на любой кусок файла — но ТОЛЬКО если попросить её
//  БЕЗ заголовка «отдай кусок»: с ним подпись привязывается к тому самому куску,
//  и на другой она отвечает «Auth failed: invalid range» (проверено). Поэтому
//  `resolve` спрашивает адрес без просьбы о куске — и отдаёт ссылку, годную для всех
//  кусков сразу.
//
//  ⚠️ ПОДПИСЬ ЖИВЁТ ЧАС, А ЗАГРУЗКА БЫВАЕТ ДОЛЬШЕ. У официального сайта в ссылке прямо
//  написан срок (`Expires`), и это ровно 60 минут; у зеркала срок не написан вовсе —
//  такому верим 10 минут и не больше. Файл на 2 ГБ при 1 МБ/с едет 33 минуты, при
//  0,5 МБ/с — больше часа, то есть подпись протухает ПОСРЕДИ загрузки. Значит,
//  сохранять её на диск в план загрузки НЕЛЬЗЯ: на диске живёт обычный адрес, а
//  подписанная ссылка — только в памяти и с проверкой срока перед каждым куском.
//
//  ⚠️ БЕЗОПАСНОСТЬ — НЕ ОБСУЖДАЕТСЯ. Зеркало — это чужой сервер, он может отдать
//  что угодно. Поэтому:
//    • зеркала участвуют в выборе ТОЛЬКО у моделей с эталонной контрольной суммой;
//    • файл, скачанный НЕ с официального адреса, принимается только после сверки
//      суммы; не сошлась — файл удаляется, зеркало больше не используется;
//    • ни одного адреса, который требует вход, ключ или отправку чего-либо о человеке.
//

import Foundation

// MARK: - Один источник

/// Адрес, с которого можно взять файл модели.
///
/// Хранится не готовая ссылка, а шаблон с подстановками `{repo}`, `{commit}`, `{file}` —
/// так один источник работает для всех моделей справочника сразу.
public struct ModelSource: Sendable, Equatable, Identifiable {

    /// Опознаватель источника (по нему запоминаем «этот больше не берём»).
    public let id: String
    /// Как назвать источник человеку: «с Hugging Face», «с зеркала ModelScope».
    public let humanName: String
    /// Официальный ли это адрес. У неофициального файл принимается только после
    /// сверки контрольной суммы — целиком, до последнего байта.
    public let isOfficial: Bool
    /// Шаблон ссылки с подстановками `{repo}`, `{commit}`, `{file}`.
    public let urlTemplate: String
    /// Какое слово подставлять вместо номера версии, если у источника СВОЯ нумерация.
    ///
    /// ⚠️ ИЗ-ЗА ОТСУТСТВИЯ ЭТОГО ПОЛЯ ЖИВОЕ ЗЕРКАЛО ЗАПИСАЛИ В МЁРТВЫЕ. Номер версии у Hugging Face
    /// и у зеркала разный: зеркало копирует файлы, а не историю. Подставишь чужой
    /// номер — получишь честный отказ «нет такой версии», и зеркало запишут в мёртвые,
    /// хотя файл у него есть (так и вышло 09.08.2026 с ModelScope). `nil` — у источника
    /// та же нумерация, что у Hugging Face, подставляем номер из справочника.
    ///
    /// Потери закрепления версии тут нет: файл с зеркала принимается только после
    /// полной сверки контрольной суммы, а несовпадение размера видно ещё до загрузки.
    public let pinnedVersionWord: String?

    public init(id: String,
                humanName: String,
                isOfficial: Bool,
                urlTemplate: String,
                pinnedVersionWord: String? = nil) {
        self.id = id
        self.humanName = humanName
        self.isOfficial = isOfficial
        self.urlTemplate = urlTemplate
        self.pinnedVersionWord = pinnedVersionWord
    }

    /// Ссылка на файл конкретной модели. nil — источник для этой модели не годится.
    public func url(for model: ModelDescriptor) -> URL? {
        guard !model.repoID.isEmpty, !model.fileName.isEmpty, !model.repoCommit.isEmpty else {
            return nil
        }
        var text = urlTemplate
        text = text.replacingOccurrences(of: "{repo}", with: model.repoID)
        text = text.replacingOccurrences(of: "{commit}", with: pinnedVersionWord ?? model.repoCommit)
        // ⚠️ ПУТЬ ВНУТРИ РЕПОЗИТОРИЯ, А НЕ ИМЯ НА ДИСКЕ — ровно как в `downloadURL`.
        // У частей папки-модели Apple они РАЗНЫЕ: на диске файл лежит внутри
        // недособранной папки («Qwen3-4B.import/model.safetensors»), а у Hugging Face
        // он просто «model.safetensors». Подставь мы сюда имя на диске — адрес
        // указывал бы в никуда, замер источников молча падал бы на 404, и файл весов
        // (единственный, кто крупнее куска) качался бы одним потоком вместо трёх,
        // без докачки по 32 МБ. У моделей из одного файла `repoPath` пуст — для них
        // здесь ничего не меняется.
        text = text.replacingOccurrences(of: "{file}", with: model.repoPath ?? model.fileName)
        return URL(string: text)
    }
}

// MARK: - Список источников

public enum ModelSourceCatalog {

    /// Официальный адрес Hugging Face. Он же запасной: если замер не удался,
    /// молча берём его и ничего человеку не показываем.
    public static let official = ModelSource(
        id: "huggingface",
        // ⚠️ Имя площадки, а не «официальный сайт»: владелец спросил прямо — «не ясно
        // с какого хоста качаю». «Официальный сайт» чего — не понятно.
        humanName: "с Hugging Face",
        isOfficial: true,
        urlTemplate: "https://huggingface.co/{repo}/resolve/{commit}/{file}"
    )

    /// ModelScope — зеркало, которое действительно отдаёт наши файлы.
    ///
    /// Проверено живыми запросами 10.08.2026: отвечает кодом 206 на просьбу «отдай
    /// кусок», называет тот же размер, а 4 МБ, взятые с середины файла, побайтово
    /// совпали с такими же 4 МБ с Hugging Face. Ни входа, ни ключей не просит.
    ///
    /// ⚠️ Слово версии — своё («master»): у зеркала собственная нумерация, по номеру
    /// Hugging Face оно честно отвечает «нет такой версии».
    public static let modelScope = ModelSource(
        id: "modelscope",
        humanName: "с зеркала ModelScope",
        isOfficial: false,
        urlTemplate: "https://www.modelscope.cn/models/{repo}/resolve/{commit}/{file}",
        pinnedVersionWord: "master"
    )

    /// Зеркала.
    ///
    /// ⚠️ hf-mirror.com СЮДА НЕ ВХОДИТ И СЕГОДНЯ — ПЕРЕПРОВЕРЕНО 23.09.2026.
    /// Проба куском 4 МБ по всем пяти файлам модели картинок и по чат-моделям: он
    /// по-прежнему отвечает перенаправлением на ту же сеть доставки Hugging Face
    /// (us.aws.cdn.hf.co, тот же адрес объекта). То есть это не второй источник, а тот же
    /// самый через лишний крюк: мерить его отдельно — значит сравнивать Hugging Face
    /// сам с собой. ModelScope, напротив, отдал все пять файлов со своей сети
    /// (cdn-lfs-cn-1.modelscope.cn), и в адресе объекта стоит та же sha256, что у нас.
    ///
    /// Добавлять сюда можно только адрес, который (1) отдаёт файл без входа и ключей,
    /// (2) отдаёт его по частям, (3) отдаёт побайтово тот же файл — последнее проверит
    /// сверка контрольной суммы после загрузки, а до загрузки — совпадение размера
    /// и эталонной суммы, которую сервер называет сам.
    public static let mirrors: [ModelSource] = [modelScope]

    /// Все адреса, которые имеет смысл пробовать для этой модели.
    ///
    /// Зеркала подключаются ТОЛЬКО когда есть с чем сверять скачанное. Нет эталонной
    /// суммы — качаем исключительно с официального адреса, и это не обсуждается.
    public static func candidates(for model: ModelDescriptor) -> [ModelSource] {
        guard !model.sha256.isEmpty else { return [official] }
        return [official] + mirrors
    }

    /// Источник по опознавателю (нужно, чтобы продолжить прерванную загрузку).
    public static func source(withID id: String) -> ModelSource? {
        if id == official.id { return official }
        return mirrors.first { $0.id == id }
    }

    /// Куда можно уйти с текущего источника, если он затормозил или начал отказывать.
    ///
    /// ⚠️ РАНЬШЕ ДОРОГА БЫЛА ОДНОСТОРОННЕЙ: с зеркала уходили на официальный адрес,
    /// а обратно — никогда. То есть если тормозил или отказывал именно официальный
    /// сайт (а из России это обычное дело), человек досиживал до конца на нём, хотя
    /// живое зеркало было рядом. Здесь дорога в обе стороны.
    public static func alternatives(to current: ModelSource,
                                    for model: ModelDescriptor,
                                    blocked: Set<String>) -> [ModelSource] {
        candidates(for: model).filter { $0.id != current.id && !blocked.contains($0.id) }
    }
}

// MARK: - Разрешённый адрес

/// Прямая ссылка на сеть доставки — та, что получается после перенаправления.
///
/// Зачем она: каждый кусок, запрошенный по обычному адресу, платит за перенаправление
/// 1,2–3,2 секунды ожидания (замер 10.08.2026). Кусков 76 — это полторы-четыре минуты
/// впустую. Ссылка получается один раз и годится на все куски.
public struct ResolvedSourceURL: Sendable, Equatable {

    /// Прямой адрес файла в сети доставки.
    public let url: URL
    /// До какого момента ссылке можно верить.
    public let goodUntil: Date
    /// Размер файла, если сервер назвал его при разрешении адреса. 0 — не назвал.
    public let declaredTotalBytes: Int64
    /// Сервер прямо сказал, что умеет отдавать файл по частям.
    ///
    /// ⚠️ Это не мелочь, а сэкономленный запрос: когда источник ровно один и мерить
    /// скорость не с чем, ответа на разрешение адреса уже достаточно — и приложение
    /// начинает качать на целый обмен с сервером раньше.
    public let acceptsRanges: Bool

    public init(url: URL, goodUntil: Date, declaredTotalBytes: Int64, acceptsRanges: Bool = false) {
        self.url = url
        self.goodUntil = goodUntil
        self.declaredTotalBytes = declaredTotalBytes
        self.acceptsRanges = acceptsRanges
    }

    /// Ссылку ещё можно брать. Запас — минута: кусок в 32 МБ качается не мгновенно,
    /// и начинать его за секунду до конца срока значит гарантированно получить отказ.
    public func isFresh(at moment: Date = Date()) -> Bool {
        goodUntil.timeIntervalSince(moment) > 60
    }
}

// MARK: - Замер

/// Что показал замер одного источника.
public struct ModelSourceMeasurement: Sendable, Equatable {

    public let source: ModelSource
    /// Скорость на маленьком куске, байт в секунду.
    ///
    /// ⚠️ Считается ОТ ПЕРВОГО БАЙТА и без начала (разгон соединения). Раньше сюда
    /// попадало ожидание ответа — и число получалось про задержку, а не про скорость.
    public let bytesPerSecond: Double
    /// Сервер отдаёт файл по частям — значит можно качать в несколько потоков.
    public let supportsRanges: Bool
    /// Размер файла по словам сервера. 0 — сервер не сказал.
    public let declaredTotalBytes: Int64
    /// Сколько ждали первого байта. Это отдельная беда от скорости: на 76 кусках
    /// лишняя секунда ожидания — это лишняя минута с лишним общего времени.
    public let firstByteSeconds: Double
    /// Прямая ссылка на сеть доставки, если её удалось получить.
    public let resolved: ResolvedSourceURL?
    /// Почему взяли именно этот источник — человеческими словами, для строки на экране.
    /// nil — сравнивать было не с чем, и говорить не о чем.
    public let choiceNote: String?

    public init(source: ModelSource,
                bytesPerSecond: Double,
                supportsRanges: Bool,
                declaredTotalBytes: Int64,
                firstByteSeconds: Double = 0,
                resolved: ResolvedSourceURL? = nil,
                choiceNote: String? = nil) {
        self.source = source
        self.bytesPerSecond = bytesPerSecond
        self.supportsRanges = supportsRanges
        self.declaredTotalBytes = declaredTotalBytes
        self.firstByteSeconds = firstByteSeconds
        self.resolved = resolved
        self.choiceNote = choiceNote
    }

    /// «1,8 МБ/с» — для журнала, не для экрана.
    public var speedText: String {
        guard bytesPerSecond >= 1 else { return "медленнее 1 Б/с" }
        return "\(HumanFormat.bytes(Int64(bytesPerSecond.rounded())))/с"
    }

    /// Адрес, по которому качать: прямой, пока он свеж, иначе обычный.
    public func downloadURL(for model: ModelDescriptor, at moment: Date = Date()) -> URL? {
        if let resolved, resolved.isFresh(at: moment) { return resolved.url }
        return source.url(for: model)
    }

    /// Тот же замер, но с пояснением, почему выбрали его.
    func explained(_ note: String?) -> ModelSourceMeasurement {
        ModelSourceMeasurement(source: source,
                               bytesPerSecond: bytesPerSecond,
                               supportsRanges: supportsRanges,
                               declaredTotalBytes: declaredTotalBytes,
                               firstByteSeconds: firstByteSeconds,
                               resolved: resolved,
                               choiceNote: note)
    }
}

/// Быстрый замер источников перед загрузкой: кто жив, кто отдаёт по частям, кто быстрее.
///
/// ⚠️ ПОЧЕМУ СРАЗУ ПРОСИМ КУСОК, А НЕ «ТОЛЬКО ЗАГОЛОВКИ». Раньше замер начинался
/// с вопроса HEAD — «скажи размер и умеешь ли отдавать по частям». Так делать нельзя
/// по двум причинам сразу. Первая: часть серверов на HEAD отвечает пустышкой без
/// единого нужного заголовка (так отвечает ModelScope), и замер объявлял живой
/// источник мёртвым. Вторая: это лишний обмен с сервером на каждый источник, а он
/// стоит секунду-полторы на мобильной сети.
///
/// Гигабайтов ради замера не приедет: мы просим ОДИН кусок ограниченного размера,
/// и читаем его не дольше отведённого бюджета времени. Ответил сервер «вот весь файл»
/// вместо куска — обрываем связь на первых байтах.
public enum ModelSourceProbe {

    /// Сколько байт максимум берём на замер.
    ///
    /// ⚠️ ТРИ МЕГАБАЙТА, А НЕ ЧЕТВЕРТЬ, И ЭТО ПРОВЕРЕНО ПОДБОРОМ, А НЕ НА ГЛАЗ.
    /// Соединение разгоняется: первый мегабайт едет заведомо медленнее, чем пойдёт
    /// дальше. Сравнение с эталоном (честные 8 МБ подряд, замер 10.08.2026, каждый
    /// раз с нового места файла — чтобы сеть доставки его ещё не видела):
    ///   • четверть мегабайта: 0,04–0,09 МБ/с при настоящих 1,3–4,4 — мимо втрое-вдесятеро;
    ///   • полтора мегабайта:  1,11 и 2,71 при настоящих 2,85 и 4,35 — всё ещё мимо;
    ///   • три мегабайта:      3,46 и 4,49 при настоящих 2,85 и 4,35 — разница в пределах
    ///     пятой части, и этого уже хватает, чтобы сравнивать источники.
    /// Три мегабайта — это полторы десятых процента от файла модели, и на медленной
    /// связи столько всё равно не успеет приехать: чтение обрывается по времени.
    static let sampleBytes = 3 * 1024 * 1024

    /// Сколько байт в начале куска выбрасываем из подсчёта — это разгон соединения.
    static let warmupBytes = 512 * 1024

    /// Сколько времени читаем содержимое после первого байта. Дольше держать незачем:
    /// человек стоит и ждёт начала загрузки. Две секунды — цена честного числа;
    /// на одной с небольшим замер систематически занижал быстрый источник.
    static let speedBudget: TimeInterval = 2.0

    /// Сколько ждём ПЕРВОГО ответа от источника. Не ответил за это время — мимо.
    ///
    /// ⚠️ Восемь секунд, а не шесть: живой замер 10.08.2026 показал ожидание первого
    /// байта 2,5–5,8 секунды даже там, где связь хорошая (перенаправление на сеть
    /// доставки плюс её поход за куском). Шести секунд слабой связи не хватает,
    /// и тогда живой источник объявляется мёртвым.
    static let firstReplyTimeout: TimeInterval = 8

    /// Сколько всего отводим на замер одного источника.
    ///
    /// ⚠️ РАНЬШЕ ЗДЕСЬ СТОЯЛО ТО ЖЕ ЧИСЛО, ЧТО И ВЫШЕ, И ЭТО САМО ПО СЕБЕ ТОРМОЗИЛО
    /// загрузку. На слабой связи четверть мегабайта честно едет дольше шести секунд —
    /// замер обрывался, приложение решало «источник не ответил» и качало файл ОДНИМ
    /// потоком вместо трёх. То есть чем хуже связь, тем вернее мы отбирали у себя
    /// ускорение — ровно наоборот тому, что нужно.
    static let totalTimeout: TimeInterval = 20

    /// Насколько зеркало обязано быть быстрее, чтобы предпочесть его официальному сайту.
    ///
    /// ⚠️ НЕ «ХОТЬ НА БАЙТ БЫСТРЕЕ», И ЭТО ВАЖНО. Проба меряет с погрешностью: на
    /// хорошем куске она укладывается в пятую часть, но стоит связи на секунду
    /// запнуться — и оба числа уезжают куда угодно (в одном прогоне из трёх у нас
    /// вышло ровно так). Мелкая разница в такой пробе — шум, а цена ошибки не нулевая:
    /// с зеркала файл принимается только после полной сверки суммы. Поэтому уходим
    /// к зеркалу, только если оно быстрее ПОЛУТОРА раз, а не «чуть-чуть».
    static let clearWinMargin = 1.5

    /// Насколько другой источник должен обгонять нынешний, чтобы уйти на него
    /// ПОСРЕДИ загрузки. Больше, чем при первом выборе: переход стоит нового
    /// разгона соединений, и делать его ради десяти процентов не стоит.
    static let switchMargin = 1.5

    /// Сколько верим подписанной ссылке, если сервер не сказал срок сам.
    static let unknownLinkLifetime: TimeInterval = 10 * 60

    // MARK: Прямой адрес сети доставки

    /// Узнать прямой адрес файла, не скачивая ничего.
    ///
    /// ⚠️ СПРАШИВАЕМ БЕЗ ПРОСЬБЫ О КУСКЕ — ИНАЧЕ ССЫЛКА ГОДИТСЯ РОВНО НА ОДИН КУСОК.
    /// Официальный сайт вшивает в подпись тот самый диапазон, который был в запросе,
    /// и на любой другой отвечает «Auth failed: invalid range» (проверено живьём
    /// 10.08.2026). Спросишь без диапазона — получишь ссылку на весь файл, годную
    /// для всех 76 кусков сразу.
    ///
    /// Тела ответа при этом не будет вовсе: мы запрещаем переход по перенаправлению
    /// и читаем только заголовок с адресом.
    public static func resolve(_ source: ModelSource,
                               model: ModelDescriptor,
                               allowsCellular: Bool) async -> ResolvedSourceURL? {
        guard let url = source.url(for: model) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("PocketAgent/1.0", forHTTPHeaderField: "User-Agent")

        // Тело нам не нужно вовсе: слушатель обрывает связь сразу после заголовков.
        let reader = ProbeReader(stopsRedirects: true, warmupBytes: warmupBytes, budget: 0)
        guard let http = await run(request, reader: reader, allowsCellular: allowsCellular).response else {
            return nil
        }

        // Перенаправления не было — значит, обычный адрес и есть прямой.
        guard (300...399).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let direct = URL(string: location, relativeTo: url)?.absoluteURL else {
            guard (200...299).contains(http.statusCode) else { return nil }
            return ResolvedSourceURL(url: url,
                                     goodUntil: Date.distantFuture,
                                     declaredTotalBytes: linkedSize(http),
                                     acceptsRanges: saysAcceptsRanges(http))
        }

        return ResolvedSourceURL(url: direct,
                                 goodUntil: expiry(of: direct),
                                 declaredTotalBytes: linkedSize(http),
                                 acceptsRanges: saysAcceptsRanges(http))
    }

    /// Сервер сам сказал «умею отдавать по частям».
    static func saysAcceptsRanges(_ http: HTTPURLResponse) -> Bool {
        guard let text = http.value(forHTTPHeaderField: "Accept-Ranges") else { return false }
        return text.caseInsensitiveCompare("bytes") == .orderedSame
    }

    /// До какого момента живёт подписанная ссылка.
    /// Официальный сайт пишет срок прямо в адресе (`Expires`, ровно час). Зеркало
    /// не пишет ничего — такому верим `unknownLinkLifetime` и не дольше.
    static func expiry(of url: URL) -> Date {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let text = items.first(where: { $0.name.caseInsensitiveCompare("Expires") == .orderedSame })?.value,
           let seconds = Double(text), seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        return Date().addingTimeInterval(unknownLinkLifetime)
    }

    /// Размер файла, если сервер назвал его при разрешении адреса.
    static func linkedSize(_ http: HTTPURLResponse) -> Int64 {
        guard let text = http.value(forHTTPHeaderField: "X-Linked-Size"),
              let value = Int64(text) else { return 0 }
        return value
    }

    // MARK: Замер одного источника

    /// Замерить один источник. nil — источник не ответил или ответил отказом.
    /// Ничего не бросает: неудачный замер — это не ошибка для человека.
    ///
    /// - Parameter needsSpeed: нужна ли настоящая скорость. Когда источник ровно один,
    ///   сравнивать не с чем — тогда читать содержимое незачем, хватает заголовков,
    ///   и начало загрузки не откладывается.
    public static func measure(_ source: ModelSource,
                               model: ModelDescriptor,
                               allowsCellular: Bool,
                               needsSpeed: Bool = true) async -> ModelSourceMeasurement? {
        guard let canonical = source.url(for: model) else { return nil }

        // Сначала прямой адрес: он и замер ускорит, и потом достанется загрузке —
        // каждый кусок перестанет платить за перенаправление.
        let resolved = await resolve(source, model: model, allowsCellular: allowsCellular)
        let target = resolved?.url ?? canonical

        // Сервер назвал размер ещё при разрешении адреса, и он не наш — дальше не идём.
        if let resolved, resolved.declaredTotalBytes > 0, model.byteSize > 0,
           resolved.declaredTotalBytes != model.byteSize {
            return nil
        }

        // Мерить скорость не с чем, а всё нужное сервер уже сказал сам: и что отдаёт
        // по частям, и какого размера файл. Второй обмен с сервером тут — это только
        // лишние секунды перед началом загрузки.
        if !needsSpeed, let resolved, resolved.acceptsRanges,
           resolved.declaredTotalBytes > 0, resolved.declaredTotalBytes == model.byteSize {
            return ModelSourceMeasurement(source: source,
                                          bytesPerSecond: 0,
                                          supportsRanges: true,
                                          declaredTotalBytes: resolved.declaredTotalBytes,
                                          resolved: resolved)
        }

        var request = URLRequest(url: target)
        request.setValue("PocketAgent/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-\(sampleBytes - 1)", forHTTPHeaderField: "Range")

        // ⚠️ Обрыв по нашему же бюджету времени выглядит как ошибка связи, но замер
        // при этом удался. Поэтому судим не по ошибке, а по тому, что успел собрать
        // слушатель: пришли ли заголовки и сколько байт приехало за сколько времени.
        let reader = ProbeReader(stopsRedirects: false,
                                 warmupBytes: warmupBytes,
                                 budget: needsSpeed ? speedBudget : 0)
        let seen = await run(request, reader: reader, allowsCellular: allowsCellular)
        guard let http = seen.response else { return nil }

        // Сервер не понял просьбу «отдай кусок» и собрался слать файл целиком.
        // Читатель уже оборвал связь на заголовках — гигабайты не поехали.
        guard http.statusCode == 206 else {
            guard (200...299).contains(http.statusCode) else { return nil }
            return ModelSourceMeasurement(source: source,
                                          bytesPerSecond: 0,
                                          supportsRanges: false,
                                          declaredTotalBytes: 0,
                                          firstByteSeconds: seen.firstByteSeconds,
                                          resolved: resolved)
        }

        let declaredTotal = totalBytes(fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))

        // Сервер называет другой размер — это другой файл. Такому источнику веры нет.
        if declaredTotal > 0, model.byteSize > 0, declaredTotal != model.byteSize {
            return nil
        }

        // ⚠️ ПРОВЕРКА «ТОТ ЛИ ЭТО ФАЙЛ» ДО ЗАГРУЗКИ, А НЕ ПОСЛЕ. Зеркало называет
        // эталонную сумму файла само (заголовок X-Linked-Etag). Не сходится с нашей —
        // качать гигабайты, чтобы в конце их выбросить, незачем: отсеиваем сразу.
        if let declared = declaredChecksum(http), !model.sha256.isEmpty,
           declared.caseInsensitiveCompare(model.sha256) != .orderedSame {
            return nil
        }

        return ModelSourceMeasurement(source: source,
                                      bytesPerSecond: seen.bytesPerSecond,
                                      supportsRanges: true,
                                      declaredTotalBytes: declaredTotal,
                                      firstByteSeconds: seen.firstByteSeconds,
                                      resolved: resolved)
    }

    // MARK: Кто быстрее

    /// Замерить все подходящие источники разом и вернуть лучший.
    ///
    /// - Parameter blocked: опознаватели источников, которые больше не берём
    ///   (например, зеркало, отдавшее файл с несошедшейся суммой).
    /// - Returns: nil — не ответил никто. Тогда зовущий молча берёт официальный адрес.
    public static func chooseFastest(for model: ModelDescriptor,
                                     allowsCellular: Bool,
                                     blocked: Set<String>) async -> ModelSourceMeasurement? {
        let sources = ModelSourceCatalog.candidates(for: model).filter { !blocked.contains($0.id) }
        guard !sources.isEmpty else { return nil }

        if sources.count == 1 {
            // Сравнивать не с чем — скорость не нужна, а значит и лишние секунды
            // перед началом загрузки тоже.
            return await measure(sources[0],
                                 model: model,
                                 allowsCellular: allowsCellular,
                                 needsSpeed: false)
        }

        return best(of: await measureAll(sources, model: model, allowsCellular: allowsCellular))
    }

    /// Есть ли источник, который ЗАМЕТНО быстрее нынешнего прямо сейчас.
    ///
    /// Зовётся посреди загрузки, когда живая скорость просела или пошли отказы.
    /// `liveBytesPerSecond` — то, что приложение видит на настоящей загрузке; ноль
    /// означает «нынешний источник встал совсем», и тогда годится любой живой.
    ///
    /// ⚠️ Уже скачанное при переходе не пропадает: куски сложены на диске, меняется
    /// только адрес, откуда брать оставшиеся.
    public static func betterAlternative(than current: ModelSource,
                                         beating liveBytesPerSecond: Double,
                                         for model: ModelDescriptor,
                                         allowsCellular: Bool,
                                         blocked: Set<String>) async -> ModelSourceMeasurement? {
        let others = ModelSourceCatalog.alternatives(to: current, for: model, blocked: blocked)
        guard !others.isEmpty else { return nil }

        let results = await measureAll(others, model: model, allowsCellular: allowsCellular)
            .filter { $0.supportsRanges }
        guard let candidate = best(of: results) else { return nil }

        // Нынешний источник стоит — берём любого живого.
        guard liveBytesPerSecond > 0 else { return candidate }
        guard candidate.bytesPerSecond >= liveBytesPerSecond * switchMargin else { return nil }
        return candidate.explained("этот источник оказался быстрее")
    }

    /// Замерить несколько источников одновременно.
    static func measureAll(_ sources: [ModelSource],
                           model: ModelDescriptor,
                           allowsCellular: Bool) async -> [ModelSourceMeasurement] {
        await withTaskGroup(of: ModelSourceMeasurement?.self) { group in
            for source in sources {
                group.addTask {
                    await measure(source, model: model, allowsCellular: allowsCellular)
                }
            }
            var results: [ModelSourceMeasurement] = []
            for await item in group {
                if let item { results.append(item) }
            }
            return results
        }
    }

    // MARK: Мелочи

    /// Полный размер файла из заголовка «bytes 0-262143/2588147712». 0 — не разобрали.
    static func totalBytes(fromContentRange text: String?) -> Int64 {
        guard let text, let slash = text.lastIndex(of: "/") else { return 0 }
        let tail = text[text.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return Int64(tail) ?? 0
    }

    /// Эталонная сумма файла, если сервер назвал её сам. Зеркало кладёт её
    /// в X-Linked-Etag, иногда в кавычках.
    ///
    /// ⚠️ У официального сайта этого заголовка на КОНЕЧНОМ ответе нет — он остаётся
    /// на перенаправлении, которое мы уже не видим. Ничего страшного: файл с официального
    /// адреса сверяется по сумме из справочника сразу после загрузки.
    static func declaredChecksum(_ http: HTTPURLResponse) -> String? {
        guard let raw = http.value(forHTTPHeaderField: "X-Linked-Etag") else { return nil }
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        // Сумма — это 64 знака шестнадцатеричного вида. Всё прочее (например,
        // «W/"abc"» обычного ETag) сравнивать не с чем, и лезть туда не будем.
        guard value.count == 64,
              value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value
    }

    /// Кто победил — и почему, человеческими словами.
    ///
    /// Порядок решений: сначала те, кто умеет отдавать по частям (иначе теряются
    /// три потока — это дороже любой разницы в скорости). Дальше официальный адрес
    /// идёт первым по умолчанию, и уступает зеркалу, только если зеркало быстрее
    /// заметно (`clearWinMargin`). Мелкая разница — это шум замера, а не победа.
    static func best(of results: [ModelSourceMeasurement]) -> ModelSourceMeasurement? {
        guard !results.isEmpty else { return nil }

        // Умеющие отдавать по частям — отдельная лига, и она главнее скорости.
        let ranged = results.filter { $0.supportsRanges }
        let pool = ranged.isEmpty ? results : ranged
        guard pool.count > 1 else { return pool.first }

        let fastestMirror = pool.filter { !$0.source.isOfficial }
            .max { $0.bytesPerSecond < $1.bytesPerSecond }

        guard let official = pool.first(where: { $0.source.isOfficial }) else {
            return fastestMirror ?? pool.first
        }
        guard let mirror = fastestMirror else { return official }

        // ⚠️ СРАВНИВАЕМ, ТОЛЬКО ЕСЛИ ОБА ЧИСЛА НАСТОЯЩИЕ. Ноль здесь означает не
        // «медленно», а «скорость выяснить не удалось» — и без этой проверки сравнение
        // «ноль не меньше нуля» отправляло бы человека на зеркало каждый раз, когда
        // замер сорвался у обоих. Не знаем — берём официальный, он безопаснее.
        guard mirror.bytesPerSecond > 0, official.bytesPerSecond > 0 else { return official }

        if mirror.bytesPerSecond >= official.bytesPerSecond * clearWinMargin {
            return mirror.explained(advantage(of: mirror, over: official))
        }
        if official.bytesPerSecond >= mirror.bytesPerSecond * clearWinMargin {
            return official.explained(advantage(of: official, over: mirror))
        }
        // Разница в пределах погрешности — берём официальный и молчим: сказать
        // «он быстрее» было бы неправдой, а лишняя строка на экране никому не нужна.
        return official
    }

    /// «быстрее зеркала вдвое» — коротко и без чисел, которые человеку нечем проверить.
    static func advantage(of winner: ModelSourceMeasurement,
                          over loser: ModelSourceMeasurement) -> String? {
        guard loser.bytesPerSecond > 0 else { return nil }
        let times = winner.bytesPerSecond / loser.bytesPerSecond
        let other = loser.source.isOfficial ? "Hugging Face" : "зеркала"
        if times >= 2.5 { return "втрое быстрее \(other)" }
        if times >= 1.8 { return "вдвое быстрее \(other)" }
        return "быстрее \(other)"
    }

    /// Сходить одним запросом и вернуть всё, что собрал слушатель.
    ///
    /// ⚠️ СЛУШАТЕЛЬ ЗАВЕДЁН НА ВСЮ СЕССИЮ, А НЕ НА ОДНУ ЗАДАЧУ, И ЭТО НЕ ПРИДИРКА.
    /// Короткий способ «скачай и отдай всё сразу» отдаёт только готовый результат:
    /// ни времени первого байта, ни возможности оборвать связь на середине у него нет,
    /// а нам нужно ровно это. Поэтому задача обычная, а ответ мы читаем по мере
    /// прихода — тогда и скорость считается честно, и лишнее не скачивается.
    private static func run(_ request: URLRequest,
                            reader: ProbeReader,
                            allowsCellular: Bool) async -> ProbeReader.Seen {
        let session = URLSession(configuration: probeConfig(allowsCellular: allowsCellular),
                                 delegate: reader,
                                 delegateQueue: nil)
        // ⚠️ Сессию с слушателем ОБЯЗАТЕЛЬНО распускать: пока она жива, она держит
        // слушателя, а тот — её. Замеров за жизнь приложения десятки.
        defer { session.finishTasksAndInvalidate() }

        let task = session.dataTask(with: request)
        task.resume()
        await reader.waitUntilDone()
        return reader.snapshot()
    }

    /// Настройки лёгкой сессии под замер: фоновую для этого трогать нельзя —
    /// в ней живёт сама загрузка модели.
    private static func probeConfig(allowsCellular: Bool) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = allowsCellular
        config.allowsExpensiveNetworkAccess = allowsCellular
        // ⚠️ РЕЖИМ ЭКОНОМИИ ТРАФИКА НЕ ДОЛЖЕН МОЛЧА ОТБИРАТЬ СКОРОСТЬ. Пока здесь
        // стоял запрет, у человека с включённой экономией замер падал всегда — а раз
        // замер не удался, файл качался одним потоком вместо трёх. Человек нажал
        // «Скачать модель»: это и есть его согласие, придумывать за него запрет нечего.
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForRequest = firstReplyTimeout
        config.timeoutIntervalForResource = totalTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldSetCookies = false
        return config
    }
}

// MARK: - Слушатель ответа

/// Читает ответ по мере прихода: ловит заголовки, считает настоящую скорость
/// и вовремя обрывает связь.
///
/// ⚠️ ПОЧЕМУ НЕ ПРОСТО «СКАЧАЙ И ПОДЕЛИ». Деление объёма на время запроса меряет
/// не скорость, а ожидание: у сети доставки первый байт приходит через секунды, и на
/// маленьком куске он съедает весь замер (так и было — оба источника показывали
/// 0,04–0,09 МБ/с при настоящих 1,3–4,4). Здесь время считается от ПЕРВОГО байта,
/// а первые `warmupBytes` (разгон соединения) не считаются вовсе. И связь обрывается
/// по бюджету времени, а не когда приедет всё, — иначе на медленной связи сам замер
/// стал бы задержкой.
private final class ProbeReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    struct Seen {
        let response: HTTPURLResponse?
        let bytesPerSecond: Double
        let firstByteSeconds: Double
    }

    private let lock = NSLock()
    /// Не ходить по перенаправлению: нам нужен сам адрес, а не файл по нему.
    private let stopsRedirects: Bool
    private let warmupBytes: Int
    private let budget: TimeInterval

    private let startedAt = Date()
    private var response: HTTPURLResponse?
    private var firstByteAt: Date?
    private var tailStartedAt: Date?
    private var received = 0
    private var tailBytes = 0
    private var lastByteAt: Date?
    private var isDone = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(stopsRedirects: Bool, warmupBytes: Int, budget: TimeInterval) {
        self.stopsRedirects = stopsRedirects
        self.warmupBytes = warmupBytes
        self.budget = budget
    }

    /// Дождаться конца запроса. Вечно не повиснет: у сессии свои сроки ожидания.
    func waitUntilDone() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isDone {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // ⚠️ Ответ с перенаправлением запоминаем ЗДЕСЬ. Про промежуточный ответ система
        // обычным способом («вот заголовки») не сообщает — а нам нужен именно он: в нём
        // и адрес сети доставки, и размер файла, и признак «отдаю по частям».
        if stopsRedirects {
            lock.withLock { if self.response == nil { self.response = response } }
        }
        completionHandler(stopsRedirects ? nil : request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        isDone = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume()
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        lock.withLock { if !self.stopsRedirects || self.response == nil { self.response = http } }
        // Заголовков достаточно: либо содержимое нам не нужно, либо сервер вообще
        // не понял просьбу о куске и сейчас пришлёт весь файл — обрываем сразу.
        let wanted = budget > 0 && http?.statusCode == 206
        completionHandler(wanted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let now = Date()
        let enough: Bool = lock.withLock { () -> Bool in
            if firstByteAt == nil { firstByteAt = now }
            received += data.count
            lastByteAt = now
            if tailStartedAt == nil, received >= warmupBytes {
                tailStartedAt = now
            } else if tailStartedAt != nil {
                tailBytes += data.count
            }
            guard let first = firstByteAt else { return false }
            return now.timeIntervalSince(first) >= budget
        }
        if enough { dataTask.cancel() }
    }

    func snapshot() -> Seen {
        lock.withLock { () -> Seen in
            let firstByteSeconds = firstByteAt.map { $0.timeIntervalSince(startedAt) } ?? 0

            // Хвост после разгона — самое честное, что у нас есть.
            if let tailStart = tailStartedAt, let last = lastByteAt, tailBytes > 0 {
                let seconds = last.timeIntervalSince(tailStart)
                if seconds > 0.05 {
                    return Seen(response: response,
                                bytesPerSecond: Double(tailBytes) / seconds,
                                firstByteSeconds: firstByteSeconds)
                }
            }
            // Разгон закончиться не успел (связь медленная или кусок кончился раньше) —
            // считаем по всему, что приехало. Хуже, чем по хвосту, но честнее нуля.
            if let first = firstByteAt, let last = lastByteAt, received > 0 {
                let seconds = last.timeIntervalSince(first)
                if seconds > 0.05 {
                    return Seen(response: response,
                                bytesPerSecond: Double(received) / seconds,
                                firstByteSeconds: firstByteSeconds)
                }
            }
            return Seen(response: response, bytesPerSecond: 0, firstByteSeconds: firstByteSeconds)
        }
    }
}
