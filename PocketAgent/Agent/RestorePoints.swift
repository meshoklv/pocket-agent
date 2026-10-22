//
//  RestorePoints.swift
//  PocketAgent
//
//  Точка возврата: «Вернуть, как было».
//
//  ⚠️ ЗАЧЕМ. У человека был выбор только ДО нажатия — применить правку или нет.
//  После нажатия дороги назад не было вовсе. Разведка по чужим агентам-программистам
//  (docs/research/oss-features.md, приём №1) назвала это единственным, чего
//  по-настоящему не хватает нашему ядру «шаг — подтверждение»: подтверждать
//  не страшно, если можно отменить.
//
//  ⚠️ МОДЕЛЬ В ЭТОМ НЕ УЧАСТВУЕТ ВООБЩЕ, И В ЭТОМ ВЕСЬ СМЫСЛ. Прежний текст файла
//  запоминает приложение в момент записи, и оно же кладёт его обратно — слово в слово.
//  Попроси мы вернуть файл модель на 2 млрд параметров — получили бы «примерно
//  прежний» файл; здесь надёжность стопроцентная, потому что ничего не сочиняется.
//
//  ⚠️ И ПОЭТОМУ ЖЕ ПРЕЖНИЙ ТЕКСТ ЛЕЖИТ НА ДИСКЕ, А НЕ В ПАМЯТИ РАЗГОВОРА. Всё, что
//  попало в память разговора, уходит модели КАЖДЫЙ ход и стоит токенов, а их всего
//  4096. Возврат не стоит модели ни одного токена: она о нём не знает вовсе.
//
//  Где лежит: ~/Library/Application Support/RestorePoints — рядом с записями разговоров,
//  в резервную копию не попадает и никуда не отправляется. Стирается вместе с историей
//  разговоров: там лежат куски файлов человека, и держать их дольше, чем он разрешил,
//  нельзя.
//
//  ⚠️ ДВА ФАЙЛА НА ОДНУ ТОЧКУ, А НЕ ОДИН. Список точек нужен постоянно (какая правка
//  последняя — от этого зависит, у какой строки ленты живёт кнопка), а сам прежний текст —
//  только в тот миг, когда человек нажал. Лежи всё в одном файле, приложение при запуске
//  поднимало бы с диска мегабайт содержимого ради пяти строк метаданных.
//

import Foundation

// MARK: - Одна точка возврата

/// Что приложение помнит об одной применённой правке. Самого текста здесь НЕТ —
/// он лежит отдельным файлом и читается только в момент нажатия.
public struct RestorePoint: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    /// Путь файла от корня папки проекта.
    public let relativePath: String
    /// В какой папке это было. Точки чужого проекта человеку не предлагаем.
    public let folderPath: String
    public let createdAt: Date
    /// Файла не было вовсе — правка его создала. Вернуть, как было, значит удалить его.
    public let wasMissing: Bool
    /// Сколько весит сохранённый прежний текст. 0 — файла не было.
    public let textBytes: Int

    public init(id: UUID = UUID(),
                relativePath: String,
                folderPath: String,
                createdAt: Date = Date(),
                wasMissing: Bool,
                textBytes: Int) {
        self.id = id
        self.relativePath = relativePath
        self.folderPath = folderPath
        self.createdAt = createdAt
        self.wasMissing = wasMissing
        self.textBytes = textBytes
    }
}

// MARK: - Хранилище точек

@MainActor
public enum RestorePointStore {

    // MARK: Пределы

    /// Сколько последних правок можно вернуть.
    ///
    /// ⚠️ ПЯТЬ — И ЭТО НЕ ОКРУГЛЁННОЕ «НА ГЛАЗ». Правок за одну задачу обычно одна-три
    /// (шагов до двух десятков, но записей среди них единицы), поэтому пять покрывают
    /// всю текущую задачу и ещё предыдущую. Кнопка при этом всегда ОДНА — у самой свежей
    /// правки; вернул её — кнопка перешла к предыдущей, и так до пяти шагов назад.
    /// Держать больше значит хранить на телефоне куски файлов, к которым человек уже
    /// не вернётся: место занято, а пользы ноль.
    public static let maxPoints = 5

    /// Больше этого прежний текст не храним (байты).
    ///
    /// ⚠️ 256 КБ — это примерно шесть тысяч строк кода, то есть файл крупнее любого
    /// обычного исходника. Пять таких точек — самое большее 1,3 МБ на телефоне рядом
    /// с моделью на 2,5 ГБ, то есть ничто. Но обещать возврат файла, который мы не
    /// сохранили, нельзя — поэтому про такой файл человеку говорится ЗАРАНЕЕ, прямо
    /// в карточке подтверждения, а не после нажатия (см. ApprovalCard).
    public nonisolated static let maxTextBytes = 256 * 1024

    /// Влезет ли прежнее содержимое в точку возврата.
    /// `nil` — файла не было вовсе: хранить нечего, а вернуть можно всегда.
    ///
    /// ⚠️ `nonisolated`: этот же вопрос задаёт карточка подтверждения, чтобы сказать
    /// про слишком большой файл ДО нажатия, а не после. Никакого состояния тут нет —
    /// только сравнение с пределом.
    public nonisolated static func canKeep(previousText: String?) -> Bool {
        guard let previousText = previousText else { return true }
        return previousText.utf8.count <= maxTextBytes
    }

    // MARK: Список точек

    /// Метаданные всех точек, от старой к свежей. Текстов здесь нет.
    /// nil — с диска ещё не поднимали.
    private static var index: [RestorePoint]?

    private static func points() -> [RestorePoint] {
        if let known = index { return known }
        let loaded = loadIndexFromDisk()
        index = loaded
        return loaded
    }

    /// Самая свежая правка ЭТОЙ папки, которую ещё можно вернуть.
    public static func latest(inFolder folderPath: String) -> RestorePoint? {
        guard !folderPath.isEmpty else { return nil }
        return points().last { $0.folderPath == folderPath }
    }

    public static func point(withID id: UUID) -> RestorePoint? {
        points().first { $0.id == id }
    }

    // MARK: Запомнить прежнее содержимое

    /// Записали файл — запоминаем, что в нём было до этого.
    ///
    /// Возвращает точку, если её удалось завести, и nil — если возврат этой правки
    /// мы честно не обещаем (файл слишком велик, папки нет).
    ///
    /// ⚠️ Точка появляется в списке СРАЗУ, а на диск уезжает следом, отдельной очередью:
    /// человек видит кнопку «Вернуть, как было» в тот же миг, а не через полсекунды,
    /// нужные диску. Не доехало на диск (приложение закрыли в ту же секунду) — не беда:
    /// список при следующем запуске поднимается с диска, то есть сам себя и поправит.
    @discardableResult
    public static func remember(relativePath: String,
                                folderPath: String,
                                previousText: String?) -> RestorePoint? {
        guard !folderPath.isEmpty, !relativePath.isEmpty else { return nil }
        guard canKeep(previousText: previousText) else { return nil }

        let point = RestorePoint(relativePath: relativePath,
                                 folderPath: folderPath,
                                 wasMissing: previousText == nil,
                                 textBytes: previousText?.utf8.count ?? 0)

        var list = points()
        list.append(point)

        // Лишние точки убираем сразу и вместе с их текстами: именно тексты и занимают место.
        var dropped: [RestorePoint] = []
        if list.count > maxPoints {
            let extra = list.count - maxPoints
            dropped = Array(list.prefix(extra))
            list.removeFirst(extra)
        }
        index = list

        let text = previousText
        queue.async {
            write(point, text: text)
            for old in dropped { removeFiles(of: old) }
            pruneStrayFiles(keeping: list)
        }
        return point
    }

    // MARK: Забыть

    /// Точка использована (или оказалась пустышкой) — убираем её насовсем.
    public static func forget(_ id: UUID) {
        var list = points()
        guard let position = list.firstIndex(where: { $0.id == id }) else { return }
        let point = list.remove(at: position)
        index = list
        queue.async { removeFiles(of: point) }
    }

    /// «Стереть историю разговоров» — вместе с ней уходят и прежние тексты файлов.
    /// Иначе куски чужих файлов оставались бы на телефоне после того, как человек
    /// прямо попросил их стереть.
    public static func eraseAll() {
        index = []
        queue.async {
            guard let dir = directory(create: false) else { return }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: Прежний текст (читается только в момент нажатия)

    /// Прежнее содержимое файла. nil — файла не было вовсе или текст не прочитался.
    ///
    /// ⚠️ `nonisolated` намеренно: это единственная тяжёлая работа с диском во всём
    /// хранилище (до 256 КБ), и звать её надо ВНЕ главного потока — иначе лента чата
    /// замирает ровно в тот момент, когда человек нажал кнопку.
    public nonisolated static func previousText(of point: RestorePoint) -> String? {
        guard !point.wasMissing, let dir = directory(create: false) else { return nil }
        let url = dir.appendingPathComponent("\(point.id.uuidString).txt")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Диск

    /// Вся работа с файлами идёт здесь и только здесь — главный поток её не ждёт.
    private nonisolated static let queue = DispatchQueue(label: "pocketagent.restorepoints",
                                                         qos: .utility)

    private nonisolated static func directory(create: Bool) -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: create) else { return nil }
        let dir = base.appendingPathComponent("RestorePoints", isDirectory: true)
        guard create else { return dir }
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Куски рабочих файлов человека в облако не возим — это его дело, не наше.
            try? ModelStorage.excludeFromBackup(dir)
        }
        return dir
    }

    private nonisolated static func loadIndexFromDisk() -> [RestorePoint] {
        guard let dir = directory(create: false),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(RestorePoint.self, from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Только внутри `queue`.
    private nonisolated static func write(_ point: RestorePoint, text: String?) {
        guard let dir = directory(create: true) else { return }

        // Сначала текст, потом метаданные: список точек поднимается по метаданным,
        // и точка без текста хуже, чем текст без точки (её просто никто не увидит).
        if let text = text, let data = text.data(using: .utf8) {
            let textURL = dir.appendingPathComponent("\(point.id.uuidString).txt")
            try? data.write(to: textURL, options: .atomic)
            try? ModelStorage.excludeFromBackup(textURL)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let meta = try? encoder.encode(point) else { return }
        let metaURL = dir.appendingPathComponent("\(point.id.uuidString).json")
        try? meta.write(to: metaURL, options: .atomic)
        try? ModelStorage.excludeFromBackup(metaURL)
    }

    /// Только внутри `queue`.
    private nonisolated static func removeFiles(of point: RestorePoint) {
        guard let dir = directory(create: false) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(point.id.uuidString).json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(point.id.uuidString).txt"))
    }

    /// Только внутри `queue`. Убирает файлы, за которыми не стоит ни одной точки:
    /// приложение могли закрыть между записью текста и записью метаданных, и такой
    /// осиротевший текст занимал бы место молча и вечно.
    private nonisolated static func pruneStrayFiles(keeping list: [RestorePoint]) {
        guard let dir = directory(create: false),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return }

        let alive = Set(list.map { $0.id.uuidString })
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            guard !alive.contains(name) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Что человек читает про возврат

/// Все слова про возврат — в одном месте, по-русски и без кодерского языка.
public enum UndoTexts {

    /// Кнопка у применённой правки.
    public static let button = "Вернуть, как было"

    /// Заголовок карточки возврата.
    public static func title(path: String) -> String {
        "Вернуть \(PathTail.fileName(of: path)), как было"
    }

    /// Подпись под заголовком карточки: обычный возврат.
    public static let restoreSubtitle =
        "Вернём файл к тому, что в нём было до правки. "
        + "До вашего согласия на диске ничего не меняется."

    /// То же самое, когда правка создала файл: вернуть — значит удалить его.
    public static let deleteSubtitle =
        "Этого файла до правки не было — возврат удалит его целиком. "
        + "До вашего согласия на диске ничего не меняется."

    /// Слишком большой файл: говорим ДО применения, а не после.
    public static let tooBigToKeep =
        "Файл слишком большой — вернуть его прежний текст потом не получится."

    public static func restored(path: String, added: Int, removed: Int) -> String {
        "Вернул \(path), как было до правки (+\(added) −\(removed))"
    }

    public static func deleted(path: String) -> String {
        "Удалил \(path) — до правки этого файла не было"
    }

    public static func alreadyAsBefore(path: String) -> String {
        "Файл \(path) и так в прежнем виде — возвращать нечего."
    }

    public static let textLost =
        "Прежний текст этой правки на телефоне не сохранился — вернуть не получится."

    public static func changedSince(path: String) -> String {
        "Файл \(path) успел измениться — возврат отменён, чтобы не потерять эти изменения. "
        + "Посмотрите файл и решите сами."
    }

    public static let cancelled = "Возврат отменён — на диске ничего не менялось."
}

/// Имя файла без папок. Своё, крошечное: `PathDisplay` живёт в интерфейсе,
/// а тексты возврата нужны и здесь, где про интерфейс ничего не знают.
enum PathTail {
    static func fileName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
