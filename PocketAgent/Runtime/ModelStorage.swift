//
//  ModelStorage.swift
//  PocketAgent / Runtime
//
//  Где живёт файл модели и как приложение его НАХОДИТ.
//
//  Два места, и оба равноправные:
//    • Documents — папка «Карманный агент» в «Файлах». Сюда человек кладёт файл сам:
//      кабелем, по AirDrop, из iCloud Drive, из другого приложения. Система показывает
//      в «Файлах» ТОЛЬКО эту папку — Library/Application Support не видно никогда
//      и никаким ключом Info.plist не открывается.
//    • Library/Application Support/Models — сюда приложение кладёт то, что скачало само.
//
//  ⚠️ ГЛАВНОЕ ИЗМЕНЕНИЕ. Раньше приложение проверяло РОВНО ОДИН путь —
//  Application Support/Models/<имя файла из каталога> — и не перечисляло папки вовсе.
//  Файл с любым другим именем не находился, даже лёжа в правильной папке: человек
//  копировал модель по проводу и видел пустой экран подготовки. Теперь обе папки
//  просматриваются целиком, и годной считается ЛЮБАЯ модель .litertlm, а не одна зашитая.
//
//  Файлы моделей исключаются из резервной копии iCloud — иначе 2,6 ГБ полезут в облако
//  пользователя, и приложение рискует не пройти ревью App Store. Пометка ставится в момент,
//  когда человек взял файл в работу: `ModelImporter.adopt`, `install`, `moveIntoAppStorage`,
//  и на собственную папку хранилища.
//
//  ⚠️ ЧТО ПОИСК ДЕЛАЕТ С ФАЙЛАМИ ЧЕЛОВЕКА: РОВНЫМ СЧЁТОМ НИЧЕГО. Он только читает.
//  Не перемещает, не копирует, не переименовывает, не удаляет — и НЕ ПОМЕЧАЕТ.
//  Раньше пометка «не класть в резервную копию» ставилась КАЖДОМУ найденному файлу
//  прямо при обходе папки — то есть при запуске, при каждом возврате из фона и ещё раз
//  через несколько секунд. Это запись в чужой файл без единого нажатия: файл человек мог
//  положить в Documents для другого приложения, а поведение его резервной копии мы этим
//  меняли молча. Ядро продукта — «записи без подтверждения быть не может», и расширенный
//  атрибут тоже запись.
//

import Foundation

public enum ModelStorage {

    // MARK: - Папки

    /// ~/Library/Application Support/Models — создаётся при первом обращении.
    public static func modelsDirectory() throws -> URL {
        let base: URL
        do {
            base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        } catch {
            throw PocketAgentError.writeFailed(path: "Application Support",
                                               reason: SystemErrorText.russian(for: error))
        }

        let dir = base.appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw PocketAgentError.writeFailed(path: dir.path,
                                                   reason: SystemErrorText.russian(for: error))
            }
        }
        // Не критично, если не получилось: файл всё равно рабочий.
        try? excludeFromBackup(dir)
        return dir
    }

    /// Папка «Карманный агент», которую человек видит в «Файлах».
    /// Именно сюда — и только сюда — можно положить файл снаружи.
    public static func documentsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Все папки, где имеет смысл искать модель.
    ///
    /// Порядок важен: сначала своё хранилище (то, что приложение скачало само),
    /// потом папка человека в «Файлах», потом Documents/Inbox — туда система кладёт
    /// копию, когда другое приложение «отправляет» файл в наше не на месте.
    /// Несуществующие папки просто выпадают из списка — создавать их ради поиска не надо.
    ///
    /// ⚠️ ПОЧЕМУ ЗАГЛЯДЫВАЕМ В ПОДПАПКИ, И ПОЧЕМУ ИМЕННО НА ТРИ ШАГА.
    /// Это не запас на всякий случай, а разбор живого телефона владельца. Он перенёс к нам
    /// из Google AI Edge Gallery не файл, а ПАПКУ ЦЕЛИКОМ, и модель легла так:
    ///
    ///     Карманный агент → «Gemma_4_E4B_it 2» → «v2» → gemma-4-E4B-it.litertlm
    ///
    /// То есть на ДВА уровня глубже, чем смотрело приложение (оно ходило ровно по своей
    /// папке и одной подпапке с заранее известным именем). Файл лежал в правильном месте,
    /// весил 3,41 ГБ — и не находился вообще никогда. Отсюда и «положил модель в папку —
    /// оно не видит модель».
    ///
    /// Три уровня — это тот случай плюс один шаг запаса. Больше нельзя: обход всего
    /// контейнера означал бы чтение тысяч файлов при КАЖДОМ возврате в приложение.
    /// Имена подпапок произвольные («Gemma_4_E4B_it 2», «v2»), поэтому по именам папок
    /// не решаем ничего — только по расширению самого файла.
    static func searchDirectories() -> [(url: URL, location: ModelFileLocation)] {
        var result: [(URL, ModelFileLocation)] = []

        // Своё хранилище берём БЕЗ создания: поиск не должен ничего создавать на диске.
        if let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: false) {
            result.append((support.appendingPathComponent("Models", isDirectory: true), .appStorage))
        }

        if let docs = documentsDirectory() {
            result.append((docs, .documents))
            result.append((docs.appendingPathComponent("Inbox", isDirectory: true), .inbox))
            // Все вложенные папки человека — вглубь на три шага.
            for sub in descendantFolders(of: docs) {
                let isInbox = sub.lastPathComponent.caseInsensitiveCompare("Inbox") == .orderedSame
                result.append((sub, isInbox ? .inbox : .documents))
            }
        }

        // Один и тот же путь мог попасть в список дважды (Inbox назван и явно, и подпапкой) —
        // повтор здесь означал бы задвоенный обход и задвоенные строки на экране.
        var seenPaths = Set<String>()
        return result
            .filter { FileManager.default.fileExists(atPath: $0.0.path) }
            .filter { seenPaths.insert($0.0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
            .map { (url: $0.0, location: $0.1) }
    }

    /// Насколько глубоко заходим в папки человека. Ровно столько, сколько понадобилось
    /// на живом телефоне (модель лежала через две папки), плюс один шаг запаса.
    private static let maximumFolderDepth = 3

    /// Сколько вложенных папок готовы просмотреть всего. Ограничение не от жадности:
    /// папка «Карманный агент» — обычная папка в «Файлах», в неё может попасть что угодно,
    /// а обход должен оставаться мгновенным при каждом возврате в приложение.
    private static let maximumSubfolders = 60

    /// Вложенные папки, слой за слоем, с пределом и по глубине, и по общему числу.
    /// Ничего не создаём и не меняем — только читаем.
    ///
    /// ⚠️ Обход именно послойный, а не «вглубь до упора»: при упоре в предел числа папок
    /// мы теряем самые дальние, а не соседей найденного файла. Ссылки на папки не
    /// разворачиваем — иначе можно уйти по кругу и не вернуться.
    private static func descendantFolders(of directory: URL) -> [URL] {
        var found: [URL] = []
        var layer = [directory]
        var depth = 0

        while depth < maximumFolderDepth, !layer.isEmpty, found.count < maximumSubfolders {
            var next: [URL] = []
            for folder in layer {
                for child in childFolders(of: folder) {
                    guard found.count < maximumSubfolders else { break }
                    found.append(child)
                    next.append(child)
                }
            }
            layer = next
            depth += 1
        }
        return found
    }

    /// Папки первого уровня внутри одной папки, по алфавиту.
    private static func childFolders(of directory: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        return items
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Куда приложение заглядывало, ЧЕЛОВЕЧЕСКИМ ЯЗЫКОМ — для честной строки на экране
    /// «смотрю вот здесь». Без этой строки человек не может отличить «ищу не там»
    /// от «ищу там, но файла нет».
    ///
    /// ⚠️ Вложенные папки НЕ перечисляем по именам: их бывает несколько десятков,
    /// и строка состояния превратилась бы в простыню. Говорим числом.
    static func searchPlaceNames() -> [String] {
        let ownFolder = documentsDirectory()?.resolvingSymlinksInPath().standardizedFileURL.path
        var names: [String] = []
        var nestedCount = 0

        for place in searchDirectories() {
            switch place.location {
            case .bundle, .appStorage:
                if !names.contains("внутри самого приложения") {
                    names.append("внутри самого приложения")
                }
            case .inbox:
                if !names.contains("то, что прислали другие приложения") {
                    names.append("то, что прислали другие приложения")
                }
            case .documents:
                let path = place.url.resolvingSymlinksInPath().standardizedFileURL.path
                if let ownFolder, path == ownFolder {
                    let own = "«Файлы» → На iPhone → Карманный агент"
                    if !names.contains(own) { names.append(own) }
                } else {
                    nestedCount += 1
                }
            }
        }

        if nestedCount > 0 {
            names.append("и все папки внутри неё (\(nestedCount))")
        }
        return names
    }

    /// Куда кладём конкретную модель.
    public static func fileURL(for model: ModelDescriptor) throws -> URL {
        try modelsDirectory().appendingPathComponent(model.fileName)
    }

    /// Путь для активной модели.
    public static func modelFileURL() throws -> URL {
        try fileURL(for: ModelSpec.descriptor)
    }

    /// Куда складываем данные для докачки после обрыва.
    public static func resumeDataURL(for model: ModelDescriptor) throws -> URL {
        try modelsDirectory().appendingPathComponent("\(model.id).resume")
    }

    // MARK: - Поиск готового файла

    /// Модель могли положить прямо в бандл приложения (тогда качать нечего).
    /// Бандл доступен только для чтения — поэтому cacheDir движка обязан быть отдельным.
    public static func bundledModelURL(for model: ModelDescriptor) -> URL? {
        Bundle.main.url(forResource: model.bundleResourceName,
                        withExtension: model.fileExtension)
    }

    /// Готовый к работе файл ИМЕННО ЭТОЙ модели: сначала бандл, потом своё хранилище,
    /// потом папка человека в «Файлах».
    /// nil — файла с таким именем нигде нет.
    ///
    /// ⚠️ Поиск по папке человека добавлен намеренно: файл, положенный в «Файлы»
    /// (кабелем, AirDrop, из iCloud Drive), раньше не находился вовсе — приложение
    /// смотрело ровно один путь в своём хранилище.
    public static func installedModelURL(for model: ModelDescriptor) -> URL? {
        if let bundled = bundledModelURL(for: model) {
            return bundled
        }
        if let downloaded = try? fileURL(for: model),
           FileManager.default.fileExists(atPath: downloaded.path) {
            return downloaded
        }
        // Тот же файл, но лежащий в папке человека, — это тоже установленная модель.
        for place in searchDirectories() where place.location != .appStorage {
            let candidate = place.url.appendingPathComponent(model.fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Скачан ли файл нужного размера (быстрая проверка без хеша).
    public static func isDownloadComplete(_ model: ModelDescriptor) -> Bool {
        guard let url = installedModelURL(for: model) else { return false }
        return byteSize(of: url) == model.byteSize
    }

    /// Сколько места занимает модель: у файла — его размер, у ПАПКИ — сумма по всем
    /// её файлам.
    ///
    /// ⚠️ Про папку спрашивать необходимо: у модели Apple модель и есть папка, а система
    /// на вопрос «сколько весит папка» отвечает размером самой записи о ней — сотней байт.
    /// Показать человеку «модель весит 96 байт» хуже, чем не показать ничего.
    public static func byteSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return MLXModelFolder.totalBytes(of: url) }
        if let size = values?.fileSize { return Int64(size) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Место на диске

    /// Хватит ли места: модель + запас (файл сначала лежит во временной папке).
    public static func hasEnoughFreeSpace(for model: ModelDescriptor) -> Bool {
        availableBytes() > Int64(Double(model.byteSize) * 1.2)
    }

    /// Сколько места реально можно занять «важными» данными.
    public static func availableBytes() -> Int64 {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true),
              let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return free
    }

    // MARK: - Резервная копия

    /// 2,6 ГБ в iCloud не нужны никому.
    ///
    /// ⚠️ Копия URL нужна не «на всякий случай»: `setResourceValues` объявлен изменяющим
    /// сам URL (он кэширует значения внутри себя), поэтому вызвать его у константы нельзя.
    ///
    /// ⚠️ Это ЗАПИСЬ в файл (расширенный атрибут). Звать только там, где человек уже
    /// подтвердил, что файл берётся в работу, — не при обходе папки.
    public static func excludeFromBackup(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }

    // MARK: - Удаление

    /// Удалить скачанную модель (файл в бандле, разумеется, не трогаем).
    public static func removeDownloadedModel(_ model: ModelDescriptor) throws {
        let url = try fileURL(for: model)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw PocketAgentError.writeFailed(path: url.path,
                                                   reason: SystemErrorText.russian(for: error))
            }
        }
        clearResumeData(for: model)
    }

    /// Сколько занимает скачанное — для экрана настроек.
    public static func downloadedBytes(for model: ModelDescriptor) -> Int64 {
        guard let url = try? fileURL(for: model),
              FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return byteSize(of: url)
    }

    // MARK: - Данные для докачки

    public static func saveResumeData(_ data: Data, for model: ModelDescriptor) {
        guard let url = try? resumeDataURL(for: model) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func loadResumeData(for model: ModelDescriptor) -> Data? {
        guard let url = try? resumeDataURL(for: model),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func clearResumeData(for model: ModelDescriptor) {
        guard let url = try? resumeDataURL(for: model) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Наша собственная загрузка, оборванная на середине

    /// Служебные файлы НАШЕЙ загрузки, лежащие рядом с моделями.
    ///
    /// ⚠️ ЗАЧЕМ ИХ ЗНАТЬ ПО ИМЕНАМ. Приложение показывает человеку всё, что видит рядом
    /// с моделями, — и раньше в этот список попадали наши же черновики: собираемый файл
    /// «…litertlm.partial» и план докачки «…litertlm.plan». Про них было написано
    /// «копирование не дошло до конца — у него лишний хвост в имени, скопируйте модель
    /// ещё раз». Человек ничего не копировал: это оборвалась наша загрузка, и рядом
    /// лежал план, по которому её можно продолжить. Теперь про такую пару рассказывает
    /// карточка «Загрузка не докачана», а сами служебные файлы человеку не показываются.
    enum DownloadLeftover {
        /// Собираемый файл: «<опознаватель модели>.partial».
        static let partialExtension = "partial"
        /// План докачки: «<опознаватель модели>.plan».
        static let planExtension = "plan"
        /// Точка докачки обычной (однопоточной) загрузки: «<опознаватель модели>.resume».
        static let resumeExtension = "resume"

        /// Это один из наших служебных файлов загрузки?
        static func isOurs(_ fileName: String) -> Bool {
            let ext = (fileName as NSString).pathExtension.lowercased()
            if ext == partialExtension || ext == planExtension || ext == resumeExtension {
                return true
            }
            // Кусок: «…chunk12». Номер обязателен — иначе под правило попал бы
            // чужой файл со словом chunk в расширении.
            guard ext.hasPrefix("chunk") else { return false }
            let tail = ext.dropFirst("chunk".count)
            return !tail.isEmpty && tail.allSatisfy(\.isNumber)
        }

        /// Опознаватель модели по имени служебного файла.
        static func modelID(of fileName: String) -> String {
            (fileName as NSString).deletingPathExtension
        }
    }

    /// Незаконченная загрузка: что качали, сколько уже лежит на телефоне и чем продолжить.
    ///
    /// ⚠️ Появилось после живого случая 10.08.2026: владелец бросил загрузку на 68 кусках
    /// из 76, приложение перезапустилось — и о недокачанных 2,28 ГБ на экране не было
    /// ни слова, кроме строки «этот файл не подошёл» про наш же черновик.
    public struct UnfinishedModelDownload: Sendable, Equatable, Identifiable {

        public var id: String { modelID }

        /// Опознаватель модели — он же имя служебных файлов.
        public let modelID: String
        /// Имя файла модели, каким оно станет после загрузки.
        public let fileName: String
        /// Имя для человека.
        public let displayName: String
        /// Сколько байт уже собрано на телефоне.
        public let doneBytes: Int64
        /// Сколько байт во всём файле. 0 — плана нет, размер неизвестен.
        public let totalBytes: Int64
        /// Описание модели, по которому загрузку можно продолжить. nil — продолжить нечем.
        public let descriptor: ModelDescriptor?
        /// Это недособранная ПАПКА модели Apple, а не один файл.
        ///
        /// ⚠️ Отличать обязательно: у папки другой способ продолжить. Кнопки «Докачать»
        /// у неё нет (списка файлов в обрывках не осталось), но и потерянным скачанное
        /// не считается — начните загрузку этой же модели заново, и докачается только
        /// недостающее. Без этого признака экран сказал бы «продолжить не получится»
        /// и человек стёр бы гигабайты, которые ему ещё пригодились бы.
        public let isFolder: Bool

        public init(modelID: String,
                    fileName: String,
                    displayName: String,
                    doneBytes: Int64,
                    totalBytes: Int64,
                    descriptor: ModelDescriptor?,
                    isFolder: Bool = false) {
            self.modelID = modelID
            self.fileName = fileName
            self.displayName = displayName
            self.doneBytes = doneBytes
            self.totalBytes = totalBytes
            self.descriptor = descriptor
            self.isFolder = isFolder
        }

        /// «2,28 из 2,55 ГБ» — или просто «скачано 2,13 ГБ», когда полный размер неизвестен.
        public var progressText: String {
            guard totalBytes > 0 else { return "скачано \(HumanFormat.bytes(doneBytes))" }
            return "\(HumanFormat.bytes(doneBytes)) из \(HumanFormat.bytes(totalBytes))"
        }

        /// Сколько освободится, если стереть недокачанное.
        public var occupiedText: String { HumanFormat.bytes(doneBytes) }

        /// Продолжить можно.
        public var canResume: Bool { descriptor != nil && totalBytes > doneBytes }
    }

    /// Все наши незаконченные загрузки. Работа с диском — звать вне главного потока.
    ///
    /// Пусто — недокачанного нет. Части модели-папки отдельными строками НЕ идут:
    /// у неё качается восемь файлов сразу, и строка на каждый завалила бы экран
    /// черновиками. Вместо этого вся недособранная папка — ОДНА строка.
    ///
    /// ⚠️ РАНЬШЕ ПАПКИ НЕ БЫЛО ВИДНО ВООБЩЕ, И ЭТО СТОИЛО ЧЕЛОВЕКУ ГИГАБАЙТОВ. Части
    /// пропускались по косой черте в имени, а больше про них никто не рассказывал:
    /// ни строки на экране, ни способа стереть. Скачал три гигабайта из пяти, закрыл
    /// приложение — и они лежали мёртвым грузом, потому что в счёт «установлено»
    /// недособранная папка тоже не идёт.
    public static func unfinishedDownloads() -> [UnfinishedModelDownload] {
        let manager = FileManager.default
        guard let directory = try? manager.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: false)
            .appendingPathComponent("Models", isDirectory: true),
              let items = try? manager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: [.fileSizeKey],
                                                           options: [.skipsSubdirectoryDescendants]) else {
            return []
        }

        var result: [UnfinishedModelDownload] = []
        var seen = Set<String>()

        // Сначала планы: в них записано и что качали, и сколько уже собрано.
        for url in items where url.pathExtension.lowercased() == DownloadLeftover.planExtension {
            let modelID = DownloadLeftover.modelID(of: url.lastPathComponent)
            guard let plan = ModelDownloadPlanStore.load(modelID: modelID),
                  !plan.isComplete,
                  // Часть модели-папки: на диске она лежит внутри недособранной папки,
                  // и её имя содержит косую черту.
                  !plan.fileName.contains("/") else { continue }
            guard seen.insert(modelID).inserted else { continue }

            // Имя берём у описания, если оно нашлось: у знакомой модели там человеческое
            // «Gemma 4 E2B», а не имя файла.
            let descriptor = resumableDescriptor(for: plan)
            result.append(UnfinishedModelDownload(
                modelID: modelID,
                fileName: plan.fileName,
                displayName: descriptor?.displayName
                    ?? ModelCatalog.humanName(forFileName: plan.fileName),
                doneBytes: plan.doneBytes,
                totalBytes: plan.totalBytes,
                descriptor: descriptor
            ))
        }

        // Недособранная папка модели Apple — ОДНОЙ строкой на всю папку.
        //
        // ⚠️ Считаем по самой папке на диске, а не по планам её частей: файлы, которые
        // уже доехали целиком, планов не имеют вовсе (план стирается, как только часть
        // собрана), а место занимают — и как раз они и есть те гигабайты, о которых
        // человеку надо знать. Полный размер папки взять неоткуда: список её файлов
        // живёт в описании модели, а его в обрывках не осталось. Поэтому честное
        // «скачано столько-то», без «из».
        for url in items where url.pathExtension.lowercased() == ModelImporter.temporaryExtension {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let folderName = url.deletingPathExtension().lastPathComponent
            guard seen.insert(folderName).inserted else { continue }
            let size = byteSize(of: url)
            guard size > 0 else { continue }
            result.append(UnfinishedModelDownload(
                modelID: folderName,
                fileName: folderName,
                displayName: ModelCatalog.humanName(forFileName: folderName),
                doneBytes: size,
                totalBytes: 0,
                descriptor: nil,
                isFolder: true
            ))
        }

        // Собираемый файл без плана — сирота от давней загрузки. Продолжить его нечем,
        // но молчать про занятое место нельзя: человек должен уметь его освободить.
        for url in items where url.pathExtension.lowercased() == DownloadLeftover.partialExtension {
            let modelID = DownloadLeftover.modelID(of: url.lastPathComponent)
            guard seen.insert(modelID).inserted else { continue }
            let size = byteSize(of: url)
            guard size > 0 else { continue }
            result.append(UnfinishedModelDownload(
                modelID: modelID,
                fileName: modelID,
                displayName: ModelCatalog.humanName(forFileName: modelID),
                doneBytes: size,
                totalBytes: 0,
                descriptor: nil
            ))
        }

        return result.sorted { $0.doneBytes > $1.doneBytes }
    }

    /// Полный размер файла по НАШЕМУ плану загрузки. 0 — про этот файл плана нет.
    ///
    /// Нужен проверке файла: размер в плане назвал сервер, и это точное число,
    /// которому можно верить больше, чем догадке по разметке внутри файла.
    public static func plannedTotalBytes(forFileName fileName: String) -> Int64 {
        let manager = FileManager.default
        guard let directory = try? manager.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: false)
            .appendingPathComponent("Models", isDirectory: true),
              let items = try? manager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: nil,
                                                           options: [.skipsSubdirectoryDescendants]) else {
            return 0
        }
        for url in items where url.pathExtension.lowercased() == DownloadLeftover.planExtension {
            let modelID = DownloadLeftover.modelID(of: url.lastPathComponent)
            guard let plan = ModelDownloadPlanStore.load(modelID: modelID),
                  plan.fileName.caseInsensitiveCompare(fileName) == .orderedSame else { continue }
            return plan.totalBytes
        }
        return 0
    }

    /// Стереть недокачанное: план, собираемый файл и все куски.
    ///
    /// ⚠️ У ПАПКИ СТИРАТЬ НАДО ДВА РАЗНЫХ МЕСТА. Планы частей освобождают только куски,
    /// которые ещё едут; сами доехавшие файлы лежат в недособранной папке и весят почти
    /// всё. Уберём одно без другого — человек нажмёт «стереть», а место не освободится.
    public static func discardUnfinishedDownload(_ item: UnfinishedModelDownload) {
        guard item.isFolder else {
            ModelDownloadPlanStore.clear(modelID: item.modelID)
            return
        }

        let manager = FileManager.default
        guard let directory = try? manager.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: false)
            .appendingPathComponent("Models", isDirectory: true) else { return }

        // Сначала планы частей: у части в имени файла стоит «<папка>.import/<файл>».
        let prefix = "\(item.fileName).\(ModelImporter.temporaryExtension)/"
        if let items = try? manager.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsSubdirectoryDescendants]) {
            for url in items where url.pathExtension.lowercased() == DownloadLeftover.planExtension {
                let modelID = DownloadLeftover.modelID(of: url.lastPathComponent)
                guard let plan = ModelDownloadPlanStore.load(modelID: modelID),
                      plan.fileName.hasPrefix(prefix) else { continue }
                ModelDownloadPlanStore.clear(modelID: modelID)
            }
        }

        // И сама недособранная папка — в ней и лежат скачанные гигабайты.
        let folder = directory.appendingPathComponent("\(item.fileName).\(ModelImporter.temporaryExtension)",
                                                      isDirectory: true)
        try? manager.removeItem(at: folder)
    }

    /// Описание модели, по которому можно ПРОДОЛЖИТЬ оборванную загрузку.
    ///
    /// ⚠️ ЗАЧЕМ ЭТО ВООБЩЕ НУЖНО. Модель, найденную поиском по интернету, приложение
    /// помнит только до перезапуска — а загрузка переживает и перезапуск, и выключение
    /// телефона. После перезапуска продолжать было нечем: строки такой модели нет ни
    /// в справочнике, ни на телефоне. Всё нужное лежит в самом плане, поэтому описание
    /// собирается из него: тот же опознаватель, то же имя файла, тот же размер —
    /// а значит загрузчик признаёт план своим и докачивает только недостающее.
    ///
    /// nil — продолжить нечем: адрес совсем не разобрать.
    /// Врать кнопкой «Докачать», которая ничего не сделает, нельзя.
    ///
    /// ⚠️ ЗЕРКАЛО ТОЖЕ РАЗБИРАЕМ, И ЭТО НЕ МЕЛОЧЬ. Раньше здесь принимался только адрес
    /// Hugging Face — а источник теперь выбирается замером, и загрузка спокойно уходит
    /// на ModelScope, когда он быстрее. То есть чем быстрее качали, тем вернее человек
    /// читал «приложение не помнит, откуда качало этот файл» и терял скачанное.
    static func resumableDescriptor(for plan: ModelDownloadPlan) -> ModelDescriptor? {
        // Модель из справочника — берём её описание целиком: там и контрольная сумма.
        if let known = ModelCatalog.model(withID: plan.modelID),
           known.fileName == plan.fileName,
           known.byteSize == plan.totalBytes {
            return known
        }
        guard plan.totalBytes > 0,
              let url = URL(string: plan.urlString),
              let host = url.host?.lowercased() else {
            return nil
        }
        // Свой ли это адрес: либо официальный сайт, либо зеркало, записанное в плане.
        let isKnownSource = host == "huggingface.co" || host.hasSuffix(".huggingface.co")
            || ModelSourceCatalog.source(withID: plan.sourceID)?.urlTemplate.contains(host) == true
        guard isKnownSource else { return nil }

        // Адрес вида …/<кто>/<что>/resolve/<версия>/<путь внутри репозитория>.
        //
        // ⚠️ Ищем слово «resolve», а не считаем части от начала: у зеркала перед именем
        // репозитория стоит ещё одна часть («/models/…»), и жёсткий отсчёт от начала
        // разбирал бы его адрес неверно.
        let parts = url.path.split(separator: "/").map(String.init)
        guard let resolveIndex = parts.firstIndex(of: "resolve"),
              resolveIndex >= 2,
              parts.count > resolveIndex + 2 else { return nil }
        let repoID = "\(parts[resolveIndex - 2])/\(parts[resolveIndex - 1])"
        // ⚠️ У зеркала своё слово версии («master»), и в описание оно попадёт как есть.
        // Для докачки это безразлично: план на диске уже знает и адрес, и источник,
        // а описание нужно ему лишь чтобы узнать себя по имени файла и размеру.
        let commit = parts[resolveIndex + 1]
        let tail = parts.dropFirst(resolveIndex + 2).joined(separator: "/")
        let repoPath = tail.removingPercentEncoding ?? tail

        return ModelDescriptor(
            id: plan.modelID,
            displayName: ModelCatalog.humanName(forFileName: plan.fileName),
            repoID: repoID,
            repoCommit: commit,
            fileName: plan.fileName,
            byteSize: plan.totalBytes,
            // Контрольной суммы в плане нет. Это не беда: она нужна для сверки после
            // загрузки, а её отсутствие лишь означает, что зеркала мы брать не станем.
            sha256: "",
            summary: "",
            hardware: ModelCatalog.hardware(forFileName: plan.fileName),
            origin: .catalog,
            repoPath: repoPath == plan.fileName ? nil : repoPath
        )
    }

    // MARK: - Кэш движка

    /// Движку нужна записываемая папка под свой кэш: рядом с моделью писать нельзя,
    /// если модель лежит в бандле (он только для чтения).
    public static func engineCacheDirectory() throws -> URL {
        let base: URL
        do {
            base = try FileManager.default.url(for: .cachesDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        } catch {
            throw PocketAgentError.writeFailed(path: "Caches",
                                               reason: SystemErrorText.russian(for: error))
        }
        let dir = base.appendingPathComponent("LiteRTLM", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Сбросить кэш движка (например, после смены версии модели).
    public static func clearEngineCache() {
        guard let dir = try? engineCacheDirectory() else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Что можно запустить прямо сейчас

    /// Модель, готовая к работе БЕЗ единого нажатия: найдена на телефоне, проверена,
    /// выбор человека учтён. nil — запускать нечего, нужен экран подготовки.
    ///
    /// Именно эту пару и должен спрашивать движок вместо «файл с зашитым именем»:
    /// описание приходит от найденного файла, поэтому размер и требования по памяти
    /// у него всегда свои, а не от единственной модели из каталога.
    ///
    /// ⚠️ Работа с диском — звать вне главного потока.
    public static func readyModel() -> (descriptor: ModelDescriptor, url: URL)? {
        guard let file = ModelDiscovery.best() else { return nil }
        return (file.descriptor, file.url)
    }

    // MARK: - Файл из облака

    /// В каком виде файл лежит на телефоне.
    public enum CloudState: Sendable, Equatable {
        /// Обычный локальный файл.
        case local
        /// Файлом управляет iCloud, но байты на телефоне есть.
        case downloaded
        /// Только имя: содержимое лежит в облаке, читать нечего.
        case placeholder
    }

    /// Файл может оказаться «заглушкой» из iCloud Drive: имя видно, содержимого нет.
    /// Читать такой файл — значит молча качать гигабайты по той связи, которая сейчас есть.
    ///
    /// ⚠️ Состояние `.downloaded` считается ГОДНЫМ: оно означает, что байты на телефоне
    /// есть, а отставать может лишь версия. Файл модели никто не редактирует, поэтому
    /// отвергать его (как делалось раньше) значило бы отказывать человеку без причины.
    public static func cloudState(of url: URL) -> CloudState {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                       .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return .local }

        let status = values?.ubiquitousItemDownloadingStatus
        if status == .current || status == .downloaded { return .downloaded }
        return .placeholder
    }

    /// Попросить систему выгрузить файл из облака на телефон.
    ///
    /// ⚠️ Работает АСИНХРОННО и без обработчика завершения: управление возвращается сразу,
    /// а готовность узнаётся повторной проверкой `cloudState(of:)`. Поэтому экран должен
    /// сказать «скачиваю из облака» и перепроверить позже, а не ждать на месте.
    @discardableResult
    public static func requestCloudDownload(_ url: URL) -> Bool {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Путь внутри контейнера

    /// Путь файла ОТНОСИТЕЛЬНО домашней папки приложения.
    ///
    /// ⚠️ Абсолютный путь запоминать нельзя: в нём стоит идентификатор контейнера,
    /// который меняется при переустановке приложения. Сохранённый абсолютный путь
    /// после этого указывает в никуда, и модель «пропадает» без всякой причины.
    public static func containerRelativePath(of url: URL) -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(home + "/") else { return nil }
        return String(path.dropFirst(home.count + 1))
    }

    /// Обратное превращение: относительный путь → сегодняшний абсолютный.
    public static func url(forContainerRelativePath relativePath: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath)
    }

    /// В какой из наших папок лежит файл. nil — вне известных папок.
    /// Из нескольких подходящих берём САМУЮ ГЛУБОКУЮ: файл в Documents/Inbox
    /// формально лежит и в Documents тоже, но назвать его надо «прислан из другого приложения».
    static func location(of url: URL) -> ModelFileLocation? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var bestLength = -1
        var bestLocation: ModelFileLocation?

        for place in searchDirectories() {
            let directory = place.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(directory + "/"), directory.count > bestLength else { continue }
            bestLength = directory.count
            bestLocation = place.location
        }
        return bestLocation
    }
}

// MARK: - Где лежит найденный файл

/// Место, откуда приехал файл модели, — человеческим языком.
public enum ModelFileLocation: String, Sendable, Equatable, Codable {
    /// Вшит в само приложение.
    case bundle
    /// Своё хранилище: Library/Application Support/Models.
    case appStorage
    /// Папка «Карманный агент» в «Файлах».
    case documents
    /// Documents/Inbox — сюда система кладёт файл, присланный из другого приложения.
    case inbox

    /// Как назвать это место человеку.
    public var humanPlace: String {
        switch self {
        case .bundle:     return "внутри приложения"
        case .appStorage: return "внутри приложения"
        case .documents:  return "в вашей папке в «Файлах»"
        case .inbox:      return "прислан из другого приложения"
        }
    }

    /// Можно ли удалить этот файл руками человека (и значит, стоит предупредить).
    public var isVisibleToPerson: Bool {
        self == .documents || self == .inbox
    }
}

// MARK: - Найденный файл модели

/// Один файл модели, найденный на телефоне.
///
/// ⚠️ Содержимое файла разбирает НЕ этот тип, а `ModelVerifier.inspect`: он читает
/// первые килобайты, узнаёт версию формата, состав модели, требование к железу
/// и целостность. Здесь лежит только то, что нужно списку на экране: где файл,
/// сколько весит и можно ли его брать в работу.
public struct DiscoveredModelFile: Sendable, Equatable, Identifiable {

    /// Путь внутри контейнера — он же устойчивый опознаватель: переживает
    /// перезапуск и переустановку приложения, в отличие от полного пути.
    public var id: String { relativePath }

    public let url: URL
    public let relativePath: String
    public let fileName: String
    public let byteSize: Int64
    public let location: ModelFileLocation
    /// Когда файл последний раз менялся — по этому полю сортируем «самое свежее сверху».
    public let modifiedAt: Date
    /// Описание модели: из справочника, если файл узнан, иначе собранное по самому файлу.
    public let descriptor: ModelDescriptor
    /// Насколько мы уверены, что это за файл.
    public let confidence: ModelFileConfidence
    /// Честные оговорки для человека: «сборка только для видеочипа», «памяти может не хватить».
    public let warnings: [String]
    /// Файл лежит в iCloud и на телефон не выгружен.
    public let isCloudPlaceholder: Bool
    /// Почему файл не годится, человеческими словами. nil — годится.
    public let problem: String?
    /// Модель лежит ПАПКОЙ из нескольких файлов (формат Apple), а не одним файлом.
    /// Тогда `byteSize` — сумма по папке, а `url` указывает на саму папку.
    public let isFolder: Bool

    public init(url: URL,
                relativePath: String,
                fileName: String,
                byteSize: Int64,
                location: ModelFileLocation,
                modifiedAt: Date,
                descriptor: ModelDescriptor,
                confidence: ModelFileConfidence,
                warnings: [String],
                isCloudPlaceholder: Bool,
                problem: String?,
                isFolder: Bool = false) {
        self.url = url
        self.relativePath = relativePath
        self.fileName = fileName
        self.byteSize = byteSize
        self.location = location
        self.modifiedAt = modifiedAt
        self.descriptor = descriptor
        self.confidence = confidence
        self.warnings = warnings
        self.isCloudPlaceholder = isCloudPlaceholder
        self.problem = problem
        self.isFolder = isFolder
    }

    /// Вид модели: файл Google или папка Apple.
    public var format: ModelFileFormat {
        isFolder ? .mlx : ModelFileFormat.detect(fileName: fileName)
    }

    /// Можно ли прямо сейчас запускать модель из этого файла.
    public var isUsable: Bool { problem == nil && !isCloudPlaceholder }

    /// Можно ли выбрать эту модель САМИМ, без человека.
    ///
    /// ⚠️ Отдельно от `isUsable` ровно по одной причине: движок Apple ещё не вшит
    /// в сборщик агента, и подсунуть папку движку Google — значит получить безликое
    /// «не удалось создать движок» на ровном месте. Человеку папку показываем и выбрать
    /// не мешаем (это его решение), но САМИ на неё не переключаемся.
    /// Когда движок будет подключён, снимается это одним переключателем —
    /// `MLXModelFolder.isEngineWired`.
    public var canStartAutomatically: Bool {
        isUsable && (!isFolder || MLXModelFolder.isEngineWired)
    }

    /// Файл узнан справочником приложения.
    public var isKnownToCatalog: Bool { confidence != .unknown }

    /// Имя для человека: «Gemma 4 E4B».
    public var displayName: String { descriptor.displayName }

    /// Вложенные папки, в которых лежит файл, — «Gemma_4_E4B_it 2 → v2».
    /// nil — файл лежит прямо в папке человека или внутри приложения.
    ///
    /// ⚠️ Нужно человеку, а не нам: именно вложенность и была причиной, по которой модель
    /// «не находилась». Увидев, ГДЕ файл нашёлся, человек понимает, что произошло, —
    /// и в следующий раз кладёт файл туда, куда ему удобно, без гадания.
    public var subfolderNote: String? {
        guard location == .documents || location == .inbox else { return nil }
        var parts = relativePath.split(separator: "/").map(String.init)
        // Первый кусок — служебное имя папки самого приложения, человеку оно ничего
        // не говорит; последний — имя файла, оно и так показано рядом.
        guard parts.count > 2 else { return nil }
        parts.removeFirst()
        parts.removeLast()
        return parts.joined(separator: " → ")
    }

    /// Размер человеческим языком: «3,66 ГБ».
    public var sizeText: String { HumanFormat.bytes(byteSize) }

    /// Одна строка под именем на экране выбора.
    public var subtitle: String {
        if isCloudPlaceholder {
            return "Скачиваю из облака — файл пока хранится в iCloud"
        }
        if let problem {
            return problem
        }
        return "\(sizeText) · \(location.humanPlace)"
    }
}

// MARK: - Файл, который лежит рядом, но моделью не стал

/// Файл, который приложение УВИДЕЛО, но взять в работу не может.
///
/// ⚠️ Ради этого типа всё и заводилось. Раньше такие файлы отбрасывались МОЛЧА: человек
/// клал модель, приложение её не показывало, и понять почему было нельзя вообще никак —
/// ни «вижу, но файл ещё копируется», ни «вижу, но он остался в облаке», ни «это не тот
/// файл». Человек видел пустой экран и решал, что приложение сломано.
public struct RejectedModelFile: Sendable, Equatable, Identifiable {

    /// Путь внутри контейнера — он же устойчивый опознаватель строки на экране.
    public var id: String { relativePath }

    public let relativePath: String
    public let fileName: String
    public let byteSize: Int64
    public let location: ModelFileLocation
    /// Почему не годится — человеческими словами, готовой фразой для экрана.
    public let reason: String

    public init(relativePath: String,
                fileName: String,
                byteSize: Int64,
                location: ModelFileLocation,
                reason: String) {
        self.relativePath = relativePath
        self.fileName = fileName
        self.byteSize = byteSize
        self.location = location
        self.reason = reason
    }

    /// Размер человеческим языком. Ноль байт — про размер молчим: у заглушки из облака
    /// его попросту нет, и «0 байт» человека только запутает.
    public var sizeText: String? {
        byteSize > 0 ? HumanFormat.bytes(byteSize) : nil
    }
}

// MARK: - Что дал один проход поиска

/// Итог одного просмотра папок: что нашли, что отвергли и где вообще смотрели.
public struct ModelScanResult: Sendable, Equatable {

    /// Файлы моделей. Негодные тоже здесь — у них заполнено `problem`.
    public let files: [DiscoveredModelFile]
    /// Файлы, которые моделью не являются, но человеку про них сказать надо.
    public let rejected: [RejectedModelFile]
    /// Куда заглядывали, человеческим языком.
    public let places: [String]
    /// Когда закончили смотреть — чтобы экран мог сказать «смотрел только что».
    public let finishedAt: Date

    public init(files: [DiscoveredModelFile],
                rejected: [RejectedModelFile],
                places: [String],
                finishedAt: Date) {
        self.files = files
        self.rejected = rejected
        self.places = places
        self.finishedAt = finishedAt
    }
}

// MARK: - Поиск моделей на телефоне

/// Кто и когда ищет модели.
///
/// ⚠️ События «в закрытое приложение положили файл» в iOS не существует: разбудить
/// приложение из-за изменения собственной Documents система не умеет. Поэтому поиск
/// запускается в трёх точках — при запуске, при возврате из фона и по кнопке «Обновить».
/// Первых двух хватает на обычный случай: человек свернул приложение, открыл «Файлы»,
/// положил файл и вернулся.
///
/// Стоимость поиска — перечисление трёх папок на один уровень плюс чтение первых
/// килобайт каждого файла .litertlm. Это мгновение; sha256 по 2,6 ГБ здесь не считается
/// НИКОГДА — он нужен только для файлов, которые приложение скачало само.
public enum ModelDiscovery {

    /// Последний результат поиска. Читается экранами, обновляется `rescan()`.
    /// Читать можно с любого потока: доступ закрыт замком.
    public static var cached: [DiscoveredModelFile] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Файлы, которые видели рядом с моделями, но взять не смогли. Читается экранами.
    public static var rejectedCached: [RejectedModelFile] {
        lock.lock()
        defer { lock.unlock() }
        return rejectedStorage
    }

    /// Когда последний раз смотрели папки. nil — ни разу.
    public static var lastScanAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastScanDate
    }

    private static var storage: [DiscoveredModelFile] = []
    private static var rejectedStorage: [RejectedModelFile] = []
    private static var lastScanDate: Date?

    /// Замок вокруг кэша: поиск идёт вне главного потока, а читают его экраны.
    private static let lock = NSLock()

    /// С какого размера посторонний файл достоин упоминания на экране.
    ///
    /// ⚠️ Порог нужен, чтобы не сыпать человеку в лицо всякую мелочь: в папке лежит
    /// наша же подсказка «Как положить модель», туда попадают заметки и картинки.
    /// А вот увесистый файл рядом с пустым списком моделей — это почти всегда та самая
    /// модель, которую переименовали, недокопировали или оставили лежать в архиве.
    private static let strangerNoticeBytes: Int64 = 16 * 1024 * 1024

    /// Сколько неподошедших файлов показываем человеку. Дальше это уже не объяснение,
    /// а список содержимого папки.
    private static let maximumRejectedShown = 6

    /// Сколько секунд после последней записи файл считается «ещё копируется».
    ///
    /// ⚠️ Признака «копирование идёт» в системе нет: запись в папке появляется сразу,
    /// а содержимое дописывается ещё минуту. Заголовок при этом уже на месте, и разбор
    /// начала файла проходит — приложение решило бы, что модель готова, а движок молча
    /// отказался бы её открыть. Поэтому только что изменённый файл помечаем
    /// «ещё копируется»; следующий поиск снимет пометку сам.
    private static let settleSeconds: TimeInterval = 2

    /// Найти все файлы моделей. Работа с диском — звать вне главного потока.
    @discardableResult
    public static func rescan() -> [DiscoveredModelFile] {
        rescanDetailed().files
    }

    /// То же самое, но с полным отчётом: что нашли, что отвергли и где смотрели.
    ///
    /// ⚠️ Отчёт нужен экрану подготовки. Без него человек, положивший файл, видел ровно
    /// пустоту: ни «сколько вижу», ни «где смотрел», ни «почему не взял этот файл».
    @discardableResult
    public static func rescanDetailed() -> ModelScanResult {
        var found: [DiscoveredModelFile] = []
        var rejected: [RejectedModelFile] = []
        var seen = Set<String>()
        var seenRejected = Set<String>()

        for place in ModelStorage.searchDirectories() {
            let contents = files(in: place.url)

            for url in contents.models {
                switch examine(url, location: place.location) {
                case .model(let file):
                    // Один и тот же файл может попасться дважды (папка и её подпапка) —
                    // берём первый и не задваиваем список.
                    if seen.insert(file.relativePath).inserted { found.append(file) }
                case .rejected(let note):
                    if seenRejected.insert(note.relativePath).inserted { rejected.append(note) }
                case .ignore:
                    break
                }
            }

            // Модель Apple — папка целиком. Она попадает в тот же список, что и файлы:
            // человеку всё равно, из скольких файлов состоит его модель.
            for url in contents.folders {
                switch examineFolder(url, location: place.location) {
                case .model(let file):
                    if seen.insert(file.relativePath).inserted { found.append(file) }
                case .rejected(let note):
                    if seenRejected.insert(note.relativePath).inserted { rejected.append(note) }
                case .ignore:
                    break
                }
            }

            // Обрывки нашей же установки: целые доводим до готовой модели, неполные
            // убираем и объясняем. Делается до строк-отказов, чтобы спасённая модель
            // попала в список тем же проходом.
            for url in contents.leftovers {
                switch handleLeftover(url, location: place.location) {
                case .rescued(let file):
                    if seen.insert(file.relativePath).inserted { found.append(file) }
                case .explained(let note):
                    if seenRejected.insert(note.relativePath).inserted { rejected.append(note) }
                case .quiet:
                    break
                }
            }

            for url in contents.strangers {
                guard let note = strangerNote(url, location: place.location) else { continue }
                if seenRejected.insert(note.relativePath).inserted { rejected.append(note) }
            }
        }

        // Модель, вшитую в приложение, тоже показываем: удалить её нельзя, но она годна.
        if let bundled = bundledFile() {
            found.append(bundled)
        }

        found.sort(by: isBefore)
        // Крупные первыми: если модель среди этих файлов и есть, она самая тяжёлая.
        // Список подрезаем — простыня из двух десятков строк объясняет не лучше, а хуже.
        rejected.sort { $0.byteSize > $1.byteSize }
        rejected = Array(rejected.prefix(maximumRejectedShown))

        let finishedAt = Date()

        lock.lock()
        storage = found
        rejectedStorage = rejected
        lastScanDate = finishedAt
        lock.unlock()

        return ModelScanResult(files: found,
                               rejected: rejected,
                               places: ModelStorage.searchPlaceNames(),
                               finishedAt: finishedAt)
    }

    /// Лучший файл для запуска: выбор человека, потом узнанное справочником,
    /// потом самое свежее. nil — запускать нечего.
    ///
    /// ⚠️ Если поиск ещё ни разу не проводился, здесь он и случится — то есть будет
    /// работа с диском. Звать из фоновой задачи, а не с главного потока.
    public static func best() -> DiscoveredModelFile? {
        let known = cached
        let list = known.isEmpty ? rescan() : known

        // Выбор человека главнее любой сортировки: он его сделал руками.
        if let chosen = ModelSpec.choice?.relativePath,
           let file = list.first(where: { $0.relativePath == chosen }), file.isUsable {
            return file
        }
        // А вот сами берём только то, что запустится прямо сейчас: см. `canStartAutomatically`.
        return list.first(where: { $0.canStartAutomatically })
    }

    /// Есть ли на телефоне хоть одна готовая к работе модель.
    public static func hasUsableModel() -> Bool {
        best() != nil
    }

    /// Пересмотреть папки и сказать экранам, что список изменился.
    /// Зовётся после всего, что меняет состав файлов: установки, переноса, удаления.
    /// Сообщение уходит на главном потоке — его слушают экраны.
    public static func refreshAndNotify() {
        _ = rescan()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .pocketAgentModelsChanged, object: nil)
        }
    }

    /// Опознать одну конкретную модель внутри контейнера (без обхода папок) —
    /// файл Google или папку Apple, одинаково.
    public static func describe(_ url: URL) -> DiscoveredModelFile? {
        let location = ModelStorage.location(of: url) ?? .documents
        if MLXModelFolder.isFolder(url) {
            if case .model(let file) = examineFolder(url, location: location) { return file }
            return nil
        }
        return inspect(url, location: location)
    }

    // MARK: Перечисление папки

    /// Что лежит в одной папке: похожее на модель и всё остальное, о чём стоит сказать.
    private struct DirectoryContents {
        /// Файлы моделей: .litertlm (Google) и .gguf (движок Bonsai).
        let models: [URL]
        /// Папки-модели Apple: у них модель — это папка целиком, а не файл внутри.
        let folders: [URL]
        let strangers: [URL]
        /// Обрывки нашей же установки — файлы с хвостом «.import».
        /// Моделью не считаются никогда; что с ними делать, решает `handleLeftover`.
        let leftovers: [URL]
    }

    /// ⚠️ Скрытые файлы больше не пропускаются подчистую. Файл, который лежит в iCloud
    /// и на телефон не выгружен, система показывает СКРЫТОЙ заглушкой с хвостом «.icloud» —
    /// и раньше поиск не видел ни его, ни причины: человек смотрел в «Файлы», видел там
    /// свою модель и не понимал, почему приложение её «не замечает».
    private static func files(in directory: URL) -> DirectoryContents {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return DirectoryContents(models: [], folders: [], strangers: [], leftovers: [])
        }

        var models: [URL] = []
        var folders: [URL] = []
        var strangers: [URL] = []
        var leftovers: [URL] = []

        // ⚠️ МЫ САМИ МОЖЕМ СТОЯТЬ ВНУТРИ ПАПКИ-МОДЕЛИ: обход заходит в папки человека
        // на три уровня вглубь, а модель Apple — это как раз папка. Её восемь файлов
        // нельзя вываливать человеку строками «это не файл модели»: он увидел бы восемь
        // пугающих строк вместо одной понятной строки про модель (саму папку показывает
        // тот проход, который смотрел на уровень выше).
        // Файлы .litertlm и .gguf при этом ищем как обычно — прятать рабочую модель
        // Google из-за соседства с чужой папкой мы не станем ни при каких условиях.
        let insideModelFolder = MLXModelFolder.looksLikeModelFolder(directory)

        for url in items {
            let name = url.lastPathComponent

            // Заглушка файла из облака: имя есть, содержимого на телефоне нет.
            if name.lowercased().hasSuffix(".icloud") {
                if !insideModelFolder { strangers.append(url) }
                continue
            }
            // Остальное служебное скрытое — не наше дело.
            if name.hasPrefix(".") { continue }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey,
                                                           .fileSizeKey,
                                                           .isDirectoryKey])

            // Модель Apple лежит ПАПКОЙ. Вопрос дешёвый: сначала одна проверка наличия
            // устройства модели внутри, и только у похожих папок — перечисление.
            if values?.isDirectory == true {
                if MLXModelFolder.looksLikeModelFolder(url) { folders.append(url) }
                continue
            }

            guard values?.isRegularFile == true else { continue }

            // Модель — файл одного из двух наших форматов: родного (.litertlm) и
            // формата второго движка (.gguf, Bonsai). Без второго расширения годный
            // GGUF проваливался бы дальше и попадал в «не подошли» — крупный файл
            // рядом с моделями, то есть наша же модель называлась бы чужим мусором.
            // Годность по содержимому дальше проверяет ModelVerifier, он умеет оба.
            let ext = url.pathExtension.lowercased()
            if ext == ModelCatalog.fileExtension
                || ext == ModelCatalog.ggufFileExtension {
                models.append(url)
                continue
            }

            // ⚠️ НАШ СОБСТВЕННЫЙ ОБРЫВОК УСТАНОВКИ — «…litertlm.import». Моделью он
            // не станет никогда, но и молчать о нём нельзя: это гигабайты, которых
            // человек не видит. Разбирается он отдельно — см. `handleLeftover`.
            if ext == ModelImporter.temporaryExtension {
                leftovers.append(url)
                continue
            }

            // Внутри папки-модели остальные файлы — её законные части, а не мусор.
            if insideModelFolder { continue }

            // Служебные файлы движка рядом с моделью — не наше дело и не беда человека.
            if isEngineLeftover(name) { continue }

            // ⚠️ ЧЕРНОВИКИ НАШЕЙ ЖЕ ЗАГРУЗКИ — ТОЖЕ НЕ БЕДА ЧЕЛОВЕКА. Собираемый файл
            // «…partial», план докачки «…plan» и куски человек не создавал и чинить их
            // ему нечем. Про них ему говорили «копирование не дошло до конца — у него
            // лишний хвост в имени, скопируйте модель ещё раз»: неправда от первого
            // слова до последнего. Про недокачанную загрузку рассказывает своя карточка
            // на экране моделей (`ModelStorage.unfinishedDownloads`), где написано,
            // сколько скачано и сколько осталось, и есть кнопка «Докачать».
            if ModelStorage.DownloadLeftover.isOurs(name) { continue }

            // Не модель — но человеку стоит сказать про недокопированный хвост
            // («…litertlm.download») и просто про крупный файл рядом с пустым списком.
            let size = Int64(values?.fileSize ?? 0)
            if name.lowercased().contains("." + ModelCatalog.fileExtension) || size >= strangerNoticeBytes {
                strangers.append(url)
            }
        }

        return DirectoryContents(models: models,
                                 folders: folders,
                                 strangers: strangers,
                                 leftovers: leftovers)
    }

    /// Служебный файл ускорителя, который Google кладёт рядом с моделью.
    ///
    /// ⚠️ На телефоне владельца таких оказалось шесть штук на 2,4 ГБ — кэши расчёта
    /// (`.xnnpack_cache_…`, `…_mldrift_….bin`). Моделью они не являются, лечить их
    /// человеку не надо, и в списке «эти файлы не подошли» им делать нечего: шесть
    /// пугающих строк вместо одной понятной — это хуже, чем молчание.
    private static func isEngineLeftover(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        if lower.contains("xnnpack") || lower.contains("mldrift") || lower.contains("cache") {
            return true
        }
        // ⚠️ Обрывка нашей же установки («…litertlm.import») здесь БОЛЬШЕ НЕТ, и это
        // не забывчивость. Раньше он молча прятался: приложение показывало его человеку
        // как ЕГО ошибку («скопируйте модель ещё раз»), и вместо правки текста его просто
        // убрали с глаз. Прятать гигабайты нельзя — теперь такой файл разбирает
        // `handleLeftover`: целый доводит до готовой модели, неполный убирает и объясняет.
        return (fileName as NSString).pathExtension.lowercased() == "bin"
    }

    // MARK: Проверка одного файла

    /// Чем закончился осмотр одного файла.
    enum FileVerdict {
        /// Это файл модели (годный или с названной бедой внутри `problem`).
        case model(DiscoveredModelFile)
        /// Это не модель, но человеку надо сказать почему.
        case rejected(RejectedModelFile)
        /// Молчим: файл вне контейнера или вообще не файл.
        case ignore
    }

    /// Всё, что можно узнать о файле за мгновение. nil — это не файл модели вовсе.
    ///
    /// ⚠️ Оставлено с прежним поведением намеренно: этим вызовом пользуются установка
    /// файла на месте и перенос внутрь приложения, и им нужен ровно «модель или ничего».
    /// Экрану подготовки нужен разговорчивый вариант — `examine(_:location:)`.
    static func inspect(_ url: URL, location: ModelFileLocation) -> DiscoveredModelFile? {
        if case .model(let file) = examine(url, location: location) { return file }
        return nil
    }

    /// Тот же осмотр, но вместо молчаливого «нет» даёт причину для человека.
    static func examine(_ url: URL, location: ModelFileLocation) -> FileVerdict {
        let name = url.lastPathComponent
        guard let relativePath = ModelStorage.containerRelativePath(of: url) else { return .ignore }

        let values = try? url.resourceValues(forKeys: [.isRegularFileKey,
                                                       .contentModificationDateKey])
        guard values?.isRegularFile == true else { return .ignore }

        let size = ModelStorage.byteSize(of: url)
        let modified = values?.contentModificationDate ?? .distantPast

        // Файл из облака: имя есть, содержимого нет. Не отвергаем молча — просим систему
        // выгрузить его и показываем человеку «скачиваю из облака».
        if ModelStorage.cloudState(of: url) == .placeholder {
            ModelStorage.requestCloudDownload(url)
            return .model(DiscoveredModelFile(url: url,
                                             relativePath: relativePath,
                                             fileName: name,
                                             byteSize: size,
                                             location: location,
                                             modifiedAt: modified,
                                             descriptor: ModelDescriptor.unknown(fileName: name,
                                                                                 byteSize: size),
                                             confidence: .unknown,
                                             warnings: [],
                                             isCloudPlaceholder: true,
                                             problem: nil))
        }

        // Недоделанная установка моделью не является НИКОГДА — ни строкой в списке,
        // ни выбором. Что с ней делать (довести до конца или убрать и объяснить),
        // решает `handleLeftover`; сюда такие файлы обход уже не приносит, и это
        // последняя подстраховка на случай прямого вызова.
        if name.hasSuffix("." + ModelImporter.temporaryExtension) { return .ignore }

        // Содержимое разбирает общий сверщик: он же пишет человеческие тексты отказов.
        let report: ModelFileReport?
        var problem: String?
        do {
            report = try ModelVerifier.inspect(url)
        } catch let error as ModelFileError {
            // ⚠️ РАНЬШЕ ЭТИ ДВА СЛУЧАЯ ВОЗВРАЩАЛИ nil — то есть файл исчезал с экрана
            // без единого слова. Именно так пропадал обрывок недокачанной модели: человек
            // видел файл в «Файлах», а приложение делало вид, что папка пуста. Теперь
            // причина доезжает до человека отдельной строкой.
            if case .tooSmall = error {
                return .rejected(RejectedModelFile(relativePath: relativePath,
                                                   fileName: name,
                                                   byteSize: size,
                                                   location: location,
                                                   reason: error.errorDescription
                                                       ?? "Для модели файл слишком мал."))
            }
            if case .wrongExtension = error {
                return .rejected(RejectedModelFile(relativePath: relativePath,
                                                   fileName: name,
                                                   byteSize: size,
                                                   location: location,
                                                   reason: error.errorDescription
                                                       ?? "Это не файл модели."))
            }
            report = nil
            problem = error.errorDescription
        } catch {
            report = nil
            problem = SystemErrorText.russian(for: error)
        }

        // Файл, который прямо сейчас дописывается, годным не считаем — см. settleSeconds.
        if problem == nil, Date().timeIntervalSince(modified) < settleSeconds {
            problem = "Файл ещё копируется — дождитесь конца копирования."
        }

        // ⚠️ НЕДОКАЧАННЫЙ ФАЙЛ НЕ ДОЛЖЕН ВЫГЛЯДЕТЬ ГОТОВОЙ МОДЕЛЬЮ. Имя правильное,
        // начало файла на месте, разбор проходит — а весов внутри нет. Раньше такой файл
        // становился обычной строкой списка: его можно было выбрать, и человек получал
        // от движка невнятный отказ вместо простого «докачайте». Ловим по справочнику:
        // имя знакомо, а весит меньше эталона — это всегда обрыв загрузки, а не другая
        // сборка (у каждой сборки своё имя). Разницу называем цифрами, иначе человеку
        // нечего проверить. Больше эталона — молчим: это может быть новая версия модели.
        if problem == nil,
           let sameName = ModelCatalog.model(withFileName: name),
           sameName.byteSize > 0, size < sameName.byteSize {
            problem = "Файл скачан не до конца: \(HumanFormat.bytes(size)) "
                + "из \(HumanFormat.bytes(sameName.byteSize)). Докачайте его до конца "
                + "и положите в папку заново."
        }

        // ⚠️ ЗДЕСЬ НЕТ И НЕ ДОЛЖНО БЫТЬ НИ ОДНОЙ ЗАПИСИ В ФАЙЛ. Раньше отсюда каждому
        // найденному файлу ставилась пометка «не класть в резервную копию» — при запуске,
        // при каждом возврате из фона и ещё раз через несколько секунд. Файл человек мог
        // положить в Documents для другого приложения (сама подсказка советует брать его
        // из Google AI Edge Gallery), а мы молча меняли поведение его резервной копии.
        // Пометка стоит там, где человек нажал «Использовать эту модель», — в
        // `ModelImporter.adopt` и `install`.

        return .model(DiscoveredModelFile(url: url,
                                         relativePath: relativePath,
                                         fileName: name,
                                         byteSize: size,
                                         location: location,
                                         modifiedAt: modified,
                                         descriptor: report?.descriptor
                                             ?? ModelDescriptor.unknown(fileName: name, byteSize: size),
                                         confidence: report?.confidence ?? .unknown,
                                         warnings: report?.warnings ?? [],
                                         isCloudPlaceholder: false,
                                         problem: problem))
    }

    // MARK: Проверка одной папки-модели

    /// Осмотр модели, которая лежит ПАПКОЙ (формат Apple).
    ///
    /// ⚠️ Здесь НЕ читается ни один байт весов: состав папки, размеры её файлов
    /// и маленькое оглавление — этого достаточно, чтобы отличить готовую модель
    /// от недокопированной. Гигабайты трогать при обходе нельзя.
    static func examineFolder(_ url: URL, location: ModelFileLocation) -> FileVerdict {
        let name = url.lastPathComponent
        guard let relativePath = ModelStorage.containerRelativePath(of: url) else { return .ignore }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        let report: MLXFolderReport
        do {
            report = try MLXModelFolder.inspect(url)
        } catch {
            // Причина уже написана человеческим языком: чего не хватает и что сделать.
            // Молча спрятать неполную папку нельзя — ровно из-за такого молчания
            // человек когда-то смотрел на пустой экран и решал, что приложение сломано.
            return .rejected(RejectedModelFile(relativePath: relativePath,
                                               fileName: name,
                                               byteSize: MLXModelFolder.totalBytes(of: url),
                                               location: location,
                                               reason: SystemErrorText.russian(for: error)))
        }

        let descriptor = MLXModelFolder.descriptor(for: report)
        let warnings = MLXModelFolder.warnings(for: report,
                                               availableMemoryMB: MemoryGate.availableMemoryMB())

        // Папку могли положить секунду назад — тогда файлы ещё дописываются, и объявлять
        // модель готовой нельзя. Признака «копирование идёт» в системе нет, поэтому
        // смотрим на время последней записи, как и у файлов.
        var problem: String?
        if Date().timeIntervalSince(modified) < settleSeconds {
            problem = "Папка ещё копируется — дождитесь конца копирования."
        }

        return .model(DiscoveredModelFile(url: url,
                                          relativePath: relativePath,
                                          fileName: name,
                                          byteSize: report.totalBytes,
                                          location: location,
                                          modifiedAt: modified,
                                          descriptor: descriptor,
                                          confidence: .unknown,
                                          warnings: warnings,
                                          isCloudPlaceholder: false,
                                          problem: problem,
                                          isFolder: true))
    }

    // MARK: Обрывок нашей же установки

    /// Чем кончился разбор обрывка «…litertlm.import».
    private enum LeftoverOutcome {
        /// Файл оказался целой моделью — установку довели до конца, вот она.
        case rescued(DiscoveredModelFile)
        /// Спасать нечего: кусок убран, человеку сказано человеческими словами.
        case explained(RejectedModelFile)
        /// Говорить нечего: работа идёт прямо сейчас либо кусок убран как лишний.
        case quiet
    }

    /// Сколько файл должен пролежать нетронутым, прежде чем считать установку брошенной.
    ///
    /// ⚠️ Копирование гигабайтов идёт минутами и всё это время дописывает файл, поэтому
    /// свежая запись — верный признак, что работа идёт прямо сейчас. Полминуты запаса
    /// хватает с большим избытком: между двумя кусками по 8 МБ проходят доли секунды.
    private static let abandonedAfterSeconds: TimeInterval = 30

    /// Что делать с недоделанной установкой.
    ///
    /// ⚠️ ЗАЧЕМ ЭТО ПОЯВИЛОСЬ. Жалоба владельца 10.08.2026: «твоя модель, которую ты
    /// скачал, не запускается», и на снимке — файл с хвостом «.import», про который
    /// приложение отвечало «это не файл модели». Хвост ставим мы сами, пока не довели
    /// установку до конца; человеку в нём чинить нечего. Раньше такой файл просто
    /// прятался — то есть гигабайты лежали молча, и выхода из тупика не было.
    ///
    /// Теперь три честных случая:
    ///  • **кусок оказался целой моделью** — доводим установку до конца сами
    ///    (переименовываем), и модель появляется в списке обычной строкой;
    ///  • **кусок неполный** — запускать нечего и докачивать нечем (исходный файл
    ///    человека нам недоступен), поэтому убираем его и говорим, что произошло;
    ///  • **работа идёт прямо сейчас** — не трогаем ничего.
    ///
    /// ⚠️ УДАЛЯЕМ ТОЛЬКО В СВОЁМ ХРАНИЛИЩЕ. В папке человека в «Файлах» приложение
    /// не стирает ничего и никогда — там мы только объясняем.
    private static func handleLeftover(_ url: URL,
                                       location: ModelFileLocation) -> LeftoverOutcome {
        // Живая установка или загрузка пишет ровно такой же файл — её не трогаем.
        if ModelImporter.isInstalling || ModelDownloader.shared.isDownloading { return .quiet }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        if Date().timeIntervalSince(modified) < abandonedAfterSeconds { return .quiet }

        guard let relativePath = ModelStorage.containerRelativePath(of: url) else { return .quiet }

        let size = ModelStorage.byteSize(of: url)
        // Настоящее имя модели — то же самое без служебного хвоста.
        let finalURL = url.deletingPathExtension()
        let finalName = finalURL.lastPathComponent
        let manager = FileManager.default
        let ourOwnStorage = location == .appStorage

        // 1. Кусок целый? Тогда это готовая модель, и не хватало ей ровно одного —
        // переименования. Разбираем его ПОД НАСТОЯЩИМ ИМЕНЕМ: по служебному любая
        // проверка ответит «это не файл модели».
        let isWholeModel = (try? ModelVerifier.inspect(url, named: finalName)) != nil
        if isWholeModel, ourOwnStorage {
            if manager.fileExists(atPath: finalURL.path) {
                // Такая модель уже стоит — вторая копия не нужна никому.
                try? manager.removeItem(at: url)
                return .quiet
            }
            if (try? manager.moveItem(at: url, to: finalURL)) != nil {
                try? ModelStorage.excludeFromBackup(finalURL)
                if case .model(let file) = examine(finalURL, location: location) {
                    return .rescued(file)
                }
                return .quiet
            }
        }

        // 2. Спасать нечего. В своём хранилище кусок убираем — держать невидимые
        // гигабайты и не давать их удалить это и есть тупик, на который жаловались.
        // ⚠️ Исходный файл человека при этом цел: неполным кусок бывает только после
        // оборванного КОПИРОВАНИЯ, а копируем мы с его файла, не трогая оригинал.
        var removed = false
        if ourOwnStorage {
            removed = (try? manager.removeItem(at: url)) != nil
        }

        let weight = size > 0 ? " на \(HumanFormat.bytes(size))" : ""
        let tail = removed
            ? "Я его убрал — место освободилось."
            : "Его можно удалить в «Файлах»."
        return .explained(RejectedModelFile(
            relativePath: relativePath,
            fileName: finalName,
            byteSize: size,
            location: location,
            reason: "Установка этой модели оборвалась на середине, и от неё остался "
                + "кусок файла\(weight). Запустить его нельзя, и это не ваша ошибка: "
                + "так приложение называет свою копию, пока не доведёт установку до конца. "
                + tail + " Скачайте модель заново или выберите файл ещё раз."
        ))
    }

    // MARK: Посторонний файл, о котором стоит сказать

    /// Крупный файл рядом с моделями, который моделью не является. Раньше про такие
    /// приложение молчало, и человек, положивший модель под другим именем или не до конца
    /// её скопировавший, оставался наедине с пустым экраном.
    private static func strangerNote(_ url: URL, location: ModelFileLocation) -> RejectedModelFile? {
        let rawName = url.lastPathComponent
        guard let relativePath = ModelStorage.containerRelativePath(of: url) else { return nil }

        let size = ModelStorage.byteSize(of: url)
        let lower = rawName.lowercased()

        // Заглушка из облака: настоящее имя спрятано под точкой в начале и хвостом «.icloud».
        if lower.hasSuffix(".icloud") {
            var real = rawName
            real.removeLast(".icloud".count)
            if real.hasPrefix(".") { real.removeFirst() }
            ModelStorage.requestCloudDownload(url.deletingLastPathComponent()
                .appendingPathComponent(real))
            return RejectedModelFile(
                relativePath: relativePath,
                fileName: real,
                byteSize: 0,
                location: location,
                reason: "Файл пока хранится в iCloud и на телефон не скачан. Я попросил систему "
                    + "его скачать: откройте «Файлы» и дождитесь, пока рядом с ним пропадёт "
                    + "значок облака."
            )
        }

        // Недокопированный хвост: имя вида «модель.litertlm.что-то» — или то же самое
        // с GGUF: недокопированная модель второго движка заслуживает того же честного
        // объяснения, а не общего «это не файл модели».
        if lower.contains("." + ModelCatalog.fileExtension)
            || lower.contains("." + ModelCatalog.ggufFileExtension) {
            return RejectedModelFile(
                relativePath: relativePath,
                fileName: rawName,
                byteSize: size,
                location: location,
                reason: "Копирование этого файла не дошло до конца — у него лишний хвост в имени. "
                    + "Скопируйте модель ещё раз и дождитесь конца копирования."
            )
        }

        let archiveExtensions = ["zip", "7z", "rar", "gz", "tar", "tgz", "bz2", "xz"]
        if archiveExtensions.contains(url.pathExtension.lowercased()) {
            return RejectedModelFile(
                relativePath: relativePath,
                fileName: rawName,
                byteSize: size,
                location: location,
                reason: "Модель лежит внутри архива. Распакуйте его и положите сюда сам файл "
                    + "с расширением .\(ModelCatalog.fileExtension) "
                    + "или .\(ModelCatalog.ggufFileExtension)."
            )
        }

        return RejectedModelFile(
            relativePath: relativePath,
            fileName: rawName,
            byteSize: size,
            location: location,
            reason: "Это не файл модели: приложению нужен файл с расширением "
                + ".\(ModelCatalog.fileExtension) или .\(ModelCatalog.ggufFileExtension). "
                + "Если это и есть модель — верните ей правильное имя, "
                + "«Файлы» умеют переименовывать."
        )
    }

    /// Модель могли положить прямо в приложение при сборке.
    private static func bundledFile() -> DiscoveredModelFile? {
        guard let url = Bundle.main.urls(forResourcesWithExtension: ModelCatalog.fileExtension,
                                         subdirectory: nil)?.first else { return nil }
        let name = url.lastPathComponent
        let size = ModelStorage.byteSize(of: url)
        let report = try? ModelVerifier.inspect(url)
        return DiscoveredModelFile(url: url,
                                   relativePath: "bundle/" + name,
                                   fileName: name,
                                   byteSize: size,
                                   location: .bundle,
                                   modifiedAt: .distantPast,
                                   descriptor: report?.descriptor
                                       ?? ModelDescriptor.unknown(fileName: name, byteSize: size),
                                   confidence: report?.confidence ?? .unknown,
                                   warnings: report?.warnings ?? [],
                                   isCloudPlaceholder: false,
                                   problem: nil)
    }

    /// Порядок в списке: сначала то, что можно запустить; из годных — узнанное справочником;
    /// дальше самое свежее (человек только что положил файл — он и должен быть сверху).
    private static func isBefore(_ left: DiscoveredModelFile, _ right: DiscoveredModelFile) -> Bool {
        if left.isUsable != right.isUsable { return left.isUsable }
        if left.isKnownToCatalog != right.isKnownToCatalog { return left.isKnownToCatalog }
        if left.modifiedAt != right.modifiedAt { return left.modifiedAt > right.modifiedAt }
        return left.fileName < right.fileName
    }
}

// MARK: - Сообщение о том, что список моделей изменился

public extension Notification.Name {
    /// Поиск нашёл (или потерял) файлы моделей — экранам пора перечитать
    /// `ModelDiscovery.cached`. Рассылается на главном потоке.
    static let pocketAgentModelsChanged = Notification.Name("pocketagent.models.changed")
}
