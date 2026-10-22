//
//  PlaygroundLibrary.swift
//  PocketAgent
//
//  ПОЛКА ГОТОВЫХ БИБЛИОТЕК: опись, поиск по ней и переписывание страницы.
//
//  ⚠️ ЗАЧЕМ ЭТО ВООБЩЕ ПОЯВИЛОСЬ. У страницы на площадке интернета нет намеренно —
//  она лежит в папке человека и наружу не ходит. А модель, обученная на обычном вебе,
//  пишет по привычке `<script src="https://cdn.jsdelivr.net/npm/three@0.169/…">` —
//  и человек получает пустой экран. Распоряжение владельца дословно: «Просто поставь
//  все нужные библиотеки и такие, чтоб точно хватило на любой случай». Значит файлы
//  лежат ВНУТРИ приложения, а знакомый интернет-адрес мы молча подменяем на свой.
//
//  ⚠️ ЧТО ЗДЕСЬ НЕ ДЕЛАЕТСЯ И ПОЧЕМУ. Мы НЕ заменяем строки по всему файлу подряд.
//  Подмена идёт только в значениях `src` у `<script>` и `href` у `<link>` — авторский
//  текст, комментарии и содержимое скриптов остаются дословно теми же. Замена «по
//  всему файлу» однажды переписала бы адрес внутри абзаца, который человек читает.
//
//  ⚠️ И НЕ ПОДМЕНЯЕМ НЕЗНАКОМОЕ. Нет библиотеки на полке — адрес остаётся как есть,
//  страница честно жалуется «тянет оформление из интернета». Иначе подмена стала бы
//  дырой, прячущей настоящую попытку выйти в сеть.
//

import Foundation

// MARK: - Опись полки

/// Один файл библиотеки на полке.
///
/// ⚠️ Всё, кроме пути, необязательно НАМЕРЕННО: опись кладёт сюда другой человек
/// (в нашем случае — соседний агент), и одно недостающее поле не должно ронять
/// разбор всей описи. Лучше полка без подсказки, чем полка, которой нет.
struct PlaygroundShelfFile: Decodable {
    let path: String
    /// `umd` — обычный скрипт, который кладёт себя в `window`; `module` — для `import`.
    let form: String?
    /// Как библиотека называет себя в `window` (для `umd`).
    let global: String?
}

/// Одна библиотека на полке.
struct PlaygroundShelfLibrary: Decodable {
    let id: String?
    let name: String?
    let version: String?
    let kind: String?
    let files: [PlaygroundShelfFile]?
    /// Голые имена для `import` — `three`, `three/addons/`.
    let bare: [String]?
    /// Знакомые интернет-адреса без схемы: `cdn.jsdelivr.net/npm/three`.
    let cdn: [String]?
    let license: String?
    let licenseFile: String?
    let bytes: Int?
    let hint: String?

    /// Служебная ли это запись — такую модели показывать незачем.
    ///
    /// ⚠️ СЕЙЧАС ТАКИХ ЗАПИСЕЙ НА ПОЛКЕ НЕТ, И ЭТО НАРОЧНО. Раньше рядом лежала
    /// заглушка `pa-selfcheck`, но в опись её так и не внесли — значит признак не
    /// срабатывал ни разу, а два файла всё равно ехали в приложение мёртвым грузом.
    /// Заглушку убрали: самопроверка площадки и без неё доказывает подмену на
    /// настоящем `three` (и обычной сборкой, и голым именем в модуле). Признак
    /// оставлен как замок на будущее — появится служебная запись, она сразу будет
    /// скрыта от модели, а не всплывёт в её инструкции.
    var isInternal: Bool { (kind ?? "").lowercased() == "selfcheck" }

    /// Как назвать библиотеку модели: коротко и узнаваемо.
    var shortName: String { name ?? id ?? "" }

    /// Какой файл отдать по этому адресу.
    ///
    /// ⚠️ Выбор не «первый попавшийся»: для `<link>` нужен стиль, для `import` —
    /// модульная сборка, для обычного `<script>` — та, что кладёт себя в `window`.
    /// Ошибиться тут значит отдать страницу, которая молча не работает.
    func pick(css: Bool, module: Bool) -> PlaygroundShelfFile? {
        let all = files ?? []
        if css { return all.first { $0.path.lowercased().hasSuffix(".css") } }
        let scripts = all.filter { !$0.path.lowercased().hasSuffix(".css") }
        let asModule = scripts.first { ($0.form ?? "").lowercased() == "module" }
        let asPlain = scripts.first { ($0.form ?? "").lowercased() == "umd" }
        if module { return asModule ?? asPlain ?? scripts.first }
        return asPlain ?? asModule ?? scripts.first
    }
}

private struct PlaygroundShelfManifest: Decodable {
    let generatedAt: String?
    let libraries: [PlaygroundShelfLibrary]?
}

// MARK: - Сама полка

/// Полка: читается ОДИН раз за запуск и живёт дальше в памяти.
///
/// ⚠️ Один раз — это требование, а не украшение. Опись нужна на каждый показ
/// страницы и на каждый файл, который страница просит; перечитывать её с диска
/// по десять раз на кадр — верный способ подвесить площадку на ровном месте.
final class PlaygroundShelf {

    /// Единственная полка приложения.
    static let shared = PlaygroundShelf()

    /// Библиотеки, которые удалось разобрать.
    let libraries: [PlaygroundShelfLibrary]
    /// Папка полки внутри приложения (nil — полки нет).
    let rootURL: URL?
    /// Почему полка пуста — человеческими словами, для самопроверки.
    let problem: String?

    /// Есть ли на полке хоть что-то.
    var hasAnything: Bool { !libraries.isEmpty && rootURL != nil }

    private init() {
        guard let root = Self.findRoot() else {
            libraries = []
            rootURL = nil
            problem = "папки PlaygroundLib нет в приложении — опись читать негде"
            return
        }
        rootURL = root
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            libraries = []
            problem = "manifest.json не прочитался"
            return
        }
        guard let parsed = try? JSONDecoder().decode(PlaygroundShelfManifest.self, from: data) else {
            libraries = []
            problem = "manifest.json не разобрался — похоже, там не та опись"
            return
        }
        // ⚠️ Записи без имени выбрасываем поштучно, а не роняем всю опись: соседний
        // агент дописывает её параллельно, и одна кривая строка не должна оставить
        // площадку без всех остальных библиотек.
        libraries = (parsed.libraries ?? []).filter { !($0.id ?? "").isEmpty }
        problem = libraries.isEmpty ? "в описи нет ни одной библиотеки" : nil
    }

    /// Где лежит полка.
    ///
    /// ⚠️ ДВА ПУТИ, И ВТОРОЙ — НЕ ПЕРЕСТРАХОВКА. Папка попадает в приложение
    /// ссылкой на папку (`type: folder` в project.yml), и тогда структура
    /// сохраняется. Но стоит кому-то подключить её обычной группой — сборщик
    /// разложит файлы ПЛОСКО, рядом друг с другом, и адрес `three/three.min.js`
    /// не найдёт ничего. Второй путь ищет опись рядом с остальными ресурсами,
    /// а поиск файла ниже умеет искать по одному лишь имени.
    private static func findRoot() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let folder = resources.appendingPathComponent("PlaygroundLib", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) {
            return folder
        }
        if FileManager.default.fileExists(atPath: resources.appendingPathComponent("manifest.json").path) {
            return resources
        }
        return nil
    }

    // MARK: Файлы полки

    /// Найти файл на полке по пути из описи.
    ///
    /// ⚠️ ГРАНИЦА ПОЛКИ ДЕРЖИТСЯ НА СБОРКЕ ПУТИ, А НЕ НА СРАВНЕНИИ ПОТОМ.
    /// Если путь состоит только из обычных имён (без `..`, `.` и пустых), то
    /// приклеить их к папке полки и выйти за её пределы физически невозможно.
    /// Это надёжнее сравнения готовых путей: у сравнения есть свои ловушки
    /// (`/var` против `/private/var` на телефоне), и оно однажды солжёт.
    func fileURL(forShelfPath path: String) -> URL? {
        guard let rootURL else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        for part in parts where part == ".." || part == "." || part.isEmpty {
            return nil
        }
        var url = rootURL
        for part in parts { url.appendPathComponent(part) }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // Запасной путь для плоской раскладки — см. findRoot().
        if let last = parts.last {
            let flat = rootURL.appendingPathComponent(last)
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return nil
    }

    /// Адрес файла полки для страницы.
    static func address(forPath path: String) -> String {
        let parts = path.split(separator: "/").map { piece -> String in
            String(piece).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(piece)
        }
        // Хвостовой «/» значим: он отличает приставку от файла (см. importMapJSON).
        let tail = path.hasSuffix("/") ? "/" : ""
        return "\(PlaygroundSchemeHandler.scheme)://\(PlaygroundSchemeHandler.libraryHost)/"
            + parts.joined(separator: "/") + tail
    }

    // MARK: Поиск по знакомым адресам

    /// Куда увести знакомый интернет-адрес. `nil` — такой библиотеки у нас нет.
    ///
    /// - Parameters:
    ///   - raw: адрес из атрибута страницы, как его написала модель.
    ///   - wantsModule: тег помечен `type="module"` — значит нужна модульная сборка.
    func shelfAddress(forExternal raw: String, wantsModule: Bool) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var rest = trimmed.lowercased()
        if rest.hasPrefix("https://") {
            rest.removeFirst(8)
        } else if rest.hasPrefix("http://") {
            rest.removeFirst(7)
        } else if rest.hasPrefix("//") {
            rest.removeFirst(2)
        } else {
            return nil   // относительный путь — это сосед по папке, не наше дело
        }

        var best: (library: PlaygroundShelfLibrary, marker: String)?
        for library in libraries {
            for rawMarker in library.cdn ?? [] {
                let marker = rawMarker.lowercased()
                guard !marker.isEmpty, rest.hasPrefix(marker) else { continue }
                // ⚠️ ГРАНИЦА ИМЕНИ ОБЯЗАТЕЛЬНА, иначе `unpkg.com/three-mesh-bvh@1`
                // сойдёт за `three` — почему именно так, см. isNameBoundary.
                let after = rest.dropFirst(marker.count)
                guard Self.isNameBoundary(after) else { continue }
                if marker.count > (best?.marker.count ?? 0) {
                    best = (library, marker)
                }
            }
        }
        guard let found = best else { return nil }

        let pathOnly = rest.split(separator: "?").first.map(String.init) ?? rest
        let wantsCSS = pathOnly.hasSuffix(".css")
        let esm = wantsModule
            || pathOnly.contains(".module.")
            || pathOnly.contains("/esm/")
            || pathOnly.hasSuffix("+esm")
        guard let file = found.library.pick(css: wantsCSS, module: esm) else { return nil }
        return Self.address(forPath: file.path)
    }

    /// Кончилось ли имя библиотеки там, где кончился знакомый кусок адреса.
    ///
    /// ⚠️ ГРАНИЦА ИМЕНИ ОБЯЗАТЕЛЬНА. Без неё `unpkg.com/three-mesh-bvh@1` считался бы
    /// за `unpkg.com/three` — и страница получила бы совсем другую библиотеку, молча
    /// и без единой жалобы.
    ///
    /// ⚠️ ДЕФИС ПЕРЕД ЦИФРОЙ — ТОЖЕ ГРАНИЦА, И ЭТО НЕ ПОСЛАБЛЕНИЕ. Половина мира
    /// пишет jQuery адресом `code.jquery.com/jquery-3.7.1.min.js`: версия приклеена
    /// к имени дефисом, и по строгому правилу такой адрес не узнавался бы вовсе.
    /// А `three-mesh-bvh` по-прежнему отсекается: там после дефиса буква, а не цифра.
    private static func isNameBoundary(_ after: Substring) -> Bool {
        guard let first = after.first else { return true }   // адрес кончился ровно на имени
        if first == "@" || first == "/" || first == "?" || first == "#" { return true }
        if first == "-" {
            // `jquery-3.7.1.min.js` — да; `three-mesh-bvh` — нет.
            let next = after.dropFirst().first
            return next?.isNumber == true
        }
        return false
    }

    /// Найти на полке файл ПО ОДНОМУ ИМЕНИ — без папок и без адреса.
    ///
    /// ⚠️ ЗАЧЕМ ЭТО НУЖНО (дыра, найденная приёмщиком 11.09.2026). Маленькая модель
    /// почти всегда пишет `<script src="three.min.js">` — просто имя файла, как будто
    /// он лежит рядом. Такой адрес не подменяется (он относительный, это сосед по
    /// папке), файла в папке человека нет, страница получает 404, площадка считает
    /// это поломкой и отправляет помощнику «почини» — круг на ровном месте, а человек
    /// видит голую страницу. Поэтому: нет файла у человека — ищем это же имя у себя.
    ///
    /// ⚠️ УГАДЫВАНИЯ ЗДЕСЬ НЕТ. Сравниваем имя целиком (без учёта регистра) и только
    /// со списком из описи. Единственная поблажка — «сжатость»: `three.module.js`
    /// и `three.module.min.js` для модели одно и то же, и отдать сжатую сборку вместо
    /// несжатой честно. Ничего похожего «по смыслу» мы не подставляем: отдать не ту
    /// библиотеку хуже, чем честный 404.
    ///
    /// - Returns: путь внутри полки (`three/three.min.js`) или `nil`.
    func shelfPath(forFileName name: String) -> String? {
        let wanted = name.lowercased()
        guard !wanted.isEmpty, !wanted.contains("/") else { return nil }
        for library in libraries {
            for file in library.files ?? [] where Self.lastComponent(file.path) == wanted {
                return file.path
            }
        }
        // Второй заход — уже без «.min».
        let bare = wanted.replacingOccurrences(of: ".min.", with: ".")
        for library in libraries {
            for file in library.files ?? [] {
                let last = Self.lastComponent(file.path)
                if last.replacingOccurrences(of: ".min.", with: ".") == bare { return file.path }
            }
        }
        return nil
    }

    /// Последнее имя в пути, в нижнем регистре. Пустая строка — если пути нет.
    private static func lastComponent(_ path: String) -> String {
        guard let piece = path.split(separator: "/").last else { return "" }
        return String(piece).lowercased()
    }

    /// Готовый тег `<script src>` для библиотеки с полки. `nil` — её у нас нет.
    ///
    /// ⚠️ Нужен там, где страницу собираем МЫ САМИ (например, заворачиваем записку
    /// `.md` в страницу): подставлять адрес руками в трёх местах — верный способ
    /// однажды разойтись с описью.
    func scriptTag(forLibraryId id: String) -> String? {
        guard let library = libraries.first(where: { ($0.id ?? "") == id }),
              let file = library.pick(css: false, module: false)
                      ?? library.pick(css: false, module: true) else { return nil }
        return "<script src=\"\(Self.address(forPath: file.path))\"></script>"
    }

    /// Готовый тег `<link rel="stylesheet">` для оформления с полки.
    func styleTag(forLibraryId id: String) -> String? {
        guard let library = libraries.first(where: { ($0.id ?? "") == id }),
              let file = library.pick(css: true, module: false) else { return nil }
        return "<link rel=\"stylesheet\" href=\"\(Self.address(forPath: file.path))\">"
    }

    /// Карта соответствий для голых имён (`import * as THREE from 'three'`).
    ///
    /// ⚠️ Записи с хвостовым «/» — это ПРИСТАВКА, а не файл: браузер сам подставит
    /// продолжение (`three/addons/loaders/GLTFLoader.js`). Потерять этот «/» значит
    /// сломать все дополнения библиотеки разом, и заметно это будет не сразу.
    func importMapJSON() -> String? {
        var imports: [String: String] = [:]
        for library in libraries {
            for name in library.bare ?? [] where !name.isEmpty {
                if name.hasSuffix("/") {
                    imports[name] = Self.address(forPath: name)
                } else if let file = library.pick(css: false, module: true) {
                    imports[name] = Self.address(forPath: file.path)
                }
            }
        }
        guard !imports.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: ["imports": imports],
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: Что сказать модели

    /// Назначения по важности для инструкции — от самого частого к редкому.
    ///
    /// ⚠️ ПОРЯДОК ЗДЕСЬ — ЭТО ОТВЕТ НА ВОПРОС «ЗА ЧЕМ МОДЕЛЬ ТЯНЕТСЯ ЧАЩЕ ВСЕГО».
    /// Оформление страницы и графики она просит почти в каждой задаче, счётчик кадров —
    /// почти никогда. Восемь имён достаются сверху этого списка.
    private static let promptKindOrder = [
        "style", "chart", "3d", "game", "physics", "creative", "audio", "ui", "motion", "util"
    ]

    /// Кого называть представителем назначения, когда на полке их несколько.
    ///
    /// ⚠️ БЕЗ ЭТОГО СПИСКА ВЫБОР ДЕЛАЛА ОЧЕРЁДНОСТЬ ОПИСИ — и в инструкцию попадали
    /// ДВА объёмных движка физики подряд (`cannon-es` и `cannon.js`, одно и то же
    /// разными словами), а Bootstrap, Chart.js и D3 не попадали вовсе. Восемь мест
    /// слишком дороги, чтобы тратить их на двойников.
    private static let promptPreferred: [String: String] = [
        "style": "bootstrap",     // самое узнаваемое оформление
        "chart": "chart.js",      // графики одной строкой
        "3d": "three",
        "game": "phaser",
        "physics": "matter-js",   // плоская физика нужна чаще объёмной
        "creative": "p5",
        "audio": "tone",
        "ui": "alpinejs",
        "motion": "animejs",
        "util": "marked"
    ]

    /// Короткий перечень для системной инструкции.
    ///
    /// ⚠️ КОРОТКИЙ — ЭТО ТРЕБОВАНИЕ, А НЕ ВКУС. Длинные добавки в инструкцию у нас
    /// уже портили качество ответов, поэтому здесь только имена
    /// и не больше восьми: перечень нужен, чтобы модель ЗНАЛА о полке, а не чтобы
    /// пересказать ей опись.
    ///
    /// ⚠️ И ПО ОДНОМУ ПРЕДСТАВИТЕЛЮ НА НАЗНАЧЕНИЕ. Второе имя того же рода ничего
    /// модели не добавляет, а место у восьмёрки отнимает.
    var namesForPrompt: [String] {
        let usable = libraries.filter { !$0.isInternal && !$0.shortName.isEmpty }

        var byKind: [String: PlaygroundShelfLibrary] = [:]
        for library in usable {
            let kind = (library.kind ?? "").lowercased()
            if (library.id ?? "") == Self.promptPreferred[kind] {
                byKind[kind] = library            // назначенный представитель побеждает всегда
            } else if byKind[kind] == nil {
                byKind[kind] = library            // иначе — первый по описи
            }
        }

        var ordered: [String] = []
        for kind in Self.promptKindOrder {
            if let library = byKind.removeValue(forKey: kind) { ordered.append(library.shortName) }
        }
        // Назначения, которых в порядке нет (опись пополняется другими руками),
        // уходят в хвост — но по имени, чтобы перечень не менялся от запуска к запуску.
        ordered += byKind.values.map(\.shortName).sorted()
        return Array(ordered.prefix(8))
    }
}

// MARK: - Переписывание страницы

/// Переписывает знакомые интернет-адреса на адреса полки.
enum PlaygroundLibraryRewrite {

    /// Что вышло из переписывания.
    struct Outcome {
        let html: String
        /// Адреса, которые мы увели на полку. Пусто — не тронули ничего.
        let replaced: [String]
        /// Вставили ли карту соответствий для голых имён.
        let addedImportMap: Bool

        /// Изменилась ли страница вообще.
        ///
        /// ⚠️ ЭТИМ РЕШАЕТСЯ, КАКИМ ПУТЁМ ОТКРЫВАТЬ СТРАНИЦУ. Ничего не изменилось —
        /// открываем ровно так же, как открывали всегда (файлом с диска), и ни одна
        /// старая страница не замечает, что полка вообще появилась. Это осознанный
        /// способ не сломать то, что уже работает.
        var changed: Bool { !replaced.isEmpty || addedImportMap }
    }

    /// Разобранный открывающий тег.
    private struct Tag {
        let name: String
        /// Индекс СРАЗУ ЗА закрывающей скобкой тега.
        let end: Int
        /// Атрибуты: значение и где оно лежит в исходных символах.
        let attrs: [String: (value: String, start: Int, end: Int)]

        func value(_ key: String) -> String? { attrs[key]?.value }
    }

    static func rewrite(html: String, shelf: PlaygroundShelf) -> Outcome {
        guard shelf.hasAnything else {
            return Outcome(html: html, replaced: [], addedImportMap: false)
        }

        let source = Array(html)
        var out: [Character] = []
        out.reserveCapacity(source.count + 256)
        var replaced: [String] = []
        var firstScriptAt: Int?
        var sawModule = false
        var pageHasOwnImportMap = false

        var i = 0
        while i < source.count {
            guard source[i] == "<", let tag = readTag(source, from: i) else {
                out.append(source[i])
                i += 1
                continue
            }
            let type = (tag.value("type") ?? "").lowercased()
            if tag.name == "script" {
                if firstScriptAt == nil { firstScriptAt = out.count }
                if type == "module" { sawModule = true }
                if type == "importmap" { pageHasOwnImportMap = true }
            }
            var piece = Array(source[i..<tag.end])
            let attrName = tag.name == "link" ? "href" : "src"
            let asModule = type == "module"
                || (tag.value("rel") ?? "").lowercased() == "modulepreload"
            if let address = tag.value(attrName),
               let place = tag.attrs[attrName],
               let target = shelf.shelfAddress(forExternal: address, wantsModule: asModule) {
                // ⚠️ ТРОГАЕМ РОВНО ЗНАЧЕНИЕ АТРИБУТА. Ни кавычки, ни остальные
                // атрибуты, ни авторский текст вокруг тега не сдвигаются.
                piece.replaceSubrange((place.start - i)..<(place.end - i), with: Array(target))
                replaced.append(address)
            }
            out.append(contentsOf: piece)
            i = tag.end

            // ⚠️⚠️ ВТОРАЯ ДВЕРЬ В ИНТЕРНЕТ — ВНУТРИ САМОГО МОДУЛЯ, И ДО 11.09.2026
            // ОНА СТОЯЛА НАСТЕЖЬ. Самый ходовой способ подключить трёхмерку в коде
            // маленькой модели выглядит так:
            //
            //     <script type="module">
            //       import * as THREE from 'https://unpkg.com/three@0.160/build/three.module.js';
            //
            // Никакого `src` у тега нет, подменять нечего — и адрес уходил в сеть,
            // которой нет. Страница молчала, площадка звала помощника «почини»,
            // а чинить было нечего: код правильный.
            //
            // ⚠️ ТРОГАЕМ ТОЛЬКО СТРОКОВЫЙ ЛИТЕРАЛ АДРЕСА, а не тело скрипта целиком:
            // замена «по всему тексту» однажды переписала бы адрес в комментарии или
            // в строке, которую человек видит на экране.
            //
            // ⚠️ КАРТУ СООТВЕТСТВИЙ САМОЙ СТРАНИЦЫ ПРАВИМ ТОЖЕ. Если страница
            // принесла свою `importmap` с адресами в интернет, нашу мы не вставляем
            // (двух карт браузер не допускает) — значит её собственная карта и есть
            // единственный шанс; неисправленная, она ведёт ровно в ту же пустоту.
            if tag.name == "script", tag.value("src") == nil,
               type == "module" || type == "importmap" {
                let bodyEnd = closingScript(source, from: i) ?? source.count
                let body = String(source[i..<bodyEnd])
                let fixed = rewriteAddresses(inScript: body, shelf: shelf,
                                             // в карте соответствий адрес стоит просто
                                             // значением, никакого `import` перед ним нет
                                             requireImportBefore: type == "module",
                                             replaced: &replaced)
                out.append(contentsOf: Array(fixed))
                i = bodyEnd
            }
        }

        var addedMap = false
        // ⚠️ КАРТУ СТАВИМ ПЕРЕД ПЕРВЫМ СКРИПТОМ, А НЕ «ГДЕ-НИБУДЬ В ГОЛОВЕ».
        // Браузер обязан увидеть её ДО первого модуля, иначе голое имя `three`
        // он объявит неразрешимым — и страница не запустится вовсе.
        // Если карта у страницы своя — не лезем: двух карт браузер не допускает.
        if sawModule, !pageHasOwnImportMap, let place = firstScriptAt,
           let map = shelf.importMapJSON() {
            out.insert(contentsOf: Array("<script type=\"importmap\">\(map)</script>\n"), at: place)
            addedMap = true
        }

        let changed = addedMap || !replaced.isEmpty
        return Outcome(html: changed ? String(out) : html,
                       replaced: replaced,
                       addedImportMap: addedMap)
    }

    /// Где кончается тело скрипта — индекс символа `<` у `</script`.
    ///
    /// ⚠️ Ищем без учёта регистра: `</SCRIPT>` встречается в старых образцах, по
    /// которым обучена модель, и промах здесь съел бы остаток страницы.
    private static func closingScript(_ source: [Character], from start: Int) -> Int? {
        // ⚠️ Сравниваем строками, а не Character(…lowercased()): у части букв нижний
        // регистр состоит из ДВУХ знаков, и попытка собрать из них один символ
        // уронила бы приложение на ровном месте.
        let needle = Array("</script").map { String($0) }
        guard start >= 0, source.count >= needle.count else { return nil }
        var i = max(start, 0)
        while i + needle.count <= source.count {
            var match = true
            for k in 0..<needle.count where source[i + k].lowercased() != needle[k] {
                match = false
                break
            }
            if match { return i }
            i += 1
        }
        return nil
    }

    /// Подменить знакомые интернет-адреса ВНУТРИ тела скрипта.
    ///
    /// - Parameters:
    ///   - requireImportBefore: менять только там, где перед строкой стоит `import`
    ///     или `from`. Для тела модуля — да (иначе тронули бы любую строку подряд),
    ///     для карты соответствий — нет (там адрес стоит просто значением).
    ///
    /// ⚠️ РАЗБОР НАРОЧНО ТРУСЛИВЫЙ. Разобрать JavaScript по-настоящему мы тут не
    /// можем и не будем: любая непонятная кавычка, перевод строки внутри обычной
    /// строки или экранирование — повод НЕ ТРОГАТЬ и идти дальше. Худшее, что
    /// случится от такой осторожности, — адрес останется как был (это ровно то,
    /// что было до правки). Худшее от смелости — испорченный код на экране.
    private static func rewriteAddresses(inScript body: String,
                                         shelf: PlaygroundShelf,
                                         requireImportBefore: Bool,
                                         replaced: inout [String]) -> String {
        let chars = Array(body)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let quote = chars[i]
            guard quote == "\"" || quote == "'" || quote == "`" else {
                out.append(chars[i])
                i += 1
                continue
            }
            var j = i + 1
            var value = ""
            var closed = false
            var spoiled = false
            while j < chars.count {
                let c = chars[j]
                if c == "\\" { spoiled = true; break }        // экранирование — не наш случай
                if c == quote { closed = true; break }
                // Обычная строка не бывает многострочной: перевод строки означает,
                // что кавычка была не открывающей, а частью текста или комментария.
                if c == "\n", quote != "`" { break }
                value.append(c)
                j += 1
            }
            guard closed, !spoiled else {
                out.append(chars[i])
                i += 1
                continue
            }
            let target: String?
            if requireImportBefore, !precededByImport(chars, before: i) {
                target = nil
            } else {
                target = shelf.shelfAddress(forExternal: value, wantsModule: true)
            }
            if let target {
                out.append(quote)
                out.append(contentsOf: Array(target))
                out.append(quote)
                replaced.append(value)
            } else {
                // Литерал переписываем дословно — и целиком, чтобы кавычки не
                // разъехались на следующем проходе.
                out.append(contentsOf: chars[i...j])
            }
            i = j + 1
        }
        return String(out)
    }

    /// Стоит ли перед этой строкой `import`, `from` или `import(`.
    private static func precededByImport(_ chars: [Character], before start: Int) -> Bool {
        var k = start - 1
        while k >= 0, chars[k].isWhitespace { k -= 1 }
        guard k >= 0 else { return false }
        if chars[k] == "(" {            // динамический `import('адрес')`
            k -= 1
            while k >= 0, chars[k].isWhitespace { k -= 1 }
        }
        var word = ""
        while k >= 0, chars[k].isLetter {
            word.insert(chars[k], at: word.startIndex)
            k -= 1
        }
        return word == "from" || word == "import"
    }

    /// Прочитать открывающий тег `<script …>` или `<link …>`.
    ///
    /// ⚠️ ЧУЖИЕ ТЕГИ ВОЗВРАЩАЮТ nil НАМЕРЕННО — тогда внешний обход просто копирует
    /// символ и идёт дальше. Так же обрабатывается и `a < b` внутри скрипта: имя
    /// тега там не читается, значит это не тег, значит трогать нечего.
    private static func readTag(_ source: [Character], from start: Int) -> Tag? {
        var i = start + 1
        var name = ""
        while i < source.count, source[i].isLetter || source[i].isNumber {
            name.append(source[i])
            i += 1
        }
        let lower = name.lowercased()
        guard lower == "script" || lower == "link" else { return nil }
        guard i < source.count else { return nil }
        guard source[i].isWhitespace || source[i] == ">" || source[i] == "/" else { return nil }

        var attrs: [String: (value: String, start: Int, end: Int)] = [:]
        while i < source.count {
            while i < source.count, source[i].isWhitespace { i += 1 }
            guard i < source.count else { break }
            if source[i] == ">" { i += 1; break }
            if source[i] == "/" { i += 1; continue }
            var key = ""
            while i < source.count, !source[i].isWhitespace,
                  source[i] != "=", source[i] != ">", source[i] != "/" {
                key.append(source[i])
                i += 1
            }
            // Пустое имя означало бы вечный цикл на непонятном символе — шагаем дальше.
            if key.isEmpty { i += 1; continue }
            while i < source.count, source[i].isWhitespace { i += 1 }
            guard i < source.count, source[i] == "=" else {
                attrs[key.lowercased()] = ("", i, i)
                continue
            }
            i += 1
            while i < source.count, source[i].isWhitespace { i += 1 }
            guard i < source.count else { break }
            var value = ""
            let valueStart: Int
            let valueEnd: Int
            if source[i] == "\"" || source[i] == "'" {
                let quote = source[i]
                i += 1
                valueStart = i
                while i < source.count, source[i] != quote {
                    value.append(source[i])
                    i += 1
                }
                valueEnd = i
                if i < source.count { i += 1 }
            } else {
                valueStart = i
                while i < source.count, !source[i].isWhitespace, source[i] != ">" {
                    value.append(source[i])
                    i += 1
                }
                valueEnd = i
            }
            attrs[key.lowercased()] = (value, valueStart, valueEnd)
        }
        return Tag(name: lower, end: i, attrs: attrs)
    }
}
