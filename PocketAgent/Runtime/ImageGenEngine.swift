//
//  ImageGenEngine.swift
//  PocketAgent / Runtime
//
//  Генерация картинок моделью Qwen-Image-2.1 прямо на телефоне, без сети.
//  Движок — stable-diffusion.cpp (пакет Vendor/SDCpp, модуль SDEngine).
//
//  ⚠️ ЭТО НЕ ПЯТЫЙ ИНСТРУМЕНТ ПОМОЩНИКА. Модель чата о картинках не знает и звать
//  их не может: набор действий остаётся ровно тем же (CLAUDE.md). Это отдельный
//  экран, который человек открывает сам.
//
//  ⚠️ ПАМЯТЬ — ГЛАВНОЕ. Части модели весят 5,0 ГБ (энкодер) + 3,3–4,2 ГБ (рисующая)
//  + 0,7 ГБ (проявка) + 1,2 ГБ (зрение для правки). В память разом они не нужны:
//  энкодер отрабатывает один раз в начале, потом рисует DiT, потом проявляет VAE.
//  Так и настроено: параметры модели живут «на диске» (`params_backend = "disk"`) —
//  движок подгружает часть, когда она нужна, и отпускает её, когда она отработала
//
//  completion»). Файлы читаются отображением в память (mmap): такие страницы система
//  может выкинуть без записи, в отличие от обычной выделенной памяти.
//  Сколько это даёт на телефоне владельца — НЕ ИЗМЕРЯЛИ. Для этого экран и
//  показывает пик памяти после каждой картинки.
//

import Foundation
import os
#if canImport(SDEngine)
import SDEngine
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Что заказали нарисовать.
public struct ImageGenRequest: Sendable, Equatable {
    public var prompt: String
    public var width: Int
    public var height: Int
    public var steps: Int
    public var seed: Int64?          // nil — случайный
    public var preciseWeights: Bool  // точная рисующая часть вместо лёгкой
    /// Каким семейством рисовать (`ImageModelRegistry`)..
    public var familyID: String
    /// Образцы для режима правки: RGB, по 3 байта на точку, построчно.
    public var references: [ImageGenPixels]
    /// Какой формат рисующей части взять вместо обычного (id из `diffusionChoices`).
    /// nil или не скачан — обычный выбор (лёгкая / точная).
    public var diffusionOverrideID: String? = nil
    /// Рисовать турбо-версией (свои шаги, CFG 1, без кэша шагов). Решает экран через
    /// `ImageModelCatalog.turboToUse` — там же, где выбирает число шагов..
    public var useTurbo: Bool = false
    /// Рисовать турбо v0.2.1: обычная рисующая часть + дополнение Viggle, 6 шагов
    /// на своём расписании.
    public var useTurboLoRA: Bool = false

    public init(prompt: String, width: Int, height: Int, steps: Int, seed: Int64?,
                preciseWeights: Bool, references: [ImageGenPixels],
                familyID: String = ImageModelRegistry.qwenImage21.id) {
        self.familyID = familyID
        self.prompt = prompt
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
        self.preciseWeights = preciseWeights
        self.references = references
    }
}

/// Картинка как голые точки — так её понимает движок.
public struct ImageGenPixels: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var channels: Int   // 3 — RGB, 4 — RGBA (модель умеет прозрачность)
    public var bytes: Data
}

/// Итог с замером — числа нужны, чтобы первый запуск на телефоне дал факты.
public struct ImageGenResult: Sendable {
    public var image: ImageGenPixels
    public var seed: Int64
    public var totalSeconds: Double
    /// Сколько ушло до первого шага: загрузка частей и работа энкодера.
    public var prepareSeconds: Double
    /// Время каждого шага рисования по счёту движка (с кэшем шагов пропущенные — короткие).
    public var stepSeconds: [Double]
    /// Проявка (VAE) — от конца последнего шага до готовой картинки.
    public var decodeSeconds: Double
    /// Пик занятой приложением памяти за генерацию (phys_footprint), байты.
    public var peakFootprintBytes: UInt64
    /// Меньше всего оставалось памяти до отстрела системой (os_proc_available_memory), байты.
    public var minAvailableBytes: UInt64
    /// Каким файлом рисовали: «qwen_image_2.1-Q4_0» — чтобы сравнивать форматы.
    public var diffusionName: String
    /// Модель уже была открыта прошлой картинкой — контекст движка не создавали заново.
    public var contextReused: Bool = false
    /// Сколько заняло открытие модели (`new_sd_ctx`), если открывали. 0 — не открывали.
    public var contextOpenSeconds: Double = 0
    /// Описание уже разбирали с теми же размером и образцами — энкодер не запускался.
    public var promptFromCache: Bool = false
}

public enum ImageGenError: Error, Equatable {
    case engineMissing
    case modelMissing
    case outOfMemory(detail: String)
    case failed(detail: String)
    /// Видеочип оборвал работу (Metal). `reason` — человеческое «почему».
    case gpuFailed(reason: String, detail: String)
    case cancelled
    /// Движок уже занят другой картинкой (второй запуск отклонён).
    case busy

    /// По-русски и человеческими словами.
    public var humanText: String {
        switch self {
        case .engineMissing:
            return "В этой сборке нет движка картинок."
        case .modelMissing:
            return "Модель картинок скачана не полностью. Докачайте её."
        case .outOfMemory:
            return "Телефону не хватило памяти. Закройте другие приложения или выберите «Быстро» и лёгкие веса."
        case .failed:
            return "Не получилось нарисовать. Попробуйте ещё раз."
        case .gpuFailed(let reason, _):
            return "Видеочип не справился: \(reason)."
        case .cancelled:
            return "Остановлено."
        case .busy:
            return "Картинка уже рисуется — дождитесь её или остановите."
        }
    }

    public var detail: String? {
        switch self {
        case .outOfMemory(let d), .failed(let d), .gpuFailed(_, let d): return d.isEmpty ? nil : d
        default: return nil
        }
    }
}

/// Замер памяти процесса.
public enum ProcessMemory {
    /// Сколько памяти приложение занимает по счёту системы (то, за что убивают).
    public static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Сколько ещё можно занять до отстрела. 0 — система не сказала.
    public static func availableBytes() -> UInt64 {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return 0
        #endif
    }

    /// Потолок видеопамяти, который Metal советует не превышать (байты). 0 — нет Metal.
    public static func metalWorkingSetBytes() -> UInt64 {
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0
        #else
        return 0
        #endif
    }
}

/// Движок. Одна генерация за раз.
///
/// ⚠️ КОНТЕКСТ ДВИЖКА ЖИВЁТ МЕЖДУ КАРТИНКАМИ. Раньше он
/// создавался на каждую картинку и уничтожался сразу после — и вторая картинка
/// с тем же описанием заново гоняла энкодер (9 с на телефоне). Теперь контекст
/// держим, пока открыт экран «Картинки» (и `keepAfterCloseSeconds` после, если чат
/// не возвращается), и пересоздаём только при смене файлов: рисующая часть
/// (формат, турбо ↔ обычная), зрение для образцов, особые настройки семейства.
/// Закрываем при уходе в фон, перед возвратом чат-модели (`AppViewModel.prepareModel`),
/// перед удалением файлов модели и по таймеру после закрытия экрана. Предупреждение
/// системы о памяти модель НЕ закрывает.
///
/// Что это даёт — по исходнику движка 88411ef, а не по догадке:
/// • Повторный `generate_image` на том же контексте — штатный путь: так работает
///   sd-server движка (один контекст на все запросы). Отметку «остановить» движок
///   сбрасывает сам в начале каждого вызова, кэш шагов (easycache) заводится заново
///   на каждый вызов.
/// • В контексте живёт КЭШ УСЛОВИЙ (`ConditioningCache`, 4 записи): то же описание
///   с тем же размером и теми же образцами энкодер не считает вовсе — «conditioning
///   cache hit» в журнале. Повтор с другим зерном — без энкодера.
/// • ВЕСА РИСУЮЩЕЙ ЧАСТИ И ПРОЯВКИ МЕЖДУ КАРТИНКАМИ ОСТАЮТСЯ (движок v7, `SD_KEEP_WEIGHTS=1`).
///   Штатно в конце каждого `generate_image` движок выселял все веса (`end_runners` →
///   `runner_end`, `params_backend = disk`), и первый шаг каждой картинки платил +7 с
///   подгрузки. Теперь выселяется только энкодер (4,3 ГБ, нужен лишь в начале; с НОВЫМ
///   описанием он грузится заново). ⚠️ Значит, открытый контекст держит ~4,5 ГБ
///   (рисующая часть + проявка) — поэтому закрытие в фоне, перед чат-моделью
///   и по таймеру (выше) обязательно: `free_sd_ctx` выселяет всё. При нехватке места
///   посреди картинки движок выселяет оставленные веса сам (они не закреплены).
///   Сколько держит — пишется в журнал после каждой картинки.
public final class ImageGenEngine: @unchecked Sendable {

    public static let shared = ImageGenEngine()

    /// Запас памяти сверх бюджета движка (МБ): бюджет = доступно приложению − запас.
    /// Остаётся 1536, как в v8. Проверено на мини 24.09.2026 (тот же счёт памяти, что на
    /// телефоне — выселения совпали до мегабайта): проявке 512² одной плиткой на шаге
    /// увеличения до 512² нужно ~1,6 ГБ, и при запасе 1536 она выселяет ~1 ГБ рисующей части,
    /// при 1024 — 0,53 ГБ; чтобы не выселяла вовсе, бюджет нужен ~5,5 ГБ, а доступно ~5,9.
    /// Цена выселения при открытой модели — дочитать выселенное на первом шаге следующей
    /// картинки: на мини 1,27 с (запас 1536) против 0,62 с (1024). Ради 0,6 с поднимать пик
    /// памяти на 0,5 ГБ (минимум свободного на телефоне и так 0,86–1,05 ГБ) не стоит.
    /// Для опыта на телефоне — SD_RESIDENCY_MARGIN_MB (аргумент запуска или подмена замера).
    public static let defaultResidencyMarginMB = 1536

    static func residencyMarginMB() -> Int {
        if let raw = getenv("SD_RESIDENCY_MARGIN_MB"), let v = Int(String(cString: raw)), v >= 256 {
            return v
        }
        return defaultResidencyMarginMB
    }

    /// Сколько держать открытую модель после закрытия экрана, если чат-модель
    /// не возвращается (её не было). Вернулся на экран за это время — без открытия.
    /// Пока экран открыт, таймера нет вовсе — модель живёт сколько угодно. 180 с оставлено
    /// сознательно: ровно столько ggml держит наборы видеопамяти после последнего счёта
    /// (журнал: «residency set collection (keep_alive = 180 s)»). Дольше держать контекст
    /// можно, но после этого срока веса у видеочипа уже отпущены, и выигрыш от открытой
    /// модели меньше (не мерили, насколько). Короче — теряем «вышел и вернулся».
    public static let keepAfterCloseSeconds: TimeInterval = 180

    init() {
        #if canImport(UIKit)
        // Ушло в фон — открытую модель отпускаем (идёт картинка — сразу после неё).
        // Предупреждение о памяти модель НЕ закрывает — см. `handleMemoryWarning`.
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                               object: nil, queue: nil) { [weak self] _ in
            self?.handleMemoryWarning()
        }
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: nil) { [weak self] _ in
            self?.releaseContext(reason: "приложение ушло в фон")
        }
        #endif
    }

    /// Выключить матричные блоки видеочипа.
    /// ggml сам включает их на A19, хотя в его же исходнике сказано, что эти ядра пока
    /// не быстрее обычных. Видеочип ggml открывает один раз за жизнь приложения —
    /// поэтому переключатель действует после перезапуска.
    public static let tensorOffKey = "imageGenMetalTensorOff"

    /// Выключить «быстрый режим» матричных блоков (наша правка движка v4): активации
    /// идут в блоки как half, а не float, который блоки не считают. По умолчанию
    /// включён; выключатель — чтобы сравнить скорость и картинку на телефоне
    ///. Тоже действует после перезапуска.
    public static let tensorF16OffKey = "imageGenMetalTensorF16Off"

    /// Выключить проявку в half (наша правка движка v5): веса проявки хранятся в bf16,
    /// а матричные блоки A19 считают half × half, но не bf16. Движок переводит веса
    /// в half прямо в графе. На M1 скорость та же и картинка совпадает побитово;
    /// на телефоне не мерили — выключатель для сравнения.
    /// Действует сразу, со следующей картинки: переменную движок читает при сборке графа.
    public static let vaeF16OffKey = "imageGenVaeF16Off"

    /// Выключить ядро умножения по схеме MLX (наша правка движка v6c): каждая группа
    /// видеочипа считает свою плитку на матричных блоках A19 с операндами в регистрах.
    /// По умолчанию включено; выключатель — на случай, если «Проверить ядро» покажет
    /// ошибку или замедление. Действует сразу: движок читает переменную на каждом умножении.
    public static let naxOffKey = "imageGenMetalNaxOff"

    /// Отчёт последней «Проверки ядра» целиком. Забрать с телефона —
    /// как `last-run.log`, только имя `kernel-check.log`.
    public static var kernelCheckLogURL: URL? {
        lastRunLogURL?.deletingLastPathComponent().appendingPathComponent("kernel-check.log")
    }

    private let lock = NSLock()
    /// Открытый контекст движка — живёт между картинками (см. описание класса).
    private var ctx: OpaquePointer?
    /// Из каких файлов открыт `ctx`. Другие файлы — контекст пересоздаётся.
    private var ctxKey: ContextKey?
    /// Отпустить модель просили, пока шла картинка, — отпустим в `release()`.
    private var releaseAfterRun = false
    /// Почему закрыли прошлую модель — первой строкой журнала следующей картинки, если
    /// она откроет модель заново. Замер v8 на телефоне 24.09.2026: картинки «3 подряд» ни
    /// разу не взяли открытую модель (contextReused = false), и по журналу не видно почему —
    /// а без этого удержание весов между картинками не работает вовсе.
    private var releaseNote: String?
    private var pendingReleaseReason: String?
    /// Предупреждения о памяти, пришедшие между картинками, — в журнал следующей.
    private var idleWarningNotes: [String] = []
    /// Отложенное «отпустить модель» после закрытия экрана.
    private var pendingRelease: DispatchWorkItem?
    /// Встретилось ли в журнале движка «conditioning cache hit» за эту картинку.
    private var promptCacheHit = false
    private var cancelRequested = false
    private var logTail: [String] = []
    /// Первые строки уровня «ошибка» за запуск. Сбой видеочипа ggml печатает
    /// каскадом: сначала настоящая причина, потом «жертвы» и «движок в состоянии
    /// ошибки». В хвост из 12 строк причина не доживает — поэтому держим её отдельно
    /// и показываем в «Подробностях» ПЕРВОЙ.
    private var firstErrors: [String] = []
    /// Журнал запуска целиком (с уровня «сведения») — пишется в файл `lastRunLogURL`.
    private var fullLog: [String] = []
    /// Что с чат-моделью в момент старта картинки — первой строкой в журнал запуска.
    /// Ставит тот, кто зовёт `generate` (экран картинок, замер).:
    /// гипотеза владельца «в памяти две модели» проверяется только так — по журналу.
    private var chatNote: String?
    /// Подмены для удалённого замера (Bench/ImageBench.swift). Пусто — обычная работа.
    private var overrides = Overrides()

    /// Подмены замера: рисующая часть другим файлом и переменные движка поверх обычных.
    /// ⚠️ Переменные входят в ключ контекста: поменялись — модель открывается заново,
    /// иначе часть переменных (читаемых при открытии) молча не подействовала бы.
    public struct Overrides: Sendable, Equatable {
        /// Файл рисующей части вместо выбранного каталогом (любой .gguf на телефоне).
        public var diffusionURL: URL?
        /// Переменные движка. Пустое значение — снять переменную.
        public var env: [String: String] = [:]
        public init(diffusionURL: URL? = nil, env: [String: String] = [:]) {
            self.diffusionURL = diffusionURL
            self.env = env
        }
    }

    public func setOverrides(_ value: Overrides) {
        lock.lock(); overrides = value; lock.unlock()
    }

    /// Строка о чат-модели для журнала следующей картинки. Звать перед `generate`.
    public func setChatModelNote(_ note: String?) {
        lock.lock(); chatNote = note; lock.unlock()
    }

    /// Журнал последней генерации целиком. Забрать с телефона:
    /// `devicectl device copy from --domain-type appDataContainer
    ///  --domain-identifier pocket-agent --source "Library/Application Support/ImageGen/last-run.log"`.
    public static var lastRunLogURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ImageGen", isDirectory: true)
            .appendingPathComponent("last-run.log")
    }
    /// Занят ли движок. ⚠️ Флаг на весь процесс, а не на экран: экран можно закрыть
    /// и открыть заново, пока фоновая задача ещё держит веса. Две генерации разом —
    /// это два набора гигабайтов в памяти и почти гарантированный отстрел системой.
    private var busy = false

    /// Есть ли движок в этой сборке вообще (на симуляторе его нет).
    public static var isAvailable: Bool {
        #if canImport(SDEngine)
        return true
        #else
        return false
        #endif
    }

    /// Занять движок под одну генерацию. false — он уже занят, второй запуск отклонён.
    ///
    /// ⚠️ Отметка «остановить» сбрасывается ЗДЕСЬ, а не в `generate`: между занятием
    /// и самим рисованием ещё выгружается чат-модель (секунды), и человек может нажать
    /// «Остановить» уже на «Готовлю модель…». Сбрось `generate` отметку заново —
    /// это нажатие молча потерялось бы, и картинка нарисовалась бы вопреки ему.
    public func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        cancelRequested = false
        return true
    }

    /// Отпустить движок. Звать ПОСЛЕ выхода из `generate`. Энкодер к этому моменту
    /// движок уже выселил сам, рисующая часть и проявка остаются (`SD_KEEP_WEIGHTS`);
    /// контекст остаётся открытым для следующей картинки,
    /// если только его не просили закрыть, пока она рисовалась.
    public func release() {
        lock.lock(); defer { lock.unlock() }
        busy = false
        if releaseAfterRun {
            releaseAfterRun = false
            freeContextLocked(reason: pendingReleaseReason ?? "закрыта после картинки")
            pendingReleaseReason = nil
        }
    }

    /// Закрыть открытую модель (контекст движка). Безопасно звать с любого потока.
    /// Идёт картинка — закроется сразу после неё, саму картинку не трогаем.
    public func releaseContext(reason: String = "закрыта по запросу") {
        lock.lock(); defer { lock.unlock() }
        pendingRelease?.cancel()
        pendingRelease = nil
        if busy {
            releaseAfterRun = true
            pendingReleaseReason = reason + " (во время картинки)"
            return
        }
        freeContextLocked(reason: reason)
    }

    /// Предупреждение системы о памяти. Модель НЕ закрываем — только пишем в журнал.
    ///
    /// Почему (, правило владельца: никаких своих ограничений по памяти;
    /// настоящий предел — только отстрел системой). Замер v9 на телефоне 24.09.2026
    ///: предупреждение приходило во ВРЕМЯ КАЖДОЙ картинки,
    /// а мы по нему закрывали модель сразу после неё. Итог — ни одна картинка подряд
    /// не взяла открытую модель (contextReused = false), и каждая заново платила
    /// открытие и подготовку (5,4 с). При этом свободно оставалось ~1,9 ГБ, и система
    /// нас ни разу не убила — предупреждение было не про нас.
    ///
    /// Освобождать дёшево нечего: энкодер (4,3 ГБ) движок и так выселяет в конце каждой
    /// картинки сам, буферы счёта — тоже; отдельного вызова «сбросить лишнее» движок
    /// не даёт. Рисующую часть держим: это она экономит секунды на следующей картинке.
    /// При настоящей нехватке посреди картинки движок выселяет незакреплённые веса сам.
    /// Закрывают модель по-прежнему: уход в фон, возврат чат-модели, удаление файлов,
    /// таймер после закрытия экрана.
    func handleMemoryWarning() {
        let freeGB = Double(ProcessMemory.availableBytes()) / 1_073_741_824
        let usedGB = Double(ProcessMemory.footprintBytes()) / 1_073_741_824
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        lock.lock()
        let isBusy = busy
        let hasModel = ctx != nil
        lock.unlock()
        let what = hasModel ? "модель оставляю" : "модель не открыта"
        let line = String(format: "PocketAgent: предупреждение о памяти%@ — %@, свободно %.2f ГБ, занято %.2f ГБ (в %@)",
                          isBusy ? " во время картинки" : "", what, freeGB, usedGB, f.string(from: Date()))
        NSLog("%@", line)
        if isBusy {
            // Идёт картинка — строка попадёт в её журнал.
            appendLog(line, level: 2)
        } else {
            // Картинки нет — журнал прошлой уже записан; покажем первой строкой следующей.
            lock.lock(); idleWarningNotes.append(line)
            if idleWarningNotes.count > 8 { idleWarningNotes.removeFirst(idleWarningNotes.count - 8) }
            lock.unlock()
        }
    }

    /// Закрыть модель через `seconds`, если до этого её не понадобили снова.
    public func scheduleRelease(after seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.releaseContext(reason: "таймер после закрытия экрана") }
        lock.lock()
        pendingRelease?.cancel()
        pendingRelease = item
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Экран снова открыли — отложенное закрытие отменяем.
    public func cancelScheduledRelease() {
        lock.lock(); defer { lock.unlock() }
        pendingRelease?.cancel()
        pendingRelease = nil
    }

    /// ⚠️ Под замком. Уничтожать контекст здесь можно потому, что движок в этот
    /// момент ничего не рисует (`busy == false`), а значит обратные вызовы журнала
    /// сняты (`generate` снимает их на выходе) — движок не позовёт `appendLog`,
    /// который взял бы тот же замок.
    private func freeContextLocked(reason: String = "закрыта") {
        guard let held = ctx else { return }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        releaseNote = "\(reason), в \(f.string(from: Date()))"
        ctx = nil
        ctxKey = nil
        #if canImport(SDEngine)
        free_sd_ctx(held)
        #endif
    }

    public var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return busy
    }

    /// Просили ли остановить текущую генерацию.
    public var isCancelRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    /// Остановить идущую генерацию. Безопасно звать с любого потока.
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelRequested = true
        #if canImport(SDEngine)
        if let ctx { sd_cancel_generation(ctx, SD_CANCEL_ALL) }
        #endif
    }

    /// Нарисовать. Блокирует вызывающий поток на всё время генерации —
    /// звать из фоновой задачи, заняв движок через `reserve()`.
    /// `onStep(шаг, всего)` приходит с потока движка и только для шагов рисования.
    /// `onPreview` — черновик картинки после каждого шага (тоже с потока движка).
    public func generate(_ request: ImageGenRequest,
                         onPreview: (@Sendable (ImageGenPixels) -> Void)? = nil,
                         onStep: @escaping @Sendable (Int, Int) -> Void) throws -> ImageGenResult {
        #if canImport(SDEngine)
        guard let family = ImageModelRegistry.family(id: request.familyID) else {
            throw ImageGenError.modelMissing
        }
        lock.lock(); let over = overrides; lock.unlock()
        // Турбо: своя рисующая часть и свои настройки, энкодер и проявка — общие.
        let loraTurbo = request.useTurboLoRA ? family.turboLoRA : nil
        let turbo = request.useTurbo && loraTurbo == nil ? family.turbo : nil
        if request.useTurbo || request.useTurboLoRA, turbo == nil, loraTurbo == nil {
            throw ImageGenError.modelMissing
        }
        // Дополнение v0.2.1 ложится на обычную рисующую часть; первый раз — слияние (~3 с).
        let loraStarted = Date()
        let loraURL = try loraTurbo.map { try ImageModelCatalog.preparedLoRA($0) }
        let loraPrepSeconds = Date().timeIntervalSince(loraStarted)
        guard let dit = turbo?.diffusion
                ?? ImageModelCatalog.diffusionToUse(family, precise: request.preciseWeights && loraTurbo == nil,
                                                    overrideID: request.diffusionOverrideID)
                    // Замер подменил файл — обычной рисующей части на телефоне может и не быть.
                    ?? (over.diffusionURL != nil ? family.diffusionLight : nil),
              let ditURL = over.diffusionURL ?? ImageModelCatalog.url(of: dit),
              let encURL = ImageModelCatalog.url(of: family.textEncoder),
              let vaeURL = ImageModelCatalog.url(of: family.vae) else {
            throw ImageGenError.modelMissing
        }
        // Модель правку по образцам не умеет — образцы не передаём вовсе
        // (экран их и не показывает, это вторая линия защиты).
        let references = family.supportsReferences ? request.references : []
        // Зрение грузим ТОЛЬКО когда есть образцы и оно у семейства бывает
        // (у Qwen-Image; FLUX.2 klein читает образец без отдельного зрения).
        let visionURL: URL?
        if references.isEmpty || family.vision == nil {
            visionURL = nil
        } else {
            guard let vision = family.vision, let v = ImageModelCatalog.url(of: vision) else {
                throw ImageGenError.modelMissing
            }
            visionURL = v
        }

        // Отметку «остановить» здесь НЕ сбрасываем (см. `reserve`): остановили
        // ещё до начала — выходим сразу, не открывая гигабайты модели.
        lock.lock()
        logTail.removeAll()
        firstErrors.removeAll()
        fullLog.removeAll()
        promptCacheHit = false
        let stoppedBeforeStart = cancelRequested
        let chatAtStart = chatNote
        let warningsBetween = idleWarningNotes
        idleWarningNotes.removeAll()
        lock.unlock()
        if stoppedBeforeStart { throw ImageGenError.cancelled }
        for line in warningsBetween { appendLog(line + " — между картинками", level: 2) }
        appendLog("PocketAgent: чат-модель при старте картинки — \(chatAtStart ?? "не сообщили")"
                  + String(format: " · занято %.2f ГБ, свободно %.2f ГБ",
                           Double(ProcessMemory.footprintBytes()) / 1_073_741_824,
                           Double(ProcessMemory.availableBytes()) / 1_073_741_824), level: 2)
        if loraPrepSeconds > 0.5 {
            appendLog(String(format: "PocketAgent: дополнение турбо слито за %.1f с", loraPrepSeconds), level: 2)
        }

        // Замер памяти: опрос раз в четверть секунды на своём потоке.
        let meter = MemoryMeter()
        meter.start()
        let started = Date()
        var firstStepAt: Date?
        var lastStepAt: Date?
        // Время каждого шага рисования — его отдаёт сам движок (то же «s/it», что
        // печатает sd-cli). Нужно для «Подробностей» и журнала: на телефоне сравниваем
        // форматы весов и матричные блоки по шагу, а не по общему времени.
        var stepSeconds: [Double] = []

        // Журнал движка: держим хвост, чтобы сказать человеку, что случилось.
        // Берём с уровня «сведения»: часть строк ggml о видеочипе идёт именно им.
        let logBox = Unmanaged.passRetained(CallbackBox { [weak self] level, text in
            self?.appendLog(text, level: level)
        })
        defer { logBox.release() }
        // Журнал в файл — и при успехе, и при сбое (defer срабатывает на любом выходе).
        defer { saveRunLog() }
        // Какие ядра умножения реально брались за эту картинку (движок v6c): новое по схеме
        // MLX или старое, и почему. Счёт обнуляем на входе, в журнал — на выходе (этот
        // defer объявлен позже, значит срабатывает раньше записи журнала в файл).
        _ = sd_pa_kernel_stats(1)
        defer { appendLog(String(cString: sd_pa_kernel_stats(1)), level: 2) }
        sd_set_log_callback({ level, text, data in
            guard let data, let text, level.rawValue >= SD_LOG_INFO.rawValue else { return }
            Unmanaged<CallbackBox>.fromOpaque(data).takeUnretainedValue()
                .log(Int(level.rawValue), String(cString: text))
        }, logBox.toOpaque())

        let wantedSteps = request.steps
        let stepBox = Unmanaged.passRetained(StepBox { [weak self] step, steps, time in
            // Тот же колбэк движок зовёт и на загрузке частей, и на проявке плитками —
            // со своими счётчиками («312 из 1500»). Человеку показываем только шаги
            // рисования: их число мы сами заказали. После последнего шага счёт закрыт:
            // плиток проявки бывает ровно столько же, сколько шагов (9 и 9).
            guard Int(steps) == wantedSteps, stepSeconds.count < wantedSteps else { return }
            let now = Date()
            // ⚠️ Движок зовёт колбэк ДО первого шага с номером 0 и временем 0 (начало
            // рисования), а потом после КАЖДОГО шага — с его временем. Раньше «0» шёл
            // в счёт как первый шаг, и всё съезжало на шаг: первый шаг в «Подробностях»
            // был 0,0 с, а последний (~31 с на телефоне) попадал в «проявку»
            //. Ноль — только отметка начала.
            if step == 0 {
                guard firstStepAt == nil else { return }
                firstStepAt = now
                self?.logStepState(0, of: wantedSteps, seconds: nil)
                onStep(0, Int(steps))
                return
            }
            // ⚠️ Шаги идут строго по порядку: 1, 2, 3… Всё остальное — чужой счётчик.
            // Турбо, 24.09.2026: подгрузка первого куска рисующей части (4 тензора)
            // шла через тот же колбэк как «1 из 4», «3 из 4», и при 4 шагах это
            // совпадало с нашим числом — четыре «шага по 0,0 с» закрывали счёт ещё
            // до первого настоящего шага, строка в «Подробностях» была из нулей.
            // Подгрузку от колбэка отцепили в движке (pa-vendor.sh, v5); это — страховка.
            guard firstStepAt != nil, Int(step) == stepSeconds.count + 1 else { return }
            stepSeconds.append(Double(time))
            if stepSeconds.count == wantedSteps { lastStepAt = now }
            self?.logStepState(Int(step), of: wantedSteps, seconds: Double(time))
            onStep(Int(step), Int(steps))
        })
        defer { stepBox.release() }
        sd_set_progress_callback({ step, steps, time, data in
            guard let data else { return }
            Unmanaged<StepBox>.fromOpaque(data).takeUnretainedValue().call(step, steps, time)
        }, stepBox.toOpaque())

        // Живой предпросмотр: после каждого шага движок переводит
        // «скрытую» картинку в цвета простым умножением на готовую таблицу (режим
        // PREVIEW_PROJ). Это счёт на процессоре по крошечному массиву — ни весов,
        // ни видеочипа, ни памяти. Отдельная маленькая проявка (TAE) не нужна:
        // у Qwen-Image 2.1 своя проявка на 64 канала, а готовые маленькие (taew2_1)
        // сделаны под 16 — к ней они не подходят вовсе.
        // Черновик маленький (у Qwen 512×512 → 32×32 точки) — экран растягивает его
        // размыто, этого хватает, чтобы видеть, как проступает картинка.
        let previewBox = onPreview.map { cb in
            Unmanaged.passRetained(PreviewBox { frame in
                let bytes = Int(frame.width) * Int(frame.height) * Int(frame.channel)
                guard bytes > 0, let data = frame.data else { return }
                cb(ImageGenPixels(width: Int(frame.width), height: Int(frame.height),
                                  channels: Int(frame.channel), bytes: Data(bytes: data, count: bytes)))
            })
        }
        defer { previewBox?.release() }
        if let previewBox {
            // interval 1 — каждый шаг; denoised — «что выйдет», а не шум текущего шага.
            sd_set_preview_callback({ _, count, frames, _, data in
                guard let data, let frames, count > 0 else { return }
                Unmanaged<PreviewBox>.fromOpaque(data).takeUnretainedValue().call(frames.pointee)
            }, PREVIEW_PROJ, 1, true, false, previewBox.toOpaque())
        }

        defer {
            sd_set_preview_callback(nil, PREVIEW_NONE, 0, false, false, nil)
            sd_set_progress_callback(nil, nil)
            sd_set_log_callback(nil, nil)
        }

        // Строки для C живут до конца функции — освобождаем в defer.
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }

        // Переменные движка — перед КАЖДОЙ картинкой, а не только при открытии модели:
        // контекст теперь живёт между картинками, а читаются они при сборке графа.
        // Резать шаг рисования по слоям, даже когда всё влезает в память (наша правка
        // движка, tools/mac/pa-vendor.sh). Без этого один шаг Qwen-Image — это один
        // многосекундный командный буфер видеочипа, и iOS его обрывает: первый запуск
        // на телефоне 24.09.2026 упал так на первом же шаге.
        setenv("SD_FORCE_SEGMENTED_COMPUTE", "1", 1)
        // Время каждого куска — в журнал запуска (наша правка движка, v3). Нужно, чтобы
        // с телефона было видно, куда уходит шаг: 18 с на проход против 3–4 с потолка
        // чипа. Дешёво: одна строка на кусок.
        setenv("SD_SEGMENT_TIMING", "1", 1)
        if UserDefaults.standard.bool(forKey: Self.tensorOffKey) {
            setenv("GGML_METAL_TENSOR_DISABLE", "1", 1)
        } else {
            unsetenv("GGML_METAL_TENSOR_DISABLE")
        }
        if UserDefaults.standard.bool(forKey: Self.vaeF16OffKey) {
            unsetenv("SD_VAE_F16")
        } else {
            setenv("SD_VAE_F16", "1", 1)
        }
        setenv("GGML_METAL_TENSOR_F16",
               UserDefaults.standard.bool(forKey: Self.tensorF16OffKey) ? "0" : "1", 1)
        // Режим 4 (инженер А, v11): веса слоя разворачиваются в half, затем плотное ядро
        // на нейроблоках A19. Замер 25.09.2026 на телефоне: слой 93 мс против 129 у MLX 64,
        // картинка 512² 25,4 с против ~38 с. Буфер ~127 МБ. Чего режим не умеет — уходит в MLX 64.
        setenv("GGML_METAL_NAX", UserDefaults.standard.bool(forKey: Self.naxOffKey) ? "0" : "4", 1)
        // Проявка: резы по блокам — кусок работы
        // видеочипа короткий при любой плитке; быстрые пути одного кадра (развёртка
        // полосами, без лишних копий) — та же картинка побитово, в 3–4 раза быстрее на M1.
        setenv("SD_VAE_SEGMENTS", "1", 1)
        setenv("SD_VAE_FAST", "1", 1)
        // Веса рисующей части и проявки не выселяются в конце вызова (v6a): плитки проявки
        // и следующая картинка не читают их заново. При нехватке места движок выселяет их сам.
        setenv("SD_KEEP_WEIGHTS", "1", 1)
        // Движок v8: в журнал — кто сколько весов держит и кто кого выселил (строки PA RESIDENCY).
        setenv("SD_RESIDENCY_LOG", "1", 1)
        // Для замеров, по умолчанию выкл: раскладка слоя N по операциям (PA PROFILE) и энкодер
        // в памяти между картинками. Включаются аргументами запуска, например
        // `devicectl … process launch … -SD_PROFILE_BLOCK 1` (попадают в UserDefaults).
        for name in ["SD_PROFILE_BLOCK", "SD_PROFILE_STEP", "SD_KEEP_ENCODER", "SD_EVICT_PLAIN_LRU",
                     "SD_RESIDENCY_MARGIN_MB", "SD_PA_ROPE"] {
            if let v = UserDefaults.standard.string(forKey: name) { setenv(name, v, 1) } else { unsetenv(name) }
        }

        // Подмены замера — ПОСЛЕ обычных переменных, чтобы брать верх над ними.
        for (name, value) in over.env.sorted(by: { $0.key < $1.key }) {
            if value.isEmpty { unsetenv(name) } else { setenv(name, value, 1) }
            appendLog("PocketAgent: замер: \(name)=\(value.isEmpty ? "(снята)" : value)", level: 2)
        }
        if let url = over.diffusionURL {
            appendLog("PocketAgent: замер: рисующая часть — \(url.lastPathComponent)", level: 2)
        }

        // Та же модель уже открыта прошлой картинкой — берём её (см. описание класса).
        let key = ContextKey(diffusion: ditURL.path, encoder: encURL.path, vae: vaeURL.path,
                             vision: visionURL?.path, modelArgs: family.modelArgs, env: over.env)
        lock.lock()
        let reused: OpaquePointer? = ctxKey == key ? ctx : nil
        let stale: OpaquePointer? = reused == nil ? ctx : nil
        if reused == nil { ctx = nil; ctxKey = nil }
        let closedNote = reused == nil ? releaseNote : nil
        if reused == nil { releaseNote = nil }
        lock.unlock()
        if let closedNote {
            appendLog("PocketAgent: прошлая модель была закрыта: \(closedNote)", level: 2)
        }
        // Прежнюю модель (другой формат, турбо ↔ обычная, образцы) закрываем ДО открытия
        // новой — две разом в памяти не нужны. ⚠️ Вне замка: обратный вызов журнала уже
        // поставлен, движок напишет в него при закрытии, а `appendLog` берёт тот же замок.
        if let stale {
            appendLog("PocketAgent: другие файлы модели — закрываю прежнюю", level: 2)
            free_sd_ctx(stale)
        }

        var contextOpenSeconds: Double = 0
        let made: OpaquePointer
        if let reused {
            made = reused
            appendLog("PocketAgent: модель уже открыта — без повторного открытия", level: 2)
        } else {
            var cp = sd_ctx_params_t()
            sd_ctx_params_init(&cp)
            cp.diffusion_model_path = c(ditURL.path)
            cp.llm_path = c(encURL.path)
            cp.vae_path = c(vaeURL.path)
            if let visionURL { cp.llm_vision_path = c(visionURL.path) }
            cp.enable_mmap = true
            cp.flash_attn = true
            cp.diffusion_flash_attn = true
            // Части модели — «с диска»: подгрузить, когда нужна, отпустить, когда отработала.
            cp.params_backend = c("disk")
            // Дополнение турбо v0.2.1 — только «на лету» (W·x + B·A·x): вшивать его в квантованные
            // веса неточно (Viggle: при слиянии теряется до 30–60 % добавки), а контекст общий
            // с «Максимумом», который рисует те же веса без дополнения.
            cp.lora_apply_mode = LORA_APPLY_AT_RUNTIME
            // Особые настройки семейства (у Qwen-Image 2.1 — выключенный кэш префикса,
            // пояснение в реестре). У остальных их нет.
            if let args = family.modelArgs { cp.model_args = c(args) }
            // Бюджет памяти движку — от того, сколько система РЕАЛЬНО даст приложению сейчас
            // (чат-модель к этому моменту уже выгружена), минус запас на сам экран и систему.
            // Без явного бюджета движок меряет «свободную видеопамять» по-своему, и она
            // не совпадает с порогом, за которым iOS убивает приложение. С бюджетом он
            // выселяет отработавшую часть (энкодер), прежде чем грузить рисующую
            //.
            // ⚠️ Это НЕ отказ заранее: мало памяти — движок
            // просто режет работу на куски. Верен ли запас 1,5 ГБ — проверить замером на телефоне.
            // Запас — SD_RESIDENCY_MARGIN_MB (аргумент запуска или подмена замера), по умолчанию
            // `Self.defaultResidencyMarginMB` (почему столько — там же)..
            let available = ProcessMemory.availableBytes()
            if available > 0 {
                let marginMB = Self.residencyMarginMB()
                let gib = max(1.0, Double(available) / 1_073_741_824 - Double(marginMB) / 1024)
                cp.max_vram = c(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), gib))
                appendLog(String(format: "PocketAgent: бюджет движку %.2f ГБ = доступно %.2f ГБ − запас %d МБ",
                                 gib, Double(available) / 1_073_741_824, marginMB), level: 2)
            }

            let openStarted = Date()
            guard let opened = new_sd_ctx(&cp) else {
                meter.stop()
                throw classify(fallback: "движок не смог открыть модель")
            }
            contextOpenSeconds = Date().timeIntervalSince(openStarted)
            made = opened
            appendLog(String(format: "PocketAgent: модель открыта за %.1f с", contextOpenSeconds), level: 2)
        }
        lock.lock()
        ctx = made
        ctxKey = key
        let cancelledEarly = cancelRequested
        lock.unlock()
        // Сломанный запуск (сбой видеочипа, пустой результат) — контекст закрываем:
        // после ошибки видеочипа ggml может остаться «в состоянии ошибки», и следующая
        // картинка на нём вышла бы мусором. Остановка и успех — оставляем открытым.
        var discardContext = true
        defer {
            if discardContext {
                lock.lock()
                if ctx == made { ctx = nil; ctxKey = nil; releaseNote = "сбой прошлой картинки — контекст сброшен" }
                lock.unlock()
                free_sd_ctx(made)
            }
        }
        if cancelledEarly { discardContext = false; meter.stop(); throw ImageGenError.cancelled }

        // Образцы: движок читает их, пока идёт вызов, — держим байты живыми до конца.
        var refBuffers: [UnsafeMutablePointer<UInt8>] = []
        defer { refBuffers.forEach { $0.deallocate() } }
        var refs: [sd_image_t] = references.map { px in
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: px.bytes.count)
            px.bytes.copyBytes(to: buf, count: px.bytes.count)
            refBuffers.append(buf)
            return sd_image_t(width: UInt32(px.width), height: UInt32(px.height),
                              channel: UInt32(px.channels), data: buf)
        }

        let seed = request.seed ?? Int64.random(in: 1...Int64(Int32.max))
        var gp = sd_img_gen_params_t()
        sd_img_gen_params_init(&gp)
        // Турбо короткое описание понимает плохо — оборачиваем.
        let fewSteps = turbo != nil || loraTurbo != nil
        let prompt = !fewSteps ? request.prompt
            : ImageModelCatalog.turboPrompt(request.prompt, hasReferences: !references.isEmpty)
        if prompt != request.prompt {
            appendLog("PocketAgent: описание для турбо «\(prompt)»", level: 2)
        }
        gp.prompt = c(prompt)
        gp.negative_prompt = c("")
        gp.width = Int32(request.width)
        gp.height = Int32(request.height)
        gp.seed = seed
        gp.batch_count = 1
        gp.sample_params.sample_steps = Int32(request.steps)
        gp.sample_params.sample_method = EULER_SAMPLE_METHOD
        // Сила следования описанию — своя у семейства (реестр, из примеров движка),
        // у турбо — 1: тогда движок не считает второй, «пустой» проход на шаге.
        gp.sample_params.guidance.txt_cfg = loraTurbo?.cfg ?? turbo?.cfg ?? family.cfg
        // Расписание шума турбо — как у Viggle (сдвиг по размеру: 256…8192 точек, 0,5…0,9).
        // У sd.cpp свои константы (256…4096, max 1,15): на 768² сдвиг 0,85 вместо 0,60.
        // max_shift 0,6935 даёт тот же наклон прямой — совпадение точное при любом размере.
        // На мини 512² и 768² картинка та же или чуть резче.
        if turbo != nil { gp.sample_params.extra_sample_args = c("max_shift=0.6935") }
        // Турбо v0.2.1: своё расписание (узлы Viggle со сдвигом по размеру) и дополнение
        // «на лету» — множитель 1, как велит карточка (alpha = rank).
        var sigmas = loraTurbo?.sigmas(width: request.width, height: request.height) ?? []
        let sigmaBuf = UnsafeMutablePointer<Float>.allocate(capacity: max(1, sigmas.count))
        defer { sigmaBuf.deallocate() }
        var loraSpec = sd_lora_t()
        if let loraURL, !sigmas.isEmpty {
            sigmaBuf.initialize(from: &sigmas, count: sigmas.count)
            gp.sample_params.custom_sigmas = sigmaBuf
            gp.sample_params.custom_sigmas_count = Int32(sigmas.count)
            loraSpec.is_high_noise = false
            loraSpec.multiplier = 1
            loraSpec.path = c(loraURL.path)
            appendLog("PocketAgent: турбо v0.2.1, расписание "
                      + sigmas.map { String(format: "%.4f", $0) }.joined(separator: ","), level: 2)
        }
        // Пропуск похожих шагов (кэш шагов движка) — только где замер показал выигрыш
        // без потери качества. У турбо — нет:
        // из 4 шагов пропускать нечего, а пропущенный шаг дистиллированной модели —
        // это прямо потерянные детали.
        if !fewSteps, let cache = family.stepCache {
            switch cache.mode {
            case .easyCache: gp.cache.mode = SD_CACHE_EASYCACHE
            case .spectrum: gp.cache.mode = SD_CACHE_SPECTRUM
            }
            if let t = cache.threshold { gp.cache.reuse_threshold = t }
        }
        // Проявка (VAE) — плитками. Второй запуск на телефоне 24.09.2026: шаги прошли,
        // а проявка целиком упала на видеочипе («Discarded … InnocentVictim»), движок
        // этого не заметил и отдал мусор вместо картинки. Плитка 16×16
        // точек латента (128×128 на картинке) — короткие куски работы для видеочипа.
        // Перекрытие 0,25, а не 0,5 по умолчанию движка: при 0,5 каждая
        // точка проявляется примерно трижды. Замер на мини 24.09.2026 (Z-Image, 512²):
        // проявка 22,3 с → 11,5 с, отличие от проявки целиком то же (35,3 против 35,6 дБ),
        // швов не видно. Размер плитки прежний — кусок работы видеочипа не вырос.
        gp.vae_tiling_params.enabled = true
        if family.id == ImageModelRegistry.qwenImage21.id {
            // Qwen-Image 2.1 (проявка ×16) с резами по блокам (движок v6a): плитка до 32×32
            // точек латента — 512² целиком одной плиткой, без перекрытий (побитово как
            // проявка целиком); крупнее — наименьшим числом плиток с перекрытием 4 точки.
            // Замер на мини 24.09.2026: 512² — 26,5 → 6,7 с, 768² — 48,2 → 14,6 с.
            let t = Self.qwenVaeTiles(width: request.width, height: request.height)
            gp.vae_tiling_params.tile_size_x = Int32(t.x)
            gp.vae_tiling_params.tile_size_y = Int32(t.y)
            gp.vae_tiling_params.target_overlap = t.overlap
            appendLog("PocketAgent: проявка плиткой \(t.x)×\(t.y) точек латента", level: 2)
        } else {
            gp.vae_tiling_params.tile_size_x = 16
            gp.vae_tiling_params.tile_size_y = 16
            gp.vae_tiling_params.target_overlap = 0.25
        }

        var images: UnsafeMutablePointer<sd_image_t>?
        var count: Int32 = 0
        let ok: Bool = refs.withUnsafeMutableBufferPointer { buf in
            gp.ref_images = buf.baseAddress
            gp.ref_images_count = Int32(buf.count)
            return withUnsafePointer(to: &loraSpec) { lp in
                if loraURL != nil { gp.loras = lp; gp.lora_count = 1 }
                return generate_image(made, &gp, &images, &count)
            }
        }
        let finished = Date()
        let mem = meter.stop()

        lock.lock()
        let wasCancelled = cancelRequested
        let errs = firstErrors
        let fromCache = promptCacheHit
        lock.unlock()
        // ⚠️ Движок НЕ считает сбой видеочипа ошибкой: командный буфер отбрасывается,
        // а вызов возвращает «успех» с мусором в памяти (так было 24.09.2026 —
        // «картинка» из полос и повторов). Ошибка видеочипа в журнале = провал,
        // что бы ни сказал движок. Мусор человеку не показываем.
        if ok, Self.gpuReason(errs.joined(separator: "\n").lowercased()) != nil {
            if let images { free_sd_images(images, count) }
            if wasCancelled { throw ImageGenError.cancelled }
            throw classify(fallback: "сбой видеочипа")
        }
        guard ok, count > 0, let images, let data = images.pointee.data else {
            if let images { free_sd_images(images, count) }
            if wasCancelled { discardContext = false; throw ImageGenError.cancelled }
            throw classify(fallback: "движок вернул пустой результат")
        }
        let first = images.pointee
        let byteCount = Int(first.width) * Int(first.height) * Int(first.channel)
        let pixels = ImageGenPixels(width: Int(first.width), height: Int(first.height),
                                    channels: Int(first.channel),
                                    bytes: Data(bytes: data, count: byteCount))
        free_sd_images(images, count)
        discardContext = false
        // Сколько держит открытая модель без весов: движок их уже выселил
        // (`end_runners` в конце `generate_image`). Растёт от картинки к картинке —
        // значит течёт; так и проверяем на телефоне.
        let footAfter = ProcessMemory.footprintBytes()
        appendLog(String(format: "PocketAgent: после картинки занято %.2f ГБ, модель остаётся открытой",
                         Double(footAfter) / 1_073_741_824), level: 2)

        // Подготовка — до начала первого шага (загрузка частей + энкодер текста);
        // проявка — от конца последнего шага до готовой картинки.
        // `firstStepAt` — отметка «0» от движка, то есть именно начало первого шага.
        let prepare = max(0, (firstStepAt ?? finished).timeIntervalSince(started))
        let decode = lastStepAt.map { finished.timeIntervalSince($0) } ?? 0
        appendLog(String(format: "PocketAgent: подготовка %.1f с, шаги [%@] с, проявка %.1f с, всего %.1f с",
                         prepare, stepSeconds.map { String(format: "%.1f", $0) }.joined(separator: " "),
                         decode, finished.timeIntervalSince(started)), level: 2)
        return ImageGenResult(image: pixels, seed: seed,
                              totalSeconds: finished.timeIntervalSince(started),
                              prepareSeconds: prepare,
                              stepSeconds: stepSeconds,
                              decodeSeconds: decode,
                              peakFootprintBytes: mem.peakFootprint,
                              minAvailableBytes: mem.minAvailable,
                              diffusionName: (ditURL.lastPathComponent as NSString)
                                .deletingPathExtension + (loraTurbo != nil ? " + турбо v0.2.1" : ""),
                              contextReused: reused != nil,
                              contextOpenSeconds: contextOpenSeconds,
                              promptFromCache: fromCache)
        #else
        throw ImageGenError.engineMissing
        #endif
    }

    /// Строка журнала на каждый шаг: сколько памяти осталось до отстрела и насколько
    /// нагрет телефон. Нужна, чтобы различить две причины замедления на ходу
    /// (9,4 → 15,5 с на проход с третьего шага): нагрев или давление памяти
    ///. Шаг «0» — начало рисования:
    /// энкодер к этому моменту уже отпущен (на мини в журнале движка «released params
    /// backend buffers (4302 MB…)» сразу за концом энкодера), и запас это покажет.
    fileprivate func logStepState(_ step: Int, of total: Int, seconds: Double?) {
        let avail = ProcessMemory.availableBytes()
        let foot = ProcessMemory.footprintBytes()
        let heat: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: heat = "нормально"
        case .fair: heat = "тёплый"
        case .serious: heat = "горячий"
        case .critical: heat = "критично"
        @unknown default: heat = "?"
        }
        let gib = { (v: UInt64) in String(format: "%.2f", Double(v) / 1_073_741_824) }
        let time = seconds.map { String(format: "%.1f с", $0) } ?? "начало"
        appendLog("PocketAgent: шаг \(step)/\(total) \(time) · свободно \(avail > 0 ? gib(avail) + " ГБ" : "—")"
                  + " · занято \(gib(foot)) ГБ · нагрев \(heat)", level: 2)
    }

    /// «Проверить ядро»: прогоняет на видеочипе умножения размеров рисующей
    /// части старым ядром и новым (схема MLX, обе плитки), сверяет с эталоном на
    /// процессоре и меряет время. Модель не нужна; сотни мегабайт на полминуты.
    /// На мини (M1) матричных блоков нет — правильность и скорость нового ядра видны
    /// только здесь, на телефоне. Звать, заняв движок `reserve()`: блокирует поток
    /// на десятки секунд. Возвращает строку для экрана; отчёт целиком — `kernelCheckLogURL`.
    public func checkKernel() -> String {
        #if canImport(SDEngine)
        // Открытую между картинками модель закрываем ДО замера: замер открывает свой
        // контекст видеочипа, и два контекста с гигабайтами весов рядом не нужны.
        // Следующая картинка откроет модель заново — уже с текущими переключателями.
        lock.lock(); freeContextLocked(); lock.unlock()
        // Те же переключатели, что и перед рисованием: если видеочип в этом запуске
        // приложения ещё не открывали, замер откроет его именно так, как рисовали бы.
        if UserDefaults.standard.bool(forKey: Self.tensorOffKey) {
            setenv("GGML_METAL_TENSOR_DISABLE", "1", 1)
        } else {
            unsetenv("GGML_METAL_TENSOR_DISABLE")
        }
        setenv("GGML_METAL_TENSOR_F16",
               UserDefaults.standard.bool(forKey: Self.tensorF16OffKey) ? "0" : "1", 1)
        // Режим 4 (инженер А, v11): веса слоя разворачиваются в half, затем плотное ядро
        // на нейроблоках A19. Замер 25.09.2026 на телефоне: слой 93 мс против 129 у MLX 64,
        // картинка 512² 25,4 с против ~38 с. Буфер ~127 МБ. Чего режим не умеет — уходит в MLX 64.
        setenv("GGML_METAL_NAX", UserDefaults.standard.bool(forKey: Self.naxOffKey) ? "0" : "4", 1)

        let heat = { () -> String in
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "нормально"
            case .fair: return "тёплый"
            case .serious: return "горячий"
            case .critical: return "критично"
            @unknown default: return "?"
            }
        }
        let heatBefore = heat()
        let started = Date()
        guard let raw = sd_pa_kernel_bench() else { return "Проверка ядра не вернула отчёт" }
        let report = String(cString: raw)
        let seconds = Date().timeIntervalSince(started)
        let header = "Проверка ядра \(ISO8601DateFormatter().string(from: started))"
            + " · \(String(format: "%.0f", seconds)) с · нагрев до \(heatBefore), после \(heat())"
            + " · выключатели: блоки \(UserDefaults.standard.bool(forKey: Self.tensorOffKey) ? "выкл" : "вкл")"
            + ", half-активации \(UserDefaults.standard.bool(forKey: Self.tensorF16OffKey) ? "выкл" : "вкл")"
            + ", ядро нейроблоков \(UserDefaults.standard.bool(forKey: Self.naxOffKey) ? "выкл" : "режим 4")"
        if let url = Self.kernelCheckLogURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? (header + "\n" + report).data(using: .utf8)?.write(to: url, options: .atomic)
        }
        Logger(subsystem: "pocket-agent", category: "kernel-check").info("\(header, privacy: .public)\n\(report, privacy: .public)")
        let first = report.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? report
        return first
        #else
        return "Движка картинок в этой сборке нет"
        #endif
    }

    private func appendLog(_ raw: String, level: Int) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        fullLog.append(text)
        // Кэш условий движка сработал — энкодер не запускался (строка уровня «сведения»).
        if text.contains("conditioning cache hit") { promptCacheHit = true }
        if fullLog.count > 4000 { fullLog.removeFirst(fullLog.count - 4000) }
        #if canImport(SDEngine)
        if level >= Int(SD_LOG_ERROR.rawValue), firstErrors.count < 4 { firstErrors.append(text) }
        if level < Int(SD_LOG_WARN.rawValue) { return }
        #endif
        logTail.append(text)
        if logTail.count > 12 { logTail.removeFirst(logTail.count - 12) }
    }

    private func saveRunLog() {
        lock.lock(); let lines = fullLog; lock.unlock()
        guard let url = Self.lastRunLogURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Плитка проявки Qwen-Image 2.1 в точках латента (картинка ÷ 16) — для движка v6a.
    /// Сторона до `maxTile` — одна плитка на всю сторону (без перекрытий и швов); длиннее —
    /// наименьшее число плиток не больше `maxTile` с перекрытием `overlap` точек.
    /// Потолок 32 — это пик памяти проявки ~1 ГБ при резах и полосах (замер на мини
    /// 24.09.2026), против 0,5 ГБ у прежних плиток 16×16. Перекрытие 4 точки (64 точки
    /// картинки) — как было у 16×16 на 1024²; на 768² отличие от проявки целиком меньше,
    /// чем у прежних плиток (45,2 против 44,6 дБ).
    /// Доля перекрытия — с запасом 0,01 точки: движок округляет «плитка × доля» вниз,
    /// и ровно 4/26 даёт у него 3.
    static func qwenVaeTiles(width: Int, height: Int, maxTile: Int = 32,
                             overlap: Int = 4) -> (x: Int, y: Int, overlap: Float) {
        func side(_ latent: Int) -> Int {
            guard latent > maxTile else { return latent }
            let n = (latent - overlap + (maxTile - overlap) - 1) / (maxTile - overlap)
            return (latent + overlap * (n - 1) + n - 1) / n
        }
        let lx = max(1, width / 16), ly = max(1, height / 16)
        let tx = side(lx), ty = side(ly)
        let split = [(lx, tx), (ly, ty)].filter { $0.0 > $0.1 }.map { $0.1 }
        let share: Float = split.min().map { (Float(overlap) + 0.01) / Float($0) } ?? 0.25
        return (tx, ty, share)
    }

    /// Почему видеочип оборвал работу — по словам Metal в первой ошибке.
    /// nil — это не сбой видеочипа.
    static func gpuReason(_ lower: String) -> String? {
        let isGPU = ["command buffer", "kiogpu", "ggml_metal", "gpu error"].contains { lower.contains($0) }
        guard isGPU else { return nil }
        if lower.contains("timeout") || lower.contains("impactinginteractivity") {
            return "один кусок работы шёл слишком долго, и система его прервала"
        }
        if lower.contains("background") || lower.contains("insufficient permission") {
            return "приложение ушло в фон — пока рисуется картинка, держите его открытым"
        }
        if lower.contains("pagefault") || lower.contains("page fault") {
            return "он обратился к памяти, которую система уже забрала"
        }
        if lower.contains("innocentvictim") {
            return "его работу сбросили из-за сбоя в другой работе видеочипа"
        }
        return "сбой при расчёте"
    }

    /// Не хватило памяти или что-то другое — решаем по журналу движка.
    private func classify(fallback: String) -> ImageGenError {
        lock.lock(); let tail = logTail; let first = firstErrors; lock.unlock()
        // В «Подробностях» первая ошибка идёт ПЕРВОЙ, хвост журнала — после.
        var parts: [String] = []
        if !first.isEmpty { parts.append("Первая ошибка:\n" + first.joined(separator: "\n")) }
        let rest = tail.filter { !first.contains($0) }
        if !rest.isEmpty { parts.append("Хвост журнала:\n" + rest.joined(separator: "\n")) }
        if !parts.isEmpty { parts.append("Журнал целиком: Library/Application Support/ImageGen/last-run.log") }
        let joined = parts.joined(separator: "\n\n")
        // Причину решаем по ПЕРВОЙ ошибке: хвост полон её последствий.
        let lower = (first.isEmpty ? tail : first).joined(separator: "\n").lowercased()
        // ⚠️ Только прямые слова о нехватке. Прежние «alloc» и «budget» ловили любые
        // строки журнала вроде «allocating compute buffer» или «vram budget 7.5 GiB» —
        // и настоящая поломка выдавалась человеку за «не хватило памяти».
        let memoryWords = ["out of memory", "outofmemory", "failed to allocate",
                           "insufficient memory", "not enough memory"]
        if memoryWords.contains(where: { lower.contains($0) }) {
            return .outOfMemory(detail: joined)
        }
        if let reason = Self.gpuReason(lower) {
            return .gpuFailed(reason: reason, detail: joined)
        }
        // Слова о нехватке бывают и предупреждением (в хвосте, не среди ошибок).
        let tailLower = tail.joined(separator: "\n").lowercased()
        if memoryWords.contains(where: { tailLower.contains($0) }) {
            return .outOfMemory(detail: joined)
        }
        return .failed(detail: joined.isEmpty ? fallback : joined)
    }
}

/// Из каких файлов открыт контекст движка. Совпало — открывать заново не нужно.
/// Размер, шаги, зерно, сила описания сюда не входят: это параметры картинки,
/// а не контекста.
private struct ContextKey: Equatable {
    var diffusion: String
    var encoder: String
    var vae: String
    var vision: String?
    var modelArgs: String?
    /// Переменные замера (`Overrides.env`): другие — контекст открывается заново.
    var env: [String: String] = [:]
}

// MARK: - Мостики для обратных вызовов из C

private final class CallbackBox {
    let log: (Int, String) -> Void
    init(_ log: @escaping (Int, String) -> Void) { self.log = log }
}

#if canImport(SDEngine)
private final class PreviewBox {
    let call: (sd_image_t) -> Void
    init(_ call: @escaping (sd_image_t) -> Void) { self.call = call }
}
#endif

private final class StepBox {
    let call: (Int32, Int32, Float) -> Void
    init(_ call: @escaping (Int32, Int32, Float) -> Void) { self.call = call }
}

/// Опрос памяти на своём потоке, пока идёт генерация.
private final class MemoryMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var peak: UInt64 = 0
    private var minAvail: UInt64 = .max

    func start() {
        lock.lock(); running = true; lock.unlock()
        let t = Thread { [weak self] in
            while let self, self.sample() {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        t.qualityOfService = .utility
        t.start()
    }

    /// Снять одно значение; false — пора выходить.
    private func sample() -> Bool {
        let f = ProcessMemory.footprintBytes()
        let a = ProcessMemory.availableBytes()
        lock.lock(); defer { lock.unlock() }
        guard running else { return false }
        peak = max(peak, f)
        if a > 0 { minAvail = min(minAvail, a) }
        return true
    }

    @discardableResult
    func stop() -> (peakFootprint: UInt64, minAvailable: UInt64) {
        _ = sample()
        lock.lock(); defer { lock.unlock() }
        running = false
        return (peak, minAvail == .max ? 0 : minAvail)
    }
}
