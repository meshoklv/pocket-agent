//
//  ModelFitRule.swift
//  PocketAgent / Runtime
//
//  Честный ответ на вопрос «пойдёт эта модель на этом телефоне или нет» — ДО того,
//  как человек потратит время и гигабайты.
//
//  ⚠️ ГЛАВНОЕ ПРАВИЛО, ИЗ-ЗА КОТОРОГО ФАЙЛ И ПОЯВИЛСЯ:
//  считать по РАЗМЕРУ ФАЙЛА и способу сжатия, НИКОГДА по числу параметров.
//  Живой факт владельца: модель Bonsai 27B «в один бит» (файл 3,8 ГБ) на его iPhone Air
//  спокойно запускается. Двадцать семь миллиардов параметров — и работает. Любое правило,
//  которое смотрит на «27B» и отвечает «не влезет», негодное по построению.
//
//  ⚠️ ВТОРОЕ ПРАВИЛО: у каждого движка СВОЯ физика памяти, и одна формула на всех
//  либо отвергнет рабочую модель, либо промолчит там, где памяти честно не хватит.
//  Поэтому расход считается отдельно для файлов Google (.litertlm), отдельно для GGUF
//  и отдельно для MLX.
//
//  ⚠️ ТРЕТЬЕ ПРАВИЛО: это ПРЕДУПРЕЖДЕНИЕ, а не запрет. Нехватка памяти никогда
//  не даёт «красную» пометку — только «жёлтую». Красная бывает ровно там, где файл
//  на iPhone не заработает в принципе (сборка для браузера или под чужой ускоритель).
//

import Foundation

// MARK: - Что за файл перед нами

/// Вид файла модели. Определяется по расширению — другого признака до скачивания нет.
///
/// ⚠️ Сегодня приложение работает с тремя видами: `.litertlm` (движок Google, один файл),
/// `.mlx` (движок Apple, ПАПКА из нескольких файлов — см. `MLXModelFolder`) и `.gguf`
/// (движок llama.cpp, один файл — работает через ОТДЕЛЬНЫЙ движок, не через Google).
/// Раньше здесь стояло «GGUF пока не работает, и врать нельзя» — теперь он запускается,
/// и правило чтения памяти (`ggufShare`) работает по-настоящему.
public enum ModelFileFormat: String, Sendable, Equatable, Codable {

    /// Формат Google: одна модель — один файл.
    case litertlm
    /// Формат движка llama.cpp.
    case gguf
    /// Формат движка Apple MLX (веса лежат в наборе файлов .safetensors).
    case mlx
    /// Что-то другое: описание, картинка, набор для дообучения.
    case other

    /// Разобрать вид файла по его имени.
    public static func detect(fileName: String) -> ModelFileFormat {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".litertlm") { return .litertlm }
        if lower.hasSuffix(".gguf") { return .gguf }
        if lower.hasSuffix(".safetensors") || lower.hasSuffix(".npz") { return .mlx }
        return .other
    }

    /// Разобрать вид модели, которая лежит ПАПКОЙ.
    ///
    /// ⚠️ ВТОРОЙ ВХОД НУЖЕН ИМЕННО ПОТОМУ, ЧТО ПЕРВЫЙ СМОТРИТ НА ИМЯ. У модели Apple
    /// имя папки не говорит ни о чём: «gemma-4-e2b-it-4bit» — это может быть что угодно.
    /// Вид определяется ПО СОДЕРЖИМОМУ (устройство модели плюс веса внутри), и другого
    /// честного способа тут нет.
    public static func detect(folderAt url: URL) -> ModelFileFormat {
        MLXModelFolder.looksLikeModelFolder(url) ? .mlx : .other
    }

    /// Приложение умеет это запустить прямо сейчас.
    public var canRunToday: Bool { self == .litertlm || self == .mlx || self == .gguf }

    /// Короткое имя вида — так же, как он называется на самом Hugging Face.
    public var shortName: String {
        switch self {
        case .litertlm: return "LiteRT-LM"
        case .gguf:     return "GGUF"
        case .mlx:      return "MLX"
        case .other:    return "другой вид"
        }
    }

    /// Почему запустить пока нельзя. Пусто — можно.
    public var notYetNote: String {
        switch self {
        case .litertlm, .mlx, .gguf:
            return ""
        case .other:
            return "Это не похоже на файл модели, который приложение умеет открывать."
        }
    }
}

// MARK: - Ответ человеку

/// Пометка годности: то самое «пойдёт или нет», ради чего всё и считается.
public struct ModelFit: Sendable, Equatable {

    /// Четыре и только четыре состояния — по цветам, которые видит человек.
    public enum Level: String, Sendable, Equatable {
        /// Зелёная: должна пойти на этом телефоне.
        case ready
        /// Жёлтая: может не хватить памяти. Запретить нечего — только предупредить.
        case tight
        /// Серая: пока не запустим (чужой вид файла либо нечем измерить память).
        case notYet
        /// Красная: на iPhone не работает вообще.
        case impossible
    }

    public let level: Level
    /// Два-три слова на саму пометку: «Должна пойти».
    public let title: String
    /// Одна фраза «почему так».
    public let detail: String
    /// Отдельная строка про память с числами. nil — сказать нечего.
    public let memoryNote: String?

    public init(level: Level, title: String, detail: String, memoryNote: String?) {
        self.level = level
        self.title = title
        self.detail = detail
        self.memoryNote = memoryNote
    }
}

// MARK: - Сам расчёт

public enum ModelFitRule {

    // MARK: Сколько памяти просит движок

    /// GGUF: веса читаются ПРЯМО ИЗ ФАЙЛА по мере надобности, а не копируются в память
    /// целиком — поэтому расхожее «нужно столько же, сколько весит файл» тут завышает.
    ///
    /// ⚠️ ЭТО ОЦЕНКА, А НЕ ЗАМЕР, и подаётся человеку именно как оценка. Проверочная
    /// точка — живой факт владельца: Bonsai 27B «в один бит», файл 3,8 ГБ, на iPhone Air
    /// работает. По этому правилу ему нужно около 2,2 ГБ — то есть правило его пропускает
    /// с большим запасом. Взять долю больше единицы (как советуют в интернете) значило бы
    /// отвергнуть модель, которая на глазах у владельца работает.
    private static let ggufShare = 0.60

    /// MLX: движок Apple держит веса в общей памяти телефона, и доля выше, чем у GGUF.
    /// Тоже оценка: своих замеров у нас нет, а обещать по чужим — то же враньё.
    private static let mlxShare = 0.90

    /// Незнакомый вид файла: считаем по самому осторожному правилу — сколько весит,
    /// столько и просим.
    private static let unknownShare = 1.00

    /// Меньше этого не просим ни у кого: любой запуск тратит память на сам движок.
    private static let minimumNeedMB = 256

    /// Сколько свободной памяти нужно под этот файл (МБ).
    ///
    /// - Parameters:
    ///   - format: вид файла — у каждого движка своя физика памяти;
    ///   - fileBytes: точный размер файла;
    ///   - hardware: на чём файл вообще способен считать.
    public static func memoryNeedMB(format: ModelFileFormat,
                                    fileBytes: Int64,
                                    hardware: ModelHardware) -> Int {
        guard fileBytes > 0 else { return 0 }
        switch format {
        case .litertlm:
            // Тут гадать не надо: есть замеры Google на iPhone 17 Pro, и они уже
            // разложены по правилам в ModelMemoryRule. Сборке «только для видеочипа»
            // отступать некуда — спрашиваем ровно её порог.
            return hardware == .gpuOnly
                ? ModelMemoryRule.gpuRequirementMB(forFileBytes: fileBytes)
                : ModelMemoryRule.cpuRequirementMB(forFileBytes: fileBytes)
        case .gguf:
            return share(ggufShare, of: fileBytes)
        case .mlx:
            return share(mlxShare, of: fileBytes)
        case .other:
            return share(unknownShare, of: fileBytes)
        }
    }

    private static func share(_ value: Double, of bytes: Int64) -> Int {
        let megabytes = Int(Double(bytes) * value / (1024 * 1024))
        return max(minimumNeedMB, megabytes)
    }

    // MARK: Пометка годности

    /// Пойдёт эта модель на этом телефоне или нет.
    ///
    /// - Parameters:
    ///   - fileName: имя файла — по нему видно и вид файла, и то, под какое железо он собран;
    ///   - fileBytes: точный размер файла (с Hugging Face он известен до скачивания);
    ///   - availableMemoryMB: сколько приложение ещё может занять (`MemoryGate`).
    ///     `Int.max` означает «измерить не удалось» — тогда мы НИЧЕГО не обещаем.
    public static func fit(fileName: String,
                           fileBytes: Int64,
                           availableMemoryMB: Int) -> ModelFit {
        fit(name: fileName,
            format: ModelFileFormat.detect(fileName: fileName),
            hardware: ModelCatalog.hardware(forFileName: fileName),
            fileBytes: fileBytes,
            availableMemoryMB: availableMemoryMB)
    }

    /// То же самое для модели, которая лежит ПАПКОЙ (формат Apple).
    ///
    /// ⚠️ Отдельный вход нужен потому, что вид модели тут определяется не именем,
    /// а составом папки, а размер — это СУММА по всем её файлам. Расход памяти считается
    /// по своему правилу движка Apple (`mlxShare`), а не по меркам, снятым с файлов Google.
    public static func fit(folderName: String,
                           totalBytes: Int64,
                           availableMemoryMB: Int) -> ModelFit {
        fit(name: folderName,
            format: .mlx,
            hardware: ModelCatalog.hardware(forFileName: folderName),
            fileBytes: totalBytes,
            availableMemoryMB: availableMemoryMB)
    }

    /// Общий расчёт для файла и для папки: всё, что различается, уже решено вызывающим.
    private static func fit(name fileName: String,
                            format: ModelFileFormat,
                            hardware: ModelHardware,
                            fileBytes: Int64,
                            availableMemoryMB: Int) -> ModelFit {

        // 1. Красная. Сборка для браузера или под чужой ускоритель на iPhone не заработает
        //    никогда — ни при какой памяти. Об этом надо сказать первым делом.
        guard hardware.isUsableOnIPhone else {
            return ModelFit(level: .impossible,
                            title: "На iPhone не работает",
                            detail: hardware.note,
                            memoryNote: nil)
        }

        // 2. Память считаем ВСЕГДА, даже для видов файлов, которые ещё не запускаем
        //    (сейчас такой один — совсем незнакомый): человеку полезно знать заранее,
        //    влезет ли она вообще. Именно это правило держалось на живом примере Bonsai 27B
        //    ещё до того, как GGUF заработал.
        let needMB = memoryNeedMB(format: format, fileBytes: fileBytes, hardware: hardware)
        let isMemoryKnown = availableMemoryMB > 0 && availableMemoryMB != Int.max
        let isEnough = !isMemoryKnown || availableMemoryMB >= needMB
        let memoryNote: String? = isMemoryKnown
            ? memorySentence(needMB: needMB,
                             availableMB: availableMemoryMB,
                             isEnough: isEnough,
                             certainty: certainty(format: format, fileName: fileName))
            : nil

        // 3. Серая по виду файла. Скачивать то, что нечем открыть, мы не предлагаем.
        guard format.canRunToday else {
            return ModelFit(level: .notYet,
                            title: "Пока не запустим",
                            detail: format.notYetNote,
                            memoryNote: memoryNote)
        }

        // 4. Серая по незнанию. Памяти не измерили — обещать нечего, и зелёную галочку
        //    в этом месте ставить нельзя: она была бы догадкой, а не ответом.
        guard isMemoryKnown else {
            return ModelFit(level: .notYet,
                            title: "Не берусь обещать",
                            detail: "Не получилось узнать, сколько у телефона свободной памяти. "
                                + "Скачать и попробовать никто не мешает.",
                            memoryNote: nil)
        }

        // 5. Жёлтая. Именно предупреждение: решает человек, а не приложение.
        guard isEnough else {
            return ModelFit(level: .tight,
                            title: "Может не хватить памяти",
                            detail: hardware == .gpuOnly
                                ? "Эта модель считает только на видеочипе, а ему сейчас памяти мало. "
                                    + "Закройте другие приложения — или возьмите модель полегче."
                                : "Попробовать можно, но телефон может закрыть приложение "
                                    + "во время загрузки модели. Закройте другие приложения "
                                    + "или возьмите модель полегче.",
                            memoryNote: memoryNote)
        }

        // 6. Зелёная. Ставится только здесь: вид файла нам знаком, память измерена и её хватает.
        //
        // ⚠️ ОДНА ОГОВОРКА ОБЯЗАТЕЛЬНА. Обычному файлу мы меряем порог ПРОЦЕССОРА — то есть
        // «запустится вообще». На видеочипе тот же файл просит заметно больше, и если этого
        // больше нет, модель поедет медленно. Молчать об этом нельзя: ровно на такой тихой
        // подмене приложение уже обожглось с Gemma 4 E4B — она уходила на процессор,
        // а там не отвечала вовсе.
        var readyDetail = "Такой файл приложение открывает, и памяти телефона хватает."
        if format == .mlx {
            // ⚠️ Слово «около» здесь не вежливость, а честность: у движка Apple мы НЕ МЕРИЛИ
            // расход памяти ни разу — цифра выше посчитана по доле от размера, а не снята
            // с телефона. Обещать «хватит» тем же тоном, что и для замеренной Gemma, нельзя.
            readyDetail = "Это модель для движка Apple — папка из нескольких файлов. "
                + "Памяти телефона должно хватить, но расход мы считаем, а не мерили."
        } else if format == .gguf {
            // ⚠️ Та же честность, что и у MLX: расход посчитан по доле файла
            // (`ggufShare`), а не снят с телефона. И движок здесь другой — не тот,
            // что у файлов Google; не назвать его значило бы выдать один за другой.
            readyDetail = "Это модель для отдельного движка (GGUF). Памяти телефона "
                + "должно хватить, но расход мы считаем, а не мерили."
        } else if hardware == .gpuOnly {
            readyDetail = "Такой файл приложение открывает. Считает он только на видеочипе — "
                + "быстро, но запасного пути у него нет."
        } else if format == .litertlm {
            let acceleratedNeedMB = ModelMemoryRule.gpuRequirementMB(forFileBytes: fileBytes)
            if availableMemoryMB < acceleratedNeedMB {
                readyDetail += " Памяти хватит только на работу без ускорения — "
                    + "отвечать будет медленнее."
            }
        }

        return ModelFit(level: .ready,
                        title: "Должна пойти",
                        detail: readyDetail,
                        memoryNote: memoryNote)
    }

    // MARK: Насколько мы уверены в цифре памяти

    /// Откуда взялось число «нужно столько-то памяти».
    ///
    /// ⚠️ РАЗДЕЛЕНИЕ ПОЯВИЛОСЬ ВМЕСТЕ С ЖИВЫМ СПИСКОМ МОДЕЛЕЙ ИЗ ИНТЕРНЕТА, и вот зачем.
    /// Раньше в приложении было ровно одно семейство — Gemma, — и цифры расхода памяти
    /// взяты из ЗАМЕРОВ Google на живом iPhone. Теперь в том же формате находятся Qwen,
    /// Phi, DeepSeek, SmolLM и прочие, и им мы прикладываем ту же мерку, снятую с Gemma.
    /// Это разумно, но это уже РАСЧЁТ, а не замер, — и молчать про разницу нельзя:
    /// человек по этой строке решает, качать ему три гигабайта или нет.
    private enum MemoryCertainty {
        /// Цифра из замеров на живом телефоне (семейство Gemma).
        case measured
        /// Тот же вид файла, но другое семейство: мерку приложили от Gemma.
        case byGemmaRule
        /// Gemma, пересобранная чужими руками: слово «gemma» в имени есть, а замеры
        /// Google к этому файлу уже не относятся.
        case byReworkedGemma
        /// Расчёт по формуле без живых замеров (GGUF, MLX и прочее).
        case byFormula

        var tail: String {
            switch self {
            case .measured:         return ""
            case .byGemmaRule:      return " (расчёт: живьём мы мерили только Gemma)"
            case .byReworkedGemma:  return " (расчёт: файл пересобран чужими руками, "
                                         + "мерили мы только сборки Google)"
            case .byFormula:        return " (оценка — на живом телефоне не мерили)"
            }
        }
    }

    /// Приметы ЧУЖОЙ ПЕРЕДЕЛКИ в имени файла.
    ///
    /// ⚠️ ЗАЧЕМ ОТДЕЛЬНЫЙ СПИСОК, ЕСЛИ СЛОВО «GEMMA» В ИМЕНИ И ТАК ЕСТЬ. Потому что
    /// «supergemma4-e4b-abliterated.litertlm» — это НЕ файл Google: веса правили, файл
    /// пересобирали заново. Замеры Google к нему не относятся, а прежнее правило смотрело
    /// только на слово «gemma» и подписывало такому файлу «замерено». Выдать чужую
    /// пересборку за измеренную нами Gemma — ровно то враньё, от которого весь этот
    /// перечислитель и заведён.
    private static let reworkMarkers = [
        "abliterated", "uncensored", "unaligned", "unfiltered", "heretic", "nsfw"
    ]

    /// ⚠️ Семейство определяем по имени файла — другого признака до скачивания нет.
    /// Приблизительно? Да. Но ошибка тут стоит одной лишней оговорки в скобках,
    /// а обратная ошибка — обещания, снятого с чужих замеров.
    private static func certainty(format: ModelFileFormat, fileName: String) -> MemoryCertainty {
        guard format == .litertlm else { return .byFormula }
        let lower = fileName.lowercased()
        guard lower.contains("gemma") else { return .byGemmaRule }
        return reworkMarkers.contains(where: { lower.contains($0) }) ? .byReworkedGemma : .measured
    }

    /// Строка про память с двумя числами. Человеку нужны именно цифры: «может не хватить»
    /// без них — пустой звук.
    private static func memorySentence(needMB: Int,
                                       availableMB: Int,
                                       isEnough: Bool,
                                       certainty: MemoryCertainty) -> String {
        let need = memoryText(needMB)
        let free = memoryText(availableMB)
        let tail = certainty.tail
        return isEnough
            ? "Нужно около \(need), свободно \(free)\(tail)."
            : "Нужно около \(need), а свободно \(free)\(tail)."
    }

    /// Мегабайты человеческим языком. Считаем настоящие мегабайты (по 1024 КБ) — именно
    /// в них меряет память сама система, — а печатаем общим форматировщиком приложения.
    private static func memoryText(_ megabytes: Int) -> String {
        HumanFormat.bytes(Int64(megabytes) * 1024 * 1024)
    }
}
