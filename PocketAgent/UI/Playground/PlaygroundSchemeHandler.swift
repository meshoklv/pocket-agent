//
//  PlaygroundSchemeHandler.swift
//  PocketAgent
//
//  Отдаёт страницы площадки так, будто это настоящий сайт — но БЕЗ ЕДИНОГО ОТКРЫТОГО
//  ПОРТА и без выхода в сеть. Файлы берутся с диска, из выбранной папки проекта.
//
//  ⚠️⚠️ ЗАЧЕМ ЭТО ВООБЩЕ ПОНАДОБИЛОСЬ. Правка владельца: «сделай плейграунд полноценным
//  с поддержкой всего ваще — пусть модель делает сайты, игры, 3д модели».
//  Раньше страница открывалась как `file://`, и у неё НЕ БЫЛО ПРОИСХОЖДЕНИЯ (origin).
//  Браузер в таком режиме молча запрещает ровно то, из чего состоят сайты, игры и
//  трёхмерные сцены:
//    • `<script type="module">` и `import` — отказ по правилам общего происхождения;
//    • `fetch()`/XHR к соседнему файлу (уровни игры, сцена, JSON) — запрещены;
//    • Web Worker — не создаётся вовсе;
//    • текстура WebGL из соседней картинки «портит» холст (tainted canvas) — сцена гаснет;
//    • localStorage/IndexedDB ведут себя непредсказуемо.
//  Человеку это видно как «модель написала игру, а она не работает» — и он винит модель.
//
//  ⚠️⚠️ ПОЧЕМУ НЕ ЛОКАЛЬНЫЙ ВЕБ-СЕРВЕР, ХОТЯ ЭТО «ПРОЩЕ». Сервер — это слушающий сокет.
//  Сервис без пароля на порту уже стоил нам взлома (правило №00.1), и на телефоне это
//  ровно та же дыра: любое приложение и любой сосед по Wi-Fi постучится в наш порт и
//  прочитает папку человека. Обработчик схемы живёт ВНУТРИ движка страницы: снаружи
//  до него не дотянуться никак, порт не открывается ни на миллисекунду.
//
//  ⚠️ ГРАНИЦА ПАПКИ ЗДЕСЬ — ТАКАЯ ЖЕ, КАК У ИНСТРУМЕНТОВ МОДЕЛИ. Свою проверку путей
//  не пишем: она однажды разойдётся с `SafePath` и окажется слабее. Зовём те же самые
//  примитивы (`sanitizeComponents`, `isSymbolicLink`, `isInside`, `ensureNotProtected`),
//  которыми закрыты дыры 08.09.2026.
//
//  ⚠️ ЧЕГО ЭТА СХЕМА НЕ ДАЁТ (говорим честно, чтобы следующий не искал): происхождение
//  считается НЕ защищённым (это не https), поэтому Service Worker и `crypto.subtle`
//  тут не заведутся. Для сайтов, игр и трёхмерных сцен они не нужны.
//

import Foundation
import WebKit

/// Выдача файлов площадки по собственной схеме `pa-play://page/<путь от корня папки>`.
final class PlaygroundSchemeHandler: NSObject, WKURLSchemeHandler {

    /// Имя схемы. Своё, не системное: перехватывать `http`/`file` WebKit не даёт,
    /// да и не нужно — нам важна не сеть, а НАЛИЧИЕ происхождения у страницы.
    static let scheme = "pa-play"

    /// Хост. Он же — вторая половина происхождения (`pa-play://page`).
    ///
    /// ⚠️ ХОСТ ЖЁСТКО ОДИН, И ЭТО НЕ ПРИДИРКА. Разный хост = разное происхождение:
    /// страница, открывшая `pa-play://другое/…`, оказалась бы в отдельной песочнице,
    /// и половина её же файлов перестала бы читаться. Плюс это лишняя развилка в
    /// проверке границ. Один хост — одна песочница, одна проверка.
    static let host = "page"

    /// Второй раздел того же адреса — ПОЛКА БИБЛИОТЕК, которая лежит внутри приложения.
    ///
    /// ⚠️ ЗАЧЕМ ОН ВООБЩЕ НУЖЕН. Сети у страницы нет намеренно, а модель по привычке
    /// пишет `<script src="https://cdn…/three.min.js">` — и страница остаётся пустой.
    /// Поэтому известные ссылки в интернет мы подменяем на `pa-play://lib/…`, и файл
    /// приезжает с полки, лежащей в самом приложении. Владелец 11.09.2026: «поставь
    /// все нужные библиотеки и такие, чтоб точно хватило на любой случай».
    static let libraryHost = "lib"

    /// Сколько отдаём за один кусок. Читать 300-мегабайтную сцену целиком в память
    /// на телефоне нельзя, а по кускам движок начинает рисовать, не дожидаясь конца.
    private static let chunkSize = 256 * 1024

    /// Корень папки проекта. Меняется, когда человек выбрал другую папку.
    private var root: URL
    /// Задачи, которые ещё живы. Отдавать данные снятой задаче — падение приложения.
    private var liveTasks = Set<ObjectIdentifier>()
    private let lock = NSLock()

    /// Диск трогаем в стороне от главного потока: страница на 200 МБ иначе заморозит
    /// экран, а вместе с ним и саму загрузку.
    /// ⚠️ Очередь ПАРАЛЛЕЛЬНАЯ нарочно. На последовательной один длинный кусок видео
    /// задерживал бы стили и картинки той же страницы — игра открывалась бы рывками.
    private let readQueue = DispatchQueue(label: "pocketagent.playground.files",
                                          qos: .userInitiated, attributes: .concurrent)

    init(root: URL) {
        self.root = SafePath.canonical(root)
        super.init()
    }

    /// Сменить папку проекта. Зовётся перед загрузкой страницы.
    func updateRoot(_ newRoot: URL) {
        lock.lock(); root = SafePath.canonical(newRoot); lock.unlock()
    }

    private var currentRoot: URL {
        lock.lock(); defer { lock.unlock() }
        return root
    }

    // MARK: - Разбор адреса в файл

    /// Чем закончился разбор адреса.
    enum Resolution {
        /// Файл найден и его можно отдавать.
        case ok(URL)
        /// Читать нельзя: за пределами папки, ссылка наружу, служебный файл.
        case forbidden(String)
        /// Внутри папки, но такого файла нет.
        case notFound(String)
    }

    /// Превратить адрес страницы в файл на диске — со всеми проверками границы.
    ///
    /// ⚠️ НАРОЧНО СТРОГО, БЕЗ «УГАДЫВАНИЯ». `SafePath.resolve` умеет прощать модели
    /// лишнее имя папки в начале пути — там это спасает разговор. Здесь путь пишет не
    /// человек и не модель, а сама страница (`<img src="…">`), и угадывание означало бы
    /// «отдал не тот файл». Поэтому берём из SafePath только ПРОВЕРКИ, а склейку делаем
    /// сами и в одну сторону.
    static func resolve(_ url: URL, root: URL) -> Resolution {
        guard url.scheme?.lowercased() == scheme else {
            return .forbidden("чужая схема адреса")
        }
        let section = (url.host ?? "").lowercased()
        if section == libraryHost {
            return resolveShelf(url)
        }
        guard section == host else {
            return .forbidden("чужой хост в адресе площадки")
        }

        // `url.path` уже раскодирован из процентов — имена по-русски приходят как есть.
        let rawPath = url.path
        let components: [String]
        do {
            components = try SafePath.sanitizeComponents(rawPath)
        } catch {
            // Управляющие символы и нулевой байт в пути — это не опечатка, а попытка.
            return .forbidden("недопустимые символы в пути")
        }
        // ⚠️ «..» отклоняем ЦЕЛИКОМ, а не схлопываем. Схлопывание тоже безопасно
        // (проверка границы ниже поймает выход), но тогда `../../чужое.html` вернул бы
        // «файл не найден» вместо честного «нельзя» — и мы бы не увидели попытки.
        guard !components.contains("..") else {
            return .forbidden("путь ведёт за пределы папки проекта")
        }
        guard !components.isEmpty else {
            // Голый `pa-play://page/` — это папка, а не страница.
            return .notFound("адрес без имени файла")
        }

        let canonicalRoot = SafePath.canonical(root)

        // ⚠️⚠️ ССЫЛКУ ЗАПРЕЩАЕМ НА КАЖДОМ ШАГЕ, А НЕ ТОЛЬКО В КОНЦЕ. Это дословно
        // повторяет дыру, найденную в SafePath 08.09.2026: «ссылка-на-чужую-папку/
        // файл.png» лежит внутри папки по написанию, но читается снаружи. Ссылки мы
        // не разворачиваем принципиально — «наружу нельзя» значит «нельзя».
        var walk = canonicalRoot
        for component in components {
            walk = walk.appendingPathComponent(component)
            if SafePath.isSymbolicLink(walk) {
                return .forbidden("на пути символическая ссылка — читать по ней нельзя")
            }
        }

        var target = walk.standardizedFileURL
        // Граница — той же проверкой по компонентам, что и везде в приложении.
        guard SafePath.isInside(target, root: canonicalRoot) else {
            return .forbidden("файл за пределами папки проекта")
        }
        // Служебные папки и секреты закрыты так же, как для модели: .git/config и .env
        // не должны утечь ни в контекст модели, ни в страницу, которую та написала.
        do {
            try SafePath.ensureNotProtected(target, root: canonicalRoot, rawPath: rawPath)
        } catch {
            return .forbidden("это служебный файл, показывать его нельзя")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            // ⚠️⚠️ ЗАПАСНОЙ ПУТЬ: БИБЛИОТЕКА, ЗАПРОШЕННАЯ КАК СОСЕД ПО ПАПКЕ.
            // Маленькая модель почти всегда пишет `<script src="three.min.js">` —
            // просто имя файла, без адреса. Подменять такую ссылку заранее нельзя
            // (относительный путь — это и правда сосед по папке человека), и до
            // 11.09.2026 она честно превращалась в 404: площадка считала страницу
            // сломанной и отправляла помощнику «почини», а чинить было нечего.
            // Теперь так: у человека такого файла НЕТ — отдаём одноимённый с полки.
            //
            // ⚠️ ПОРЯДОК ИМЕННО ТАКОЙ, И ЭТО ВАЖНО. Сначала папка человека, полка —
            // только если там пусто. Свой `three.min.js` рядом со страницей обязан
            // выигрывать у нашего: это его файл, его версия, его правки.
            //
            // ⚠️ ГРАНИЦУ ЭТО НЕ ОСЛАБЛЯЕТ. Наружу мы не выходим ни на шаг: берётся
            // ТОЛЬКО имя файла (папки из запроса выброшены), и ищется оно ТОЛЬКО
            // среди путей описи, которые собираются внутри папки полки.
            if let name = components.last, let fromShelf = Self.shelfTwin(ofFileName: name) {
                return .ok(fromShelf)
            }
            return .notFound("файла нет: \(components.joined(separator: "/"))")
        }
        if isDirectory.boolValue {
            // Сайт из нескольких страниц обычно ссылается на папку («игра/»), подразумевая
            // index.html внутри. Без этого половина ссылок обычного сайта мертва.
            let index = target.appendingPathComponent("index.html")
            guard !SafePath.isSymbolicLink(index),
                  FileManager.default.fileExists(atPath: index.path) else {
                return .notFound("в папке нет index.html")
            }
            target = index
        }
        return .ok(target)
    }

    /// Одноимённый файл с полки — для ссылки вида `<script src="three.min.js">`.
    ///
    /// ⚠️ ТОЛЬКО КОД И ОФОРМЛЕНИЕ. Картинку, звук или текстовый файл с полки
    /// подставлять нельзя: страница просила СВОЙ файл, и «нашёлся похожий у нас» —
    /// это подлог, а не помощь. Библиотеку подставить честно: другой такой на полке
    /// нет и быть не может, а без неё страница просто мертва.
    /// - Returns: `nil`, если такого имени на полке нет — тогда пусть будет честный 404.
    static func shelfTwin(ofFileName name: String) -> URL? {
        let ext = (name.split(separator: ".").last.map { String($0) } ?? "").lowercased()
        guard ["js", "mjs", "css"].contains(ext) else { return nil }
        let shelf = PlaygroundShelf.shared
        guard let path = shelf.shelfPath(forFileName: name) else { return nil }
        return shelf.fileURL(forShelfPath: path)
    }

    /// Найти файл на полке библиотек — она лежит В ПРИЛОЖЕНИИ, а не в папке человека.
    ///
    /// ⚠️ ПРОВЕРЯЕМ ТАК ЖЕ СТРОГО, ХОТЯ ПАПКА НАША. Адрес сюда пишет страница, а её
    /// сочинила модель: `pa-play://lib/../../документы/тайна.txt` — ровно та попытка,
    /// ради которой проверка и существует. Своей папке доверяем не больше чужой.
    static func resolveShelf(_ url: URL) -> Resolution {
        guard let shelfRoot = PlaygroundShelf.shared.rootURL else {
            return .notFound("полка библиотек не доехала до приложения")
        }
        let components: [String]
        do {
            components = try SafePath.sanitizeComponents(url.path)
        } catch {
            return .forbidden("недопустимые символы в пути к библиотеке")
        }
        guard !components.contains("..") else {
            return .forbidden("путь ведёт за пределы полки")
        }
        guard !components.isEmpty else {
            return .notFound("адрес без имени файла")
        }
        var target = shelfRoot
        for component in components {
            target = target.appendingPathComponent(component)
        }
        target = target.standardizedFileURL
        guard SafePath.isInside(target, root: SafePath.canonical(shelfRoot)) else {
            return .forbidden("файл за пределами полки")
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            return .notFound("такой библиотеки на полке нет: \(components.joined(separator: "/"))")
        }
        return .ok(target)
    }

    /// Адрес файла НА ПОЛКЕ — им подменяются ссылки в интернет.
    static func libURL(forShelfPath path: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        var encoded: [String] = []
        for part in path.split(separator: "/") {
            guard let piece = String(part).addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            encoded.append(piece)
        }
        guard !encoded.isEmpty else { return nil }
        return URL(string: "\(scheme)://\(libraryHost)/" + encoded.joined(separator: "/"))
    }

    /// Адрес, по которому надо открыть файл из папки проекта.
    /// - Returns: `nil`, если файл лежит вне папки — тогда открывать его нельзя вовсе.
    static func pageURL(forFile fileURL: URL, root: URL) -> URL? {
        let canonicalRoot = SafePath.canonical(root)
        let canonicalFile = SafePath.canonical(fileURL)
        let parts = SafePath.relativeComponents(of: canonicalFile, root: canonicalRoot)
        guard !parts.isEmpty else { return nil }
        // Кодируем ПОКОМПОНЕНТНО: иначе слэш внутри имени файла превратился бы в
        // разделитель пути, и «папка/имя-с-слэшем» уехало бы не туда.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        var encoded: [String] = []
        for part in parts {
            guard let piece = part.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            encoded.append(piece)
        }
        return URL(string: "\(scheme)://\(host)/" + encoded.joined(separator: "/"))
    }

    // MARK: - Тип содержимого

    /// Чем оно является для браузера.
    ///
    /// ⚠️ ДЛЯ `.js`/`.mjs` ТИП ОБЯЗАН БЫТЬ `text/javascript`. При любом другом типе
    /// браузер ОТКАЗЫВАЕТСЯ выполнять модуль (строгая проверка типа для `type="module"`)
    /// — а модули и есть то, ради чего затеяна вся эта правка.
    static let contentTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "wasm": "application/wasm",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "gif": "image/gif",
        "bmp": "image/bmp",
        "ico": "image/x-icon",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "oga": "audio/ogg",
        "m4a": "audio/mp4",
        "aac": "audio/aac",
        "flac": "audio/flac",
        "mp4": "video/mp4",
        "webm": "video/webm",
        "mov": "video/quicktime",
        "m4v": "video/x-m4v",
        // Трёхмерные сцены — прямая просьба владельца «пусть модель делает 3д модели».
        "glb": "model/gltf-binary",
        "gltf": "model/gltf+json",
        "obj": "model/obj",
        "mtl": "model/mtl",
        "stl": "model/stl",
        "usdz": "model/vnd.usdz+zip",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "txt": "text/plain; charset=utf-8",
        "md": "text/markdown; charset=utf-8",
        "csv": "text/csv; charset=utf-8",
        "xml": "text/xml; charset=utf-8",
        "webmanifest": "application/manifest+json",
        "pdf": "application/pdf"
    ]

    static func contentType(for url: URL) -> String {
        contentTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }

    // MARK: - Запрос по кускам

    /// Что именно просят отдать.
    enum RangeRequest: Equatable {
        case whole
        case part(start: Int64, length: Int64)
        /// Просят кусок, которого в файле нет.
        case unsatisfiable
    }

    /// Разобрать заголовок `Range`.
    ///
    /// ⚠️⚠️ БЕЗ ЭТОГО SAFARI НЕ ИГРАЕТ НИ ЗВУК, НИ ВИДЕО. Проигрыватель WebKit сначала
    /// просит кусок файла и, не получив ответа «отдаю кусок» (206), считает источник
    /// непригодным и молчит. Игра со звуком выглядела бы просто немой — и это списали
    /// бы на модель, а не на нас.
    static func parseRange(_ header: String?, totalSize: Int64) -> RangeRequest {
        guard let header, !header.isEmpty else { return .whole }
        let trimmed = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("bytes=") else { return .whole }
        // Составные запросы («bytes=0-10,20-30») в жизни от проигрывателя не приходят;
        // берём первый кусок — это разрешено правилами и понятнее, чем отказ.
        let pieces = trimmed.dropFirst("bytes=".count)
            .split(separator: ",", omittingEmptySubsequences: true)
        guard let firstPiece = pieces.first else { return .whole }
        let spec = String(firstPiece).trimmingCharacters(in: .whitespaces)
        guard let dash = spec.firstIndex(of: "-") else { return .whole }
        let head = String(spec[spec.startIndex..<dash])
        let tail = String(spec[spec.index(after: dash)...])

        guard totalSize > 0 else { return .unsatisfiable }

        if head.isEmpty {
            // «bytes=-500» — последние 500 байт.
            guard let suffix = Int64(tail), suffix > 0 else { return .unsatisfiable }
            let length = min(suffix, totalSize)
            return .part(start: totalSize - length, length: length)
        }
        guard let start = Int64(head), start >= 0, start < totalSize else { return .unsatisfiable }
        if tail.isEmpty {
            return .part(start: start, length: totalSize - start)
        }
        guard let end = Int64(tail), end >= start else { return .unsatisfiable }
        let last = min(end, totalSize - 1)
        return .part(start: start, length: last - start + 1)
    }

    // MARK: - Работа обработчика

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        lock.lock(); liveTasks.insert(key); lock.unlock()

        guard let url = urlSchemeTask.request.url else {
            // Адреса нет вовсе — отдавать отказ некуда, просто отпускаем задачу,
            // иначе страница будет ждать ответа вечно.
            onMainIfLive(urlSchemeTask) { $0.didFailWithError(Self.readError()) }
            retire(urlSchemeTask)
            return
        }
        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
        let root = currentRoot

        readQueue.async { [weak self] in
            guard let self else { return }
            switch Self.resolve(url, root: root) {
            case .forbidden(let why):
                // ⚠️ ОТКАЗ — ЧЕСТНЫЙ ОТВЕТ, А НЕ МОЛЧАНИЕ. Молча брошенная задача выглядит
                // для страницы как вечная загрузка, наш сторож её не видит, и человеку
                // никто ничего не скажет. 403 со страницей-объяснением видят оба.
                self.deliverError(to: urlSchemeTask, url: url, status: 403, reason: why)
            case .notFound(let why):
                self.deliverError(to: urlSchemeTask, url: url, status: 404, reason: why)
            case .ok(let file):
                // ⚠️ СТРАНИЦУ ОТДАЁМ, ПОДМЕНИВ В НЕЙ ССЫЛКИ НА ПОЛКУ. Другого места
                // для подмены нет: браузер должен увидеть уже исправленный адрес,
                // иначе он пойдёт в интернет, которого у него нет, и страница
                // останется голой. Меняется только значение `src`/`href` у знакомых
                // библиотек — авторский текст не трогаем. Не изменилось ничего —
                // отдаём файл как есть, байт в байт.
                if Self.looksLikeMarkdown(file), let page = Self.htmlForMarkdown(file) {
                    // Записку показываем страницей — иначе человек увидит решётки.
                    self.deliverResponse(status: 200,
                                         headers: ["Content-Type": "text/html; charset=utf-8",
                                                   "Cache-Control": "no-store",
                                                   "Content-Length": String(page.count)],
                                         body: page, url: url, to: urlSchemeTask)
                } else if Self.looksLikeHTML(file), let page = Self.rewrittenHTML(of: file) {
                    self.deliverResponse(status: 200,
                                         headers: ["Content-Type": "text/html; charset=utf-8",
                                                   "Cache-Control": "no-store",
                                                   "Content-Length": String(page.count)],
                                         body: page, url: url, to: urlSchemeTask)
                } else {
                    self.deliverFile(file, url: url, rangeHeader: rangeHeader, to: urlSchemeTask)
                }
            }
        }
    }

    /// Это страница, в которой имеет смысл искать ссылки на библиотеки?
    static func looksLikeHTML(_ url: URL) -> Bool {
        ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    /// Это записка, которую надо превратить в страницу?
    static func looksLikeMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    /// Завернуть записку в страницу и оформить её библиотекой с полки.
    ///
    /// ⚠️ ПОЧЕМУ ВООБЩЕ ЗАВОРАЧИВАЕМ. Отдать `.md` как есть — значит показать человеку
    /// решётки и звёздочки: движок такой файл не оформляет. Помощник же пишет записки
    /// (план, разбор, список дел) постоянно, и смотреть их на площадке — самое
    /// естественное желание. Разметку разбирает `marked` с полки, оформление даёт
    /// `pico.css` оттуда же — сети для этого не нужно.
    /// ⚠️ Текст записки кладём в страницу как ДАННЫЕ (в `<script type="text/plain">`),
    /// а не подставляем в разметку: иначе `<script>` внутри записки выполнился бы,
    /// и чужая записка стала бы чужим кодом.
    static func htmlForMarkdown(_ file: URL) -> Data? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let shelf = PlaygroundShelf.shared
        // Закрывающий тег внутри данных разорвал бы страницу — единственная опасная
        // последовательность, и её достаточно разбить, не портя текст.
        let safe = text.replacingOccurrences(of: "</script", with: "<\\/script")
        let markedTag = shelf.scriptTag(forLibraryId: "marked") ?? ""
        let styleTag = shelf.styleTag(forLibraryId: "pico") ?? shelf.styleTag(forLibraryId: "water") ?? ""
        let page = """
        <!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(file.lastPathComponent)</title>
        \(styleTag)
        <style>body{max-width:44rem;margin:0 auto;padding:1rem 1.2rem}</style>
        \(markedTag)
        </head><body><main id="текст"></main>
        <script id="исходник" type="text/plain">\(safe)</script>
        <script>
        var сырое = document.getElementById('исходник').textContent;
        var место = document.getElementById('текст');
        if (window.marked && marked.parse) { место.innerHTML = marked.parse(сырое); }
        else { var pre = document.createElement('pre'); pre.textContent = сырое; место.appendChild(pre); }
        </script></body></html>
        """
        return page.data(using: .utf8)
    }

    /// Текст страницы с подменёнными ссылками. `nil` — менять было нечего.
    static func rewrittenHTML(of file: URL) -> Data? {
        let shelf = PlaygroundShelf.shared
        guard shelf.hasAnything else { return nil }
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let outcome = PlaygroundLibraryRewrite.rewrite(html: raw, shelf: shelf)
        guard outcome.changed else { return nil }
        return outcome.html.data(using: .utf8)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // ⚠️⚠️ ПОСЛЕ ЭТОГО ЗАДАЧЕ НЕЛЬЗЯ СЛАТЬ НИЧЕГО. Один `didReceive` после снятия —
        // и приложение падает с исключением WebKit. Поэтому единственный признак
        // «жива» держим здесь, а выдача перед КАЖДЫМ шагом его перечитывает.
        lock.lock(); liveTasks.remove(ObjectIdentifier(urlSchemeTask)); lock.unlock()
    }

    /// Жива ли ещё задача.
    ///
    /// ⚠️ Опознаём по адресу объекта. Это надёжно ровно потому, что мы всегда убираем
    /// запись — и при снятии, и при завершении: «повисшей» записи, под которую мог бы
    /// попасть новый объект по тому же адресу, не остаётся.
    private func isLive(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveTasks.contains(ObjectIdentifier(task))
    }

    private func retire(_ task: WKURLSchemeTask) {
        lock.lock(); liveTasks.remove(ObjectIdentifier(task)); lock.unlock()
    }

    /// Сделать что-то с задачей на главном потоке, если она ещё жива.
    ///
    /// ⚠️ ПОЧЕМУ ЧЕРЕЗ ГЛАВНЫЙ ПОТОК И СИНХРОННО. Снятие задачи (`stop`) WebKit зовёт
    /// на главном потоке. Если выдавать данные с чужого потока, между проверкой «жива»
    /// и самой выдачей помещается снятие — и это падение. Один поток на оба события
    /// убирает гонку целиком, а синхронность заодно держит порядок кусков.
    /// Главный поток нас не ждёт, так что взаимной блокировки тут быть не может.
    @discardableResult
    private func onMainIfLive(_ task: WKURLSchemeTask, _ body: (WKURLSchemeTask) -> Void) -> Bool {
        // ⚠️ Замыкание НЕ выносим в переменную: `body` приезжает сюда как несбегающее,
        // и присвоение его в локальную переменную-функцию Swift не разрешает.
        if Thread.isMainThread {
            guard isLive(task) else { return false }
            body(task)
            return true
        }
        return DispatchQueue.main.sync {
            guard isLive(task) else { return false }
            body(task)
            return true
        }
    }

    /// Отдать файл — целиком или куском.
    private func deliverFile(_ file: URL, url: URL, rangeHeader: String?, to task: WKURLSchemeTask) {
        let size: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            deliverError(to: task, url: url, status: 404, reason: "файл не читается")
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: file) else {
            deliverError(to: task, url: url, status: 403, reason: "файл не открывается на чтение")
            return
        }
        defer { try? handle.close() }

        let type = Self.contentType(for: file)
        let requested = Self.parseRange(rangeHeader, totalSize: size)

        var status = 200
        var start: Int64 = 0
        var length: Int64 = size
        var headers: [String: String] = [
            "Content-Type": type,
            // Говорим проигрывателю, что куски мы умеем. Без этого он даже не попросит.
            "Accept-Ranges": "bytes",
            // ⚠️ БЕЗ КЭША НАРОЧНО. Площадка перезагружает страницу сразу после того,
            // как человек принял правку помощника. Отдай мы старую копию из памяти
            // движка — он увидел бы «ничего не изменилось» и решил, что починка не
            // работает. Файл лежит рядом на диске, экономить тут нечего.
            "Cache-Control": "no-store",
            // Своё же происхождение. Нужно там, где страница читает свои файлы из
            // рабочего потока или из кадра: у них происхождение считается отдельно.
            // Наружу это ничего не открывает — в этом движке других источников нет,
            // сеть перекрыта правилами, а отдаём мы только файлы этой самой папки.
            "Access-Control-Allow-Origin": "*"
        ]

        switch requested {
        case .whole:
            headers["Content-Length"] = String(size)
        case .part(let from, let count):
            status = 206
            start = from
            length = count
            headers["Content-Length"] = String(count)
            headers["Content-Range"] = "bytes \(from)-\(from + count - 1)/\(size)"
        case .unsatisfiable:
            var wrong = headers
            wrong["Content-Range"] = "bytes */\(size)"
            wrong["Content-Length"] = "0"
            deliverResponse(status: 416, headers: wrong, body: Data(), url: url, to: task)
            return
        }

        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else {
            deliverError(to: task, url: url, status: 500, reason: "не собрался ответ")
            return
        }

        guard onMainIfLive(task, { $0.didReceive(response) }) else { retire(task); return }

        if length > 0 {
            if start > 0 {
                do { try handle.seek(toOffset: UInt64(start)) } catch {
                    // Заголовки уже ушли — остаётся закончить ошибкой, иначе страница
                    // будет ждать данные вечно.
                    onMainIfLive(task, { $0.didFailWithError(Self.readError()) })
                    retire(task)
                    return
                }
            }
            var left = length
            while left > 0 {
                let piece = Int(min(Int64(Self.chunkSize), left))
                let data: Data
                do {
                    data = try handle.read(upToCount: piece) ?? Data()
                } catch {
                    onMainIfLive(task, { $0.didFailWithError(Self.readError()) })
                    retire(task)
                    return
                }
                if data.isEmpty { break }   // файл кончился раньше, чем обещал размер
                left -= Int64(data.count)
                // Задачу могли снять посреди выдачи — тогда просто уходим молча.
                guard onMainIfLive(task, { $0.didReceive(data) }) else { retire(task); return }
            }
        }

        onMainIfLive(task, { $0.didFinish() })
        retire(task)
    }

    /// Честный отказ, который видно и странице, и нашему сторожу.
    /// Страница отказа — ЕДИНСТВЕННОЕ место обработчика, которое видит живой человек.
    ///
    /// ⚠️ ПОЭТОМУ ЗДЕСЬ ЧЕЛОВЕЧЕСКИЕ СЛОВА, А НЕ НАШИ. Инженерная причина («чужой хост
    /// в адресе площадки», «недопустимые символы в пути») человеку не говорит ничего
    /// и нарушает правило языка всего приложения. Переводим её в одну понятную фразу,
    /// а саму причину оставляем мелким шрифтом — она нужна, когда страницу чинит
    /// помощник, и не мешает, когда читает человек.
    private static func humanReason(_ reason: String, status: Int) -> String {
        let lower = reason.lowercased()
        if lower.contains("полка") { return "Библиотека не доехала вместе с приложением." }
        if lower.contains("ссылк") { return "Этот файл — ярлык на что-то вне папки проекта. По ярлыкам наружу мы не ходим." }
        if lower.contains("служебн") || lower.contains(".git") { return "Это служебный файл проекта — показывать его нельзя." }
        if lower.contains("предел") || lower.contains("хост") || lower.contains("символ") {
            return "Страница просит файл за пределами папки проекта. Наружу площадка не выходит."
        }
        if status == 404 { return "Такого файла рядом нет — проверьте имя в ссылке." }
        return "Открыть не получилось."
    }

    private func deliverError(to task: WKURLSchemeTask, url: URL, status: Int, reason: String) {
        let text = """
        <!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width, initial-scale=1">\
        <title>Не открылось</title></head>\
        <body style="font-family:system-ui;background:#111;color:#eee;padding:24px;line-height:1.5">\
        <h1 style="font-size:20px;margin:0 0 8px">Страница не открылась</h1>\
        <p style="margin:0 0 16px">\(Self.escaped(Self.humanReason(reason, status: status)))</p>\
        <p style="font-size:13px;opacity:.55;margin:0">\(Self.escaped(reason))</p></body></html>
        """
        let body = Data(text.utf8)
        deliverResponse(status: status,
                        headers: ["Content-Type": "text/html; charset=utf-8",
                                  "Content-Length": String(body.count),
                                  "Cache-Control": "no-store"],
                        body: body, url: url, to: task)
    }

    private func deliverResponse(status: Int, headers: [String: String],
                                 body: Data, url: URL, to task: WKURLSchemeTask) {
        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else {
            onMainIfLive(task, { $0.didFailWithError(Self.readError()) })
            retire(task)
            return
        }
        guard onMainIfLive(task, { $0.didReceive(response) }) else { retire(task); return }
        if !body.isEmpty {
            guard onMainIfLive(task, { $0.didReceive(body) }) else { retire(task); return }
        }
        onMainIfLive(task, { $0.didFinish() })
        retire(task)
    }

    private static func readError() -> NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile,
                userInfo: [NSLocalizedDescriptionKey: "файл площадки не прочитался"])
    }

    /// Причина отказа уходит в разметку — значит её надо обезвредить.
    /// В имени файла может стоять `<script>`, и тогда наша же страница отказа
    /// исполнила бы чужой код.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
