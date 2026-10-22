//
//  ModelImporter.swift
//  PocketAgent / Runtime
//
//  Установка модели ИЗ ГОТОВОГО ФАЙЛА, который человек уже положил на телефон
//  («Файлы», iCloud Drive, AirDrop, кабель). Второй путь рядом со скачиванием:
//  файл на 1,87 ГБ проще один раз перекинуть с компьютера, чем тянуть по мобильной связи.
//
//  ⚠️ ГЛАВНОЕ ИЗМЕНЕНИЕ. Раньше здесь стояла сверка «размер байт в байт с ЕДИНСТВЕННОЙ
//  зашитой моделью», и человек с годным файлом Gemma 4 E4B получал отказ
//  «весит 3,66 ГБ, а нужен ровно 2,01 ГБ». Теперь файл разбирает `ModelVerifier.inspect`:
//  он читает начало файла и сам говорит, что это за модель, целиком ли она скачана
//  и на каком железе пойдёт. Контрольная сумма при установке НЕ считается: за принесённый
//  файл отвечает его собственное содержимое, а эталон из справочника относится к файлу
//  из репозитория Google — те же модели раздают десятки зеркал, часть перезалита,
//  и сверка отвергала бы годный файл (плюс читала бы 3,66 ГБ на каждую установку).
//  Сумму сверяет только загрузка из интернета, где эталон действительно наш.
//
//  Второе: копировать файл больше не обязательно. Файл, лежащий в папке человека
//  в «Файлах», можно взять НА МЕСТЕ (`adopt`) — это ноль дополнительных гигабайт.
//
//  ⚠️ ТРЕТЬЕ (10.08.2026, жалоба владельца: «мы всё ещё не реализовали импорт модели
//  из любого места на телефоне — у гугла эта фича есть по умолчанию»). Установка
//  принимает ТРИ вида выбора, а не один файл:
//   • файл .litertlm — как раньше;
//   • ПАПКА модели Apple (там их семь-десять штук, и модель — это вся папка);
//   • обычная папка, внутри которой лежит один файл модели, — так модель почти всегда
//     и лежит в «Файлах»: в папке загрузок, в папке другого приложения.
//  Разбирается это одним местом — `ModelVerifier.resolvePicked`, тем же, которым
//  пользуется предварительный осмотр: иначе экран показал бы одно, а установка
//  взялась бы за другое.
//
//  Что здесь важно и почему код выглядит именно так:
//
//  • Файл человека лежит ЗА пределами песочницы приложения, поэтому доступ к нему
//    открывается через security-scoped ресурс и обязательно закрывается через defer.
//    Не закрыть — утечка системного ресурса: приложение перестанет открывать новые файлы.
//  • Читаем через NSFileCoordinator: файл может отдавать другой процесс
//    (iCloud, Working Copy, «Файлы») и его нужно сначала материализовать.
//  • Копируем КУСКАМИ по 8 МБ, а не одним Data(contentsOf:): 1,87 ГБ в памяти телефона
//    не помещаются — система убьёт приложение раньше, чем оно допишет файл.
//  • Все проверки идут ДО того, как файл объявлен моделью, и каждая ошибка объясняет
//    человеку, что именно не так и что с этим делать.
//  • Разбор содержимого и контрольную сумму считает ModelVerifier — здесь ни того,
//    ни другого не дублируется. Собственные ошибки этого файла — только про то,
//    чего сверщик не знает: место на телефоне, идущая загрузка, отмена, срыв копирования.
//
//  ⚠️ ВСЯ работа этого файла — синхронная и долгая (копирование плюс чтение 1,87 ГБ).
//  Звать ТОЛЬКО вне главного потока, через Task.detached. Отмена — обычная отмена задачи
//  Swift: цикл копирования и проверка сверяются с Task.isCancelled.
//

import Foundation

// MARK: - Прогресс

/// Этап установки — чтобы экран говорил «копирую», а не крутил безымянный спиннер.
public enum ModelImportStage: String, Sendable, Equatable {
    /// Проверяем сам файл: размер, метка, место на телефоне.
    case checking
    /// Копируем файл в хранилище приложения.
    case copying
    /// Сверяем контрольную сумму скопированного.
    case verifying
}

/// Насколько продвинулась установка.
public struct ModelImportProgress: Sendable, Equatable {
    public let stage: ModelImportStage
    /// 0…1 внутри текущего этапа.
    public let fraction: Double
    /// Сколько байт уже скопировано (для этапа копирования).
    public let copiedBytes: Int64
    /// Сколько всего байт должно получиться.
    public let totalBytes: Int64

    public init(stage: ModelImportStage,
                fraction: Double,
                copiedBytes: Int64,
                totalBytes: Int64) {
        self.stage = stage
        self.fraction = min(max(fraction, 0), 1)
        self.copiedBytes = copiedBytes
        self.totalBytes = totalBytes
    }
}

// MARK: - Ошибки установки из файла

/// Отдельный тип ошибок, а не новые случаи в `PocketAgentError`, ровно по одной причине:
/// человеку здесь нужен не диагноз «файл повреждён», а объяснение — какой именно файл нужен,
/// чем не подошёл этот и что сделать дальше. Все тексты пишутся отсюда целиком.
/// ⚠️ Помечен `HumanReadableError` НАМЕРЕННО: без этой метки экран показал бы вместо
/// подробного объяснения общее «что-то пошло не так» — разбор ошибок пропускает наружу
/// только помеченные типы, чтобы системные английские фразы не просочились.
public enum ModelImportError: HumanReadableError, Equatable {

    /// Выбрана папка или что-то, что файлом не является.
    case notAFile(name: String)
    /// Файл лежит в iCloud и ещё не скачан на телефон.
    case cloudFileNotDownloaded(name: String)
    /// Файл не проходит проверку: не тот формат, обрывок, чужая сборка, ещё копируется.
    /// Причина уже написана человеческим языком — её сочиняет `ModelVerifier`.
    ///
    /// ⚠️ Прежние случаи `sizeMismatch` («весит столько-то, а нужен ровно столько-то»)
    /// и `notAModelFile` убраны намеренно: приложение больше не требует ОДИН файл
    /// определённого размера, а недокачанный файл узнаётся по его собственному
    /// содержимому и объясняется текстом из `ModelFileError`.
    case unsuitableFile(name: String, reason: String)
    /// Не хватает места, чтобы положить копию рядом.
    /// ⚠️ Несём ВСЕ ТРИ числа, а не одну нехватку: человеку нужно решить, что удалять,
    /// а для этого он должен видеть, сколько нужно и сколько у него есть на самом деле.
    case notEnoughSpace(needBytes: Int64, freeBytes: Int64, canFreeBytes: Int64)
    /// Файл нужного размера, но содержимое отличается от эталона.
    case checksumMismatch(name: String)
    /// Система не дала прочитать выбранный файл.
    case accessDenied(name: String, reason: String)
    /// Копирование сорвалось.
    case copyFailed(reason: String)
    /// Прямо сейчас идёт загрузка модели из интернета.
    case downloadInProgress
    /// Человек нажал «Отменить».
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notAFile(let name):
            return "«\(name)» — это не файл модели, а папка или ярлык. Выберите сам файл модели."

        case .cloudFileNotDownloaded(let name):
            // ⚠️ Слова берём у сверщика, а не пишем свои. Про файл в облаке человек
            // читает одно и то же объяснение, откуда бы он ни пришёл — с осмотра файла,
            // с установки или с папки модели Apple. Вторая формулировка того же самого
            // выглядит как второй, другой отказ.
            return ModelFileError.stillInCloud(name: name).errorDescription

        case .unsuitableFile(let name, let reason):
            return "Файл «\(name)» не подходит. \(reason)"

        case .notEnoughSpace(let need, let free, let canFree):
            let head = "Не хватает места: модель весит \(Self.bytes(need)), "
                + "а свободно \(Self.bytes(free))."
            if canFree > 0 {
                return head + " Можно освободить \(Self.bytes(canFree)), удалив старый файл "
                    + "модели на странице «О программе», — или убрать что-нибудь ненужное в телефоне."
            }
            return head + " Освободите место и попробуйте снова."

        case .checksumMismatch(let name):
            return """
            Файл «\(name)» нужного размера, но его содержимое отличается от эталонного — \
            скорее всего, он побился при передаче на телефон. Скопируйте его ещё раз.
            """

        case .accessDenied(let name, let reason):
            return "Не удалось прочитать «\(name)»: \(reason). Попробуйте выбрать файл заново."

        case .copyFailed(let reason):
            return "Не удалось скопировать файл на телефон: \(reason)"

        case .downloadInProgress:
            return "Сейчас идёт загрузка модели из интернета. Сначала дождитесь её окончания или остановите загрузку."

        case .cancelled:
            return "Установка отменена. Ничего не изменилось."
        }
    }

    /// Размер человеческим языком. Общий форматировщик из Contracts: он всегда ставит
    /// русскую запятую, а ByteCountFormatter брал разделитель из настроек телефона —
    /// на нерусском устройстве в одной строке оказывались «2.59» и «ГБ».
    private static func bytes(_ value: Int64) -> String {
        HumanFormat.bytes(value)
    }
}

// MARK: - Установка из файла

public enum ModelImporter {

    /// Размер куска при копировании. 8 МБ — компромисс: меньше кусков (быстрее),
    /// но столько памяти телефон отдаёт спокойно.
    private static let chunkSize = 8 * 1024 * 1024

    /// Запас места сверх размера самой модели. Копируем прямо в хранилище приложения,
    /// поэтому удвоение не нужно — нужен только небольшой воздух системе.
    private static let spaceReserveBytes: Int64 = 250 * 1024 * 1024

    /// Расширение недокопированного файла. Одно на весь проект: по нему же
    /// «Модель на телефоне» считает и убирает хвост, оставшийся после сбоя.
    static let temporaryExtension = "import"

    /// Идёт ли прямо сейчас установка из файла.
    ///
    /// ⚠️ ЗАЧЕМ ЭТО ЗНАТЬ СНАРУЖИ. Уборка обрывков (`ModelDiscovery`) видит на диске
    /// ровно то же самое, что видит установка в разгар копирования: файл с хвостом
    /// «.import». Без этого флага обход папок мог бы посчитать живую копию брошенной
    /// и стереть её из-под работающей установки.
    public static var isInstalling: Bool {
        installLock.lock(); defer { installLock.unlock() }
        return installsInFlight > 0
    }

    private static let installLock = NSLock()
    private static var installsInFlight = 0

    private static func beginInstall() {
        installLock.lock(); installsInFlight += 1; installLock.unlock()
    }

    private static func endInstall() {
        installLock.lock(); installsInFlight = max(0, installsInFlight - 1); installLock.unlock()
    }

    /// Куда копируем, пока файл не проверен.
    static func temporaryFileURL(for model: ModelDescriptor) -> URL? {
        (try? ModelStorage.fileURL(for: model))?.appendingPathExtension(temporaryExtension)
    }

    /// Установить модель из выбранного человеком файла.
    ///
    /// - Parameter model: эталон, если человек ставит ЗАРАНЕЕ ИЗВЕСТНУЮ модель.
    ///   `nil` (и это обычный случай) — описание выводится из самого файла, и тогда
    ///   принимается ЛЮБАЯ годная модель .litertlm, а не одна зашитая.
    /// - Returns: путь к готовому файлу модели в хранилище приложения.
    /// - Important: работает синхронно и долго. Звать ТОЛЬКО вне главного потока.
    ///
    /// Принимает ВСЁ, что человек мог выбрать в «Файлах»: файл модели, папку модели
    /// Apple и папку, внутри которой лежит один файл модели. Откуда именно он его взял —
    /// «На iPhone», iCloud Drive, папка другого приложения — здесь неважно: доступ
    /// к чужой папке открывает система, и делается это первой же строкой.
    ///
    /// ⚠️ Файл, который УЖЕ лежит в папке приложения («Файлы» → «Карманный агент»),
    /// НЕ копируется и даже не переносится: он берётся на месте (`adopt`). Раньше здесь
    /// был перенос внутрь приложения — мгновенный и без второй копии, но файл при этом
    /// пропадал из «Файлов», и человек его больше не находил.
    @discardableResult
    public static func install(from pickedURL: URL,
                               model requested: ModelDescriptor? = nil,
                               onProgress: @escaping @Sendable (ModelImportProgress) -> Void) throws -> URL {

        // Одновременно качать и устанавливать один и тот же файл нельзя:
        // загрузчик пишет ровно туда же, куда кладём мы.
        guard !ModelDownloader.shared.isDownloading else {
            throw ModelImportError.downloadInProgress
        }

        // Пока установка идёт, уборка обрывков не должна трогать нашу копию.
        beginInstall()
        defer { endInstall() }

        // Файл человека живёт за пределами песочницы — открываем доступ на всё время работы.
        // ⚠️ Закрыть обязательно: незакрытый доступ система считает утечкой,
        // и приложение перестаёт открывать новые файлы до перезапуска.
        // ⚠️ Доступ открывается на ТО, ЧТО ВЫБРАЛ ЧЕЛОВЕК: если это папка, разрешение
        // распространяется и на её содержимое, а разрешения на файл внутри отдельно нам
        // никто не выдавал. Поэтому просим доступ до всякого разбора и на исходный URL.
        let didStartAccess = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { pickedURL.stopAccessingSecurityScopedResource() }
        }

        // Человек мог выбрать папку, в которой лежит сам файл модели, — работаем с тем,
        // что выбрано на самом деле. Тем же разбором, что и предварительный осмотр,
        // иначе экран показал бы одно, а установка взялась бы за другое.
        let source = try ModelVerifier.resolvePicked(pickedURL)
        let name = source.lastPathComponent

        // Модель Apple — это ПАПКА из нескольких файлов, и всё ниже (один поток байтов,
        // одна метка в начале, один размер) про неё неверно. У неё своя установка.
        if MLXModelFolder.isFolder(source) {
            return try installFolder(from: source, onProgress: onProgress)
        }

        // ⚠️ ФАЙЛ УЖЕ ВНУТРИ ПЕСОЧНИЦЫ — НЕ ТРОГАЕМ ЕГО ВООБЩЕ. Ни копии (это вторые
        // гигабайты), ни переноса: из папки «Карманный агент» модель читается напрямую,
        // а перенос молча убрал бы файл из «Файлов» — человек искал бы его и не нашёл.
        // Не вышло взять на месте — идём обычным путём, он объяснит причину сам.
        if isInsideAppContainer(source),
           (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
           let adopted = try? adopt(fileAt: source) {
            // ⚠️ Кэш движка чистим ровно так же, как на обычном пути установки файла:
            // он собран под ПРОШЛУЮ модель, и оставить его при подмене модели — значит
            // поднимать новую поверх чужих служебных данных.
            ModelStorage.clearEngineCache()
            report(onProgress, .verifying, 1, adopted.byteSize, adopted.byteSize)
            return adopted.url
        }

        report(onProgress, .checking, 0, 0, ModelStorage.byteSize(of: source))

        // Что это за модель, решаем ПО САМОМУ ФАЙЛУ. Эталон из каталога подставляется
        // только если файл совпал с ним имя-в-имя и байт-в-байт.
        let model = try resolveDescriptor(for: source, name: name, requested: requested)

        let destination = try ModelStorage.fileURL(for: model)

        // Человек выбрал уже установленный файл (такое возможно, если папку приложения
        // видно в «Файлах»). Копировать файл сам в себя нельзя — это его уничтожит.
        if sameFile(source, destination) {
            try verifyCopy(at: destination, model: model, onProgress: onProgress)
            rememberInstalled(destination, model: model)
            return destination
        }

        // Файл из папки самого приложения не копируется, а переносится, — там место не нужно.
        // ⚠️ Проверку места отсюда убрали намеренно: перенос может не удаться (другой том,
        // занятый файл), и тогда управление уходило в честное копирование двух гигабайт
        // БЕЗ единой проверки. Человек получал сырое «не удалось скопировать» где-то на
        // последнем гигабайте вместо понятного «не хватает столько-то». Теперь проверка
        // стоит на самом пути копирования — см. ниже, перед copyChunked.
        let willMove = isInsideAppContainer(source)

        // Пишем во временный файл рядом: пока копия не проверена, старую модель не трогаем.
        let temporary = destination.appendingPathExtension(Self.temporaryExtension)
        try? FileManager.default.removeItem(at: temporary)

        var isFinished = false
        // Откуда файл был ПЕРЕНЕСЁН (а не скопирован). nil — переноса не было.
        var movedFrom: URL?

        // ⚠️ Никаких return/break внутри defer: Swift запрещает выходить из него
        // передачей управления, поэтому всё условие написано обычным if.
        defer {
            if !isFinished {
                if let origin = movedFrom {
                    // ⚠️ ФАЙЛ БЫЛ ПЕРЕНЕСЁН — значит, у человека его больше нигде нет.
                    // Удалить его на неудаче или на отмене (а отменяют чаще всего прямо
                    // во время долгой сверки) означало бы уничтожить те самые гигабайты,
                    // которые человек качал полдня. Возвращаем файл туда, где взяли.
                    try? FileManager.default.moveItem(at: temporary, to: origin)
                } else {
                    // Копия — не жалко: оригинал человека лежит на месте нетронутым.
                    try? FileManager.default.removeItem(at: temporary)
                }
            }
        }

        if willMove, moveIfPossible(from: source, to: temporary) {
            movedFrom = source
            report(onProgress, .copying, 1, model.byteSize, model.byteSize)
        } else {
            // Копируем по-настоящему — значит место нужно, и узнать о нехватке
            // человек обязан ДО того, как мы начнём таскать гигабайты.
            try checkFreeSpace(for: model)
            try copyChunked(from: source,
                            to: temporary,
                            model: model,
                            name: name,
                            onProgress: onProgress)
        }

        try verifyCopy(at: temporary, model: model, onProgress: onProgress)

        // Только теперь заменяем то, что было: до этой строки установленная модель цела.
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw ModelImportError.copyFailed(reason: error.localizedDescription)
        }
        isFinished = true

        // Гигабайты модели в резервной копии iCloud не нужны никому.
        try? ModelStorage.excludeFromBackup(destination)
        // Недокачанный кусок из интернета больше не пригодится.
        ModelStorage.clearResumeData(for: model)
        // Кэш движка собран под ПРОШЛЫЙ файл модели — после подмены он недействителен.
        ModelStorage.clearEngineCache()
        rememberInstalled(destination, model: model)
        // Список моделей изменился — экранам пора его перечитать.
        ModelDiscovery.refreshAndNotify()

        report(onProgress, .verifying, 1, model.byteSize, model.byteSize)
        return destination
    }

    // MARK: - Установка ПАПКИ с моделью Apple

    /// Установить модель, которая лежит папкой из нескольких файлов.
    ///
    /// ⚠️ ЧТО ЗДЕСЬ ПРИНЦИПИАЛЬНО ИНАЧЕ, ЧЕМ У ОДНОГО ФАЙЛА:
    ///
    /// • **Проверка — по составу, а не по метке.** Восемь файлов, и без мелких описаний
    ///   модель не запускается вовсе. Что именно проверяется — в `MLXModelFolder`.
    /// • **Прогресс — общий на всю папку.** Человек не должен видеть восемь полосок,
    ///   восемь раз уезжающих с нуля; он видит одну и общий вес.
    /// • **Обрыв на середине не оставляет полумодели.** Копия собирается в папке
    ///   с хвостом «.import» рядом с настоящей; она не считается моделью ни при обходе,
    ///   ни при следующем запуске, и стирается целиком. Если папку не копировали,
    ///   а ПЕРЕНЕСЛИ (она уже была внутри приложения) — на любой неудаче её возвращают
    ///   туда, где взяли: у человека другой копии этих гигабайтов нет.
    ///
    /// - Returns: путь к готовой ПАПКЕ модели в хранилище приложения.
    @discardableResult
    static func installFolder(from pickedURL: URL,
                              onProgress: @escaping @Sendable (ModelImportProgress) -> Void) throws -> URL {

        let name = pickedURL.lastPathComponent

        report(onProgress, .checking, 0, 0, 0)

        // Состав папки: есть ли устройство модели, веса, словарь, все ли части на месте.
        // Ошибка отсюда уже написана человеческим языком — заворачивать её незачем.
        let folder = try MLXModelFolder.inspect(pickedURL)
        let total = folder.totalBytes
        let model = MLXModelFolder.descriptor(for: folder)

        report(onProgress, .checking, 1, 0, total)

        let destination = try ModelStorage.modelsDirectory().appendingPathComponent(name,
                                                                                    isDirectory: true)

        // Человек выбрал уже установленную папку. Копировать её саму в себя нельзя.
        if sameFile(pickedURL, destination) {
            rememberFolder(destination, model: model)
            return destination
        }

        let willMove = isInsideAppContainer(pickedURL)
        if !willMove {
            try checkFreeSpace(bytes: total, model: model)
        }

        // Пока копия не собрана целиком, настоящую папку не трогаем.
        let temporary = destination.appendingPathExtension(Self.temporaryExtension)
        try? FileManager.default.removeItem(at: temporary)

        var isFinished = false
        var movedFrom: URL?

        defer {
            if !isFinished {
                if let origin = movedFrom {
                    // Папку ПЕРЕНЕСЛИ — значит, у человека её больше нигде нет.
                    // Возвращаем туда, где взяли.
                    try? FileManager.default.moveItem(at: temporary, to: origin)
                } else {
                    // Недокопированная папка целиком: половина модели никому не нужна,
                    // а лежала бы она гигабайтами и молча.
                    try? FileManager.default.removeItem(at: temporary)
                }
            }
        }

        if willMove, moveIfPossible(from: pickedURL, to: temporary) {
            movedFrom = pickedURL
            report(onProgress, .copying, 1, total, total)
        } else {
            try copyFolder(folder, to: temporary, onProgress: onProgress)
        }

        // Проверяем ИМЕННО КОПИЮ, а не оригинал: короткое чтение у файл-провайдера —
        // дело обычное, и половина файла на телефоне выглядит как целая папка.
        report(onProgress, .verifying, 0, total, total)
        let copied = try MLXModelFolder.inspect(temporary)
        guard copied.totalBytes == total else {
            throw ModelImportError.copyFailed(
                reason: "папка скопирована не целиком (\(HumanFormat.bytes(copied.totalBytes)) "
                    + "из \(HumanFormat.bytes(total)))"
            )
        }

        // Только теперь заменяем то, что лежало раньше.
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw ModelImportError.copyFailed(reason: error.localizedDescription)
        }
        isFinished = true

        // Гигабайты модели в резервной копии iCloud не нужны никому.
        try? ModelStorage.excludeFromBackup(destination)
        // ⚠️ Кэш движка ЗДЕСЬ НЕ ЧИСТИМ, в отличие от установки файла. Он собран движком
        // Google под ЕГО модель и к папке Apple отношения не имеет: снести его — значит
        // заставить работающую модель человека собирать кэш заново на ровном месте.
        rememberFolder(destination, model: model)
        ModelDiscovery.refreshAndNotify()

        report(onProgress, .verifying, 1, total, total)
        return destination
    }

    /// Скопировать папку файл за файлом с общим прогрессом.
    ///
    /// ⚠️ Кусками по 8 МБ, как и одиночный файл: файл весов на 3,5 ГБ в память телефона
    /// не помещается, и `copyItem` целиком тоже не годится — он не умеет ни отчитываться
    /// о ходе, ни останавливаться по нажатию «Отменить».
    private static func copyFolder(_ folder: MLXFolderReport,
                                   to destination: URL,
                                   onProgress: @escaping @Sendable (ModelImportProgress) -> Void) throws {

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw ModelImportError.copyFailed(reason: error.localizedDescription)
        }

        let total = max(folder.totalBytes, 1)
        var copiedTotal: Int64 = 0

        for item in folder.items {
            if Task.isCancelled { throw ModelImportError.cancelled }

            let source = folder.url.appendingPathComponent(item.name)
            let target = destination.appendingPathComponent(item.name)
            let alreadyCopied = copiedTotal

            try copyChunked(from: source,
                            to: target,
                            name: item.name,
                            expectedBytes: item.byteSize) { bytesOfThisFile in
                report(onProgress,
                       .copying,
                       Double(alreadyCopied + bytesOfThisFile) / Double(total),
                       alreadyCopied + bytesOfThisFile,
                       folder.totalBytes)
            }

            copiedTotal += item.byteSize
        }
    }

    /// Копирование одного файла кусками. Чтение координированное: файл может отдавать
    /// другой процесс (iCloud, «Файлы»), и ему нужно дать себя подготовить.
    private static func copyChunked(from source: URL,
                                    to destination: URL,
                                    name: String,
                                    expectedBytes: Int64,
                                    onCopied: @escaping @Sendable (Int64) -> Void) throws {

        var coordinationError: NSError?
        var thrownError: Error?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedURL in
            do {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw ModelImportError.copyFailed(reason: "не удалось создать файл «\(name)»")
                }
                let input = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }

                var copied: Int64 = 0
                while true {
                    if Task.isCancelled { throw ModelImportError.cancelled }
                    guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                    try output.write(contentsOf: chunk)
                    copied += Int64(chunk.count)
                    onCopied(copied)
                }
                try output.synchronize()

                // Короткое чтение законно, а вот молча принять обрезанный файл нельзя:
                // дальше эта папка притворится целой моделью.
                guard copied == expectedBytes else {
                    throw ModelImportError.copyFailed(
                        reason: "файл «\(name)» прочитан не целиком (\(copied) из \(expectedBytes) байт)"
                    )
                }
            } catch {
                thrownError = error
            }
        }

        if let coordinationError {
            throw ModelImportError.accessDenied(name: name,
                                                reason: coordinationError.localizedDescription)
        }
        if let thrownError {
            if let known = thrownError as? ModelImportError { throw known }
            throw ModelImportError.copyFailed(reason: thrownError.localizedDescription)
        }
    }

    /// Запомнить установленную папку как активную модель — но только если её есть чем
    /// запускать.
    ///
    /// ⚠️ ЗАЧЕМ ОГОВОРКА. Пока движок Apple не вшит в сборщик агента, объявить папку
    /// активной моделью значит отобрать у человека РАБОТАЮЩУЮ модель Google и подсунуть
    /// движку папку, которую он не откроет. Поэтому папку ставим, показываем в списке,
    /// а активную модель не трогаем. Снимается это переключателем
    /// `MLXModelFolder.isEngineWired` — одной строкой, вместе с шагом «выбор движка».
    private static func rememberFolder(_ url: URL, model: ModelDescriptor) {
        guard MLXModelFolder.isEngineWired else { return }
        ModelSpec.select(model, fileURL: url)
    }

    // MARK: - Что это за файл

    /// Опознать модель ПО ФАЙЛУ и заодно проверить всё, что проверяется мгновенно, —
    /// до того как трогать гигабайты.
    ///
    /// ⚠️ Здесь больше НЕТ сверки «размер обязан совпасть с единственной зашитой моделью».
    /// Именно она отвергала годный файл Gemma 4 E4B: «весит 3,66 ГБ, а нужен ровно 2,01 ГБ».
    /// Целостность теперь проверяется по СОДЕРЖИМОМУ файла (`ModelVerifier.inspect`):
    /// внутри записано, где кончаются данные, и недокачанный файл виден без всякого эталона.
    ///
    /// - Throws: `ModelFileError` — с готовым объяснением, что именно не так с файлом.
    static func resolveDescriptor(for url: URL,
                                  name: String,
                                  requested: ModelDescriptor?) throws -> ModelDescriptor {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            throw ModelImportError.notAFile(name: name)
        }

        // Файл из iCloud может быть «заглушкой»: имя есть, содержимого на телефоне нет.
        // Читать такой файл — это молча качать гигабайты по той сети, которая сейчас есть.
        // Состояние «выгружен, но версия могла отстать» считается годным: байты на месте.
        if ModelStorage.cloudState(of: url) == .placeholder {
            ModelStorage.requestCloudDownload(url)
            throw ModelImportError.cloudFileNotDownloaded(name: name)
        }

        // Разбор содержимого: формат, версия, состав, целостность, требование к железу.
        let report = try ModelVerifier.inspect(url)

        // Человек ставит ровно ту модель, которую просили, и файл совпал байт в байт —
        // тогда работает и полная сверка по контрольной сумме, как раньше.
        if let requested, requested.fileName == name, requested.byteSize == report.byteSize {
            return requested
        }
        // Иначе описание берём у сверщика: узнанное — из справочника, чужое — по файлу.
        return report.descriptor
    }

    /// Хватит ли места под копию. Ноль от системы означает «узнать не получилось» —
    /// тогда не мешаем: соврать про нехватку хуже, чем не проверить.
    private static func checkFreeSpace(for model: ModelDescriptor) throws {
        try checkFreeSpace(bytes: model.byteSize, model: model)
    }

    /// То же самое, когда размер известен отдельно от описания модели, — так бывает
    /// у папки: её вес это сумма по файлам, а не размер одной записи на диске.
    private static func checkFreeSpace(bytes: Int64, model: ModelDescriptor) throws {
        let free = ModelStorage.availableBytes()
        guard free > 0 else { return }

        let needed = bytes + spaceReserveBytes
        guard free < needed else { return }

        // ⚠️ Человеку называем вес САМОЙ МОДЕЛИ и свободное место, а не служебную
        // разницу с запасом: «не хватает 40 МБ» на файле в 3,66 ГБ звучит так, будто
        // дело в мелочи, — а удалять придётся гигабайты.
        throw ModelImportError.notEnoughSpace(needBytes: bytes,
                                              freeBytes: free,
                                              canFreeBytes: ModelInstallation.occupiedBytes(for: model))
    }

    // MARK: - Копирование

    /// Файл из папки самого приложения переносим, а не копируем: место на телефоне
    /// не удваивается, и дубликат не остаётся валяться в «Файлах».
    /// Возвращает false, если перенос не удался, — тогда работает обычное копирование.
    private static func moveIfPossible(from source: URL, to destination: URL) -> Bool {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    /// Копирование кусками с прогрессом и возможностью отмены.
    /// Чтение — координированное: файл может отдавать другой процесс (iCloud, Working Copy),
    /// и ему нужно дать себя подготовить.
    private static func copyChunked(from source: URL,
                                    to destination: URL,
                                    model: ModelDescriptor,
                                    name: String,
                                    onProgress: @escaping @Sendable (ModelImportProgress) -> Void) throws {

        var coordinationError: NSError?
        var thrownError: Error?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedURL in
            // Работаем ТОЛЬКО с URL, пришедшим в блок: исходный может указывать на заглушку.
            do {
                try stream(from: coordinatedURL,
                           to: destination,
                           model: model,
                           name: name,
                           onProgress: onProgress)
            } catch {
                thrownError = error
            }
        }

        if let coordinationError {
            throw ModelImportError.accessDenied(name: name,
                                                reason: coordinationError.localizedDescription)
        }
        if let thrownError { throw thrownError }
    }

    /// Собственно перекладывание байтов. Память не растёт: в ней живёт один кусок.
    private static func stream(from source: URL,
                               to destination: URL,
                               model: ModelDescriptor,
                               name: String,
                               onProgress: @escaping @Sendable (ModelImportProgress) -> Void) throws {

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ModelImportError.copyFailed(reason: "не удалось создать файл в хранилище приложения")
        }

        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw ModelImportError.accessDenied(name: name, reason: error.localizedDescription)
        }
        defer { try? input.close() }

        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destination)
        } catch {
            throw ModelImportError.copyFailed(reason: error.localizedDescription)
        }
        defer { try? output.close() }

        var copied: Int64 = 0
        let total = max(model.byteSize, 1)

        while true {
            // Человек нажал «Отменить» — бросаем работу сразу, не дочитывая гигабайты.
            if Task.isCancelled { throw ModelImportError.cancelled }

            let chunk: Data?
            do {
                chunk = try input.read(upToCount: chunkSize)
            } catch {
                throw ModelImportError.accessDenied(name: name, reason: error.localizedDescription)
            }
            guard let chunk, !chunk.isEmpty else { break }

            do {
                try output.write(contentsOf: chunk)
            } catch {
                throw ModelImportError.copyFailed(reason: error.localizedDescription)
            }

            copied += Int64(chunk.count)
            report(onProgress, .copying, Double(copied) / Double(total), copied, model.byteSize)
        }

        do {
            try output.synchronize()
        } catch {
            throw ModelImportError.copyFailed(reason: error.localizedDescription)
        }

        // Короткое чтение у файл-провайдера законно: он мог отдать меньше, чем обещал размер.
        // Молча принять обрезанный файл нельзя — дальше он притворится моделью.
        guard copied == model.byteSize else {
            throw ModelImportError.copyFailed(
                reason: "файл прочитан не целиком (\(copied) из \(model.byteSize) байт)"
            )
        }
    }

    // MARK: - Проверка копии

    /// Авторитетная проверка — ModelVerifier: размер на месте, метка формата на месте,
    /// содержимое разобрано и целостность подтверждена концом последней секции.
    ///
    /// ⚠️ КОНТРОЛЬНАЯ СУММА ЗДЕСЬ НЕ СЧИТАЕТСЯ (`checksum: .skip`), и это не небрежность.
    /// Файл принёс человек: эталон в справочнике относится к файлу из репозитория Google,
    /// а те же модели раздают десятки зеркал, часть перезалита. Сверка отвергала бы годный
    /// файл ровно тем же отказом, ради ухода от которого всё и переделывалось, — и стоила
    /// бы чтения 3,66 ГБ при каждой установке. Целостность уже проверена по содержимому.
    private static func verifyCopy(at url: URL,
                                   model: ModelDescriptor,
                                   onProgress: @escaping @Sendable (ModelImportProgress) -> Void) throws {
        report(onProgress, .verifying, 0, model.byteSize, model.byteSize)
        do {
            try ModelVerifier.verify(url, model: model, checksum: .skip) { fraction in
                report(onProgress, .verifying, fraction, model.byteSize, model.byteSize)
            }
        } catch {
            // ⚠️ Имя называем НАСТОЯЩЕЕ, а не служебное. Здесь проверяется копия под
            // временным именем «…litertlm.import», и человеку в отказе показывали именно
            // его — он читал про файл, которого у себя никогда не видел.
            throw mapVerifierError(error, name: model.fileName)
        }
    }

    /// ModelVerifier отвечает общими словами («файл повреждён») — переводим их
    /// в объяснение для человека.
    private static func mapVerifierError(_ error: Error, name: String) -> Error {
        if let known = error as? ModelImportError { return known }
        // Разбор содержимого уже объясняет человеку, что не так с файлом («скачан не
        // полностью», «сборка для браузера»). Заворачивать это в «не удалось скопировать»
        // значило бы спрятать готовое объяснение за общей фразой.
        if let fileError = error as? ModelFileError { return fileError }
        guard let agentError = error as? PocketAgentError else {
            return ModelImportError.copyFailed(reason: error.localizedDescription)
        }
        switch agentError {
        case .generationCancelled:
            return ModelImportError.cancelled
        case .modelFileCorrupted, .modelFileMissing:
            return ModelImportError.checksumMismatch(name: name)
        case .readFailed(_, let reason):
            return ModelImportError.copyFailed(reason: reason)
        default:
            return ModelImportError.copyFailed(reason: agentError.errorDescription ?? "неизвестная ошибка")
        }
    }

    // MARK: - Использовать файл НА МЕСТЕ, без копирования

    /// Взять в работу файл, который уже лежит в папке приложения («Файлы» → «Карманный агент»),
    /// НЕ копируя его.
    ///
    /// ⚠️ Зачем: копия файла на 3,66 ГБ — это ещё 3,66 ГБ на телефоне человека, при том
    /// что файл и так лежит внутри песочницы приложения и прекрасно читается оттуда.
    /// Запускать модель прямо из Documents можно: это обычная записываемая папка контейнера,
    /// отдельного разрешения для своих же файлов не нужно, а кэш движка и так живёт отдельно.
    ///
    /// Расплата ровно одна: человек может удалить файл из «Файлов» — поэтому перед каждым
    /// запуском наличие файла проверяется заново, а не берётся на веру из настроек.
    @discardableResult
    public static func adopt(fileAt url: URL) throws -> DiscoveredModelFile {
        let name = url.lastPathComponent

        guard isInsideAppContainer(url) else {
            throw ModelImportError.unsuitableFile(
                name: name,
                reason: "Файл лежит вне папки приложения — такой нужно устанавливать копированием."
            )
        }

        if MLXModelFolder.isFolder(url) {
            // Папку проверяем по составу — тем же разбором, что и при установке.
            _ = try MLXModelFolder.inspect(url)
            // ⚠️ Единственный настоящий запрет во всей этой работе, и он не выдуман:
            // запускать модель Apple приложению пока НЕЧЕМ. Взять её «в работу» значит
            // молча отобрать у человека ту модель, которая у него работает сейчас.
            // Снимается вместе с подключением движка — `MLXModelFolder.isEngineWired`.
            guard MLXModelFolder.isEngineWired else {
                throw ModelImportError.unsuitableFile(name: name, reason: MLXModelFolder.engineNote)
            }
        } else {
            // Те же проверки, что и при установке: формат, целостность, сборка для браузера.
            _ = try resolveDescriptor(for: url, name: name, requested: nil)
        }

        guard let file = ModelDiscovery.describe(url) else {
            throw ModelImportError.unsuitableFile(name: name, reason: "Файл не читается.")
        }
        // Файл могли положить секунду назад — тогда он ещё дописывается, и объявлять его
        // готовым нельзя: движок откроет обрывок и ответит невнятной ошибкой.
        guard file.isUsable else {
            throw ModelImportError.unsuitableFile(name: name,
                                                  reason: file.problem ?? "Файл пока недоступен.")
        }

        // Гигабайты в резервной копии не нужны никому, а Documents бэкапится по умолчанию.
        try? ModelStorage.excludeFromBackup(url)
        ModelSpec.select(file.descriptor, fileURL: file.url)
        ModelDiscovery.refreshAndNotify()
        return file
    }

    /// Убрать файл из «Файлов» внутрь приложения, чтобы его нельзя было снести случайно.
    ///
    /// ⚠️ Это ПЕРЕИМЕНОВАНИЕ, а не копия: Documents и Application Support лежат в одном
    /// контейнере на одном томе, поэтому перенос мгновенный и не стоит ни одного лишнего
    /// байта. Опасение «копия на 2 ГБ = двойной расход места» относится только к файлам
    /// ИЗВНЕ песочницы.
    @discardableResult
    public static func moveIntoAppStorage(_ file: DiscoveredModelFile) throws -> DiscoveredModelFile {
        guard file.location != .appStorage, file.location != .bundle else { return file }

        let destination = try ModelStorage.modelsDirectory().appendingPathComponent(file.fileName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ModelImportError.copyFailed(
                reason: "внутри приложения уже лежит файл с таким именем — сначала удалите его"
            )
        }

        do {
            try FileManager.default.moveItem(at: file.url, to: destination)
        } catch {
            throw ModelImportError.copyFailed(reason: error.localizedDescription)
        }

        try? ModelStorage.excludeFromBackup(destination)
        // Кэш движка собран под прежний путь модели — после переноса он недействителен.
        // Папки Apple это не касается: её движок своего кэша здесь не держит, а чужой
        // сносить незачем — работающая модель человека потеряла бы его на ровном месте.
        if !file.isFolder {
            ModelStorage.clearEngineCache()
        }

        guard let moved = ModelDiscovery.describe(destination) else {
            throw ModelImportError.copyFailed(reason: "файл перенесён, но перестал читаться")
        }
        // Активной моделью делаем только то, что есть чем запустить (см. `rememberFolder`).
        if moved.isFolder {
            rememberFolder(moved.url, model: moved.descriptor)
        } else {
            ModelSpec.select(moved.descriptor, fileURL: moved.url)
        }
        ModelDiscovery.refreshAndNotify()
        return moved
    }

    /// Сколько места на телефоне уйдёт, если ставить этот файл копированием.
    /// 0 — копии не будет вовсе: файл внутри песочницы, он просто переедет.
    /// Это число экран показывает человеку ДО того, как он согласится.
    ///
    /// ⚠️ Оригинал, лежащий ВНЕ приложения (iCloud Drive, «Загрузки», другое приложение),
    /// после копирования остаётся на месте, и удалить его за человека приложение не может —
    /// прав на чужие папки у него нет. Поэтому честная формулировка на экране такая:
    /// «займёт ещё столько-то; ваш исходный файл останется в „Файлах“ — удалите его сами,
    /// если нужно место». Обещать автоматическую уборку нельзя.
    /// ⚠️ У папки-модели это сумма по всем её файлам: `ModelStorage.byteSize` про папку
    /// спрашивает именно так, поэтому отдельной ветки здесь не нужно.
    public static func copyCostBytes(for url: URL) -> Int64 {
        isInsideAppContainer(url) ? 0 : ModelStorage.byteSize(of: url)
    }

    // MARK: - Мелочи

    /// Запомнить, какой файл теперь рабочий. Хранением занимается ModelSpec:
    /// он кладёт описание модели и путь ОТНОСИТЕЛЬНО домашней папки приложения,
    /// поэтому выбор переживает и перезапуск, и переустановку.
    private static func rememberInstalled(_ url: URL, model: ModelDescriptor) {
        ModelSpec.select(model, fileURL: url)
    }

    private static func report(_ onProgress: (ModelImportProgress) -> Void,
                               _ stage: ModelImportStage,
                               _ fraction: Double,
                               _ copied: Int64,
                               _ total: Int64) {
        onProgress(ModelImportProgress(stage: stage,
                                       fraction: fraction,
                                       copiedBytes: copied,
                                       totalBytes: total))
    }

    /// Лежит ли файл внутри песочницы самого приложения (папка «Карманный агент» в «Файлах»).
    private static func isInsideAppContainer(_ url: URL) -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(home + "/")
    }

    /// Один и тот же файл на диске (сравниваем по разрешённому пути, а не по URL).
    private static func sameFile(_ left: URL, _ right: URL) -> Bool {
        left.resolvingSymlinksInPath().standardizedFileURL.path
            == right.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

// MARK: - Что установлено и как это удалить

/// Сколько места занимает модель на телефоне и как её убрать.
/// Вынесено отдельно от `ModelStorage`, чтобы экраны спрашивали про «установленное»
/// одним понятным именем, а не собирали сумму из трёх разных мест.
public enum ModelInstallation {

    /// Сколько байт занимает установленная модель вместе со служебным кэшем движка.
    /// 0 — устанавливать нечего (модель не скачана и не импортирована).
    ///
    /// ⚠️ Модель, вшитая в само приложение, сюда не попадает: удалить её нельзя,
    /// и обещать освобождение места было бы обманом.
    public static func occupiedBytes(for model: ModelDescriptor = ModelSpec.descriptor) -> Int64 {
        let file = ModelStorage.downloadedBytes(for: model)
        // ⚠️ Недокопированный хвост считаем ТОЖЕ. Приложение могли убить прямо во время
        // установки из файла, и тогда в хранилище лежат гигабайты, о которых человек
        // не знает и которые ниоткуда не видны. Молчать о занятом месте нельзя.
        let leftover = leftoverImportBytes(for: model)
        guard file > 0 || leftover > 0 else { return 0 }
        return file + leftover + engineCacheBytes()
    }

    /// Есть ли что удалять.
    public static func isRemovable(_ model: ModelDescriptor = ModelSpec.descriptor) -> Bool {
        occupiedBytes(for: model) > 0
    }

    /// Сколько весит хвост незаконченной установки.
    private static func leftoverImportBytes(for model: ModelDescriptor) -> Int64 {
        guard let url = ModelImporter.temporaryFileURL(for: model),
              FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return ModelStorage.byteSize(of: url)
    }

    /// Удалить установленную модель и всё служебное вокруг неё.
    /// - Returns: сколько байт освободилось на самом деле.
    @discardableResult
    public static func remove(model: ModelDescriptor = ModelSpec.descriptor) throws -> Int64 {
        // Удалять файл из-под работающей загрузки нельзя: она пишет ровно туда же.
        guard !ModelDownloader.shared.isDownloading else {
            throw ModelImportError.downloadInProgress
        }
        let freed = occupiedBytes(for: model)
        try ModelStorage.removeDownloadedModel(model)
        // Хвост незаконченной установки убираем тем же движением.
        if let leftover = ModelImporter.temporaryFileURL(for: model) {
            try? FileManager.default.removeItem(at: leftover)
        }
        // ⚠️ У модели Apple хвостов больше: она качается по файлам, и у каждого своя
        // точка докачки и свои недособранные куски (до гигабайтов). В списке моделей
        // их не видно, в занятом месте не посчитать — значит, убрать их человек может
        // только здесь, вместе с самой моделью.
        if model.isFolderModel {
            ModelDownloader.shared.discardFolderParts(of: model)
        }
        // Кэш движка без модели — просто мусор.
        ModelStorage.clearEngineCache()
        return freed
    }

    // MARK: - Все файлы моделей, а не одна из каталога

    /// Сколько занимают ВСЕ файлы моделей на телефоне — и скачанные, и положенные
    /// человеком в «Файлы». Для честного ответа на вопрос «сколько это ест места».
    ///
    /// ⚠️ Модель, вшитую в приложение, не считаем: удалить её нельзя, и обещать
    /// освобождение места было бы обманом.
    public static func occupiedBytesOfAllFiles() -> Int64 {
        let files = ModelDiscovery.cached.isEmpty ? ModelDiscovery.rescan() : ModelDiscovery.cached
        let models = files
            .filter { $0.location != .bundle }
            .reduce(Int64(0)) { $0 + $1.byteSize }
        guard models > 0 else { return 0 }
        return models + engineCacheBytes()
    }

    /// Удалить ОДИН конкретный файл модели — тот, который человек выбрал в списке.
    /// - Returns: сколько байт освободилось.
    @discardableResult
    public static func remove(file: DiscoveredModelFile) throws -> Int64 {
        guard file.location != .bundle else { return 0 }
        // Удалять файл из-под работающей загрузки нельзя: она пишет ровно туда же.
        guard !ModelDownloader.shared.isDownloading else {
            throw ModelImportError.downloadInProgress
        }

        let freed = ModelStorage.byteSize(of: file.url)
        do {
            try FileManager.default.removeItem(at: file.url)
        } catch {
            throw PocketAgentError.writeFailed(path: file.fileName,
                                               reason: SystemErrorText.russian(for: error))
        }

        // Удалили именно ту модель, которая была выбрана, — выбор больше не действителен.
        if ModelSpec.choice?.relativePath == file.relativePath {
            ModelSpec.clearSelection()
        }
        // Кэш движка собран под удалённый файл — без модели это просто мусор.
        ModelStorage.clearEngineCache()
        ModelDiscovery.refreshAndNotify()
        return freed
    }

    /// Размер кэша движка. Папка маленькая (несколько файлов), обход дешёвый.
    private static func engineCacheBytes() -> Int64 {
        guard let dir = try? ModelStorage.engineCacheDirectory(),
              let items = FileManager.default.enumerator(at: dir,
                                                         includingPropertiesForKeys: [.fileSizeKey],
                                                         options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in items {
            total += ModelStorage.byteSize(of: url)
        }
        return total
    }
}
