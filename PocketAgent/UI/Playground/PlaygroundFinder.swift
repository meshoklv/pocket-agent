//
//  PlaygroundFinder.swift
//  PocketAgent
//
//  Что в папке проекта можно ОТКРЫТЬ И ПОСМОТРЕТЬ.
//
//  ⚠️ ЗАЧЕМ ЭТО ПОЯВИЛОСЬ (правка владельца 10.09.2026, ROADMAP §18). Дословно:
//  «место где можно будет смотреть хтмл всякие которые делает модель, или игры».
//  До сих пор помощник умел НАПИСАТЬ страницу или игру, а человеку показать её было
//  негде: он видел в переписке только текст файла. Площадка закрывает этот разрыв.
//
//  ⚠️ ПОЧЕМУ ОБХОД СВОЙ, А НЕ ЧЕРЕЗ ИНСТРУМЕНТЫ АГЕНТА. Инструменты — это то, чем
//  пользуется МОДЕЛЬ, и их ровно четыре (см. CLAUDE.md). Площадка — просмотрщик для
//  человека, и добавлять ради неё пятый инструмент значило бы путать модель ради
//  экрана, к которому она отношения не имеет.
//
//  ⚠️ ПОЧЕМУ С ПОТОЛКОМ И СРОКОМ. Папка владельца лежит в iCloud и бывает огромной
//  (в его `ouroboros-main` — 971 файл). Полный обход такого дерева на телефоне
//  занимает секунды, а если часть файлов ещё не скачана — может встать совсем.
//  Экран не имеет права ждать: лучше показать «нашли первые N» и работать.
//

import Foundation

/// Одна вещь, которую можно запустить на площадке.
struct PlaygroundItem: Identifiable, Hashable, Sendable {

    /// Путь от корня папки проекта — он же опознаватель: в одной папке двух
    /// одинаковых путей не бывает.
    var id: String { relativePath }

    let url: URL
    /// Путь от корня — показываем его, когда файл лежит не на верхнем уровне.
    let relativePath: String
    /// Имя файла для крупной подписи.
    let name: String
    let sizeInBytes: Int
    let modifiedAt: Date

    /// Лежит ли файл прямо в корне папки. Такие показываем первыми: обычно это
    /// и есть то, что помощник только что сделал по просьбе человека.
    var isAtRoot: Bool { !relativePath.contains("/") }

    /// Папка, в которой файл лежит («—», если он в корне).
    var folderPath: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[relativePath.startIndex..<slash])
    }
}

/// Поиск того, что можно показать, внутри папки проекта.
enum PlaygroundFinder {

    /// Что считаем «страницей, которую можно открыть».
    ///
    /// ⚠️ НАРОЧНО ТОЛЬКО СТРАНИЦЫ, А НЕ «ЛЮБОЙ ФАЙЛ». Площадка — не файловый
    /// менеджер: показать человеку `.swift` или `.json` она может разве что текстом,
    /// а текст он и так видит в переписке. Ценность ровно в том, что страница
    /// ОЖИВАЕТ: кнопки нажимаются, игра играется.
    ///
    /// ⚠️ ЧЕТЫРЕ ВИДА, А НЕ ОДИН (11.09.2026). Владелец просил площадку «с поддержкой
    /// всего ваще», и три соседа страницы движок показывает сам, без единой строчки
    /// с нашей стороны: рисунок `.svg` (это и есть разметка, он живой — в нём работают
    /// анимация и нажатия), готовый документ `.pdf` и записка `.md` (её мы заворачиваем
    /// в страницу и оформляем библиотекой с полки). Файловым менеджером площадка от
    /// этого не становится: `.swift` и `.json` по-прежнему не показываем — их человек
    /// видит в переписке, и оживать им нечем.
    static let openableExtensions: Set<String> = ["html", "htm", "svg", "pdf", "md", "markdown"]

    /// Сколько файлов максимум показываем. Больше — человек всё равно не выберет.
    static let maxItems = 200
    /// Глубже не спускаемся: страницы, зарытые на седьмой уровень, — это чужие
    /// потроха (node_modules, сборки), а не то, что писал помощник.
    static let maxDepth = 4

    /// Папки, в которые не заходим никогда.
    ///
    /// ⚠️ Без этого списка в чужом репозитории площадка покажет сотни страниц
    /// документации и отчётов покрытия, среди которых не найти свою игру.
    static let skippedFolders: Set<String> = [
        "node_modules", ".git", ".github", "build", "dist", ".build",
        "pods", "vendor", "venv", ".venv", "__pycache__", ".next",
        "coverage", "htmlcov", ".idea", ".vscode", "derriveddata", "deriveddata"
    ]

    /// Обойти папку и собрать то, что можно открыть.
    ///
    /// Вызывать в стороне от главного потока: обход трогает диск, а часть файлов
    /// может докачиваться из облака.
    ///
    /// - Parameters:
    ///   - root: корень папки проекта. Наружу не выходим никогда.
    ///   - deadline: общий срок. Вышел — отдаём то, что успели, и говорим об этом.
    static func scan(rawRoot: URL,
                     deadline: Date = Date().addingTimeInterval(6)) -> PlaygroundScan {
        // ⚠️⚠️ КОРЕНЬ ПРИВОДИМ К КАНОНИЧЕСКОМУ ВИДУ ПЕРВОЙ СТРОКОЙ, И ЭТО НЕ ПРИДИРКА.
        // `SafePath.isInside` канонизирует корень (`/var/…` превращается в
        // `/private/var/…`), а адрес файла — нет. Если папка пришла неканоническим
        // путём, каждый найденный файл не совпадёт с корнем и будет отброшен: площадка
        // покажет «страниц не нашёл» на папке, где страницы лежат. Ошибка безопасная
        // (запирает, а не открывает), но площадка при ней мертва. Обходим уже от
        // канонического корня — тогда и все адреса внутри канонические.
        let root = SafePath.canonical(rawRoot)
        var found: [PlaygroundItem] = []
        var didStop = false

        // Обход своим списком, а не рекурсией: так глубину и срок видно в одном месте,
        // и стек не растёт на чужих деревьях в тысячи папок.
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        let manager = FileManager.default

        while !queue.isEmpty {
            if Date() >= deadline || found.count >= maxItems { didStop = true; break }
            let (folder, depth) = queue.removeFirst()

            let contents = try? manager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            guard let contents else { continue }

            for entry in contents {
                if Date() >= deadline || found.count >= maxItems { didStop = true; break }
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])

                // ⚠️⚠️ ССЫЛКУ НЕ ТРОГАЕМ ВООБЩЕ — НИ ПАПКУ, НИ ФАЙЛ.
                // `isDirectoryKey` идёт ПО ссылке, а не по ней самой: ссылка `x -> /`
                // спокойно легла бы в очередь, и обход ушёл бы гулять по всему диску,
                // а на облачной папке ещё и потянул бы скачивание чужих файлов.
                // Ровно эта дыра уже была найдена в SafePath 08.09.2026 — не заводим её заново.
                guard !SafePath.isSymbolicLink(entry) else { continue }

                if values?.isDirectory == true {
                    guard depth < maxDepth else { continue }
                    guard !skippedFolders.contains(entry.lastPathComponent.lowercased()) else { continue }
                    queue.append((entry, depth + 1))
                    continue
                }

                guard openableExtensions.contains(entry.pathExtension.lowercased()) else { continue }
                // ⚠️ Граница папки — той же проверкой, что и везде в приложении.
                guard SafePath.isInside(entry, root: root) else { continue }
                guard let relative = relativePath(of: entry, from: root) else { continue }
                found.append(PlaygroundItem(url: entry,
                                            relativePath: relative,
                                            name: entry.lastPathComponent,
                                            sizeInBytes: values?.fileSize ?? 0,
                                            modifiedAt: values?.contentModificationDate ?? .distantPast))
            }
        }

        // ⚠️ ПОРЯДОК ВАЖЕН, И ГЛАВНОЕ В НЁМ — ВРЕМЯ, А НЕ ГЛУБИНА. Человек приходит
        // сюда сразу после того, как помощник что-то написал, — значит сверху лежит
        // самое свежее. «В корне» осталось, но только как РАЗРЕШЕНИЕ СПОРА при
        // одинаковом времени: пока оно стояло первым, свежая страница, положенная
        // в подпапку, уезжала под сотню старых корневых — то есть человек не находил
        // ровно то, за чем пришёл.
        found.sort { left, right in
            if left.modifiedAt != right.modifiedAt { return left.modifiedAt > right.modifiedAt }
            if left.isAtRoot != right.isAtRoot { return left.isAtRoot }
            // Последняя ступенька — чтобы порядок был устойчивым, а не случайным.
            return left.relativePath < right.relativePath
        }
        return PlaygroundScan(items: found, isPartial: didStop)
    }

    /// Путь от корня — компонентами, а не отрезанием строки.
    ///
    /// ⚠️ ПОЧЕМУ НЕ `hasPrefix`. Соседняя папка `проект-чужой` начинается с тех же
    /// букв, что и `проект`, и строковая проверка считает её своей. Это выстрадано
    /// в SafePath, там же лежит готовый разбор по компонентам — зовём его.
    private static func relativePath(of url: URL, from root: URL) -> String? {
        let parts = SafePath.relativeComponents(of: url, root: root)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }
}

/// Чем закончился обход.
struct PlaygroundScan: Sendable {
    let items: [PlaygroundItem]
    /// Обход прервали по сроку или потолку — значит показано не всё.
    /// Человеку об этом говорим прямо: молчаливая неполнота хуже неполноты.
    let isPartial: Bool

    static let empty = PlaygroundScan(items: [], isPartial: false)
}
