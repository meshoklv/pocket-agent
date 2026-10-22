//
//  ImageModelFamily.swift
//  PocketAgent / Runtime
//
//  Реестр семейств моделей картинок: из каких частей состоит модель, откуда их брать,
//  с какими настройками рисовать и как узнать семейство по находке в поиске.
// (дополнение владельца: «не только Qwen-Image»).
//
//  ⚠️ ЧТО УМЕЕТ ДВИЖОК — СВЕРЕНО ПО ЕГО ДОКУМЕНТАЦИИ НА НАШЕМ КОММИТЕ 88411ef
//,
//  23.09.2026. В реестр вошли три набора, у которых все части лежат в ОТКРЫТЫХ
//  репозиториях (без согласия с условиями на сайте — приложение так качать не умеет):
//    • Qwen-Image 2.1 — был и раньше;
//    • Z-Image-Turbo — лёгкая и быстрая (8 шагов), без правки фото;
//    • FLUX.2 klein 4B — самая лёгкая (4 шага), умеет правку по образцу.
//    • FLUX.3 klein — добавлена 16.10.2026.
//  FLUX.1 schnell движок тоже умеет, но ему нужны clip_l + t5xxl (ещё ~5 ГБ,
//  четвёртая часть) — отложено. SDXL/SD1.5 — отдельный путь (один файл-чекпойнт),
//  тоже отложено: записано в.
//
//  ⚠️ ВСЕ РАЗМЕРЫ, СУММЫ И ВЕРСИИ СНЯТЫ ЗАПРОСОМ К API HUGGING FACE
//  (`/api/models/<репо>?blobs=true`) 23.09.2026. Править «по памяти» нельзя.
//  Наличие каждого файла на зеркале ModelScope проверено живым запросом куска
//  в тот же день — значит общий загрузчик сам выберет быстрый источник.
//
//  ⚠️ НАСТРОЙКИ РИСОВАНИЯ (шаги, CFG) ВЗЯТЫ ИЗ ПРИМЕРОВ В ДОКУМЕНТАЦИИ ДВИЖКА,
//  а не подобраны на телефоне. Скорость и качество на iPhone владельца НЕ МЕРИЛИ.
//

import Foundation

/// Уровень «Быстро / Нормально / Максимум». У каждого семейства свои числа.
public enum ImagePresetLevel: String, CaseIterable, Sendable {
    case fast, normal, max
}

/// Что значит уровень для конкретной модели.
public struct ImagePreset: Sendable, Equatable {
    /// Шаги рисования.
    public let steps: Int
    /// Сторона квадрата той же площади. Другие пропорции берут ту же площадь.
    public let baseSide: Int
}

/// Пропуск похожих шагов рисования.
/// Ставится семейству, только если замер показал выигрыш без потери качества.
public struct ImageStepCache: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case easyCache, spectrum }
    public let mode: Mode
    /// nil — порог по умолчанию движка.
    public let threshold: Float?
}

/// Турбо-версия рисующей части: та же модель, «дистиллированная» на несколько шагов
/// и без силы следования описанию (CFG 1)..
///
/// ⚠️ CFG 1 — это не «слабее следует описанию», а ПОЛОВИНА работы: движок при CFG 1
/// не считает второй, «пустой» проход на каждом шаге (проверено по исходнику
/// stable-diffusion.cpp на нашем коммите 88411ef: `request.cpp`, `resolve_guidance` —
/// безусловный проход включается, только когда txt_cfg ≠ img_cfg, а img_cfg по
/// умолчанию 1). У обычной Qwen-Image с CFG 6 каждый шаг — два прохода.
public struct ImageTurbo: Sendable, Equatable {
    /// Рисующая часть турбо-версии (свой файл; энкодер и проявка — общие с семейством).
    public let diffusion: ModelDescriptor
    /// Шаги рисования — те, на которые модель дистиллирована.
    public let steps: Int
    /// Сила следования описанию. У дистиллированных — 1.
    public let cfg: Float
    /// Для каких уровней турбо идёт вместо обычной модели.
    public let levels: Set<ImagePresetLevel>
}

/// Турбо на дополнении-LoRA поверх ОБЫЧНОЙ рисующей части.
///
/// ⚠️ Только поверх обычной модели: Viggle прямо пишет «never stack two students» —
/// LoRA на турбо-файл v0.1 давала бы двойную дистилляцию. Поэтому рисует лёгкая Q4_0
/// (или та, что стоит) + это дополнение, 6 шагов на своём расписании, CFG 1.
public struct ImageTurboLoRA: Sendable, Equatable {
    /// Файл дополнения, как его выложила Viggle (качается общим загрузчиком, сумма — его).
    public let lora: ModelDescriptor
    /// Имя слитого файла рядом — его и читает движок (`LoRAFuse`). Оригинал после слияния стирается.
    public let fusedFileName: String
    /// «Сырые» узлы расписания с карточки Viggle, до сдвига по размеру картинки.
    public let nodes: [Float]
    public let levels: Set<ImagePresetLevel>
    public var steps: Int { nodes.count }
    public var cfg: Float { 1.0 }

    /// Расписание шума для размера картинки: узлы Viggle со сдвигом по числу точек
    /// (как их пайплайн и узел ComfyUI: mu = 0,5…0,9 на 256…8192 точек латента 1/16,
    /// экспоненциальный сдвиг), в конце 0. Движок `--sigmas` берёт как есть, без сдвига
    /// (исходник 88411ef, `request.cpp`), поэтому сдвигаем сами.
    public func sigmas(width: Int, height: Int) -> [Float] {
        let tokens = Double((width / 16) * (height / 16))
        let e = Foundation.exp(0.5 + (0.9 - 0.5) * (tokens - 256) / (8192 - 256))
        return nodes.map { Float(e / (e + (1 / Double($0) - 1))) } + [0]
    }
}

/// Одно семейство моделей картинок и его готовый набор файлов.
public struct ImageModelFamily: Sendable, Identifiable, Equatable {

    public let id: String
    /// Имя для человека: «Z-Image-Turbo».
    public let displayName: String
    /// Одна строка «чем хороша» — для выбора модели.
    public let tagline: String
    /// Подпапка в хранилище моделей. ⚠️ У каждого семейства своя: одинаковые имена
    /// файлов у разных семейств (ae.safetensors) не должны затирать друг друга.
    public let folderName: String

    /// Рисующая часть: лёгкая — ставится всегда.
    public let diffusionLight: ModelDescriptor
    /// Рисующая часть поточнее — дополнение для «Максимума». nil — не бывает.
    public let diffusionPrecise: ModelDescriptor?
    /// Понимание текста (языковая модель).
    public let textEncoder: ModelDescriptor
    /// Проявка картинки (VAE).
    public let vae: ModelDescriptor
    /// «Глаза» языковой модели — нужны только Qwen-Image для правки фото.
    public let vision: ModelDescriptor?

    /// Умеет ли правку по фото-образцам. Нет — экран образцы не показывает вовсе.
    public let supportsReferences: Bool
    /// Сила следования описанию. У «дистиллированных» моделей — 1.
    public let cfg: Float
    /// Особые настройки движка (строка `model_args`). nil — не нужны.
    public let modelArgs: String?

    public let fast: ImagePreset
    public let normal: ImagePreset
    public let max: ImagePreset

    /// По каким словам в имени репозитория или файла узнаём семейство в поиске.
    /// Сравнение без регистра, «-», «_», «.» и пробелов («Qwen-Image-2.1» = «qwenimage21»).
    public let nameKeys: [String]

    public let license: String

    /// Слова, при которых находка — НЕ это семейство, хоть ключ и совпал
    /// («flux3imagekleinbase» содержит «flux3imageklein», а настройки у неё другие).
    public var nameExcludes: [String] = []

    /// Другие форматы рисующей части — для сравнения скорости на телефоне.
    /// Человек выбирает их в «…» → «Веса рисующей части»; сами не качаются.
    public var diffusionVariants: [ModelDescriptor] = []
    /// Кэш шагов. nil — каждый шаг считается полностью.
    /// ⚠️ К турбо-версии не применяется: при 4 шагах пропускать нечего, а пропуск
    /// шага у дистиллированной модели — это прямая потеря деталей.
    public var stepCache: ImageStepCache? = nil
    /// Турбо-версия. nil — у семейства её нет (или оно само турбо).
    public var turbo: ImageTurbo? = nil
    /// Турбо v0.2.1 — дополнение к обычной модели, качается кнопкой по желанию.
    /// ⚠️ В установку по умолчанию НЕ входит: честное сравнение с настоящей v0.1 на мини
    /// разницы «заметно лучше» не показало, а на телефоне это ~+30 с к картинке.
    public var turboLoRA: ImageTurboLoRA? = nil

    /// Рисующая часть, которая ставится по умолчанию: турбо, если есть, иначе лёгкая.
    public var defaultDiffusion: ModelDescriptor { turbo?.diffusion ?? diffusionLight }

    /// Все форматы рисующей части: лёгкий, точный, для сравнения.
    public var diffusionChoices: [ModelDescriptor] {
        [diffusionLight] + (diffusionPrecise.map { [$0] } ?? []) + diffusionVariants
    }

    public func preset(_ level: ImagePresetLevel) -> ImagePreset {
        switch level {
        case .fast: return fast
        case .normal: return normal
        case .max: return max
        }
    }

    /// Что обязано лежать на телефоне, чтобы рисовать.
    /// От мелких к крупным: оборвётся на большом — мелкие уже на месте.
    /// ⚠️ У Qwen-Image с турбо-версией обычная лёгкая сюда НЕ входит: «Быстро» и
    /// «Нормально» рисует турбо, а «Максимуму» нужна точная — её качают дополнением.
    public var baseParts: [ModelDescriptor] {
        ([vae] + (vision.map { [$0] } ?? []) + [defaultDiffusion, textEncoder])
            .sorted { $0.byteSize < $1.byteSize }
    }

    /// Все файлы семейства, какие вообще бывают на диске.
    public var allParts: [ModelDescriptor] {
        var seen = Set<String>()
        return (baseParts + diffusionChoices + (turbo.map { [$0.diffusion] } ?? [])
                + (turboLoRA.map { [$0.lora] } ?? []))
            .filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Реестр

public enum ImageModelRegistry {

    public static let qwenImage21 = ImageModelFamily(
        id: "qwen-image-2.1",
        displayName: "Qwen-Image 2.1",
        tagline: "Лучше всех пишет текст на картинке, правит фото. Тяжёлая.",
        folderName: ImageModelCatalog.folderName,
        diffusionLight: ImageModelCatalog.ditLight,
        diffusionPrecise: ImageModelCatalog.ditPrecise,
        textEncoder: ImageModelCatalog.encoder,
        vae: ImageModelCatalog.vae,
        vision: ImageModelCatalog.vision,
        supportsReferences: true,
        // CFG 6 — в документации движка и в примерах unsloth для Qwen-Image-2.1.
        cfg: 6.0,
        // ⚠️ Кэш префикса выключен: по документации движка он берёт ~4 ГиБ на каждое
        // условие ради скорости. Включать — только после замера на телефоне.
        modelArgs: "qwen_image_2_1_prefix_cache=false",
        fast: ImagePreset(steps: 12, baseSide: 512),
        normal: ImagePreset(steps: 20, baseSide: 768),
        max: ImagePreset(steps: 28, baseSide: 1024),
        nameKeys: ["qwenimage21"],
        license: "Qwen Research License — только некоммерческое использование",
        diffusionVariants: [ImageModelCatalog.ditQ3K, ImageModelCatalog.ditQ8_0],
        // Кэш шагов EasyCache: замер на мини 24.09.2026 — 12 шагов за 268 с вместо 454 с
        // (пропущено 5 из 12), картинка та же (отличие от обычной на уровне шума между
        // двумя видами внимания). Отвергнуты числом: Spectrum (306 с — медленнее),
        // DBCache (232 с, но двоится лицо).
        stepCache: ImageStepCache(mode: .easyCache, threshold: nil),
        turbo: ImageModelCatalog.turbo,
        turboLoRA: ImageModelCatalog.turboLoRA)

    // MARK: Z-Image-Turbo

    private static let zFolder = "ZImageTurbo"

    public static let zImageTurbo = ImageModelFamily(
        id: "z-image-turbo",
        displayName: "Z-Image-Turbo",
        tagline: "Быстрая: 8 шагов, фотографичная. Без правки фото.",
        folderName: zFolder,
        diffusionLight: part(
            id: "z-image-turbo-q3k", name: "Z-Image-Turbo — рисующая часть (лёгкая)",
            folder: zFolder, repo: "leejet/Z-Image-Turbo-GGUF",
            commit: "c61c0e422dc8b541b7548cf33a4ef8302b0f8085",
            path: "z_image_turbo-Q3_K.gguf", bytes: 3_143_559_104,
            sha: "4b44bdaa7814f20d7cf144e3939bd93aa32f50660204dd0c2aea5c5376232980",
            license: "Apache 2.0"),
        diffusionPrecise: part(
            id: "z-image-turbo-q4k", name: "Z-Image-Turbo — рисующая часть (точная)",
            folder: zFolder, repo: "leejet/Z-Image-Turbo-GGUF",
            commit: "c61c0e422dc8b541b7548cf33a4ef8302b0f8085",
            path: "z_image_turbo-Q4_K.gguf", bytes: 3_864_250_304,
            sha: "14b375ab4f226bc5378f68f37e899ef3c2242b8541e61e2bc1aff40976086fbd",
            license: "Apache 2.0"),
        // Энкодер — тот, что назван в примере движка: Qwen3-4B-Instruct-2507 Q4_K_M.
        textEncoder: part(
            id: "z-image-qwen3-4b-instruct-q4km", name: "Z-Image-Turbo — понимание текста",
            folder: zFolder, repo: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
            commit: "a06e946bb6b655725eafa393f4a9745d460374c9",
            path: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", bytes: 2_497_281_120,
            sha: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
            license: "Apache 2.0"),
        // ⚠️ VAE — тот же ae.safetensors, что у FLUX.1 (так в документации движка),
        // но из ОТКРЫТОГО репозитория Comfy-Org: у black-forest-labs/FLUX.1-schnell
        // стоит согласие с условиями (gated=auto). Сумма совпадает побайтово.
        vae: part(
            id: "z-image-vae-ae", name: "Z-Image-Turbo — проявка картинки",
            folder: zFolder, repo: "Comfy-Org/z_image_turbo",
            commit: "6fc90a3b1b653e935a0d175e260736de25b84df5",
            path: "split_files/vae/ae.safetensors", bytes: 335_304_388,
            sha: "afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38",
            license: "Apache 2.0"),
        vision: nil,
        supportsReferences: false,
        // Пример движка: --cfg-scale 1.0 --steps 8 (турбо-модель, дистиллирована).
        cfg: 1.0,
        modelArgs: nil,
        fast: ImagePreset(steps: 6, baseSide: 512),
        normal: ImagePreset(steps: 8, baseSide: 768),
        max: ImagePreset(steps: 9, baseSide: 1024),
        // ⚠️ Только «turbo»: базовая Z-Image — другая модель (CFG 5, ~50 шагов),
        // с нашими настройками она нарисует кашу.
        nameKeys: ["zimageturbo"],
        license: "Apache 2.0",
        // Для сравнения на телефоне; суммы из API HF 24.09.2026.
        diffusionVariants: [
            part(id: "z-image-turbo-q4-0", name: "Z-Image-Turbo — рисующая часть (Q4_0)",
                 folder: zFolder, repo: "leejet/Z-Image-Turbo-GGUF",
                 commit: "c61c0e422dc8b541b7548cf33a4ef8302b0f8085",
                 path: "z_image_turbo-Q4_0.gguf", bytes: 3_683_370_944,
                 sha: "2bc57986874c84f7ec6d02d9d7070a53b0029954a0e38a6e1342eb91095572f5",
                 license: "Apache 2.0"),
            part(id: "z-image-turbo-q8-0", name: "Z-Image-Turbo — рисующая часть (Q8_0)",
                 folder: zFolder, repo: "leejet/Z-Image-Turbo-GGUF",
                 commit: "c61c0e422dc8b541b7548cf33a4ef8302b0f8085",
                 path: "z_image_turbo-Q8_0.gguf", bytes: 6_577_440_704,
                 sha: "df1c5baa86d1398c979495a6072dbcee79444fdb884a2445582ba0769c44e9a1",
                 license: "Apache 2.0"),
        ])

    // MARK: FLUX.2 klein 4B

    private static let kleinFolder = "Flux2Klein4B"

    public static let flux2Klein4B = ImageModelFamily(
        id: "flux2-klein-4b",
        displayName: "FLUX.2 klein 4B",
        tagline: "Самая лёгкая: 4 шага. Правит фото по образцу.",
        folderName: kleinFolder,
        diffusionLight: part(
            id: "flux2-klein-4b-q4-0", name: "FLUX.2 klein — рисующая часть (лёгкая)",
            folder: kleinFolder, repo: "leejet/FLUX.2-klein-4B-GGUF",
            commit: "3b1f5a9dc3abb32238b053aeb3d823c30afdacbd",
            path: "flux-2-klein-4b-Q4_0.gguf", bytes: 2_460_378_560,
            sha: "d1023499ef3f2f82ff7c50e6778495195c1b6cc34835741778868428111f9ff4",
            license: "Apache 2.0"),
        diffusionPrecise: part(
            id: "flux2-klein-4b-q8-0", name: "FLUX.2 klein — рисующая часть (точная)",
            folder: kleinFolder, repo: "leejet/FLUX.2-klein-4B-GGUF",
            commit: "3b1f5a9dc3abb32238b053aeb3d823c30afdacbd",
            path: "flux-2-klein-4b-Q8_0.gguf", bytes: 4_300_629_440,
            sha: "0bba6951258ec8f92d51114a8fa13e66828297bfff58a738f52729b3ef66fa28",
            license: "Apache 2.0"),
        // Энкодер по документации движка — Qwen3 4B (базовый, не Instruct).
        textEncoder: part(
            id: "flux2-klein-qwen3-4b-q4km", name: "FLUX.2 klein — понимание текста",
            folder: kleinFolder, repo: "unsloth/Qwen3-4B-GGUF",
            commit: "22c9fc8a8c7700b76a1789366280a6a5a1ad1120",
            path: "Qwen3-4B-Q4_K_M.gguf", bytes: 2_497_281_312,
            sha: "f6f851777709861056efcdad3af01da38b31223a3ba26e61a4f8bf3a2195813a",
            license: "Apache 2.0"),
        // ⚠️ VAE FLUX.2 у black-forest-labs/FLUX.2-dev закрыт согласием (gated=auto).
        // Тот же файл побайтово (сумма совпала) лежит открыто у Comfy-Org.
        vae: part(
            id: "flux2-vae", name: "FLUX.2 klein — проявка картинки",
            folder: kleinFolder, repo: "Comfy-Org/flux2-klein-4B",
            commit: "5f526678002e43af5551dadb73ce2e8c91b43afe",
            path: "split_files/vae/flux2-vae.safetensors", bytes: 336_211_292,
            sha: "868fe7b343cc8f3a19dbcfcafbc3d5f888802be3f89bd81b65b3621a066ce8f3",
            license: "Apache 2.0"),
        vision: nil,
        // Пример движка: `-r kontext_input.png` — правка по образцу без отдельного зрения.
        supportsReferences: true,
        // Пример движка: --cfg-scale 1.0 --steps 4.
        cfg: 1.0,
        modelArgs: nil,
        fast: ImagePreset(steps: 4, baseSide: 512),
        normal: ImagePreset(steps: 4, baseSide: 768),
        max: ImagePreset(steps: 6, baseSide: 1024),
        // ⚠️ Только 4B и не «base»: у 9B другой энкодер (Qwen3 8B), у base — CFG 4
        // и 20 шагов. «flux2kleinbase4b» ключ «flux2klein4b» не содержит.
        nameKeys: ["flux2klein4b"],
        license: "Apache 2.0")

    // MARK: FLUX.3 Image Klein
    //
    // Новый Flux от Black Forest Labs (вышел 13.10.2026): 5,6B, «дистиллированная» версия
    // рисует за 16 шагов без второго прохода CFG. Движок умеет её с п.14 нашего форка
    // (перенос апстрима 8cd731e7b4, tools/mac/pa-vendor.sh, метка sdcpp-88411ef-v12).
    //
    // ⚠️ ЭНКОДЕР — НЕ ТОТ, ЧТО У FLUX.2 klein, хоть оба «Qwen3 4B». Сверено по исходнику
    // движка (conditioner.hpp): FLUX.2 klein — арх QWEN3 (текстовая Qwen3-4B, слои 9/18/27),
    // FLUX.3 — арх QWEN3_VL (Qwen3-VL-4B-Instruct, слои 4…32 и позиции mrope). Веса разные,
    // подсунуть файл FLUX.2 значит молча получить кашу. Поэтому — свой файл.
    // ⚠️ ПРОЯВКА (VAE) — ТА ЖЕ, ЧТО У FLUX.2 klein, побайтово: у black-forest-labs/flux-3-image-klein
    // ae.safetensors 336 211 292 байт, sha256 868fe7b3…ce8f3 — ровно наш flux2-vae.safetensors.
    // Берём тот же файл из той же папки: у кого стоит FLUX.2 klein, второй раз не качает.
    // Стирание одного семейства общий файл не трогает, пока он нужен другому (`ImageModelCatalog`).
    //
    // ⚠️ Рисующая часть — GGUF от Abiray (пересчёт 16-шаговой дистиллированной из
    // flux-3-image-klein-comfy). Сам репозиторий BFL закрыт согласием (gated=auto) —
    // приложение так качать не умеет. Имена тензоров в GGUF сверены по заголовку файла
    // (range-запрос 16.10.2026): emb_in.image, txt_mode_blocks.*, ref_time_in — ровно то,
    // по чему движок узнаёт FLUX.3 и включает «целевой шаг» дистиллированной.
    // Q4_K_M: 264 слоя в q4_K (наше ядро нейроблоков режима 4 его умеет), 7 — в bf16.
    // Размеры и суммы — из API HF (`?blobs=true`) 16.10.2026, коммиты закреплены.
    //
    // ⚠️ Шаги и CFG — из примера документации движка (16 шагов, CFG 1, euler), на телефоне
    // не подобраны. Скорость на iPhone владельца НЕ МЕРИЛИ.

    private static let flux3Folder = "Flux3Klein"

    public static let flux3Klein = ImageModelFamily(
        id: "flux3-image-klein",
        displayName: "FLUX.3 klein",
        tagline: "Новый Flux: 16 шагов, правит фото по образцу.",
        folderName: flux3Folder,
        diffusionLight: part(
            id: "flux3-klein-q4km", name: "FLUX.3 klein — рисующая часть (лёгкая)",
            folder: flux3Folder, repo: "Abiray/flux-3-image-klein-sd-GGUF",
            commit: "1960618efcfaeec728f22fd7f656a7034ee5f73b",
            path: "flux3_image_klein_sd_Q4_K_M.gguf", bytes: 3_269_858_080,
            sha: "c0dc60488f1d73517e60252d0d1ce24a8a9a19275ea669c0b96408a10fc871ac",
            license: flux3License),
        diffusionPrecise: part(
            id: "flux3-klein-q8-0", name: "FLUX.3 klein — рисующая часть (точная)",
            folder: flux3Folder, repo: "Abiray/flux-3-image-klein-sd-GGUF",
            commit: "1960618efcfaeec728f22fd7f656a7034ee5f73b",
            path: "flux3_image_klein_sd_Q8_0.gguf", bytes: 5_991_748_384,
            sha: "b4daf9ac8e103207830f7b2d310ba9b074c05a35719b5af20698006c32c22638",
            license: flux3License),
        // Энкодер по документации движка — Qwen3-VL 4B (официальный GGUF от Qwen).
        textEncoder: part(
            id: "flux3-qwen3-vl-4b-q4km", name: "FLUX.3 klein — понимание текста",
            folder: flux3Folder, repo: "Qwen/Qwen3-VL-4B-Instruct-GGUF",
            commit: "1cd86afb9a95c410a6038ab3b40d8b578c892266",
            path: "Qwen3VL-4B-Instruct-Q4_K_M.gguf", bytes: 2_497_281_664,
            sha: "66358cb18bb6b3b1b6675aa412c7a88ef01d228f481184d13668e5201c730a0a",
            license: "Apache 2.0"),
        vae: flux2Klein4B.vae,
        vision: nil,
        // Пример движка: `-r …png` — правка по образцу (до 10 образцов) без отдельного зрения.
        supportsReferences: true,
        // Пример движка: --cfg-scale 1.0 --steps 16 --sampling-method euler.
        cfg: 1.0,
        modelArgs: nil,
        fast: ImagePreset(steps: 16, baseSide: 512),
        normal: ImagePreset(steps: 16, baseSide: 768),
        max: ImagePreset(steps: 16, baseSide: 1024),
        // ⚠️ Только дистиллированная: у Klein Base CFG 3,5 и 20+ шагов — с нашими
        // настройками она нарисует кашу. «flux3imagekleinbase» отсекаем явно.
        nameKeys: ["flux3imageklein", "flux3klein"],
        license: flux3License,
        nameExcludes: ["kleinbase"])

    // Условия самой лицензии за согласием на сайте BFL — мы их не читали; имя — из карточки HF.
    private static let flux3License = "FLUX Kommunity License"

    /// Все готовые наборы — в том порядке, в каком их видит человек.
    public static let all: [ImageModelFamily] = [qwenImage21, zImageTurbo, flux2Klein4B, flux3Klein]

    public static func family(id: String) -> ImageModelFamily? {
        all.first { $0.id == id }
    }

    // MARK: Узнать семейство по находке в поиске

    /// Что поиск понял про репозиторий.
    public enum Recognition: Equatable, Sendable {
        /// Наше семейство — ставится в «Картинках».
        case family(String)
        /// Модель для картинок, но такой движок у нас не умеет.
        case unsupportedImage
    }

    /// Узнать семейство по имени репозитория и файлов, признаку справочника
    /// («text-to-image») и, если есть, по `general.architecture` из заголовка GGUF.
    ///
    /// ⚠️ ИМЯ ГЛАВНЕЕ ЗАГОЛОВКА. Проверено 23.09.2026: файлы leejet (автора движка)
    /// выходят БЕЗ единой записи в заголовке — `general.architecture` там нет вовсе,
    /// а у city96/unsloth есть, но одна на все версии Qwen-Image («qwen_image»),
    /// то есть 2.1 от прежней по нему не отличить.
    ///
    /// nil — это не модель картинок, поиск показывает её как обычно.
    public static func recognize(repoID: String,
                                 fileNames: [String] = [],
                                 pipelineTag: String? = nil,
                                 ggufArchitecture: String? = nil) -> Recognition? {
        let haystack = ([repoID] + fileNames).map(squash)
        for family in all {
            if family.nameKeys.contains(where: { key in haystack.contains { $0.contains(key) } }),
               !family.nameExcludes.contains(where: { ex in haystack.contains { $0.contains(ex) } }) {
                return .family(family.id)
            }
        }
        let imageTags: Set<String> = ["text-to-image", "image-to-image", "image-text-to-image"]
        let imageArchitectures: Set<String> = ["qwen_image", "flux", "sd3", "sdxl", "sd1",
                                               "lumina2", "hidream", "chroma", "wan"]
        let looksLikeImage = (pipelineTag.map { imageTags.contains($0) } ?? false)
            || (ggufArchitecture.map { imageArchitectures.contains($0.lowercased()) } ?? false)
            || haystack.contains { key in
                ["qwenimage", "stablediffusion", "sdxl", "flux1", "flux2", "flux3", "hidream"]
                    .contains { key.contains($0) }
            }
        return looksLikeImage ? .unsupportedImage : nil
    }

    /// «Qwen-Image_2.1 GGUF» → «qwenimage21gguf».
    static func squash(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func part(id: String, name: String, folder: String, repo: String,
                             commit: String, path: String, bytes: Int64, sha: String,
                             license: String) -> ModelDescriptor {
        ModelDescriptor(
            id: id,
            displayName: name,
            repoID: repo,
            repoCommit: commit,
            fileName: "\(folder)/\((path as NSString).lastPathComponent)",
            byteSize: bytes,
            sha256: sha,
            summary: "Часть модели картинок.",
            isForPhone: true,
            license: license,
            repoPath: path)
    }
}
