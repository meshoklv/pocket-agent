//
//  ModelCatalog.swift
//  PocketAgent / Runtime
//
//  Список моделей, которые приложение УЗНАЁТ, и правила про память.
//
//  ⚠️ ГЛАВНОЕ ИЗМЕНЕНИЕ (09.08.2026). Раньше здесь лежала РОВНО ОДНА модель, и её
//  размер с контрольной суммой были единственным пропуском: человек приносил свою
//  gemma-4-E4B-it.litertlm (3,66 ГБ, скачанную другим приложением) и получал отказ
//  «нужен ровно 2,01 ГБ». Это было браком: файл был совершенно годный.
//  Теперь каталог — это СПРАВОЧНИК УЗНАВАНИЯ, а не пропускной пункт:
//    • файл узнали по сумме или по имени с размером → показываем человеку имя модели;
//    • файл не узнали → он всё равно принимается, если это настоящий .litertlm
//      (см. ModelVerifier), просто честно помечается «не проверена».
//  Отказ остаётся только для явного мусора и для сборок, которые на iPhone не работают.
//
//  ⚠️ ВСЕ ЦИФРЫ НИЖЕ (размеры в байтах и sha256) СНЯТЫ С Hugging Face API.
//  Ни одну из них нельзя «поправить по памяти» — только по свежему ответу API.
//  Оценки памяти — из карточек моделей Google (замеры на iPhone 17 Pro) и из списка
//  минимальных требований Google AI Edge Gallery.
//
//  ⚠️ Токен Hugging Face НЕ нужен для репозиториев litert-community/gemma-4-*:
//  они открыты. Репозитории google/gemma-3n-* и litert-community/Gemma3-1B-IT
//  закрыты согласием с лицензией — их приложение СКАЧАТЬ не может (экрана входа нет),
//  но ПРИНЯТЬ уже скачанный человеком файл обязано.
//

import Foundation

// MARK: - На каком железе работает файл

/// Под какое железо собран файл модели. Определяется по заголовку файла
/// (ключ backend_constraint) и по имени файла.
public enum ModelHardware: String, Sendable, Equatable, Codable {

    /// Работает и на процессоре, и на видеочипе. Самый безопасный вариант для телефона:
    /// если видеочипу не хватит памяти, модель поднимется на процессоре.
    case universal

    /// Только видеочип (в заголовке стоит `gpu_artisan`). Запасного пути на процессор нет:
    /// не хватило памяти видеочипу — модель не запустится вовсе.
    case gpuOnly

    /// Сборка для браузера (файлы со словом «-web» в имени). На телефоне не работает.
    case browserOnly

    /// Сборка под чужой ускоритель (Qualcomm, MediaTek, Intel, Google Tensor).
    /// На iPhone бесполезна.
    case foreignChip

    /// Можно ли вообще пытаться запустить это на iPhone.
    public var isUsableOnIPhone: Bool {
        switch self {
        case .universal, .gpuOnly: return true
        case .browserOnly, .foreignChip: return false
        }
    }

    /// Пояснение человеческим языком — для карточки модели.
    public var note: String {
        switch self {
        case .universal:
            return "Работает и на видеочипе, и на процессоре."
        // ⚠️ Про поломку с числами тут НЕ пишем, хотя она есть: `note` идёт в строку
        // «2,59 ГБ · …» под именем модели, и длинное предупреждение её разорвёт.
        // Предупреждение живёт в описании модели (`summary`) и в `numbersWarning`.
        case .gpuOnly:
            return "Работает только на видеочипе: если ему не хватит памяти, модель не запустится."
        case .browserOnly:
            return "Это сборка для браузера — на телефоне она не работает."
        case .foreignChip:
            return "Это сборка под чужой ускоритель (Qualcomm, MediaTek, Intel, Google Tensor) — на iPhone она не работает."
        }
    }
}

// MARK: - О чём предупреждать человека, но чего не запрещать

/// Известные поломки движка, про которые человек должен знать ДО того, как отдаст
/// агенту свои файлы. Запрещать мы ничего не запрещаем — предупреждаем и не молчим.
public enum ModelWarnings {

    /// ⚠️ ЭТО НЕ ДОГАДКА, А РАЗБОР ПЕРЕПИСКИ С ТЕЛЕФОНА ВЛАДЕЛЬЦА (10.08.2026).
    /// Файл `gemma-4-E4B-it.litertlm` считал на видеочипе. Инструмент отдал модели
    /// оглавление файла целиком и без ошибок, а модель пересказала его так:
    /// «весна-лето 2026» → «весна-лето2226», «после 17.06.2026» → «после 7.0.206.026»,
    /// «Опросник от 15.03.2026» → «Опросник 15.0.3.26». Портятся не только числа:
    /// «Кислота — на паузе» → «Кита — на пау», «Гинекология» → «Гинея»,
    /// «Прошлые острые эпизоды» → «шлые острые эпизоды», «Голосовой» → «Голосовойвой».
    /// Тот же изъян ломает и работу: имя «02-правила.md» модель выговорила как
    /// «0-2-правила.md», и задача встала на файле, которого не существует.
    /// Совпадает с известной поломкой LiteRT-LM #2814 («2033-01-10» → «20333-01010»).
    ///
    /// Сказать об этом человеку обязаны: агент правит его файлы, и перевранная дата
    /// в правке — это испорченный файл, а не косметика.
    public static let brokenNumbers =
        "⚠️ На видеочипе у движка есть поломка: числа и даты в ответах выходят перевранными "
        + "(«17.06.2026» превращается в «7.0.206.026»), иногда пропадают куски слов. "
        + "Для правки файлов это опасно — проверяйте цифры в предпросмотре перед «Применить»."
}

/// Откуда взялось описание модели.
public enum ModelOrigin: String, Sendable, Equatable, Codable {
    /// Модель есть в справочнике: размер и контрольная сумма сверены с Hugging Face.
    case catalog
    /// Файл принесли, эталона для него нет. Работать можно, но обещать нечего.
    case unknownFile
}

// MARK: - Память: сколько просить под неизвестный файл

/// Правило «сколько памяти нужно модели», когда замеров нет и есть только размер файла.
///
/// ⚠️ Расхожее правило «нужно вдвое больше памяти, чем весит файл» — НЕВЕРНО и завышает
/// требование в 2–4 раза. Веса читаются с диска отображением в память, а не копируются.
/// Замеры Google на iPhone 17 Pro:
///   • Gemma 4 E2B — файл 2583 МБ → 607 МБ на процессоре, 1450 МБ на видеочипе (0,24 и 0,56);
///   • Gemma 4 E4B — файл 3654 МБ → 961 МБ на процессоре, 3380 МБ на видеочипе (0,26 и 0,93).
/// Отсюда рабочее правило: на видеочипе — примерно как весит файл, на процессоре — примерно треть.
public enum ModelMemoryRule {

    /// Надбавка за части для картинок и звука.
    ///
    /// ⚠️ ЭТО ОЦЕНКА, А НЕ ЗАМЕР, и врать про неё нельзя. Google публикует цифры только
    /// для текстовой работы; сколько занимают исполнители картинок и звука, он не мерил.
    /// Берём +20% от веса файла: эти части лежат в том же файле, и по весу они заметно
    /// меньше самой языковой модели. Просить больше — значит своими руками запретить
    /// запуск там, где он на самом деле возможен.
    private static let multimodalSurcharge = 0.20

    /// Сколько памяти просить под видеочип: вес файла плюс запас 20%.
    /// Накрывает самый тяжёлый замеренный случай (0,93 у E4B).
    /// - Parameter multimodal: поднимаются ли ещё и исполнители картинок и звука.
    public static func gpuRequirementMB(forFileBytes bytes: Int64, multimodal: Bool = false) -> Int {
        megabytes(Double(bytes) * (multimodal ? 1.2 + multimodalSurcharge : 1.2))
    }

    /// Сколько памяти просить под процессор: треть файла (в замерах 0,24–0,26 — запас заложен).
    /// - Parameter multimodal: поднимаются ли ещё и исполнители картинок и звука.
    public static func cpuRequirementMB(forFileBytes bytes: Int64, multimodal: Bool = false) -> Int {
        megabytes(Double(bytes) * (multimodal ? 0.35 + multimodalSurcharge : 0.35))
    }

    private static func megabytes(_ value: Double) -> Int {
        guard value > 0 else { return 0 }
        return max(1, Int(value / (1024 * 1024)))
    }

    /// Предупреждение о памяти — именно ПРЕДУПРЕЖДЕНИЕ, а не запрет.
    /// Так же поступает Google AI Edge Gallery: показывает окно и кнопку «всё равно продолжить».
    ///
    /// - Parameter availableMemoryMB: сколько приложение ещё может занять (MemoryGate).
    ///   `Int.max` означает «узнать не удалось» — тогда молчим, врать про нехватку хуже.
    /// - Parameter multimodal: считать ли память с учётом исполнителей картинок и звука.
    /// - Returns: текст для человека или nil, если всё в порядке.
    public static func warning(for model: ModelDescriptor,
                               availableMemoryMB: Int,
                               multimodal: Bool = false) -> String? {
        guard availableMemoryMB > 0, availableMemoryMB != Int.max else { return nil }

        let cpuNeed = model.cpuMemoryNeedMB(multimodal: multimodal)
        let gpuNeed = model.gpuMemoryNeedMB(multimodal: multimodal)

        if model.hardware == .gpuOnly, availableMemoryMB < gpuNeed {
            return "Эта модель работает только на видеочипе, а ему нужно около "
                + "\(gpuNeed) МБ — сейчас свободно \(availableMemoryMB) МБ. "
                + "Скорее всего не запустится. Закройте другие приложения или возьмите модель полегче."
        }

        if availableMemoryMB < cpuNeed {
            return "Похоже, памяти не хватит: модели нужно около \(cpuNeed) МБ, "
                + "а сейчас свободно \(availableMemoryMB) МБ. Попробовать можно, но телефон "
                + "может закрыть приложение во время загрузки. Закройте другие приложения "
                + "или возьмите модель полегче."
        }

        if availableMemoryMB < gpuNeed {
            return "Памяти хватит только на работу без ускорения — модель пойдёт на процессоре "
                + "и будет отвечать медленнее."
        }

        return nil
    }
}

// MARK: - Описание одной модели

/// Одна модель: что это за файл, откуда он, сколько весит и сколько просит памяти.
///
/// ⚠️ Описание МОЖЕТ быть собрано не из справочника, а из принесённого файла
/// (см. `ModelDescriptor.unknown`). Тогда `origin == .unknownFile`, `sha256` пуст,
/// а всё остальное посчитано по самому файлу. Такой моделью можно пользоваться —
/// просто про неё нечего обещать.
public struct ModelDescriptor: Sendable, Equatable, Identifiable, Codable {

    /// Стабильный идентификатор (по нему ищем служебные файлы вроде точки докачки).
    public let id: String
    /// Имя для человека.
    public let displayName: String
    /// Репозиторий Hugging Face вида "litert-community/gemma-4-E2B-it-litert-lm".
    public let repoID: String
    /// Пин на конкретный коммит: репозиторий живой, `main` может уехать под приложением.
    /// Значение "main" означает «версия не закреплена» — качать такое мы не даём.
    public let repoCommit: String
    /// Имя файла модели (оно же имя файла на устройстве).
    public let fileName: String
    /// Точный размер файла в байтах.
    public let byteSize: Int64
    /// sha256 из LFS-метаданных Hugging Face. Пусто — эталона нет.
    public let sha256: String
    /// Под какое железо собран файл.
    public let hardware: ModelHardware
    /// Откуда взялось это описание.
    public let origin: ModelOrigin
    /// Сколько свободной памяти просить (МБ). 0 — считать по размеру файла.
    public let requiredFreeMemoryMB: Int
    /// Пик памяти по замерам Google на iPhone 17 Pro, процессор (МБ). 0 — не мерили.
    public let referencePeakCPUMemoryMB: Int
    /// Пик памяти по замерам Google на iPhone 17 Pro, видеочип (МБ). 0 — не мерили.
    public let referencePeakGPUMemoryMB: Int
    /// Сколько памяти Google просит у телефона под эту модель (ГБ). 0 — неизвестно.
    public let minimumDeviceMemoryGB: Int
    /// Годится ли файл для телефона вообще (12B и крупнее — нет).
    public let isForPhone: Bool
    /// Пояснение человеческим языком: в чём разница с соседями по списку.
    public let summary: String
    /// Лицензия — показываем в «О программе».
    public let license: String
    /// Стоит ли предлагать её первой.
    public let isRecommended: Bool

    /// Из чего состоит модель, которая лежит ПАПКОЙ (формат Apple). nil или пусто —
    /// обычная модель из одного файла, и весь прежний путь загрузки остаётся прежним.
    ///
    /// ⚠️ Поле необязательное НАМЕРЕННО, и это не вкус. Выбор человека хранится между
    /// запусками записанным на диск; сделай мы поле обязательным — запись, сделанная
    /// прошлой версией приложения, перестала бы читаться, и у владельца молча слетела бы
    /// выбранная модель.
    public let folderFiles: [ModelFolderFile]?

    /// Путь файла ВНУТРИ репозитория, если он отличается от имени на диске.
    /// nil — совпадает с `fileName` (так у всех моделей из одного файла).
    ///
    /// ⚠️ Нужен ровно для частей папки: на диске часть лежит внутри недособранной папки,
    /// а у Hugging Face — просто «config.json».
    public let repoPath: String?

    public init(id: String,
                displayName: String,
                repoID: String,
                repoCommit: String,
                fileName: String,
                byteSize: Int64,
                sha256: String,
                summary: String,
                hardware: ModelHardware = .universal,
                origin: ModelOrigin = .catalog,
                requiredFreeMemoryMB: Int = 0,
                referencePeakCPUMemoryMB: Int = 0,
                referencePeakGPUMemoryMB: Int = 0,
                minimumDeviceMemoryGB: Int = 0,
                isForPhone: Bool = true,
                license: String = "Apache 2.0",
                isRecommended: Bool = false,
                folderFiles: [ModelFolderFile]? = nil,
                repoPath: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.repoID = repoID
        self.repoCommit = repoCommit
        self.fileName = fileName
        self.byteSize = byteSize
        self.sha256 = sha256
        self.summary = summary
        self.hardware = hardware
        self.origin = origin
        self.requiredFreeMemoryMB = requiredFreeMemoryMB
        self.referencePeakCPUMemoryMB = referencePeakCPUMemoryMB
        self.referencePeakGPUMemoryMB = referencePeakGPUMemoryMB
        self.minimumDeviceMemoryGB = minimumDeviceMemoryGB
        self.isForPhone = isForPhone
        self.license = license
        self.isRecommended = isRecommended
        self.folderFiles = folderFiles
        self.repoPath = repoPath
    }

    // MARK: Папка вместо файла

    /// Модель лежит папкой (формат Apple), а не одним файлом.
    public var isFolderModel: Bool { !folderFileList.isEmpty }

    /// Из каких файлов состоит папка. Пусто — модель из одного файла.
    public var folderFileList: [ModelFolderFile] { folderFiles ?? [] }

    // MARK: Ссылки

    /// Ссылка на скачивание, закреплённая на коммит.
    /// Заголовок Authorization не нужен — репозитории gemma-4 открыты.
    public var downloadURL: URL {
        // Компоненты фиксированные и без пробелов, поэтому сборка строкой безопасна.
        // ⚠️ Берём путь ВНУТРИ репозитория, а не имя на диске: у частей папки они разные.
        let text = "https://huggingface.co/\(repoID)/resolve/\(repoCommit)/\(repoPath ?? fileName)"
        guard let url = URL(string: text) else {
            // Недостижимо при корректном каталоге; лучше упасть на сборке, чем молча качать не то.
            preconditionFailure("Некорректная ссылка на модель: \(text)")
        }
        return url
    }

    /// Страница модели — для экрана «О программе».
    public var pageURL: URL? {
        guard !repoID.isEmpty else { return nil }
        return URL(string: "https://huggingface.co/\(repoID)")
    }

    // MARK: Размеры и память

    /// Размер человеческим языком: «2,59 ГБ».
    ///
    /// ⚠️ Считает наш общий форматировщик, а не ByteCountFormatter. Тот брал разделитель
    /// дробной части из региональных настроек телефона: на нерусском устройстве выходило
    /// «2.59 ГБ» — точка от системы, «ГБ» от нас.
    public var humanSize: String {
        HumanFormat.bytes(byteSize)
    }

    /// Сколько свободной памяти просить ПЕРЕД попыткой на видеочипе (МБ).
    /// Есть замер — берём его с запасом 20%; замера нет — считаем по размеру файла.
    public var gpuMemoryRequirementMB: Int {
        gpuMemoryNeedMB(multimodal: false)
    }

    /// Сколько свободной памяти просить перед загрузкой на процессоре (МБ).
    /// Это минимум, без которого модель не поднимется вообще.
    public var cpuMemoryRequirementMB: Int {
        cpuMemoryNeedMB(multimodal: false)
    }

    /// То же, но с учётом исполнителей картинок и звука.
    ///
    /// ⚠️ Замеры Google сняты на ТЕКСТОВОЙ работе — для модели с картинками и звуком они
    /// занижены. Поэтому здесь берётся большее из двух: замер и правило по размеру файла
    /// с надбавкой. Обещать «памяти хватит» по текстовой мерке нельзя: система убьёт
    /// приложение уже во время загрузки, и человек увидит просто вылет.
    ///
    /// ⚠️ Имя не совпадает с именем свойства выше НАМЕРЕННО: свойство и метод с одинаковым
    /// началом имени в одном типе — верный способ поспорить с компилятором на ровном месте.
    /// ⚠️ ЗАПАС СНИЖЕН С 20% ДО 5% ПО ЖИВОМУ ЗАМЕРУ 09.08.2026, И ЭТО НЕ ПРИДИРКА
    /// К ЦИФРЕ, А ИСПРАВЛЕНИЕ ГЛАВНОЙ ПОЛОМКИ ДНЯ. Для Gemma 4 E4B мы требовали
    /// 4056 МБ свободной памяти под видеочип (замер Google 3380 плюс наши 20%),
    /// свободно было 3292 — и приложение раз за разом уводило модель на процессор.
    /// А на процессоре эта модель НЕ РАБОТАЕТ ВОВСЕ: пять разных настроек подряд,
    /// и на каждой пустой ответ. Стоило перебору насильно запустить её на видеочипе
    /// при тех же 3292 МБ — она сразу заговорила.
    ///
    /// То есть наш собственный запас, взятый «на всякий случай», и был тем, из-за чего
    /// модель, ради которой затевалось приложение, не работала. Замер Google — это уже
    /// пик потребления, накидывать поверх него пятую часть значит отказывать себе там,
    /// где всё бы прошло. 5% оставляем на разброс между устройствами.
    public func gpuMemoryNeedMB(multimodal: Bool) -> Int {
        let byRule = ModelMemoryRule.gpuRequirementMB(forFileBytes: byteSize, multimodal: multimodal)
        let measured = referencePeakGPUMemoryMB > 0
            ? Int(Double(referencePeakGPUMemoryMB) * 1.05)
            : byRule
        return max(requiredFreeMemoryMB, multimodal ? max(measured, byRule) : measured)
    }

    /// То же для процессора.
    public func cpuMemoryNeedMB(multimodal: Bool) -> Int {
        let byRule = ModelMemoryRule.cpuRequirementMB(forFileBytes: byteSize, multimodal: multimodal)
        guard referencePeakCPUMemoryMB > 0 else { return byRule }
        let measured = Int(Double(referencePeakCPUMemoryMB) * 1.5)
        return multimodal ? max(measured, byRule) : measured
    }

    // MARK: Мелочи

    /// Имя ресурса в бандле без расширения — если модель решат положить прямо в приложение.
    public var bundleResourceName: String {
        (fileName as NSString).deletingPathExtension
    }

    /// Расширение файла модели (обычно "litertlm").
    public var fileExtension: String {
        (fileName as NSString).pathExtension
    }

    /// Про эту модель нам известно всё: она из справочника и сумма на месте.
    public var isKnown: Bool {
        origin == .catalog && !sha256.isEmpty
    }

    /// Одна строка для карточки: «2,59 ГБ · работает и на видеочипе, и на процессоре».
    public var hardwareLine: String {
        "\(humanSize) · \(hardware.note)"
    }

    /// Предупреждение о переврании чисел, если эта модель будет считать на видеочипе.
    /// nil — предупреждать не о чем.
    ///
    /// ⚠️ Считать нужно ПО ФАКТУ РАСЧЁТА, а не по имени файла. Поломка живёт в расчёте
    /// на видеочипе, а не в слове «-gpu»: у владельца портил числа универсальный файл
    /// E4B — просто потому, что универсальный тоже уходит на видеочип, когда памяти
    /// хватает. Поэтому «только для видеочипа» предупреждаем всегда, а универсальную —
    /// когда вызывающий знает, что расчёт пошёл на видеочип.
    public func numbersWarning(runningOnGPU: Bool) -> String? {
        guard hardware == .gpuOnly || runningOnGPU else { return nil }
        return ModelWarnings.brokenNumbers
    }

    /// Требование к телефону словами. nil — Google цифры не публиковал.
    public var deviceRequirementNote: String? {
        guard minimumDeviceMemoryGB > 0 else { return nil }
        return "Google советует телефон с памятью от \(minimumDeviceMemoryGB) ГБ."
    }

    /// Та же модель, но с уточнённым железом. Нужно ровно затем, чтобы верить
    /// ЗАГОЛОВКУ САМОГО ФАЙЛА, а не записи в справочнике: справочник мог отстать
    /// от того, что Google переложил в репозитории.
    public func withHardware(_ newHardware: ModelHardware) -> ModelDescriptor {
        guard newHardware != hardware else { return self }
        return ModelDescriptor(id: id,
                               displayName: displayName,
                               repoID: repoID,
                               repoCommit: repoCommit,
                               fileName: fileName,
                               byteSize: byteSize,
                               sha256: sha256,
                               summary: summary,
                               hardware: newHardware,
                               origin: origin,
                               requiredFreeMemoryMB: requiredFreeMemoryMB,
                               referencePeakCPUMemoryMB: referencePeakCPUMemoryMB,
                               referencePeakGPUMemoryMB: referencePeakGPUMemoryMB,
                               minimumDeviceMemoryGB: minimumDeviceMemoryGB,
                               isForPhone: isForPhone,
                               license: license,
                               isRecommended: isRecommended,
                               folderFiles: folderFiles,
                               repoPath: repoPath)
    }

    /// Та же модель, но файл у человека называется иначе (его переименовали).
    ///
    /// ⚠️ Контрольную сумму и закреплённую версию при этом УБИРАЕМ. Узнать модель под
    /// чужим именем мы могли только по размеру, а размер у разных файлов совпадает
    /// побайтово (у сборок «-gpu» и «-web» он одинаковый). Обещать сумму в такой
    /// ситуации нельзя: честный файл получил бы отказ «содержимое отличается от эталона».
    public func withFileName(_ newFileName: String) -> ModelDescriptor {
        guard newFileName.lowercased() != fileName.lowercased() else { return self }
        return ModelDescriptor(id: id + "-local",
                               displayName: displayName,
                               repoID: repoID,
                               repoCommit: "main",
                               fileName: newFileName,
                               byteSize: byteSize,
                               sha256: "",
                               summary: summary,
                               hardware: hardware,
                               origin: origin,
                               requiredFreeMemoryMB: requiredFreeMemoryMB,
                               referencePeakCPUMemoryMB: referencePeakCPUMemoryMB,
                               referencePeakGPUMemoryMB: referencePeakGPUMemoryMB,
                               minimumDeviceMemoryGB: minimumDeviceMemoryGB,
                               isForPhone: isForPhone,
                               license: license,
                               isRecommended: false,
                               folderFiles: folderFiles,
                               repoPath: repoPath)
    }

    // MARK: Описание для принесённого файла

    /// Описание для файла, которого нет в справочнике.
    ///
    /// Имя для человека берётся ИЗ ИМЕНИ ФАЙЛА — внутри самого файла человеческого имени
    /// модели нет вовсе (ни в заголовке, ни в описании модели). Память считаем по размеру.
    public static func unknown(fileName: String,
                               byteSize: Int64,
                               hardware: ModelHardware = .universal) -> ModelDescriptor {
        ModelDescriptor(
            id: unknownID(for: fileName),
            displayName: ModelCatalog.humanName(forFileName: fileName),
            repoID: "",
            repoCommit: "main",
            fileName: fileName,
            byteSize: byteSize,
            sha256: "",
            summary: "Файл принесли на телефон. В справочнике приложения его нет — "
                + "значит, поручиться за него нельзя, но запустить можно.",
            hardware: hardware,
            origin: .unknownFile,
            license: "неизвестна — смотрите условия того, кто выложил файл",
            isRecommended: false
        )
    }

    /// Идентификатор для принесённого файла: только безопасные для имени файла знаки.
    private static func unknownID(for fileName: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let lower = fileName.lowercased()
        let cleaned = String(lower.map { allowed.contains($0) ? $0 : "-" })
        return "imported-" + cleaned
    }
}

// MARK: - Справочник моделей

/// Всё, что приложение знает про модели семейства Gemma в формате .litertlm.
///
/// ⚠️ Справочник НЕ ограничивает выбор человека. Он нужен ровно для трёх вещей:
///   1) показать имя и честное описание, если файл узнан;
///   2) предупредить заранее, если сборка не для iPhone (браузерная или под чужой ускоритель);
///   3) дать список того, что приложение умеет скачать само.
public enum ModelCatalog {

    // Репозитории и закреплённые версии.
    private static let repoE2B = "litert-community/gemma-4-E2B-it-litert-lm"
    private static let repoE4B = "litert-community/gemma-4-E4B-it-litert-lm"
    private static let repo12B = "litert-community/gemma-4-12B-it-litert-lm"
    private static let repo26B = "litert-community/gemma-4-26B-A4B-it-litert-lm"
    private static let repo31B = "litert-community/gemma-4-31B-it-litert-lm"
    private static let repo3nE2B = "google/gemma-3n-E2B-it-litert-lm"
    private static let repo3nE4B = "google/gemma-3n-E4B-it-litert-lm"
    private static let repo3_1B = "litert-community/Gemma3-1B-IT"
    private static let repo270m = "litert-community/gemma-3-270m-it"
    private static let repoFunction = "litert-community/functiongemma-270m-ft-mobile-actions"
    private static let repoFunctionGarden = "litert-community/functiongemma-270m-ft-tiny-garden"
    private static let repoMedGemma = "litert-community/MedGemma-1.5-4B-IT"

    /// Закреплённая версия репозитория E2B. Проверена на боевой загрузке.
    private static let commitE2B = "6b78abd019e61a1ca4cbe3b212d2c9ce8ff38a94"
    /// Текущая версия репозитория E4B (снята с Hugging Face 09.08.2026).
    /// ⚠️ Если загрузка начнёт отвечать 404 — значит репозиторий переехал: снять новый
    /// коммит с API и обновить эту строку. Молча ставить "main" НЕЛЬЗЯ: файл под нами
    /// подменится между релизами, и сумма перестанет сходиться.
    private static let commitE4B = "2eee7ac325f20eb8c9ac1d0e972f7c84663062da"
    /// «Версия не закреплена» — такие файлы приложение умеет только принять, но не скачать.
    private static let unpinned = "main"

    /// Условия закрытых репозиториев: файл нужно сначала получить самому.
    private static let gatedLicense = "по условиям Google (на Hugging Face нужно согласиться с лицензией)"

    // MARK: Gemma 4 E2B — рабочая лошадка приложения

    /// Основная модель приложения: та, которую оно умеет скачать само.
    /// ⚠️ Сборка ТОЛЬКО под видеочип. Запасного пути на процессор у неё нет.
    /// ⚠️ Опознаватель намеренно БЕЗ «-gpu», хотя файл именно gpu-шный: ровно этот
    /// опознаватель уже уехал в сборку у владельца, и по нему лежит точка докачки.
    /// Переименовать — значит бросить недокачанные гигабайты сиротой на телефоне.
    public static let gemma4E2BGPU = ModelDescriptor(
        id: "gemma-4-e2b-it",
        displayName: "Gemma 4 E2B (для видеочипа)",
        repoID: repoE2B,
        repoCommit: commitE2B,
        fileName: "gemma-4-E2B-it-gpu.litertlm",
        byteSize: 2_008_432_640,
        sha256: "a53a59001894c58e6bdb5b9b227709f91a2e3e556baa7d85acf9c55402ba5cf5",
        summary: "Самый лёгкий файл и самые быстрые ответы. Считает только на видеочипе: "
            + "не хватит ему памяти — откатиться на процессор не выйдет, модель просто не запустится. "
            + "А на видеочипе движок перевирает числа и даты — правкам с цифрами не верьте на слово. "
            + "Берите, если важна скорость и телефон свободен.",
        hardware: .gpuOnly,
        requiredFreeMemoryMB: AgentLimits.requiredFreeMemoryMB,
        // ⚠️ Замеры Google сделаны на универсальном файле той же модели (2583 МБ):
        // 607 МБ на процессоре, 1450 МБ на видеочипе. Для этой сборки отдельных цифр нет.
        referencePeakCPUMemoryMB: 607,
        referencePeakGPUMemoryMB: 1450,
        minimumDeviceMemoryGB: 8,
        license: "Apache 2.0",
        isRecommended: false
    )

    /// Универсальная сборка той же модели: тяжелее файлом, зато работает и без видеочипа.
    ///
    /// ⚠️ ИМЕННО ОНА — ГЛАВНАЯ МОДЕЛЬ ПРИЛОЖЕНИЯ, и это исправление живой поломки.
    /// Раньше по умолчанию скачивалась сборка «только для видеочипа», и у неё НЕТ
    /// запасного пути: не хватило видеочипу памяти в момент запуска — модель не поднимется
    /// вовсе, а человек читает «не удалось запустить, закройте другие приложения» и делает
    /// бесполезное. Владелец так и сказал: «должна спокойно грузиться, но почему-то
    /// не грузится». У этой сборки откат на процессор есть.
    /// Вдобавок известен баг с числами (LiteRT-LM #2814): «2033-01-10» превращается
    /// в «20333-01010» — для агента, который правит файлы, это приговор.
    /// ⚠️ УТОЧНЕНО 10.08.2026 ПО ПЕРЕПИСКЕ С ТЕЛЕФОНА: баг сидит в РАСЧЁТЕ НА ВИДЕОЧИПЕ,
    /// а не в слове «-gpu» в имени файла. У владельца числа портил универсальный файл
    /// E4B — потому что универсальный тоже уходит на видеочип, когда памяти хватает.
    /// Значит эта сборка спасает только там, где расчёт реально ушёл на процессор.
    ///
    /// Версия репозитория закреплена и сверена живым запросом 09.08.2026: размер
    /// 2 588 147 712 байт и контрольная сумма отданы Hugging Face на этом же коммите.
    public static let gemma4E2B = ModelDescriptor(
        id: "gemma-4-e2b-it-universal",
        displayName: "Gemma 4 E2B",
        repoID: repoE2B,
        repoCommit: commitE2B,
        fileName: "gemma-4-E2B-it.litertlm",
        byteSize: 2_588_147_712,
        sha256: "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
        summary: "Та же Gemma 4 E2B, но собранная на все случаи: пойдёт и на видеочипе, "
            + "и на процессоре. Файл больше, зато запускается почти на любом телефоне.",
        hardware: .universal,
        referencePeakCPUMemoryMB: 607,
        referencePeakGPUMemoryMB: 1450,
        minimumDeviceMemoryGB: 8,
        license: "Apache 2.0",
        isRecommended: true
    )

    /// Сборка для браузера. Весит РОВНО столько же, сколько «для видеочипа», — по размеру
    /// их не отличить, только по имени и контрольной сумме.
    public static let gemma4E2BWeb = ModelDescriptor(
        id: "gemma-4-e2b-it-web",
        displayName: "Gemma 4 E2B (для браузера)",
        repoID: repoE2B,
        repoCommit: unpinned,
        fileName: "gemma-4-E2B-it-web.litertlm",
        byteSize: 2_008_432_640,
        sha256: "3a08e8d94e23b814ae5414469c370c503813949acb8ceaa17e4ebf8a35af35b5",
        summary: "Сборка для браузера. Весит столько же, сколько сборка для видеочипа, "
            + "но на телефоне не работает — возьмите файл без «-web» в имени.",
        hardware: .browserOnly,
        license: "Apache 2.0"
    )

    // MARK: Gemma 4 E4B — умнее и тяжелее

    /// ★ Именно этот файл принёс владелец (3,66 ГБ) и получил отказ от старой проверки.
    ///
    /// ⚠️ ОПИСАНИЕ ИСПРАВЛЕНО ПО ЖИВОЙ ПЕРЕПИСКЕ 10.08.2026. Раньше здесь было написано
    /// «заметно аккуратнее в длинных задачах и с числами» — и это оказалось неправдой
    /// ровно там, где важнее всего: на телефоне E4B уходит на видеочип (на процессор
    /// её пускает только запас памяти, которого на телефоне нет), а на видеочипе числа
    /// как раз и портятся. Обещать человеку аккуратность с числами мы не вправе.
    public static let gemma4E4B = ModelDescriptor(
        id: "gemma-4-e4b-it-universal",
        displayName: "Gemma 4 E4B",
        repoID: repoE4B,
        repoCommit: commitE4B,
        fileName: "gemma-4-E4B-it.litertlm",
        byteSize: 3_659_530_240,
        sha256: "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0",
        summary: "Старшая из телефонных: держит длинную задачу лучше, но тяжелее и отвечает "
            + "медленнее. На телефоне почти всегда считает на видеочипе — а там числа и даты "
            + "в ответах перевираются, для правки файлов это опасно. "
            + "Google просит телефон с памятью от 12 ГБ.",
        hardware: .universal,
        referencePeakCPUMemoryMB: 961,
        referencePeakGPUMemoryMB: 3380,
        minimumDeviceMemoryGB: 12,
        license: "Apache 2.0"
    )

    /// Та же E4B, но только под видеочип.
    /// Опознаватель, как и у E2B, оставлен прежним — он уже уехал в сборку.
    public static let gemma4E4BGPU = ModelDescriptor(
        id: "gemma-4-e4b-it",
        displayName: "Gemma 4 E4B (для видеочипа)",
        repoID: repoE4B,
        repoCommit: commitE4B,
        fileName: "gemma-4-E4B-it-gpu.litertlm",
        byteSize: 2_969_059_328,
        sha256: "4912bb5a9c30993c51a7711f763212077458529312175df0573a78323a2bb7ff",
        summary: "E4B в лёгком файле, но считает только на видеочипе — а там движок "
            + "перевирает числа и даты в ответах. "
            + "На телефоне без большого запаса памяти лучше не брать.",
        hardware: .gpuOnly,
        referencePeakCPUMemoryMB: 961,
        referencePeakGPUMemoryMB: 3380,
        minimumDeviceMemoryGB: 12,
        license: "Apache 2.0"
    )

    public static let gemma4E4BWeb = ModelDescriptor(
        id: "gemma-4-e4b-it-web",
        displayName: "Gemma 4 E4B (для браузера)",
        repoID: repoE4B,
        repoCommit: commitE4B,
        fileName: "gemma-4-E4B-it-web.litertlm",
        byteSize: 2_969_059_328,
        sha256: "3904d826d5dddd25ea173e85204caec09e68ba038116e9b992b69cbdc94f57a0",
        summary: "Сборка для браузера — на телефоне не работает.",
        hardware: .browserOnly,
        license: "Apache 2.0"
    )

    // MARK: Gemma 3n — прошлое поколение, тоже принимаем

    /// Эту модель Google сам ставит в свой список для iOS.
    /// ⚠️ Репозиторий закрыт согласием с лицензией: скачать её приложение не может,
    /// но человек мог получить файл другим приложением — принять обязаны.
    public static let gemma3nE2B = ModelDescriptor(
        id: "gemma-3n-e2b-it-int4",
        displayName: "Gemma 3n E2B",
        repoID: repo3nE2B,
        repoCommit: unpinned,
        fileName: "gemma-3n-E2B-it-int4.litertlm",
        byteSize: 3_655_827_456,
        sha256: "2ed7bc3a0026c93d5b8a4544b352d9d00cd66ff0bac3ef6a20ac3d2cba4010d6",
        summary: "Прошлое поколение. В коде и рассуждениях слабее Gemma 4, но проверена "
            + "временем и работает как на видеочипе, так и на процессоре.",
        hardware: .universal,
        minimumDeviceMemoryGB: 6,
        license: gatedLicense
    )

    public static let gemma3nE2BWeb = ModelDescriptor(
        id: "gemma-3n-e2b-it-int4-web",
        displayName: "Gemma 3n E2B (для браузера)",
        repoID: repo3nE2B,
        repoCommit: unpinned,
        fileName: "gemma-3n-E2B-it-int4-Web.litertlm",
        byteSize: 3_038_117_888,
        sha256: "b6c8e1081ec80730f14473a5ece941b48da5d8e2a80c97c2963da153f3eff3d2",
        summary: "Сборка для браузера — на телефоне не работает. "
            + "Обратите внимание: слово «Web» здесь с большой буквы.",
        hardware: .browserOnly,
        license: gatedLicense
    )

    public static let gemma3nE4B = ModelDescriptor(
        id: "gemma-3n-e4b-it-int4",
        displayName: "Gemma 3n E4B",
        repoID: repo3nE4B,
        repoCommit: unpinned,
        fileName: "gemma-3n-E4B-it-int4.litertlm",
        byteSize: 4_919_541_760,
        sha256: "2e67a6cd51dfe0f793431e6bd4ed8d029c88e10f52ca0469ad38445e3cd3c1f4",
        summary: "Старшая из прошлого поколения: аккуратнее, но почти 5 ГБ файла. "
            + "Google просит телефон с памятью от 8 ГБ.",
        hardware: .universal,
        minimumDeviceMemoryGB: 8,
        license: gatedLicense
    )

    public static let gemma3nE4BWeb = ModelDescriptor(
        id: "gemma-3n-e4b-it-int4-web",
        displayName: "Gemma 3n E4B (для браузера)",
        repoID: repo3nE4B,
        repoCommit: unpinned,
        fileName: "gemma-3n-E4B-it-int4-Web.litertlm",
        byteSize: 4_275_044_352,
        sha256: "63730ba3225a23a90d3292d89fdeff1a7537cedeb72aa687de9a35732d057e52",
        summary: "Сборка для браузера — на телефоне не работает.",
        hardware: .browserOnly,
        license: gatedLicense
    )

    // MARK: Маленькие модели — для слабых телефонов и опытов

    /// Самая маленькая из «взрослых»: 584 МБ.
    /// ⚠️ Формат у неё старый (1.0.0) и метки семейства внутри нет вовсе — именно поэтому
    /// проверка файла НЕ имеет права требовать метку «это Gemma».
    public static let gemma3_1B = ModelDescriptor(
        id: "gemma3-1b-it-int4",
        displayName: "Gemma 3 1B",
        repoID: repo3_1B,
        repoCommit: unpinned,
        fileName: "gemma3-1b-it-int4.litertlm",
        byteSize: 584_417_280,
        sha256: "1325ae366d31950f137c9c357b9fa89448b176d76998180c08ceaca78bba98be",
        summary: "Самая лёгкая и быстрая, помещается почти в любой телефон. "
            + "Но заметно проще остальных: путает числа и хуже держит длинные указания. "
            + "Годится, когда важнее скорость, чем аккуратность.",
        hardware: .universal,
        minimumDeviceMemoryGB: 4,
        license: gatedLicense
    )

    /// Тот же самый файл под другим именем (сумма совпадает побайтово).
    /// Держим отдельной записью, чтобы узнать модель, как бы её ни назвали.
    public static let gemma3_1BLongName = ModelDescriptor(
        id: "gemma3-1b-it-int4-ekv4096",
        displayName: "Gemma 3 1B",
        repoID: repo3_1B,
        repoCommit: unpinned,
        fileName: "Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm",
        byteSize: 584_417_280,
        sha256: "1325ae366d31950f137c9c357b9fa89448b176d76998180c08ceaca78bba98be",
        summary: "Это тот же файл, что «Gemma 3 1B», просто выложен под другим именем.",
        hardware: .universal,
        minimumDeviceMemoryGB: 4,
        license: gatedLicense
    )

    public static let gemma3_270m = ModelDescriptor(
        id: "gemma3-270m-it-q8",
        displayName: "Gemma 3 270M",
        repoID: repo270m,
        repoCommit: unpinned,
        fileName: "gemma3-270m-it-q8.litertlm",
        byteSize: 304_005_120,
        sha256: "757e9119fa5bd667a2774fb470ac4afcd3190a21c677f8e69a5d6bc908abdd63",
        summary: "Крошечная модель на 304 МБ — интересна как опыт. "
            + "Для работы агентом слишком проста: путается в указаниях и в путях файлов.",
        hardware: .universal,
        license: gatedLicense
    )

    public static let functionGemmaMobile = ModelDescriptor(
        id: "functiongemma-270m-mobile-actions",
        displayName: "FunctionGemma 270M (действия в телефоне)",
        repoID: repoFunction,
        repoCommit: unpinned,
        fileName: "mobile_actions_q8_ekv1024.litertlm",
        byteSize: 288_964_608,
        sha256: "33e295cbd996b419bb1de8f3f85c5b6b01ee058a2c89bdb2173cf3e6ff4ce9d0",
        summary: "Крошечная модель, обученная вызывать инструменты, но под чужой набор задач. "
            + "Обычный разговор ведёт плохо.",
        hardware: .universal,
        license: gatedLicense
    )

    public static let functionGemmaGarden = ModelDescriptor(
        id: "functiongemma-270m-tiny-garden",
        displayName: "FunctionGemma 270M (садовые задачи)",
        repoID: repoFunctionGarden,
        repoCommit: unpinned,
        fileName: "tiny_garden_q8_ekv1024.litertlm",
        byteSize: 288_964_608,
        sha256: "38067934eac6845417a456602da8714e1c0a5ae28970140d3b5f6abaf48e3141",
        summary: "Та же крошечная модель, дообученная под другие задачи. "
            + "Весит столько же, сколько соседняя, а внутри другая — по размеру их не различить.",
        hardware: .universal,
        license: gatedLicense
    )

    public static let medGemma = ModelDescriptor(
        id: "medgemma-1.5-4b-it",
        displayName: "MedGemma 1.5 4B",
        repoID: repoMedGemma,
        repoCommit: unpinned,
        fileName: "medgemma-1.5-4b-it_q4_block32_ekv2048.litertlm",
        byteSize: 2_583_871_056,
        sha256: "6778edd3137104d8b47f65b24dbc21c8eecb0329c987a3d64bd2fba201e6bf51",
        summary: "Медицинская Gemma. Для кода и обычных задач хуже обычной. "
            + "Весит почти столько же, сколько Gemma 4 E2B, — по размеру их не отличить.",
        hardware: .universal,
        license: gatedLicense
    )

    public static let medGemmaVision = ModelDescriptor(
        id: "medgemma-1.5-4b-it-vision",
        displayName: "MedGemma 1.5 4B (с картинками)",
        repoID: repoMedGemma,
        repoCommit: unpinned,
        fileName: "medgemma-1.5-4b-it_q4_block32_vision_ekv2048.litertlm",
        byteSize: 3_023_069_488,
        sha256: "1627e2e433c3799e4ff06ff0895408ca65b255f786dc270fb5cfa325e349233a",
        summary: "Медицинская Gemma, умеющая ещё и картинки. Приложение картинки не использует.",
        hardware: .universal,
        license: gatedLicense
    )

    // MARK: Крупные модели — узнаём, но на телефон не пускаем

    public static let gemma4_12BGPU = ModelDescriptor(
        id: "gemma-4-12b-it-gpu",
        displayName: "Gemma 4 12B (для видеочипа)",
        repoID: repo12B,
        repoCommit: unpinned,
        fileName: "gemma-4-12B-it-gpu.litertlm",
        byteSize: 5_986_074_624,
        sha256: "fba0ea417fda0eecdcc1e62e0ea7777acf44f171cefb3bc05a642746f39faf39",
        summary: "Модель для компьютера: почти 6 ГБ. На iPhone памяти под неё не хватит.",
        hardware: .gpuOnly,
        isForPhone: false,
        license: "Apache 2.0"
    )

    public static let gemma4_12BWeb = ModelDescriptor(
        id: "gemma-4-12b-it-web",
        displayName: "Gemma 4 12B (для браузера)",
        repoID: repo12B,
        repoCommit: unpinned,
        fileName: "gemma-4-12B-it-web.litertlm",
        byteSize: 5_986_074_624,
        sha256: "d37f9392b4f093b470b50b72624c9a752cc0b288ed549b769037cbbd04024449",
        summary: "Сборка для браузера, да ещё и размером с компьютерную. На телефоне не работает.",
        hardware: .browserOnly,
        isForPhone: false,
        license: "Apache 2.0"
    )

    public static let gemma4_12B = ModelDescriptor(
        id: "gemma-4-12b-it",
        displayName: "Gemma 4 12B",
        repoID: repo12B,
        repoCommit: unpinned,
        fileName: "gemma-4-12B-it.litertlm",
        byteSize: 6_547_589_312,
        sha256: "74fc29a10c20eb5b3ced6c389471a7994a0ffd657255b2a1c764262fb9054aef",
        summary: "Модель для компьютера: 6,5 ГБ. Телефон её не потянет.",
        hardware: .universal,
        isForPhone: false,
        license: "Apache 2.0"
    )

    public static let gemma4_26BGPU = ModelDescriptor(
        id: "gemma-4-26b-a4b-it-gpu",
        displayName: "Gemma 4 26B (для видеочипа)",
        repoID: repo26B,
        repoCommit: unpinned,
        fileName: "gemma-4-26B-A4B-it-gpu.litertlm",
        byteSize: 15_786_524_672,
        sha256: "94bbde2453dd9b67c61c16017af331e5841cbbd9edf83bd2f84bc73e2a7cbdb1",
        summary: "15,8 ГБ — это модель для настольной машины, не для телефона.",
        hardware: .gpuOnly,
        isForPhone: false,
        license: "Apache 2.0"
    )

    public static let gemma4_26BWeb = ModelDescriptor(
        id: "gemma-4-26b-a4b-it-web",
        displayName: "Gemma 4 26B (для браузера)",
        repoID: repo26B,
        repoCommit: unpinned,
        fileName: "gemma-4-26B-A4B-it-web.litertlm",
        byteSize: 15_786_524_672,
        sha256: "4523b2de695a7f22dc675b716253ba9a8512ca9f4852fb6a682fe4c2eb859c16",
        summary: "Сборка для браузера размером 15,8 ГБ. На телефоне не работает.",
        hardware: .browserOnly,
        isForPhone: false,
        license: "Apache 2.0"
    )

    public static let gemma4_31BGPU = ModelDescriptor(
        id: "gemma-4-31b-it-gpu",
        displayName: "Gemma 4 31B (для видеочипа)",
        repoID: repo31B,
        repoCommit: unpinned,
        fileName: "gemma-4-31B-it-gpu.litertlm",
        byteSize: 19_217_989_632,
        sha256: "6cd4031c2f3a6c8dc7f96eaf4ded58132de82e38b49862e5c2ed1ef8cc450e35",
        summary: "19,2 ГБ — только для настольной машины.",
        hardware: .gpuOnly,
        isForPhone: false,
        license: "Apache 2.0"
    )

    public static let gemma4_31BWeb = ModelDescriptor(
        id: "gemma-4-31b-it-web",
        displayName: "Gemma 4 31B (для браузера)",
        repoID: repo31B,
        repoCommit: unpinned,
        fileName: "gemma-4-31B-it-web.litertlm",
        byteSize: 19_217_989_632,
        sha256: "5131b21f70265632e7545abe21dc6b52ff6a690779033eef48d368957374035b",
        summary: "Сборка для браузера на 19,2 ГБ. На телефоне не работает.",
        hardware: .browserOnly,
        isForPhone: false,
        license: "Apache 2.0"
    )

    // MARK: Сборки под чужие ускорители

    /// Сборки того же репозитория E2B под чужое железо. Держим их в справочнике, чтобы
    /// вместо «неизвестный файл» человек получил внятное «это сборка под чужой ускоритель».
    /// Сборки под чужое железо из остальных репозиториев опознаются по имени файла
    /// (см. `hardware(forFileName:)`) — перечислять их все смысла нет.
    public static let foreignChipBuilds: [ModelDescriptor] = [
        foreignChip(id: "gemma-4-e2b-it-tensor-g5",
                    fileName: "gemma-4-E2B-it_Google_Tensor_G5.litertlm",
                    byteSize: 3_113_545_589,
                    sha256: "af1082986639ecde7db95d91be6fe54f8b6b458104734c5bafc204e69d6852dc",
                    chip: "нейроускоритель Google Tensor G5 (телефоны Pixel)"),
        foreignChip(id: "gemma-4-e2b-it-intel-lnl",
                    fileName: "gemma-4-E2B-it_intel_LNL.litertlm",
                    byteSize: 2_960_506_880,
                    sha256: "dacc900381bdc837696fc5deb1f3b7dbfe0854295dc3934564e1841086ab0383",
                    chip: "процессоры Intel Lunar Lake (ноутбуки)"),
        foreignChip(id: "gemma-4-e2b-it-intel-ptl",
                    fileName: "gemma-4-E2B-it_intel_PTL.litertlm",
                    byteSize: 2_948_333_568,
                    sha256: "8c0877f721ff0c057a007b330bbf9f6ec4d0278e730f88db95f2252372c701e8",
                    chip: "процессоры Intel Panther Lake"),
        foreignChip(id: "gemma-4-e2b-it-qcs8275",
                    fileName: "gemma-4-E2B-it_qualcomm_qcs8275.litertlm",
                    byteSize: 3_294_593_024,
                    sha256: "ebc103e548e76a34b8114a1dc1dd6d33a893c38add108d8bae8165b51f320f02",
                    chip: "нейроускоритель Qualcomm QCS8275"),
        foreignChip(id: "gemma-4-e2b-it-sm8750",
                    fileName: "gemma-4-E2B-it_qualcomm_sm8750.litertlm",
                    byteSize: 3_016_294_400,
                    sha256: "41dd675fbe735b6029012b5576a5716bac614fd8156de0128db4c9dff3cebd4e",
                    chip: "Qualcomm Snapdragon 8 Elite"),
        foreignChip(id: "gemma-3n-e2b-it-mt6993",
                    repoID: repo3nE2B,
                    fileName: "gemma-3n-E2B-it-int4.mediatek.mt6993.litertlm",
                    byteSize: 4_330_192_896,
                    sha256: "ba38d54766a3a51cb977499a852d9839843c496a4f2f16c8b472a2cd52b8ab94",
                    chip: "нейроускоритель MediaTek",
                    license: gatedLicense)
    ]

    private static func foreignChip(id: String,
                                    repoID: String = repoE2B,
                                    fileName: String,
                                    byteSize: Int64,
                                    sha256: String,
                                    chip: String,
                                    license: String = "Apache 2.0") -> ModelDescriptor {
        ModelDescriptor(
            id: id,
            displayName: ModelCatalog.humanName(forFileName: fileName),
            repoID: repoID,
            repoCommit: unpinned,
            fileName: fileName,
            byteSize: byteSize,
            sha256: sha256,
            summary: "Сборка под \(chip). На iPhone она не запустится — возьмите обычный файл.",
            hardware: .foreignChip,
            isForPhone: false,
            license: license
        )
    }

    // MARK: Модели для движка Apple — они лежат ПАПКОЙ, а не файлом

    // ⚠️ ВСЁ НИЖЕ СНЯТО ЖИВЫМ ЗАПРОСОМ К HUGGING FACE 10.08.2026: версия репозитория,
    // состав файлов, размер каждого файла и контрольные суммы крупных. Ни одну цифру
    // нельзя поправить «по памяти» — только новым ответом сервера. Если загрузка начнёт
    // отвечать 404, значит репозиторий переехал: снять свежую версию и обновить строки.
    //
    // ⚠️ ПОЧЕМУ ФАЙЛОВ РОВНО СТОЛЬКО. Мы берём те же файлы, что и загрузчик самой Apple:
    // `*.safetensors`, `*.json`, `*.jinja` (`MLXLMCommon/ModelFactory.swift`). Всё
    // остальное в этих репозиториях (README, .gitattributes, merges.txt) движку Apple
    // не нужно — он его не качает и не читает, а лишние мегабайты по мобильной сети
    // человек оплачивает своими.

    /// ★ Главная модель для движка Apple. Её и предлагаем первой.
    ///
    /// ⚠️ ЧЕМ ОНА ОСОБЕННАЯ И ПОЧЕМУ ВЫБРАНА ИМЕННО ОНА. Внутри неё 32 набора знаний,
    /// но на каждое слово работают лишь четыре из них. Отсюда и вся выгода: знает она
    /// как большая модель, а считает как маленькая — ровно то, что просил владелец
    /// («что-то среднее между скоростью и интеллектом, чтоб был комфорт»).
    ///
    /// Три проверяемые причины:
    ///   • **влезает целиком**: 4,85 ГБ при примерно 6 ГБ свободных на iPhone Air —
    ///     значит, ничего не надо подгружать с диска на ходу;
    ///   • **движок Apple знает её устройство**: `model_type: lfm2_moe` есть в списке
    ///     моделей библиотеки (`LLMModelFactory`) — ни строчки нового кода не нужно;
    ///   • **вызовы действий разбираются**: библиотека сама определяет вид вызова
    ///     по устройству модели (`ToolCallFormat.infer`, всё, что начинается с «lfm2»),
    ///     а в шаблоне разговора модели этот же вид и записан —
    ///     `<|tool_call_start|>[…]<|tool_call_end|>`. То есть просьба модели «прочитай
    ///     файл» доедет до нас вызовом действия, а не пересказом словами.
    ///
    /// ⚠️ ЧЕГО МЫ ПРО НЕЁ НЕ ЗНАЕМ — И ЭТО ВАЖНЕЕ ВСЕГО, ЧТО НАПИСАНО ВЫШЕ.
    /// Сколько памяти она займёт НА САМОМ ДЕЛЕ — неизвестно. Наш расчёт (доля от веса
    /// папки, `ModelFitRule.mlxShare`) — прикидка, а не замер: движок Apple мы не мерили
    /// ни разу, ни на одной модели. Чужой замер на одной и той же модели показывал
    /// у MLX 3 ГБ там, где движок Google обходился 497 МБ. Цифра подозрительная,
    /// проверить её можно только на живом телефоне — на симуляторе движок Apple
    /// не считает вовсе.
    ///
    /// ⚠️ ВСЁ ПРО ФАЙЛЫ СНЯТО ЖИВЫМ ЗАПРОСОМ К HUGGING FACE 10.08.2026: версия
    /// репозитория, состав (7 файлов), размер каждого и суммы крупных. Шаблон разговора
    /// (`chat_template.jinja`) в папке ЕСТЬ — проверено там же; без него модель
    /// не узнала бы, что у неё вообще есть действия.
    public static let mlxLFM2_5 = ModelDescriptor(
        id: "mlx-lfm2-5-8b-a1b-4bit",
        displayName: "LFM2.5 8B (для движка Apple)",
        repoID: "LiquidAI/LFM2.5-8B-A1B-MLX-4bit",
        repoCommit: "760bf10c9e91d8330a554ae144fdb2bcd597b0c2",
        fileName: "LFM2.5-8B-A1B-MLX-4bit",
        byteSize: 4_851_982_711,
        sha256: "",
        summary: "Модель для движка Apple, и самая интересная из них: она много знает, "
            + "но на каждое слово включает только малую часть себя — поэтому отвечает "
            + "быстро. На телефон приезжает папкой из 7 файлов. "
            + "Сколько памяти она займёт на самом деле, мы не знаем: движок Apple "
            + "на телефоне ещё ни разу не запускался, и наша цифра — расчёт, а не замер.",
        hardware: .universal,
        license: "LFM Open License v1.0 — смотрите условия на странице модели",
        isRecommended: true,
        folderFiles: [
            ModelFolderFile(name: "generation_config.json", byteSize: 230),
            ModelFolderFile(name: "tokenizer_config.json", byteSize: 315),
            ModelFolderFile(name: "config.json", byteSize: 1_858),
            ModelFolderFile(name: "chat_template.jinja", byteSize: 4_621),
            ModelFolderFile(name: "model.safetensors.index.json", byteSize: 40_148),
            ModelFolderFile(name: "tokenizer.json", byteSize: 17_905_598,
                            sha256: "695be7802a0e4b8a81048f0ff5ebb7fc811a0ba5a6be63dbb24deb5a81096f41"),
            ModelFolderFile(name: "model.safetensors", byteSize: 4_834_029_941,
                            sha256: "3cc15631acc1894b3584ac11fb4122beee50b604e1a0be575da686cee87aa3a4")
        ]
    )

    /// Модель Apple полегче — на случай, если главная не влезет.
    ///
    /// ⚠️ ЗАЧЕМ ВТОРАЯ. Главная весит 4,85 ГБ, и на телефоне, где свободно меньше,
    /// её просто некуда положить. Эта — 2,28 ГБ, вдвое легче, и вызовы действий у неё
    /// в самом ходовом виде (`<tool_call>{…}</tool_call>`), который библиотека Apple
    /// разбирает по умолчанию. Устройство модели (`model_type: qwen3`) библиотека тоже
    /// знает. Всё проверено живым запросом 10.08.2026.
    public static let mlxQwen3_4B = ModelDescriptor(
        id: "mlx-qwen3-4b-instruct-2507-4bit",
        displayName: "Qwen3 4B (для движка Apple)",
        repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        repoCommit: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
        fileName: "Qwen3-4B-Instruct-2507-4bit",
        byteSize: 2_277_297_844,
        sha256: "",
        summary: "Модель для движка Apple. На телефон приезжает папкой из 10 файлов, "
            + "а не одним файлом. Самая лёгкая из тех, что мы предлагаем для этого движка, "
            + "и умеет пользоваться действиями. Живьём мы её ещё не запускали: "
            + "проверить движок Apple можно только на настоящем телефоне.",
        hardware: .universal,
        license: "Apache 2.0",
        folderFiles: [
            ModelFolderFile(name: "generation_config.json", byteSize: 238),
            ModelFolderFile(name: "special_tokens_map.json", byteSize: 613),
            ModelFolderFile(name: "added_tokens.json", byteSize: 707),
            ModelFolderFile(name: "config.json", byteSize: 938),
            ModelFolderFile(name: "chat_template.jinja", byteSize: 4_040),
            ModelFolderFile(name: "tokenizer_config.json", byteSize: 5_440),
            ModelFolderFile(name: "model.safetensors.index.json", byteSize: 63_964),
            ModelFolderFile(name: "vocab.json", byteSize: 2_776_833),
            ModelFolderFile(name: "tokenizer.json", byteSize: 11_422_654,
                            sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ModelFolderFile(name: "model.safetensors", byteSize: 2_263_022_417,
                            sha256: "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f")
        ]
    )

    // MARK: GGUF — файлы отдельного движка (llama.cpp)

    /// ★ Bonsai 2 27B — тернарная модель, ради которой приложению открыли третий вид файлов.
    ///
    /// ⚠️ ВСЁ ПРО ФАЙЛ СНЯТО ЖИВЫМ ЗАПРОСОМ К HUGGING FACE 20.09.2026: версия репозитория,
    /// точный размер (5 946 648 928 байт) и контрольная сумма. Ни одну цифру нельзя
    /// поправить «по памяти» — только новым ответом сервера.
    ///
    /// ⚠️ ЗРЕНИЕ НЕ ПОДКЛЮЧЕНО — ПРИЛОЖЕНИЕ БЕРЁТ ТОЛЬКО ТЕКСТ. В том же репозитории
    /// рядом лежит отдельный файл зрения (mmproj-Q8_0, 629 246 976 байт, sha256
    /// 6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903 — снято тем же
    /// запросом 20.09.2026). Мы его не качаем и не читаем: без него модель умеет только
    /// текст, и обещать картинки человеку нельзя.
    ///
    /// ⚠️ ЧЕГО МЫ ПРО НЕЁ НЕ ЗНАЕМ. Сколько она займёт памяти — расчёт по доле файла
    /// (`ModelFitRule.ggufShare`), а не замер: наш GGUF-движок на телефоне ещё не гонялся.
    /// Скорость «4–5 слов в секунду» и слабость в вызове действий — из разведки на телефоне,
    /// не наш собственный замер, поэтому в описании для человека это «примерно».
    public static let bonsai27B = ModelDescriptor(
        id: "bonsai-2-27b-ptq1-0-gguf",
        displayName: "Bonsai 2 27B (GGUF)",
        repoID: "prism-ml/Ternary-Bonsai-2-27B-gguf",
        repoCommit: "6ed5e12bf84b7a63069882c91dd9e9218647d17b",
        fileName: "Ternary-Bonsai-2-27B-PTQ1_0.gguf",
        byteSize: 5_946_648_928,
        sha256: "53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3",
        summary: "Внутри 27 миллиардов весов, но каждый вес — всего одно из трёх значений, "
            + "поэтому файл весит меньше шести гигабайт. Сильная в математике и рассуждениях, "
            + "но действия вызывает неуверенно: чаще расскажет, что сделала бы, чем возьмётся "
            + "за файл. На телефоне отвечает примерно 4–5 слов в секунду и влезает только "
            + "с короткой историей разговора. Картинки не понимает: приложению отдаётся "
            + "только текстовая часть модели.",
        hardware: .universal,
        license: "Apache 2.0"
    )

    // MARK: Чужие переделки без цензуры

    // ⚠️⚠️ ЗАЧЕМ ОНИ ЗДЕСЬ ВООБЩЕ. Живая жалоба владельца 10.08.2026: он искал модель
    // без цензуры и не нашёл её ВООБЩЕ — «добавь в списки моделей те которых нет».
    // До этой правки во встроенном списке были только сборки Google: двадцать четыре
    // Gemma и ни одной чужой переделки. Философия проекта тут однозначна (ROADMAP,
    // раздел 6): предупреждение, а не запрет. Прячем — человек уходит искать в браузер
    // и приносит файл вслепую; показываем с честной пометкой — он решает сам.
    //
    // ⚠️⚠️ И ГЛАВНОЕ, О ЧЁМ НЕЛЬЗЯ ПРОМОЛЧАТЬ НИ В ОДНОМ ИЗ ЭТИХ ОПИСАНИЙ.
    // «Без цензуры» делают так: у модели вырезают способность отказываться. Отказ и
    // послушание — это одно и то же умение, и вырезают их вместе. А наше приложение
    // держится на том, что модель ЗОВЁТ ДЕЙСТВИЕ («прочитай файл», «запиши файл»),
    // а не рассказывает словами, что бы она сделала. Переделанная модель заметно чаще
    // сбивается на рассказ — и человек получает красивую модель, которая не умеет
    // работать с файлами. Это написано в каждом описании ниже человеческими словами:
    // не пугая, но и не умалчивая.
    //
    // ⚠️ ВСЕ ЦИФРЫ НИЖЕ СНЯТЫ ЖИВЫМ ЗАПРОСОМ К HUGGING FACE 10.08.2026: версия
    // репозитория, имя файла, точный размер и контрольная сумма. Ни одну нельзя
    // поправить «по памяти» — только новым ответом сервера.
    //
    // ⚠️ ЗАМЕРОВ ПАМЯТИ У НИХ НЕТ И БЫТЬ НЕ МОЖЕТ. Поля `referencePeak…` и
    // `minimumDeviceMemoryGB` оставлены нулями НАМЕРЕННО: замеры Google сделаны на его
    // собственных файлах, а эти собирали чужие руки. Расход для них считается по размеру
    // файла, и человеку он показывается с пометкой «расчёт» (см. `ModelFitRule`).

    /// ★ Та самая модель, которую владелец искал и не нашёл.
    /// Переделка Gemma 4 E4B: сначала её дообучили (SuperGemma), потом сняли отказы.
    public static let superGemma4E4BAbliterated = ModelDescriptor(
        id: "supergemma4-e4b-abliterated",
        displayName: "SuperGemma 4 E4B (без цензуры)",
        repoID: "typomonster/supergemma4-e4b-abliterated-litert-lm",
        repoCommit: "3cb37a0fe1688c84cdb9faaa273052d82b8ca68b",
        fileName: "supergemma4-e4b-abliterated.litertlm",
        byteSize: 3_654_467_584,
        sha256: "83399794f0ad10166c0034451e06b9cdb120590eab3665863ff20e443b3f9750",
        summary: "Gemma 4 E4B, переделанная чужими руками: отказы у неё сняты. "
            + "Собирал не Google, никто её не проверял. "
            + "Учтите главное: вместе с отказами у таких моделей слабеет послушание — "
            + "она чаще рассказывает словами, что сделала бы, вместо того чтобы взяться "
            + "за файл. Сколько ей нужно памяти, мы считаем, а не мерили.",
        hardware: .universal,
        license: "Gemma Terms of Use — условия Google на странице модели",
        isRecommended: false
    )

    /// Самая ходовая из переделок в этом виде файлов: 2342 скачивания на 10.08.2026 —
    /// больше, чем у любой другой сборки без цензуры под движок Google.
    /// ⚠️ В репозитории лежат ТРИ файла, и два из них весят побайтово одинаково при разном
    /// содержимом. Берём самый лёгкий и с самым понятным именем — угадывать за человека,
    /// чем «model.litertlm» отличается от «gemma4_uncensored_INT4_8192.litertlm», нечестно;
    /// остальные два он увидит на странице поиска.
    public static let gemma4E2BUncensored = ModelDescriptor(
        id: "gemma-4-e2b-uncensored-max",
        displayName: "Gemma 4 E2B (без цензуры)",
        repoID: "PeppX/gemma-4-e2b-uncensored-litertlm",
        repoCommit: "0adcc4e5497d0bd4202a7a6f2c72c00d1a0d4be9",
        fileName: "gemma-4-E2B-it-Uncensored-MAX.litertlm",
        byteSize: 2_550_041_824,
        sha256: "34738f7eb50d04ee123d23dcea0df0b49e074b555134101251685f9416f39bb9",
        summary: "Младшая Gemma 4, переделанная чужими руками: отказы сняты. "
            + "Самая лёгкая из таких и самая ходовая. Собирал не Google, никто её "
            + "не проверял. Вместе с отказами у таких моделей слабеет послушание — "
            + "она чаще отвечает словами вместо того, чтобы взяться за файл. "
            + "Сколько ей нужно памяти, мы считаем, а не мерили.",
        hardware: .universal,
        license: "Apache 2.0",
        isRecommended: false
    )

    /// Gemma 4 E4B со снятыми отказами — без дообучения, сама Google-сборка, только правленая.
    ///
    /// ⚠️⚠️ ВЕСИТ РОВНО СТОЛЬКО ЖЕ, СКОЛЬКО ОБЫЧНАЯ E4B (3 659 530 240 байт), а внутри —
    /// другое: контрольные суммы разные. Так и должно быть, правка весов размер файла
    /// не меняет. Отсюда следствие, которое надо знать: принесённый файл ЭТОГО размера
    /// приложение больше не опознаёт «по размеру» — два разных файла делят одно число,
    /// и `recognize` в таком случае честно молчит вместо того, чтобы назвать наугад.
    /// Опознание по ИМЕНИ (а с ним и обычная E4B владельца) работает как работало.
    public static let gemma4E4BAbliterated = ModelDescriptor(
        id: "gemma-4-e4b-it-abliterated",
        displayName: "Gemma 4 E4B (без цензуры)",
        repoID: "olekk/gemma-4-E4B-it-abliterated-litert-lm",
        repoCommit: "a4eecccd3b0ba1777660180cda60a396eedcb8aa",
        fileName: "gemma-4-E4B-it-abliterated.litertlm",
        byteSize: 3_659_530_240,
        sha256: "f5a6625e0368e853743c91b39fa6ac6a8add1fc4825b18f98f518966610f2a88",
        summary: "Старшая телефонная Gemma 4 со снятыми отказами. Собирал не Google, "
            + "никто её не проверял. Вместе с отказами у таких моделей слабеет "
            + "послушание — она чаще рассказывает словами, что сделала бы, вместо того "
            + "чтобы взяться за файл. Тяжёлая: на телефоне почти всегда считает "
            + "на видеочипе, а там движок перевирает числа и даты. "
            + "Сколько ей нужно памяти, мы считаем, а не мерили.",
        hardware: .universal,
        license: "Apache 2.0",
        isRecommended: false
    )

    // MARK: Списки

    /// Всё, что приложение узнаёт. Порядок важен только для показа.
    public static let all: [ModelDescriptor] = [
        gemma4E2B,
        gemma4E2BGPU,
        gemma4E4B,
        gemma4E4BGPU,
        mlxLFM2_5,
        mlxQwen3_4B,
        bonsai27B,
        gemma3nE2B,
        gemma3nE4B,
        gemma3_1B,
        gemma3_1BLongName,
        gemma3_270m,
        functionGemmaMobile,
        functionGemmaGarden,
        medGemma,
        medGemmaVision,
        // ⚠️ Чужие переделки идут ПОСЛЕ сборок Google, и это не случайный порядок:
        // сверху то, за что мы можем ручаться, ниже — то, что человек берёт на свой страх.
        gemma4E2BUncensored,
        superGemma4E4BAbliterated,
        gemma4E4BAbliterated,
        gemma4E2BWeb,
        gemma4E4BWeb,
        gemma3nE2BWeb,
        gemma3nE4BWeb,
        gemma4_12B,
        gemma4_12BGPU,
        gemma4_12BWeb,
        gemma4_26BGPU,
        gemma4_26BWeb,
        gemma4_31BGPU,
        gemma4_31BWeb
    ] + foreignChipBuilds

    /// Что ПРЕДЛАГАЕМ скачать, пока на телефоне нет ни одной модели.
    /// ⚠️ Именно эта модель закреплена на версию репозитория и проверена загрузкой.
    ///
    /// ⚠️ ЭТО СОВЕТ, А НЕ «АКТИВНАЯ МОДЕЛЬ», И ПУТАТЬ ОДНО С ДРУГИМ ДОРОГО. Живая жалоба
    /// владельца 10.08.2026: «по умолчанию аппка якобы видит гемма 4 E2B, хотя её нету
    /// даже в папке». Выходило так: движок брал с телефона настоящий файл (E4B), но выбор
    /// человека оставался пустым — а на пустой выбор всё приложение отвечало вот этой
    /// строчкой. Теперь взятый файл сразу запоминается выбором (`LiteRTRuntime`,
    /// шаг «беру модель, которая уже лежит на телефоне»), и сюда доходит только случай
    /// «на телефоне нет вообще ничего». Появится соблазн ответить этой моделью на вопрос
    /// «какая модель работает» — не отвечать: работающую знает движок.
    public static let `default`: ModelDescriptor = gemma4E2B

    /// Модели, которые имеет смысл предлагать на телефоне.
    public static var forPhone: [ModelDescriptor] {
        all.filter { $0.isForPhone && $0.hardware.isUsableOnIPhone }
    }

    /// То, что стоит показать первым.
    public static var recommended: [ModelDescriptor] {
        all.filter(\.isRecommended)
    }

    /// То, что приложение умеет скачать само (без входа на Hugging Face и с проверкой суммы).
    public static var downloadable: [ModelDescriptor] {
        all.filter { canDownload($0) }
    }

    // MARK: Поиск

    public static func model(withID id: String) -> ModelDescriptor? {
        all.first { $0.id == id }
    }

    /// Точное совпадение по контрольной сумме — самый надёжный способ узнать файл.
    public static func model(withSHA256 hex: String) -> ModelDescriptor? {
        let needle = hex.lowercased()
        guard needle.count == 64 else { return nil }
        return all.first { $0.sha256.lowercased() == needle }
    }

    /// Совпадение по имени файла (без учёта регистра).
    ///
    /// ⚠️ Модели-папки (формат Apple) здесь НЕ участвуют, и это не мелочь. Узнавание
    /// по имени и размеру заведено для ОДНОГО файла: у папки «размер» — это сумма
    /// восьми файлов, а «имя» — имя папки. Пусти их сюда — и посторонний файл, случайно
    /// совпавший размером с суммой по папке, объявился бы моделью Apple.
    public static func model(withFileName name: String) -> ModelDescriptor? {
        let needle = name.lowercased()
        return all.first { !$0.isFolderModel && $0.fileName.lowercased() == needle }
    }

    /// Узнать модель-папку (формат Apple) по имени папки и её суммарному весу.
    ///
    /// ⚠️ ЗАЧЕМ. Папку, которую приложение само же и скачало из этого справочника,
    /// обход папок находит заново — и, не узнав, честно подписывает «эту модель
    /// приложение не знает, за неё никто не ручается». Про свою собственную советуемую
    /// модель это неправда, и человек справедливо перестал бы верить таким подписям.
    ///
    /// ⚠️ Условия те же, что и для файла: имя И точный вес. Совпало только имя —
    /// значит, внутри папки что-то другое, и узнавать её нельзя.
    public static func folderModel(forFolderName name: String, totalBytes: Int64) -> ModelDescriptor? {
        let needle = name.lowercased()
        return all.first {
            $0.isFolderModel && $0.fileName.lowercased() == needle && $0.byteSize == totalBytes
        }
    }

    /// Все известные файлы такого размера. Их может быть несколько:
    /// сборки «-gpu» и «-web» весят РОВНО одинаково.
    public static func models(withByteSize bytes: Int64) -> [ModelDescriptor] {
        guard bytes > 0 else { return [] }
        return all.filter { !$0.isFolderModel && $0.byteSize == bytes }
    }

    /// Узнать модель по имени и размеру — без чтения содержимого и без sha256.
    /// nil означает «не узнали», а НЕ «файл плохой».
    public static func recognize(fileName: String, byteSize: Int64) -> ModelDescriptor? {
        // 1. Имя и размер совпали — это она.
        if let byName = model(withFileName: fileName), byName.byteSize == byteSize {
            return byName
        }
        // 2. Имени не знаем, но размер однозначно указывает на одну модель.
        //    Если размер делят несколько файлов (gpu и web) — молчим, врать нельзя.
        let sameSize = models(withByteSize: byteSize)
        if sameSize.count == 1 {
            return sameSize[0]
        }
        return nil
    }

    // MARK: Что модель умеет кроме текста

    /// Модели, у которых внутри, кроме текста, лежат картинки и звук.
    ///
    /// ⚠️ ЗАЧЕМ СПИСОК, ЕСЛИ ЕСТЬ РАЗБОР ФАЙЛА. Разбор читает начало файла и ищет пометки
    /// картинок и звука — это главный источник. Но пометки могли назвать иначе в новом
    /// поколении формата, и тогда мы приняли бы мультимодальную модель за текстовую
    /// и никогда не подняли бы ей нужных исполнителей. Список — вторая линия.
    ///
    /// ⚠️ ЧЕМ ПОДТВЕРЖДЁН. Для Gemma 4 E4B — находкой владельца: рядом с его файлом
    /// приложение Google оставило кэши vision_encoder, audio_adapter и
    /// static_audio_encoder. Gemma 3n E2B/E4B — по описанию самого Google (картинки, звук,
    /// текст). MedGemma «с картинками» — по имени файла и описанию репозитория.
    private static let multimodalIDs: Set<String> = [
        gemma4E4B.id, gemma4E4BGPU.id, gemma4E4BWeb.id,
        gemma3nE2B.id, gemma3nE2BWeb.id,
        gemma3nE4B.id, gemma3nE4BWeb.id,
        medGemmaVision.id
    ]

    /// Модели, которые на iPhone проверены как ТЕКСТОВЫЕ и работают без всяких исполнителей.
    ///
    /// ⚠️ Этот список главнее разбора файла, и вот почему. Gemma 4 E2B у владельца работает
    /// прекрасно ровно так, как приложение запускает её сегодня. Если разбор вдруг найдёт
    /// в её файле пометку картинок, мы поменяем ей способ запуска — и сломаем единственную
    /// модель, которая точно работает. Живой факт главнее догадки по заголовку.
    private static let provenTextOnlyIDs: Set<String> = [
        gemma4E2B.id, gemma4E2BGPU.id, gemma4E2BWeb.id,
        gemma3_1B.id, gemma3_1BLongName.id, gemma3_270m.id,
        functionGemmaMobile.id, functionGemmaGarden.id,
        medGemma.id
    ]

    // ⚠️ ЧУЖИХ ПЕРЕДЕЛОК НЕТ НИ В ОДНОМ ИЗ ДВУХ СПИСКОВ ВЫШЕ, И ЭТО РЕШЕНИЕ, А НЕ ЗАБЫВЧИВОСТЬ.
    // Обе E4B-переделки сделаны из модели, которая умеет не только текст, — значит, руки
    // тянутся вписать их в мультимодальные. Но мы этого не проверяли ни разу: файл пересобирали
    // чужие руки, и что осталось внутри — неизвестно. Оба списка меняют СПОСОБ ЗАПУСКА модели,
    // и ошибка тут ломает запуск молча. Поэтому решает разбор самого файла — он читает пометки
    // в его начале и не гадает по имени. Появится живая проверка на телефоне — впишем.

    /// Опознаватель без пометки «файл переименовали» — её добавляет `withFileName`.
    private static func baseID(_ model: ModelDescriptor) -> String {
        model.id.hasSuffix("-local") ? String(model.id.dropLast("-local".count)) : model.id
    }

    /// Знаем ли мы эту модель как «не только текст».
    public static func isKnownMultimodal(_ model: ModelDescriptor) -> Bool {
        multimodalIDs.contains(baseID(model))
    }

    /// То же по имени файла и размеру — когда описания ещё нет.
    public static func isKnownMultimodal(fileName: String, byteSize: Int64) -> Bool {
        if let recognized = recognize(fileName: fileName, byteSize: byteSize) {
            return isKnownMultimodal(recognized)
        }
        if let byName = model(withFileName: fileName) {
            return isKnownMultimodal(byName)
        }
        return false
    }

    /// Проверено живьём: эта модель — текстовая, и трогать её способ запуска не надо.
    public static func isProvenTextOnly(_ model: ModelDescriptor) -> Bool {
        provenTextOnlyIDs.contains(baseID(model))
    }

    /// То же по имени файла и размеру.
    public static func isProvenTextOnly(fileName: String, byteSize: Int64) -> Bool {
        if let recognized = recognize(fileName: fileName, byteSize: byteSize) {
            return isProvenTextOnly(recognized)
        }
        if let byName = model(withFileName: fileName) {
            return isProvenTextOnly(byName)
        }
        return false
    }

    /// Есть ли у описания всё нужное, чтобы приложение скачало файл САМО:
    /// закреплённая версия репозитория, контрольная сумма и пригодность для телефона.
    public static func canDownload(_ model: ModelDescriptor) -> Bool {
        // У папки-модели эталон другой: не одна контрольная сумма на весь файл, а список
        // файлов с точными размерами. По нему и качаем, и проверяем, что скачалось всё.
        if model.isFolderModel {
            return model.byteSize > 0
                && model.repoCommit != unpinned
                && !model.repoID.isEmpty
                && model.isForPhone
        }
        return !model.sha256.isEmpty
            && model.byteSize > 0
            && model.repoCommit != unpinned
            && !model.repoID.isEmpty
            && model.isForPhone
            && model.hardware.isUsableOnIPhone
            && model.origin == .catalog
    }

    // MARK: Разбор имени файла

    /// Расширение, с которым работает приложение.
    public static let fileExtension = "litertlm"

    /// Расширение файлов отдельного движка (llama.cpp). Их приложение тоже принимает:
    /// разбирает начало файла (`ModelVerifier`) и запускает своим GGUF-движком.
    public static let ggufFileExtension = "gguf"

    /// Сборка для браузера? Отличить её от обычной можно ТОЛЬКО по имени:
    /// файлы «-web» и «-gpu» весят побайтово одинаково, и заголовок у них почти не отличается.
    /// Именно так поступает и сам Google в своём приложении.
    /// ⚠️ Без учёта регистра: у Gemma 3n файл называется «...-int4-Web.litertlm».
    public static func isBrowserBuild(fileName: String) -> Bool {
        fileName.lowercased().contains("-web")
    }

    /// Приметы сборок под чужие ускорители в имени файла.
    private static let foreignChipMarkers = [
        "qualcomm", "mediatek", "intel_", "_intel", "tensor_g", "_g5.",
        "sm8550", "sm8650", "sm8750", "sm8850",
        "mt6989", "mt6991", "mt6993", "qcs8275", "_lnl", "_ptl"
    ]

    /// Что можно сказать о железе по одному имени файла.
    /// Заголовок самого файла главнее — если он говорит «только видеочип», верить надо ему.
    public static func hardware(forFileName fileName: String) -> ModelHardware {
        let lower = fileName.lowercased()
        if isBrowserBuild(fileName: fileName) { return .browserOnly }
        if foreignChipMarkers.contains(where: { lower.contains($0) }) { return .foreignChip }
        if lower.contains("-gpu") { return .gpuOnly }
        return .universal
    }

    /// Имя для человека из имени файла.
    /// ⚠️ Другого источника нет: внутри файла человеческого имени модели не хранится вовсе —
    /// ни в заголовке, ни в описании модели.
    public static func humanName(forFileName fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        if name.isEmpty { return fileName }
        if let first = name.first, first.isLowercase {
            name = String(first).uppercased() + name.dropFirst()
        }
        return name
    }
}
