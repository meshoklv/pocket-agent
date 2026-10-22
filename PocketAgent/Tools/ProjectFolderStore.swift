//
//  ProjectFolderStore.swift
//  PocketAgent
//
//  Владелец выбранной пользователем папки: security-scoped доступ + закладка,
//  которая переживает перезапуск приложения.
//
//  ⚠️ ГЛАВНОЕ ПРО iOS:
//  .withSecurityScope при СОЗДАНИИ и при РЕЗОЛВЕ закладки в Swift объявлен ТОЛЬКО для macOS
//  и Mac Catalyst. Под iOS проект с ним просто не соберётся. Здесь его нет и быть не должно —
//  закладка без явного scope сама несёт implicit ephemeral security scope, этого достаточно.
//
//  ⚠️ БАЛАНС start/stop:
//  с iOS 14.2 резолв закладки САМ неявно зовёт startAccessingSecurityScopedResource.
//  Поэтому резолвим с .withoutImplicitStartAccessing и стартуем вручную — тогда пар ровно 1:1.
//  Забыть stop = утечка kernel-ресурсов, после которой приложение перестаёт открывать
//  любые папки ДО ПЕРЕЗАПУСКА. Поэтому все ранние выходы закрыты через defer.
//

import Foundation

@MainActor
public final class ProjectRoot: ProjectFolderStore {

    /// Общий экземпляр — доступ к папке в приложении ровно один.
    public static let shared = ProjectRoot()

    // MARK: - Состояние

    public private(set) var current: ProjectFolder?

    /// Открыт ли сейчас security-scoped доступ (нужно для честного парного stop).
    public private(set) var isAccessing = false

    /// URL, на котором реально был вызван start. Именно на нём обязан быть вызван stop.
    private var accessedURL: URL?

    private let defaults: UserDefaults
    private let bookmarkKey: String

    public init(defaults: UserDefaults = .standard,
                bookmarkKey: String = "pocketagent.project.root.bookmark") {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
    }

#if DEBUG
    // ⚠️⚠️ ТОЛЬКО ДЛЯ ЗАМЕРА, И ВОТ ЗАЧЕМ ЭТО ПОЯВИЛОСЬ 09.09.2026.
    // Замер раскладывает свою папку и принимает её ровно тем же `adopt`, что и человек, —
    // а `adopt` ПЕРЕЗАПИСЫВАЕТ сохранённую закладку. То есть каждый прогон замера
    // молча отбирал у владельца выбранную им папку: после прогона приложение открывалось
    // не на его проекте, а на служебной папке замера, и он выбирал свою заново, не
    // понимая почему. Поймано числами: прогон «в настоящей папке владельца» показал
    // содержимое папки ЗАМЕРА, потому что закладку до этого перетёр обычный прогон.
    // Теперь замер обязан снять закладку до работы и вернуть её после.
    var savedBookmark: Data? { defaults.data(forKey: bookmarkKey) }

    func restoreSavedBookmark(_ data: Data) { defaults.set(data, forKey: bookmarkKey) }
#endif

    deinit {
        // ⚠️ Здесь читаются ХРАНИМЫЕ свойства класса, изолированного к MainActor.
        // При SWIFT_VERSION 5.0 + strict concurrency = minimal (как в project.yml) это
        // разрешено. При переходе на язык Swift 6 deinit придётся переписать:
        // либо isolated deinit, либо освобождать доступ только через явный release()
        // из AppViewModel (он уже зовёт его при уходе в фон). См. BUILD.md.
        if isAccessing, let url = accessedURL {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Выбор новой папки

    /// Принять URL из fileImporter: открыть доступ, сохранить закладку.
    @discardableResult
    public func adopt(pickedURL: URL) throws -> ProjectFolder {
        // ⚠️ Служебную папку нельзя брать КОРНЕМ проекта.
        // Защита SafePath смотрит на путь ОТНОСИТЕЛЬНО корня: выбери человек корнем
        // сам `/Repo/.git` (или `~/.ssh`) — имя `.git` в относительный путь не попадёт
        // вовсе, и агент спокойно прочитал бы `config`, `HEAD`, `packed-refs`.
        try Self.ensureNotProtectedFolder(pickedURL)

        // URL из пикера — security-scoped. Без start не прочитается даже список файлов.
        let started = pickedURL.startAccessingSecurityScopedResource()

        // Всё, что не дошло до успеха, обязано отпустить ресурс — иначе течём.
        var accepted = false
        defer {
            if !accepted && started {
                pickedURL.stopAccessingSecurityScopedResource()
            }
        }

        // start вернул false — это не всегда отказ: у не-scoped URL (папка самого приложения)
        // он тоже false. Проверяем фактом: читается ли папка.
        if !started && !isReadableDirectory(pickedURL) {
            throw PocketAgentError.folderAccessDenied
        }

        let bookmark: Data
        do {
            // options: [] — НИКОГДА не .withSecurityScope, он macOS-only в Swift.
            bookmark = try pickedURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil, // TODO(API): у URL тип Set<URLResourceKey>?, nil подходит обоим
                relativeTo: nil
            )
        } catch {
            throw PocketAgentError.bookmarkUnusable
        }

        // Предыдущую папку отпускаем ТОЛЬКО когда новая уже точно принята
        releaseAccess()

        let folder = ProjectFolder(url: pickedURL,
                                   bookmark: bookmark,
                                   displayName: displayName(for: pickedURL),
                                   adoptedAt: Date())
        defaults.set(bookmark, forKey: bookmarkKey)
        current = folder
        accessedURL = pickedURL
        isAccessing = started
        accepted = true
        return folder
    }

    // MARK: - Восстановление при следующем запуске

    /// Восстановить папку по закладке. nil — надо просить выбрать заново.
    @discardableResult
    public func restore() -> ProjectFolder? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }

        var isStale = false
        let resolved: URL
        do {
            // .withSecurityScope тут ТОЖЕ macOS-only — не передаём.
            // .withoutImplicitStartAccessing гасит неявный старт, чтобы баланс был ручной и предсказуемый.
            resolved = try URL(
                resolvingBookmarkData: data,
                options: [.withoutImplicitStartAccessing], // TODO(API): проверить на устройстве, что явный start после этого открывает доступ
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            defaults.removeObject(forKey: bookmarkKey)
            return nil
        }

        var started = resolved.startAccessingSecurityScopedResource()
        var accepted = false
        var url = resolved
        defer {
            if !accepted && started {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if !started && !isReadableDirectory(resolved) {
            // ⚠️ Запасной путь. Документация Apple на .withoutImplicitStartAccessing
            // сама себе противоречит: в описании сказано «неявного старта НЕ будет»,
            // а в обсуждении на той же странице — «опция вызывает неявный старт».
            // Если верна вторая формулировка, наш ручной start уже второй по счёту
            // и вернуть true не обязан. Тогда резолвим ещё раз БЕЗ опции и полагаемся
            // на неявный старт, руками ничего не открывая — иначе счётчик уйдёт в +2
            // и один stop его не отпустит (это и есть та утечка, после которой
            // приложение перестаёт открывать любые папки до перезапуска).
            var staleAgain = false
            if let fallback = try? URL(resolvingBookmarkData: data,
                                       options: [],
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &staleAgain),
               isReadableDirectory(fallback) {
                url = fallback
                isStale = staleAgain
                started = true          // доступ открыт неявно резолвом
            } else {
                // Доступ потерян (папку удалили, провайдер отключили) — закладку выбрасываем.
                defaults.removeObject(forKey: bookmarkKey)
                return nil
            }
        }

        // Та же проверка, что и при выборе: закладка могла быть сохранена ещё до неё.
        do {
            try Self.ensureNotProtectedFolder(url)
        } catch {
            defaults.removeObject(forKey: bookmarkKey)
            return nil
        }

        let opened = url
        releaseAccess()

        // isStale — не поломка: URL рабочий, надо просто перезаписать закладку,
        // пока доступ ещё открыт.
        var bookmark = data
        if isStale {
            if let fresh = try? opened.bookmarkData(options: [],
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) {
                bookmark = fresh
                defaults.set(fresh, forKey: bookmarkKey)
            }
            // Перезаписать не смогли — текущую сессию доработаем на уже открытом доступе.
        }

        let folder = ProjectFolder(url: opened,
                                   bookmark: bookmark,
                                   displayName: displayName(for: opened),
                                   adoptedAt: Date())
        current = folder
        accessedURL = opened
        isAccessing = started
        accepted = true
        return folder
    }

    // MARK: - Отпускание доступа

    /// Отдать доступ, но помнить папку (для показа имени и последующего restore()).
    /// Обязателен при уходе приложения в фон.
    public func release() {
        releaseAccess()
    }

    /// Забыть папку совсем (смена проекта).
    public func forget() {
        releaseAccess()
        current = nil
        defaults.removeObject(forKey: bookmarkKey)
    }

    /// Вернуть доступ после фона.
    ///
    /// ⚠️ Сначала пробуем открыть доступ НА ТОМ ЖЕ объекте URL, который уже лежит в `current`.
    /// Это важно: инструменты держат корень внутри себя, и если URL пересоздать из закладки,
    /// они останутся работать по объекту, у которого пара start/stop уже закрыта.
    /// Пересоздали URL — сообщаем об этом отдельно (.replaced), чтобы сессию собрали заново.
    @discardableResult
    public func resumeAccess() -> FolderResume {
        if isAccessing, let folder = current { return .same(folder) }

        if let folder = current {
            let started = folder.url.startAccessingSecurityScopedResource()
            if started || isReadableDirectory(folder.url) {
                accessedURL = folder.url
                isAccessing = started
                return .same(folder)
            }
            // Не открылся — отпускаем то, что могли занять, и идём длинным путём.
            if started { folder.url.stopAccessingSecurityScopedResource() }
        }

        guard let restored = restore() else { return .lost }
        return .replaced(restored)
    }

    // MARK: - Рабочая обёртка для инструментов

    public func makeWorkspace() throws -> any FileWorkspace {
        guard let folder = current else { throw PocketAgentError.noProjectFolder }
        guard isAccessing || isReadableDirectory(folder.url) else {
            throw PocketAgentError.folderAccessDenied
        }
        return SecurityScopedWorkspace(root: folder.url)
    }

    // MARK: - Внутреннее

    /// Единственное место, где вызывается stopAccessingSecurityScopedResource.
    private func releaseAccess() {
        if isAccessing, let url = accessedURL {
            url.stopAccessingSecurityScopedResource()
        }
        isAccessing = false
        accessedURL = nil
    }

    /// Служебная папка (.git, .ssh, .aws…) корнем проекта быть не может.
    /// Список — тот же самый, что закрывает эти папки внутри проекта: два списка
    /// разъехались бы при первой же правке.
    private static func ensureNotProtectedFolder(_ url: URL) throws {
        let name = url.lastPathComponent
        guard SafePath.protectedDirectoryNames.contains(name.lowercased()) else { return }
        throw PocketAgentError.protectedFolderChosen(name)
    }

    /// Дешёвая проверка «папка на месте и читается».
    ///
    /// ⚠️ РАНЬШЕ ЗДЕСЬ БЫЛ `contentsOfDirectory` — то есть перечисление ВСЕГО содержимого
    /// выбранной папки, и на главном потоке: при запуске, при выборе папки и при каждом
    /// возврате из фона. На папке с node_modules или на медленном файл-провайдере
    /// (iCloud Drive, Working Copy) это секунды заморозки, а иногда и отстрел приложения
    /// сторожевым таймером прямо на старте. Спрашиваем ровно два признака у файловой
    /// системы — это один вызов, а не обход дерева.
    private func isReadableDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey]),
              values.isDirectory == true else {
            return false
        }
        // isReadable иногда не приезжает у файл-провайдера — считаем это «читается»,
        // а настоящую проверку доступа делает первая же работа с файлами.
        return values.isReadable ?? true
    }

    private func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}
