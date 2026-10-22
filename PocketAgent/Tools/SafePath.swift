//
//  SafePath.swift
//  PocketAgent
//
//  КРИТИЧЕСКИЙ модуль безопасности.
//  Превращает путь, который назвала модель, в URL ВНУТРИ выбранной папки.
//  Любая попытка уйти наружу (../, ведущий /, симлинк) — ошибка, а не «почти правильный» путь.
//
//  Три отдельные дыры, которые здесь закрыты:
//    1) "../../.." — схлопывается лексически через standardizedFileURL;
//    2) "/etc/passwd" — ведущие слэши срезаются, абсолютный путь не склеивается;
//    3) симлинк внутри папки, ведущий наружу — снимается resolvingSymlinksInPath.
//  Сравнение — по МАССИВУ pathComponents, а не по строковому префиксу:
//  hasPrefix пропустил бы "/Root" -> "/RootEvil", и наоборот ломался бы на /var -> /private/var.
//

import Foundation

public enum SafePath {

    /// Терпеть ли лишнее имя папки проекта в начале пути (см. `resolve`).
    ///
    /// ⚠️ ЭТО НЕ НАСТРОЙКА ПРИЛОЖЕНИЯ И НЕ ВЫКЛЮЧАТЕЛЬ ДЛЯ ЧЕЛОВЕКА. Значение всегда
    /// `true`, и меняет его ровно одно место на всё приложение — замер (`Bench/`),
    /// когда снимает эту правку, чтобы получить честное число «как было ДО» на том же
    /// телефоне и той же модели. В сборку для магазина замер не попадает вовсе.
    public static var tolerateRedundantProjectPrefix = true

    // MARK: - Служебные папки, куда запись запрещена всегда

    /// Имена папок, внутрь которых мы не пускаем ни при каких условиях — ни на запись, ни на чтение.
    /// .git — история репозитория: одна запись модели туда ломает проект необратимо,
    /// а одно чтение .git/config уводит токен доступа к репозиторию прямо в контекст модели.
    public static let protectedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", ".ssh",
        // Учётные данные облаков и инструментов лежат ровно здесь.
        ".aws", ".gnupg", ".kube", ".docker", ".terraform"
    ]

    /// Файлы с секретами. Читать их модели нельзя: содержимое уедет в контекст и в историю
    /// разговора, а человек в ленте увидит только строку «прочитан файл».
    /// Плюс это готовый канал внушения: чужой текст становится инструкцией для модели.
    public static let protectedFileNames: Set<String> = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".netrc", ".npmrc", ".pgpass",
        // Частые носители секретов, которых раньше в списке не было.
        ".gitconfig", ".git-credentials", ".pypirc", ".yarnrc", ".yarnrc.yml", ".dockercfg",
        "credentials", "secrets.json", "secrets.yml", "secrets.yaml",
        "service-account.json", "serviceaccount.json", "google-services.json",
        "gradle.properties", "keystore.properties"
    ]

    /// Расширения секретов.
    public static let protectedFileExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "keystore", "jks", "asc",
        // Ключи и профили выпуска приложений.
        "p8", "mobileprovision", "provisionprofile", "cer", "der", "crt", "ppk"
    ]

    /// Имя файла похоже на секрет: .env, .env.local, id_ed25519, ключ, сертификат.
    public static func isProtectedFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if protectedFileNames.contains(lower) { return true }
        if lower == ".env" || lower.hasPrefix(".env.") || lower.hasSuffix(".env") { return true }
        let ext = (lower as NSString).pathExtension
        return protectedFileExtensions.contains(ext)
    }

    // MARK: - Канонизация

    /// Канонический вид пути: сняты симлинки (/var -> /private/var) и схлопнуты «.» и «..».
    /// Канонизировать нужно ОБЕ стороны сравнения, иначе получим ложный «выход за папку».
    public static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Разбирает путь от модели в безопасный список компонентов.
    /// Здесь же обезвреживается абсолютный путь и обратные слэши.
    /// - Throws: `.pathEscapesRoot`, если в пути есть управляющие символы или нулевой байт.
    public static func sanitizeComponents(_ rawPath: String) throws -> [String] {
        // Нулевой байт и управляющие символы отклоняем ЦЕЛИКОМ, а не вычищаем:
        // Foundation обрезает путь по NUL, и тогда файл записался бы не туда,
        // куда показала карточка подтверждения («notes.txt\0.png» → «notes.txt»).
        if rawPath.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw PocketAgentError.pathEscapesRoot(rawPath)
        }

        var text = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // Модель иногда присылает URL целиком
        if text.lowercased().hasPrefix("file://") {
            text = String(text.dropFirst("file://".count))
            text = text.removingPercentEncoding ?? text
        }

        // Windows-разделители приводим к обычным
        text = text.replacingOccurrences(of: "\\", with: "/")

        // Ведущие слэши: "/etc/passwd" не должен превратиться в абсолютный путь
        while text.hasPrefix("/") { text.removeFirst() }

        // Домашняя тильда — тоже попытка уйти наружу, просто отбрасываем её как компонент.
        // Компоненты из одних пробелов тоже отбрасываем: имя " " ведёт себя непредсказуемо.
        return text
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { component in
                component != "." && component != "~"
                    && !component.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }

    // MARK: - Главная функция

    /// Путь от модели → безопасный URL внутри корня.
    /// - Parameters:
    ///   - rawPath: то, что назвала модель (может быть каким угодно).
    ///   - root: корень проекта (канонизируется здесь же).
    ///   - allowRoot: разрешено ли указывать сам корень (для list_files — да, для read/write — нет).
    /// - Throws: `PocketAgentError.pathEscapesRoot` при любой попытке выйти наружу,
    ///           `PocketAgentError.emptyPath` если путь пуст, а корень не разрешён.
    public static func resolve(_ rawPath: String,
                               root: URL,
                               allowRoot: Bool = true) throws -> URL {
        let canonicalRoot = canonical(root)
        let components = try sanitizeComponents(rawPath)

        if components.isEmpty {
            guard allowRoot else { throw PocketAgentError.emptyPath }
            return canonicalRoot
        }

        // ⚠️ САМАЯ ЧАСТАЯ ПРИЧИНА «ФАЙЛА НЕТ» НА ЖИВОМ ТЕЛЕФОНЕ — ЛИШНЕЕ ИМЯ ПАПКИ
        // В НАЧАЛЕ ПУТИ. Разбор переписок владельца (10.08.2026): list_files честно
        // показывает «README.md», а следом модель зовёт read_file
        // («sima-profile-main/README.md») — приклеивает спереди имя самой папки
        // проекта. Оно и понятно: это имя стоит у неё в инструкции первой строкой
        // («Правишь файлы только внутри папки «sima-profile-main»»), и «путь от корня»
        // модель на 2–4 млрд параметров понимает как «от корня вместе с корнем».
        // Дальше всё разваливалось: отказ, повтор того же вызова, и в конце модель
        // пересказывала проект по ОДНИМ ИМЕНАМ файлов, ничего не открыв.
        //
        // Терпим ровно один такой лишний ведущий сегмент, равный имени корневой папки.
        // Это НЕ ослабление защиты: мы только УБИРАЕМ сегмент, никогда не добавляем,
        // и оба кандидата проходят одну и ту же проверку выхода за корень ниже.
        //
        // ⚠️ ОТДЕЛЬНО — СЛУЧАЙ «ПУТЬ = ИМЯ САМОЙ ПАПКИ», И ОН НЕ РЕДКОСТЬ, А САМЫЙ ЧАСТЫЙ
        // ПЕРВЫЙ ХОД. Замер на телефоне 07.09.2026: на задачу «Прочитай README.md и скажи,
        // как называется проект» модель ТРИ раза из трёх начинала с list_files("sklad-main") —
        // то есть просила показать саму рабочую папку по имени. Ответ «не найден», повтор
        // того же вызова, и задача умирала на пределе неверных ходов, ни разу не открыв
        // файл. Здесь после снятия лишнего сегмента не остаётся НИЧЕГО, а пустой путь —
        // это и есть корень проекта: ровно то, что модель и просила показать.
        // Поэтому пустой остаток допускаем, но только там, где корень вообще разрешён
        // (список файлов — да; читать или писать сам корень нельзя, он папка, а не файл).
        var candidateLists: [[String]] = [components]
        if tolerateRedundantProjectPrefix,
           let first = components.first,
           first.caseInsensitiveCompare(canonicalRoot.lastPathComponent) == .orderedSame {
            let rest = Array(components.dropFirst())
            if !rest.isEmpty || allowRoot {
                candidateLists.append(rest)
            }
        }

        // Выбираем между «как прислала модель» и «без лишнего имени папки» ПО ДИСКУ,
        // а не по догадке: сам файл существует — берём его; для новой записи смотрим,
        // у какого варианта существует папка-родитель. Если не подошло ничто —
        // остаёмся при том, что прислала модель, и ошибка будет про её путь.
        var firstValid: URL?
        var parentExists: URL?
        for list in candidateLists {
            guard let url = try? buildTarget(list,
                                             canonicalRoot: canonicalRoot,
                                             allowRoot: allowRoot,
                                             rawPath: rawPath)
            else { continue }

            if FileManager.default.fileExists(atPath: url.path) { return url }
            if firstValid == nil { firstValid = url }
            if parentExists == nil,
               isExistingDirectory(url.deletingLastPathComponent()) {
                parentExists = url
            }
        }
        if let parentExists { return parentExists }
        if let firstValid { return firstValid }

        // Ни один кандидат не построился — пусть бросит ошибку исходный путь модели,
        // чтобы в тексте отказа стояло ровно то, что она просила.
        return try buildTarget(components,
                               canonicalRoot: canonicalRoot,
                               allowRoot: allowRoot,
                               rawPath: rawPath)
    }

    /// Склеить компоненты с корнем и провести ВСЕ проверки безопасности.
    /// Вынесено из `resolve`, чтобы одни и те же проверки прошёл каждый кандидат пути.
    private static func buildTarget(_ components: [String],
                                    canonicalRoot: URL,
                                    allowRoot: Bool,
                                    rawPath: String) throws -> URL {
        // Склеиваем покомпонентно и схлопываем «..» ЛЕКСИЧЕСКИ
        var candidate = canonicalRoot
        for component in components {
            candidate = candidate.appendingPathComponent(component)
        }
        candidate = candidate.standardizedFileURL

        // Сам последний компонент не должен быть символьной ссылкой — ни живой, ни висячей.
        // fileExists() ходит ПО ссылке, поэтому висячий симлинк выглядел бы как «файла нет»,
        // и запись затёрла бы саму ссылку, показав человеку карточку «новый файл».
        if isSymbolicLink(candidate) {
            throw PocketAgentError.pathEscapesRoot(rawPath)
        }

        // ⚠️ ДЫРА, НАЙДЕННАЯ 08.09.2026 ПРОВЕРКОЙ tools/safepath-probe. Раньше здесь
        // раскрывались только ссылки у СУЩЕСТВУЮЩИХ путей. Из-за этого
        // «ссылка-на-чужую-папку/НОВАЯ-подпапка/файл.txt» проходил насквозь: весь путь
        // не существует, раскрывать нечего, проверка довольна — а запись потом сама
        // создаёт промежуточные папки, идёт ПО ссылке и кладёт файл ВНЕ папки проекта.
        // Проверено живьём: файл физически появлялся в чужой папке.
        //
        // Поэтому идём от корня вниз и запрещаем ссылку на ЛЮБОМ шаге, а не только
        // в конце. Ссылки мы не разворачиваем принципиально: «наружу нельзя» должно
        // читаться как «нельзя», а не «нельзя, если система успела заметить».
        var walk = canonicalRoot
        for component in components {
            walk = walk.appendingPathComponent(component)
            if isSymbolicLink(walk) {
                throw PocketAgentError.pathEscapesRoot(rawPath)
            }
        }

        // Снимаем симлинки. Для НЕсуществующего файла (создаём новый) resolvingSymlinksInPath
        // не трогает последний компонент — поэтому резолвим родителя и приклеиваем имя.
        let target: URL
        if FileManager.default.fileExists(atPath: candidate.path) {
            target = canonical(candidate)
        } else {
            let parent = canonical(candidate.deletingLastPathComponent())
            target = parent
                .appendingPathComponent(candidate.lastPathComponent)
                .standardizedFileURL
        }

        // Сравнение по компонентам, не по строке
        let rootParts = canonicalRoot.pathComponents
        let targetParts = target.pathComponents
        guard targetParts.count >= rootParts.count,
              Array(targetParts.prefix(rootParts.count)) == rootParts
        else {
            throw PocketAgentError.pathEscapesRoot(rawPath)
        }

        if !allowRoot && targetParts.count == rootParts.count {
            throw PocketAgentError.emptyPath
        }

        return target
    }

    /// Путь для ЗАПИСИ: корень запрещён, служебные папки запрещены,
    /// поверх записать существующую папку тоже нельзя.
    public static func resolveForWriting(_ rawPath: String, root: URL) throws -> URL {
        let target = try resolve(rawPath, root: root, allowRoot: false)
        try ensureNotProtected(target, root: root, rawPath: rawPath)

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw PocketAgentError.writeFailed(path: rawPath, reason: "по этому пути находится папка")
        }
        return target
    }

    /// Путь для ЧТЕНИЯ файла: корень запрещён (корень — это папка, а не файл),
    /// служебные папки и файлы с секретами запрещены так же, как на запись.
    /// ⚠️ Раньше защита стояла ТОЛЬКО на записи, и read_file(".git/config") проходил:
    /// токен доступа к репозиторию уезжал в контекст модели, а человек видел в ленте
    /// только строку «прочитан файл».
    public static func resolveForReading(_ rawPath: String, root: URL) throws -> URL {
        let target = try resolve(rawPath, root: root, allowRoot: false)
        try ensureNotProtected(target, root: root, rawPath: rawPath)
        return target
    }

    // MARK: - Служебные проверки

    /// Бросает ошибку, если путь ведёт в .git и подобные служебные папки
    /// или указывает на файл, похожий на секрет (.env, ключи, сертификаты).
    public static func ensureNotProtected(_ url: URL, root: URL, rawPath: String) throws {
        let components = relativeComponents(of: url, root: root)

        for component in components {
            if protectedDirectoryNames.contains(component.lowercased()) {
                throw PocketAgentError.pathIsProtected(rawPath)
            }
        }

        if let name = components.last, isProtectedFileName(name) {
            throw PocketAgentError.pathIsProtected(rawPath)
        }
    }

    /// Является ли последний компонент символьной ссылкой (по lstat, не по цели).
    public static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

    /// Существует ли по этому пути ПАПКА. Нужно выбору между «путём как прислала
    /// модель» и «путём без лишнего имени папки проекта»: для файла, которого ещё нет,
    /// единственный признак правильного места — существующая папка-родитель.
    public static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    /// Лежит ли URL внутри корня (без бросания ошибки).
    public static func isInside(_ url: URL, root: URL) -> Bool {
        let rootParts = canonical(root).pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= rootParts.count else { return false }
        return Array(parts.prefix(rootParts.count)) == rootParts
    }

    /// Компоненты пути относительно корня.
    public static func relativeComponents(of url: URL, root: URL) -> [String] {
        relativeComponents(of: url, rootComponents: canonical(root).pathComponents)
    }

    /// То же самое, но с заранее посчитанными компонентами корня.
    /// В обходе папки это важно: canonical() лезет на диск, а вызывается он на каждый файл.
    public static func relativeComponents(of url: URL, rootComponents: [String]) -> [String] {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootComponents.count,
              Array(parts.prefix(rootComponents.count)) == rootComponents
        else { return [] }
        return Array(parts.suffix(from: rootComponents.count))
    }

    /// Путь относительно корня в человеческом виде: "src/main.swift".
    public static func relativePath(of url: URL, root: URL) -> String {
        relativeComponents(of: url, root: root).joined(separator: "/")
    }

    public static func relativePath(of url: URL, rootComponents: [String]) -> String {
        relativeComponents(of: url, rootComponents: rootComponents).joined(separator: "/")
    }
}

/// Имя из архитектурной карты — оставлено, чтобы соседние модули могли писать PathGuard.
public typealias PathGuard = SafePath
