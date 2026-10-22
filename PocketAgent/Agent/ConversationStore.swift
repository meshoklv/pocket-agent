//
//  ConversationStore.swift
//  PocketAgent
//
//  Записи разговоров: что человек просил, что помощник предлагал, что человек
//  подтвердил и на чём всё сломалось. Лежат на самом телефоне и никуда не уходят.
//
//  ⚠️ ЗАЧЕМ ЭТО ВООБЩЕ НУЖНО. Две разные причины, и обе живые:
//    1. Приложение держит в памяти веса модели (1–2 ГБ), поэтому система выгружает его
//       почти при каждом переключении на что-то тяжёлое. Раньше вся работа жила только
//       в оперативной памяти: человек начинал задачу, сворачивал приложение, смотрел
//       видео — и возвращался к чистому экрану «С чего начнём?».
//    2. Разбор поломки упирался в скриншоты владельца. Записи не было вовсе, пока
//       приложение не уходило в фон, — а если человек его не сворачивал, читать было
//       нечего вообще.
//
//  ⚠️ ЧТО ИЗМЕНИЛОСЬ (не откатывать):
//   • запись идёт ПО ХОДУ РАБОТЫ (после каждого хода помощника и каждой применённой
//     правки), а не только при уходе в фон;
//   • хранится НЕСКОЛЬКО последних разговоров — по одному файлу на задачу, с временем
//     начала прямо в имени файла. Лишние сверх `maxConversations` приложение удаляет само;
//   • файл трогается не чаще раза в пару секунд, а сама запись идёт ВНЕ главного потока:
//     иначе лента дёргалась бы на каждом ходе.
//
//  ⚠️ ПРИВАТНОСТЬ. Записи лежат ТОЛЬКО в папке приложения на телефоне, в резервную копию
//  не попадают и никуда не отправляются — приложение вообще не ходит в сеть с данными
//  человека. Стереть их человек может сам: меню «…» → «Стереть историю разговоров».
//  ⚠️ И честно про содержимое: в ленте есть НАЧАЛО файлов, которые помощник читал
//  (первые строки — их видит и сам человек в переписке). Значит, они есть и в записи.
//  Так и написано в «О программе»; врать про это нельзя.
//
//  Что НЕ сохраняем намеренно:
//    • карточку подтверждения целиком — «до/после» строились по старому состоянию файла,
//      и применять их после перезапуска нельзя: за это время файл могли поменять;
//    • тексты «до» и «после» из правок — это мегабайты на диске ни за чем. От правки
//      остаётся строка «README.md · +4 −1».
//

import Foundation

// MARK: - Что записываем

/// Одна запись разговора — всё, что нужно, чтобы потом понять, что происходило.
///
/// ⚠️ Собирает её интерфейс (AppViewModel), и это не случайность: только он видит
/// разом и снимок работы помощника, и то, что движок рассказал про загруженную модель.
/// Само хранилище ничего ни у кого не спрашивает — оно только пишет и читает файлы.
public struct ConversationLog: Sendable, Equatable {

    /// Опознаватель разговора. По нему запись ложится в СВОЙ файл и дополняется,
    /// а не плодит новый файл на каждый ход.
    public let id: UUID
    /// Когда человек начал эту задачу — это же время стоит в имени файла.
    public let startedAt: Date
    /// Папка проекта: полный путь (по нему решаем, чью переписку восстанавливать)
    /// и имя для человека.
    public let folderPath: String
    public let folderName: String?
    /// Чем считали: имя модели, имя файла, размер и «на видеочипе» / «на процессоре».
    public let modelName: String?
    public let modelFileName: String?
    public let modelSizeText: String?
    public let backendText: String?
    /// Задача человека — его первая фраза, дословно.
    public let task: String?
    /// Чем кончилось (или чем занято прямо сейчас), человеческим языком.
    public let outcome: String
    /// Действие, которое ждёт решения человека прямо сейчас: «Записать README.md».
    public let awaiting: String?
    public let stepsUsed: Int
    public let stepLimit: Int
    /// Разговор ещё идёт. Только такую запись возвращаем на экран после перезапуска:
    /// закрытая — это уже история, и подсовывать её как «продолжаем» нечестно.
    public let isOpen: Bool
    /// Последняя ошибка, если она была.
    public let errorText: String?
    /// Лента сообщений: задача человека, ответы модели, что делали инструменты.
    public let messages: [ChatMessage]

    public init(id: UUID,
                startedAt: Date,
                folderPath: String,
                folderName: String?,
                modelName: String?,
                modelFileName: String?,
                modelSizeText: String?,
                backendText: String?,
                task: String?,
                outcome: String,
                awaiting: String?,
                stepsUsed: Int,
                stepLimit: Int,
                isOpen: Bool,
                errorText: String?,
                messages: [ChatMessage]) {
        self.id = id
        self.startedAt = startedAt
        self.folderPath = folderPath
        self.folderName = folderName
        self.modelName = modelName
        self.modelFileName = modelFileName
        self.modelSizeText = modelSizeText
        self.backendText = backendText
        self.task = task
        self.outcome = outcome
        self.awaiting = awaiting
        self.stepsUsed = stepsUsed
        self.stepLimit = stepLimit
        self.isOpen = isOpen
        self.errorText = errorText
        self.messages = messages
    }
}

/// Разговор, поднятый с диска после перезапуска приложения.
///
/// ⚠️ Отдаём не только ленту, но и опознаватель с временем начала: продолжение той же
/// задачи обязано дописываться в ТОТ ЖЕ файл. Без этого каждый перезапуск порождал бы
/// вторую запись про одну и ту же задачу, и десять последних разговоров кончились бы
/// за один вечер.
public struct RestoredConversation: Sendable {
    public let id: UUID
    public let startedAt: Date
    public let messages: [ChatMessage]
}

// MARK: - Хранилище

public enum ConversationStore {

    // MARK: Настройки

    /// Сколько последних сообщений храним в одной записи. Больше человеку и не нужно —
    /// это лента для «вспомнить, на чём остановились», а не архив.
    private static let maxMessages = 60
    /// Длиннее этого одно сообщение не храним: в ленте бывают куски файлов.
    private static let maxCharactersPerMessage = 2000
    /// Через сутки переписка неинтересна — показывать её как «продолжаем» нечестно.
    /// На саму историю это не влияет: файл остаётся, просто не подставляется в чат.
    private static let lifetime: TimeInterval = 24 * 3600
    /// Сколько последних разговоров держим на телефоне. Старшие приложение удаляет само —
    /// расти без предела папке с записями нельзя.
    private static let maxConversations = 10
    /// Чаще этого файл не трогаем. Запись после каждого хода полезна, запись по десять
    /// раз в секунду — только износ памяти телефона и дёрганье ленты.
    private static let minimumWriteInterval: TimeInterval = 2

    // MARK: Что лежит на диске

    private struct StoredMessage: Codable {
        let author: String
        let text: String
        let createdAt: Date
        /// След от правки файла: «README.md · +4 −1». Самих текстов «до/после» здесь нет.
        let change: String?
        /// Опознаватель точки возврата — по нему после перезапуска возвращается кнопка
        /// «Вернуть, как было». Сам прежний текст лежит отдельно (`RestorePointStore`),
        /// сюда он не попадает: в переписке ему делать нечего.
        /// Необязательное поле — записи прежних версий приложения читаются как раньше.
        let restorePointID: UUID?
    }

    private struct StoredConversation: Codable {
        let id: UUID
        let startedAt: Date
        let savedAt: Date
        let folderPath: String
        let folderName: String?
        let modelName: String?
        let modelFileName: String?
        let modelSizeText: String?
        let backendText: String?
        let task: String?
        let outcome: String
        let awaiting: String?
        let stepsUsed: Int
        let stepLimit: Int
        let isOpen: Bool
        let errorText: String?
        let messages: [StoredMessage]
    }

    // MARK: Где лежат файлы

    /// Папка с записями: ~/Library/Application Support/Conversations.
    /// В «Файлах» её не видно — это служебное место приложения, а не папка человека.
    private static func directory(create: Bool) -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: create) else { return nil }
        let dir = base.appendingPathComponent("Conversations", isDirectory: true)
        guard create else { return dir }
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Рабочие заметки человека в облако не возим — это его дело, не наше.
            try? ModelStorage.excludeFromBackup(dir)
        }
        return dir
    }

    /// Имя файла с временем начала разговора: «conversation-2026-08-09_14-32-05-1A2B3C4D.json».
    ///
    /// ⚠️ Время стоит ПЕРВЫМ не для красоты: имена в таком виде сортируются по алфавиту
    /// ровно так же, как по времени, и поиск свежего разговора не требует открывать
    /// все файлы подряд.
    private static func fileName(for log: ConversationLog) -> String {
        "conversation-\(stamp(log.startedAt))-\(log.id.uuidString.prefix(8)).json"
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Постоянная локаль: иначе на телефоне с другим календарём выйдут другие цифры,
        // и сортировка по имени перестанет совпадать с порядком времени.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    /// Единственный файл прежних версий приложения. Формат другой, читать нечего —
    /// убираем, чтобы не занимал место и не путал при разборе папки.
    private static func removeLegacyFile() {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: false) else { return }
        let legacy = base.appendingPathComponent("conversation.json")
        try? FileManager.default.removeItem(at: legacy)
    }

    // MARK: Очередь записи

    /// Всё, что касается диска, живёт ЗДЕСЬ и только здесь.
    ///
    /// ⚠️ Главный поток сюда не заходит и записи не ждёт — кроме ухода в фон
    /// (см. `saveBeforeSuspend`). Запись после каждого хода прямо на главном потоке
    /// означала бы подтормаживание ленты ровно в тот момент, когда человек читает ответ.
    private static let queue = DispatchQueue(label: "pocketagent.conversations", qos: .utility)
    /// Последняя запись, которая ещё не легла на диск. Читается и пишется только в `queue`.
    private static var pending: ConversationLog?
    private static var lastWriteAt: Date?
    private static var isFlushScheduled = false

    /// Сохранить разговор. Файл трогается не чаще, чем раз в `minimumWriteInterval`.
    ///
    /// ⚠️ Частые вызовы не теряются, а СХЛОПЫВАЮТСЯ: последняя запись ждёт своей очереди
    /// и уходит на диск целиком. Простое «слишком рано — пропускаем» потеряло бы как раз
    /// последний ход, ради которого всё и затевалось.
    public static func save(_ log: ConversationLog) {
        queue.async { enqueue(log, immediately: false) }
    }

    /// Сохранить не откладывая — но и не заставляя человека ждать диск.
    /// Для закрытия разговора: «Новая задача», смена папки, смена модели.
    public static func saveNow(_ log: ConversationLog) {
        queue.async { enqueue(log, immediately: true) }
    }

    /// Сохранить и ДОЖДАТЬСЯ, пока запись ляжет на диск.
    ///
    /// ⚠️ Единственное место вызова — уход приложения в фон, и ожидание здесь намеренное:
    /// система вот-вот заморозит приложение, и запись, отправленная в фоновую очередь,
    /// просто не успела бы дойти до диска. Файл маленький (десятки килобайт), ожидание —
    /// миллисекунды, и случается оно ровно тогда, когда экран уже уезжает.
    /// ⛔️ Из обычной работы это звать нельзя: главный поток встанет на время записи.
    public static func saveBeforeSuspend(_ log: ConversationLog) {
        queue.sync { enqueue(log, immediately: true) }
    }

    /// Только внутри `queue`.
    private static func enqueue(_ log: ConversationLog, immediately: Bool) {
        pending = log
        if immediately {
            flush()
            return
        }
        let sinceLast = lastWriteAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if sinceLast >= minimumWriteInterval {
            flush()
            return
        }
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        queue.asyncAfter(deadline: .now() + (minimumWriteInterval - sinceLast)) {
            isFlushScheduled = false
            flush()
        }
    }

    /// Только внутри `queue`.
    private static func flush() {
        guard let log = pending else { return }
        pending = nil
        lastWriteAt = Date()
        write(log)
    }

    /// Только внутри `queue`.
    private static func write(_ log: ConversationLog) {
        guard !log.folderPath.isEmpty, !log.messages.isEmpty else { return }
        guard let dir = directory(create: true) else { return }

        let url = dir.appendingPathComponent(fileName(for: log))
        let isNewFile = !FileManager.default.fileExists(atPath: url.path)

        let messages = log.messages.suffix(maxMessages).map { message in
            StoredMessage(author: message.author.rawValue,
                          text: String(message.text.prefix(maxCharactersPerMessage)),
                          createdAt: message.createdAt,
                          change: changeNote(for: message.diff),
                          restorePointID: message.restorePointID)
        }

        let stored = StoredConversation(id: log.id,
                                        startedAt: log.startedAt,
                                        savedAt: Date(),
                                        folderPath: log.folderPath,
                                        folderName: log.folderName,
                                        modelName: log.modelName,
                                        modelFileName: log.modelFileName,
                                        modelSizeText: log.modelSizeText,
                                        backendText: log.backendText,
                                        task: log.task,
                                        outcome: log.outcome,
                                        awaiting: log.awaiting,
                                        stepsUsed: log.stepsUsed,
                                        stepLimit: log.stepLimit,
                                        isOpen: log.isOpen,
                                        errorText: log.errorText,
                                        messages: Array(messages))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
        try? ModelStorage.excludeFromBackup(url)

        // Считаем и подрезаем только когда файл появился впервые: перечитывать папку
        // на каждое дописывание одной и той же записи незачем.
        if isNewFile {
            removeLegacyFile()
            prune(in: dir)
        }
    }

    /// «README.md · +4 −1». Тексты «до» и «после» сюда не попадают — только след.
    private static func changeNote(for diff: FileDiff?) -> String? {
        guard let diff else { return nil }
        return "\(diff.relativePath) · +\(diff.addedCount) −\(diff.removedCount)"
    }

    /// Оставить `maxConversations` самых свежих записей, остальные удалить.
    /// Порядок берём по имени файла — оно начинается со времени начала разговора.
    private static func prune(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        let records = files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        guard records.count > maxConversations else { return }
        for url in records.dropFirst(maxConversations) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Восстановление

    /// Поднять разговор прошлого запуска. nil — восстанавливать нечего.
    ///
    /// Отдаём только НЕЗАКРЫТУЮ запись той же папки и не старше суток: чужой проект
    /// путать нельзя, а вчерашнюю задачу нечестно показывать как продолжающуюся.
    ///
    /// ⚠️ Чтение синхронное и с главного потока — это один маленький файл при запуске
    /// приложения, ровно как было раньше. Файлы перебираются от самого свежего, и
    /// разбирается обычно первый же.
    public static func restore(folderPath: String?) -> RestoredConversation? {
        guard let folderPath, !folderPath.isEmpty,
              let dir = directory(create: false),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let records = files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for url in records {
            guard let data = try? Data(contentsOf: url),
                  let stored = try? decoder.decode(StoredConversation.self, from: data) else { continue }
            guard stored.isOpen, stored.folderPath == folderPath else { continue }
            // Самый свежий незакрытый разговор этой папки уже устарел — значит и все
            // остальные тоже: они лежат ниже по времени.
            guard Date().timeIntervalSince(stored.savedAt) < lifetime else { return nil }

            let messages = stored.messages.map { item in
                ChatMessage(author: ChatAuthor(rawValue: item.author) ?? .system,
                            text: item.text,
                            createdAt: item.createdAt,
                            diff: nil,
                            restorePointID: item.restorePointID)
            }
            return RestoredConversation(id: stored.id,
                                        startedAt: stored.startedAt,
                                        messages: messages)
        }
        return nil
    }

    // MARK: Стереть всё

    /// «Стереть историю разговоров». Файлы удаляются с телефона совсем и не
    /// восстанавливаются: это решение человека, и оно должно быть настоящим.
    public static func eraseAll() {
        queue.async {
            // Отложенная запись больше не нужна — иначе она вернула бы на диск
            // ровно то, что человек только что просил стереть.
            pending = nil
            removeLegacyFile()
            guard let dir = directory(create: false) else { return }
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
