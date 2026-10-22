//
//  ModelVerifier.swift
//  PocketAgent / Runtime
//
//  Проверка файла модели.
//
//  ⚠️ ГЛАВНОЕ ИЗМЕНЕНИЕ (09.08.2026). Раньше единственной проверкой было «размер и сумма
//  сошлись с ОДНОЙ зашитой моделью». Любой другой годный файл получал отказ
//  «это не тот файл: весит 3,66 ГБ, а нужен ровно 2,01 ГБ». Это брак: файл был рабочий.
//
//  Теперь проверка идёт по СОДЕРЖИМОМУ файла, и эталон нужен только тогда, когда он есть:
//
//    1. Файл узнали по справочнику (сумма или имя с размером) — показываем имя модели
//       и, если файл скачали мы сами, дополнительно сверяем sha256.
//    2. Файл не узнали, но он выглядит настоящим — принимаем как «неизвестную модель»
//       и честно говорим человеку, что за неё никто не ручается.
//    3. Отказываем ТОЛЬКО явному мусору: не тот формат, пустой файл, слишком маленький
//       файл, сборка для браузера (она на телефоне не работает никогда).
//
//  ⚠️ «НЕДОКАЧАН» БОЛЬШЕ НЕ ОТКАЗ (10.08.2026). Целостность мы не читаем, а угадываем
//  перебором чисел в заголовке, и на файле не из семейства Gemma догадка соврала:
//  целый Qwen2.5-Coder-3B получил «файл скачан не полностью» и не запускался. Теперь
//  это оговорка рядом с кнопкой, а при совпадении размера с точным ожидаемым — молчание.
//
//  ЧТО ЧИТАЕМ ИЗ ФАЙЛА (первые ~2 КБ, это мгновение против секунд на sha256 по 2,6 ГБ):
//    • байты 0…7      — метка «LITERTLM», единственный и достаточный признак формата;
//    • байты 8…19     — версия формата (старшая, средняя, младшая);
//    • байты 24…31    — адрес конца заголовка;
//    • далее до этого адреса — описание секций, откуда мы берём:
//        – конец последних данных (проверка «файл скачан целиком» БЕЗ зашитого размера),
//        – пометку «gpu_artisan» (модель пойдёт только на видеочипе),
//        – пометку текстового декодера (это языковая модель, а не, скажем, поисковая),
//        – пометки картинок и звука (vision_encoder, audio_adapter и подобные) — такая
//          сборка просит больше памяти, а её части для картинок и звука движок умеет
//          поднимать отдельно. Человеку про это ничего не пишем: такие модели работают.
//
//  ⚠️ ПОЧЕМУ ВСЁ ЭТО НАДО ДЕЛАТЬ ДО ЗАПУСКА ДВИЖКА. Движок на негодный файл отвечает
//  пустотой: функция создания возвращает NULL без текста, и наружу приходит безликое
//  «Failed to create engine». Причину оттуда достать нельзя вообще — значит объяснять
//  человеку, что не так, обязаны мы сами и заранее.
//

import Foundation
import CryptoKit

// MARK: - Что известно про целостность файла

/// Сходится ли объявленный внутри файла объём данных с тем, что лежит на диске.
///
/// ⚠️ ЭТО ДОГАДКА, А НЕ ПРИГОВОР (переписано 10.08.2026). Ни одно из значений здесь
/// не запрещает запуск модели: конец данных мы не читаем из отведённого поля, а ИЩЕМ
/// перебором чисел в заголовке, и подобран этот поиск на файлах одного семейства.
/// На файле другого семейства он ошибается — живой случай владельца ниже, в `inspect`.
public enum LiteRTLMIntegrity: String, Sendable, Equatable {
    /// Данные заканчиваются там же, где файл. Файл скачан целиком.
    case confirmed
    /// Похоже, что данных внутри объявлено больше, чем есть. Повод предупредить.
    case truncated
    /// Понять не удалось. Не повод отказывать — повод не обещать лишнего.
    case unknown
}

// MARK: - Что умеет модель, кроме текста

/// Откуда мы узнали, что модель не только текстовая.
public enum ModelModalitySource: String, Sendable, Equatable {
    /// Прочитали в самом файле — это самый надёжный источник.
    case header
    /// Файла не спросили или он промолчал, но модель узнана справочником.
    case catalog
    /// Признаков не нашли: считаем модель текстовой.
    case none
}

/// Что, кроме текста, лежит внутри файла модели.
///
/// ⚠️ ЗАЧЕМ ЭТО НУЖНО И ЧЕГО ЗДЕСЬ НЕТ. Движок создаёт исполнителей картинок и звука
/// ТОЛЬКО если их попросили (`visionBackend`/`audioBackend`); по умолчанию их нет вовсе.
/// Сначала мы решили, что молчание Gemma 4 E4B — из-за этого, и ошиблись: официальный
/// пример Google для iOS гоняет мультимодальную Gemma 4, не прося исполнителей вовсе,
/// а рабочие сторонние приложения держат их выключенными нарочно — они стоят сотни
/// мегабайт памяти. Поэтому признак нужен для ДВУХ вещей: честного порога памяти
/// и будущей работы с картинками, — а не для объяснения молчания.
public struct ModelModalities: Sendable, Equatable {

    /// Внутри есть части для картинок.
    public let hasVision: Bool
    /// Внутри есть части для звука.
    public let hasAudio: Bool
    /// Откуда узнали.
    public let source: ModelModalitySource

    public init(hasVision: Bool, hasAudio: Bool, source: ModelModalitySource) {
        self.hasVision = hasVision
        self.hasAudio = hasAudio
        self.source = source
    }

    /// Ничего, кроме текста.
    public static let textOnly = ModelModalities(hasVision: false, hasAudio: false, source: .none)

    /// Модель не только текстовая.
    public var isMultimodal: Bool { hasVision || hasAudio }

    /// Строка для журнала: «картинки: да · звук: да · узнали: из самого файла».
    public var journalLine: String {
        let place: String
        switch source {
        case .header:  place = "из самого файла"
        case .catalog: place = "из справочника приложения"
        case .none:    place = "признаков не нашли"
        }
        return "картинки: \(hasVision ? "да" : "нет") · звук: \(hasAudio ? "да" : "нет") · узнали: \(place)"
    }
}

/// Разбор начала файла .litertlm.
public struct LiteRTLMHeaderInfo: Sendable, Equatable {

    /// Старшая часть версии формата. Читатель Google отвергает файл только при её несовпадении.
    public let majorVersion: UInt32
    public let minorVersion: UInt32
    public let patchVersion: UInt32
    /// Где кончается заголовок (байт от начала файла).
    public let headerEndOffset: Int64
    /// Размер файла на диске.
    public let fileSize: Int64
    /// Конец последних данных по записи внутри файла. nil — узнать не удалось.
    public let declaredDataEnd: Int64?
    /// Внутри есть запись о текстовом декодере — то есть это языковая модель.
    public let hasTextDecoder: Bool
    /// Внутри есть части для картинок (vision_encoder, vision_adapter и подобные).
    public let hasVisionParts: Bool
    /// Внутри есть части для звука (audio_encoder, audio_adapter и подобные).
    public let hasAudioParts: Bool
    /// Внутри стоит ограничение «только видеочип» (gpu_artisan).
    public let requiresGPU: Bool
    /// Сходится ли объём данных с размером файла.
    public let integrity: LiteRTLMIntegrity

    /// «1.5.0» — как это пишет сам Google.
    public var versionText: String {
        "\(majorVersion).\(minorVersion).\(patchVersion)"
    }

    /// Что модель умеет кроме текста — по тому, что написано в самом файле.
    public var modalities: ModelModalities {
        ModelModalities(hasVision: hasVisionParts,
                        hasAudio: hasAudioParts,
                        source: (hasVisionParts || hasAudioParts) ? .header : .none)
    }

    /// Сколько байт не хватает до объявленного конца данных (для текста ошибки).
    public var missingBytes: Int64 {
        guard let declaredDataEnd, declaredDataEnd > fileSize else { return 0 }
        return declaredDataEnd - fileSize
    }

    /// Разбора не было и быть не могло: модель лежит ПАПКОЙ (формат Apple), а начало
    /// файла .litertlm — понятие не про неё.
    ///
    /// ⚠️ Пустышка, а не «плохой заголовок»: единственный, кто её создаёт, —
    /// `MLXModelFolder.fileReport`, и он же сам пишет все оговорки для человека.
    /// Ни одна проверка по этим нулям не делается: папка проверяется по своему составу.
    static let notApplicable = LiteRTLMHeaderInfo(majorVersion: 0,
                                                 minorVersion: 0,
                                                 patchVersion: 0,
                                                 headerEndOffset: 0,
                                                 fileSize: 0,
                                                 declaredDataEnd: nil,
                                                 hasTextDecoder: false,
                                                 hasVisionParts: false,
                                                 hasAudioParts: false,
                                                 requiresGPU: false,
                                                 integrity: .unknown)
}

// MARK: - Чтение заголовка

/// Разбор начала файла .litertlm. Все смещения — из исходников Google
/// (schema/core/litertlm_read.cc, python/litert_lm_builder/litertlm_core.py)
/// и проверены на шести живых файлах разных поколений.
enum LiteRTLMHeader {

    /// Первые восемь байт настоящего файла модели.
    static let magicBytes: [UInt8] = Array("LITERTLM".utf8)
    /// С этого байта начинается описание секций.
    static let headerBeginOffset = 32
    /// По этому смещению лежит адрес конца заголовка (8 байт, младший байт первым).
    static let headerEndLocationOffset = 24
    /// Данные внутри файла выравниваются по этому блоку — отсюда допуск проверки целостности.
    static let blockSize: Int64 = 16 * 1024
    /// Заголовки живых файлов укладывались в 704…1872 байта. Берём с большим запасом.
    static let maxHeaderBytes: Int64 = 1024 * 1024
    /// Файл меньше этого моделью быть не может (самая маленькая известная Gemma — 289 МБ,
    /// но оставляем большой запас, чтобы не отсечь что-то необычное).
    static let minimumModelBytes: Int64 = 16 * 1024 * 1024

    /// Прочитать и разобрать начало файла.
    /// - Throws: `ModelFileError`, если это вообще не файл модели.
    static func read(from url: URL, fileSize: Int64) throws -> LiteRTLMHeaderInfo {
        let name = url.lastPathComponent

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ModelFileError.unreadable(name: name, reason: SystemErrorText.russian(for: error))
        }
        defer { try? handle.close() }

        // Шаг 1: первые 32 байта — метка, версия и адрес конца заголовка.
        let headBytes = try readBytes(handle, count: headerBeginOffset, name: name)
        guard headBytes.count >= headerBeginOffset else {
            throw ModelFileError.notAModel(name: name)
        }
        guard Array(headBytes.prefix(magicBytes.count)) == magicBytes else {
            throw ModelFileError.notAModel(name: name)
        }

        let major = uint32LE(headBytes, 8) ?? 0
        let minor = uint32LE(headBytes, 12) ?? 0
        let patch = uint32LE(headBytes, 16) ?? 0

        // Читатель Google сверяет ТОЛЬКО старшую версию: остальное меняется свободно.
        guard major == 1 else {
            throw ModelFileError.unsupportedVersion(name: name,
                                                    version: "\(major).\(minor).\(patch)")
        }

        let rawHeaderEnd = uint64LE(headBytes, headerEndLocationOffset) ?? 0
        guard rawHeaderEnd > UInt64(headerBeginOffset) else {
            throw ModelFileError.notAModel(name: name)
        }
        // Заголовок не помещается в файл — файл обрезан почти в самом начале.
        //
        // ⚠️ ЕДИНСТВЕННЫЙ ОТКАЗ ПРО НЕДОКАЧАННОСТЬ, КОТОРЫЙ ОСТАЛСЯ, И ЭТО НЕ ДОГАДКА:
        // адрес конца заголовка лежит в отведённом ему месте (байты 24…31), а не ищется
        // перебором. Если он указывает за конец файла — читать описание секций попросту
        // неоткуда, и никакой запуск невозможен. Всё остальное про целостность теперь
        // предупреждение, а не запрет (см. `inspect`).
        // ⚠️ Разницу считаем в UInt64 и только потом сужаем: у испорченного файла здесь
        // может лежать любое число вплоть до предельного, а перевод такого в Int64 —
        // это аварийная остановка приложения, а не ошибка.
        guard rawHeaderEnd <= UInt64(fileSize) else {
            let missing = rawHeaderEnd - UInt64(fileSize)
            throw ModelFileError.truncated(name: name,
                                           missingBytes: missing > UInt64(Int64.max) ? 0 : Int64(missing))
        }

        let headerEnd = Int64(rawHeaderEnd)
        let readLength = Int(min(headerEnd, maxHeaderBytes))

        // Шаг 2: сам заголовок целиком.
        do {
            try handle.seek(toOffset: 0)
        } catch {
            throw ModelFileError.unreadable(name: name, reason: SystemErrorText.russian(for: error))
        }
        let bytes = try readBytes(handle, count: readLength, name: name)
        guard bytes.count > headerBeginOffset else {
            throw ModelFileError.notAModel(name: name)
        }

        // Шаг 3: что внутри написано про содержимое.
        let scanFrom = headerBeginOffset
        let scanTo = bytes.count

        // Названия видов секций лежат в заголовке обычным текстом, поэтому ищем их
        // как есть, без разбора структуры. Регистр разный: у старой Gemma 3 (формат 1.0.0)
        // написано ЗАГЛАВНЫМИ — TF_LITE_PREFILL_DECODE.
        let hasDecoder = containsASCII("prefill_decode", in: bytes, from: scanFrom, to: scanTo)
            || containsASCII("artisan_text_decoder", in: bytes, from: scanFrom, to: scanTo)
        let gpuOnly = containsASCII("gpu_artisan", in: bytes, from: scanFrom, to: scanTo)

        // Картинки и звук. Ищем ОБРЫВКИ слов с подчёркиванием, а не голые «vision»/«audio»:
        // так под пометку попадают все известные написания — TF_LITE_VISION_ENCODER,
        // artisan_vision_encoder, static_audio_encoder, audio_adapter, — и при этом
        // случайное слово вроде «division» пометкой не станет.
        // ⚠️ Имена именно такие: ровно так называются кэши, которые приложение Google
        // оставило рядом с файлом E4B на телефоне владельца (vision_encoder,
        // audio_adapter, static_audio_encoder).
        let hasVision = containsASCII("vision_", in: bytes, from: scanFrom, to: scanTo)
            || containsASCII("_vision", in: bytes, from: scanFrom, to: scanTo)
        let hasAudio = containsASCII("audio_", in: bytes, from: scanFrom, to: scanTo)
            || containsASCII("_audio", in: bytes, from: scanFrom, to: scanTo)

        let scan = scanDataEnd(bytes, from: scanFrom, to: scanTo, fileSize: fileSize)

        return LiteRTLMHeaderInfo(majorVersion: major,
                                  minorVersion: minor,
                                  patchVersion: patch,
                                  headerEndOffset: headerEnd,
                                  fileSize: fileSize,
                                  declaredDataEnd: scan.declaredEnd,
                                  hasTextDecoder: hasDecoder,
                                  hasVisionParts: hasVision,
                                  hasAudioParts: hasAudio,
                                  requiresGPU: gpuOnly,
                                  integrity: scan.integrity)
    }

    // MARK: Проверка целостности без зашитого размера

    private struct DataEndScan {
        let declaredEnd: Int64?
        let integrity: LiteRTLMIntegrity
    }

    /// Найти в заголовке конец последних данных и сравнить его с размером файла.
    ///
    /// ⚠️ ПОЧЕМУ ЭТО РАБОТАЕТ И ПОЧЕМУ НЕ ДАЁТ ЛОЖНЫХ ОТКАЗОВ.
    /// Границы всех секций записаны в заголовке восьмибайтовыми числами, выровненными
    /// по восьми байтам от начала файла (заголовок начинается с байта 32, тоже кратного
    /// восьми). Мы перебираем ВСЕ такие числа — значит настоящий «конец последней секции»
    /// среди них обязательно есть. У целого файла он отстоит от конца файла меньше чем на
    /// блок выравнивания (замеры на шести файлах: 0, 0, 88, 3568, 9392, 11760 байт при
    /// блоке 16384). Берём наибольшее число, не превышающее размер файла: оно не может
    /// оказаться меньше настоящего конца данных, значит у целого файла зазор всегда мал —
    /// случайные числа могут только «помочь», но не оболгать.
    ///
    /// Обратное — отказ — выносим лишь при ДВУХ условиях сразу: зазор велик И в заголовке
    /// есть число, которое указывает ЗА конец файла, но в разумных пределах (до восьми
    /// размеров файла). Так недокачанный файл виден, а на целом обвинение невозможно.
    private static func scanDataEnd(_ bytes: [UInt8],
                                    from: Int,
                                    to: Int,
                                    fileSize: Int64) -> DataEndScan {
        guard fileSize > 0, to - from >= 8 else {
            return DataEndScan(declaredEnd: nil, integrity: .unknown)
        }

        let limit = UInt64(fileSize)
        // Верхняя граница правдоподобия: дальше — уже не смещение, а метка времени
        // или кусок строки, случайно прочитанный как число.
        let plausibleCeiling = limit > (UInt64.max / 8) ? UInt64.max : limit * 8

        var best: UInt64 = 0
        var claimsBeyondFile = false

        // Начинаем с первого смещения, кратного восьми.
        var offset = from + ((8 - (from % 8)) % 8)
        while offset + 8 <= to {
            if let value = uint64LE(bytes, offset) {
                if value <= limit {
                    if value > best { best = value }
                } else if value <= plausibleCeiling {
                    claimsBeyondFile = true
                }
            }
            offset += 8
        }

        // Ни одного числа в пределах файла: сказать нечего. Если при этом что-то
        // указывает за конец файла — это недокачанный файл.
        guard best > 0 else {
            return DataEndScan(declaredEnd: nil,
                               integrity: claimsBeyondFile ? .truncated : .unknown)
        }

        let declared = Int64(best)
        let gap = fileSize - declared
        if gap >= 0 && gap < blockSize {
            return DataEndScan(declaredEnd: declared, integrity: .confirmed)
        }
        return DataEndScan(declaredEnd: declared,
                           integrity: claimsBeyondFile ? .truncated : .unknown)
    }

    // MARK: Мелкие помощники

    private static func readBytes(_ handle: FileHandle, count: Int, name: String) throws -> [UInt8] {
        guard count > 0 else { return [] }
        do {
            let data = try handle.read(upToCount: count) ?? Data()
            return [UInt8](data)
        } catch {
            throw ModelFileError.unreadable(name: name, reason: SystemErrorText.russian(for: error))
        }
    }

    /// Четыре байта, младший первым.
    static func uint32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        var index = offset + 3
        while index >= offset {
            value = (value << 8) | UInt32(bytes[index])
            index -= 1
        }
        return value
    }

    /// Восемь байт, младший первым.
    static func uint64LE(_ bytes: [UInt8], _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        var value: UInt64 = 0
        var index = offset + 7
        while index >= offset {
            value = (value << 8) | UInt64(bytes[index])
            index -= 1
        }
        return value
    }

    /// Поиск текста в куске файла без учёта регистра (только латиница — этого достаточно,
    /// все служебные слова внутри файла английские).
    static func containsASCII(_ needle: String, in bytes: [UInt8], from: Int, to: Int) -> Bool {
        let pattern = Array(needle.lowercased().utf8)
        guard !pattern.isEmpty, from >= 0, to <= bytes.count, to - from >= pattern.count else {
            return false
        }

        let last = to - pattern.count
        var start = from
        while start <= last {
            var matched = true
            var index = 0
            while index < pattern.count {
                if lowercasedASCII(bytes[start + index]) != pattern[index] {
                    matched = false
                    break
                }
                index += 1
            }
            if matched { return true }
            start += 1
        }
        return false
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        // 'A'…'Z' → 'a'…'z'
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }
}

// MARK: - Чтение заголовка GGUF

/// Разбор начала файла GGUF — формата отдельного движка (llama.cpp).
///
/// ⚠️ Устройство заголовка взято из описания самого формата (исходники llama.cpp,
/// `gguf-py`):
///   • байты 0…3    — метка «GGUF»;
///   • байты 4…7    — версия формата (сейчас живут вторая и третья);
///   • байты 8…15   — сколько весовых матриц внутри (у настоящей модели их много);
///   • байты 16…23  — сколько записей-сведений (имя модели, словарь и прочее).
/// Этого достаточно, чтобы отличить настоящий файл от мусора и обрывка в начале.
///
/// ⚠️ БОЛЬШЕ МЫ ИЗ GGUF НЕ ЧИТАЕМ НАМЕРЕННО. Полная проверка «докачан ли файл»
/// потребовала бы разбора всех сведений и таблиц сжатия — сотни строк, которые нечем
/// проверить без живого файла. А точный размер наших моделей и так известен из
/// справочника или из плана загрузки: сравнение с ним (в `ModelVerifier`) и есть
/// проверка, причём фактами, а не догадкой по разметке.
enum GGUFHeader {

    /// Первые четыре байта настоящего GGUF-файла: латинское «GGUF».
    static let magicBytes: [UInt8] = Array("GGUF".utf8)

    /// Версии формата, которые понимает движок. Первая — древность с другим
    /// устройством счётчиков, её давно никто не выкладывает; новее третьей движок не читает.
    static let supportedVersions: ClosedRange<UInt32> = 2...3

    struct Info: Sendable, Equatable {
        /// Версия формата — вторая или третья.
        let version: UInt32
        /// Сколько весовых матриц обещает заголовок. Ноль — это не модель.
        let tensorCount: UInt64
    }

    /// Прочитать и проверить первые 24 байта файла.
    /// - Throws: `ModelFileError`, если это не GGUF или файл побит в самом начале.
    static func read(from url: URL, fileSize: Int64) throws -> Info {
        let name = url.lastPathComponent

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ModelFileError.unreadable(name: name, reason: SystemErrorText.russian(for: error))
        }
        defer { try? handle.close() }

        // ⚠️ Своя копия `readBytes`: помощник «Лите-разборщика» закрыт `private`,
        // и расширять его видимость ради соседа не стоит.
        func readBytes(_ count: Int) throws -> [UInt8] {
            do {
                let data = try handle.read(upToCount: count) ?? Data()
                return [UInt8](data)
            } catch {
                throw ModelFileError.unreadable(name: name,
                                                reason: SystemErrorText.russian(for: error))
            }
        }

        let headBytes = try readBytes(24)
        guard headBytes.count >= 24 else {
            // Файл короче собственной шапки: не GGUF либо обрывок в самом начале.
            // Оба случая для человека звучат одинаково — «это не файл модели».
            throw ModelFileError.notAModel(name: name)
        }
        guard Array(headBytes.prefix(magicBytes.count)) == magicBytes else {
            throw ModelFileError.notAModel(name: name)
        }

        let version = LiteRTLMHeader.uint32LE(headBytes, 4) ?? 0
        guard supportedVersions.contains(version) else {
            throw ModelFileError.ggufNewFormat(name: name, version: version)
        }

        let tensorCount = LiteRTLMHeader.uint64LE(headBytes, 8) ?? 0
        guard tensorCount > 0 else {
            throw ModelFileError.ggufNoTensors(name: name)
        }

        return Info(version: version, tensorCount: tensorCount)
    }
}

// MARK: - Результат проверки

/// Насколько мы уверены в том, что за файл нам дали.
public enum ModelFileConfidence: String, Sendable, Equatable {
    /// Файл узнан и контрольная сумма сошлась байт в байт.
    case verified
    /// Файл узнан по имени и размеру, сумму не считали (это долго — секунды на гигабайтах).
    case recognized
    /// Справочник такого файла не знает. Формат правильный, но поручиться не за что.
    case unknown
}

/// Что мы поняли про файл, который человек принёс или скачал.
public struct ModelFileReport: Sendable, Equatable {

    /// Имя файла как есть.
    public let fileName: String
    /// Размер файла на диске.
    public let byteSize: Int64
    /// Описание модели, готовое к работе: из справочника, если узнали, иначе собранное по файлу.
    public let descriptor: ModelDescriptor
    /// Узнанная модель из справочника. nil — такого файла мы не знаем.
    public let known: ModelDescriptor?
    /// Насколько уверены.
    public let confidence: ModelFileConfidence
    /// Разбор начала файла.
    public let header: LiteRTLMHeaderInfo
    /// Честные оговорки для человека — их показывают рядом с кнопкой «Использовать».
    public let warnings: [String]
    /// Модель лежит ПАПКОЙ (формат Apple MLX), а не одним файлом.
    /// Тогда `byteSize` — это сумма по папке, а `header` не значит ничего.
    public let isFolder: Bool

    public init(fileName: String,
                byteSize: Int64,
                descriptor: ModelDescriptor,
                known: ModelDescriptor?,
                confidence: ModelFileConfidence,
                header: LiteRTLMHeaderInfo,
                warnings: [String],
                isFolder: Bool = false) {
        self.fileName = fileName
        self.byteSize = byteSize
        self.descriptor = descriptor
        self.known = known
        self.confidence = confidence
        self.header = header
        self.warnings = warnings
        self.isFolder = isFolder
    }

    /// Тот же разбор плюс ещё одна оговорка для человека.
    public func addingWarning(_ text: String) -> ModelFileReport {
        ModelFileReport(fileName: fileName,
                        byteSize: byteSize,
                        descriptor: descriptor,
                        known: known,
                        confidence: confidence,
                        header: header,
                        warnings: warnings + [text],
                        isFolder: isFolder)
    }

    /// Тот же разбор, но контрольная сумма уже сверена с эталоном.
    public func confirmingChecksum() -> ModelFileReport {
        ModelFileReport(fileName: fileName,
                        byteSize: byteSize,
                        descriptor: descriptor,
                        known: known,
                        confidence: .verified,
                        header: header,
                        warnings: warnings,
                        isFolder: isFolder)
    }

    /// Имя, которое стоит показать человеку.
    public var displayName: String { descriptor.displayName }

    /// Файл узнан справочником.
    public var isKnownModel: Bool { known != nil }

    /// Что модель умеет кроме текста. Сначала верим самому файлу, потом справочнику.
    public var modalities: ModelModalities {
        // Модель, проверенная живьём как текстовая, остаётся текстовой — что бы ни было
        // написано у неё в заголовке. Ломать то, что работает, мы не будем.
        if let known, ModelCatalog.isProvenTextOnly(known) { return .textOnly }
        let fromHeader = header.modalities
        if fromHeader.isMultimodal { return fromHeader }
        if ModelCatalog.isKnownMultimodal(fileName: fileName, byteSize: byteSize) {
            // Заголовок промолчал, а справочник эту модель знает как «не только текст».
            // Чем именно она богата — картинками или звуком, — справочник не различает,
            // поэтому честно помечаем оба: движку всё равно поднимать обоих исполнителей.
            return ModelModalities(hasVision: true, hasAudio: true, source: .catalog)
        }
        return .textOnly
    }

    /// Модель не только текстовая — значит движку нужны отдельные исполнители.
    public var isMultimodal: Bool { modalities.isMultimodal }

    /// Одна строка-итог для карточки: «Gemma 4 E4B · 3,66 ГБ · проверена».
    public var headline: String {
        let mark: String
        switch confidence {
        case .verified:   mark = "проверена"
        case .recognized: mark = "узнана"
        case .unknown:    mark = "не проверена"
        }
        return "\(displayName) · \(HumanFormat.bytes(byteSize)) · \(mark)"
    }
}

// MARK: - Ошибки проверки файла

/// Отказы, которые человек должен понять с первого раза: что не так и что делать.
/// Помечен `HumanReadableError` намеренно — иначе разбор ошибок подменит текст
/// общим «что-то пошло не так».
public enum ModelFileError: HumanReadableError, Equatable {

    /// Файла нет.
    case missing(name: String)
    /// Файл лежит в iCloud, и на телефон он ещё не скачан.
    ///
    /// ⚠️ Отдельно от `missing` НАМЕРЕННО. У невыгруженного файла на диске лежит
    /// служебная заглушка «.имя.icloud», и обычный вопрос «файл есть?» отвечает «нет» —
    /// человек получал «файл не найден, возможно его переименовали» на совершенно целой
    /// модели, которая просто ещё в облаке. Это тупик: делать по такому совету нечего.
    case stillInCloud(name: String)
    /// Файл пустой.
    case empty(name: String)
    /// Выбрана папка, а внутри лежит НЕСКОЛЬКО файлов моделей — какой из них брать,
    /// решает человек, а не мы за него.
    case severalInsideFolder(name: String, count: Int)
    /// Расширение не то.
    case wrongExtension(name: String)
    /// Это наш собственный недоделанный кусок — файл с хвостом «.import».
    ///
    /// ⚠️ ОТДЕЛЬНО ОТ `wrongExtension` НАМЕРЕННО, и это прямая жалоба владельца 10.08.2026:
    /// приложение отвечало ему «не файл модели, нужен файл с расширением .litertlm» на файл,
    /// который создало САМО, — так называется копия, пока установка не доведена до конца.
    /// Человеку нечего исправлять в этом имени: виновата оборвавшаяся установка, а не он.
    case unfinishedImport(name: String, bytes: Int64)
    /// Нет метки формата в начале файла.
    case notAModel(name: String)
    /// Файл слишком мал, чтобы быть моделью.
    case tooSmall(name: String, bytes: Int64)
    /// Формат новее, чем приложение понимает.
    case unsupportedVersion(name: String, version: String)
    /// Внутри написано, что данных больше, чем есть на диске.
    case truncated(name: String, missingBytes: Int64)
    /// Сборка для браузера — на телефоне не работает никогда.
    case browserBuild(name: String)
    /// GGUF-файл версии формата, которую движок не понимает.
    case ggufNewFormat(name: String, version: UInt32)
    /// В GGUF-файле нет ни одной весовой матрицы — моделью он быть не может.
    case ggufNoTensors(name: String)
    /// GGUF скачан не полностью. ⚠️ Это не догадка, а факт: точный размер известен
    /// из справочника или из нашего же плана загрузки, и на диске его меньше.
    case ggufTruncated(name: String, haveBytes: Int64, expectedBytes: Int64)
    /// Файл нужного размера, но содержимое отличается от эталонного.
    case checksumMismatch(name: String)
    /// Файл не читается.
    case unreadable(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "Файл «\(name)» не найден. Возможно, его переименовали или удалили."

        case .stillInCloud(let name):
            // ⚠️ ЕДИНСТВЕННАЯ формулировка про облако на весь путь установки: её же
            // берёт `ModelImportError.cloudFileNotDownloaded`. Про папку модели Apple
            // то же самое говорит `MLXFolderError.partsInCloud` — теми же словами,
            // только во множественном числе. Второй, «своей» фразы здесь заводить нельзя:
            // человек должен читать одно и то же объяснение, откуда бы ни пришёл.
            return """
            Файл «\(name)» пока хранится только в iCloud и на телефон не скачан. \
            Я попросил систему начать загрузку: откройте «Файлы», дождитесь, пока рядом с файлом \
            пропадёт значок облака, и выберите его снова.
            """

        case .severalInsideFolder(let name, let count):
            let word = HumanFormat.plural(count, "модель", "модели", "моделей")
            return "В папке «\(name)» лежат \(count) \(word) сразу. "
                + "Откройте папку и выберите ту, которая нужна."

        case .empty(let name):
            return "Файл «\(name)» пустой — в нём ноль байт. "
                + "Скорее всего, копирование оборвалось в самом начале. Скопируйте его заново."

        case .wrongExtension(let name):
            return "«\(name)» — не файл модели. Нужен файл с расширением "
                + ".\(ModelCatalog.fileExtension), например gemma-4-E2B-it.litertlm. "
                + "Если файл лежит в архиве — сначала распакуйте его."

        case .unfinishedImport(let name, let bytes):
            let weight = bytes > 0 ? " на \(HumanFormat.bytes(bytes))" : ""
            // Настоящее имя модели — то же самое без хвоста: так человеку понятнее,
            // о какой именно модели речь.
            let realName = (name as NSString).deletingPathExtension
            return "«\(realName)» до конца не установилась: загрузка оборвалась, "
                + "и на телефоне остался кусок файла\(weight). Запустить его нельзя, "
                + "и это не ваша ошибка — так называет свою копию само приложение, "
                + "пока не доведёт установку до конца. Скачайте модель заново "
                + "или выберите исходный файл ещё раз; кусок приложение уберёт само."

        case .notAModel(let name):
            return "Внутри «\(name)» нет опознавательной метки модели. "
                + "Так бывает, когда вместо файла скачалась страница с ошибкой "
                + "или когда файл ещё лежит в архиве."

        case .tooSmall(let name, let bytes):
            return "Файл «\(name)» весит всего \(HumanFormat.bytes(bytes)) — для модели этого "
                + "слишком мало. Похоже, загрузка оборвалась. Скачайте файл заново."

        case .unsupportedVersion(let name, let version):
            return "Файл «\(name)» сделан в формате версии \(version), а приложение понимает "
                + "первую версию. Обновите приложение или возьмите файл модели постарше."

        case .truncated(let name, let missing):
            if missing > 0 {
                return "Файл «\(name)» скачан не полностью: внутри записано, что данных ещё на "
                    + "\(HumanFormat.bytes(missing)) больше. Докачайте его до конца и попробуйте снова."
            }
            return "Файл «\(name)» скачан не полностью — часть данных отсутствует. "
                + "Скопируйте его на телефон заново."

        case .browserBuild(let name):
            return "«\(name)» — сборка для браузера, на телефоне она не работает. "
                + "Возьмите тот же файл без «-web» в имени."

        case .ggufNewFormat(let name, let version):
            return "Файл «\(name)» записан в формате GGUF версии \(version), а движок понимает "
                + "вторую и третью. Обновите приложение или возьмите этот же файл "
                + "в сборке постарше."

        case .ggufNoTensors(let name):
            return "Внутри «\(name)» нет весов — это не файл модели. Так бывает, когда вместо "
                + "модели скачивается служебный файл: описание, таблица или картинка."

        case .ggufTruncated(let name, let have, let expected):
            return "Файл «\(name)» не докачался: на месте должно быть \(HumanFormat.bytes(expected)), "
                + "а весит \(HumanFormat.bytes(have)). Скачайте файл заново."

        case .checksumMismatch(let name):
            return "Файл «\(name)» нужного размера, но внутри он отличается от эталонного — "
                + "скорее всего, побился при передаче на телефон. Скопируйте его ещё раз."

        case .unreadable(let name, let reason):
            return "Не удалось прочитать «\(name)»: \(reason)"
        }
    }
}

// MARK: - Проверка

public enum ModelVerifier {

    // MARK: Главный вход: понять, что за файл нам дали

    /// Разобрать файл и сказать, что это. Читает первые ~2 КБ — работает мгновенно.
    ///
    /// - Parameters:
    ///   - picked: то, что человек выбрал: файл модели, папка модели Apple или папка,
    ///     внутри которой лежит файл модели (см. `resolvePicked`).
    ///   - availableMemoryMB: сколько памяти приложение ещё может занять; нужно только
    ///     для предупреждения «может не хватить». Предупреждение НЕ запрещает работу.
    ///   - apparentName: под каким именем разбирать файл, если на диске он лежит под
    ///     служебным. ⚠️ ЭТО НЕ УДОБСТВО, А ПОЧИНКА. Установка из файла сначала кладёт
    ///     копию под временным именем «…litertlm.import» и проверяет ИМЕННО ЕЁ — а проверка
    ///     смотрела на расширение и отвечала «не файл модели, нужен файл .litertlm».
    ///     То есть любая установка копированием падала на последнем шаге, уже перекачав
    ///     гигабайты, и человек читал отказ про файл, который создали мы сами
    ///     (жалоба владельца 10.08.2026, ROADMAP 12.1).
    /// - Throws: `ModelFileError` — только на явном мусоре.
    public static func inspect(_ picked: URL,
                               availableMemoryMB: Int = MemoryGate.availableMemoryMB(),
                               named apparentName: String? = nil) throws -> ModelFileReport {

        // Человек мог выбрать не сам файл, а папку, в которой файл лежит, — разбираемся
        // с тем, что выбрано НА САМОМ ДЕЛЕ (см. `resolvePicked`).
        let url = try resolvePicked(picked)
        // Подставное имя годится только для того файла, который нам и дали: если разбор
        // ушёл внутрь папки, речь уже про другой файл, и звать его чужим именем нельзя.
        let name = (url.path == picked.path ? apparentName : nil) ?? url.lastPathComponent

        // ⚠️ ПРО ОБЛАКО СПРАШИВАЕМ ПЕРВЫМ, ДО ВОПРОСА «А ФАЙЛ ВООБЩЕ ЕСТЬ?».
        // У файла из iCloud, не выгруженного на телефон, на диске лежит заглушка
        // «.имя.icloud» — обычная проверка существования отвечает «нет», и человек
        // получал «файл не найден» на целой модели. Просим систему её выгрузить
        // и говорим, чего ждать.
        if ModelStorage.cloudState(of: url) == .placeholder {
            ModelStorage.requestCloudDownload(url)
            throw ModelFileError.stillInCloud(name: name)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ModelFileError.missing(name: name)
        }

        // ⚠️ ПАПКА ИДЁТ СВОЕЙ ДОРОГОЙ, А НЕ В ОБХОД ПРОВЕРКИ. Модель Apple — это папка
        // из восьми файлов, и метки «LITERTLM» в ней нет ни в одном байте. Проверять
        // её надо ПО СОСТАВУ (есть ли устройство модели, веса, словарь, все ли части
        // на месте) — этим занимается `MLXModelFolder`, и требования там не мягче здешних.
        // Защита от мусора для обычных файлов ниже осталась ровно такой, какой была.
        if MLXModelFolder.isFolder(url) {
            return try MLXModelFolder.fileReport(for: url, availableMemoryMB: availableMemoryMB)
        }

        // ⚠️ ХВОСТ «.import» СТАВИМ МЫ САМИ — это метка недоделанной установки. Отвечать
        // на неё «не файл модели, нужен файл .litertlm» значит ругать человека за файл,
        // который создало приложение. Говорим правду: установка оборвалась.
        if (name as NSString).pathExtension.lowercased() == ModelImporter.temporaryExtension {
            throw ModelFileError.unfinishedImport(name: name,
                                                  bytes: ModelStorage.byteSize(of: url))
        }

        // ⚠️ GGUF ИДЁТ СВОЕЙ ДОРОГОЙ, ДО ОБЩЕЙ ПРОВЕРКИ РАСШИРЕНИЯ. У файла другого
        // движка другое начало (метка «GGUF», а не «LITERTLM»), и общий путь ответил бы
        // ему «это не модель», хотя файл настоящий. У файлов Google ниже ничего не меняется.
        if (name as NSString).pathExtension.lowercased() == ModelCatalog.ggufFileExtension {
            return try inspectGGUF(url, name: name, availableMemoryMB: availableMemoryMB)
        }

        guard (name as NSString).pathExtension.lowercased() == ModelCatalog.fileExtension else {
            throw ModelFileError.wrongExtension(name: name)
        }

        let size = ModelStorage.byteSize(of: url)
        guard size > 0 else {
            throw ModelFileError.empty(name: name)
        }

        // Сборку для браузера отличить от обычной можно ТОЛЬКО по имени: она весит
        // побайтово столько же, сколько сборка для видеочипа, и заголовок у них почти
        // одинаковый. Так же поступает и Google в своём приложении.
        guard !ModelCatalog.isBrowserBuild(fileName: name) else {
            throw ModelFileError.browserBuild(name: name)
        }

        // Разбор начала файла: метка, версия, состав, целостность.
        // ⚠️ Идёт РАНЬШЕ проверки «не слишком ли мал файл» намеренно: постороннему файлу
        // с подменённым расширением надо говорить «это не модель», а не «докачайте до конца».
        let header = try LiteRTLMHeader.read(from: url, fileSize: size)

        // ⚠️ ЗДЕСЬ БЫЛ ОТКАЗ «файл скачан не полностью», И ОН БИЛ ПО ЦЕЛЫМ ФАЙЛАМ.
        // Живой случай владельца 10.08.2026: он положил Qwen2.5-Coder-3B ровно того
        // размера, что лежит у выложившего (3 433 083 824 байта), а приложение ответило
        // «часть данных отсутствует, скопируйте заново» и запустить модель не дало.
        // Врала догадка: конец данных мы ИЩЕМ перебором чисел в заголовке, и подобран
        // этот поиск на шести файлах Gemma — у другого семейства разметка своя.
        // Догадка не может быть запретом (раздел 6 дорожной карты: предупреждение,
        // а не запрет), поэтому теперь она уходит в оговорки ниже, а модель запускается.
        guard size >= LiteRTLMHeader.minimumModelBytes else {
            throw ModelFileError.tooSmall(name: name, bytes: size)
        }

        // Узнаём файл по справочнику: сначала имя с размером, потом однозначный размер.
        let known = ModelCatalog.recognize(fileName: name, byteSize: size)

        var warnings: [String] = []

        // Железо: пометка внутри файла главнее имени и главнее справочника.
        let hardwareByName = ModelCatalog.hardware(forFileName: name)
        let hardware: ModelHardware
        if header.requiresGPU {
            hardware = .gpuOnly
        } else if hardwareByName == .foreignChip {
            hardware = .foreignChip
        } else if let known {
            hardware = known.hardware
        } else {
            hardware = hardwareByName
        }

        // Описание: из справочника, если узнали, иначе собираем по самому файлу.
        // Файл могли переименовать — тогда работаем под НАСТОЯЩИМ именем файла,
        // иначе приложение будет искать его по имени из справочника и не найдёт.
        let descriptor: ModelDescriptor
        if let known {
            descriptor = known.withHardware(hardware).withFileName(name)
            if known.fileName.lowercased() != name.lowercased() {
                warnings.append("Файл переименован: узнали модель «\(known.displayName)» "
                                + "по размеру. Если это не она — сравните имя файла с тем, "
                                + "что вы скачивали.")
            }
        } else {
            descriptor = ModelDescriptor.unknown(fileName: name, byteSize: size, hardware: hardware)
        }

        // MARK: Оговорки, которые человек обязан увидеть

        if known == nil {
            warnings.append("Эта модель приложению незнакома — за неё никто не ручается. "
                            + "Формат файла правильный, запустить её можно, но как она себя поведёт, "
                            + "заранее сказать нельзя.")

            // Имя знакомое, а размер другой — почти всегда недокачанный файл.
            if let sameName = ModelCatalog.model(withFileName: name), sameName.byteSize != size {
                warnings.append("Файл называется так же, как известная модель «\(sameName.displayName)», "
                                + "но весит \(HumanFormat.bytes(size)) вместо \(sameName.humanSize). "
                                + "Проверьте, что он скачался до конца.")
            }
        }

        // MARK: Целостность — оговорка, а не отказ
        //
        // Молчим совсем, когда точный размер известен из источника, который его правда
        // знает (справочник приложения или наш же план загрузки), и он сошёлся:
        // тогда обвинять файл не в чем, что бы ни показала догадка по разметке.
        if header.integrity != .confirmed,
           !expectedSizeConfirms(fileName: name, byteSize: size) {
            switch header.integrity {
            case .truncated:
                warnings.append("Похоже, файл скачан не до конца: внутри объявлено больше "
                                + "данных, чем в нём есть. Наверняка сказать нельзя — "
                                + "у моделей разных семейств эта разметка своя. Запустить "
                                + "можно; если модель не откроется, скачайте файл заново.")
            case .unknown:
                warnings.append("Проверить, что файл скачан целиком, не удалось — "
                                + "внутренняя разметка необычная. Если модель не запустится, "
                                + "скопируйте файл заново.")
            case .confirmed:
                break
            }
        }

        if !header.hasTextDecoder {
            warnings.append("Внутри файла не нашлось привычной пометки о том, что это модель "
                            + "для разговора. Возможно, она предназначена для другого — например, "
                            + "для поиска по смыслу. Если модель не заработает, дело скорее всего в этом.")
        }

        switch hardware {
        case .gpuOnly:
            warnings.append("Эта сборка работает только на видеочипе. Если ему не хватит памяти, "
                            + "перейти на обычные вычисления не получится — модель просто не запустится.")
        case .foreignChip:
            warnings.append("Похоже, это сборка под чужой ускоритель (Qualcomm, MediaTek, Intel "
                            + "или Google Tensor) — такие на iPhone не работают. "
                            + "Возьмите обычный файл, без пометки о чипе в имени.")
        case .browserOnly, .universal:
            break
        }

        // Есть ли внутри картинки и звук. ⚠️ Человеку об этом НИЧЕГО не пишем: такая модель
        // работает — Gemma 4 E4B у владельца отвечает в приложении Google на том же самом
        // телефоне. Признак нужен только нам: на него смотрит порог памяти (эти части
        // грузятся отдельно) и последняя ступенька подбора настроек в движке.
        let knownMultimodal = ModelCatalog.isKnownMultimodal(fileName: name, byteSize: size)
        let provenTextOnly = known.map { ModelCatalog.isProvenTextOnly($0) } ?? false
        let multimodal = provenTextOnly
            ? ModelModalities.textOnly
            : ModelModalities(hasVision: header.hasVisionParts || knownMultimodal,
                              hasAudio: header.hasAudioParts || knownMultimodal,
                              source: (header.hasVisionParts || header.hasAudioParts) ? .header : .catalog)

        // Порог памяти считаем с учётом исполнителей картинок и звука: они грузятся
        // отдельно от текстовой части, и обещать «памяти хватит» по текстовой мерке —
        // значит подвести человека ровно в момент загрузки.
        if let memoryWarning = ModelMemoryRule.warning(for: descriptor,
                                                       availableMemoryMB: availableMemoryMB,
                                                       multimodal: multimodal.isMultimodal) {
            warnings.append(memoryWarning)
        }

        if let deviceNote = descriptor.deviceRequirementNote, known != nil {
            warnings.append(deviceNote)
        }

        return ModelFileReport(fileName: name,
                               byteSize: size,
                               descriptor: descriptor,
                               known: known,
                               confidence: known == nil ? .unknown : .recognized,
                               header: header,
                               warnings: warnings)
    }

    /// Похож ли файл на модель. Ничего не бросает — для перебора содержимого папки,
    /// где ошибка на каждом лишнем файле не нужна.
    public static func looksLikeModelFile(_ url: URL) -> Bool {
        (try? inspect(url)) != nil
    }

    // MARK: GGUF — файл отдельного движка

    /// Разобрать GGUF-файл (движок llama.cpp) и собрать по нему отчёт.
    ///
    /// ⚠️ ПОЧЕМУ ОТДЕЛЬНАЯ ДОРОГА, А НЕ ОБЩИЙ ПУТЬ С .litertlm. У этих файлов разное
    /// устройство начала, и общий разбор отвечал бы настоящему файлу «это не модель».
    /// Проверяем своё: метка формата, версия, счётчик весов, докачан ли файл. А вот
    /// совместимость файла с движком здесь НЕ проверяется и НЕ обещается — что файл
    /// откроется, знает только сам движок при запуске; врать о совместимости словами
    /// проверки мы не будем.
    ///
    /// ⚠️ «НЕДОКАЧАН» ЗДЕСЬ ОТКАЗ, А НЕ ОГОВОРКА — в отличие от .litertlm, где такую
    /// проверку пришлось отменить (догадка по разметке обманывалась на чужих семействах).
    /// Разница в источнике правды: у GGUF конца данных в заголовке нет, зато точный
    /// размер файла известен из справочника или из нашего же плана загрузки. Данные
    /// лежат в конце файла, значит «на диске меньше заявленного» — факт, а не догадка.
    private static func inspectGGUF(_ url: URL,
                                    name: String,
                                    availableMemoryMB: Int) throws -> ModelFileReport {
        let size = ModelStorage.byteSize(of: url)
        guard size > 0 else {
            throw ModelFileError.empty(name: name)
        }

        _ = try GGUFHeader.read(from: url, fileSize: size)

        // Докачан ли. Спрашиваем только тех, кто знает точный размер по-настоящему:
        // справочник (наши модели) и план загрузки (то, что качало само приложение).
        // Размер больше ожидаемого не ругаем: у чужих сборок он бывает разным,
        // и обвинять файл без причины нельзя.
        // Планировщик отдаёт не-опционал (0 = «ничего не знаем»), поэтому
        // склеиваем два источника руками: ноль не имеет права выглядеть размером.
        let catalogBytes = ModelCatalog.model(withFileName: name)?.byteSize
        let plannedBytes = ModelStorage.plannedTotalBytes(forFileName: name)
        let expectedBytes = catalogBytes ?? (plannedBytes > 0 ? plannedBytes : nil)
        if let expectedBytes, expectedBytes > 0, size < expectedBytes {
            throw ModelFileError.ggufTruncated(name: name,
                                               haveBytes: size,
                                               expectedBytes: expectedBytes)
        }

        let known = ModelCatalog.recognize(fileName: name, byteSize: size)

        var warnings: [String] = []
        if let known {
            // Файл могли переименовать — работаем под настоящим именем файла,
            // как и у .litertlm: иначе приложение будет искать его по имени
            // из справочника и не найдёт.
            if known.fileName.lowercased() != name.lowercased() {
                warnings.append("Файл переименован: узнали модель «\(known.displayName)» "
                                + "по размеру. Если это не она — сравните имя файла с тем, "
                                + "что вы скачивали.")
            }
        } else {
            warnings.append("Эта модель приложению незнакома — за неё никто не ручается. "
                            + "Формат файла правильный, запустить её можно, но как она себя "
                            + "поведёт, заранее сказать нельзя.")
        }

        let hardware = known?.hardware ?? ModelCatalog.hardware(forFileName: name)
        let descriptor = known.map { $0.withHardware(hardware).withFileName(name) }
            ?? ModelDescriptor.unknown(fileName: name, byteSize: size, hardware: hardware)

        // Про память говорим правилом ЭТОГО движка (`ModelFitRule`): доля файла по
        // физике llama.cpp, без выбора «видеочип или процессор», которого здесь нет.
        // Мерка замеров Google («нужно около 1985 МБ», «хватит только без ускорения»)
        // для GGUF — ложь про реальную площадку в 3,4+ ГБ. Строка та же, что человек
        // видит в списке моделей и на карточке каталога, — три места, один текст.
        let fit = ModelFitRule.fit(fileName: name,
                                   fileBytes: size,
                                   availableMemoryMB: availableMemoryMB)
        if fit.level == .tight {
            warnings.append([fit.detail, fit.memoryNote].compactMap { $0 }
                .joined(separator: " "))
        }

        return ModelFileReport(fileName: name,
                               byteSize: size,
                               descriptor: descriptor,
                               known: known,
                               confidence: known == nil ? .unknown : .recognized,
                               // Разбор начала .litertlm к GGUF неприменим — пустышка,
                               // как и у папки Apple: никто на эти нули не смотрит.
                               header: .notApplicable,
                               warnings: warnings)
    }

    /// Известен ли ТОЧНЫЙ ожидаемый размер этого файла — и сошёлся ли он с тем,
    /// что лежит на диске.
    ///
    /// ⚠️ ЭТО СИЛЬНЕЕ ЛЮБОЙ ДОГАДКИ ПО РАЗМЕТКЕ, поэтому и спрашивается первым.
    /// Точное число берут два источника, которые его правда знают: справочник приложения
    /// и наш собственный план загрузки (в нём записан размер, который назвал сервер).
    /// Сошлось — про «файл скачан не до конца» не говорим ни слова: обвинять не в чем.
    ///
    /// Спрашивать дорого (перечисление папки), поэтому зовём только тогда, когда догадка
    /// уже засомневалась.
    public static func expectedSizeConfirms(fileName: String, byteSize: Int64) -> Bool {
        guard byteSize > 0 else { return false }
        if let sameName = ModelCatalog.model(withFileName: fileName),
           sameName.byteSize == byteSize {
            return true
        }
        if ModelCatalog.recognize(fileName: fileName, byteSize: byteSize) != nil {
            return true
        }
        return ModelStorage.plannedTotalBytes(forFileName: fileName) == byteSize
    }

    // MARK: Что человек выбрал на самом деле

    /// Развернуть выбор человека в то, что мы будем ставить.
    ///
    /// Три случая, и все три встречаются живьём:
    ///  • выбран файл — берём его как есть;
    ///  • выбрана папка модели Apple — она и есть модель, оставляем папку;
    ///  • выбрана ОБЫЧНАЯ папка, а модель лежит внутри неё — берём файл изнутри.
    ///
    /// ⚠️ ЗАЧЕМ ТРЕТИЙ СЛУЧАЙ. Модель почти никогда не лежит в «Файлах» голым файлом:
    /// её кладут в папку загрузок, в папку другого приложения, в «Модели». Человек,
    /// выбравший такую папку, получал отказ «в папке нет ни одного файла модели
    /// (.safetensors)» — то есть приложение говорило «модели нет» ровно там, где она есть.
    ///
    /// ⚠️ Только ОДИН уровень и только когда файл ровно один: два файла — это выбор,
    /// и делать его за человека нельзя (`severalInsideFolder` попросит выбрать сам).
    /// Вглубь не ходим — чужие деревья в «Файлах» бывают огромными.
    public static func resolvePicked(_ url: URL) throws -> URL {
        guard MLXModelFolder.isFolder(url) else { return url }
        // Папка модели Apple — сама себе модель, разбирать её нутро здесь нечем.
        guard !MLXModelFolder.looksLikeModelFolder(url) else { return url }

        let inside = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        let models = inside.filter {
            // Файл нашего движка и файл отдельного (GGUF) равноправны. Обрезать поиск
            // одним расширением значило бы говорить «в папке нет модели» там, где она
            // лежит — просто в другом формате.
            let ext = $0.pathExtension.lowercased()
            return ext == ModelCatalog.fileExtension || ext == ModelCatalog.ggufFileExtension
        }
        if models.count > 1 {
            throw ModelFileError.severalInsideFolder(name: url.lastPathComponent,
                                                     count: models.count)
        }
        // Ни одного файла модели внутри — пусть отвечает разбор папки Apple:
        // он назовёт, чего именно в ней не хватает.
        return models.first ?? url
    }

    /// Что модель умеет кроме текста. Читает ~2 КБ начала файла — это мгновение.
    ///
    /// ⚠️ Ничего не бросает НАМЕРЕННО: это вопрос «с какими исполнителями поднимать движок»,
    /// а не проверка годности файла. Не смогли прочитать — считаем модель текстовой
    /// и идём обычным путём: не заводить исполнителей безопаснее, чем завести их наугад
    /// (текстовой модели чужие исполнители не подсунуть — движок на этом не поднимется).
    ///
    /// - Parameter descriptor: описание модели, если оно уже есть. Нужно только для
    ///   второго источника — справочника, когда сам файл про картинки и звук промолчал.
    public static func modalities(of url: URL, descriptor: ModelDescriptor? = nil) -> ModelModalities {
        let size = ModelStorage.byteSize(of: url)

        // Живой факт главнее заголовка: модель, которая на телефоне работает как текстовая,
        // мы запускаем ровно так, как запускали. См. ModelCatalog.isProvenTextOnly.
        if ModelCatalog.isProvenTextOnly(fileName: url.lastPathComponent, byteSize: size) {
            return .textOnly
        }
        if let descriptor, ModelCatalog.isProvenTextOnly(descriptor) {
            return .textOnly
        }

        if size > 0, let header = try? LiteRTLMHeader.read(from: url, fileSize: size) {
            let fromFile = header.modalities
            if fromFile.isMultimodal { return fromFile }
        }

        // Файл промолчал — спрашиваем справочник. Сначала по тому, что лежит на диске,
        // потом по описанию: файл могли переименовать, и тогда его узнали по размеру.
        var known = ModelCatalog.isKnownMultimodal(fileName: url.lastPathComponent, byteSize: size)
        if !known, let descriptor {
            known = ModelCatalog.isKnownMultimodal(descriptor)
        }
        guard known else { return .textOnly }

        return ModelModalities(hasVision: true, hasAudio: true, source: .catalog)
    }

    /// Разбор файла плюс сверка контрольной суммы — но ТОЛЬКО если эталон известен.
    ///
    /// ⚠️ Долгая: чтение всего файла, несколько секунд на гигабайтах. Звать вне главного
    /// потока. Для НЕЗНАКОМОЙ модели сверять не с чем — тогда работает обычный разбор,
    /// и это не повод отказывать: целостность уже проверена по содержимому.
    public static func inspectVerifyingChecksum(_ url: URL,
                                                availableMemoryMB: Int = MemoryGate.availableMemoryMB(),
                                                onProgress: ((Double) -> Void)? = nil) throws -> ModelFileReport {
        let report = try inspect(url, availableMemoryMB: availableMemoryMB)

        let expected = report.descriptor.sha256
        guard !expected.isEmpty else { return report }

        let hex = try checksum(url, expectedBytes: report.byteSize, onProgress: onProgress)
        guard hex.caseInsensitiveCompare(expected) == .orderedSame else {
            // ⚠️ НЕ ОТКАЗ, а оговорка. Эти же модели лежат в десятках зеркал, часть из них
            // перезалита, и полного списка известных сумм не будет никогда. Отвергать
            // годный файл из зеркала — это ровно тот отказ годному файлу, от которого
            // мы уходили. Целостность уже проверена по содержимому самого файла.
            return report.addingWarning(
                "Содержимое файла отличается от известного нам — скорее всего, "
                + "это другая сборка той же модели. Работать она может, "
                + "но поручиться за неё нельзя."
            )
        }
        return report.confirmingChecksum()
    }

    // MARK: Быстрая проверка перед запуском движка

    /// Быстрая проверка: файл на месте, метка в начале есть, размер не изменился.
    /// Зовётся при каждом запуске приложения — поэтому здесь никакого sha256.
    ///
    /// ⚠️ У GGUF своя метка начала («GGUF», версия 2/3, тензоры больше нуля) — он
    /// проверяется ею, а не «LITERTLM»: файлу другого движка чужая метка не положена.
    ///
    /// ⚠️ Для модели ИЗ СПРАВОЧНИКА размер обязан совпасть байт в байт: это ловит и обрыв
    /// загрузки, и подмену файла. Для принесённой человеком модели эталон — её собственный
    /// размер, записанный при установке: расхождение значит, что файл подменили или обрезали.
    public static func quickCheck(_ url: URL, model: ModelDescriptor) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PocketAgentError.modelFileMissing
        }

        let size = ModelStorage.byteSize(of: url)
        guard size > 0 else {
            throw PocketAgentError.modelFileCorrupted
        }

        // ⚠️ ТОЧНЫЙ РАЗМЕР СВЕРЯЕМ ТОЛЬКО У ТОГО, ЧТО СКАЧАЛИ МЫ САМИ. Это последнее
        // место, где жила та самая привязка к одной модели, и оно било по человеку уже
        // ПОСЛЕ успешной установки: файл принят, лежит на месте — а перед запуском движка
        // его размер сверялся с числом из справочника и не сходился. Человек видел
        // «Файл модели повреждён. Скачайте заново» на совершенно целом файле, который
        // качать неоткуда. Те же модели раздают десятки зеркал, часть перезалита, и
        // сходиться байт в байт они не обязаны. Для принесённого файла эталон —
        // он сам: пустоту и чужой формат ловим здесь же, ниже.
        let ourOwnDownload = model.origin == .catalog && ModelCatalog.canDownload(model)
        if ourOwnDownload, model.byteSize > 0, size != model.byteSize {
            throw PocketAgentError.modelFileCorrupted
        }

        // ⚠️ У ФАЙЛА ДРУГОГО ДВИЖКА ДРУГОЕ НАЧАЛО — ОБЩАЯ ПРОВЕРКА НИЖЕ ЕГО ЛОМАЛА.
        // У GGUF в начале лежат метка «GGUF», версия формата и счётчик весовых матриц,
        // а не «LITERTLM». Раньше импорт годного GGUF падал ровно здесь: файл сверяли
        // с чужой меткой, она не сходилась, и человек читал «содержимое отличается от
        // эталонного — побился при передаче» на совершенно целом файле. Проверяем своё:
        // та же логика, что и в разборе GGUF (`inspectGGUF`) — метка, версия 2/3,
        // тензоры больше нуля.
        //
        // ⚠️ ВИД ФАЙЛА БЕРЁМ ПО ИМЕНИ МОДЕЛИ, А НЕ ПО ИМЕНИ НА ДИСКЕ — тот же урок,
        // что у `verify` ниже: установка из файла проверяет ещё не переименованную
        // копию «X.gguf.import», и по имени на диске она снова выглядела бы не GGUF.
        // Ошибки отсюда — `ModelFileError` с готовым человеческим текстом; для файлов
        // Google ниже ничего не меняется.
        let apparentName = model.fileName.isEmpty ? url.lastPathComponent : model.fileName
        if ModelFileFormat.detect(fileName: apparentName) == .gguf {
            _ = try GGUFHeader.read(from: url, fileSize: size)
            return
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PocketAgentError.readFailed(path: url.lastPathComponent,
                                              reason: SystemErrorText.russian(for: error))
        }
        defer { try? handle.close() }

        let head: Data?
        do {
            head = try handle.read(upToCount: ModelSpec.magic.count)
        } catch {
            throw PocketAgentError.readFailed(path: url.lastPathComponent,
                                              reason: SystemErrorText.russian(for: error))
        }
        guard head == ModelSpec.magic else {
            throw PocketAgentError.modelFileCorrupted
        }
    }

    // MARK: Контрольная сумма

    /// Полная проверка sha256 — только когда эталон есть (файл скачали мы сами).
    /// Долгая: секунды на гигабайтах. Звать вне главного потока.
    /// `onProgress` получает 0…1, чтобы экран подготовки не выглядел зависшим.
    public static func verifyHash(_ url: URL,
                                  model: ModelDescriptor,
                                  onProgress: ((Double) -> Void)? = nil) throws {
        guard !model.sha256.isEmpty else {
            // Эталона нет (модель принесли, а не скачали) — сверять не с чем.
            // Это НЕ повод отказывать: целостность уже проверена по содержимому файла.
            return
        }

        let hex = try checksum(url,
                               expectedBytes: model.byteSize,
                               onProgress: onProgress)

        guard hex.caseInsensitiveCompare(model.sha256) == .orderedSame else {
            throw PocketAgentError.modelFileCorrupted
        }
    }

    /// Посчитать sha256 файла. Пригодится, чтобы один раз запомнить сумму принесённой
    /// модели и потом ловить её порчу — эталона из справочника для такой модели нет.
    /// - Parameter expectedBytes: только для показа прогресса; 0 — взять размер файла.
    @discardableResult
    public static func checksum(_ url: URL,
                                expectedBytes: Int64 = 0,
                                onProgress: ((Double) -> Void)? = nil) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PocketAgentError.readFailed(path: url.lastPathComponent,
                                              reason: SystemErrorText.russian(for: error))
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var processed: Int64 = 0
        let declared = expectedBytes > 0 ? expectedBytes : ModelStorage.byteSize(of: url)
        let total = max(declared, 1)
        let chunkSize = 4 * 1024 * 1024

        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw PocketAgentError.readFailed(path: url.lastPathComponent,
                                                  reason: SystemErrorText.russian(for: error))
            }
            guard let chunk, !chunk.isEmpty else { break }

            hasher.update(data: chunk)
            processed += Int64(chunk.count)
            onProgress?(min(1.0, Double(processed) / Double(total)))

            // Проверку целостности тоже можно отменить (пользователь ушёл с экрана).
            if Task.isCancelled { throw PocketAgentError.generationCancelled }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Проверка «под ключ»

    /// Считать ли контрольную сумму — это секунды чтения по гигабайтам.
    public enum ChecksumPolicy: Sendable, Equatable {
        /// Файл скачало САМО приложение по нашей же ссылке с закреплённой версией.
        /// Здесь эталон настоящий, и он обязан сойтись: иначе загрузка побилась.
        case required
        /// Файл принёс человек. Сумму не считаем вовсе.
        ///
        /// ⚠️ Две причины, и обе важны. Первая: эталон в справочнике относится к файлу
        /// из репозитория Google, а те же модели раздают десятки зеркал, часть из них
        /// перезалита, — годный файл получил бы отказ ровно того класса, от которого мы
        /// уходили. Вторая: это чтение 3,66 ГБ при КАЖДОЙ установке ради проверки,
        /// которая ничего не решает — целостность уже видна по содержимому файла.
        case skip
    }

    /// Полная проверка: быстрая, затем разбор содержимого, затем — если положено — сумма.
    ///
    /// ⚠️ Здесь и было главное место брака: раньше отсутствие эталона считалось поводом
    /// отказать. Теперь эталон — приятное дополнение, а решает содержимое файла.
    ///
    /// - Parameter policy: `.required` — только для того, что приложение скачало само.
    ///   Для принесённого человеком файла зовите с `.skip`.
    public static func verify(_ url: URL,
                              model: ModelDescriptor,
                              checksum policy: ChecksumPolicy = .required,
                              onProgress: ((Double) -> Void)? = nil) throws {
        try quickCheck(url, model: model)

        // Разбор содержимого: он объясняет человеку, ЧТО не так, вместо «файл повреждён».
        // Для файла из справочника это ещё и вторая линия обороны против подмены.
        //
        // ⚠️ ИМЯ БЕРЁМ У МОДЕЛИ, А НЕ У ФАЙЛА НА ДИСКЕ. Установка из файла проверяет
        // ещё не переименованную копию — «…litertlm.import», — и разбор по имени файла
        // отвергал её как «не файл модели». Именно это и ломало установку копированием
        // целиком (ROADMAP 12.1).
        _ = try inspect(url, named: model.fileName)

        // Сумму сверяем ТОЛЬКО у файлов, которые приложение скачало само по закреплённой
        // версии репозитория. У всего остального эталон либо чужой, либо его нет.
        guard policy == .required,
              model.origin == .catalog,
              ModelCatalog.canDownload(model) else { return }

        try verifyHash(url, model: model, onProgress: onProgress)
    }
}
