//
//  MLXModelFolder.swift
//  PocketAgent / Runtime
//
//  Модель для движка Apple — это ПАПКА, а не файл.
//
//  ⚠️ РАДИ ЭТОГО ФАЙЛ И ЗАВЁЛСЯ. Всё приложение построено вокруг «модель = один файл
//  .litertlm»: поиск смотрит на расширение, проверка читает первые восемь байт,
//  установка копирует один поток байтов. У Apple же на диске лежит папка из восьми
//  файлов (разведка 09.08.2026, `docs/MLX-PLAN.md`, раздел 4):
//
//      config.json · model.safetensors · model.safetensors.index.json
//      tokenizer.json · tokenizer_config.json · chat_template.jinja
//      generation_config.json · processor_config.json
//
//  Без мелких `.json` модель не запускается ВООБЩЕ: в них и устройство модели,
//  и шаблон разговора, из которого берётся вызов действий. Поэтому папку нельзя
//  проверять «по размеру» — обрыв одного файла на 6 КБ суммарный размер почти
//  не сдвинет. Проверяем ПО СОСТАВУ и пофайлово.
//
//  ⚠️ ЧЕМ ЭТО НЕ ЯВЛЯЕТСЯ. Здесь нет ни одной поблажки проверке файлов Google:
//  папка идёт своей дорогой и по своим правилам, а `.litertlm` как проверялся
//  по метке в начале файла, так и проверяется. Ослабить защиту от мусора «заодно»
//  было бы худшим исходом этой работы.
//
//  ⚠️ ЧТО ЗДЕСЬ НЕ ЧИТАЕТСЯ: содержимое весов. Файл `model.safetensors` на 3,5 ГБ
//  не открывается вовсе — обход папки идёт при каждом открытии экрана моделей,
//  и чтение гигабайтов там недопустимо. Всё, что нам нужно, лежит в именах файлов,
//  их размерах и одном маленьком оглавлении.
//

import Foundation

// MARK: - Что не так с папкой

/// Отказы, которые человек должен понять с первого раза: чего в папке не хватает
/// и что с этим делать. Помечен `HumanReadableError` намеренно — иначе разбор ошибок
/// подменит подробное объяснение общим «что-то пошло не так».
public enum MLXFolderError: HumanReadableError, Equatable {

    /// Дали не папку, а обычный файл.
    case notAFolder(name: String)
    /// Папку не удалось перечислить.
    case unreadable(name: String, reason: String)
    /// Внутри нет ни одного файла с весами — на модель это не похоже вовсе.
    case noWeights(name: String)
    /// Нет описания устройства модели.
    case noConfig(name: String)
    /// Нет словаря.
    case noTokenizer(name: String)
    /// В оглавлении перечислены части, которых в папке нет.
    case missingParts(name: String, missing: [String])
    /// Внутри есть пустой файл — копирование оборвалось.
    case emptyPart(name: String, partName: String)
    /// Часть файлов ещё лежит в iCloud и на телефон не выгружена.
    case partsInCloud(name: String, count: Int)

    public var errorDescription: String? {
        switch self {
        case .notAFolder(let name):
            return "«\(name)» — это отдельный файл, а модель Apple лежит папкой. "
                + "Выберите папку целиком."

        case .unreadable(let name, let reason):
            return "Не удалось заглянуть в папку «\(name)»: \(reason)"

        case .noWeights(let name):
            return "В папке «\(name)» нет ни одного файла модели (.safetensors) — "
                + "на модель это не похоже. Если модель лежит в архиве, сначала распакуйте его."

        case .noConfig(let name):
            return "В папке «\(name)» не хватает файла config.json — без него модель не запустить. "
                + "Скорее всего, папка скопирована не целиком: скопируйте её заново со всем содержимым."

        case .noTokenizer(let name):
            return "В папке «\(name)» не хватает словаря — файла tokenizer.json. "
                + "Без него модель не понимает текст. Скопируйте папку заново, целиком."

        case .missingParts(let name, let missing):
            let shown = missing.prefix(3).joined(separator: ", ")
            let tail = missing.count > 3 ? " и ещё \(missing.count - 3)" : ""
            return "Папка «\(name)» скопирована не полностью: в её оглавлении перечислены части, "
                + "которых на телефоне нет — \(shown)\(tail). Скопируйте папку заново."

        case .emptyPart(let name, let partName):
            return "В папке «\(name)» файл «\(partName)» пустой — в нём ноль байт. "
                + "Копирование оборвалось: скопируйте папку заново."

        case .partsInCloud(let name, let count):
            let word = HumanFormat.plural(count, "файл", "файла", "файлов")
            return "У модели «\(name)» \(count) \(word) пока хранятся только в iCloud. "
                + "Я попросил систему их скачать: откройте «Файлы» и дождитесь, "
                + "пока рядом с ними пропадут значки облака."
        }
    }
}

// MARK: - Что лежит в папке

/// Один файл внутри папки модели. Больше про него ничего знать не надо.
public struct MLXFolderItem: Sendable, Equatable {
    public let name: String
    public let byteSize: Int64
    /// Файл числится за iCloud и на телефон не выгружен — читать нечего.
    public let isCloudPlaceholder: Bool
}

/// Разбор папки: что внутри, сколько весит, чего не хватает.
public struct MLXFolderReport: Sendable, Equatable {

    /// Сама папка.
    public let url: URL
    /// Имя папки — оно же имя модели для человека.
    public let folderName: String
    /// Суммарный размер ВСЕХ файлов папки. Именно это число видит человек в списке.
    public let totalBytes: Int64
    /// Сколько весят только веса — по ним считается расход памяти.
    public let weightBytes: Int64
    /// Все файлы папки.
    public let items: [MLXFolderItem]
    /// На сколько частей разбиты веса.
    public let shardCount: Int
    /// В папке есть шаблон разговора — без него модель не поймёт, что у неё есть действия.
    public let hasChatTemplate: Bool
    /// Устройство модели — то самое слово из `config.json`, по которому движок Apple
    /// решает, умеет он такую модель или нет. nil — прочитать не удалось.
    ///
    /// ⚠️ ТЕХНИЧЕСКОЕ СЛОВО, НА ЭКРАН ЕГО НЕ ВЫВОДИТЬ. Владелец уже прочитал одно такое
    /// («Unsupported model type: qwen3_5_mtp») и не понял ни что случилось, ни что делать.
    /// Человеку — объяснение из `MLXArchitectures.humanText`, слово — в журнал движка.
    public let modelType: String?

    /// Сколько файлов внутри.
    public var fileCount: Int { items.count }
}

// MARK: - Разбор папки модели

public enum MLXModelFolder {

    // MARK: Из чего состоит модель Apple

    /// Устройство модели. Загрузчик Apple без него не поднимет модель вовсе.
    public static let configFileName = "config.json"
    /// Словарь модели.
    public static let tokenizerFileName = "tokenizer.json"
    /// Оглавление, когда веса разложены на части.
    public static let shardIndexFileName = "model.safetensors.index.json"
    /// Шаблон разговора. Именно из него берётся описание действий для модели.
    public static let chatTemplateFileName = "chat_template.jinja"
    /// Запасное место для шаблона разговора: в части моделей он лежит внутри настроек словаря.
    public static let tokenizerConfigFileName = "tokenizer_config.json"
    /// Расширение файла с весами.
    public static let weightsExtension = "safetensors"

    /// ⚠️ ГЛАВНЫЙ ВЫКЛЮЧАТЕЛЬ, И ОН ОДИН НА ВСЁ ПРИЛОЖЕНИЕ.
    ///
    /// Папку модели Apple приложение умеет найти, посчитать, проверить и установить —
    /// это сделано здесь. Запустить её умеет выбор движка (`EngineRouter`
    /// в `Agent/AgentAssembly.swift`): файл `.litertlm` уходит движку Google, папка —
    /// движку Apple, и прежние веса выгружаются до загрузки новых.
    ///
    /// Поэтому здесь `true` (шаг 5 плана `docs/MLX-PLAN.md` сделан): папку можно сделать
    /// активной моделью, и она поднимется.
    ///
    /// ⚠️ ЧЕГО ЭТА ПРАВДА НЕ ЗНАЧИТ: что запуск ПРОВЕРЕН. Движок Apple на симуляторе
    /// не считает вообще, поэтому ни одна облачная сборка не скажет, работает ли это, —
    /// скажет только живой iPhone. Ставить обратно `false` при первой же неудаче не надо:
    /// сначала журнал, потом решение.
    public static let isEngineWired = true

    /// Что сказать человеку, пока движок Apple не подключён. Пусто — говорить нечего.
    static var engineNote: String {
        isEngineWired
            ? ""
            : "Это модель для движка Apple. Сам движок ещё подключается — папку видно "
                + "и можно проверить, но запустить её приложение пока не сможет."
    }

    // MARK: Опознание

    /// Это папка, а не файл.
    public static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Похожа ли папка на модель Apple. Дёшево: одна проверка наличия `config.json`
    /// и — только если он есть — перечисление папки в поисках весов.
    ///
    /// ⚠️ ДЕШЕВИЗНА ЗДЕСЬ ОБЯЗАТЕЛЬНА, А НЕ ЖЕЛАТЕЛЬНА. Этот вопрос задаётся каждой
    /// папке при каждом открытии экрана моделей (до шестидесяти папок), и полное
    /// перечисление каждой из них превратило бы мгновенный обход в заметное подвисание.
    /// Папок с `config.json` внутри в норме ровно столько, сколько у человека моделей.
    public static func looksLikeModelFolder(_ url: URL) -> Bool {
        guard isFolder(url) else { return false }
        // Недокопированная папка нашей же установки — это наш мусор, а не модель человека.
        // Без этой строки прерванная установка сразу же показывалась бы как готовая модель.
        guard url.pathExtension.lowercased() != ModelImporter.temporaryExtension else { return false }
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent(configFileName).path
        ) else { return false }
        return hasWeights(in: url)
    }

    /// Суммарный размер папки. Ноль — заглянуть не удалось.
    ///
    /// ⚠️ Считаем ОДИН уровень: у моделей Apple папка плоская, а обход вглубь на общем
    /// экране моделей стоил бы чтения чужих деревьев на каждом открытии.
    public static func totalBytes(of url: URL) -> Int64 {
        (try? contents(of: url))?.reduce(Int64(0)) { $0 + $1.byteSize } ?? 0
    }

    // MARK: Полная проверка

    /// Разобрать папку: состав, размер, целостность.
    ///
    /// ⚠️ ЧЕГО ЭТА ПРОВЕРКА НЕ УМЕЕТ, И ПРО ЭТО ЛУЧШЕ ЗНАТЬ ЗАРАНЕЕ. У файла Google
    /// внутри записано, где кончаются его данные, — поэтому недокачанный файл видно
    /// без всякого эталона. У модели Apple такой записи нет НИГДЕ: если единственный
    /// файл весов скопировался наполовину, отличить его от целого нам нечем — эталонного
    /// размера у принесённой папки не существует. Ловится только то, что действительно
    /// ловится: пропавшие файлы, пустые файлы и недостающие части по оглавлению.
    /// Придумывать проверку, которой нет, — хуже, чем честно её не иметь.
    ///
    /// - Throws: `MLXFolderError` — с готовым объяснением, чего не хватает.
    public static func inspect(_ url: URL) throws -> MLXFolderReport {
        let name = url.lastPathComponent

        guard isFolder(url) else { throw MLXFolderError.notAFolder(name: name) }

        let items: [MLXFolderItem]
        do {
            items = try contents(of: url)
        } catch {
            throw MLXFolderError.unreadable(name: name, reason: SystemErrorText.russian(for: error))
        }

        // Файл, оставшийся в облаке, читать нечем — и это не «сломано», а «ещё едет».
        // Просим систему выгрузить их и говорим человеку подождать.
        let inCloud = items.filter(\.isCloudPlaceholder)
        if !inCloud.isEmpty {
            for item in inCloud {
                ModelStorage.requestCloudDownload(url.appendingPathComponent(item.name))
            }
            throw MLXFolderError.partsInCloud(name: name, count: inCloud.count)
        }

        let names = Set(items.map { $0.name.lowercased() })
        let weights = items.filter { ($0.name as NSString).pathExtension.lowercased() == weightsExtension }

        // Порядок отказов — от «это вообще не модель» к «модель, но неполная»:
        // человеку с посторонней папкой надо сказать «это не модель», а не «докопируйте».
        guard !weights.isEmpty else { throw MLXFolderError.noWeights(name: name) }
        guard names.contains(configFileName) else { throw MLXFolderError.noConfig(name: name) }
        guard names.contains(tokenizerFileName) else { throw MLXFolderError.noTokenizer(name: name) }

        // Пустой файл = оборванное копирование. Суммарный размер такое почти не сдвигает,
        // поэтому ловится оно только пофайлово — ради этого проверка и написана.
        if let empty = items.first(where: { $0.byteSize == 0 }) {
            throw MLXFolderError.emptyPart(name: name, partName: empty.name)
        }

        // Веса разложены на части — в оглавлении написано, какие части должны быть.
        // Это единственная настоящая проверка «скачалось ли всё», которая нам доступна
        // без эталона: сам файл честно перечисляет свои куски.
        if names.contains(shardIndexFileName) {
            let missing = missingShards(in: url, present: names)
            if !missing.isEmpty {
                throw MLXFolderError.missingParts(name: name, missing: missing)
            }
        }

        let total = items.reduce(Int64(0)) { $0 + $1.byteSize }
        let weightBytes = weights.reduce(Int64(0)) { $0 + $1.byteSize }

        return MLXFolderReport(
            url: url,
            folderName: name,
            totalBytes: total,
            weightBytes: weightBytes,
            items: items,
            shardCount: weights.count,
            hasChatTemplate: names.contains(chatTemplateFileName)
                || names.contains(tokenizerConfigFileName),
            // Устройство модели читаем ЗДЕСЬ, пока папка и так под рукой: файл
            // маленький (килобайты), а без этого слова нельзя сказать, запустится
            // ли модель вообще (ROADMAP, 12.8).
            modelType: MLXArchitectures.modelType(inFolder: url)
        )
    }

    // MARK: Описание модели

    /// Описание модели, собранное по папке, — в том же виде, в каком его ждёт
    /// остальное приложение.
    ///
    /// ⚠️ `byteSize` — это СУММА по папке, а не размер одного файла. От неё считаются
    /// и строка «3,58 ГБ» в списке, и порог памяти.
    public static func descriptor(for report: MLXFolderReport) -> ModelDescriptor {
        // ⚠️ СНАЧАЛА СПРАШИВАЕМ СПРАВОЧНИК. Папку, которую приложение само скачало
        // из своего же списка, надо узнавать: иначе про собственную советуемую модель
        // человек читает «эту модель приложение не знает». Узнаём по имени И весу —
        // ровно так же, как узнаём файлы.
        if let known = ModelCatalog.folderModel(forFolderName: report.folderName,
                                                totalBytes: report.totalBytes) {
            return known
        }

        let parts = HumanFormat.plural(report.fileCount, "файла", "файлов", "файлов")
        return ModelDescriptor(
            id: identifier(for: report.folderName),
            displayName: ModelCatalog.humanName(forFileName: report.folderName),
            repoID: "",
            repoCommit: "main",
            fileName: report.folderName,
            byteSize: report.totalBytes,
            sha256: "",
            summary: "Модель для движка Apple: папка из \(report.fileCount) \(parts). "
                + "Её принесли на телефон — в справочнике приложения такой нет, "
                + "значит поручиться за неё нельзя.",
            hardware: ModelCatalog.hardware(forFileName: report.folderName),
            origin: .unknownFile,
            license: "неизвестна — смотрите условия того, кто выложил модель",
            isRecommended: false
        )
    }

    /// Оговорки, которые человек обязан увидеть рядом с папкой.
    /// Первой идёт самая важная — её показывают в списке одной строкой.
    public static func warnings(for report: MLXFolderReport, availableMemoryMB: Int) -> [String] {
        var result: [String] = []

        // ⚠️ ПЕРВОЙ — ТА, ПОСЛЕ КОТОРОЙ ОСТАЛЬНОЕ НЕ ИМЕЕТ ЗНАЧЕНИЯ. Модель, устройство
        // которой движок не умеет, не запустится никогда: рассказывать про память
        // и шаблон разговора рядом с этим — только путать.
        if let type = report.modelType,
           case .notRunnable = MLXArchitectures.cachedVerdict(forModelType: type) {
            result.append(MLXArchitectures.humanText(forModelType: type))
        }

        let note = engineNote
        if !note.isEmpty { result.append(note) }

        let fit = ModelFitRule.fit(folderName: report.folderName,
                                   totalBytes: report.totalBytes,
                                   availableMemoryMB: availableMemoryMB)
        if fit.level == .tight || fit.level == .impossible {
            result.append([fit.detail, fit.memoryNote].compactMap { $0 }.joined(separator: " "))
        }

        if !report.hasChatTemplate {
            result.append("В папке нет шаблона разговора — скорее всего, модель не поймёт, "
                          + "что ей можно пользоваться действиями. Работать она будет, "
                          + "но только как собеседник.")
        }

        // Про модель из своего же справочника этого писать нельзя — мы её знаем.
        let isKnown = ModelCatalog.folderModel(forFolderName: report.folderName,
                                               totalBytes: report.totalBytes) != nil
        if !isKnown {
            result.append("Эту модель приложение не знает — за неё никто не ручается. "
                          + "Состав папки правильный, но как она себя поведёт, "
                          + "заранее сказать нельзя.")
        }
        return result
    }

    /// Готовый разбор в том же виде, в каком его отдаёт сверщик файлов, — чтобы
    /// остальное приложение не различало «файл» и «папка» там, где ему это не нужно.
    static func fileReport(for url: URL,
                           availableMemoryMB: Int) throws -> ModelFileReport {
        let report = try inspect(url)
        return ModelFileReport(fileName: report.folderName,
                               byteSize: report.totalBytes,
                               descriptor: descriptor(for: report),
                               known: nil,
                               confidence: .unknown,
                               header: .notApplicable,
                               warnings: warnings(for: report, availableMemoryMB: availableMemoryMB),
                               isFolder: true)
    }

    // MARK: - Мелочи

    /// Перечислить папку на один уровень. Подпапки пропускаем: у моделей Apple
    /// их не бывает, а заходить в чужие деревья на общем обходе нельзя.
    static func contents(of url: URL) throws -> [MLXFolderItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let items = try FileManager.default.contentsOfDirectory(at: url,
                                                                includingPropertiesForKeys: keys,
                                                                options: [.skipsSubdirectoryDescendants])
        var result: [MLXFolderItem] = []
        for item in items {
            let name = item.lastPathComponent

            // Заглушка из iCloud: имя есть, содержимого на телефоне нет. Настоящее имя
            // спрятано под точкой в начале и хвостом «.icloud».
            if name.lowercased().hasSuffix(".icloud") {
                var real = name
                real.removeLast(".icloud".count)
                if real.hasPrefix(".") { real.removeFirst() }
                result.append(MLXFolderItem(name: real, byteSize: 0, isCloudPlaceholder: true))
                continue
            }
            // Служебное скрытое (.DS_Store и подобное) моделью не является и в сумму
            // размера идти не должно.
            if name.hasPrefix(".") { continue }

            // ⚠️ Тот же список ключей, но здесь он нужен множеством: обход папки берёт
            // массив, а запрос свойств одного файла — множество. Разные требования
            // у двух соседних вызовов, и сборка на этом падала.
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }

            // Файл, которым управляет iCloud, но байты на телефоне есть, — обычный файл.
            let isPlaceholder = ModelStorage.cloudState(of: item) == .placeholder
            result.append(MLXFolderItem(name: name,
                                        byteSize: Int64(values?.fileSize ?? 0),
                                        isCloudPlaceholder: isPlaceholder))
        }
        return result
    }

    /// Есть ли в папке хоть один файл с весами.
    private static func hasWeights(in url: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return false }
        return items.contains { $0.pathExtension.lowercased() == weightsExtension }
    }

    /// Каких частей весов не хватает по оглавлению.
    ///
    /// ⚠️ Оглавление — это маленький файл (у Gemma 4 E2B — 218 КБ), и читается он
    /// ТОЛЬКО когда он есть. Ошибка разбора здесь не отказ: не смогли прочитать —
    /// значит просто не проверили, придумывать отсутствующие части нельзя.
    private static func missingShards(in url: URL, present: Set<String>) -> [String] {
        let indexURL = url.appendingPathComponent(shardIndexFileName)
        guard let data = try? Data(contentsOf: indexURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = root["weight_map"] as? [String: String] else {
            return []
        }
        let needed = Set(map.values)
        return needed
            .filter { !present.contains($0.lowercased()) }
            .sorted()
    }

    /// Опознаватель модели: только безопасные для имени файла знаки.
    private static func identifier(for folderName: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let cleaned = String(folderName.lowercased().map { allowed.contains($0) ? $0 : "-" })
        return "mlx-" + cleaned
    }
}
