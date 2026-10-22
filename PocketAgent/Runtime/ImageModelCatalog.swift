//
//  ImageModelCatalog.swift
//  PocketAgent / Runtime
//
//  Файлы модели картинок Qwen-Image-2.1 для движка stable-diffusion.cpp.
//.
//
//  ⚠️ ВСЕ ЦИФРЫ СНЯТЫ ЖИВЫМ ЗАПРОСОМ К API HUGGING FACE 23.09.2026
//  (`/api/models/<репо>?blobs=true`): версия репозитория, точный размер и sha256.
//  Поправить «по памяти» нельзя — только новым ответом сервера.
//
//  ⚠️ ЧЕЛОВЕКУ ЭТИ ФАЙЛЫ В СПИСКЕ ЧАТ-МОДЕЛЕЙ НЕ ПОКАЗЫВАЮТСЯ. Они лежат в своей
//  подпапке «QwenImage21» внутри хранилища моделей, а поиск чат-моделей в подпапки
//  своего хранилища не заходит. Иначе два файла .gguf (рисующая часть и энкодер)
//  выглядели бы как модели для разговора, и выбрать их там было бы можно — а говорить
//  рисующая часть не умеет вовсе.
//
//  Почему рисующая часть от leejet, а не от unsloth: leejet — автор самого
//  stable-diffusion.cpp, и его файлы указаны в документации движка для Qwen-Image-2.1
//. У unsloth «динамические» кванты с поднятой точностью
//  отдельных слоёв — движок их, по словам unsloth, тоже читает, но мы это не проверяли.
//  Размеры почти те же: Q3_K 3,27 ГБ против Q3_K_M 3,17 ГБ, Q4_K 4,20 против 4,20.
//

import Foundation

public enum ImageModelCatalog {

    /// Подпапка внутри хранилища моделей.
    public static let folderName = "QwenImage21"

    // ⚠️ Лицензия самой модели — исследовательская (Qwen Research License), НЕ для
    // продажи в магазине без договора с Alibaba. Для личного телефона владельца — можно.
    // Для выкладки в App Store это блокер, записан в.
    private static let researchLicense = "Qwen Research License — только некоммерческое использование"

    private static let ditRepo = "leejet/Qwen-Image-2.1-GGUF"
    private static let ditCommit = "cc11433936a06e9765f7c0c0b1f0436cfd2b9856"

    /// Рисующая часть, лёгкие веса (Q4_0) — обычная с 24.09.2026.
    ///
    /// Почему Q4_0, а не прежняя Q3_K: на мини (M1) обе идут с одной скоростью
    /// (12 шагов — 456 с против 454 с), а Q4_0 заметно чётче: у Q3_K мыльное лицо,
    /// у Q4_0 видны глаза и листья.
    /// Цена — +0,9 ГБ на диске и в памяти; при 12 ГБ телефона владельца это приемлемо.
    /// Уже скачанная Q3_K не пропадает и не требует докачки: рисуем ей, пока человек
    /// сам не выберет другую (`requiredParts`, `diffusionToUse`).
    public static let ditLight = part(
        id: "qwen-image-2-1-dit-q4-0",
        name: "Qwen-Image 2.1 — рисующая часть (лёгкая)",
        repo: ditRepo, commit: ditCommit,
        repoPath: "qwen_image_2.1-Q4_0.gguf",
        bytes: 4_197_494_816,
        sha: "8d992dc95dcbf13196a4aca893697fb56a5c9263e19e7b40c898be2cf29e9147",
        license: researchLicense)

    /// Прежняя лёгкая (Q3_K, до 24.09.2026) — меньше на 0,9 ГБ, та же скорость на M1, мыльнее.
    public static let ditQ3K = part(
        id: "qwen-image-2-1-dit-q3k",
        name: "Qwen-Image 2.1 — рисующая часть (Q3_K)",
        repo: ditRepo, commit: ditCommit,
        repoPath: "qwen_image_2.1-Q3_K.gguf",
        bytes: 3_270_553_632,
        sha: "5a6352cb450d334ba17a9d18c7fd8c3e774799245b9da0f963ce0c6624deb758",
        license: researchLicense)

    /// Рисующая часть, точные веса (Q4_K).
    public static let ditPrecise = part(
        id: "qwen-image-2-1-dit-q4k",
        name: "Qwen-Image 2.1 — рисующая часть (точная)",
        repo: ditRepo, commit: ditCommit,
        repoPath: "qwen_image_2.1-Q4_K.gguf",
        bytes: 4_197_494_816,
        sha: "29f9c83c249ff0292fb2943fceddfa2319b446601866c82a4f8be062abea72c2",
        license: researchLicense)

    /// Q8_0 — для сравнения скорости на телефоне: у ggml самые простые
    /// ядра для 8 бит. На мини с 8 ГБ не запускали (7,7 ГБ не помещаются рядом с системой);
    /// на телефоне с 12 ГБ — не проверено. Размер и сумма — из API HF 24.09.2026.
    public static let ditQ8_0 = part(
        id: "qwen-image-2-1-dit-q8-0",
        name: "Qwen-Image 2.1 — рисующая часть (Q8_0)",
        repo: ditRepo, commit: ditCommit,
        repoPath: "qwen_image_2.1-Q8_0.gguf",
        bytes: 7_687_155_744,
        sha: "f8b244b00937f0e444a40dbf7866460871b89b30142594973b6012d1b471dc0a",
        license: researchLicense)

    // MARK: Турбо-версия
    //
    // Viggle/Qwen-Image-2.1-viggle-turbo — та же Qwen-Image 2.1, дообученная (DMD2)
    // рисовать за 4 шага без второго прохода CFG: 4 прохода вместо 24 на «Быстро».
    // Энкодер и проявка — те же, что у обычной (так в карточке модели: «Text encoder,
    // VAE and processor are not redistributed; they load from the base repo»).
    //
    // ⚠️ ПОЧЕМУ ИМЕННО ЭТОТ ФАЙЛ (карточки прочитаны 24.09.2026):
    //  • Готовый файл целиком у Viggle один — v0.1 (`transformer/`, 4 шага). Более
    //    новые v0.2 / v0.2.1 выпущены ТОЛЬКО как дополнение-LoRA поверх обычной модели
    //    (6 шагов на особом расписании шума). По словам авторов они лучше v0.1
    //    (разнообразие 0,98 против 0,72 от обычной модели, резче), но им нужно
    //    подключение LoRA «на лету» и своё расписание шагов — на телефоне это
    //    не проверено вовсе. Записано в как следующий шаг.
    //  • GGUF от Abiray — пересчёт v0.1 из `transformer/` (сказано в карточке).
    //    Нормировки внимания оставлены в FP32, входной слой — в BF16 (так в карточке).
    //  • Квант Q4_K_S (4,06 ГБ): по размеру и точности ровня нашей обычной лёгкой Q4_0
    //    (4,20 ГБ), весь из одного вида блоков. Q4_K_M на 0,13 ГБ больше ради Q6_K
    //    у части слоёв; Q3_K_M меньше, но у обычной Q3_K мы уже видели мыльное лицо.
    //  • Лицензия — та же Qwen Research License (некоммерческая), как у обычной.
    // Размер и сумма — из API HF (`?blobs=true`) 24.09.2026, коммит закреплён.
    public static let turboDiT = part(
        id: "qwen-image-2-1-turbo-q4ks",
        name: "Qwen-Image 2.1 — рисующая часть (турбо)",
        repo: "Abiray/Qwen-Image-2.1-viggle-4-steps-turbo-GGUF",
        commit: "0016110b769f6625b92098ab9e3f4906dba367f6",
        repoPath: "qwen_image_2.1_turbo_Q4_K_S.gguf",
        bytes: 4_059_323_168,
        sha: "b94e9ce95d810dbd51d953d3c92a8aa5e9065ac1b1aa4013008915ded0131b29",
        license: researchLicense)

    /// Настройки турбо — из карточек (4 шага, CFG 1, euler). «Максимум» рисует обычная.
    public static let turbo = ImageTurbo(diffusion: turboDiT, steps: 4, cfg: 1.0,
                                         levels: [.fast, .normal])

    // MARK: Турбо v0.2.1 — дополнение-LoRA от Viggle
    //
    // Viggle выпускает v0.2.1 только дополнением к обычной модели (готового файла нет).
    // По их замеру она ближе к обычной модели (разнообразие 0,98 против 0,72 у v0.1,
    // точнее следует описанию). Наше честное сравнение с НАСТОЯЩЕЙ v0.1 на мини — картинки
    // сопоставимы, у v0.2.1 чуть реалистичнее.
    // Цена — 6 шагов вместо 4 и ~+17 % на шаг (дополнение считается на лету). Поэтому
    // это выбор по кнопке, а не установка по умолчанию.
    //
    // ⚠️ ПОЧЕМУ r128, А НЕ r256: r128 — точное усечение r256 (SVD), у Viggle отличие
    // картинок LPIPS 0,024 — на уровне шума самой перезаписи r256 (0,024). Вдвое легче
    // (0,68 против 1,36 ГБ) и дешевле на шаге. Её же берут их процессы ComfyUI.
    // Размер и сумма — из API HF (`?blobs=true`) 24.09.2026, коммит закреплён.
    public static let turboLoRAFile = part(
        id: "qwen-image-2-1-turbo-v021-lora-r128",
        name: "Qwen-Image 2.1 — турбо v0.2.1 (дополнение)",
        repo: "Viggle/Qwen-Image-2.1-viggle-turbo",
        commit: "b77064be8b3f0b1a13c6a212067cb3d281c60c84",
        repoPath: "Qwen-Image-2.1-viggle-turbo-v0.2.1-6step-lora-r128.safetensors",
        bytes: 679_604_800,
        sha: "bafb91d0047df3f9b8a5a850b0c967f051164314d8aad778dfa34d9c24ec345b",
        license: researchLicense)

    /// Узлы расписания — дословно с карточки v0.2.1: 4 учебных узла, первый отрезок
    /// 1 → 0,75 порезан на три («6 steps … 0% composition drift»).
    public static let turboLoRA = ImageTurboLoRA(
        lora: turboLoRAFile, fusedFileName: "turbo-v021-r128-fused.safetensors",
        nodes: [1.0, 0.9375, 0.875, 0.75, 0.5, 0.25], levels: [.fast, .normal])

    private static let turboLoRAs = [turboLoRA]

    /// Слитый файл дополнения (его читает движок). Лежит рядом с оригиналом.
    public static func fusedURL(_ t: ImageTurboLoRA) -> URL? {
        (try? ModelStorage.fileURL(for: t.lora))?
            .deletingLastPathComponent().appendingPathComponent(t.fusedFileName)
    }

    /// Готовый к движку файл дополнения. Первый раз после загрузки — сливает
    /// (`LoRAFuse`, ~3 с на M1, без единого умножения) и стирает оригинал: он больше
    /// не нужен, а 0,68 ГБ на телефоне лишние. Слитый пишется атомарно — огрызок
    /// после обрыва за готовый не сойдёт. Звать с фонового потока.
    public static func preparedLoRA(_ t: ImageTurboLoRA) throws -> URL {
        guard let fused = fusedURL(t), let original = try? ModelStorage.fileURL(for: t.lora) else {
            throw ImageGenError.modelMissing
        }
        if FileManager.default.fileExists(atPath: fused.path) { return fused }
        guard ModelStorage.byteSize(of: original) == t.lora.byteSize else {
            throw ImageGenError.modelMissing
        }
        try LoRAFuse.fuseQwenImageMLP(input: original, output: fused)
        ModelDownloadPlanStore.clear(modelID: t.lora.id)
        try? FileManager.default.removeItem(at: original)
        return fused
    }

    /// Текстовый энкодер Qwen3-VL-8B — официальный файл Qwen, его же называет
    /// документация движка.
    public static let encoder = part(
        id: "qwen3-vl-8b-q4km-encoder",
        name: "Qwen-Image 2.1 — понимание текста",
        repo: "Qwen/Qwen3-VL-8B-Instruct-GGUF",
        commit: "f982a07559d4a2f6c8744d840bf6fccab30eea96",
        repoPath: "Qwen3VL-8B-Instruct-Q4_K_M.gguf",
        bytes: 5_027_784_800,
        sha: "67d1659bfe71b89d50b45a4ad1a9e5b997e5bb16ce5da66a6a6167abd569e9e2",
        license: "Apache 2.0")

    /// «Глаза» энкодера — нужны, только когда есть фото-образцы (режим правки).
    /// Качаем сразу вместе с остальным: приложение обещает работать без сети, и правка
    /// в самолёте не должна упереться в «сначала докачайте».
    public static let vision = part(
        id: "qwen3-vl-8b-mmproj-f16",
        name: "Qwen-Image 2.1 — зрение для правки фото",
        repo: "Qwen/Qwen3-VL-8B-Instruct-GGUF",
        commit: "f982a07559d4a2f6c8744d840bf6fccab30eea96",
        repoPath: "mmproj-Qwen3VL-8B-Instruct-F16.gguf",
        bytes: 1_159_029_824,
        sha: "ca524100ebf825c9a870db1c580d03879e0da0ab2541697e2458e64891cf9d38",
        license: "Apache 2.0")

    /// Декодер картинки (VAE) — от Comfy-Org, ссылку на него даёт документация движка.
    /// ⚠️ Прежние VAE (Qwen-Image, Wan 2.2) к 2.1 НЕ подходят — это прямо сказано там же.
    public static let vae = part(
        id: "qwen-image-2-1-vae-bf16",
        name: "Qwen-Image 2.1 — проявка картинки",
        repo: "Comfy-Org/Qwen-Image-2.1",
        commit: "9a44dbdb47cefd046be9c0a13476192f34c8db8e",
        repoPath: "vae/qwen_image_2.1_vae_bf16.safetensors",
        bytes: 675_509_688,
        sha: "bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9",
        license: researchLicense)

    // MARK: Любое семейство из реестра (ImageModelFamily.swift)
    //
    // ⚠️ Раньше здесь было всё только про Qwen-Image. Теперь набор выбирает человек
    //, и каждое действие спрашивает, О КАКОМ семействе речь.

    /// Что обязано лежать на телефоне, чтобы рисовать: общий набор + рисующая часть.
    ///
    /// ⚠️ Уже лежит любая рисующая часть семейства (например, прежняя лёгкая Q3_K,
    /// до смены лёгкой на Q4_0 24.09.2026) — новую лёгкую НЕ требуем: рисовать уже
    /// можно, а 4 ГБ без спроса человек не заказывал.
    ///
    /// ⚠️ То же с турбо (24.09.2026): у кого обычная Qwen-Image уже стоит, тот может
    /// рисовать и без турбо — 4 ГБ ему предлагаются отдельной кнопкой, а не ставятся
    /// условием «докачайте, иначе не нарисуете».
    public static func requiredParts(_ family: ImageModelFamily, precise: Bool) -> [ModelDescriptor] {
        var parts = family.baseParts
        let main = family.defaultDiffusion
        let anyDrawing = (family.diffusionChoices + (family.turbo.map { [$0.diffusion] } ?? []))
            .contains(where: isReady)
        // Рисовать уже есть чем (турбо v0.1 или обычная) — ни обычную, ни дополнение v0.2.1
        // условием не ставим: они предлагаются кнопкой «Качество лучше».
        if anyDrawing {
            let optional = [main.id] + (family.turboLoRA.map { [$0.lora.id] } ?? [])
            parts.removeAll { optional.contains($0.id) && !isReady($0) }
        }
        if precise, let p = family.diffusionPrecise { parts.append(p) }
        return parts
    }

    /// Какой рисующей частью рисовать: выбранной вручную → обычной (лёгкой / точной
    /// в «Максимуме») → любой скачанной. nil — ни одной на телефоне.
    public static func diffusionToUse(_ family: ImageModelFamily, precise: Bool,
                                      overrideID: String?) -> ModelDescriptor? {
        if let id = overrideID, let chosen = family.diffusionChoices.first(where: { $0.id == id }),
           isReady(chosen) {
            return chosen
        }
        if precise, let p = family.diffusionPrecise, isReady(p) { return p }
        if isReady(family.diffusionLight) { return family.diffusionLight }
        return family.diffusionChoices.first(where: isReady)
    }

    /// Рисовать ли турбо v0.2.1 (дополнение поверх обычной). Для своих уровней, если
    /// дополнение и обычная рисующая часть на телефоне. Иначе — `turboToUse` (v0.1).
    /// Ручной выбор формата («Для замера скорости») здесь выбирает обычную под дополнением.
    public static func turboLoRAToUse(_ family: ImageModelFamily, level: ImagePresetLevel,
                                      overrideID: String?) -> ImageTurboLoRA? {
        guard let t = family.turboLoRA, t.levels.contains(level), isReady(t.lora),
              diffusionToUse(family, precise: false, overrideID: overrideID) != nil else { return nil }
        return t
    }

    /// Сколько докачать ради турбо v0.2.1: дополнение и, если её нет, обычная лёгкая.
    public static func turboLoRAParts(_ family: ImageModelFamily) -> [ModelDescriptor] {
        guard let t = family.turboLoRA else { return [] }
        let base = diffusionToUse(family, precise: false, overrideID: nil) == nil ? [family.diffusionLight] : []
        return ([t.lora] + base).filter { !isReady($0) }
    }

    /// Рисовать ли турбо-версией. nil — обычной моделью.
    ///
    /// Турбо — для своих уровней («Быстро», «Нормально»), если скачана. «Максимум» —
    /// обычная модель; турбо там только когда обычной на телефоне нет вовсе (новая
    /// установка без дополнения): лучше нарисовать турбо, чем отказать.
    /// ⚠️ Ручной выбор формата («Для замера скорости») касается ТОЛЬКО обычной модели:
    /// иначе однажды выбранная для замера Q3_K молча отняла бы у человека турбо.
    public static func turboToUse(_ family: ImageModelFamily, level: ImagePresetLevel,
                                  precise: Bool, overrideID: String?) -> ImageTurbo? {
        guard let t = family.turbo, isReady(t.diffusion) else { return nil }
        if t.levels.contains(level) { return t }
        return diffusionToUse(family, precise: precise, overrideID: overrideID) == nil ? t : nil
    }

    /// Что отдать турбо вместо короткого описания.
    ///
    /// Турбо v0.1 на голое слово «Космос» рисовала что попало (на телефоне — орла в горах,
    /// на мини — облачное небо с луной и птицу): одно слово с большой буквы для неё —
    /// скорее имя или название, а не просьба; обычная модель на то же слово рисует
    /// туманность. Та же просьба, оформленная как описание — «Картинка: космос.», —
    /// даёт туманность при обоих проверенных зёрнах, а на ясных коротких просьбах
    /// («Кот», «Город ночью») картинка почти не меняется.
    /// Поэтому оборачиваем только короткое (до 4 слов) и только для рисования с нуля:
    /// в правке по образцу текст — указание, его не трогаем. Длинное описание — как есть.
    public static func turboPrompt(_ prompt: String, hasReferences: Bool) -> String {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hasReferences, !text.isEmpty else { return prompt }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words <= 4 else { return prompt }
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let end = text.last.map { ".!?…".contains($0) } == true ? "" : "."
        return (cyrillic ? "Картинка: " : "Image: ") + text + end
    }

    /// Сколько качать для набора, в байтах (только то, чего ещё нет).
    public static func missingBytes(_ family: ImageModelFamily, precise: Bool) -> Int64 {
        requiredParts(family, precise: precise)
            .filter { !isReady($0) }
            .reduce(0) { $0 + $1.byteSize }
    }

    /// Можно ли рисовать этим семейством (лёгкий набор на месте).
    public static func isInstalled(_ family: ImageModelFamily) -> Bool {
        requiredParts(family, precise: false).allSatisfy(isReady)
    }

    /// Лежит ли файл целиком (по размеру; сумма сверяется при загрузке).
    public static func isReady(_ part: ModelDescriptor) -> Bool {
        // Дополнение v0.2.1 после слияния живёт слитым файлом, оригинал стёрт (`preparedLoRA`).
        if let t = turboLoRAs.first(where: { $0.lora.id == part.id }), let f = fusedURL(t),
           FileManager.default.fileExists(atPath: f.path) { return true }
        guard let url = try? ModelStorage.fileURL(for: part) else { return false }
        return ModelStorage.byteSize(of: url) == part.byteSize
    }

    public static func url(of part: ModelDescriptor) -> URL? {
        guard isReady(part) else { return nil }
        return try? ModelStorage.fileURL(for: part)
    }

    /// Папку создаём заранее: загрузчик кладёт готовый файл по пути с подпапкой
    /// и сам её не создаёт (для частей модели Apple её тоже создают заранее).
    ///
    /// ⚠️ Папок может быть больше одной: FLUX.3 klein берёт проявку из папки FLUX.2 klein
    /// (общий файл,). Без этой папки загрузка общей части упала бы на последнем шаге.
    public static func ensureFolder(_ family: ImageModelFamily) throws {
        let root = try ModelStorage.modelsDirectory()
        let folders = Set([family.folderName] + family.allParts.compactMap { part -> String? in
            let dir = (part.fileName as NSString).deletingLastPathComponent
            return dir.isEmpty ? nil : dir
        })
        for folder in folders {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    /// Нужна ли часть ДРУГОМУ семейству, которое стоит на телефоне (у него есть
    /// хоть одна своя, не общая часть). Такую часть стирание этого семейства не трогает
    /// и в «освободится» не считает: иначе удаление FLUX.3 молча ломало бы FLUX.2 klein.
    static func neededElsewhere(_ part: ModelDescriptor, besides family: ImageModelFamily) -> Bool {
        let mine = Set(family.allParts.map(\.id))
        return ImageModelRegistry.all.contains { other in
            other.id != family.id
                && other.allParts.contains { $0.id == part.id }
                && other.allParts.contains { !mine.contains($0.id) && isReady($0) }
        }
    }

    /// Всего занято на диске файлами этого семейства.
    public static func occupiedBytes(_ family: ImageModelFamily) -> Int64 {
        (family.allParts.filter { !neededElsewhere($0, besides: family) }
            .compactMap { try? ModelStorage.fileURL(for: $0) }
         + (family.turboLoRA.flatMap(fusedURL).map { [$0] } ?? []))
            .reduce(0) { $0 + ModelStorage.byteSize(of: $1) }
    }

    /// Стереть семейство целиком (и недокачанное тоже).
    ///
    /// ⚠️ `ModelDownloader.cancelAndDiscard` здесь НЕ зовём: он гасит ВСЕ загрузки
    /// приложения, в том числе чат-модель, которая могла качаться рядом. Вызывающий
    /// обязан не пускать сюда, пока наша загрузка идёт (экран так и делает).
    public static func deleteAll(_ family: ImageModelFamily) {
        // Открытая модель держит файлы отображёнными в память: стёртый файл не освободил
        // бы место, пока контекст жив. Закрываем до удаления.
        ImageGenEngine.shared.releaseContext(reason: "файлы модели удаляются")
        for p in family.allParts where !neededElsewhere(p, besides: family) {
            ModelDownloadPlanStore.clear(modelID: p.id)
            try? ModelStorage.removeDownloadedModel(p)
        }
        if let f = family.turboLoRA.flatMap(fusedURL) { try? FileManager.default.removeItem(at: f) }
    }

    private static func part(id: String, name: String, repo: String, commit: String,
                             repoPath: String, bytes: Int64, sha: String,
                             license: String) -> ModelDescriptor {
        let fileName = (repoPath as NSString).lastPathComponent
        return ModelDescriptor(
            id: id,
            displayName: name,
            repoID: repo,
            repoCommit: commit,
            fileName: "\(folderName)/\(fileName)",
            byteSize: bytes,
            sha256: sha,
            summary: "Часть модели картинок Qwen-Image 2.1.",
            isForPhone: true,
            license: license,
            repoPath: repoPath)
    }
}
