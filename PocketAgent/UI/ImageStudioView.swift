//
//  ImageStudioView.swift
//  PocketAgent / UI
//
//  Экран «Картинки»: модель картинок (Qwen-Image 2.1, Z-Image-Turbo, FLUX.2 klein, FLUX.3 klein —
//  реестр `ImageModelRegistry`) рисует и правит фото прямо на телефоне.
//  Вход — строка «Картинки» на вкладке «Модели» и находка в поиске. ROADMAP §21, §23.
//
//  ⚠️ ЭКРАН ГОВОРИТ ТОЛЬКО ТО, ЧТО НУЖНО СЕЙЧАС (CLAUDE.md, приёмщик интерфейса).
//  Пока модели нет — одна карточка «скачать». Когда есть — поле, образцы, два выбора
//  и кнопка. Под готовой картинкой на виду только время, остальной замер — за
//  «Подробности»: он нужен, чтобы первый запуск на телефоне дал факты про память.
//

import SwiftUI
import PhotosUI
import Photos
import UIKit

// MARK: - Выборы

enum ImageQuality: String, CaseIterable, Identifiable {
    case fast, normal, max
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: return "Быстро"
        case .normal: return "Нормально"
        case .max: return "Максимум"
        }
    }
    /// ⚠️ Шаги и размер больше не здесь: у каждой модели свои (реестр
    /// `ImageModelRegistry`, ROADMAP §23). Турбо-модели на 28 шагах просто зря
    /// греют телефон, а Qwen-Image на 8 рисует кашу.
    var level: ImagePresetLevel {
        switch self {
        case .fast: return .fast
        case .normal: return .normal
        case .max: return .max
        }
    }
}

enum ImageAspect: String, CaseIterable, Identifiable {
    case square = "1:1", portrait = "3:4", landscape = "4:3", tall = "9:16", wide = "16:9"
    var id: String { rawValue }
    private var ratio: Double {
        switch self {
        case .square: return 1
        case .portrait: return 3.0 / 4.0
        case .landscape: return 4.0 / 3.0
        case .tall: return 9.0 / 16.0
        case .wide: return 16.0 / 9.0
        }
    }
    /// Ширина и высота при заданной площади. Кратно 32 — требование движка для 2.1.
    func size(baseSide: Int) -> (Int, Int) {
        let area = Double(baseSide * baseSide)
        let w = (area * ratio).squareRoot()
        let h = area / w
        func r32(_ v: Double) -> Int { max(256, Int((v / 32).rounded()) * 32) }
        return (r32(w), r32(h))
    }
}

// MARK: - Состояние экрана

/// Фото-образец вместе с тем выбором в «Фото», из которого он взялся.
/// ⚠️ Парой, а не двумя параллельными списками: если одно фото не открылось,
/// списки расходились по номерам, и крестик на втором образце убирал третий выбор.
struct ImageReference: Identifiable {
    let id = UUID()
    let item: PhotosPickerItem
    let image: UIImage
}

@MainActor
final class ImageStudioModel: ObservableObject {

    /// ⚠️ ОДИН НА ПРИЛОЖЕНИЕ, А НЕ НА ОТКРЫТИЕ ЭКРАНА. Загрузка на гигабайты и
    /// остановка генерации переживают закрытие экрана. Живи состояние в экране —
    /// при новом открытии он не знал бы, что наша же загрузка идёт («качается другая
    /// модель»), и дал бы нажать «Удалить» посреди неё или запустить вторую картинку.
    static let shared = ImageStudioModel()

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case generating(step: Int, of: Int)
    }

    /// Почему остановили — чтобы сказать человеку, если остановил не он.
    private enum StopReason { case user, background }

    @Published var prompt = ""
    @Published var quality: ImageQuality = .normal
    @Published var aspect: ImageAspect = .square
    @Published var seedText = ""
    @Published private(set) var references: [ImageReference] = []
    @Published var pickerItems: [PhotosPickerItem] = []

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isStopping = false
    @Published private(set) var result: UIImage?
    /// Черновик, который проступает по шагам (ROADMAP §24). Есть только пока рисуем.
    @Published private(set) var preview: UIImage?
    /// Растёт на каждой новой картинке — экран по нему прокручивается к ней.
    @Published private(set) var resultVersion = 0
    @Published private(set) var resultTime: String?
    @Published private(set) var resultNote: String?
    @Published private(set) var lastSeed: Int64?
    @Published private(set) var errorText: String?
    @Published private(set) var errorDetail: String?
    @Published private(set) var savedNote: String?
    @Published private(set) var photosDenied = false
    @Published private(set) var modelReady = false
    /// Какой моделью рисуем. Запоминается между запусками.
    @Published private(set) var family: ImageModelFamily = ImageStudioModel.savedFamily()
    @Published private(set) var preciseReady = false
    /// Турбо-версия на телефоне (у семейства, где она бывает). ROADMAP §24.
    @Published private(set) var turboReady = false
    /// Турбо v0.2.1 (дополнение поверх обычной) на телефоне. ROADMAP §24.4.
    @Published private(set) var turboLoRAReady = false
    /// «2,4 МБ/с · осталось 12 мин · с зеркала ModelScope» — пока идёт загрузка.
    /// Пусто — считать ещё не по чему. ROADMAP §23: «непонятно даже какая скорость
    /// и ваще не ясно с какого хоста качаю».
    @Published private(set) var downloadLine = ""

    static let maxReferences = 4
    private let inFlightKey = "imageGenInFlight"
    private var downloadWork: Task<Void, Never>?
    private var genWork: Task<Void, Never>?
    private var stopReason: StopReason?
    /// Открыт ли экран сейчас: закрытый и тут же открытый снова экран не должен
    /// назначить закрытие модели, пока на нём рисуют (см. `screenClosed`).
    private var screenIsOpen = false

    private init() {
        refreshModelState()
        // Прошлая генерация не дошла до конца и не сообщила об ошибке — значит
        // приложение закрыла система. Почти всегда это нехватка памяти: говорим прямо.
        if UserDefaults.standard.bool(forKey: inFlightKey) {
            UserDefaults.standard.set(false, forKey: inFlightKey)
            errorText = "Прошлая картинка оборвалась — похоже, телефону не хватило памяти. "
                + "Попробуйте «Быстро»."
        }
    }

    var isBusy: Bool { phase != .idle }
    var isDownloading: Bool { if case .downloading = phase { return true } else { return false } }

    var canGenerate: Bool {
        modelReady && !isBusy && !isCheckingKernel
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var downloadSizeText: String {
        HumanFormat.bytes(ImageModelCatalog.missingBytes(family, precise: false))
    }

    /// «Максимум» выбран, а дополнения для чётких картинок на телефоне нет.
    var needsPreciseForMax: Bool {
        quality == .max && family.diffusionPrecise != nil && !preciseReady
    }

    /// Выбран уровень, который рисует турбо, а её на телефоне нет — предложить скачать.
    /// Только когда модель уже стоит: новой установке турбо и так входит в «Скачать».
    var offersTurbo: Bool {
        // Есть турбо v0.2.1 — предлагаем её (лучше и легче), а не v0.1.
        guard modelReady, !turboReady, family.turboLoRA == nil, let t = family.turbo else { return false }
        return t.levels.contains(quality.level)
    }

    /// Турбо v0.2.1 не скачана, а уровень её — предложить. Сколько: дополнение 0,68 ГБ
    /// и обычная лёгкая, если стоит только турбо v0.1 (дополнение ложится на обычную).
    var turboLoRAOfferBytes: Int64? {
        guard modelReady, !turboLoRAReady, let t = family.turboLoRA,
              t.levels.contains(quality.level) else { return nil }
        let bytes = ImageModelCatalog.turboLoRAParts(family).reduce(Int64(0)) { $0 + $1.byteSize }
        return bytes > 0 ? bytes : nil
    }

    func downloadTurboLoRA() {
        download(precise: false, extras: ImageModelCatalog.turboLoRAParts(family))
    }

    func downloadTurbo() {
        guard let t = family.turbo else { return }
        download(precise: false, extra: t.diffusion)
    }

    func refreshModelState() {
        modelReady = ImageModelCatalog.isInstalled(family)
        preciseReady = family.diffusionPrecise.map(ImageModelCatalog.isReady) ?? false
        turboReady = family.turbo.map { ImageModelCatalog.isReady($0.diffusion) } ?? false
        turboLoRAReady = family.turboLoRA.map { ImageModelCatalog.isReady($0.lora) } ?? false
        diffusionOverrideID = UserDefaults.standard.string(forKey: Self.overrideKey(family))
    }

    // MARK: Формат рисующей части (для замера скорости, ROADMAP §24)

    /// Выбранный вручную формат. nil — как обычно (лёгкая, в «Максимуме» точная).
    @Published private(set) var diffusionOverrideID: String?

    private static func overrideKey(_ f: ImageModelFamily) -> String { "imageDitOverride.\(f.id)" }

    /// Выбрать формат. Не скачан — начинаем качать; рисовать им начнём, когда докачается
    /// (до тех пор движок берёт обычный).
    func chooseDiffusion(_ part: ModelDescriptor?) {
        guard !isBusy else { return }
        UserDefaults.standard.set(part?.id, forKey: Self.overrideKey(family))
        diffusionOverrideID = part?.id
        if let part, !ImageModelCatalog.isReady(part) { download(precise: false, extra: part) }
    }

    // MARK: Выбор модели

    private static let familyKey = "imageFamilyID"

    private static func savedFamily() -> ImageModelFamily {
        UserDefaults.standard.string(forKey: familyKey).flatMap(ImageModelRegistry.family(id:))
            ?? ImageModelRegistry.qwenImage21
    }

    /// Сменить модель. Во время загрузки или рисования нельзя: и то, и другое ведёт
    /// конкретный набор файлов, и смена посреди — это полоса чужой модели.
    func select(_ id: String) {
        guard !isBusy, let next = ImageModelRegistry.family(id: id), next != family else { return }
        family = next
        UserDefaults.standard.set(next.id, forKey: Self.familyKey)
        // Образцы другой модели ни к чему: у выбранной правки может не быть вовсе.
        if !next.supportsReferences {
            references.removeAll()
            pickerItems.removeAll()
        }
        errorText = nil
        errorDetail = nil
        refreshModelState()
    }

    // MARK: Загрузка

    /// Скачать недостающее. `precise` — ещё и рисующую часть для чётких картинок.
    func download(precise: Bool, extra: ModelDescriptor? = nil, extras: [ModelDescriptor] = []) {
        guard !isBusy else { return }
        // Загрузчик в приложении один и ведёт одну модель за раз. Нашу загрузку
        // сюда не пускает `isBusy` выше — значит, это правда чужая.
        if ModelDownloader.shared.isDownloading {
            errorText = "Сейчас качается другая модель. Дождитесь её и нажмите снова."
            errorDetail = nil
            return
        }
        errorText = nil
        errorDetail = nil
        let family = self.family
        let parts = ImageModelCatalog.requiredParts(family, precise: precise) + (extra.map { [$0] } ?? []) + extras
        let missing = parts.filter { !ImageModelCatalog.isReady($0) }
        let totalBytes = missing.reduce(Int64(0)) { $0 + $1.byteSize }
        guard totalBytes > 0 else { refreshModelState(); return }
        // Место проверяем под ВЕСЬ набор, а не под первый файл: иначе мелкие части
        // скачались бы, а на энкодере в 5 ГБ загрузка встала бы через полчаса.
        // Запас — пятая часть самого крупного файла: он сначала лежит во временной папке.
        let largest = missing.map(\.byteSize).max() ?? 0
        let needed = totalBytes + largest / 5
        let free = ModelStorage.availableBytes()
        if free > 0, free < needed {
            errorText = "Не хватает места: нужно \(HumanFormat.bytes(needed)), "
                + "свободно \(HumanFormat.bytes(free)). Освободите место на телефоне."
            return
        }
        let total = Double(totalBytes)
        phase = .downloading(0)
        speedTracker = AppViewModel.DownloadSpeedTracker()
        downloadLine = ""
        // ⚠️ ВСЕ ЧАСТИ КАЧАЕТ ОБЩИЙ ЗАГРУЗЧИК — тот же, что и чат-модели: он сам меряет
        // Hugging Face и зеркало ModelScope, берёт быстрый, качает в несколько потоков,
        // докачивает после обрыва и сверяет sha256 (у каждой части она своя, из
        // `ImageModelCatalog`). Второго пути загрузки здесь нет и заводить его нельзя.
        downloadWork = Task { [weak self] in
            do {
                try ImageModelCatalog.ensureFolder(family)
                var done: Int64 = 0
                for part in missing {
                    let base = done
                    try await ModelDownloader.shared.download(part) { p in
                        let written = Double(base) + p * Double(part.byteSize)
                        Task { @MainActor in
                            guard let self, case .downloading = self.phase else { return }
                            self.phase = .downloading(min(1, written / total))
                            self.updateDownloadLine(written: Int64(written), total: totalBytes)
                        }
                    }
                    done += part.byteSize
                }
                self?.phase = .idle
                self?.downloadLine = ""
            } catch {
                self?.phase = .idle
                self?.downloadLine = ""
                if let text = Self.downloadErrorText(error), !Task.isCancelled {
                    self?.errorText = text
                    self?.errorDetail = String(describing: error)
                }
            }
            self?.refreshModelState()
        }
    }

    private var speedTracker = AppViewModel.DownloadSpeedTracker()

    /// Скорость, остаток и откуда — одной строкой. Тот же счётчик скорости, что у
    /// чат-моделей: сглаженный, без цифр в первые секунды (они там скачут).
    private func updateDownloadLine(written: Int64, total: Int64) {
        speedTracker.addSample(bytesWritten: written)
        var parts: [String] = []
        if let speed = speedTracker.reliableBytesPerSecond, speed >= 1 {
            parts.append("\(HumanFormat.bytes(Int64(speed.rounded())))/с")
            let left = Double(max(0, total - written))
            if left > 0 { parts.append("осталось \(AppViewModel.humanDuration(left / speed))") }
        }
        if let source = ModelDownloader.shared.sourceName { parts.append(source) }
        let line = parts.joined(separator: " · ")
        if line != downloadLine { downloadLine = line }
    }

    /// Что сказать человеку про оборванную загрузку. nil — её остановил он сам.
    private static func downloadErrorText(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        switch error as? PocketAgentError {
        case .generationCancelled?, .downloadStopped?:
            return nil
        case .notEnoughDiskSpace?, .diskSpaceRanOutWhileDownloading?:
            return "На телефоне кончилось место. Освободите место и нажмите «Скачать» — "
                + "скачанное не пропадёт."
        case .modelFileCorrupted?:
            return "Файл скачался испорченным. Нажмите «Скачать» — он загрузится заново."
        default:
            return "Загрузка оборвалась. Проверьте интернет и нажмите «Скачать» — "
                + "продолжится с того же места."
        }
    }

    /// Пауза: загрузчик сам запоминает, где остановился.
    func pauseDownload() {
        downloadWork?.cancel()
    }

    func deleteModel() {
        // ⚠️ Во время загрузки нельзя: стёртый файл докачивался бы в пустоту,
        // а гасить заодно загрузку чат-модели мы права не имеем (см. deleteAll).
        guard !isBusy else { return }
        ImageModelCatalog.deleteAll(family)
        result = nil
        resultTime = nil
        resultNote = nil
        refreshModelState()
    }

    // MARK: Образцы

    func loadPicked() async {
        var loaded: [ImageReference] = []
        var failed = 0
        for item in pickerItems.prefix(Self.maxReferences) {
            // Уже открытое не открываем заново — крестик меняет выбор, и без этого
            // каждое удаление перечитывало бы все фото.
            if let known = references.first(where: { $0.item == item }) {
                loaded.append(known)
                continue
            }
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                loaded.append(ImageReference(item: item, image: image))
            } else {
                failed += 1
            }
        }
        references = loaded
        if failed > 0 {
            errorText = failed == 1 ? "Одно фото не открылось — его нет среди образцов."
                                    : "Не открылось фото: \(failed). Их нет среди образцов."
            errorDetail = nil
        }
    }

    func removeReference(_ ref: ImageReference) {
        guard !isBusy else { return }
        references.removeAll { $0.id == ref.id }
        pickerItems.removeAll { $0 == ref.item }
    }

    // MARK: Генерация

    func generate(app: AppViewModel) {
        guard canGenerate else { return }
        // Движок один на процесс. Занимаем его ДО всякого ожидания: так второй запуск
        // отклоняется сразу, а нажатие «Остановить» на «Готовлю модель…» не теряется
        // (отметка остановки сбрасывается здесь и больше нигде, см. `reserve`).
        guard ImageGenEngine.shared.reserve() else {
            errorText = ImageGenError.busy.humanText
            errorDetail = nil
            return
        }
        stopReason = nil
        isStopping = false
        errorText = nil
        errorDetail = nil
        savedNote = nil
        photosDenied = false
        let preset = family.preset(quality.level)
        let (w, h) = aspect.size(baseSide: preset.baseSide)
        let seed = Int64(seedText.trimmingCharacters(in: .whitespaces))
        // Чёткая рисующая часть — только в «Максимуме» и только если она скачана.
        let precise = quality == .max && preciseReady
        let refs = family.supportsReferences
            ? references.compactMap { Self.pixels(from: $0.image, maxSide: preset.baseSide) }
            : []
        // Турбо рисует за свои 4 шага (ROADMAP §24); размер — тот же, что у уровня.
        // Турбо v0.2.1 (дополнение) — за 6 шагов на своём расписании (§24.4); нет её — v0.1.
        let loraTurbo = ImageModelCatalog.turboLoRAToUse(family, level: quality.level,
                                                         overrideID: diffusionOverrideID)
        let turbo = loraTurbo == nil
            ? ImageModelCatalog.turboToUse(family, level: quality.level, precise: precise,
                                           overrideID: diffusionOverrideID) : nil
        let steps = loraTurbo?.steps ?? turbo?.steps ?? preset.steps
        var request = ImageGenRequest(prompt: prompt, width: w, height: h, steps: steps,
                                      seed: seed, preciseWeights: precise, references: refs,
                                      familyID: family.id)
        request.diffusionOverrideID = diffusionOverrideID
        request.useTurbo = turbo != nil
        request.useTurboLoRA = loraTurbo != nil
        phase = .generating(step: 0, of: steps)
        preview = nil
        UIApplication.shared.isIdleTimerDisabled = true
        // Модель живёт всё время приложения (`shared`), поэтому держим её сильной ссылкой.
        genWork = Task {
            // Чат-модель держит гигабайты — отпускаем её до того, как грузить свою.
            await app.releaseChatModelForImages()
            // В журнал картинки — выгрузилась ли чат-модель на самом деле (ROADMAP §24.5).
            ImageGenEngine.shared.setChatModelNote(app.chatModelNoteForImageLog)
            let outcome: Result<ImageGenResult, Error>
            // Остановили, пока выгружалась чат-модель, — дальше не идём.
            if ImageGenEngine.shared.isCancelRequested {
                outcome = .failure(ImageGenError.cancelled)
            } else {
                UserDefaults.standard.set(true, forKey: self.inFlightKey)
                outcome = await Task.detached(priority: .userInitiated) {
                    Result {
                        try ImageGenEngine.shared.generate(request, onPreview: { px in
                            let image = ImageStudioModel.image(from: px)
                            Task { @MainActor in
                                let m = ImageStudioModel.shared
                                guard case .generating = m.phase, let image else { return }
                                let first = m.preview == nil
                                m.preview = image
                                // Первый черновик — прокрутить к нему, как к готовой картинке.
                                if first { m.resultVersion += 1 }
                            }
                        }) { step, of in
                            Task { @MainActor in
                                let m = ImageStudioModel.shared
                                if case .generating = m.phase { m.phase = .generating(step: step, of: of) }
                            }
                        }
                    }
                }.value
                UserDefaults.standard.set(false, forKey: self.inFlightKey)
            }
            // Сюда приходим, когда `generate` уже вышел, а с ним и `free_sd_ctx`:
            // веса отданы, движок можно отпускать.
            ImageGenEngine.shared.release()
            UIApplication.shared.isIdleTimerDisabled = false
            self.phase = .idle
            self.preview = nil
            self.isStopping = false
            switch outcome {
            case .success(let r):
                self.result = Self.image(from: r.image)
                self.resultVersion += 1
                self.lastSeed = r.seed
                self.resultTime = "Готово за \(Int(r.totalSeconds.rounded())) с"
                self.resultNote = Self.note(for: r, w: w, h: h)
            case .failure(let error):
                let e = (error as? ImageGenError) ?? .failed(detail: String(describing: error))
                if e == .cancelled {
                    if self.stopReason == .background {
                        self.errorText = "Остановлено: приложение свернули."
                    }
                } else {
                    self.errorText = e.humanText
                    self.errorDetail = e.detail
                }
            }
            self.stopReason = nil
        }
    }

    func stop() {
        guard case .generating = phase else { return }
        if stopReason == nil { stopReason = .user }
        isStopping = true
        ImageGenEngine.shared.cancel()
    }

    /// Приложение свернули. Рисовать в фоне iOS видеокарте не даёт, а память
    /// приложения в фоне — первая на выселение: честнее остановить и сказать.
    func appWentToBackground() {
        guard case .generating = phase else { return }
        stopReason = .background
        stop()
    }

    /// Экран закрыли. Идущую картинку останавливаем (держать гигабайты без зрителя
    /// незачем), а чат-модель возвращаем, только когда фоновая задача ДЕЙСТВИТЕЛЬНО
    /// вышла: до этого контекст движка ещё держит веса, и вернуть чат сразу — значит
    /// на секунды получить две модели в памяти. Загрузку не трогаем — она доедет сама.
    ///
    /// Открытую модель картинок (контекст движка) держим для следующей картинки
    /// (ROADMAP §24, задача Б): возвращается чат-модель — закрываем сразу (это делает
    /// `AppViewModel.prepareModel`); чату возвращать нечего — держим ещё
    /// `keepAfterCloseSeconds`, чтобы вернуться на экран без повторного открытия.
    func screenClosed(app: AppViewModel) {
        screenIsOpen = false
        stop()
        let running = genWork
        Task {
            await running?.value
            let chatReturns = app.restoreChatModelAfterImages()
            if !chatReturns && !self.screenIsOpen {
                ImageGenEngine.shared.scheduleRelease(after: ImageGenEngine.keepAfterCloseSeconds)
            }
        }
    }

    /// Экран открыли — назначенное закрытие модели отменяем: она пригодится.
    func screenOpened() {
        screenIsOpen = true
        ImageGenEngine.shared.cancelScheduledRelease()
    }

    // MARK: Проверка ядра умножения (для замера скорости, ROADMAP §24)

    /// Итог последней проверки одной строкой; nil — не проверяли.
    @Published private(set) var kernelCheckLine: String?
    @Published private(set) var isCheckingKernel = false

    /// Прогнать на видеочипе старое и новое (схема MLX) ядро умножения и сравнить:
    /// верно ли считает и во сколько быстрее. Движок занимается на время замера —
    /// рисовать в это же время нельзя (два набора памяти видеочипа разом).
    func checkKernel() {
        guard !isBusy, !isCheckingKernel else { return }
        guard ImageGenEngine.shared.reserve() else {
            errorText = ImageGenError.busy.humanText
            return
        }
        isCheckingKernel = true
        kernelCheckLine = "Проверяю ядро… до минуты"
        Task.detached(priority: .userInitiated) {
            let line = ImageGenEngine.shared.checkKernel()
            ImageGenEngine.shared.release()
            await MainActor.run {
                ImageStudioModel.shared.isCheckingKernel = false
                ImageStudioModel.shared.kernelCheckLine = line
            }
        }
    }

    // MARK: Зерно

    func reuseLastSeed() {
        if let lastSeed { seedText = String(lastSeed) }
    }

    func clearSeed() { seedText = "" }

    // MARK: Сохранение

    func saveToPhotos() {
        guard let image = result, let png = image.pngData() else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    self.savedNote = "Нет доступа к «Фото»."
                    self.photosDenied = true
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                // PNG, а не JPEG: модель умеет прозрачный фон, JPEG его потеряет.
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: nil)
            }) { ok, _ in
                Task { @MainActor in
                    self.photosDenied = false
                    self.savedNote = ok ? "Сохранено в «Фото»" : "Не получилось сохранить."
                }
            }
        }
    }

    // MARK: Числа замера

    /// Подробности под картинкой. ⚠️ Не удалять: первый запуск на телефоне владельца
    /// должен дать факты про память, а не догадки. Спрятаны за «Подробности».
    private static func note(for r: ImageGenResult, w: Int, h: Int) -> String {
        func gb(_ v: UInt64) -> String { String(format: "%.1f ГБ", Double(v) / 1_073_741_824).replacingOccurrences(of: ".", with: ",") }
        func sec(_ v: Double) -> String { String(format: "%.1f с", v).replacingOccurrences(of: ".", with: ",") }
        // По частям — чтобы на телефоне сравнивать форматы весов и матричные блоки
        // по шагу, а не по общему времени (ROADMAP §24). Каждый шаг — в журнале запуска.
        let steps = r.stepSeconds
        var parts = ["подготовка \(sec(r.prepareSeconds))"]
        // Была ли модель уже открыта прошлой картинкой и понадобился ли энкодер
        // (ROADMAP §24, задача Б) — чтобы на телефоне видеть, откуда взялась подготовка.
        parts.append(r.contextReused ? "модель уже открыта" : "открытие модели \(sec(r.contextOpenSeconds))")
        if r.promptFromCache { parts.append("описание из памяти") }
        if !steps.isEmpty {
            // Медиана, а не среднее: первый шаг с прогревом, пропущенные кэшем — короткие.
            let median = steps.sorted()[steps.count / 2]
            parts.append("шаг \(sec(median)) (\(steps.count) шт.)")
        }
        parts.append("проявка \(sec(r.decodeSeconds))")
        if r.peakFootprintBytes > 0 { parts.append("пик памяти \(gb(r.peakFootprintBytes))") }
        if r.minAvailableBytes > 0 { parts.append("запас \(gb(r.minAvailableBytes))") }
        parts.append("\(w)×\(h)")
        parts.append("веса \(r.diffusionName)")
        parts.append("зерно \(r.seed)")
        return parts.joined(separator: " · ")
    }

    // MARK: Точки ↔ картинки

    /// Образец для движка: RGB без прозрачности, длинная сторона не больше `maxSide`.
    /// Меньше образец — короче «подсказка» энкодеру и меньше памяти на неё.
    static func pixels(from image: UIImage, maxSide: Int) -> ImageGenPixels? {
        guard let cg = image.cgImage else { return nil }
        let scale = min(1.0, Double(maxSide) / Double(max(cg.width, cg.height)))
        let w = max(32, Int(Double(cg.width) * scale))
        let h = max(32, Int(Double(cg.height) * scale))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Поворот снимка с камеры учитывает UIImage, а не CGImage: рисуем через UIKit.
        UIGraphicsPushContext(ctx)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        UIGraphicsPopContext()
        var rgb = Data(count: w * h * 3)
        rgb.withUnsafeMutableBytes { out in
            let o = out.bindMemory(to: UInt8.self)
            for i in 0..<(w * h) {
                o[i * 3] = rgba[i * 4]
                o[i * 3 + 1] = rgba[i * 4 + 1]
                o[i * 3 + 2] = rgba[i * 4 + 2]
            }
        }
        return ImageGenPixels(width: w, height: h, channels: 3, bytes: rgb)
    }

    // nonisolated: черновики собираются на потоке движка, не занимая главный.
    nonisolated static func image(from px: ImageGenPixels) -> UIImage? {
        let bpp = px.channels
        guard bpp == 3 || bpp == 4, let provider = CGDataProvider(data: px.bytes as CFData) else { return nil }
        let info: CGBitmapInfo = bpp == 4
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let cg = CGImage(width: px.width, height: px.height, bitsPerComponent: 8,
                               bitsPerPixel: 8 * bpp, bytesPerRow: px.width * bpp,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Экран

struct ImageStudioView: View {

    @ObservedObject var app: AppViewModel
    /// С какой моделью открыться (пришли из поиска). nil — с той, что выбрана.
    var openFamilyID: String? = nil
    @ObservedObject private var model = ImageStudioModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var isDeleteAsked = false
    @State private var isDetailShown = false
    @State private var isNoteShown = false
    @State private var isSeedAsked = false
    @State private var seedDraft = ""
    @AppStorage(ImageGenEngine.tensorOffKey) private var tensorOff = false
    @AppStorage(ImageGenEngine.tensorF16OffKey) private var tensorF16Off = false
    @AppStorage(ImageGenEngine.vaeF16OffKey) private var vaeF16Off = false
    @AppStorage(ImageGenEngine.naxOffKey) private var naxOff = false

    private static let resultAnchor = "result"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Картинки")
                            .font(Theme.Fonts.screenTitle)
                            .foregroundStyle(Theme.textPrimary)
                        familyPicker
                    }

                    if model.modelReady {
                        promptBlock
                        // Модель правку по фото не умеет — образцов нет вовсе, а не
                        // серой кнопкой: нажимать на то, что не сработает, незачем.
                        if model.family.supportsReferences { referencesBlock }
                        choicesBlock
                        resultBlock.id(Self.resultAnchor)
                    } else {
                        downloadCard
                    }
                    errorBlock
                    if model.modelReady { modelFooter }
                    if let line = model.kernelCheckLine {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.bottom, 24)
            }
            // Готовая картинка появляется ниже поля и выборов — без прокрутки человек
            // её просто не увидел бы, особенно с открытой клавиатурой.
            .onChange(of: model.resultVersion) { _ in
                withAnimation { proxy.scrollTo(Self.resultAnchor, anchor: .top) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            GlassCircleButtonRow {
                GlassCircleButton(systemImage: "xmark", accessibilityTitle: "Закрыть") { dismiss() }
            } trailing: {
                EmptyView()
            }
            .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.modelReady { actionBar }
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            model.screenOpened()
            if let openFamilyID { model.select(openFamilyID) }
            model.refreshModelState()
        }
        .onChange(of: model.pickerItems) { _ in
            Task { await model.loadPicked() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { model.appWentToBackground() }
        }
        .onDisappear {
            // Картинку останавливаем, чат-модель вернётся, когда движок отпустит веса.
            model.screenClosed(app: app)
        }
        .confirmationDialog("Удалить \(model.family.displayName)?", isPresented: $isDeleteAsked,
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { model.deleteModel() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Освободится \(HumanFormat.bytes(ImageModelCatalog.occupiedBytes(model.family))). Скачать заново можно в любой момент.")
        }
        .alert("Зерно", isPresented: $isSeedAsked) {
            TextField("число", text: $seedDraft)
                .keyboardType(.numberPad)
            Button("Готово") { model.seedText = seedDraft.filter(\.isNumber) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("С тем же зерном и тем же описанием выйдет та же картинка.")
        }
    }

    // MARK: Какой моделью рисуем

    /// Имя модели под заголовком; нажатие — список всех наборов.
    /// ⚠️ Меню, а не ещё один блок на экране: выбирают модель редко, а место под
    /// полем описания нужно каждый раз.
    private var familyPicker: some View {
        Menu {
            ForEach(ImageModelRegistry.all) { f in
                Button {
                    model.select(f.id)
                } label: {
                    if f == model.family {
                        Label(f.displayName, systemImage: "checkmark")
                    } else {
                        Text(f.displayName)
                    }
                    Text(familySubtitle(f))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.family.displayName)
                    .font(.subheadline)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(minHeight: Theme.Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        // Во время загрузки и рисования смена модели не пускается (`select`) —
        // и кнопка не притворяется живой.
        .disabled(model.isBusy)
        .accessibilityLabel("Модель: \(model.family.displayName)")
    }

    /// «На телефоне · Быстрая: 8 шагов…» или «6,0 ГБ · …».
    private func familySubtitle(_ f: ImageModelFamily) -> String {
        let head = ImageModelCatalog.isInstalled(f)
            ? "На телефоне"
            : HumanFormat.bytes(ImageModelCatalog.missingBytes(f, precise: false))
        return "\(head) · \(f.tagline)"
    }

    // MARK: Модель не скачана

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Что умеет модель, уже сказано на входе — здесь только то, что нужно сейчас.
            Text("Модель скачивается один раз, дальше работает без интернета.")
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if case .downloading(let p) = model.phase {
                ProgressView(value: p)
                    .tint(Theme.Colors.accent)
                HStack {
                    Text("\(Int((p * 100).rounded())) %")
                        .font(Theme.Fonts.counter)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Пауза") { model.pauseDownload() }
                        .font(.subheadline)
                }
                // Скорость, остаток и откуда качаем — ROADMAP §23. Пока считать не по чему,
                // строки нет вовсе, а не «считаю…»: процент выше и так показывает движение.
                if !model.downloadLine.isEmpty {
                    Text(model.downloadLine)
                        .font(Theme.Fonts.counter)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button {
                    model.download(precise: false)
                } label: {
                    Text("Скачать · \(model.downloadSizeText)")
                        .font(.body.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.Colors.accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Theme.Colors.textOnAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Metrics.cardPadding)
        .cardSurface()
    }

    // MARK: Поле

    private var promptBlock: some View {
        TextField(model.references.isEmpty ? "Что нарисовать?" : "Что поменять на фото?",
                  text: $model.prompt, axis: .vertical)
            .lineLimit(3...8)
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .padding(Theme.Metrics.cardPadding)
            .cardSurface()
            .disabled(model.isBusy)
    }

    // MARK: Образцы

    private var referencesBlock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.references) { ref in
                    Image(uiImage: ref.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            Button { model.removeReference(ref) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Убрать образец")
                            // Образцы уже переданы движку — убирать их посреди картинки бессмысленно.
                            .disabled(model.isBusy)
                            .opacity(model.isBusy ? 0 : 1)
                        }
                }
                if model.references.count < ImageStudioModel.maxReferences {
                    PhotosPicker(selection: $model.pickerItems,
                                 maxSelectionCount: ImageStudioModel.maxReferences,
                                 matching: .images) {
                        Label(model.references.isEmpty ? "Фото для правки" : "Ещё",
                              systemImage: "photo.badge.plus")
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .frame(height: 64)
                            .cardSurface(cornerRadius: 10)
                    }
                    .disabled(model.isBusy)
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: Выборы

    private var choicesBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                choiceLabel("Качество")
                Picker("Качество", selection: $model.quality) {
                    ForEach(ImageQuality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                // Выбрал «Максимум» без дополнения — говорим прямо здесь, а не молча
                // рисуем обычным режимом.
                if let bytes = model.turboLoRAOfferBytes {
                    HStack {
                        Text("Ближе к обычной модели · ~+30 с · +\(HumanFormat.bytes(bytes))")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if model.isDownloading {
                            Text("Качается…")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Button("Скачать") { model.downloadTurboLoRA() }
                                .font(.caption.bold())
                        }
                    }
                }
                if model.offersTurbo, let t = model.family.turbo {
                    HStack {
                        Text("Быстрее в несколько раз · +\(HumanFormat.bytes(t.diffusion.byteSize))")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if model.isDownloading {
                            Text("Качается…")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Button("Скачать") { model.downloadTurbo() }
                                .font(.caption.bold())
                        }
                    }
                }
                if model.needsPreciseForMax {
                    HStack {
                        Text("Чётче с дополнением · +\(HumanFormat.bytes(model.family.diffusionPrecise?.byteSize ?? 0))")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if model.isDownloading {
                            Text("Качается…")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Button("Скачать") { model.download(precise: true) }
                                .font(.caption.bold())
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                choiceLabel("Пропорции")
                Picker("Пропорции", selection: $model.aspect) {
                    ForEach(ImageAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            // Зерно видно, только когда его задали: иначе человек забыл бы, почему
            // картинки вдруг перестали меняться.
            if !model.seedText.isEmpty {
                HStack(spacing: 6) {
                    Text("Зерно \(model.seedText)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Button { model.clearSeed() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Случайное зерно")
                }
            }
        }
        .disabled(model.isBusy)
    }

    private func choiceLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
    }

    // MARK: Итог

    @ViewBuilder
    private var resultBlock: some View {
        if let draft = model.preview {
            // Черновик по шагам: крошечный (у Qwen 32×32 точки), растянут мягко —
            // видно, как проступает картинка. Кнопок под ним нет: сохранять нечего.
            Image(uiImage: draft)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, maxHeight: 440)
                .accessibilityLabel("Черновик картинки")
        } else if let image = model.result {
            VStack(alignment: .leading, spacing: 10) {
                // Высота ограничена, чтобы «Сохранить в Фото» под картинкой оставалась
                // на экране, а не уезжала вниз у высоких пропорций.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity, maxHeight: 440)
                HStack {
                    Button { model.saveToPhotos() } label: {
                        Label("Сохранить в Фото", systemImage: "square.and.arrow.down")
                            .font(.subheadline)
                    }
                    Spacer()
                    if let saved = model.savedNote {
                        Text(saved)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if model.photosDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Открыть Настройки") { UIApplication.shared.open(url) }
                        .font(.caption)
                }
                if let time = model.resultTime {
                    // На виду только время; остальной замер — за «Подробности».
                    // ⚠️ Замер не удалять: он нужен первому запуску на телефоне владельца.
                    if let note = model.resultNote {
                        DisclosureGroup(isExpanded: $isNoteShown) {
                            Text(note)
                                .font(Theme.Fonts.caption.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Text(time)
                        }
                        .font(.caption)
                        .tint(Theme.textSecondary)
                    } else {
                        Text(time)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var errorBlock: some View {
        if let text = model.errorText {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = model.errorDetail {
                    DisclosureGroup("Подробности", isExpanded: $isDetailShown) {
                        Text(detail)
                            .font(Theme.Fonts.code)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .tint(Theme.textSecondary)
                }
            }
        }
    }

    /// Модель на телефоне: сколько весит и что с ней можно сделать — одним меню.
    /// Туда же — редкое: зерно.
    private var modelFooter: some View {
        HStack {
            if case .downloading(let p) = model.phase {
                // Докачка дополнений (турбо, «чётче») идёт здесь, а не в карточке первого
                // скачивания, — и строка скорости/источника нужна тут же. Без неё владелец
                // видел «просто полоску» и не понимал, почему так долго (24.09.2026).
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: p).tint(Theme.Colors.accent)
                    Text(model.downloadLine.isEmpty
                         ? "\(Int((p * 100).rounded())) % · замеряю скорость…"
                         : "\(Int((p * 100).rounded())) % · \(model.downloadLine)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Button("Пауза") { model.pauseDownload() }.font(.caption)
            } else {
                Text("Модель на телефоне · \(HumanFormat.bytes(ImageModelCatalog.occupiedBytes(model.family)))")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                Spacer()
                Menu {
                    Section {
                        if model.lastSeed != nil {
                            Button("Повторить с тем же зерном") { model.reuseLastSeed() }
                        }
                        Button("Задать зерно…") {
                            seedDraft = model.seedText
                            isSeedAsked = true
                        }
                    }
                    if !model.preciseReady, let precise = model.family.diffusionPrecise {
                        Button("Чёткие картинки в «Максимуме» · +\(HumanFormat.bytes(precise.byteSize))") {
                            model.download(precise: true)
                        }
                    }
                    speedMenu
                    Button("Удалить модель", role: .destructive) { isDeleteAsked = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.textSecondary)
                }
                .disabled(model.isBusy)
                .accessibilityLabel("Ещё")
            }
        }
    }

    /// Переключатели для сравнения скорости на телефоне (ROADMAP §24): формат
    /// рисующей части и матричные блоки видеочипа. Спрятаны в «…»: нужны для замера,
    /// а не каждый раз. Какими весами рисовали — видно в «Подробностях» под картинкой.
    private var speedMenu: some View {
        Menu("Для замера скорости") {
            // С турбо v0.1 «Быстро» и «Нормально» рисует она — выбор касается «Максимума».
            // С турбо v0.2.1 выбор касается всех уровней: дополнение ложится на эти же веса.
            Section(model.turboReady && !model.turboLoRAReady ? "Веса для «Максимума»" : "Веса рисующей части") { diffusionButtons }
            Toggle("Матричные блоки видеочипа", isOn: Binding(
                get: { !tensorOff }, set: { tensorOff = !$0 }))
            Toggle("Быстрый режим матричных блоков", isOn: Binding(
                get: { !tensorF16Off }, set: { tensorF16Off = !$0 }))
                .disabled(tensorOff)
            Toggle("Проявка в half", isOn: Binding(
                get: { !vaeF16Off }, set: { vaeF16Off = !$0 }))
            Toggle("Ядро MLX", isOn: Binding(
                get: { !naxOff }, set: { naxOff = !$0 }))
                .disabled(tensorOff)
            Button(model.isCheckingKernel ? "Проверяю ядро…" : "Проверить ядро") { model.checkKernel() }
                .disabled(model.isCheckingKernel)
            Text("Блоки видеочипа — после перезапуска приложения")
        }
    }

    @ViewBuilder
    private var diffusionButtons: some View {
            Button {
                model.chooseDiffusion(nil)
            } label: {
                if model.diffusionOverrideID == nil { Label("Как обычно", systemImage: "checkmark") }
                else { Text("Как обычно") }
            }
            ForEach(model.family.diffusionChoices, id: \.id) { part in
                Button {
                    model.chooseDiffusion(part)
                } label: {
                    let title = Self.quantName(part)
                    if model.diffusionOverrideID == part.id { Label(title, systemImage: "checkmark") }
                    else { Text(title) }
                    Text(ImageModelCatalog.isReady(part) ? HumanFormat.bytes(part.byteSize)
                         : "скачать \(HumanFormat.bytes(part.byteSize))")
                }
            }
    }

    /// «qwen_image_2.1-Q4_0.gguf» → «Q4_0».
    private static func quantName(_ part: ModelDescriptor) -> String {
        let name = ((part.fileName as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.split(separator: "-").last.map(String.init) ?? name
    }

    // MARK: Кнопка

    private var actionBar: some View {
        FloatingGlassBar {
            if case .generating(let step, let of) = model.phase {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.isStopping ? "Останавливаю…"
                             : step == 0 ? "Готовлю модель…" : "Шаг \(step) из \(of)")
                            .font(Theme.Fonts.counter)
                            .foregroundStyle(Theme.Colors.glassTextPrimary)
                        ProgressView(value: of > 0 ? Double(step) / Double(of) : 0)
                            .tint(Theme.Colors.accent)
                    }
                    GlassCircleButton(systemImage: "stop.fill", accessibilityTitle: "Остановить",
                                      emphasis: .destructive) { model.stop() }
                        .disabled(model.isStopping)
                }
            } else {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    model.generate(app: app)
                } label: {
                    Text(model.references.isEmpty ? "Нарисовать" : "Изменить")
                        .font(.body.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.Colors.accent.opacity(model.canGenerate ? 1 : 0.35),
                                    in: Capsule())
                        .foregroundStyle(Theme.Colors.textOnAccent)
                }
                .buttonStyle(.plain)
                .disabled(!model.canGenerate)
            }
        }
    }
}

extension AppViewModel {
    /// Что с чат-моделью прямо сейчас — строкой для журнала картинки. Гипотеза владельца
    /// «в памяти сидят две модели» (ROADMAP §24.5) проверяется по этой строке, а не на глаз.
    var chatModelNoteForImageLog: String {
        switch modelStatus {
        case .idle: return "не загружена"
        case .downloading: return "качается (в памяти её нет)"
        case .verifying: return "проверяется файл"
        case .loading: return "ГРУЗИТСЯ в память"
        case .ready: return "ЗАГРУЖЕНА в память"
        case .failed: return "не загружена (ошибка)"
        }
    }
}
