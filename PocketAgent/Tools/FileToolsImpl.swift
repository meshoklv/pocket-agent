//
//  FileToolsImpl.swift
//  PocketAgent
//
//  Вся реальная работа с файлами внутри выбранной папки:
//    • CoordinatedFileIO      — координированное чтение и атомарная запись (iCloud, Working Copy);
//    • DirectoryLister        — обход папки с лимитами глубины и количества;
//    • SecurityScopedWorkspace— реализация FileWorkspace поверх корня проекта;
//    • четыре инструмента     — list_files / read_file / write_file / finish.
//
//  ⚠️ ЯДРО ПРОДУКТА: write_file НИЧЕГО не пишет в preview(). Он только строит дифф.
//  Запись происходит в execute(), который вызывается ТОЛЬКО после «Применить» от человека.
//  Больше того: execute() отказывается писать, если по этому же вызову не был построен
//  предпросмотр — то есть файл физически не может быть записан втихую.
//

import Foundation

// MARK: - Координированный ввод-вывод

/// Ящик под результат чтения: пишет его один поток, читает другой.
///
/// ⚠️ Нужен ровно потому, что у чтения теперь есть предел по времени. Мы можем уйти
/// по этому пределу, пока блок координатора ещё работает, — и тогда две стороны
/// трогают одну память одновременно. Замок это разводит.
private final class ReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<Data, Error>?
    private var storedCoordinationError: NSError?

    func put(_ value: Result<Data, Error>) {
        lock.lock(); defer { lock.unlock() }
        storedResult = value
    }

    func putCoordinationError(_ value: NSError) {
        lock.lock(); defer { lock.unlock() }
        storedCoordinationError = value
    }

    var result: Result<Data, Error>? {
        lock.lock(); defer { lock.unlock() }
        return storedResult
    }

    var coordinationError: NSError? {
        lock.lock(); defer { lock.unlock() }
        return storedCoordinationError
    }
}

public enum CoordinatedFileIO {

    /// Дата последнего изменения файла (nil — файла нет).
    public static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Размер файла в байтах (nil — файла нет).
    public static func byteSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    public static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
    }

    public static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Сколько ждём файл, который система отдаёт не сразу.
    ///
    /// ⚠️ ЗАЧЕМ ПРЕДЕЛ ВООБЩЕ ПОЯВИЛСЯ (09.09.2026, по живым перепискам владельца).
    /// Раньше ожидание было БЕСКОНЕЧНЫМ. Папки владельца лежат в iCloud, и файл,
    /// который телефон ещё не скачал, координированное чтение ждёт молча и без конца.
    /// В ленте оставалась строка «Читаю файл README.md», после неё — тишина: 65, 91,
    /// 128 секунд, а один раз система убила приложение целиком через 121 секунду.
    /// Четыре разговора подряд владелец останавливал сам. Со стороны это и есть
    /// «модель ничего не может»: на деле она ждала файл, которого ей не дали.
    /// Лучше честно сказать через двадцать секунд, чем висеть вечно.
    public static let waitLimit: TimeInterval = 20

    /// Скачан ли файл из облака. `nil` — обычный файл на диске, ждать нечего.
    ///
    /// ⚠️ СБРАСЫВАЕМ КЭШ ПЕРЕД КАЖДЫМ ВОПРОСОМ. Система имеет право отдать значение,
    /// прочитанное раньше, — а мы спрашиваем один и тот же адрес в цикле, ожидая, что
    /// ответ изменится. С кэшем файл навсегда остался бы «не скачан», и даже скачанный
    /// упирался бы в предел ожидания. Один вызов на четверть секунды опроса — не цена.
    private static func cloudStatus(of url: URL) -> URLUbiquitousItemDownloadingStatus? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                         .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return nil }
        return values?.ubiquitousItemDownloadingStatus
    }

    /// Попросить систему скачать файл из облака и подождать его — но не дольше предела.
    ///
    /// ⚠️ Просто «подождать» мало: пока никто не попросил, iCloud файл и не начнёт качать.
    /// Поэтому сначала просим (`startDownloadingUbiquitousItem`), потом ждём.
    /// - Parameter deadline: общий срок на ВСЮ операцию чтения. Своего предела у этого
    ///   ожидания нет намеренно: два независимых предела складывались (20 + 20 = 40)
    ///   и вылезали за сторож действий в 30 секунд — человек ждал сорок секунд, чтобы
    ///   услышать «не ответило за полминуты». Срок один на всё.
    static func ensureDownloaded(at url: URL, displayPath: String, deadline: Date) throws {
        // ⚠️ ЖДЁМ ТОЛЬКО «СОВСЕМ НЕ СКАЧАН». У облачного файла три состояния, и второе
        // из них — «копия есть, но в облаке лежит посвежее». Такой файл читается
        // немедленно и ждать его нельзя: проверка «не самое свежее» задержала бы на
        // двадцать секунд каждый обычный файл в папке iCloud и закончилась бы отказом
        // на совершенно исправном файле.
        guard cloudStatus(of: url) == .notDownloaded else { return }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        while Date() < deadline {
            // Как только появилась локальная копия — читаем, «самая свежая» она или нет.
            if cloudStatus(of: url) != .notDownloaded { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // Не «ошибка чтения», а понятная человеку причина и понятный выход.
        throw PocketAgentError.fileNotDownloaded(displayPath)
    }

    /// Координированное чтение не более `limit` байт.
    /// Координация нужна потому, что файл может править другой процесс:
    /// синхронизация iCloud, git-операции Working Copy, материализация из облака.
    ///
    /// ⚠️ Читаем ЦИКЛОМ до конца файла и сверяем прочитанное с его размером.
    /// read(upToCount:) — один системный вызов, и у файл-провайдера (iCloud, Working Copy)
    /// короткое чтение законно: вернётся меньше байт, чем в файле. Молча отдать такой кусок
    /// нельзя — дифф построится против неполного «до», а модель потом «допишет» файл
    /// и снесёт невидимый хвост.
    public static func readData(at url: URL, limit: Int) throws -> Data {
        // ⚠️ ОДИН СРОК НА ВСЮ ОПЕРАЦИЮ — и выпрашивание файла у облака, и само чтение
        // укладываются в него вместе. Раздельные пределы складывались и выходили за
        // сторож действий, который стоит выше.
        let deadline = Date().addingTimeInterval(waitLimit)
        try ensureDownloaded(at: url, displayPath: url.lastPathComponent, deadline: deadline)

        // ⚠️ Результаты складываем в общий ящик под замком, а не в обычные переменные:
        // читает их наш поток, а пишет — тот, что внутри координатора. Если мы уйдём
        // по пределу времени, блок координатора может ещё дописывать своё, и без
        // замка это была бы гонка за память.
        let box = ReadBox()

        let coordinator = NSFileCoordinator(filePresenter: nil)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var innerError: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &innerError) { coordinatedURL in
                box.put(readCoordinated(coordinatedURL, limit: limit))
            }
            if let innerError { box.putCoordinationError(innerError) }
            finished.signal()
        }

        // Ждём ровно столько, сколько осталось от общего срока.
        let left = max(1, deadline.timeIntervalSinceNow)
        if finished.wait(timeout: .now() + left) == .timedOut {
            // Отменяем координацию, иначе она продолжит держать файл уже никому не нужной.
            coordinator.cancel()
            throw PocketAgentError.readFailed(
                path: url.lastPathComponent,
                reason: "файл не отдался за \(Int(waitLimit)) секунд — похоже, он ещё не скачан из облака"
            )
        }

        if let coordinationError = box.coordinationError {
            throw PocketAgentError.readFailed(path: url.lastPathComponent,
                                              reason: SystemErrorText.russian(for: coordinationError))
        }
        switch box.result {
        case .success(let data):
            return data
        case .failure(let error):
            throw PocketAgentError.readFailed(path: url.lastPathComponent,
                                              reason: SystemErrorText.russian(for: error))
        case .none:
            throw PocketAgentError.readFailed(path: url.lastPathComponent,
                                              reason: "чтение не выполнилось")
        }
    }

    /// Само чтение внутри блока координатора — вынесено, чтобы верхняя часть читалась.
    private static func readCoordinated(_ coordinatedURL: URL, limit: Int) -> Result<Data, Error> {
        do {
            // Работаем ТОЛЬКО с URL, пришедшим в блок, а не с исходным
            let handle = try FileHandle(forReadingFrom: coordinatedURL)
            defer { try? handle.close() }

            var data = Data()
            while data.count < limit {
                let chunk = try handle.read(upToCount: limit - data.count)
                guard let chunk, !chunk.isEmpty else { break }
                data.append(chunk)
            }

            // Сверка с фактическим размером: файл целиком должен быть прочитан.
            let actualSize = byteSize(of: coordinatedURL)
            if let actualSize, actualSize <= limit, data.count != actualSize {
                return .failure(PocketAgentError.readFailed(
                    path: coordinatedURL.lastPathComponent,
                    reason: "файл прочитан не целиком (\(data.count) из \(actualSize) байт)"
                ))
            }
            return .success(data)
        } catch {
            return .failure(error)
        }
    }

    /// Координированная АТОМАРНАЯ запись с созданием промежуточных папок.
    /// ⚠️ Внутри блока координатора НЕЛЬЗЯ звать другой координатор — дифф считаем ДО записи.
    public static func writeText(_ text: String, to url: URL, displayPath: String) throws {
        // ⚠️ ПОЧЕМУ ЗДЕСЬ ТОЛЬКО ВЫПРАШИВАНИЕ ФАЙЛА, А ПРЕДЕЛА НА САМУ ЗАПИСЬ НЕТ.
        // Зависнуть запись может по той же причине, что и чтение: файл из iCloud ещё
        // не на телефоне. Эту причину мы снимаем — просим систему его подтянуть и ждём
        // ограниченно. А вот обрывать саму запись по времени НЕЛЬЗЯ: человек её уже
        // подтвердил, повторить её нельзя, и сказать «не получилось» про правку,
        // которая всё-таки легла на диск, — хуже любого ожидания.
        // ⚠️ ОШИБКУ ЗДЕСЬ НЕ ГЛОТАЕМ, И ЭТО ВАЖНЕЕ, ЧЕМ КАЖЕТСЯ. Проглоти мы её —
        // и следом пошла бы неограниченная координированная запись по файлу, которого
        // на телефоне нет: «Применить» зависало бы НАВСЕГДА, ровно как раньше зависало
        // чтение. Честный отказ с понятной причиной лучше вечного ожидания.
        // Новый файл этой проверкой не задевается: у несуществующего файла облачного
        // состояния нет, и проверка возвращается сразу.
        try ensureDownloaded(at: url,
                             displayPath: displayPath,
                             deadline: Date().addingTimeInterval(waitLimit))

        var coordinationError: NSError?
        var writeError: Error?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try FileManager.default.createDirectory(
                    at: coordinatedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                // atomically: true — запись во временный файл рядом и замена.
                // Недописанного файла на диске не появится ни при каком сбое.
                try text.write(to: coordinatedURL, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }

        if let coordinationError {
            throw PocketAgentError.writeFailed(path: displayPath,
                                               reason: SystemErrorText.russian(for: coordinationError))
        }
        if let writeError {
            throw PocketAgentError.writeFailed(path: displayPath,
                                               reason: SystemErrorText.russian(for: writeError))
        }
    }
}

// MARK: - Обход папки

/// Счётчик пропущенных папок. Обычный класс, потому что его меняет замыкание обхода.
private final class SkipCounter {
    var value = 0
}

public enum DirectoryLister {

    /// Папки, внутрь которых не заходим никогда: мусор сборки, служебное и хранилища секретов.
    ///
    /// ⚠️ Раньше половину этого списка закрывал флаг `.skipsHiddenFiles`, и вместе с ними
    /// из выдачи пропадали ОБЫЧНЫЕ скрытые файлы проекта: .gitignore, .env.example,
    /// .github/, .swiftlint.yml. Модель их не видела, делала вывод «файла нет» и предлагала
    /// создать новый ПОВЕРХ существующего. Теперь скрытое показывается, а не пускаем —
    /// строго по этому списку.
    public static let skippedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "Pods", "Carthage",
        ".build", "build", "DerivedData", ".next", "dist", "vendor",
        "__pycache__", ".venv", "venv", ".gradle", ".idea", ".vscode",
        // Хранилища ключей и учёток: туда не заходим даже за именами файлов.
        ".ssh", ".aws", ".gnupg", ".kube", ".docker", ".terraform",
        // Кэши инструментов: сотни тысяч файлов, смысла ноль.
        ".swiftpm", ".yarn", ".pnpm-store", ".turbo", ".parcel-cache",
        ".mypy_cache", ".pytest_cache", ".ruff_cache", ".tox", ".expo"
    ]

    /// Служебный мусор файловой системы: показывать его человеку и модели незачем.
    public static let skippedFileNames: Set<String> = [
        ".ds_store", "thumbs.db", ".localized"
    ]

    /// Двоичные файлы модели показывать бессмысленно — она их всё равно не прочитает.
    public static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico", "icns",
        "pdf", "zip", "gz", "tar", "bz2", "7z", "rar", "dmg", "ipa", "apk",
        "mp3", "wav", "aac", "m4a", "ogg", "mp4", "mov", "avi", "mkv",
        "ttf", "otf", "woff", "woff2", "eot",
        "o", "a", "so", "dylib", "framework", "xcarchive", "bin", "dat",
        "sqlite", "db", "realm", "pyc", "class", "jar", "wasm", "litertlm", "task"
    ]

    /// Обход для list_files.
    /// - Parameters:
    ///   - root: корень проекта (пути в выдаче — относительно него).
    ///   - startURL: с какой папки начинаем (может быть подпапкой корня).
    ///   - maxDepth: глубина относительно startURL.
    ///   - limit: максимум записей В ВЫДАЧЕ (сверх него записи только пересчитываются).
    public static func list(root: URL,
                            startURL: URL,
                            maxDepth: Int = AgentLimits.maxListDepth,
                            limit: Int = AgentLimits.maxListEntries,
                            countCap: Int = AgentLimits.listCountCap) throws -> WorkspaceListing {

        guard CoordinatedFileIO.isDirectory(startURL) else {
            let relative = SafePath.relativePath(of: startURL, root: root)
            // ⚠️ РАЗЛИЧАЕМ ДВА РАЗНЫХ СЛУЧАЯ, И ЭТО НЕ ПРИДИРКА. Модель регулярно зовёт
            // список по имени ФАЙЛА («посмотри BIBLE.md»). Ответ «файл не найден» —
            // ложь: файл есть. Модель на неё верит и повторяет вызов, а на втором
            // повторе задача останавливается как «два неверных действия подряд».
            // Ровно так умерла живая задача владельца 09.09.2026 на BIBLE.md.
            if CoordinatedFileIO.isRegularFile(startURL) {
                throw PocketAgentError.pathIsFileNotFolder(relative)
            }
            throw PocketAgentError.fileNotFound(relative)
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .nameKey]
        let keySet = Set(keys)

        // ⚠️ Раньше ошибки обхода глушились наглухо (`{ _, _ in true }`): нечитаемая или
        // не догруженная из облака папка молча исчезала из выдачи, и ни модель, ни человек
        // об этом не узнавали. Теперь считаем пропуски и честно дописываем их в ответ.
        let skipped = SkipCounter()

        guard let enumerator = FileManager.default.enumerator(
            at: startURL,
            includingPropertiesForKeys: keys,   // предзагрузка: без неё syscall на каждый файл
            // .skipsHiddenFiles больше НЕ ставим: скрытые файлы проекта модель обязана видеть.
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                skipped.value += 1
                return true                     // нечитаемое пропускаем, обход продолжаем
            }
        ) else {
            throw PocketAgentError.fileNotFound(SafePath.relativePath(of: startURL, root: root))
        }

        // Считаем компоненты один раз: canonical() ходит на диск, а сравнивать надо на каждый файл
        let rootComponents = SafePath.canonical(root).pathComponents
        let startComponents = SafePath.canonical(startURL).pathComponents

        // ⚠️ Собираем ВСЮ папку (до countCap), а подрезаем только в самом конце, ПОСЛЕ
        // сортировки. Иначе в предел попадали бы случайные записи в порядке обхода
        // файловой системы: человек видел бы «первые 60» из середины алфавита, и найти
        // в них что-то было бы нельзя. Заодно так получается честное общее число:
        // модель обязана увидеть словами «показаны первые 60 из 214», иначе она считает
        // список полным и уверенно говорит человеку, что в проекте больше ничего нет.
        // Считаем не бесконечно: на папке в сотни тысяч файлов сам подсчёт стал бы
        // тормозом, и тогда честно говорим «более 5000».
        var collected: [WorkspaceEntry] = []
        var isCountApproximate = false

        for case let fileURL as URL in enumerator {
            if collected.count >= countCap {
                isCountApproximate = true
                break
            }

            let values = try? fileURL.resourceValues(forKeys: keySet)
            let name = values?.name ?? fileURL.lastPathComponent
            let lowerName = name.lowercased()

            if skippedFileNames.contains(lowerName) { continue }
            // Недописанная копия приложенного файла живёт секунды, но приложение могло
            // быть закрыто системой ровно в этот миг. Показывать такой обрубок нельзя:
            // модель приняла бы его за файл проекта и предложила бы человеку его читать.
            if FileDropbox.isTemporaryCopyName(name) { continue }

            // Символьную ссылку показываем С ПОМЕТКОЙ, но внутрь не заходим и читать не даём:
            // молчаливое сокрытие убеждало модель, что файла нет, и она предлагала его «создать».
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                let relative = SafePath.relativePath(of: fileURL, rootComponents: rootComponents)
                if !relative.isEmpty {
                    collected.append(WorkspaceEntry(relativePath: relative,
                                                    isDirectory: false,
                                                    byteSize: 0,
                                                    isSymbolicLink: true))
                }
                continue
            }

            let isDirectory = values?.isDirectory ?? false

            if isDirectory {
                if skippedDirectoryNames.contains(lowerName) || skippedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                // Глубину считаем ПО КОМПОНЕНТАМ ПУТИ, а не по enumerator.level:
                // у URL-варианта смещение level документировано нечётко и легко даёт ошибку на единицу.
                let depth = SafePath.relativeComponents(of: fileURL, rootComponents: startComponents).count
                if depth >= maxDepth {
                    enumerator.skipDescendants()
                }
            } else {
                let ext = fileURL.pathExtension.lowercased()
                if binaryExtensions.contains(ext) { continue }
            }

            let relative = SafePath.relativePath(of: fileURL, rootComponents: rootComponents)
            if relative.isEmpty { continue }

            collected.append(WorkspaceEntry(relativePath: relative,
                                           isDirectory: isDirectory,
                                           byteSize: isDirectory ? 0 : (values?.fileSize ?? 0)))
        }

        collected.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }

        let didHitLimit = collected.count > limit
        let entries = didHitLimit ? Array(collected.prefix(limit)) : collected

        return WorkspaceListing(entries: entries,
                                unreadableCount: skipped.value,
                                didHitLimit: didHitLimit,
                                totalCount: collected.count,
                                isCountApproximate: isCountApproximate)
    }

    /// Сколько в проекте файлов и папок ВСЕГО — по всему дереву, а не на один уровень.
    ///
    /// ⚠️ ЗАЧЕМ ЭТО ПОЯВИЛОСЬ (10.09.2026, вариант «В» из дорожной карты).
    /// На вопрос «сколько тут файлов» помощник обходил дерево папку за папкой —
    /// единственным доступным ему способом — и упирался в предел шагов: на настоящем
    /// репозитории владельца это 24+ обхода при пределе 24, то есть не хватало всегда.
    /// Вариант «Б» (показывать два уровня в самом списке) был собран, замерен и отвергнут
    /// числами: 72 из 81 против 78 — помощник тонул в путях и переставал отвечать даже
    /// там, где раньше отвечал.
    ///
    /// Поэтому считаем МЫ, а не он. Один обход внутри приложения стоит доли секунды и
    /// ноль шагов разговора, а помощник получает готовое число и просто называет его.
    ///
    /// ⚠️ Считаем ровно то же, что показываем: те же пропуски служебных папок, двоичных
    /// файлов и мусора. Иначе число не сойдётся с тем, что человек видит в списке, и
    /// он справедливо решит, что приложение врёт.
    ///
    /// ⚠️ Два ограничителя, и оба обязательны. Предел записей — чтобы папка на сотни
    /// тысяч файлов не считалась вечно. Срок — чтобы не догруженная из облака папка
    /// не подвесила ответ: у iCloud обход умеет надолго уходить в себя.
    /// Упёрлись в любой из них — честно говорим «более N», а не выдаём обрубок за точное.
    public static func countTree(startURL: URL,
                                 cap: Int = 20_000,
                                 deadline: Date = Date().addingTimeInterval(6)) -> TreeCount {

        guard CoordinatedFileIO.isDirectory(startURL) else { return TreeCount(files: 0, folders: 0, isApproximate: false) }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        let keySet = Set(keys)

        guard let enumerator = FileManager.default.enumerator(
            at: startURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return TreeCount(files: 0, folders: 0, isApproximate: false) }

        var files = 0
        var folders = 0
        var approximate = false
        var seen = 0

        for case let fileURL as URL in enumerator {
            seen += 1
            if seen > cap { approximate = true; break }
            // Срок проверяем не на каждом файле: сам вызов времени тоже стоит.
            if seen % 512 == 0, Date() >= deadline { approximate = true; break }

            let values = try? fileURL.resourceValues(forKeys: keySet)
            let name = values?.name ?? fileURL.lastPathComponent
            let lowerName = name.lowercased()

            if skippedFileNames.contains(lowerName) { continue }
            if FileDropbox.isTemporaryCopyName(name) { continue }

            // Ссылку считаем записью, но внутрь не идём: иначе кольцо ссылок считается вечно.
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                files += 1
                continue
            }

            if values?.isDirectory == true {
                if skippedDirectoryNames.contains(lowerName) || skippedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                folders += 1
            } else {
                if binaryExtensions.contains(fileURL.pathExtension.lowercased()) { continue }
                files += 1
            }
        }

        return TreeCount(files: files, folders: folders, isApproximate: approximate)
    }

    /// Сколько всего в дереве — готовым числом.
    public struct TreeCount: Sendable, Equatable {
        public let files: Int
        public let folders: Int
        /// Досчитать до конца не успели (слишком большая папка или облако тормозит).
        public let isApproximate: Bool
    }
}

// MARK: - Страница файла, номера строк, оглавление

/// Как файл нарезается для модели.
///
/// ⚠️ ПОЧЕМУ СТРАНИЦА СЧИТАЕТСЯ В ТОКЕНАХ, А НЕ В КИЛОБАЙТАХ. Память разговора мерится
/// токенами, а один и тот же килобайт стоит по-разному: килобайт кода — 256 токенов,
/// килобайт русского текста — 512. При байтовом пределе один файл занимал полпамяти,
/// а другой такой же — всю. При токенном страница всегда одна и та же по цене.
enum FilePaging {

    /// Сколько токенов уходит в одну страницу файла ПРЯМО СЕЙЧАС.
    ///
    /// ⚠️ СЧИТАЕТСЯ ОТ ПАМЯТИ, КОТОРУЮ ДВИЖОК ВЫДАЛ, А НЕ ОТ ВЫБОРА ЧЕЛОВЕКА.
    /// Число 700 подбиралось под память в 4 096 токенов, когда другой памяти и не было.
    /// Теперь человек сам ставит до 32 000 — и при жёсткой странице выходило нелепое:
    /// памяти в восемь раз больше, а файл всё равно читается теми же крошками.
    /// Но и считать от ВЫБОРА нельзя: движок подбирает ступеньку запуска и может отдать
    /// свои 4 096 при выбранных 32 000, ничем себя не выдав (см. LiteRTRuntime, строка
    /// журнала «просил — дали — выбор человека»). Тогда страница считалась по 5 333
    /// токена, и каждое чтение упиралось в «файл не помещается в память разговора».
    /// Отсюда `ContextSizeSettings.effectiveTokens` — меньшее из выданного и выбранного.
    static var pageTokens: Int {
        AgentLimits.readPageTokens(forCeiling: ContextSizeSettings.effectiveTokens)
    }

    /// Примерно сколько БАЙТ текста помещается в одну страницу.
    ///
    /// ⚠️ Считаем с запасом, по худшему случаю: у русского текста на токен приходится
    /// меньше байт, чем у латиницы. Занизить тут не страшно (скажем «читаю частями» чуть
    /// раньше, чем надо), а завысить — значит пообещать человеку то, чего не будет.
    static var pageBytes: Int { pageTokens * 2 }

    /// Сколько строк, начиная с `startIndex`, помещается в страницу.
    /// Возвращает диапазон индексов (нумерация с нуля).
    static func pageRange(in lines: [String],
                          startIndex: Int,
                          tokenBudget: Int = FilePaging.pageTokens) -> Range<Int> {
        guard startIndex < lines.count else { return startIndex..<startIndex }

        var used = 0
        var end = startIndex
        while end < lines.count {
            // Номер строки и разделитель — тоже расход, и его надо считать честно,
            // иначе страница окажется на треть длиннее обещанного.
            let cost = ConversationHistory.estimateTokens(lines[end]) + 3
            if end > startIndex, used + cost > tokenBudget { break }
            used += cost
            end += 1
        }
        // Хотя бы одна строка отдаётся всегда: иначе на длинной строке чтение
        // возвращало бы пустоту, и модель считала бы файл пустым.
        return startIndex..<max(end, startIndex + 1)
    }

    /// Во сколько примерно страниц уложится весь файл.
    static func pageCount(of lines: [String],
                          tokenBudget: Int = FilePaging.pageTokens) -> Int {
        guard !lines.isEmpty else { return 0 }
        var total = 0
        for line in lines {
            total += ConversationHistory.estimateTokens(line) + 3
        }
        return max(1, Int((Double(total) / Double(max(1, tokenBudget))).rounded(.up)))
    }
}

/// Номера строк в выдаче чтения.
enum LineNumbering {

    /// «  1| import Foundation» — текст с номерами строк, начиная с `firstNumber`.
    ///
    /// ⚠️ Номер стоит около одного токена на строку и окупается дважды: модель может
    /// сослаться на место, не переписывая его, и видит, что файл не кончился.
    static func render(_ lines: ArraySlice<String>, firstNumber: Int) -> String {
        guard !lines.isEmpty else { return "" }
        let lastNumber = firstNumber + lines.count - 1
        let width = String(lastNumber).count
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for (offset, line) in lines.enumerated() {
            let number = String(firstNumber + offset)
            let padding = String(repeating: " ", count: max(0, width - number.count))
            out.append("\(padding)\(number)| \(line)")
        }
        return out.joined(separator: "\n")
    }

    /// Текст выглядит так, будто модель скопировала нашу же выдачу вместе с номерами строк.
    ///
    /// ⚠️ ЗАЧЕМ. Мы сами приучаем модель видеть «  42| let x = 1». Маленькая модель
    /// легко возвращает эти строки обратно в write_file — и тогда номера ушли бы
    /// в файл человека как часть кода.
    ///
    /// ⚠️ ПОЧЕМУ ПРОВЕРКА ТАКАЯ ПРИДИРЧИВАЯ. Есть настоящие файлы, где строки начинаются
    /// с числа и палочки — например выгрузка таблицы «1|Иван|20». Отказать в записи такого
    /// файла нельзя. Поэтому совпасть должно ВСЁ сразу: каждая строка, после палочки
    /// пробел или конец строки, и номера идут ровно подряд — так выглядит только наш
    /// собственный вывод.
    static func looksNumbered(_ text: String) -> Bool {
        let lines = DiffBuilder.splitLines(text)
        guard lines.count >= 2 else { return false }

        var expected: Int?
        for line in lines {
            let body = line.drop(while: { $0 == " " })
            let digits = body.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, let number = Int(digits) else { return false }

            let afterDigits = body.dropFirst(digits.count)
            guard afterDigits.first == "|" else { return false }
            let afterPipe = afterDigits.dropFirst().first
            guard afterPipe == nil || afterPipe == " " else { return false }

            if let expected, number != expected { return false }
            expected = number + 1
        }
        return true
    }

    /// Снять номера строк, которые модель скопировала из нашей же выдачи.
    ///
    /// ⚠️ Зовётся ТОЛЬКО после `looksNumbered`, то есть когда каждая строка заведомо
    /// начинается с «отступ, число, палочка». Отрезаем ровно эту приставку и ровно один
    /// пробел после палочки: отступ самого кода живёт ПОСЛЕ него, и съесть его нельзя —
    /// иначе питон приедет к человеку без отступов.
    static func strip(_ text: String) -> String {
        DiffBuilder.splitLines(text).map { line -> String in
            let body = line.drop(while: { $0 == " " })
            let digits = body.prefix(while: { $0.isNumber })
            guard !digits.isEmpty else { return line }
            var rest = body.dropFirst(digits.count)
            guard rest.first == "|" else { return line }
            rest = rest.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
            return String(rest)
        }
        .joined(separator: "\n")
    }
}

/// Оглавление файла: строки, похожие на объявления, вместе с их номерами.
///
/// ⚠️ Это ДОГАДКА ПО ВИДУ СТРОКИ, а не разбор языка. Поэтому ответ прямо говорит,
/// что это оглавление, а не текст, и если объявлений нашлось меньше трёх —
/// оглавление не показывается вовсе, отдаётся обычная первая страница.
enum FileOutline {

    /// Слова, с которых начинается объявление в языках, которые люди носят в кармане.
    private static let declarationKeywords: Set<String> = [
        "func", "fn", "def", "function", "sub", "proc",
        "class", "struct", "enum", "protocol", "extension", "actor", "interface",
        "trait", "impl", "type", "typealias", "record", "module", "namespace", "package"
    ]

    /// Приставки, которые стоят ПЕРЕД словом объявления и сами объявлением не являются.
    private static let modifiers: Set<String> = [
        "public", "private", "internal", "fileprivate", "open", "static", "final",
        "override", "mutating", "class", "async", "export", "default", "abstract",
        "protected", "extern", "inline", "const", "declare", "@objc", "pub", "unsafe"
    ]

    /// Строки оглавления, уже с номерами. Пусто — оглавление не сложилось.
    static func build(lines: [String],
                      pathExtension: String,
                      maxEntries: Int = AgentLimits.outlineMaxEntries) -> (entries: [String], total: Int) {
        let isMarkdown = ["md", "markdown", "mdx", "rst", "adoc"].contains(pathExtension.lowercased())

        var found: [(number: Int, text: String)] = []
        for (index, line) in lines.enumerated() {
            guard let title = heading(of: line, isMarkdown: isMarkdown) else { continue }
            found.append((index + 1, title))
        }

        let shown = found.prefix(maxEntries).map { "\($0.number)| \($0.text)" }
        return (shown, found.count)
    }

    /// Строка похожа на заголовок или объявление — вернуть её укороченный вид.
    private static func heading(of line: String, isMarkdown: Bool) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Заголовок разметки: «# Название». В коде такая строка — обычный комментарий,
        // поэтому берём её только там, где разметка и правда бывает.
        if isMarkdown, trimmed.hasPrefix("#") {
            return shorten(trimmed)
        }

        // Пометка раздела: её ставят руками именно как оглавление файла.
        if trimmed.contains("MARK:") { return shorten(trimmed) }

        // Остальные комментарии в оглавление не идут: иначе оно состоит из них одних.
        for marker in ["//", "/*", "*", "#", "--", ";", "<!--"] where trimmed.hasPrefix(marker) {
            return nil
        }

        // Объявление: слово-ключ стоит одним из первых слов строки.
        let words = trimmed.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
        for word in words.prefix(4) {
            let clean = word.trimmingCharacters(in: CharacterSet(charactersIn: "(:{<"))
            if declarationKeywords.contains(clean) {
                return shorten(trimmed)
            }
            // Слово не приставка и не ключ — дальше в строке объявления уже не будет.
            if !modifiers.contains(clean), !clean.hasPrefix("@") { break }
        }
        return nil
    }

    /// Длинную сигнатуру режем: оглавление обязано быть дешевле страницы.
    private static func shorten(_ text: String) -> String {
        text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}

// MARK: - Похожие имена файлов

/// Подсказка «такого файла нет, а вот похожий» для read_file.
///
/// ⚠️ ЗАЧЕМ ЭТО ПОЯВИЛОСЬ. Разобранная переписка с телефона владельца (10.08.2026,
/// 01:30–01:31): модель просит `0-2-правила.md`, а в папке лежит `02-правила.md`.
/// Ответ был тупиковый — «Файл «0-2-правила.md» не найден.», и всё. Модель повторила
/// тот же вызов восемь раз подряд, задача трижды останавливалась на ошибке, владелец
/// трижды присылал её заново и в конце написал агенту «Ало не надо читать этот файл».
/// Разница между именами — один дефис, и назвать её обязано приложение: модель
/// на 4 млрд параметров своей опечатки не видит и «исправляет» её ещё одной опечаткой
/// (следующим ходом она попросила уже `0-2-ла.md`).
///
/// ⚠️ Смотрим РОВНО ОДНУ папку — ту, куда показала модель, — одним вызовом файловой
/// системы, без обхода дерева. Поиск похожего по всему проекту стоил бы обхода всех
/// папок на каждую опечатку, а выигрыш дал бы тот же самый.
enum NearbyNames {

    /// Сколько имён предлагаем: одно-два. Больше — и модель начинает выбирать
    /// вместо того, чтобы читать.
    private static let maxSuggestions = 2
    /// Сколько имён в папке вообще просматриваем.
    private static let maxScanned = 500
    /// На сколько букв имя может отличаться, чтобы считаться тем же самым.
    private static let maxDistance = 2
    /// Короткие имена по буквам не сравниваем: «a.md» и «b.md» отличаются на одну
    /// букву, но это разные файлы, и такой совет увёл бы модель не туда.
    private static let minLengthForFuzzy = 5

    /// Ошибка «файла нет» — по возможности с готовым выходом.
    static func notFoundError(relativePath: String, missing url: URL, root: URL) -> PocketAgentError {
        let names = similar(to: url, root: root)
        guard !names.isEmpty else { return .fileNotFound(relativePath) }

        let list = names.map { "«\($0)»" }.joined(separator: " или ")
        return .readFailed(
            path: relativePath,
            reason: "такого файла нет. Рядом лежит \(list) — читай его, "
                + "если имя просто написано по-другому."
        )
    }

    /// Имена в той же папке, похожие на просимое.
    static func similar(to url: URL, root: URL) -> [String] {
        let askedKey = key(of: url.lastPathComponent)
        guard !askedKey.isEmpty else { return [] }

        // Папки на пути тоже может не быть — тогда ищем в корне проекта.
        var folder = url.deletingLastPathComponent()
        if !CoordinatedFileIO.isDirectory(folder) { folder = root }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return []
        }

        var found: [(relative: String, distance: Int)] = []
        for name in names.prefix(maxScanned) {
            let lower = name.lowercased()
            if DirectoryLister.skippedFileNames.contains(lower) { continue }
            if DirectoryLister.skippedDirectoryNames.contains(lower) { continue }

            let candidate = folder.appendingPathComponent(name)
            guard CoordinatedFileIO.isRegularFile(candidate) else { continue }
            if DirectoryLister.binaryExtensions.contains(candidate.pathExtension.lowercased()) { continue }
            guard let distance = distance(from: askedKey, to: name) else { continue }

            let relative = SafePath.relativePath(of: candidate, root: root)
            guard !relative.isEmpty else { continue }
            // Прочитать этот файл всё равно нельзя (служебный, похож на хранилище
            // ключей) — тогда и советовать его незачем: вышел бы второй тупик
            // вместо выхода из первого.
            guard (try? SafePath.resolveForReading(relative, root: root)) != nil else { continue }

            found.append((relative, distance))
        }

        found.sort { $0.distance == $1.distance ? $0.relative < $1.relative : $0.distance < $1.distance }
        return found.prefix(maxSuggestions).map { $0.relative }
    }

    /// На сколько букв имя расходится с просимым. nil — это другое имя.
    private static func distance(from askedKey: String, to name: String) -> Int? {
        let candidateKey = key(of: name)
        guard !candidateKey.isEmpty else { return nil }
        // Совпало после отбрасывания разделителей: ровно случай «0-2-правила.md»
        // против «02-правила.md» — та же самая опечатка, что дала круг.
        if candidateKey == askedKey { return 0 }

        guard askedKey.count >= minLengthForFuzzy,
              abs(candidateKey.count - askedKey.count) <= maxDistance else { return nil }
        let steps = editDistance(Array(candidateKey), Array(askedKey))
        return steps <= maxDistance ? steps : nil
    }

    /// Имя без того, что человек и модель путают чаще всего: регистра, дефисов,
    /// подчёркиваний, пробелов и точек.
    private static func key(of name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Сколько вставок, удалений и замен превращают одно слово в другое.
    /// Обычный расчёт по двум строкам таблицы — имена короткие, считать дёшево.
    private static func editDistance(_ first: [Character], _ second: [Character]) -> Int {
        guard !first.isEmpty else { return second.count }
        guard !second.isEmpty else { return first.count }

        var previous = Array(0...second.count)
        var current = [Int](repeating: 0, count: second.count + 1)

        for i in 1...first.count {
            current[0] = i
            for j in 1...second.count {
                let substitution = previous[j - 1] + (first[i - 1] == second[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[second.count]
    }
}

// MARK: - Рабочая папка

/// Реализация FileWorkspace поверх выбранной пользователем папки.
/// Все пути проходят через SafePath — за корень выйти невозможно.
public final class SecurityScopedWorkspace: FileWorkspace {

    /// Сколько байт файла отдаём МОДЕЛИ за один раз.
    /// Больше — не влезает в кэш разговора.
    public static let maxReadBytes = AgentLimits.maxReadBytes

    /// То же самое, но с поправкой на память разговора, которую движок ВЫДАЛ.
    ///
    /// ⚠️ 6 КБ подбирались под память в 4 096 токенов. На 32 000 этот потолок начинал
    /// врать: приложение отказывалось показать строку в 8 КБ («не помещается в память
    /// разговора») там, где памяти хватало вчетверо. Берём наибольшее из двух — значит
    /// на прежней настройке ничего не меняется, а на большой памяти запрет отступает.
    ///
    /// ⚠️ И считается это от ВЫДАННОГО движком окна, а не от выбора человека на экране:
    /// иначе при выданных 4 096 и выбранных 32 000 мы обещали бы вчетверо больше того,
    /// что помещается, — и упирались бы в отказ на каждом чтении (см. FilePaging.pageTokens).
    static var readCeilingBytes: Int {
        max(AgentLimits.maxReadBytes, FilePaging.pageBytes * 2)
    }

    /// Сколько байт файла читаем С ДИСКА: ради диффа и ради сверки перед записью.
    /// Здесь кэш модели ни при чём — дифф считается на телефоне.
    public static let maxFileBytes = AgentLimits.maxFileBytes

    /// Насколько новый текст может быть короче старого у файла, который модель
    /// физически не могла увидеть целиком. Ниже этой доли считаем, что модель
    /// переписывает файл по обрезанному куску, и запись не даём построить вовсе.
    private static let minKeptShareForLargeFile = 0.7

    public let rootURL: URL

    public init(root: URL) {
        // Канонизируем один раз, чтобы сравнения путей всегда шли по одной системе координат
        self.rootURL = SafePath.canonical(root)
    }

    // MARK: Пути

    public func resolve(_ rawPath: String) throws -> URL {
        try SafePath.resolve(rawPath, root: rootURL, allowRoot: true)
    }

    // MARK: Список файлов

    public func list(relativePath: String) throws -> [WorkspaceEntry] {
        try listDetailed(relativePath: relativePath).entries
    }

    public func listDetailed(relativePath: String) throws -> WorkspaceListing {
        try guardingRoot { try listInsideRoot(relativePath: relativePath) }
    }

    private func listInsideRoot(relativePath: String) throws -> WorkspaceListing {
        let start = try SafePath.resolve(relativePath, root: rootURL, allowRoot: true)
        // Внутрь .git и подобного не заходим даже за одними именами файлов.
        try SafePath.ensureNotProtected(start, root: rootURL, rawPath: relativePath)
        return try DirectoryLister.list(root: rootURL, startURL: start)
    }

    // MARK: Чтение

    /// Читает файл для МОДЕЛИ — с начала.
    public func readText(relativePath: String) throws -> WorkspaceFile {
        try readText(relativePath: relativePath, from: nil, to: nil)
    }

    /// Читает файл для МОДЕЛИ страницами.
    ///
    /// ⚠️ ПОЧЕМУ СТРАНИЦАМИ, А НЕ ЦЕЛИКОМ. Память разговора — 4096 токенов на вход
    /// и выход вместе. Обычный исходник (20–40 КБ) не помещается в неё ни в каком виде:
    /// раньше агент отдавал начало файла и на каждом шаге повторял «файл слишком большой»,
    /// то есть главный сценарий продукта просто не работал. Теперь один ответ — одна
    /// страница примерно в 700 токенов с номерами строк, и модель сама просит следующую
    /// или сразу нужный кусок. По этим же номерам она потом правит файл, не переписывая
    /// его целиком.
    ///
    /// - Parameters:
    ///   - from: с какой строки читать (нумерация с единицы). nil — с начала файла,
    ///     и тогда большой файл открывается ОГЛАВЛЕНИЕМ, а не первой страницей.
    ///   - to: по какую строку включительно. nil — сколько поместится в страницу.
    public func readText(relativePath: String, from: Int?, to: Int?) throws -> WorkspaceFile {
        try guardingRoot { try readTextInsideRoot(relativePath: relativePath, from: from, to: to) }
    }

    private func readTextInsideRoot(relativePath: String, from: Int?, to: Int?) throws -> WorkspaceFile {
        let url = try SafePath.resolveForReading(relativePath, root: rootURL)

        guard FileManager.default.fileExists(atPath: url.path) else {
            // ⚠️ НЕ ПРОСТО «файл не найден». Голый отказ — тупик: модель повторяет тот же
            // вызов, пока задача не остановится (живая переписка 10.08.2026, восемь
            // одинаковых просьб подряд). Поэтому, если рядом лежит файл с почти таким же
            // именем, называем его прямо — это и есть выход из круга.
            throw NearbyNames.notFoundError(relativePath: relativePath, missing: url, root: rootURL)
        }
        guard CoordinatedFileIO.isRegularFile(url) else {
            // Папка — самый частый случай, и ответ обязан называть выход, иначе
            // модель повторяет тот же вызов (та же беда, что была со списком по файлу).
            if CoordinatedFileIO.isDirectory(url) {
                throw PocketAgentError.pathIsFolderNotFile(relativePath)
            }
            throw PocketAgentError.notARegularFile(relativePath)
        }

        let size = CoordinatedFileIO.byteSize(of: url) ?? 0
        guard size <= Self.maxFileBytes else {
            throw PocketAgentError.fileTooLarge(path: relativePath, bytes: size)
        }

        let fullText = try readWholeText(at: url, relativePath: relativePath)
        try Self.ensureNoSecrets(in: fullText, relativePath: relativePath)

        let lines = DiffBuilder.splitLines(fullText)
        let totalLines = lines.count
        let modified = CoordinatedFileIO.modificationDate(of: url)

        // Пустой файл — законный случай, и говорить о нём надо прямо, а не отдавать пустоту.
        guard totalLines > 0 else {
            return WorkspaceFile(relativePath: relativePath,
                                 text: "",
                                 byteSize: size,
                                 modificationDate: modified,
                                 isTruncated: false,
                                 totalLineCount: 0,
                                 shownLineCount: 0)
        }

        // Номера строк проверяем ДО всего остального: молча показать не то место —
        // значит подтолкнуть модель править не то место.
        if let from, from > totalLines {
            throw PocketAgentError.readFailed(
                path: relativePath,
                reason: "строки \(from) нет — в файле всего \(HumanFormat.lines(totalLines))"
            )
        }

        let startIndex = max(0, (from ?? 1) - 1)

        // Файл целиком влезает в одну страницу — отдаём как есть, без всяких оговорок.
        if from == nil, to == nil, FilePaging.pageCount(of: lines) <= 1 {
            return WorkspaceFile(relativePath: relativePath,
                                 text: fullText,
                                 byteSize: size,
                                 modificationDate: modified,
                                 isTruncated: false,
                                 totalLineCount: totalLines,
                                 shownLineCount: totalLines)
        }

        // Первое обращение к длинному файлу — отдаём оглавление, а не начало текста.
        // Листать большой файл с первой страницы — самый дорогой способ найти нужное.
        if from == nil, to == nil, FilePaging.pageCount(of: lines) > AgentLimits.outlinePageThreshold {
            let outline = FileOutline.build(lines: lines, pathExtension: url.pathExtension)
            if outline.entries.count >= AgentLimits.outlineMinEntries {
                var text = outline.entries.joined(separator: "\n")
                if outline.total > outline.entries.count {
                    text += "\n… показаны первые \(outline.entries.count) объявлений из \(outline.total)"
                }
                return WorkspaceFile(relativePath: relativePath,
                                     text: text,
                                     byteSize: size,
                                     modificationDate: modified,
                                     isTruncated: true,
                                     totalLineCount: totalLines,
                                     shownLineCount: outline.entries.count,
                                     view: .outline,
                                     firstLine: 1)
            }
            // Объявлений не нашлось (обычный текст, незнакомый формат) — обычная страница.
        }

        // Сколько строк отдаём: либо явный диапазон модели, либо страница по размеру.
        var endIndex = FilePaging.pageRange(in: lines, startIndex: startIndex).upperBound
        if let to {
            guard to >= startIndex + 1 else {
                throw PocketAgentError.readFailed(
                    path: relativePath,
                    reason: "конец диапазона (\(to)) раньше начала (\(startIndex + 1))"
                )
            }
            // Просить больше страницы можно — отдадим сколько влезет и честно скажем сколько.
            endIndex = min(endIndex, min(to, totalLines))
        }

        let slice = lines[startIndex..<max(endIndex, startIndex + 1)]
        let shownText = slice.joined(separator: "\n")

        // Одна строка на весь файл (минифицированный код, большой JSON): показать её
        // нечем, а показать КУСОК нельзя — модель заменит строку куском и снесёт остальное.
        if slice.count == 1, shownText.utf8.count > Self.readCeilingBytes {
            throw PocketAgentError.readFailed(
                path: relativePath,
                reason: "строка \(startIndex + 1) длиной \(HumanFormat.bytes(shownText.utf8.count)) — "
                    + "она не помещается в память разговора целиком, а по кускам её править опасно. "
                    + "Скажи человеку, что этот файл придётся править на компьютере"
            )
        }

        return WorkspaceFile(relativePath: relativePath,
                             text: shownText,
                             byteSize: size,
                             modificationDate: modified,
                             isTruncated: slice.count < totalLines,
                             totalLineCount: totalLines,
                             shownLineCount: slice.count,
                             view: slice.count < totalLines ? .page : .whole,
                             firstLine: startIndex + 1)
    }

    // MARK: Дифф (ничего не пишет)

    public func diff(relativePath: String, newText: String) throws -> FileDiff {
        try guardingRoot { try diffInsideRoot(relativePath: relativePath, newText: newText) }
    }

    /// Дифф возврата к сохранённому приложением тексту.
    ///
    /// ⚠️ ОТЛИЧИЕ РОВНО ОДНО: не применяется проверка «модель прислала обрезанный файл».
    /// Она тут не просто лишняя, а вредная: текст возврата приложение списало с диска
    /// само, а сработала бы проверка именно в самом нужном случае — когда правка сильно
    /// раздула файл и человек хочет откатить её целиком. Всё остальное общее: те же
    /// проверки пути, тот же предел размера, тот же построитель диффа, та же сверка
    /// содержимого перед записью.
    public func revertDiff(relativePath: String, previousText: String) throws -> FileDiff {
        try guardingRoot {
            try diffInsideRoot(relativePath: relativePath,
                               newText: previousText,
                               trustsNewText: true)
        }
    }

    private func diffInsideRoot(relativePath: String,
                                newText: String,
                                trustsNewText: Bool = false) throws -> FileDiff {
        let url = try SafePath.resolveForWriting(relativePath, root: rootURL)
        let exists = FileManager.default.fileExists(atPath: url.path)

        var oldText: String?
        var baseDate: Date?

        // Папки, которых ещё нет: они появятся вместе с файлом, и человек обязан
        // увидеть это в карточке — сейчас их молча создаёт запись.
        let createdDirectories = missingDirectories(for: url)

        if exists {
            guard CoordinatedFileIO.isRegularFile(url) else {
                // Папка — самый частый случай, и ответ обязан называть выход, иначе
                // модель повторяет тот же вызов (та же беда, что была со списком по файлу).
                if CoordinatedFileIO.isDirectory(url) {
                    throw PocketAgentError.pathIsFolderNotFile(relativePath)
                }
                throw PocketAgentError.notARegularFile(relativePath)
            }
            let size = CoordinatedFileIO.byteSize(of: url) ?? 0
            // ⚠️ Здесь предел ДРУГОЙ, чем при чтении в модель: дифф считается на телефоне
            // и кэш разговора не занимает. Со старым общим пределом в 12 КБ обычный
            // исходник нельзя было не то что прочитать — вообще изменить.
            guard size <= Self.maxFileBytes else {
                throw PocketAgentError.fileTooLarge(path: relativePath, bytes: size)
            }

            let text = try readWholeText(at: url, relativePath: relativePath)

            // Файл заведомо больше того, что модель могла увидеть за один раз.
            // Если она прислала заметно более короткий текст — это переписывание
            // по обрезанному куску, то есть молчаливое уничтожение хвоста файла.
            // Такую карточку человеку показывать нельзя вообще.
            if !trustsNewText, text.utf8.count > Self.readCeilingBytes {
                let kept = Double(newText.utf8.count) / Double(max(1, text.utf8.count))
                if kept < Self.minKeptShareForLargeFile {
                    // ⚠️ Раньше здесь был тупик «файл слишком большой, правь на компьютере».
                    // Теперь выход есть, и назвать его обязаны прямо: заменить нужные
                    // строки по номерам. Без этой подсказки модель просто сдаётся.
                    throw PocketAgentError.writeFailed(
                        path: relativePath,
                        reason: "файл \(HumanFormat.bytes(text.utf8.count)), а ты видел только часть. "
                            + "Целиком его переписывать нельзя — пропадёт всё, чего ты не видел. "
                            // ⚠️ Без синтаксиса вызова: маленькая модель списывает такую
                            // строку буквами и отправляет её человеку вместо действия.
                            + "Замени только нужные строки, назвав их номера."
                    )
                }
            }

            oldText = text
            baseDate = CoordinatedFileIO.modificationDate(of: url)
        }

        return DiffBuilder.build(relativePath: relativePath,
                                 oldText: oldText,
                                 newText: newText,
                                 baseModificationDate: baseDate,
                                 createdDirectories: createdDirectories)
    }

    // MARK: Дифф замены строк (тоже ничего не пишет)

    /// Собирает новый текст файла из его содержимого на диске и присланного куска,
    /// после чего строит ОБЫЧНЫЙ дифф.
    ///
    /// ⚠️ ГЛАВНОЕ ЗДЕСЬ — ЧТО НИЧЕГО НЕ МЕНЯЕТСЯ ДАЛЬШЕ ПО ЦЕПОЧКЕ. Отсюда выходит
    /// такой же FileDiff, как при записи файла целиком: человек видит карточку «до/после»,
    /// жмёт «Применить», запись идёт ровно показанным текстом и со сверкой содержимого
    /// файла на диске. Ни один предохранитель подтверждения не обходится — меняется
    /// только то, ЧТО модель обязана прислать: пять строк вместо всего файла.
    public func diff(relativePath: String,
                     replacingLines lines: ClosedRange<Int>,
                     with fragment: String) throws -> FileDiff {
        try guardingRoot {
            try diffReplacingInsideRoot(relativePath: relativePath, lines: lines, fragment: fragment)
        }
    }

    private func diffReplacingInsideRoot(relativePath: String,
                                         lines range: ClosedRange<Int>,
                                         fragment: String) throws -> FileDiff {
        let url = try SafePath.resolveForWriting(relativePath, root: rootURL)

        // Номера строк применять не к чему: файла нет. Молча создать его из куска нельзя —
        // модель думает, что правит существующий файл, а человек увидел бы «новый файл».
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PocketAgentError.writeFailed(
                path: relativePath,
                reason: "файла нет, номера строк применять не к чему — "
                    + "создай его целиком, без from_line и to_line"
            )
        }
        guard CoordinatedFileIO.isRegularFile(url) else {
            // Папка — самый частый случай, и ответ обязан называть выход, иначе
            // модель повторяет тот же вызов (та же беда, что была со списком по файлу).
            if CoordinatedFileIO.isDirectory(url) {
                throw PocketAgentError.pathIsFolderNotFile(relativePath)
            }
            throw PocketAgentError.notARegularFile(relativePath)
        }
        let size = CoordinatedFileIO.byteSize(of: url) ?? 0
        guard size <= Self.maxFileBytes else {
            throw PocketAgentError.fileTooLarge(path: relativePath, bytes: size)
        }

        let oldText = try readWholeText(at: url, relativePath: relativePath)

        // Строки берём ВМЕСТЕ с их переводами строк: иначе правка пяти строк
        // молча переписала бы весь файл с другими переводами строк (см. DiffBuilder).
        let oldLines = DiffBuilder.splitPreservingLineBreaks(oldText)

        // ⚠️ Номера не сошлись — ЧЕСТНЫЙ ОТКАЗ, и ни в коем случае не «поправим сами».
        // Модель на 2 млрд параметров ошибается номером регулярно; заменить не тот кусок
        // и показать это человеку как обычную правку — самый дешёвый способ испортить файл.
        guard range.lowerBound >= 1 else {
            throw PocketAgentError.writeFailed(
                path: relativePath,
                reason: "строки нумеруются с единицы, а прислано \(range.lowerBound)"
            )
        }
        guard range.upperBound <= oldLines.count else {
            throw PocketAgentError.writeFailed(
                path: relativePath,
                reason: "строк \(range.lowerBound)–\(range.upperBound) в файле нет — "
                    + "всего \(HumanFormat.lines(oldLines.count)). "
                    + "Прочитай файл ещё раз и возьми номера из ответа"
            )
        }

        let firstIndex = range.lowerBound - 1
        let lastIndex = range.upperBound - 1

        // ⚠️ МОДЕЛЬ ПРИСЛАЛА ВЕСЬ ФАЙЛ, А НОМЕРА СТРОК — «ОТ КОНЦА»: ЭТО ПЕРЕЗАПИСЬ,
        // А НЕ ЗАМЕНА КУСКА. Иначе выходит РАЗМНОЖЕНИЕ ТЕКСТА, и оно уже случилось.
        // Живой прогон 07.09.2026, задача «допиши в конец README.md строку Проверено»:
        // модель прочитала файл из 8 строк, прислала обратно весь его текст плюс новую
        // строку и попросила заменить с 8-й. Мы честно склеили «строки 1–7» + присланное
        // и получили файл, где первые семь строк идут ДВАЖДЫ. Запись прошла, карточка
        // показала «+8 −0», проверка «в файле есть нужные слова» была довольна —
        // а файл человека испорчен.
        //
        // Признак надёжный: начало присланного куска СОВПАДАЕТ с началом файла, которое
        // мы собирались оставить нетронутым. Настоящая правка куска так не выглядит
        // никогда — незачем повторять в куске то, что и так остаётся на месте.
        // Ошибиться в безопасную сторону тоже не страшно: получится обычная запись
        // файла целиком тем текстом, который модель и прислала, и человек увидит его
        // в карточке «до и после» ДО записи.
        let fragmentLines = DiffBuilder.splitLines(fragment)
        let keptHead = DiffBuilder.splitLines(oldText).prefix(firstIndex)
        if firstIndex > 0,
           fragmentLines.count > firstIndex,
           Array(fragmentLines.prefix(firstIndex)) == Array(keptHead) {
            return try diffInsideRoot(relativePath: relativePath, newText: fragment)
        }

        // Переводы строк берём У САМОГО ФАЙЛА, а не у модели: она почти всегда присылает
        // обычные, даже если файл виндовый. Так файл с виндовыми переводами остаётся
        // виндовым, а файл без переноса в конце — без переноса.
        let fileBreak = oldLines
            .lazy
            .map { DiffBuilder.lineBreak(of: $0) }
            .first(where: { !$0.isEmpty }) ?? "\n"
        let tail = DiffBuilder.lineBreak(of: oldLines[lastIndex])
        let replacement = Self.fragmentText(fragment, lineBreak: fileBreak, tail: tail)

        var newText = oldLines[0..<firstIndex].joined()
        newText += replacement
        newText += oldLines[(lastIndex + 1)...].joined()

        return DiffBuilder.build(relativePath: relativePath,
                                 oldText: oldText,
                                 newText: newText,
                                 baseModificationDate: CoordinatedFileIO.modificationDate(of: url),
                                 createdDirectories: [])
    }

    /// Приводит присланный моделью кусок к переводам строк файла.
    /// `lineBreak` — какими переводами строк живёт файл, `tail` — чем кусок обязан
    /// закончиться (пусто, если заменяется последняя строка файла без переноса).
    static func fragmentText(_ fragment: String, lineBreak: String, tail: String) -> String {
        guard !fragment.isEmpty else { return "" }

        // Модель почти всегда присылает обычные переводы строк, даже если файл виндовый.
        // Оставить их как есть — значит намешать в файле два вида переводов строк.
        let pieces = DiffBuilder.splitLines(fragment)
        var text = pieces.joined(separator: lineBreak)
        if !tail.isEmpty {
            text += tail
        }
        return text
    }

    // MARK: Запись

    @discardableResult
    public func write(relativePath: String,
                      newText: String,
                      expecting: WriteExpectation) throws -> WorkspaceFile {
        try guardingRoot {
            try writeInsideRoot(relativePath: relativePath, newText: newText, expecting: expecting)
        }
    }

    @discardableResult
    private func writeInsideRoot(relativePath: String,
                                 newText: String,
                                 expecting: WriteExpectation) throws -> WorkspaceFile {
        let url = try SafePath.resolveForWriting(relativePath, root: rootURL)
        let exists = FileManager.default.fileExists(atPath: url.path)

        // Между показом карточки и нажатием «Применить» файл мог поменять кто угодно:
        // git-чекаут в Working Copy, догрузка из iCloud, другой редактор.
        // Проверяем в порядке строгости.
        if expecting.isNewFile {
            // Человеку показали «новый файл» — значит, содержимого он не видел.
            // Если файл успел появиться, перезапись уничтожит то, чего не показывали.
            guard !exists else {
                throw PocketAgentError.fileChangedSinceDiff(relativePath)
            }
        } else if let previous = expecting.previousText {
            // Главная проверка: сверяем СОДЕРЖИМОЕ, а не дату.
            // Дата на многих файловых системах хранится с точностью до секунды,
            // и чужая правка в ту же секунду прошла бы мимо.
            guard exists else {
                throw PocketAgentError.fileChangedSinceDiff(relativePath)
            }
            // Читаем ровно тем же пределом, что и при построении диффа, — иначе честного
            // побайтового сравнения не выйдет и защита превратится в видимость.
            let data = try CoordinatedFileIO.readData(at: url, limit: Self.maxFileBytes)
            guard let currentText = String(data: data, encoding: .utf8),
                  currentText == previous else {
                throw PocketAgentError.fileChangedSinceDiff(relativePath)
            }
        } else if let expected = expecting.modificationDate {
            // Содержимого «до» нет — остаётся быстрая проверка по дате.
            let actual = CoordinatedFileIO.modificationDate(of: url)
            guard let actual, abs(actual.timeIntervalSince(expected)) < 1.0 else {
                throw PocketAgentError.fileChangedSinceDiff(relativePath)
            }
        }

        try CoordinatedFileIO.writeText(newText, to: url, displayPath: relativePath)

        return WorkspaceFile(relativePath: relativePath,
                             text: newText,
                             byteSize: newText.utf8.count,
                             modificationDate: CoordinatedFileIO.modificationDate(of: url),
                             isTruncated: false)
    }

    // MARK: Пропала ли сама папка

    /// Выполнить работу и, если она упала, проверить главное: а папка-то ещё наша?
    ///
    /// ⚠️ ЗАЧЕМ ЭТА ОБЁРТКА. Когда папку удаляют, отзывают доступ или отключают провайдер
    /// (iCloud, Working Copy), система отвечает обычной ошибкой чтения или записи. Наверху
    /// цикл агента проверяет ровно три ошибки — «нет доступа», «закладка мертва», «папка
    /// не выбрана», — и ни одна из них отсюда не приходила: проверка была мёртвым кодом,
    /// а человек три хода подряд смотрел на одинаковые падения. Теперь при любой неудаче
    /// спрашиваем у файловой системы два признака корня (это один вызов, дерево не
    /// обходится) и, если корня больше нет, честно называем причину.
    private func guardingRoot<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            guard isRootAlive() else { throw PocketAgentError.folderAccessDenied }
            throw error
        }
    }

    /// Корень проекта на месте и читается.
    private func isRootAlive() -> Bool {
        guard let values = try? rootURL.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey]),
              values.isDirectory == true else {
            return false
        }
        // isReadable иногда не приезжает у файл-провайдера — считаем это «читается»:
        // соврать «папка пропала» хуже, чем показать исходную ошибку.
        return values.isReadable ?? true
    }

    // MARK: Служебное

    /// Прочитать файл целиком (до maxFileBytes) и убедиться, что это текст.
    private func readWholeText(at url: URL, relativePath: String) throws -> String {
        let data = try CoordinatedFileIO.readData(at: url, limit: Self.maxFileBytes)
        // Нулевой байт — верный признак двоичного файла
        if data.contains(0) {
            throw PocketAgentError.notUTF8(relativePath)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PocketAgentError.notUTF8(relativePath)
        }
        return text
    }

    /// Простая проверка на живые секреты внутри текста.
    ///
    /// ⚠️ Имя файла ничего не гарантирует: ключ доступа лежит и в `config.js`, и в
    /// `docker-compose.yml`. Прочитанное уходит в контекст модели, а человек видит
    /// в ленте только строку «прочитан файл» — поэтому такой файл честно не отдаём.
    static func ensureNoSecrets(in text: String, relativePath: String) throws {
        // Смотрим только начало: ключи и токены живут в шапке конфигов, а гонять
        // поиск по всему файлу на телефоне ради этого незачем.
        let head = String(text.prefix(4096))
        let markers = [
            "-----BEGIN ",          // приватный ключ или сертификат в любом виде
            "AKIA",                 // ключ доступа AWS
            "ASIA",                 // временный ключ доступа AWS
            "ghp_", "gho_", "ghs_", "github_pat_",
            "xoxb-", "xoxp-",       // Slack
            "sk-ant-", "sk-proj-",  // ключи моделей
            "AIzaSy"                // ключ Google API
        ]
        for marker in markers where head.contains(marker) {
            throw PocketAgentError.fileLooksLikeSecret(relativePath)
        }
    }

    /// Папки на пути к файлу, которых ещё нет (в порядке от корня, пути относительные).
    private func missingDirectories(for fileURL: URL) -> [String] {
        var missing: [String] = []
        var folder = fileURL.deletingLastPathComponent()

        while SafePath.isInside(folder, root: rootURL),
              folder.standardizedFileURL.pathComponents.count > rootURL.pathComponents.count {
            if !CoordinatedFileIO.isDirectory(folder) {
                missing.append(SafePath.relativePath(of: folder, root: rootURL))
            }
            folder = folder.deletingLastPathComponent()
        }
        return Array(missing.reversed())
    }
}

// MARK: - Хранилище показанных диффов

/// Помнит дифф, который человеку УЖЕ показали, чтобы запись шла ровно тем содержимым,
/// которое он подтвердил, и со сверкой даты изменения файла.
public final class PendingDiffStore: @unchecked Sendable {

    /// Сколько предпросмотров держим одновременно. Отклонённый и отменённый дифф
    /// теперь забирают сразу (discardPreview / discardAllPreviews), но предел оставляем
    /// как страховку: без него в памяти копились бы целые файлы за весь разговор.
    private static let capacity = 8

    private let lock = NSLock()
    private var storage: [String: FileDiff] = [:]
    /// Порядок появления — чтобы вытеснять самый старый, а не случайный.
    private var order: [String] = []

    public init() {}

    public func put(_ diff: FileDiff, for invocationID: String) {
        lock.lock(); defer { lock.unlock() }
        if storage[invocationID] == nil {
            order.append(invocationID)
        }
        storage[invocationID] = diff

        while order.count > Self.capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    /// Забрать и сразу удалить — повторно применить тот же дифф нельзя.
    public func take(_ invocationID: String) -> FileDiff? {
        lock.lock(); defer { lock.unlock() }
        order.removeAll { $0 == invocationID }
        return storage.removeValue(forKey: invocationID)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
        order.removeAll()
    }
}

// MARK: - Общие мелочи инструментов

enum ToolTextFormat {

    /// Размер человеческим языком. Считает ОДИН форматировщик на всё приложение —
    /// иначе в одной строке оказывались «2.59 ГБ» (точка от системы) и «ГБ» (наше слово).
    static func humanSize(_ bytes: Int) -> String {
        HumanFormat.bytes(bytes)
    }

    /// Строка списка ДЛЯ ЧЕЛОВЕКА — с размером файла.
    static func entryLine(_ entry: WorkspaceEntry) -> String {
        if entry.isSymbolicLink {
            return "\(entry.relativePath) (ссылка, читать нельзя)"
        }
        return entry.isDirectory
            ? "\(entry.relativePath)/"
            : "\(entry.relativePath) (\(humanSize(entry.byteSize)))"
    }

    /// Строка списка ДЛЯ МОДЕЛИ — без размера.
    ///
    /// ⚠️ Размер занимает около двух токенов в каждой строке — это шестая часть всего
    /// списка, и модели он не нужен ни для одного решения: читать файл она всё равно
    /// будет страницами. Человеку размер по-прежнему показываем: он по нему понимает,
    /// что перед ним, — поэтому строки для человека и для модели теперь разные.
    static func modelEntryLine(_ entry: WorkspaceEntry) -> String {
        if entry.isSymbolicLink {
            return "\(entry.relativePath) (ссылка, читать нельзя)"
        }
        return entry.isDirectory ? "\(entry.relativePath)/" : entry.relativePath
    }

    /// Понятный текст ошибки для человека и для модели.
    /// Системные английские тексты сюда не просачиваются — их переводит SystemErrorText.
    static func describe(_ error: Error) -> String {
        SystemErrorText.russian(for: error)
    }

    /// Первые `limit` строк текста — для предпросмотра.
    /// `characters` дополнительно ограничивает длину: одна строка бывает на весь файл.
    static func head(_ text: String, lines limit: Int, characters: Int? = nil) -> String {
        let all = DiffBuilder.splitLines(text)
        var body = all.count > limit
            ? all.prefix(limit).joined(separator: "\n") + "\n… ещё \(HumanFormat.lines(all.count - limit))"
            : text
        if let characters, body.count > characters {
            body = String(body.prefix(characters)) + "…"
        }
        return body
    }
}

// MARK: - Номера строк в аргументах модели

/// Разбор `from_line` / `to_line`.
///
/// ⚠️ ГЛАВНОЕ ПРАВИЛО: мусор вместо номера — это ОТКАЗ, а не «работаем как раньше».
/// Иначе получается самое дорогое поведение из возможных: модель просила заменить
/// пять строк, мы её не поняли и записали присланный кусок как ВЕСЬ файл — то есть
/// стёрли всё остальное. Отказ модель прочитает и повторит ход правильно.
enum LineArguments {

    /// Какой кусок файла назвала модель. Оба поля пусты — не называла вовсе.
    struct Window {
        let from: Int?
        let to: Int?

        var isEmpty: Bool { from == nil && to == nil }
    }

    static func window(for invocation: ToolInvocation, tool: ToolKind) throws -> Window {
        let from = try number(invocation.rawFromLine, name: "from_line", invocation: invocation, tool: tool)
        let to = try number(invocation.rawToLine, name: "to_line", invocation: invocation, tool: tool)

        if let to, to < 1 {
            throw failure(tool: tool, path: invocation.path,
                          reason: "строки нумеруются с единицы, а to_line = \(to)")
        }
        if let from, let to, to < from {
            throw failure(tool: tool, path: invocation.path,
                          reason: "to_line (\(to)) меньше from_line (\(from))")
        }
        // Назвали только конец диапазона: при ЧТЕНИИ это безобидно — покажем с начала
        // файла по названную строку. При ЗАПИСИ так гадать нельзя, и там этот случай
        // отдельно отвергается (replacedLines в write_file).
        return Window(from: from, to: to)
    }

    private static func number(_ raw: String?,
                               name: String,
                               invocation: ToolInvocation,
                               tool: ToolKind) throws -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // «42.0» приезжает, когда модель отдала число дробным — это тот же номер строки.
        let digits = trimmed.hasSuffix(".0") ? String(trimmed.dropLast(2)) : trimmed

        guard let value = Int(digits), value >= 1 else {
            throw failure(tool: tool, path: invocation.path,
                          reason: "\(name) = «\(trimmed)» — это не номер строки. "
                              + "Нужно целое число от 1, номера видно в ответе read_file")
        }
        return value
    }

    private static func failure(tool: ToolKind, path: String, reason: String) -> PocketAgentError {
        tool == .writeFile
            ? .writeFailed(path: path, reason: reason)
            : .readFailed(path: path, reason: reason)
    }
}

// MARK: - list_files

public struct WorkspaceListFilesTool: AgentTool {

    public let kind: ToolKind = .listFiles

    /// Текст берётся из ToolTexts — тот же самый уходит в схему для модели.
    public let details = ToolTexts.listFiles

    public let parameters: [ToolParameterSpec] = [
        ToolParameterSpec(name: "path",
                          details: ToolTexts.listFilesPath,
                          type: .string,
                          isRequired: false)
    ]

    private let workspace: any FileWorkspace
    private let listHistory: ListHistory

    public init(workspace: any FileWorkspace, listHistory: ListHistory = ListHistory()) {
        self.workspace = workspace
        self.listHistory = listHistory
    }

    public func preview(_ invocation: ToolInvocation) async throws -> ActionPreview {
        let listing = try workspace.listDetailed(relativePath: invocation.path)
        return .text(title: title(for: invocation),
                     body: body(for: listing))
    }

    public func execute(_ invocation: ToolInvocation) async throws -> ToolResult {
        do {
            let listing = try workspace.listDetailed(relativePath: invocation.path)
            // Модели — без размеров: они ей ни для чего не нужны, а место занимают.
            var lines = listing.entries.map(ToolTextFormat.modelEntryLine)
            // Оговорки уходят В МОДЕЛЬ вместе со списком: без них она считает список
            // полным и предлагает «создать» файл, который просто не догрузился из облака.
            for warning in listing.warnings {
                lines.append("⚠️ \(warning)")
            }
            // ⚠️ СТРОКУ С ЧИСЛОМ ЗАПИСЕЙ ОТСЮДА УБРАЛИ 09.09.2026 — ПО ЗАМЕРУ, А НЕ ПО
            // РАССУЖДЕНИЮ. Она задумывалась как помощь на вопрос «сколько тут файлов»,
            // а на деле сделала хуже дважды: счётной задаче не помогла вовсе (помощник
            // всё равно ушёл обходить дерево на 25 шагов), а в соседней задаче МОДЕЛЬ
            // ПРИНЯЛА ЕЁ ЗА ИМЯ ФАЙЛА и честно попробовала прочитать:
            //   «Читаю файл ⚠️ в этой папке 5 записей, не считая содержимого вложенных
            //    папок» → «файл не найден» → второй такой ход → задача остановлена.
            // Ответ списка — это массив имён, и всё, что в него положено, модель читает
            // как имя. Тот же старый урок, что и с примером вызова в инструкции:
            // покажешь буквами — получишь буквы.

            // ⚠️⚠️ ОДНУ И ТУ ЖЕ ПАПКУ ВТОРОЙ РАЗ НЕ ПОКАЗЫВАЕМ — ЭТО И ЕСТЬ ЛЕЧЕНИЕ
            // «БЕСКОНЕЧНОГО ЛУПА», НА КОТОРЫЙ ЖАЛУЕТСЯ ВЛАДЕЛЕЦ. В его переписке
            // 08.09.2026 помощник дважды подряд открыл «.github/workflows/» и получил
            // тот же ответ; разговор не сдвинулся, а шаги кончились. Список мы всё
            // равно собрали (папка могла измениться) — и только УБЕДИВШИСЬ, что
            // содержимое то же, отвечаем короткой строкой вместо повтора.
            //
            // ⚠️ Отвечаем НЕУДАЧЕЙ, а не успехом. Успех обнулил бы счётчик кривых
            // ходов в движке, и повторять можно было бы до предела шагов — ровно то,
            // от чего лечимся. Тот же приём и по той же причине уже работает у чтения.
            let fingerprint = ListHistory.fingerprint(of: listing)
            switch listHistory.advice(forPath: invocation.path, fingerprint: fingerprint) {
            case .alreadySeen(let note):
                // Первый повтор — просто не показываем список второй раз. Ход удачный:
                // в длинном разговоре смотреть корень заново на новом ходу человека
                // совершенно законно, и наказывать за это нельзя.
                return ToolResult.success(for: invocation,
                                          payload: .fields(["подсказка": note]),
                                          userSummary: "Эту папку уже смотрели — показываю не заново")
            case .stuck(let note):
                // Второй и дальше — это уже круг. Отвечаем НЕУДАЧЕЙ: успех обнулил бы
                // счётчик кривых ходов, и повторять можно было бы до предела шагов.
                return ToolResult.failure(invocation, reason: note, error: nil)
            case .asAsked:
                break
            }
            listHistory.remember(path: invocation.path, fingerprint: fingerprint)

            var summary = listing.entries.isEmpty
                ? "Папка пуста"
                : "Найдено: \(HumanFormat.entries(listing.entries.count))"
            if !listing.warnings.isEmpty {
                summary += " — " + listing.warnings.joined(separator: "; ")
            }

            return ToolResult.success(for: invocation,
                                      payload: .lines(lines.isEmpty ? [ToolTexts.emptyFolderLine] : lines),
                                      userSummary: summary)
        } catch {
            return ToolResult.failure(invocation,
                                      reason: ToolTextFormat.describe(error),
                                      error: error as? PocketAgentError)
        }
    }

    private func title(for invocation: ToolInvocation) -> String {
        invocation.path.isEmpty ? "Список файлов проекта" : "Список файлов в «\(invocation.path)»"
    }

    private func body(for listing: WorkspaceListing) -> String {
        guard !listing.entries.isEmpty else { return "Папка пуста" }
        var text = listing.entries.map(ToolTextFormat.entryLine).joined(separator: "\n")
        for warning in listing.warnings {
            text += "\n⚠️ \(warning)"
        }
        return text
    }
}

// MARK: - read_file

public struct WorkspaceReadFileTool: AgentTool {

    public let kind: ToolKind = .readFile

    public let details = ToolTexts.readFile

    public let parameters: [ToolParameterSpec] = [
        ToolParameterSpec(name: "path",
                          details: ToolTexts.readFilePath,
                          type: .string,
                          isRequired: true),
        // ⚠️ Оба параметра НЕОБЯЗАТЕЛЬНЫЕ. Модель на 2 млрд параметров про них забудет —
        // и получит ровно то же, что раньше: начало файла. Хуже не становится,
        // а схема стоит около 25 токенов.
        ToolParameterSpec(name: "from_line",
                          details: ToolTexts.readFileFromLine,
                          type: .integer,
                          isRequired: false),
        ToolParameterSpec(name: "to_line",
                          details: ToolTexts.readFileToLine,
                          type: .integer,
                          isRequired: false)
    ]

    private let workspace: any FileWorkspace

    /// Что из этих файлов модель уже получила за разговор.
    /// Тот же самый объект держит write_file — чтобы забыть файл сразу после правки.
    private let readHistory: ReadHistory

    public init(workspace: any FileWorkspace, readHistory: ReadHistory = ReadHistory()) {
        self.workspace = workspace
        self.readHistory = readHistory
    }

    public func preview(_ invocation: ToolInvocation) async throws -> ActionPreview {
        try requirePath(invocation)
        let range = try LineArguments.window(for: invocation, tool: kind)
        let file = try workspace.readText(relativePath: invocation.path, from: range.from, to: range.to)
        return .text(title: "Прочитать \(invocation.path)",
                     body: ToolTextFormat.head(Self.modelText(of: file), lines: 40))
    }

    public func execute(_ invocation: ToolInvocation) async throws -> ToolResult {
        do {
            try requirePath(invocation)
            let range = try LineArguments.window(for: invocation, tool: kind)

            // ⚠️ ГЛАВНОЕ МЕСТО ЭКОНОМИИ ПАМЯТИ РАЗГОВОРА. Модель сплошь и рядом просит
            // почти тот же кусок, что уже получила (живая переписка: строки 1–32,
            // потом 3–33, потом 4–33). Второй раз то же содержимое в память не уходит:
            // отдаём непрочитанное продолжение и одной строкой говорим об этом прямо.
            let remembered = historyEntry(for: invocation.path)
            let advice: ReadAdvice = remembered.map {
                readHistory.advice(for: $0.key,
                                   fingerprint: $0.fingerprint,
                                   from: range.from,
                                   to: range.to)
            } ?? .asAsked

            // Читать больше нечего — и сказать об этом честно дешевле, чем показать
            // ту же страницу по третьему разу. Это не отказ: ход засчитан, ошибки нет.
            if case .nothingLeft(let note) = advice {
                return ToolResult.success(
                    for: invocation,
                    payload: .fields(["path": invocation.path, "warning": note]),
                    userSummary: "\(invocation.path) уже прочитан целиком — второй раз не читаю"
                )
            }

            // Модель ходит по кругу: подряд просит только прочитанное. Дальше отвечать
            // «нечего читать» УСПЕХОМ нельзя — успешный ход сбрасывает счётчик кривых
            // ходов в цикле агента, и круг длится до предела шагов. Честный отказ этот
            // счётчик двигает, и задача останавливается сама, с понятным человеку текстом.
            if case .stuck(let note) = advice {
                // Человеку — своими словами: он читает ленту и должен понимать,
                // что происходит, а не разбирать приказ, адресованный модели.
                return ToolResult(invocationID: invocation.id,
                                  callID: invocation.callID,
                                  toolName: invocation.rawName,
                                  outcome: .failed,
                                  payload: .fields(["error": note]),
                                  userSummary: Self.goingInCirclesSummary(invocation.path))
            }

            var from = range.from
            var to = range.to
            var seenNote = ""
            if case .skipAhead(let next, let note) = advice {
                from = next
                // ⚠️ Конец диапазона от прежней просьбы к новому месту не относится:
                // он почти наверняка меньше нового начала, и чтение упало бы
                // на «конец диапазона раньше начала». Дальше решает размер страницы.
                to = nil
                seenNote = note
            }

            let file = try workspace.readText(relativePath: invocation.path, from: from, to: to)
            if let remembered { readHistory.note(file, key: remembered.key) }

            let text = Self.modelText(of: file)

            var fields = [
                "path": file.relativePath,
                "content": text
            ]
            // Показано не всё — модель обязана узнать об этом ЯВНО и в том же ответе,
            // вместе с готовым вызовом «как дочитать».
            if let notice = file.truncationNotice {
                fields["shown"] = Self.shownLine(for: file)
                fields["warning"] = seenNote + notice
            } else if !seenNote.isEmpty {
                fields["warning"] = seenNote
            }

            return ToolResult.success(
                for: invocation,
                payload: .fields(fields),
                // Показываем человеку НАЧАЛО прочитанного, а не только имя файла:
                // содержимое уходит в память модели, и он вправе видеть, что именно.
                userSummary: Self.humanPrefix(skipped: !seenNote.isEmpty)
                    + "\(Self.humanHeadline(for: file))\n"
                    + ToolTextFormat.head(text, lines: 5, characters: 300)
            )
        } catch {
            return ToolResult.failure(invocation,
                                      reason: ToolTextFormat.describe(error),
                                      error: error as? PocketAgentError)
        }
    }

    /// Забыть всё прочитанное. Зовётся, когда разговор с моделью начинается заново:
    /// показанных страниц у неё в памяти больше нет, и «ты это уже видел» станет ложью.
    public func forgetReadPages() {
        readHistory.forgetAll()
    }

    /// Прочитанная страница до модели НЕ доехала — снять пометку «показано».
    ///
    /// ⚠️ ЗАЧЕМ ЭТО НУЖНО СНАРУЖИ. Инструмент отдаёт страницу и тут же помечает её
    /// показанной, но между инструментом и моделью стоит цикл агента: он примеряет ответ
    /// к остатку памяти разговора и, если страница не влезает, отправляет модели ошибку
    /// «файл не помещается в память разговора» ВМЕСТО текста. Пометка тогда лгала:
    /// на следующую просьбу мы отвечали «строки 1–66 ты уже видел» и вели модель дальше,
    /// а начало файла становилось недостижимым до конца задачи. Кто выбросил содержимое —
    /// тот и снимает пометку; отсюда этот вызов.
    public func undoLastReadNote(path: String) {
        guard let remembered = historyEntry(for: path) else { return }
        readHistory.undoNote(key: remembered.key)
    }

    /// Ключ памяти о прочитанном и отпечаток файла на диске.
    /// nil — файла нет, путь ведёт наружу или это не наш случай: тогда читаем как обычно.
    ///
    /// ⚠️ Ключ — КАНОНИЧЕСКИЙ путь, поэтому «./README.md» и «README.md» — один файл.
    /// ⚠️ Заметку о проекте (AGENTS.md) в память не берём: её приложение перечитывает
    /// САМО перед каждой задачей, и это не ход модели. Иначе на первую же просьбу
    /// модели прочитать заметку мы ответили бы «ты её уже видел», хотя ей в разговор
    /// уходит только начало заметки, урезанное до трёхсот токенов.
    private func historyEntry(for path: String) -> (key: String, fingerprint: ReadHistory.Fingerprint)? {
        let name = (path as NSString).lastPathComponent
        guard name.caseInsensitiveCompare(AgentPrompt.projectNoteFileName) != .orderedSame else { return nil }

        guard let url = try? workspace.resolve(path),
              let size = CoordinatedFileIO.byteSize(of: url) else { return nil }

        return (url.path,
                ReadHistory.Fingerprint(byteSize: size,
                                        modified: CoordinatedFileIO.modificationDate(of: url)))
    }

    /// Человеку объясняем, почему показаны не те строки, которые просила модель.
    /// Модели про это говорит своя короткая строка — она вдвое короче этой.
    private static func humanPrefix(skipped: Bool) -> String {
        skipped ? "Это место уже читал, показываю дальше.\n" : ""
    }

    /// Что видит человек, когда модель третий раз подряд просит прочитанное.
    /// ⚠️ Без имён действий и без укоров: человеку важно понять, что приложение
    /// не зависло, а само остановило круг.
    private static func goingInCirclesSummary(_ path: String) -> String {
        let name = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = name.isEmpty ? "один и тот же файл" : "«\(name)»"
        return "Модель третий раз подряд просит \(what), хотя он уже прочитан целиком. "
            + "Прошу её перейти к делу."
    }

    /// Текст для модели: страница и целый файл — с номерами строк, оглавление — как есть
    /// (номера в нём уже проставлены при сборке).
    private static func modelText(of file: WorkspaceFile) -> String {
        guard file.view != .outline else { return file.text }
        guard !file.text.isEmpty else { return "" }
        return LineNumbering.render(DiffBuilder.splitLines(file.text)[...], firstNumber: file.firstLine)
    }

    private static func shownLine(for file: WorkspaceFile) -> String {
        switch file.view {
        case .whole:   return "весь файл, \(HumanFormat.lines(file.totalLineCount))"
        case .page:    return "строки \(file.firstLine)–\(file.lastLine) из \(file.totalLineCount)"
        case .outline: return "оглавление, в файле \(HumanFormat.lines(file.totalLineCount))"
        }
    }

    /// Строка для ленты чата: человек видит, что именно ушло в память модели.
    private static func humanHeadline(for file: WorkspaceFile) -> String {
        let size = ToolTextFormat.humanSize(file.byteSize)
        switch file.view {
        case .whole:
            return "Прочитан \(file.relativePath) — \(HumanFormat.lines(file.totalLineCount)), \(size)"
        case .page:
            return "Прочитан \(file.relativePath) — строки \(file.firstLine)–\(file.lastLine) "
                + "из \(file.totalLineCount), файл \(size)"
        case .outline:
            return "Прочитано оглавление \(file.relativePath) — "
                + "\(HumanFormat.lines(file.totalLineCount)) в файле, \(size)"
        }
    }

    private func requirePath(_ invocation: ToolInvocation) throws {
        guard !invocation.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PocketAgentError.missingArgument(tool: kind.rawValue, argument: "path")
        }
    }
}

// MARK: - write_file

/// ⚠️ Ядро продукта. preview() строит дифф и НИЧЕГО не пишет.
/// execute() пишет только то, что было в показанном диффе, и только если предпросмотр был.
public struct WorkspaceWriteFileTool: AgentTool {

    public let kind: ToolKind = .writeFile

    public let details = ToolTexts.writeFile

    public let parameters: [ToolParameterSpec] = [
        ToolParameterSpec(name: "path",
                          details: ToolTexts.writeFilePath,
                          type: .string,
                          isRequired: true),
        ToolParameterSpec(name: "content",
                          details: ToolTexts.writeFileContent,
                          type: .string,
                          isRequired: true),
        // ⚠️ Пятого инструмента нет и не будет: точечная правка живёт ВНУТРИ записи.
        // Без этих двух чисел write_file работает ровно как раньше — весь файл целиком
        // (так создаётся новый файл). С ними — заменяются только названные строки,
        // и файл любого размера становится доступен для правки: сегодня всё, что больше
        // примерно 2 КБ, модель поправить физически не может — её ответ туда не влезает.
        ToolParameterSpec(name: "from_line",
                          details: ToolTexts.writeFileFromLine,
                          type: .integer,
                          isRequired: false),
        ToolParameterSpec(name: "to_line",
                          details: ToolTexts.writeFileToLine,
                          type: .integer,
                          isRequired: false)
    ]

    private let workspace: any FileWorkspace
    private let pendingDiffs: PendingDiffStore

    /// Память о прочитанном — та же, что у read_file.
    /// ⚠️ ЗАЧЕМ ОНА ЗДЕСЬ. После записи текст на диске другой, а мы помним старый.
    /// Не забыть его — значит на следующую просьбу модели перечитать файл ответить
    /// «ты это уже видел» и не показать её же собственную правку. Свежесть дороже экономии.
    private let readHistory: ReadHistory

    /// Память о просмотренных папках — та же, что у list_files.
    /// ⚠️ ЗАЧЕМ ОНА ЗДЕСЬ. Записали файл — выдача папки изменилась, и глушить
    /// повторный просмотр как «ты это уже видел» стало бы прямым враньём: модель
    /// не увидела бы собственный только что созданный файл.
    private let listHistory: ListHistory

    /// `requiresPreview` — предохранитель: без показанного человеку диффа записи не будет.
    /// Выключать только в тестах.
    private let requiresPreview: Bool

    public init(workspace: any FileWorkspace,
                pendingDiffs: PendingDiffStore = PendingDiffStore(),
                readHistory: ReadHistory = ReadHistory(),
                listHistory: ListHistory = ListHistory(),
                requiresPreview: Bool = true) {
        self.workspace = workspace
        self.pendingDiffs = pendingDiffs
        self.readHistory = readHistory
        self.listHistory = listHistory
        self.requiresPreview = requiresPreview
    }

    // MARK: Предпросмотр — только чтение диска

    public func preview(_ invocation: ToolInvocation) async throws -> ActionPreview {
        let (path, content) = try arguments(invocation)

        // Дальше две дороги, и обе кончаются ОДНИМ И ТЕМ ЖЕ: показанным человеку диффом.
        // Замена по строкам отличается только тем, что полный текст файла собираем мы,
        // а не модель. Карточка, кнопка «Применить» и сверка файла перед записью — общие.
        let diff: FileDiff
        if let range = try Self.replacedLines(in: invocation) {
            diff = try workspace.diff(relativePath: path, replacingLines: range, with: content)
        } else {
            diff = try workspace.diff(relativePath: path, newText: content)
        }

        pendingDiffs.put(diff, for: invocation.id)
        return .diff(diff)
    }

    /// Какие строки модель просит заменить. nil — она их не называла, пишем файл целиком.
    private static func replacedLines(in invocation: ToolInvocation) throws -> ClosedRange<Int>? {
        let window = try LineArguments.window(for: invocation, tool: .writeFile)
        guard !window.isEmpty else { return nil }

        // Назван только конец — заменять «с начала файла по строку N» модель почти
        // наверняка не хотела. Это её обычная потеря аргумента, и молча угадывать здесь
        // нельзя: угадаешь неверно — сотрёшь начало файла.
        guard let from = window.from else {
            throw PocketAgentError.writeFailed(
                path: invocation.path,
                reason: "названа только to_line. Укажи и from_line — с какой строки заменять"
            )
        }
        // Конец не назван — заменяется ровно одна строка. Так короче всего сказать
        // «поправь вот эту строчку», а это самая частая правка.
        return from...(window.to ?? from)
    }

    // MARK: Запись — только после подтверждения человеком

    public func execute(_ invocation: ToolInvocation) async throws -> ToolResult {
        do {
            let (path, content) = try arguments(invocation)

            guard let approved = pendingDiffs.take(invocation.id) else {
                guard !requiresPreview else {
                    // Сюда попадаем в двух случаях, и оба обязаны кончиться отказом:
                    //  • кто-то позвал запись в обход карточки подтверждения;
                    //  • по этой же карточке уже писали — второе нажатие «Применить»
                    //    (двойной тап, повтор из ленты) не должно записать файл дважды.
                    throw PocketAgentError.writeFailed(
                        path: path,
                        reason: "это изменение не показано человеку или уже применено — "
                            + "повторная запись отменена"
                    )
                }
                // Путь без предпросмотра есть только в тестах, и полного текста файла
                // здесь взять неоткуда — записать один кусок вместо файла значило бы
                // стереть всё остальное. Отказываемся.
                let requestedRange = try Self.replacedLines(in: invocation)
                if requestedRange != nil {
                    throw PocketAgentError.writeFailed(
                        path: path,
                        reason: "замена по номерам строк идёт только через предпросмотр"
                    )
                }
                let file = try workspace.write(relativePath: path,
                                               newText: content,
                                               expecting: .unchecked)
                forgetReadPages(of: path)
                return ToolResult.success(for: invocation,
                                          payload: .fields(["path": file.relativePath, "status": "written"]),
                                          userSummary: "Записан \(file.relativePath)")
            }

            // Текст «до» и текст «после» совпадают побайтово — писать нечего.
            // Молча переписывать файл тем же содержимым нельзя: у файла поменяется дата,
            // а в системах контроля версий — ничего, и человек получит пустой коммит.
            if approved.isIdenticalToDisk {
                return ToolResult.success(
                    for: invocation,
                    payload: .fields([
                        "path": approved.relativePath,
                        "status": "unchanged"
                    ]),
                    userSummary: "Файл \(approved.relativePath) уже содержит ровно этот текст — ничего не записано"
                )
            }

            // Пишем ровно тот текст, который человек видел в диффе,
            // и только если файл на диске всё ещё тот, что был на момент показа.
            let file = try workspace.write(relativePath: approved.relativePath,
                                           newText: approved.newText,
                                           expecting: approved.writeExpectation)
            // Файл изменился — всё, что мы помнили о показанных из него строках, устарело.
            forgetReadPages(of: approved.relativePath)

            let what = approved.isNewFile ? "Создан" : "Изменён"
            return ToolResult.success(
                for: invocation,
                payload: .fields([
                    "path": file.relativePath,
                    "status": "written",
                    "added_lines": String(approved.addedCount),
                    "removed_lines": String(approved.removedCount)
                ]),
                userSummary: "\(what) \(file.relativePath) (+\(approved.addedCount) −\(approved.removedCount))"
            )
        } catch {
            // ⚠️ ЗАПИСЬ НЕ УДАЛАСЬ — РАЗРЕШАЕМ ПЕРЕЧИТАТЬ ФАЙЛ ЗАНОВО.
            // Иначе выходит запертая дверь, и она реально запиралась (замер 07.09.2026):
            // запись отклонена → модель идёт перечитать файл, чтобы взять чистый текст →
            // экономия памяти отвечает «ты это уже читал, второй раз не покажу» → модель
            // повторяет ту же ошибку до предела неверных ходов. Экономия памяти права
            // ровно до тех пор, пока у модели есть что-то на руках; после неудачной
            // записи считаем, что на руках у неё негодное, и лучше заплатить страницей
            // текста, чем похоронить задачу.
            forgetReadPages(of: invocation.path)

            // Тип ошибки несём с собой: «файл изменился снаружи» — это не кривой ход модели,
            // и наказывать её за него счётчиком неверных вызовов нельзя.
            return ToolResult.failure(invocation,
                                      reason: ToolTextFormat.describe(error),
                                      error: error as? PocketAgentError)
        }
    }

    // MARK: Забыть предпросмотр

    /// Человек нажал «Отклонить» или ход отменили: содержимое, от которого отказались,
    /// не должно лежать в памяти до вытеснения по счётчику.
    public func discardPreview(for invocationID: String) {
        _ = pendingDiffs.take(invocationID)
    }

    public func discardAllPreviews() {
        pendingDiffs.clear()
    }

    /// Забыть, какие строки этого файла модель уже видела.
    ///
    /// ⚠️ Ключ считаем ТЕМ ЖЕ способом, что и при чтении, — каноническим путём:
    /// иначе «./notes.md» после записи не совпало бы с «notes.md» при чтении,
    /// и модель получила бы старый текст вместо своей же правки. Путь не разобрался
    /// (файла нет, ведёт наружу) — забываем на всякий случай по всей памяти чтения:
    /// потерять экономию не страшно, отдать устаревший текст — страшно.
    private func forgetReadPages(of path: String) {
        // Папка, в которой файл появился или изменился, теперь выглядит иначе —
        // забываем её и всех её родителей, иначе повторный просмотр будет заглушен
        // как «ты это уже видел», и модель не увидит собственную правку.
        listHistory.forget(path: path)
        guard let url = try? workspace.resolve(path) else {
            readHistory.forgetAll()
            return
        }
        readHistory.forget(key: url.path)
    }

    // MARK: Разбор аргументов

    private func arguments(_ invocation: ToolInvocation) throws -> (path: String, content: String) {
        let path = invocation.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw PocketAgentError.missingArgument(tool: kind.rawValue, argument: "path")
        }
        // Пустое содержимое — законный случай (создать пустой файл), поэтому проверяем наличие ключа,
        // а не непустоту значения.
        guard let content = invocation.content else {
            throw PocketAgentError.missingArgument(tool: kind.rawValue, argument: "content")
        }

        // ⚠️ МОДЕЛЬ ВЕРНУЛА НАШ ЖЕ ВЫВОД ВМЕСТЕ С НОМЕРАМИ СТРОК — СНИМАЕМ ИХ И РАБОТАЕМ.
        //
        // Раньше здесь стоял отказ с объяснением «пришли только сам текст». Замер на
        // телефоне 07.09.2026 показал, что объяснение не работает и заводит в тупик,
        // причём одинаково во всех трёх прогонах задачи «допиши строку в README.md»:
        //   1) модель читает файл и получает текст с номерами («3| Проект называется…»);
        //   2) шлёт его обратно в write_file вместе с номерами — отказ;
        //   3) идёт перечитать файл, чтобы взять чистый текст, — а там её встречает
        //      ВТОРАЯ наша защита: «уже прочитан целиком, второй раз не читаю»;
        //   4) круг повторяется до предела неверных ходов, файл не тронут, а в итоге
        //      модель ещё и рапортует «строка добавлена».
        // То есть две правильные поодиночке защиты вместе давали запертую дверь.
        //
        // Снимать номера безопасно, потому что `looksNumbered` придирчива до предела:
        // совпасть должна КАЖДАЯ строка и номера обязаны идти ровно подряд — так
        // выглядит только наша собственная выдача. И главное: снятие номеров ничего
        // не записывает само по себе. Дальше всё идёт обычной дорогой — человек видит
        // карточку «до и после» и решает. Ошибись мы на редком файле вида «1|Иван|20» —
        // это будет видно в карточке ДО записи, и её просто отклонят.
        if LineNumbering.looksNumbered(content) {
            return (path, LineNumbering.strip(content))
        }
        return (path, content)
    }
}

// MARK: - finish

public struct WorkspaceFinishTool: AgentTool {

    public let kind: ToolKind = .finish

    public let details = ToolTexts.finish

    public let parameters: [ToolParameterSpec] = [
        ToolParameterSpec(name: "summary",
                          details: ToolTexts.finishSummary,
                          type: .string,
                          isRequired: true)
    ]

    public init() {}

    public func preview(_ invocation: ToolInvocation) async throws -> ActionPreview {
        .text(title: "Задача завершена", body: text(for: invocation))
    }

    public func execute(_ invocation: ToolInvocation) async throws -> ToolResult {
        let summary = text(for: invocation)
        return ToolResult.success(for: invocation,
                                  payload: .text(summary),
                                  userSummary: summary)
    }

    private func text(for invocation: ToolInvocation) -> String {
        let summary = invocation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "Готово." : summary
    }
}

// MARK: - Сборка четвёрки

public enum FileTools {

    /// Все четыре инструмента поверх одной рабочей папки.
    /// `pendingDiffs` общий — его же можно очистить при сбросе разговора.
    ///
    /// ⚠️ Память о прочитанном тоже ОБЩАЯ у чтения и записи, и это обязательно:
    /// чтение её пополняет, запись — сбрасывает по изменённому файлу. Раздай им
    /// по своему экземпляру — и после правки модель получит устаревший текст.
    public static func makeAll(workspace: any FileWorkspace,
                               pendingDiffs: PendingDiffStore = PendingDiffStore(),
                               readHistory: ReadHistory = ReadHistory(),
                               listHistory: ListHistory = ListHistory()) -> [any AgentTool] {
        [
            WorkspaceListFilesTool(workspace: workspace, listHistory: listHistory),
            WorkspaceReadFileTool(workspace: workspace, readHistory: readHistory),
            WorkspaceWriteFileTool(workspace: workspace,
                                   pendingDiffs: pendingDiffs,
                                   readHistory: readHistory,
                                   listHistory: listHistory),
            WorkspaceFinishTool()
        ]
    }
}

// MARK: - Имена из архитектурной карты

// В карте инструменты названы без приставки Workspace. Псевдонимы держат обе записи
// рабочими, чтобы карта и код не разъезжались из-за одного слова в имени.
public typealias ListFilesTool = WorkspaceListFilesTool
public typealias ReadFileTool  = WorkspaceReadFileTool
public typealias WriteFileTool = WorkspaceWriteFileTool
public typealias FinishTool    = WorkspaceFinishTool
