//
//  FileDropbox.swift
//  PocketAgent
//
//  Обмен файлами между человеком и папкой проекта — в обе стороны.
//
//  ⚠️ ГЛАВНОЕ ПРО ЭТОТ ФАЙЛ. Агент живёт ТОЛЬКО внутри выбранной папки и наружу
//  не ходит. Значит «дать файл агенту» физически означает одно: положить копию
//  файла В ПАПКУ ЧЕЛОВЕКА. Это изменение его папки — такое же, как запись файла
//  моделью, — и оно требует такого же явного согласия понятными словами.
//  Поэтому здесь ДВА шага, и они разделены намеренно:
//
//      plan(...)  — только смотрит: что за файл, поместится ли, есть ли такой уже,
//                   сможет ли агент его прочитать. НИЧЕГО не копирует.
//      copy(...)  — копирует. Зовётся ТОЛЬКО после нажатия человека.
//
//  Между ними стоит окно с текстом, который собирает сам план (`consentText`):
//  один текст, одно место, врать в двух местах по-разному невозможно.
//
//  ⚠️ Защита папки не ослаблена ни на йоту: имя файла проходит через тот же
//  SafePath.resolveForWriting, что и запись модели. Значит «..» в имени, ведущий
//  слэш, служебная папка и файл-секрет отсекаются здесь тем же кодом, а не похожим.
//

import Foundation

// MARK: - Что агент сможет с этим файлом

/// Насколько приложенный файл будет доступен агенту. Нужно затем, чтобы человек
/// узнал правду ДО копирования, а не после — «положил картинку, а агент её не видит».
public enum AttachmentReach: Sendable, Equatable {
    /// Обычный текст: агент увидит файл в списке и прочитает целиком за один раз.
    case readable
    /// Текста больше, чем помещается в один ответ: агент прочитает его по частям.
    ///
    /// ⚠️ ЭТО ОТДЕЛЬНЫЙ СЛУЧАЙ, А НЕ «слишком большой». Раньше их было два — «прочитает»
    /// и «не прочитает», — и граница между ними стояла на 512 КБ, то есть на пределе
    /// работы с диском. Человеку это врало в обе стороны: файл на 40 КБ обещали
    /// прочитать «за раз», хотя агент видит его кусками, а про то, что кусок зависит
    /// от выбранной памяти разговора, не говорили вовсе.
    case readableInParts(bytes: Int)
    /// Слишком большой: в списке будет, открыть агент его не сможет.
    case tooLarge(bytes: Int)
    /// Не текст (двоичное содержимое): в списке будет, прочитать не выйдет.
    case notText
    /// Картинка, архив, музыка и прочее двоичное по расширению: агент такие файлы
    /// пропускает при обходе папки, то есть даже имени не увидит.
    case invisible
}

// MARK: - Что именно человек подтверждает

/// Куда ляжет файл. Разделено на три случая, потому что человек подтверждает
/// РАЗНЫЕ вещи: появление нового файла и замена существующего — не одно и то же.
public enum AttachmentPlacement: Sendable, Equatable {
    /// Имя свободно — просто появится новый файл.
    case newFile
    /// Такое имя занято, кладём рядом под свободным именем.
    case keepBoth
    /// Такое имя занято, человек согласился затереть существующий файл.
    case replace
}

/// Всё, что известно про файл ДО копирования, плюс готовый текст согласия.
public struct AttachmentPlan: Sendable, Equatable, Identifiable {

    public var id: String { sourceURL.absoluteString + "|" + fileName }

    /// Откуда берём (файл живёт вне песочницы — из «Файлов» или другого приложения).
    public let sourceURL: URL
    /// Корень папки проекта, куда кладём.
    public let rootURL: URL
    /// Имя файла как есть.
    public let fileName: String
    /// Имя папки проекта — им же подписан заголовок рабочего экрана.
    public let folderName: String
    public let byteSize: Int
    /// «12,4 КБ» — человеческим языком.
    public let sizeText: String
    /// В папке уже лежит файл с таким именем.
    public let hasNameConflict: Bool
    /// Свободное имя рядом: «отчёт 2.txt». Совпадает с `fileName`, когда конфликта нет.
    public let sideBySideName: String
    public let reach: AttachmentReach
    /// Файл пришёл из другого приложения через «Поделиться» и лежит во временной
    /// папке нашего приложения — после копирования его надо убрать за собой.
    public let isTemporarySource: Bool

    public init(sourceURL: URL,
                rootURL: URL,
                fileName: String,
                folderName: String,
                byteSize: Int,
                sizeText: String,
                hasNameConflict: Bool,
                sideBySideName: String,
                reach: AttachmentReach,
                isTemporarySource: Bool) {
        self.sourceURL = sourceURL
        self.rootURL = rootURL
        self.fileName = fileName
        self.folderName = folderName
        self.byteSize = byteSize
        self.sizeText = sizeText
        self.hasNameConflict = hasNameConflict
        self.sideBySideName = sideBySideName
        self.reach = reach
        self.isTemporarySource = isTemporarySource
    }

    /// Под каким именем файл ляжет при выбранном способе.
    public func resultName(for placement: AttachmentPlacement) -> String {
        switch placement {
        case .newFile, .replace: return fileName
        case .keepBoth:          return sideBySideName
        }
    }

    // MARK: Текст согласия — ЕДИНСТВЕННОЕ место, где он собирается

    /// Заголовок окна.
    public var consentTitle: String {
        hasNameConflict ? "В папке уже есть такой файл" : "Скопировать файл в вашу папку?"
    }

    /// Полный текст согласия. Человек обязан прочитать здесь три вещи:
    /// что появится файл, что это меняет ЕГО папку, и что агент с этим файлом сможет.
    public var consentText: String {
        var parts: [String] = []

        if hasNameConflict {
            parts.append("В папке «\(folderName)» уже лежит «\(fileName)».")
            parts.append("Можно положить копию рядом — она будет называться «\(sideBySideName)». "
                         + "Или заменить существующий файл: тогда его прежнее содержимое пропадёт "
                         + "и вернуть его будет нечем.")
        } else {
            parts.append("Файл «\(fileName)» (\(sizeText)) появится в вашей папке «\(folderName)». "
                         + "Иначе агент его не увидит: он работает только внутри этой папки "
                         + "и наружу не выходит.")
        }

        parts.append("Оригинал останется там, где лежал, — мы делаем копию.")
        parts.append(reachText)
        return parts.joined(separator: "\n\n")
    }

    /// Что агент сможет с этим файлом — честно и без слов из кода.
    public var reachText: String {
        switch reach {
        case .readable:
            return "Агент увидит файл и сможет его прочитать."
        case .readableInParts(let bytes):
            // ⚠️ Число берём из ТЕКУЩЕЙ настройки памяти разговора, а не из константы:
            // человек мог поставить 32 000, и тогда за раз читается впятеро больше.
            return "Файл на \(HumanFormat.bytes(bytes)) — за один раз агент берёт "
                + "около \(HumanFormat.bytes(FileDropbox.wholeReadLimitBytes)), "
                + "поэтому читать будет частями. Чтобы брал больше за раз, "
                + "увеличьте память разговора в «О программе»."
        case .tooLarge(let bytes):
            return "Файл большой — \(HumanFormat.bytes(bytes)). Агент открывает файлы "
                + "до \(HumanFormat.bytes(FileDropbox.readableLimitBytes)): в списке он его увидит, "
                + "а прочитать не сможет."
        case .notText:
            return "Это не текстовый файл. Агент увидит его в списке, но прочитать не сможет — "
                + "он работает только с текстом."
        case .invisible:
            return "Картинки, архивы и прочие нетекстовые файлы агент пропускает — "
                + "он не увидит даже имени. В вашей папке файл всё равно появится."
        }
    }

    /// Короткая строка после успешного копирования.
    public func doneText(name: String) -> String {
        switch reach {
        case .readable:
            return "«\(name)» лежит в вашей папке — можно давать задачу."
        case .readableInParts:
            return "«\(name)» лежит в вашей папке — можно давать задачу. "
                + "Файл крупный, читать его агент будет частями."
        case .tooLarge, .notText, .invisible:
            return "«\(name)» лежит в вашей папке. Прочитать его агент не сможет."
        }
    }
}

// MARK: - Отказы

/// Отказы приёма файла. Все тексты написаны по-русски и предназначены человеку,
/// поэтому тип помечен `HumanReadableError` — разбор ошибок пропускает их как есть.
public enum AttachmentError: HumanReadableError, Equatable {
    /// Выбрана папка, а не файл.
    case notAFile(String)
    /// Имя файла такое, что внутри папки его не разместить (управляющие знаки, пусто).
    case badName(String)
    /// Имя из тех, что агент не читает никогда: ключи, пароли, служебное.
    case protectedName(String)
    /// Файл слишком велик, чтобы переносить его копированием.
    case tooBigToCopy(bytes: Int)
    /// На телефоне не хватает места под копию.
    case notEnoughSpace(needBytes: Int, freeBytes: Int64)
    /// Имя занято, а согласия на замену не было. Защита от гонки: пока человек читал
    /// окно, файл с таким именем мог появиться.
    case nameTaken(String)
    /// Человек выбрал файл, который и так лежит в папке проекта.
    case alreadyInFolder(String)
    /// Файл числится в iCloud, но на телефон ещё не скачан.
    case stillInCloud(String)
    /// Копирование не удалось.
    case copyFailed(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notAFile(let name):
            return "«\(name)» — это папку целиком перенести нельзя. Выберите один файл."
        case .badName(let name):
            return "Файл с таким именем перенести не получится: «\(name)». "
                + "Переименуйте его в «Файлах» и попробуйте снова."
        case .protectedName(let name):
            return "«\(name)» похоже на файл с паролем или ключом. Такие файлы агент "
                + "не читает никогда — переносить его в папку незачем."
        case .tooBigToCopy(let bytes):
            return "Файл весит \(HumanFormat.bytes(bytes)) — это больше, чем приложение "
                + "переносит само (\(HumanFormat.bytes(FileDropbox.maxCopyBytes))). "
                + "Скопируйте его в папку проекта через «Файлы» — агент увидит его там же."
        case .notEnoughSpace(let need, let free):
            return "На телефоне не хватает места: нужно \(HumanFormat.bytes(need)), "
                + "свободно \(HumanFormat.bytes(free)). Освободите место и повторите."
        case .nameTaken(let name):
            return "В папке уже есть «\(name)». Ничего не записано — повторите и выберите, "
                + "положить рядом или заменить."
        case .alreadyInFolder(let name):
            return "«\(name)» и так лежит в вашей папке проекта — агент его уже видит. "
                + "Копировать нечего."
        case .stillInCloud(let name):
            return "«\(name)» хранится в iCloud и на телефон ещё не скачан. "
                + "Я попросил систему его скачать: откройте «Файлы», дождитесь, пока рядом "
                + "с файлом пропадёт значок облака, и повторите."
        case .copyFailed(let name, let reason):
            return "Не удалось скопировать «\(name)»: \(reason)"
        }
    }
}

// MARK: - Сам обмен

public enum FileDropbox {

    /// Больше этого приложение файл само не переносит.
    ///
    /// ⚠️ Это НЕ выдуманное ограничение «для порядка»: копирование идёт без полосы
    /// прогресса и без возможности отмены, и на гигабайтном файле человек получил бы
    /// замерший экран без объяснений. У отказа есть работающая замена, и она названа
    /// прямо в тексте: положить файл в папку через «Файлы» руками.
    public static let maxCopyBytes = 200 * 1_000_000

    /// Файлы больше этого агент не открывает ВООБЩЕ — тот же предел, что и у чтения
    /// с диска. Держим ссылкой на общее число, чтобы два предела не разъехались.
    ///
    /// ⚠️ Это предел РАБОТЫ С ДИСКОМ, и от памяти разговора он не зависит: столько
    /// приложение готово прочитать в телефон ради диффа и сверки перед записью.
    public static var readableLimitBytes: Int { AgentLimits.maxFileBytes }

    /// Сколько байт файла попадает в ОДИН ответ модели — то есть какой файл она
    /// увидит целиком, а какой придётся читать частями.
    ///
    /// ⚠️ ЭТО ЧИСЛО СЧИТАЕТСЯ ОТ ПАМЯТИ РАЗГОВОРА, а не от старой константы в 4 096
    /// токенов. Человек сам ставит от 4 096 до 32 000 на странице «О программе»,
    /// и на 32 000 за один раз читается впятеро больше. Скажи мы ему прежнее число —
    /// оно было бы враньём ровно в том месте, ради которого он настройку и двигал.
    ///
    /// ⚠️ Но берётся ВЫДАННОЕ движком окно, а не выбранное человеком (`FilePaging`
    /// считает страницу от `ContextSizeSettings.effectiveTokens`). Эти числа расходятся:
    /// движок может подняться на 4 096 при выбранных 32 000. Обещание «этот файл
    /// прочитается целиком» в окне согласия обязано опираться на то, что есть на деле.
    public static var wholeReadLimitBytes: Int { FilePaging.pageBytes }

    /// Сколько байт держим свободными сверх размера копии.
    private static let spareBytes: Int64 = 10 * 1_000_000

    /// Сколько первых байт нюхаем, чтобы отличить текст от двоичного.
    private static let sniffBytes = 4096

    // MARK: Шаг 1 — посмотреть, ничего не трогая

    /// Разобрать выбранный человеком файл. Ничего не копирует и не меняет.
    ///
    /// - Parameters:
    ///   - source: файл из «Файлов» или из другого приложения — ЛЕЖИТ ВНЕ ПЕСОЧНИЦЫ.
    ///   - root: корень выбранной папки проекта.
    ///   - folderName: имя папки для показа человеку.
    ///   - isTemporarySource: файл пришёл через «Поделиться» и лежит в нашей временной
    ///     папке — после копирования его надо убрать.
    /// - Throws: `AttachmentError`, если файл принимать нельзя вовсе;
    ///   ошибки `SafePath`, если имя файла выводит за пределы папки.
    public static func plan(source: URL,
                            root: URL,
                            folderName: String,
                            isTemporarySource: Bool = false) throws -> AttachmentPlan {

        // ⚠️ БЕЗ ЭТОГО ЗАПРОСА ФАЙЛА ПРОСТО НЕТ. Система пускает к выбранному в «Файлах»
        // файлу только по явному запросу доступа — ровно на этом однажды сломалась
        // установка модели: заглядывание отвечало «файл не найден» на любой годный файл.
        // Файлу внутри нашего контейнера запрос не нужен и не вредит: там вернётся false.
        let didStart = source.startAccessingSecurityScopedResource()
        defer { if didStart { source.stopAccessingSecurityScopedResource() } }

        let name = source.lastPathComponent

        // Имя обязано быть ОДНИМ безопасным компонентом: ни «..», ни ведущего слэша,
        // ни управляющих знаков. Разбирает это тот же код, что и пути от модели.
        let components = try SafePath.sanitizeComponents(name)
        guard components.count == 1, let cleanName = components.first, cleanName == name else {
            throw AttachmentError.badName(name)
        }
        if SafePath.isProtectedFileName(name)
            || SafePath.protectedDirectoryNames.contains(name.lowercased()) {
            throw AttachmentError.protectedName(name)
        }

        // Файл уже внутри папки проекта — копировать его в неё же бессмысленно, а вопрос
        // «положить рядом или заменить?» на нём выглядел бы как поломка приложения.
        if SafePath.isInside(SafePath.canonical(source), root: root) {
            throw AttachmentError.alreadyInFolder(name)
        }

        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else {
            throw AttachmentError.notAFile(name)
        }

        // Файл лежит в iCloud и на телефоне его ещё нет. Копировать нечего — но и молчать
        // нельзя: система не скачивает такие файлы сама, пока её об этом не попросят.
        // Просим и говорим человеку, чего ждать. Иначе он получил бы невнятную ошибку
        // копирования на совершенно нормальном файле.
        //
        // ⚠️ СПРАШИВАЕМ ТЕМ ЖЕ КОДОМ, ЧТО И ФАЙЛ МОДЕЛИ (`ModelStorage.cloudState`).
        // Раньше здесь стояла своя проверка «состояние обязано быть ровно `.current`»,
        // и она отвергала годные файлы: состояние `.downloaded` значит, что байты на
        // телефоне ЕСТЬ, а отстать может только версия. Человек получал «файл ещё
        // не скачан» на файле, который лежал у него на диске целиком.
        if ModelStorage.cloudState(of: source) == .placeholder {
            ModelStorage.requestCloudDownload(source)
            throw AttachmentError.stillInCloud(name)
        }

        // ⚠️ Размер спрашиваем с запасным путём. У некоторых файл-провайдеров
        // `fileSizeKey` не приезжает, и прежнее `?? 0` показывало человеку «0 Б»
        // в самом окне согласия, а заодно молча выключало проверку свободного места.
        let size = values?.fileSize ?? byteSizeFromAttributes(of: source)
        guard size <= maxCopyBytes else {
            throw AttachmentError.tooBigToCopy(bytes: size)
        }

        let free = availableBytes(near: root)
        if free > 0, free < Int64(size) + spareBytes {
            throw AttachmentError.notEnoughSpace(needBytes: size, freeBytes: free)
        }

        // Та же дверь, что у записи модели: сюда не пройдут ни выход за папку,
        // ни служебная папка, ни имя, поверх которого лежит каталог.
        let target = try SafePath.resolveForWriting(name, root: root)
        let exists = FileManager.default.fileExists(atPath: target.path)

        return AttachmentPlan(sourceURL: source,
                              rootURL: root,
                              fileName: name,
                              folderName: folderName,
                              byteSize: size,
                              sizeText: HumanFormat.bytes(size),
                              hasNameConflict: exists,
                              sideBySideName: exists ? freeName(near: name, root: root) : name,
                              reach: reach(of: source, byteSize: size),
                              isTemporarySource: isTemporarySource)
    }

    // MARK: Шаг 2 — скопировать (только после нажатия человека)

    /// Положить файл в папку проекта. Зовётся ТОЛЬКО из подтверждённого действия.
    /// - Returns: имя, под которым файл лёг в папку.
    @discardableResult
    public static func copy(plan: AttachmentPlan,
                            placement: AttachmentPlacement) throws -> String {

        let name = plan.resultName(for: placement)
        let target = try SafePath.resolveForWriting(name, root: plan.rootURL)

        let alreadyThere = FileManager.default.fileExists(atPath: target.path)
        // Пока человек читал окно, файл с таким именем мог появиться. Молча затирать
        // его нельзя: согласия именно на замену не было.
        if alreadyThere && placement != .replace {
            throw AttachmentError.nameTaken(name)
        }

        let didStart = plan.sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { plan.sourceURL.stopAccessingSecurityScopedResource() } }

        // Прибираем чужой мусор ПЕРЕД своей работой: приложение могло быть закрыто
        // системой ровно посреди прошлого копирования, и тогда в папке человека остался
        // недописанный кусок весом до 200 МБ. Делаем это здесь, а не при заглядывании:
        // тут человек уже нажал кнопку, а без нажатия мы в его папке ничего не трогаем.
        sweepAbandonedCopies(in: plan.rootURL)

        var coordinationError: NSError?
        var workError: Error?

        // Координируем ОБА конца: исходный файл может дописывать iCloud, а папку
        // проекта — другое приложение (Working Copy, редактор).
        let coordinator = NSFileCoordinator(filePresenter: nil)
        // options у чтения пустые — те же, что при обычном чтении файла проекта:
        // нам нужно последнее содержимое, а не то, что было до чужого сохранения.
        coordinator.coordinate(readingItemAt: plan.sourceURL,
                               options: [],
                               writingItemAt: target,
                               options: .forReplacing,
                               error: &coordinationError) { readURL, writeURL in
            // Временное имя рядом с целью: копия сначала ложится целиком и только
            // потом занимает своё место. Оборвись копирование — на месте настоящего
            // файла не окажется обрубка.
            let temporary = writeURL
                .deletingLastPathComponent()
                .appendingPathComponent(Self.temporaryCopyPrefix + UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: readURL, to: temporary)
                if FileManager.default.fileExists(atPath: writeURL.path) {
                    _ = try FileManager.default.replaceItemAt(writeURL, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: writeURL)
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                workError = error
            }
        }

        if let coordinationError {
            throw AttachmentError.copyFailed(name: name,
                                             reason: SystemErrorText.russian(for: coordinationError))
        }
        if let workError {
            throw AttachmentError.copyFailed(name: name,
                                             reason: SystemErrorText.russian(for: workError))
        }

        // Файл пришёл через «Поделиться» и лежал в нашей временной папке — убираем за собой.
        // Не получилось — не беда: система чистит эту папку сама.
        if plan.isTemporarySource {
            try? FileManager.default.removeItem(at: plan.sourceURL)
        }

        return name
    }

    // MARK: Обратная сторона — отдать файл человеку

    /// URL файла внутри папки проекта — для системного окна «Поделиться».
    /// nil, если файла нет, он не обычный файл или путь ведёт к служебному.
    ///
    /// ⚠️ Проверки те же самые (`SafePath.resolveForReading`): секретов и служебных папок
    /// приложение не отдаёт наружу так же, как не даёт их читать модели.
    public static func shareableFileURL(relativePath: String, root: URL) -> URL? {
        guard let url = try? SafePath.resolveForReading(relativePath, root: root) else { return nil }
        guard CoordinatedFileIO.isRegularFile(url) else { return nil }
        return url
    }

    // MARK: Папка «Входящие» — где система оставляет присланные нам копии

    /// Папка, в которую iOS кладёт копию файла, присланного из другого приложения.
    /// Имя `Inbox` выбрано не нами — так называет её сама система.
    public static var appInboxURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Файл лежит в нашей папке «Входящие» — значит он наш и убрать его можно.
    ///
    /// ⚠️ Проверяем ФАКТОМ, а не доверяем ответу системы «это копия»: удалять файл
    /// по одному лишь признаку из чужих рук нельзя. Не подтвердилось — не трогаем.
    public static func isInsideAppInbox(_ url: URL) -> Bool {
        guard let inbox = appInboxURL else { return false }
        return SafePath.isInside(SafePath.canonical(url), root: inbox)
    }

    /// Что сейчас лежит во «Входящих». Пусто — и папки может не быть, это нормально.
    public static func appInboxContents() -> [URL] {
        guard let inbox = appInboxURL else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: inbox,
                                                             includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: Внутреннее

    /// Начало имени недописанной копии. Такой файл живёт секунды и лежит рядом с целью
    /// (переехать на своё место он обязан ОДНИМ движением, а это возможно только внутри
    /// того же тома). Прячем его и от модели, и от человека — см. `DirectoryLister`.
    static let temporaryCopyPrefix = ".pocketagent-copy-"

    /// Сколько недописанная копия может пролежать, прежде чем считать её брошенной.
    /// Час — с огромным запасом: живое копирование длится секунды.
    private static let abandonedCopyAge: TimeInterval = 3600

    /// Имя выглядит как наша недописанная копия.
    static func isTemporaryCopyName(_ name: String) -> Bool {
        name.hasPrefix(temporaryCopyPrefix)
    }

    /// Убрать брошенные куски прошлых копирований из корня папки проекта.
    ///
    /// ⚠️ Трогаем ТОЛЬКО свои файлы: имя обязано начинаться нашей приставкой, и лежать
    /// он должен больше часа. Ошибиться здесь — значит удалить чужой файл, поэтому
    /// оба условия обязательные, а не «или».
    private static func sweepAbandonedCopies(in root: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return
        }
        let now = Date()
        for name in names where isTemporaryCopyName(name) {
            let url = root.appendingPathComponent(name)
            let created = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let created, now.timeIntervalSince(created) > abandonedCopyAge else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Размер файла запасным путём — когда файл-провайдер не отдал `fileSizeKey`.
    static func byteSizeFromAttributes(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Свободное имя рядом с занятым: «отчёт.txt» → «отчёт 2.txt».
    /// Так же, как это делает сама система при копировании файла в ту же папку.
    static func freeName(near name: String, root: URL) -> String {
        let text = name as NSString
        let ext = text.pathExtension
        let base = text.deletingPathExtension

        for index in 2...99 {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            guard let url = try? SafePath.resolveForWriting(candidate, root: root) else { continue }
            if !FileManager.default.fileExists(atPath: url.path) {
                return candidate
            }
        }
        // Сто одинаковых имён подряд — случай невероятный, но тупика тут быть не должно.
        let tail = UUID().uuidString.prefix(6)
        return ext.isEmpty ? "\(base) \(tail)" : "\(base) \(tail).\(ext)"
    }

    /// Что агент сможет с файлом такого вида и размера.
    static func reach(of url: URL, byteSize: Int) -> AttachmentReach {
        let ext = url.pathExtension.lowercased()
        // Порядок важен: картинку агент не увидит вовсе, и это главное, что надо сказать,
        // — размер и «не текст» тут уже вторичны.
        if DirectoryLister.binaryExtensions.contains(ext) { return .invisible }
        if byteSize > readableLimitBytes { return .tooLarge(bytes: byteSize) }
        guard looksLikeText(url) else { return .notText }
        // Влезает в один ответ — или придётся читать частями. Граница едет вместе
        // с настройкой памяти разговора, поэтому считается, а не зашита числом.
        return byteSize > wholeReadLimitBytes
            ? .readableInParts(bytes: byteSize)
            : .readable
    }

    /// Нюхаем начало файла: нулевой байт или не-UTF-8 — значит не текст.
    /// Прочитать не смогли — не выдумываем диагноз и считаем файл текстом:
    /// если он и правда нечитаем, копирование скажет об этом честной ошибкой.
    static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: sniffBytes), !head.isEmpty else { return true }
        if head.contains(0) { return false }
        // Хвост может обрезать многобайтовый знак — тогда проверяем без последних байт.
        if String(data: head, encoding: .utf8) != nil { return true }
        if head.count > 4, String(data: head.dropLast(4), encoding: .utf8) != nil { return true }
        return false
    }

    /// Сколько свободно на томе, где лежит папка проекта. 0 — узнать не удалось,
    /// и тогда про место мы молчим, а не пугаем выдуманной цифрой.
    static func availableBytes(near url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
