//
//  ModelSpec.swift
//  PocketAgent / Runtime
//
//  Активная модель приложения: та, с которой оно работает прямо сейчас.
//
//  ⚠️ ГЛАВНОЕ ИЗМЕНЕНИЕ (09.08.2026). Раньше здесь стояла жёсткая строчка
//  «активная модель = единственная модель из справочника», и передать другую было НЕЧЕМ:
//  установка из файла принимала описание модели только значением по умолчанию.
//  Отсюда и росла жалоба владельца — приложение принимало ровно один файл.
//  Теперь активная модель — это ВЫБОР, который живёт между запусками:
//  человек указал файл, приложение запомнило его и работает с ним.
//
//  ⚠️ Путь к файлу хранится ОТНОСИТЕЛЬНО домашней папки приложения, а не целиком.
//  Полный путь содержит опознаватель установки, который меняется при переустановке
//  приложения: сохранённый полный путь после этого указывает в никуда, и модель
//  «пропадает» без всякой причины.
//

import Foundation

// MARK: - Выбранная модель

/// Что человек выбрал: описание модели и где лежит её файл.
public struct ActiveModelChoice: Sendable, Equatable, Codable {

    /// Описание модели — из справочника, если она узнана, иначе собранное по самому файлу.
    public let descriptor: ModelDescriptor

    /// Путь файла ОТНОСИТЕЛЬНО домашней папки приложения
    /// («Documents/gemma-4-E4B-it.litertlm» и подобное).
    /// nil — файл лежит там, где приложение и так его ищет.
    public let relativePath: String?

    /// Когда выбрали — для показа в «О программе».
    public let chosenAt: Date

    public init(descriptor: ModelDescriptor, relativePath: String?, chosenAt: Date = Date()) {
        self.descriptor = descriptor
        self.relativePath = relativePath
        self.chosenAt = chosenAt
    }

    /// Полный путь к файлу, собранный заново от нынешней домашней папки.
    public var fileURL: URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath)
    }

    /// Файл на месте прямо сейчас? Человек мог удалить его из «Файлов».
    public var isFilePresent: Bool {
        guard let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Путь внутри песочницы приложения — в том виде, в каком его можно хранить.
    /// nil — файл лежит ЗА пределами приложения, такой путь запоминать бессмысленно:
    /// доступ к чужой папке живёт только до конца работы приложения.
    public static func relativePath(for url: URL) -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(home + "/") else { return nil }
        return String(path.dropFirst(home.count + 1))
    }
}

public extension Notification.Name {
    /// Активная модель сменилась — экранам стоит перечитать её.
    static let pocketAgentActiveModelChanged = Notification.Name("PocketAgentActiveModelChanged")
}

// MARK: - Хранилище выбора

/// Где живёт выбор человека между запусками приложения.
/// Отдельный маленький класс, а не глобальная переменная: к нему обращаются из разных
/// потоков (движок, установка из файла, экраны), и доступ обязан быть под замком.
final class ActiveModelStore: @unchecked Sendable {

    static let shared = ActiveModelStore()

    private let key = "PocketAgent.activeModel.v1"
    private let lock = NSLock()
    private var cached: ActiveModelChoice?
    private var didLoad = false

    private init() {}

    var choice: ActiveModelChoice? {
        lock.lock()
        defer { lock.unlock() }
        if !didLoad {
            cached = readFromDefaults()
            didLoad = true
        }
        return cached
    }

    func set(_ newChoice: ActiveModelChoice?) {
        lock.lock()
        cached = newChoice
        didLoad = true
        lock.unlock()

        if let newChoice, let data = try? JSONEncoder().encode(newChoice) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }

        NotificationCenter.default.post(name: .pocketAgentActiveModelChanged, object: nil)
    }

    /// ⚠️ Разбор намеренно «мягкий»: если запись сделана прошлой версией приложения
    /// и больше не читается, мы молча возвращаемся к модели по умолчанию.
    /// Уронить запуск из-за старой настройки — худшее, что тут можно сделать.
    private func readFromDefaults() -> ActiveModelChoice? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ActiveModelChoice.self, from: data)
    }
}

// MARK: - Активная модель

public enum ModelSpec {

    /// Что человек выбрал. nil — ничего не выбирал, работаем с моделью по умолчанию.
    public static var choice: ActiveModelChoice? {
        ActiveModelStore.shared.choice
    }

    /// Модель, с которой приложение работает прямо сейчас.
    public static var descriptor: ModelDescriptor {
        choice?.descriptor ?? ModelCatalog.default
    }

    /// Файл активной модели, если человек указал конкретный.
    /// nil — искать файл там, где приложение хранит модели (ModelStorage).
    public static var selectedFileURL: URL? {
        guard let choice, choice.isFilePresent else { return nil }
        return choice.fileURL
    }

    /// Запомнить выбор человека.
    ///
    /// - Parameters:
    ///   - descriptor: описание модели (`ModelVerifier.inspect` отдаёт готовое).
    ///   - fileURL: где лежит файл. Если он внутри приложения — запомним путь,
    ///     чтобы модель подхватилась сама при следующем запуске.
    public static func select(_ descriptor: ModelDescriptor, fileURL: URL?) {
        let relative = fileURL.flatMap { ActiveModelChoice.relativePath(for: $0) }
        ActiveModelStore.shared.set(ActiveModelChoice(descriptor: descriptor,
                                                      relativePath: relative))
    }

    /// Забыть выбор и вернуться к модели по умолчанию.
    public static func clearSelection() {
        ActiveModelStore.shared.set(nil)
    }

    // MARK: Короткие обращения к активной модели

    /// Закреплённая версия репозитория (или "main", если версия не закреплена).
    public static var repoCommit: String { descriptor.repoCommit }

    /// Имя файла активной модели.
    public static var fileName: String { descriptor.fileName }

    /// Ссылка на скачивание. Осмысленна только для моделей из справочника
    /// с закреплённой версией — проверять через `ModelCatalog.canDownload`.
    public static var url: URL { descriptor.downloadURL }

    /// Точный размер файла в байтах.
    public static var expectedBytes: Int64 { descriptor.byteSize }

    /// sha256 из справочника. Пусто — модель принесли, эталона нет.
    public static var expectedSHA256: String { descriptor.sha256 }

    /// Имя ресурса в бандле (если модель положили прямо в приложение).
    public static var bundleResourceName: String { descriptor.bundleResourceName }

    /// Расширение файла модели.
    public static var fileExtension: String { descriptor.fileExtension }

    /// Первые 8 байт настоящего файла .litertlm.
    /// Единственный и достаточный признак формата: ровно эти байты сверяет
    /// и сам читатель Google.
    public static let magic = Data("LITERTLM".utf8)

    /// Что показать в «О программе».
    public static var attribution: String {
        let model = descriptor
        if model.origin == .unknownFile {
            return "\(model.displayName) — модель, которую вы принесли сами. "
                + "Файл \(model.fileName), \(model.humanSize). "
                + "Приложение её не проверяло: условия использования — у того, кто выложил файл."
        }
        let version = model.repoCommit == "main" ? "версия не закреплена" : String(model.repoCommit.prefix(7))
        return "\(model.displayName) от Google, лицензия \(model.license). "
            + "Файл \(model.fileName), версия \(version)."
    }
}
