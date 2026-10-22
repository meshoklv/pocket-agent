//
//  ModelDownloadPlan.swift
//  PocketAgent / Runtime
//
//  План загрузки файла кусками и всё, что нужно, чтобы его пережить.
//
//  ЗАЧЕМ КУСКИ. Один поток на мобильной сети упирается не в ширину канала, а в задержку:
//  пока пакет летит до сервера и обратно, канал простаивает. Несколько одновременных
//  потоков заполняют эту паузу. Живой замер 09.08.2026 (Hugging Face, куски по 2–4 МБ):
//  один поток 1,30 МБ/с, два 1,60, три 1,85, четыре 1,77, шесть 1,97. Прирост есть,
//  но он быстро упирается в потолок — поэтому потоков единицы, а не десятки: дальше
//  растёт только нагрев телефона и число обрывов. Сколько именно — настройка
//  (`ModelDownloader.laneCount`), потому что честного ответа без замера на живом
//  телефоне нет, а разброс между тремя и шестью был в пределах дрожания связи.
//
//  ЗАЧЕМ ПЛАН НА ДИСКЕ. Загрузка обязана продолжаться при свёрнутом и даже закрытом
//  приложении, а система может закрыть его в любой момент и разбудить снова, когда
//  кусок докачается. Значит, «что уже скачано» нельзя держать в памяти: план и куски
//  лежат на диске, и после пробуждения приложение видит ровно то, что было.
//
//  ЗАЧЕМ КУСКИ ВООБЩЕ ПОДЕЛЕНЫ. Размер куска — это цена одной неудачи: оборвался
//  кусок, теряем только его, а не весь гигабайт. И это же скорость хвоста: чем мельче
//  куски, тем чаще перетасовываются дорожки и тем меньше остальные потоки простаивают,
//  ожидая один отставший. Накладные расходы на кусок — одно обращение к серверу по уже
//  открытому соединению, доли секунды. Размер настраивается (`chunkMegabytes`),
//  по умолчанию 16 МБ.
//
//  ⚠️ СОБРАННЫЙ ФАЙЛ ОБЯЗАН БЫТЬ ПОБАЙТОВО ТЕМ ЖЕ САМЫМ. Каждый кусок пишется в файл
//  по своему точному смещению, а не «дописывается в конец», поэтому порядок прихода
//  кусков ни на что не влияет. Проверено живьём: файл, скачанный одним потоком, и файл,
//  склеенный из четырёх кусков, дали одинаковую контрольную сумму.
//

import Foundation

// MARK: - Модель, которая лежит папкой

/// Один файл внутри папки-модели Apple: как называется, сколько весит, чем сверить.
///
/// ⚠️ ЗАЧЕМ ЭТО ВООБЩЕ ЕСТЬ. Модель Google — один файл: одна ссылка, один размер, одна
/// сумма. Модель Apple — папка из 8–10 файлов, и без мелких `.json` она не запускается
/// вовсе. Значит, «что качать» перестаёт быть одной строкой и становится списком.
/// Сам список берётся у Hugging Face живым запросом (`HuggingFaceSearch`) или лежит
/// в справочнике — но выдумывать его нельзя ни в одном из этих случаев.
///
/// `sha256` пустой — обычное дело: контрольные суммы Hugging Face даёт только для
/// крупных файлов (веса, словарь), а мелкие описания отдаёт без них.
public struct ModelFolderFile: Sendable, Equatable, Codable {

    /// Имя файла внутри папки («config.json», «model-00001-of-00002.safetensors»).
    public let name: String
    /// Точный размер в байтах — по нему и считается общий ход загрузки.
    public let byteSize: Int64
    /// Контрольная сумма из хранилища больших файлов. Пусто — её не дали.
    public let sha256: String

    public init(name: String, byteSize: Int64, sha256: String = "") {
        self.name = name
        self.byteSize = byteSize
        self.sha256 = sha256
    }
}

/// Где лежит скачиваемая папка-модель и как превратить её файлы в обычные заказы
/// на загрузку — те же самые, что и для одного файла Google.
///
/// ⚠️ ГЛАВНОЕ РЕШЕНИЕ ЗДЕСЬ — ЧТО ВТОРОГО ЗАГРУЗЧИКА НЕТ. Каждый файл папки качает
/// тот же `ModelDownloader`, что и модель Google: с кусками, тремя потоками, докачкой
/// после обрыва, продолжением при закрытом приложении и проверкой размера. Второй
/// способ качать — это второй набор ошибок, и чинить их пришлось бы дважды.
///
/// ⚠️ НЕДОСОБРАННАЯ ПАПКА ЖИВЁТ ПОД ИМЕНЕМ «…import», И ЭТО НЕ МЕЛОЧЬ. Приложение
/// обходит свою папку моделей при каждом открытии экрана и показывает человеку всё,
/// что похоже на модель. Складывай мы файлы сразу в папку с настоящим именем — на
/// экране появилась бы «готовая» модель, у которой ещё нет весов, и человек нажал бы
/// на неё. Хвост «import» — тот же самый, которым помечает себя прерванная установка
/// из «Файлов»: его уже умеют не считать моделью, считать в занятое место и удалять.
public enum ModelFolderDownload {

    /// Папка, в которую складываем файлы, пока модель не собрана целиком.
    public static func temporaryFolderURL(for model: ModelDescriptor) throws -> URL {
        try ModelStorage.fileURL(for: model)
            .appendingPathExtension(ModelImporter.temporaryExtension)
    }

    /// Папка готовой модели — та, которую увидит человек и поднимет движок.
    public static func finalFolderURL(for model: ModelDescriptor) throws -> URL {
        try ModelStorage.fileURL(for: model)
    }

    /// Заказ на загрузку ОДНОГО файла папки — в том же виде, в каком загрузчик
    /// принимает обычную модель.
    ///
    /// ⚠️ Имя на диске и путь в репозитории здесь РАЗНЫЕ, поэтому и полей два.
    /// На диск файл ложится внутрь недособранной папки («Qwen3-4B.import/config.json»),
    /// а у Hugging Face он лежит просто как «config.json». Слепи мы это в одно поле —
    /// либо адрес загрузки указал бы в никуда, либо файл лёг бы не в ту папку.
    public static func partDescriptor(of model: ModelDescriptor,
                                      file: ModelFolderFile) -> ModelDescriptor {
        ModelDescriptor(
            id: partID(of: model, file: file),
            displayName: model.displayName,
            repoID: model.repoID,
            repoCommit: model.repoCommit,
            fileName: "\(model.fileName).\(ModelImporter.temporaryExtension)/\(file.name)",
            byteSize: file.byteSize,
            sha256: file.sha256,
            summary: model.summary,
            hardware: model.hardware,
            origin: model.origin,
            isForPhone: model.isForPhone,
            license: model.license,
            repoPath: file.name
        )
    }

    /// Опознаватель части: по нему называются служебные файлы докачки, поэтому
    /// в нём только те знаки, которые точно можно писать в имя файла.
    private static func partID(of model: ModelDescriptor, file: ModelFolderFile) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let raw = (model.id + "-" + file.name).lowercased()
        let cleaned = String(raw.map { allowed.contains($0) ? $0 : "-" })
        // Имя файла в системе не бывает длиннее 255 знаков, а к нему ещё добавятся
        // «.plan» и «.chunk12». Режем хвостом: в конце стоит имя файла, а именно оно
        // и отличает части друг от друга.
        return cleaned.count > 120 ? String(cleaned.suffix(120)) : cleaned
    }
}

// MARK: - План

/// Что и откуда качаем кусками, и что из этого уже готово.
public struct ModelDownloadPlan: Codable, Sendable, Equatable {

    /// Опознаватель модели (он же имя служебных файлов).
    public let modelID: String
    /// Имя файла модели — по нему сверяем, что план не от другой модели.
    public let fileName: String
    /// Полный размер файла.
    public let totalBytes: Int64
    /// Размер одного куска.
    public let chunkBytes: Int64
    /// Опознаватель источника, с которого качаем.
    public let sourceID: String
    /// Как назвать источник человеку.
    public let sourceName: String
    /// Официальный ли источник. У неофициального перед приёмкой сверяем сумму целиком.
    public let isOfficialSource: Bool
    /// Ссылка на файл.
    public let urlString: String
    /// Номера кусков, которые уже записаны в собираемый файл.
    public var doneChunks: [Int]

    public init(modelID: String,
                fileName: String,
                totalBytes: Int64,
                chunkBytes: Int64,
                sourceID: String,
                sourceName: String,
                isOfficialSource: Bool,
                urlString: String,
                doneChunks: [Int]) {
        self.modelID = modelID
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.chunkBytes = chunkBytes
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.isOfficialSource = isOfficialSource
        self.urlString = urlString
        self.doneChunks = doneChunks
    }

    /// Сколько всего кусков.
    public var chunkCount: Int {
        guard totalBytes > 0, chunkBytes > 0 else { return 0 }
        return Int((totalBytes + chunkBytes - 1) / chunkBytes)
    }

    /// С какого байта начинается кусок.
    public func offset(of index: Int) -> Int64 {
        Int64(index) * chunkBytes
    }

    /// Сколько байт в куске (последний обычно короче).
    public func length(of index: Int) -> Int64 {
        let start = offset(of: index)
        guard start < totalBytes else { return 0 }
        return min(chunkBytes, totalBytes - start)
    }

    /// Заголовок «отдай мне вот этот кусок».
    public func rangeHeader(for index: Int) -> String {
        let start = offset(of: index)
        let end = start + length(of: index) - 1
        return "bytes=\(start)-\(end)"
    }

    /// Сколько байт уже лежит в собираемом файле.
    public var doneBytes: Int64 {
        var total: Int64 = 0
        for index in doneChunks { total += length(of: index) }
        return total
    }

    /// Всё ли собрано.
    public var isComplete: Bool {
        guard chunkCount > 0 else { return false }
        return Set(doneChunks).count >= chunkCount
    }

    /// Куски, которых ещё нет, по порядку.
    public func pendingChunks() -> [Int] {
        guard chunkCount > 0 else { return [] }
        let done = Set(doneChunks)
        var result: [Int] = []
        for index in 0..<chunkCount where !done.contains(index) {
            result.append(index)
        }
        return result
    }

    /// Отметить кусок собранным (без повторов).
    public mutating func markDone(_ index: Int) {
        guard !doneChunks.contains(index) else { return }
        doneChunks.append(index)
    }

    /// Тот же план, но с другого источника: уже собранные куски сохраняются.
    /// Именно так работает переход на запасной адрес — скачанное не теряется,
    /// потому что границы кусков считаются от начала файла и от источника не зависят.
    public func switchingSource(to source: ModelSource, urlString: String) -> ModelDownloadPlan {
        ModelDownloadPlan(modelID: modelID,
                          fileName: fileName,
                          totalBytes: totalBytes,
                          chunkBytes: chunkBytes,
                          sourceID: source.id,
                          sourceName: source.humanName,
                          isOfficialSource: source.isOfficial,
                          urlString: urlString,
                          doneChunks: doneChunks)
    }

    /// План точно про эту модель? Размер и имя обязаны совпасть — иначе это остаток
    /// от прошлой модели, и собирать по нему нельзя.
    public func matches(_ model: ModelDescriptor) -> Bool {
        modelID == model.id
            && fileName == model.fileName
            && totalBytes == model.byteSize
            && chunkCount > 0
    }
}

// MARK: - Замер скорости

/// Честные цифры одной загрузки: сколько прилетело, за сколько, какими потоками.
///
/// ⚠️ ЗАЧЕМ ЭТО ВООБЩЕ ЕСТЬ. Скорость нельзя улучшить рассуждением: любое «кажется,
/// стало быстрее» — это то самое место, где легко сделать вид, что стало лучше.
/// Поэтому приложение считает и показывает цифры само, и по ним сравнивают «было → стало».
public struct ModelDownloadSpeed: Sendable {

    /// Сколько байт реально прилетело из сети за этот заход (без уже лежавшего на диске).
    public let arrivedBytes: Int64
    /// Сколько секунд байты РЕАЛЬНО шли. Пауза, потеря связи и сон телефона сюда
    /// не входят: иначе час на паузе превратил бы честные 2,3 МБ/с в 0,3 МБ/с.
    public let seconds: Double
    /// Сколько потоков и какими кусками качали — иначе цифру не с чем сравнивать.
    /// ⚠️ Это настройки НА МОМЕНТ НАЧАЛА захода, а не нынешние: человек мог поменять
    /// их посреди загрузки, и тогда строка врала бы про уже проделанную работу.
    /// Ноль — значит «к этому заходу неприменимо» (обычная загрузка одним потоком).
    public let lanes: Int
    public let chunkMegabytes: Int
    /// С какой скоростью получалось складывать куски в файл. 0 — ещё не мерили.
    public let diskBytesPerSecond: Double

    public init(arrivedBytes: Int64,
                seconds: Double,
                lanes: Int,
                chunkMegabytes: Int,
                diskBytesPerSecond: Double) {
        self.arrivedBytes = arrivedBytes
        self.seconds = seconds
        self.lanes = lanes
        self.chunkMegabytes = chunkMegabytes
        self.diskBytesPerSecond = diskBytesPerSecond
    }

    /// Скорость сети, байт в секунду.
    public var bytesPerSecond: Double {
        seconds > 0 ? Double(arrivedBytes) / seconds : 0
    }

    /// «2,55 ГБ, качалось 18 мин 20 с — 2,3 МБ/с, 4 потока по 16 МБ,
    /// запись на диск 240 МБ/с».
    ///
    /// ⚠️ Слово «качалось», а не «за»: время здесь чистое, без пауз и простоев.
    ///
    /// ⚠️ Запись на диск названа НЕ ДЛЯ КРАСОТЫ: если она окажется того же порядка,
    /// что и сеть, значит скорость упирается в телефон, а не в канал, — и дальше надо
    /// чинить сборку файла, а не число потоков.
    public var humanLine: String {
        var text = "\(HumanFormat.bytes(arrivedBytes)), качалось \(Self.duration(seconds))"
            + " — \(Self.speed(bytesPerSecond))"
        if lanes > 0 {
            text += ", \(lanes) \(HumanFormat.plural(lanes, "поток", "потока", "потоков"))"
        }
        if chunkMegabytes > 0 {
            text += " по \(chunkMegabytes) МБ"
        }
        if diskBytesPerSecond > 0 {
            text += ", запись на диск \(Self.speed(diskBytesPerSecond))"
        }
        return text
    }

    /// «2,3 МБ/с».
    public static func speed(_ bytesPerSecond: Double) -> String {
        let megabytes = bytesPerSecond / (1024 * 1024)
        let text = megabytes >= 10
            ? String(format: "%.0f", megabytes)
            : String(format: "%.1f", megabytes)
        return text.replacingOccurrences(of: ".", with: ",") + " МБ/с"
    }

    /// «18 мин 20 с», «45 с».
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total) с" }
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes) мин" : "\(minutes) мин \(rest) с"
    }
}

// MARK: - Хранение плана и кусков

/// Где лежат план, собираемый файл и временные куски.
///
/// ⚠️ Всё живёт в той же папке, что и модели (Library/Application Support/Models):
/// она исключена из резервной копии, и туда же в конце переезжает готовый файл —
/// значит, «переименовать» его получится без копирования гигабайтов.
public enum ModelDownloadPlanStore {

    /// Файл плана.
    public static func planURL(for modelID: String) throws -> URL {
        try ModelStorage.modelsDirectory().appendingPathComponent("\(modelID).plan")
    }

    /// Файл, который мы собираем из кусков.
    public static func partialURL(for modelID: String) throws -> URL {
        try ModelStorage.modelsDirectory().appendingPathComponent("\(modelID).partial")
    }

    /// Временный файл одного куска.
    public static func chunkURL(for modelID: String, index: Int) throws -> URL {
        try ModelStorage.modelsDirectory().appendingPathComponent("\(modelID).chunk\(index)")
    }

    /// Записать план на диск. Тихо: неудача записи не должна ронять загрузку —
    /// в худшем случае после перезапуска приложение начнёт кусок заново.
    public static func save(_ plan: ModelDownloadPlan) {
        guard let url = try? planURL(for: plan.modelID) else { return }
        guard let data = try? JSONEncoder().encode(plan) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Прочитать план. nil — плана нет или он испорчен.
    public static func load(modelID: String) -> ModelDownloadPlan? {
        guard let url = try? planURL(for: modelID),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let plan = try? JSONDecoder().decode(ModelDownloadPlan.self, from: data) else {
            return nil
        }
        return plan
    }

    /// Убрать план, собираемый файл и все временные куски.
    public static func clear(modelID: String) {
        let manager = FileManager.default
        if let url = try? planURL(for: modelID) { try? manager.removeItem(at: url) }
        if let url = try? partialURL(for: modelID) { try? manager.removeItem(at: url) }

        // Куски: их номера заранее неизвестны (план мог уже пропасть), поэтому
        // ищем по имени в своей же папке.
        guard let directory = try? ModelStorage.modelsDirectory(),
              let items = try? manager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: nil,
                                                           options: [.skipsSubdirectoryDescendants]) else {
            return
        }
        let prefix = modelID + ".chunk"
        for item in items where item.lastPathComponent.hasPrefix(prefix) {
            try? manager.removeItem(at: item)
        }
    }

    /// Сколько байт уже собрано на диске (для строки «удалить скачанное»).
    public static func downloadedBytes(modelID: String) -> Int64 {
        guard let plan = load(modelID: modelID) else { return 0 }
        return plan.doneBytes
    }

    // MARK: Замер записи на диск

    /// ⚠️ ВОПРОС «А НЕ УПИРАЕТСЯ ЛИ ВСЁ В ЗАПИСЬ НА ДИСК» РЕШАЕТСЯ ЗАМЕРОМ, А НЕ СПОРОМ.
    /// Здесь копятся байты и секунды сборки файла из кусков; частное показывает
    /// приложение рядом со скоростью сети. Пока это сотни МБ/с против единиц МБ/с
    /// у сети — диск ни при чём.
    private static let meter = NSLock()
    private static var meterBytes: Int64 = 0
    private static var meterSeconds: Double = 0

    private static func noteWrite(bytes: Int64, seconds: Double) {
        meter.lock()
        meterBytes += max(0, bytes)
        meterSeconds += max(0, seconds)
        meter.unlock()
    }

    /// С какой скоростью получается складывать куски в файл. 0 — ещё не мерили.
    public static var writeSpeedBytesPerSecond: Double {
        meter.lock()
        defer { meter.unlock() }
        guard meterSeconds > 0.01, meterBytes > 0 else { return 0 }
        return Double(meterBytes) / meterSeconds
    }

    // MARK: Сборка

    /// Записать кусок в собираемый файл по его точному смещению.
    ///
    /// ⚠️ Пишем ИМЕННО ПО СМЕЩЕНИЮ, а не в конец: куски приходят в произвольном порядке,
    /// и «дописать в конец» перемешало бы файл. Читаем и пишем по 4 МБ — держать в памяти
    /// весь кусок незачем, а телефон с 32 МБ в памяти на ровном месте лучше не трогать.
    public static func write(chunkAt chunk: URL, into partial: URL, offset: Int64) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: partial.path) {
            guard manager.createFile(atPath: partial.path, contents: nil) else {
                throw PocketAgentError.writeFailed(path: partial.lastPathComponent,
                                                   reason: "не удалось создать файл для сборки")
            }
            try? ModelStorage.excludeFromBackup(partial)
        }

        let reader: FileHandle
        let writer: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: chunk)
        } catch {
            throw PocketAgentError.readFailed(path: chunk.lastPathComponent,
                                              reason: SystemErrorText.russian(for: error))
        }
        do {
            writer = try FileHandle(forWritingTo: partial)
        } catch {
            try? reader.close()
            throw PocketAgentError.writeFailed(path: partial.lastPathComponent,
                                               reason: SystemErrorText.russian(for: error))
        }
        defer {
            try? reader.close()
            try? writer.close()
        }

        do {
            let startedAt = Date()
            var moved: Int64 = 0
            try writer.seek(toOffset: UInt64(max(0, offset)))
            let sliceSize = 4 * 1024 * 1024
            while true {
                let piece = try reader.read(upToCount: sliceSize)
                guard let piece, !piece.isEmpty else { break }
                try writer.write(contentsOf: piece)
                moved += Int64(piece.count)
            }
            try writer.synchronize()
            noteWrite(bytes: moved, seconds: Date().timeIntervalSince(startedAt))
        } catch {
            throw PocketAgentError.writeFailed(path: partial.lastPathComponent,
                                               reason: SystemErrorText.russian(for: error))
        }
    }
}
