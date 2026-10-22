//
//  MLXArchitectures.swift
//  PocketAgent / Runtime
//
//  ЗАПУСТИТ ЛИ ДВИЖОК APPLE ЭТУ МОДЕЛЬ — вопрос, который надо задавать ДО гигабайтов.
//
//  ⚠️ РАДИ ЧЕГО ФАЙЛ ЗАВЁЛСЯ. Владелец скачивал модель на 800 МБ
//  и в конце получил «Загрузка прервалась. Что-то пошло не так. [отладка: Unsupported
//  model type: qwen3_5_mtp]». Дословно: «пытался скачать модель — по итогу тупо
//  потратил своё время». При этом узнать всё можно было ДО ПЕРВОГО БАЙТА: устройство
//  модели написано в `config.json`, а он весит килобайты и качается первым.
//
//  ⚠️ ОТКУДА ЗДЕСЬ ПРАВДА, И ЭТО ГЛАВНОЕ. Список того, что движок Apple умеет,
//  живёт не у нас, а в самой библиотеке — `LLMTypeRegistry.shared` (mlx-swift-lm,
//  Libraries/MLXLLM/LLMModelFactory.swift). У неё есть вопрос `contains(_:)`, и авторы
//  прямо пишут, зачем он: решить ДО многогигабайтной загрузки, запустится ли модель
//  из репозитория. Поэтому отказываем мы ТОЛЬКО по ответу живой библиотеки, а не
//  по своему списку.
//
//  ⚠️ ЗАЧЕМ ТОГДА СПИСОК НИЖЕ. У библиотеки спрашивают с `await` (её справочник —
//  актор), а экрану со списком моделей ждать нечем: он рисуется здесь и сейчас.
//  Поэтому список — это СНИМОК справочника на 10.08.2026 (версия 3.31.4), снятый
//  чтением исходников на Маке владельца. Он годится, чтобы что-то показать сразу,
//  и никогда — чтобы запретить: запрет всегда сверяется с живой библиотекой.
//
//  ⚠️ ЧЕГО ЗДЕСЬ НЕТ. Никаких английских слов на экране. Название устройства модели
//  («qwen3_5_mtp») человеку не показывается нигде — оно уходит только в журнал движка.
//  Человек читает, ЧЕМ эта модель отличается от годной, а не как она называется внутри.
//

import Foundation
import MLXLLM
import MLXLMCommon

// MARK: - Ответ

/// Запустит ли движок Apple модель с таким устройством.
public enum MLXArchitectureVerdict: Sendable, Equatable {

    /// Запустит: библиотека знает такое устройство.
    case runnable(modelType: String)
    /// Не запустит никогда — сколько ни докачивай.
    case notRunnable(modelType: String)
    /// Не узнали. ⚠️ Это НЕ отказ: не смогли проверить — пускаем дальше и говорим честно.
    case unknown

    public var isNotRunnable: Bool {
        if case .notRunnable = self { return true }
        return false
    }

    /// Устройство модели — техническое слово. Только для журнала, не для экрана.
    public var modelType: String? {
        switch self {
        case .runnable(let type), .notRunnable(let type): return type
        case .unknown: return nil
        }
    }

    /// Что сказать человеку. nil — говорить нечего.
    public var humanText: String? {
        guard case .notRunnable(let type) = self else { return nil }
        return MLXArchitectures.humanText(forModelType: type)
    }
}

// MARK: - Отказ

/// Отказ, из-за которого продолжать бессмысленно: модель не запустится никогда.
/// Помечен `HumanReadableError` — иначе разбор ошибок подменит объяснение общим
/// «что-то пошло не так» (и, в отладочной сборке, английской строкой библиотеки).
public enum MLXArchitectureError: HumanReadableError, Equatable {

    /// Движок Apple не умеет запускать модели такого устройства.
    case engineCannotRun(modelName: String, modelType: String)

    public var errorDescription: String? {
        switch self {
        case .engineCannotRun(_, let type):
            return MLXArchitectures.humanText(forModelType: type)
        }
    }
}

// MARK: - Проверка устройства модели

public enum MLXArchitectures {

    /// Версия библиотеки, с которой снят список ниже. Меняете версию в project.yml —
    /// пересними список: он ТОЛЬКО для показа, но устаревший показ тоже врёт.
    public static let snapshotLibraryVersion = "3.31.4"
    /// Когда снимали.
    public static let snapshotDate = "10.08.2026"

    /// Снимок справочника `LLMTypeRegistry.shared` — всё, что движок Apple поднимает
    /// как текстовую модель. Снят чтением `Libraries/MLXLLM/LLMModelFactory.swift`
    /// версии 3.31.4.
    ///
    /// ⚠️ ЗАПРЕЩАТЬ ПО ЭТОМУ СПИСКУ НЕЛЬЗЯ. Он нужен там, где ответа надо дать сразу
    /// и ждать библиотеку нечем; всякий отказ проходит через `liveVerdict`.
    public static let snapshotRunnableTypes: Set<String> = [
        "mistral", "mixtral", "llama", "phi", "phi3", "phimoe",
        "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n",
        "gemma4", "gemma4_unified", "gemma4_text",
        "qwen2", "qwen3", "qwen3_moe", "qwen3_next",
        "qwen3_5", "qwen3_5_moe", "qwen3_5_text",
        "minicpm", "starcoder2", "cohere", "openelm", "internlm2",
        "deepseek_v3", "granite", "granitemoehybrid",
        "mimo", "mimo_v2_flash", "minimax",
        "glm4", "glm4_moe", "glm4_moe_lite",
        "acereason", "falcon_h1", "bitnet", "smollm3", "ernie4_5",
        "lfm2", "lfm2_moe", "baichuan_m1", "exaone4", "gpt_oss",
        "lille-130m", "olmoe", "olmo2", "olmo3", "bailing_moe",
        "nanochat", "nemotron_h", "afmoe", "jamba", "mamba2",
        "mistral3", "apertus", "nemotron_labs_diffusion"
    ]

    /// Устройства, которые библиотека умеет ТОЛЬКО как модели со зрением
    /// (`VLMTypeRegistry`). Приложение подключает лишь текстовую половину библиотеки
    /// (project.yml: продукты MLXLLM и MLXLMCommon), поэтому такие модели у нас
    /// не поднимутся — но сказать человеку про них надо не «неизвестное устройство»,
    /// а по делу: это модель для картинок.
    static let visionOnlyTypes: Set<String> = [
        "paligemma", "qwen2_vl", "qwen2_5_vl", "qwen3_vl", "idefics3",
        "smolvlm", "fastvlm", "llava_qwen2", "pixtral", "lfm2_vl", "lfm2-vl",
        "glm_ocr"
    ]

    // MARK: Ответ библиотеки

    /// Спросить ЖИВУЮ библиотеку. Единственный ответ, по которому можно отказывать.
    public static func liveVerdict(forModelType rawType: String) async -> MLXArchitectureVerdict {
        let type = normalized(rawType)
        guard !type.isEmpty else { return .unknown }

        if let remembered = cache.verdict(forType: type) { return remembered }

        let canRun = await LLMTypeRegistry.shared.contains(type)
        let verdict: MLXArchitectureVerdict = canRun ? .runnable(modelType: type)
                                                     : .notRunnable(modelType: type)
        cache.remember(verdict, forType: type)

        // Снимок разошёлся с библиотекой — это не поломка, но знать об этом надо:
        // значит список выше пора переснять.
        if canRun != snapshotRunnableTypes.contains(type) {
            EngineJournal.shared.record(
                .engine,
                "Список устройств моделей разошёлся с библиотекой — стоит переснять",
                detail: "устройство: \(type) · библиотека: \(canRun ? "умеет" : "не умеет") · "
                      + "наш снимок \(snapshotLibraryVersion) от \(snapshotDate): "
                      + "\(snapshotRunnableTypes.contains(type) ? "умеет" : "не умеет")"
            )
        }
        return verdict
    }

    /// Быстрый ответ без ожидания — для экранов, которые рисуются прямо сейчас.
    /// Сначала то, что уже спросили у библиотеки, потом снимок.
    ///
    /// ⚠️ По этому ответу НИЧЕГО не запрещаем: он показывает пометку, а не решает судьбу
    /// загрузки. И заодно тихо спрашивает библиотеку, чтобы в следующий раз ответ был
    /// не из снимка, а настоящий.
    public static func cachedVerdict(forModelType rawType: String) -> MLXArchitectureVerdict {
        let type = normalized(rawType)
        guard !type.isEmpty else { return .unknown }
        if let remembered = cache.verdict(forType: type) { return remembered }

        Task.detached(priority: .utility) { _ = await liveVerdict(forModelType: type) }

        return snapshotRunnableTypes.contains(type)
            ? .runnable(modelType: type)
            : .notRunnable(modelType: type)
    }

    // MARK: Устройство модели из описания

    /// Достать устройство модели из `config.json`.
    ///
    /// ⚠️ ЧИТАЕМ ТО ЖЕ ПОЛЕ, ЧТО И БИБЛИОТЕКА, И ТОЛЬКО ЕГО: верхнеуровневый
    /// `model_type` (`MLXLMCommon/BaseConfiguration.swift`). Заглядывать в `text_config`
    /// нельзя: библиотека туда не смотрит, и модель, у которой внутри знакомое слово,
    /// всё равно не поднимется — мы бы пообещали несбыточное.
    public static func modelType(inConfigData data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["model_type"] as? String else { return nil }
        let type = normalized(value)
        return type.isEmpty ? nil : type
    }

    /// Устройство модели из папки на телефоне. nil — прочитать не удалось.
    ///
    /// ⚠️ Файл маленький (килобайты), но лежит он в чужой папке: если вместо описания
    /// туда положили что-то огромное, читать это целиком в память нельзя.
    public static func modelType(inFolder url: URL) -> String? {
        let configURL = url.appendingPathComponent(MLXModelFolder.configFileName)
        guard let size = (try? configURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0, size <= maxConfigBytes,
              let data = try? Data(contentsOf: configURL) else { return nil }
        return modelType(inConfigData: data)
    }

    /// Приговор папке, которая уже лежит на телефоне.
    public static func verdict(forFolderAt url: URL) async -> MLXArchitectureVerdict {
        guard let type = modelType(inFolder: url) else { return .unknown }
        return await liveVerdict(forModelType: type)
    }

    // MARK: Устройство модели ДО загрузки

    /// Спросить справочник моделей про устройство ещё не скачанной модели.
    ///
    /// ⚠️ ЭТО И ЕСТЬ ЭКОНОМИЯ ВРЕМЕНИ ЧЕЛОВЕКА: тянем один файл `config.json` —
    /// килобайты вместо гигабайтов, — и уже по нему знаем, есть ли смысл качать.
    ///
    /// ⚠️ Не получилось (нет связи, зеркало молчит, репозиторий закрыт) — возвращаем
    /// «не проверяли». Отказать человеку из-за собственной неудачи мы права не имеем.
    public static func verdict(forRepo repoID: String, revision: String?) async -> MLXArchitectureVerdict {
        let repo = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return .unknown }

        if let remembered = cache.verdict(forRepo: repo) { return remembered }

        var verdict = MLXArchitectureVerdict.unknown
        for url in configURLs(repoID: repo, revision: revision) {
            guard let data = await fetch(url) else { continue }
            guard let type = modelType(inConfigData: data) else { continue }
            verdict = await liveVerdict(forModelType: type)
            break
        }

        // Запоминаем только настоящий ответ: «не проверяли» из-за оборванной связи
        // не должно годами висеть вместо проверки.
        if verdict != .unknown { cache.remember(verdict, forRepo: repo) }
        return verdict
    }

    // MARK: Слова для человека

    /// Первая фраза отказа — одна и та же везде, чтобы человек узнавал её с одного взгляда.
    public static let notRunnableHeadline = "Эта модель устроена иначе — приложение её не запустит."

    /// Полное объяснение: что не так и чем эта модель отличается от годной.
    ///
    /// ⚠️ БЕЗ ТЕХНИЧЕСКОГО НАЗВАНИЯ УСТРОЙСТВА. Владелец увидел на экране
    /// «Unsupported model type: qwen3_5_mtp» — набор чужих слов, из которого нельзя
    /// понять ни что случилось, ни что делать дальше.
    public static func humanText(forModelType rawType: String) -> String {
        notRunnableHeadline + " " + difference(forModelType: rawType)
    }

    /// Одна фраза для СВЁРНУТОЙ строки списка: чем эта модель плоха, и всё.
    ///
    /// ⚠️ ОБЩЕЙ ШАПКИ ЗДЕСЬ НЕТ НАМЕРЕННО. Полный приговор начинается со слов
    /// «Эта модель устроена иначе — приложение её не запустит», а в самой строке
    /// списка уже стоит красный крест и подпись «Не запустится». Повторять это
    /// третий раз — тот самый визуальный мусор: свёрнутая строка разрасталась
    /// до пяти строк текста, и список из пяти находок превращался в простыню
    /// из красных абзацев. Совет «возьмите такую-то модель» человек читает,
    /// когда раскроет строку, — там ему это и нужно.
    public static func shortText(forModelType rawType: String) -> String {
        firstSentence(of: difference(forModelType: rawType))
    }

    /// Первое предложение вместе с точкой.
    ///
    /// ⚠️ Слишком короткий кусок предложением не считаем: точка бывает и внутри
    /// фразы (сокращение, номер версии), и обрубок из трёх знаков сказал бы человеку
    /// ровно ничего. Тогда честнее отдать текст целиком.
    private static func firstSentence(of text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        let sentence = String(text[text.startIndex...dot])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count < 12 ? text : sentence
    }

    /// Чем эта модель отличается от той, которая пойдёт.
    public static func difference(forModelType rawType: String) -> String {
        let type = normalized(rawType)

        // Модель-ускоритель (multi-token prediction, «drafter»): её выкладывают
        // В ПАРЕ с основной, чтобы та отвечала быстрее. Сама по себе она не отвечает —
        // именно такую и качал владелец.
        if type.hasSuffix("_mtp") || type.contains("mtp_") || type.contains("draft")
            || type.contains("assistant") || type.contains("speculat") {
            return "Это не самостоятельная модель, а ускоритель к другой — отвечать сама она не умеет. "
                + "Возьмите обычную модель того же семейства, без слов MTP и Drafter в названии."
        }

        if visionOnlyTypes.contains(type) {
            return "Это модель для картинок, а приложение запускает текстовые. "
                + "Возьмите обычную текстовую сборку — обычно она лежит в соседнем репозитории."
        }

        return "Приложение поднимает модели других семейств: Gemma, Qwen, Llama, Mistral, "
            + "Phi, GLM и близкие к ним."
    }

    // MARK: - Мелочи

    /// Больше этого описание модели не бывает; всё крупнее — не описание, а чужой файл.
    private static let maxConfigBytes = 4 * 1024 * 1024

    /// Имя устройства пишут по-разному: с пробелами, заглавными, иногда через дефис.
    /// Библиотека сравнивает строку буква в букву, поэтому приводим к одному виду.
    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Где искать описание модели. Порядок тот же, что у загрузчика: сначала
    /// официальный адрес, потом зеркало (ModelSources.swift).
    ///
    /// ⚠️ У зеркала своё слово версии («master»): по номеру Hugging Face оно честно
    /// отвечает «нет такой версии» — ровно та же оговорка, что у загрузчика.
    private static func configURLs(repoID: String, revision: String?) -> [URL] {
        let file = MLXModelFolder.configFileName
        let commit = (revision?.isEmpty == false) ? revision! : "main"
        return [
            URL(string: "https://huggingface.co/\(repoID)/resolve/\(commit)/\(file)"),
            URL(string: "https://www.modelscope.cn/models/\(repoID)/resolve/master/\(file)")
        ].compactMap { $0 }
    }

    /// Скачать описание модели. nil — не отдали.
    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // ⚠️ Ждём мало: это проверка перед загрузкой, а не сама загрузка. Молчит
        // сервер — человек не должен смотреть на застывший экран; лучше честное
        // «не проверяли» через несколько секунд.
        request.timeoutInterval = 10

        guard let answer = try? await session.data(for: request),
              let http = answer.1 as? HTTPURLResponse,
              http.statusCode == 200,
              answer.0.count <= maxConfigBytes else { return nil }
        return answer.0
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    private static let cache = VerdictCache()
}

// MARK: - Память ответов

/// Ответы, которые уже получены. Спрашивать библиотеку и сервер по второму разу
/// на каждый кадр экрана нельзя.
///
/// ⚠️ Замок, а не актор: сюда ходят и экраны с главного потока (им ждать нечем),
/// и движок из своего актора.
private final class VerdictCache: @unchecked Sendable {

    private let lock = NSLock()
    private var byType: [String: MLXArchitectureVerdict] = [:]
    private var byRepo: [String: MLXArchitectureVerdict] = [:]

    func verdict(forType type: String) -> MLXArchitectureVerdict? {
        lock.lock(); defer { lock.unlock() }
        return byType[type]
    }

    func remember(_ verdict: MLXArchitectureVerdict, forType type: String) {
        lock.lock(); defer { lock.unlock() }
        byType[type] = verdict
    }

    func verdict(forRepo repo: String) -> MLXArchitectureVerdict? {
        lock.lock(); defer { lock.unlock() }
        return byRepo[repo]
    }

    func remember(_ verdict: MLXArchitectureVerdict, forRepo repo: String) {
        lock.lock(); defer { lock.unlock() }
        byRepo[repo] = verdict
    }
}

// MARK: - Тупики: где продолжать бессмысленно

/// Модели, которые на этом телефоне не заработают никогда, и почему.
///
/// ⚠️ ЗАЧЕМ ЭТО ОТДЕЛЬНО ОТ ОШИБКИ. Экран подготовки на любую неудачу показывает
/// «Загрузка прервалась… Повторите» и кнопку «Продолжить» — и это правильно для
/// оборванной связи. Но у модели, которую движок не умеет запускать, «Продолжить» —
/// обман: сколько ни продолжай, кончится тем же. Экран обязан уметь отличить одно
/// от другого, а для этого ему нужно не сообщение об ошибке, а факт.
///
/// ⚠️ Помним ПО МОДЕЛИ, а не «последнюю ошибку»: приговор относится именно к ней
/// и остаётся верным после перезапуска приложения — поэтому и записан на диск.
public final class ModelDeadEnds: @unchecked Sendable {

    public static let shared = ModelDeadEnds()

    private let lock = NSLock()
    private let storageKey = "pocketagent.model.deadends"
    private var reasons: [String: String]

    private init() {
        reasons = (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
    }

    /// Эта модель не заработает. Причина — человеческими словами, её покажет экран.
    public func mark(modelID: String, reason: String) {
        guard !modelID.isEmpty else { return }
        lock.lock()
        reasons[modelID] = reason
        let snapshot = reasons
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: storageKey)
    }

    /// Почему продолжать бессмысленно. nil — тупика нет, продолжать можно.
    public func reason(forModelID modelID: String) -> String? {
        guard !modelID.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return reasons[modelID]
    }

    /// Забыть приговор (человек стёр скачанное — незачем помнить о нём вечно).
    public func forget(modelID: String) {
        guard !modelID.isEmpty else { return }
        lock.lock()
        reasons[modelID] = nil
        let snapshot = reasons
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: storageKey)
    }
}
