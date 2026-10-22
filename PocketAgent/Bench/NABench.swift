//
//  NABench.swift
//  PocketAgent / Bench
//
//  МИКРОЗАМЕР МАТРИЧНЫХ БЛОКОВ A19 (Neural Accelerators) НА ТЕЛЕФОНЕ.
// Ядра K0–K6. Ядра — NABench.metal.
//
//  ЗАЧЕМ. Умножения — 74 % блока рисующей части, и идут они на ~3,3 трлн оп/с, то есть
//  на уровне обычного пути (simdgroup_matrix). Прежде чем чинить ядро в ggml, надо
//  ОДНОЗНАЧНО знать, что блоки вообще доступны нашей сборке и сколько они дают на наших
//  размерах. Статьи и чужие замеры на это не отвечают (см. CLAUDE.md про чужие цифры):
//  отвечает только число с его телефона.
//
//  ЧТО МЕРЯЕТ (группы в журнале и в na-results.json — поле `k`):
//    K0 — потолок обычного пути: simdgroup 8×8 в регистрах (na_k0_simd) + классический
//         GEMM на наших формах (na_simd_*), это база для сравнения;
//    K1 — пик блоков FP16 по tzakharko: маленькие тензоры в кэше, iters одинаковых run;
//    K2 — то же int8×int8→int32. K2 ≈ 2×K1 — единственная однозначная «подпись» блоков;
//    K3 — какие сочетания идут на блоки: bf16, half×float, float×float, half→half,
//         execution_simdgroups<4> на 64×64;
//    K4 — кооперативная mma MLX 16×32×16 в регистрах (путь нашего ядра N без памяти);
//    K5 — плотный GEMM 4096³ всеми вариантами (MPP с операндами в памяти / в общей памяти
//         группы / схема MLX в регистрах);
//    K6 — наши формы (M = 4096/12288, K = 4096/12288, N = 1024/1054): half-веса против
//         развёртки q4a (MLX affine), q4_0, q8_0, q4_K — цена развёртки и общей памяти.
//  Каждое ядро сверяется с процессором (по checkPoints случайных точек); ошибочное ядро
//  в «лучшие» не попадает, а в таблице помечено.
//
//  КАК ЗАПУСКАТЬ. Через удалённый замер картинок: план с полем "naBench" —
//  `tools/bench/image-plans/na-bench.json`:
//
//      bash tools/phone-image-bench.sh run tools/bench/image-plans/na-bench.json
//
//  Итоги — в ImageGen/bench-out/<имя>/: na-bench.log (журнал), na-results.jsonl (строка
//  на замер, по ходу), na-results.json (всё целиком + сводка), DONE (последним).
//
//  ОТКУДА БИБЛИОТЕКА ЯДЕР. "offline" — NABench.metallib, собранный шагом сборки Xcode
//  с `-std=metal4.0` (project.yml). "src4.1" / "src4.0" — тот же текст (NABench.metal
//  лежит в приложении), собранный на самом телефоне с явным языком 4.1 / 4.0: тест
//  просит проверить, что выбор языка не выключает блоки. Пиковые ядра гоняются на
//  каждой библиотеке, GEMM — на одной (`gemmLibrary`).
//
//  ⚠️ Только отладочная сборка, как и весь остальной замер.
//

#if DEBUG

import Foundation
import Metal

// MARK: - Настройки из плана

struct NABenchConfig: Decodable {
    /// Формы GEMM: [M, K, N] — строки весов, глубина, токены.
    var shapes: [[Int]]?
    /// Оставить только ядра, в имени которых есть любая из подстрок.
    var only: [String]?
    /// Выкинуть ядра, в имени которых есть любая из подстрок.
    var skip: [String]?
    /// "peak" (K0–K4) и/или "gemm" (K0-GEMM, K5, K6). По умолчанию оба.
    var groups: [String]?
    /// Какие библиотеки собрать: "offline", "src4.1", "src4.0".
    var libraries: [String]?
    /// На какой библиотеке гонять GEMM (по умолчанию первая собравшаяся).
    var gemmLibrary: String?
    var warmup: Int?
    /// Сколько замеров на ядро (берём медиану и лучший).
    var samples: Int?
    /// Сколько работы видеочипа в одном замере, мс (повторы подбираются под это).
    var targetMs: Double?
    /// Пауза между ядрами, с (по умолчанию 2).
    var pauseSeconds: Double?
    /// Сколько точек результата сверять с процессором.
    var checkPoints: Int?
    var peakGroups: Int?
    var peakIters: Int?
    /// Ждать «нормально» по нагреву перед каждой формой и перед пиками.
    var coolDown: Bool?
    var coolDownTimeoutSeconds: Double?
}

// MARK: - Описание ядер (имена ⇄ макросы NABench.metal)

enum NAType: String {
    case half, bf16, float, int8, int32
    var size: Int {
        switch self {
        case .half, .bf16: return 2
        case .float, .int32: return 4
        case .int8: return 1
        }
    }
}

/// Формат весов для путей с развёрткой (номер = WF в NABench.metal).
enum NAWeights: String {
    case f16, q4a, q40, q80, q4k
    /// Значений в блоке и байт в блоке — как na_wf<WF> в NABench.metal.
    var qk: Int { switch self { case .f16: 16; case .q4a: 64; case .q40, .q80: 32; case .q4k: 256 } }
    var blockBytes: Int { switch self { case .f16: 32; case .q4a: 36; case .q40: 18; case .q80: 34; case .q4k: 144 } }
    func rowBytes(_ k: Int) -> Int { k / qk * blockBytes }
    var fillKernel: String? { self == .f16 ? nil : "na_fill_\(rawValue)" }
}

struct NAKernel {
    enum Kind { case k0peak, peak, k4, gemm }
    let name: String
    let kind: Kind
    /// Для пиков — K0…K4 сразу; для GEMM — "G" (K0/K5/K6 решает форма и путь).
    let k: String
    /// simd · dev (MPP, операнды из памяти) · tg (MPP, через общую память) · reg (схема MLX)
    let path: String
    let a: NAType
    let b: NAType
    let c: NAType
    /// Для путей с развёрткой — формат весов; иначе nil (веса того же типа, что X).
    let weights: NAWeights?
    let bt: Int, bw: Int, bk: Int
    /// 0 — execution_simdgroup; ≥1 — execution_simdgroups<N>; -1 — не MPP.
    let nsg: Int
    let threads: Int
    let note: String

    var tile: String { "\(bt)x\(bw)x\(bk)" }
    var weightsLabel: String { weights?.rawValue ?? b.rawValue }
}

enum NABenchKernels {

    static func mppThreads(_ nsg: Int) -> Int { nsg == 0 ? 32 : nsg * 32 }

    static func typeCode(_ a: NAType, _ b: NAType, _ c: NAType) -> String {
        switch (a, b, c) {
        case (.half, .half, .float): return "hf"
        case (.half, .half, .half): return "hh"
        case (.bf16, .bf16, .float): return "bf"
        case (.half, .float, .float): return "hF"
        case (.float, .float, .float): return "ff"
        case (.int8, .int8, .int32): return "i8"
        default: return "??"
        }
    }

    static var all: [NAKernel] {
        var list: [NAKernel] = []

        // K0: потолок обычного пути
        list.append(NAKernel(name: "na_k0_simd", kind: .k0peak, k: "K0", path: "simd", a: .half, b: .half,
                             c: .float, weights: nil, bt: 8, bw: 8, bk: 8, nsg: -1, threads: 128,
                             note: "simdgroup 8×8 в регистрах"))

        // K1–K3: пики matmul2d
        let peaks: [(String, NAType, NAType, NAType, Int, Int, Int, Int, String)] = [
            ("K1", .half, .half, .float, 16, 32, 16, 0, "одна SIMD-группа, форма блока"),
            ("K1", .half, .half, .float, 32, 32, 16, 1, ""),
            ("K1", .half, .half, .float, 32, 32, 32, 1, ""),
            ("K1", .half, .half, .float, 32, 32, 64, 1, ""),
            ("K1", .half, .half, .float, 32, 32, 32, 0, "execution_simdgroup"),
            ("K2", .int8, .int8, .int32, 32, 32, 32, 1, ""),
            ("K2", .int8, .int8, .int32, 32, 32, 64, 1, ""),
            ("K2", .int8, .int8, .int32, 32, 32, 32, 0, "execution_simdgroup"),
            ("K3", .bf16, .bf16, .float, 32, 32, 32, 1, "bf16"),
            ("K3", .half, .float, .float, 32, 32, 32, 1, "half×float"),
            ("K3", .float, .float, .float, 32, 32, 32, 1, "float×float (блоки не должны)"),
            ("K3", .half, .half, .half, 32, 32, 32, 1, "half→half"),
            ("K3", .half, .half, .float, 64, 64, 32, 4, "simdgroups<4>"),
        ]
        for (k, a, b, c, m, n, kk, nsg, note) in peaks {
            list.append(NAKernel(name: "na_peak_\(typeCode(a, b, c))_\(m)x\(n)x\(kk)_s\(nsg)", kind: .peak, k: k,
                                 path: "peak", a: a, b: b, c: c, weights: nil, bt: m, bw: n, bk: kk, nsg: nsg,
                                 threads: mppThreads(nsg), note: note))
        }

        // K4: кооперативная mma MLX в регистрах
        list.append(NAKernel(name: "na_k4_hf", kind: .k4, k: "K4", path: "reg", a: .half, b: .half, c: .float,
                             weights: nil, bt: 16, bw: 32, bk: 16, nsg: 0, threads: 128, note: "mma MLX, регистры"))
        list.append(NAKernel(name: "na_k4_i8", kind: .k4, k: "K4", path: "reg", a: .int8, b: .int8, c: .int32,
                             weights: nil, bt: 16, bw: 32, bk: 16, nsg: 0, threads: 128, note: "mma MLX int8, регистры"))

        // GEMM: классика
        for (bt, bw, wt, ww) in [(64, 64, 2, 2), (128, 64, 4, 2), (128, 128, 4, 4)] {
            list.append(NAKernel(name: "na_simd_\(bt)x\(bw)", kind: .gemm, k: "G", path: "simd", a: .half, b: .half,
                                 c: .float, weights: nil, bt: bt, bw: bw, bk: 32, nsg: -1, threads: wt * ww * 32,
                                 note: "обычный путь"))
        }
        for w in [NAWeights.q4a, .q40, .q80, .q4k] {
            list.append(NAKernel(name: "na_simd_\(w.rawValue)_64x64", kind: .gemm, k: "G", path: "simd", a: .half,
                                 b: .half, c: .float, weights: w, bt: 64, bw: 64, bk: 32, nsg: -1, threads: 128,
                                 note: "обычный путь с развёрткой (ggml без тензоров)"))
        }

        // GEMM: MPP, операнды из памяти устройства
        let dev: [(NAType, NAType, Int, Int, Int, Int, Bool)] = [
            (.half, .float, 16, 32, 16, 0, true), (.half, .float, 32, 32, 32, 0, true),
            (.half, .float, 32, 32, 32, 1, true), (.half, .float, 32, 64, 32, 0, true),
            (.half, .float, 64, 32, 0, 4, true), (.half, .float, 64, 64, 32, 1, true),
            (.half, .float, 64, 64, 32, 2, true), (.half, .float, 64, 64, 32, 4, true),
            (.half, .float, 64, 64, 64, 4, true), (.half, .float, 64, 64, 0, 4, true),
            (.half, .float, 128, 64, 32, 4, true), (.half, .float, 128, 64, 0, 4, true),
            (.half, .float, 64, 128, 0, 4, true), (.half, .float, 256, 64, 0, 8, true),
            (.half, .float, 64, 256, 0, 8, true), (.half, .float, 128, 128, 32, 4, true),
            (.half, .float, 128, 128, 0, 4, true), (.half, .float, 128, 128, 32, 8, true),
            (.half, .float, 128, 128, 64, 16, true), (.half, .float, 64, 64, 32, 4, false),
            (.half, .half, 32, 32, 32, 0, true), (.half, .half, 64, 64, 32, 4, true),
            (.half, .half, 128, 128, 32, 4, true),
            (.bf16, .float, 32, 32, 32, 0, true), (.bf16, .float, 64, 64, 32, 4, true),
            (.bf16, .float, 128, 128, 32, 4, true),
            (.int8, .int32, 32, 32, 32, 0, true), (.int8, .int32, 32, 32, 64, 0, true),
            (.int8, .int32, 64, 64, 64, 1, true), (.int8, .int32, 64, 64, 64, 4, true),
            (.int8, .int32, 128, 128, 64, 4, true), (.int8, .int32, 128, 128, 0, 4, true),
            (.int8, .int32, 128, 128, 64, 16, true),
        ]
        for (t, c, bt, bw, bk, nsg, relax) in dev {
            let code = typeCode(t, t, c)
            list.append(NAKernel(name: "na_dev_\(code)_\(bt)x\(bw)x\(bk)_s\(nsg)" + (relax ? "" : "_x"), kind: .gemm,
                                 k: "G", path: "dev", a: t, b: t, c: c, weights: nil, bt: bt, bw: bw, bk: bk,
                                 nsg: nsg, threads: mppThreads(nsg),
                                 note: (bk == 0 ? "K целиком одним run" : "") + (relax ? "" : " без relaxed")))
        }

        // GEMM: MPP, операнды через общую память группы (и «наш» путь с развёрткой)
        let tg: [(String, NAType, NAType, NAWeights?, Int, Int, Int, Int)] = [
            ("hf", .half, .float, nil, 32, 32, 32, 0), ("hf", .half, .float, nil, 64, 64, 32, 1),
            ("hf", .half, .float, nil, 64, 64, 32, 4), ("hf", .half, .float, nil, 64, 64, 64, 4),
            ("hf", .half, .float, nil, 128, 64, 32, 4), ("hf", .half, .float, nil, 128, 128, 32, 4),
            ("hf", .half, .float, nil, 128, 128, 32, 16),
            ("bf", .bf16, .float, nil, 64, 64, 32, 4),
            ("i8", .int8, .int32, nil, 64, 64, 64, 4), ("i8", .int8, .int32, nil, 128, 128, 64, 4),
            ("i8", .int8, .int32, nil, 128, 128, 64, 16),
            ("q4a", .half, .float, .q4a, 64, 64, 64, 4), ("q4a", .half, .float, .q4a, 128, 128, 32, 4),
            ("q4a", .half, .float, .q4a, 128, 128, 32, 16), ("q4a", .half, .float, .q4a, 32, 32, 64, 0),
            ("q40", .half, .float, .q40, 128, 128, 32, 4), ("q80", .half, .float, .q80, 128, 128, 32, 4),
            ("q4k", .half, .float, .q4k, 128, 128, 32, 4), ("q4k", .half, .float, .q4k, 64, 64, 64, 4),
        ]
        for (code, t, c, w, bt, bw, bk, nsg) in tg {
            list.append(NAKernel(name: "na_tg_\(code)_\(bt)x\(bw)x\(bk)_s\(nsg)", kind: .gemm, k: "G", path: "tg",
                                 a: t, b: w == nil ? t : .half, c: c, weights: w, bt: bt, bw: bw, bk: bk, nsg: nsg,
                                 threads: mppThreads(nsg),
                                 note: w == nil ? "двойной буфер, 1 барьер" : "развёртка в общую память + matmul2d"))
        }

        // GEMM: схема MLX в регистрах
        let reg: [(String, NAType, NAType, NAWeights?, Int, Int, Int, Int, String)] = [
            ("hd", .half, .float, nil, 64, 64, 2, 2, "без общей памяти"),
            ("hd", .half, .float, nil, 128, 128, 4, 4, "без общей памяти (MLX fp16)"),
            ("hd", .half, .float, nil, 64, 128, 2, 4, "без общей памяти"),
            ("i8", .int8, .int32, nil, 64, 64, 2, 2, "без общей памяти (Cider)"),
            ("i8", .int8, .int32, nil, 128, 128, 4, 4, "без общей памяти (Cider)"),
            ("f16", .half, .float, .f16, 64, 64, 2, 2, "веса через общую память"),
            ("f16", .half, .float, .f16, 128, 128, 4, 4, "веса через общую память"),
            ("q4a", .half, .float, .q4a, 64, 64, 2, 2, "как наше N"),
            ("q4a", .half, .float, .q4a, 128, 128, 4, 4, "как наше N"),
            ("q40", .half, .float, .q40, 64, 64, 2, 2, "как наше N"),
            ("q40", .half, .float, .q40, 128, 128, 4, 4, "как наше N"),
            ("q80", .half, .float, .q80, 64, 64, 2, 2, "как наше N"),
            ("q80", .half, .float, .q80, 128, 128, 4, 4, "как наше N"),
            ("q4k", .half, .float, .q4k, 64, 64, 2, 2, "как наше N (q4_K)"),
            ("q4k", .half, .float, .q4k, 128, 128, 4, 4, "как наше N (q4_K)"),
        ]
        for (code, t, c, w, bt, bw, wt, ww, note) in reg {
            list.append(NAKernel(name: "na_reg_\(code)_\(bt)x\(bw)", kind: .gemm, k: "G", path: "reg", a: t,
                                 b: w == nil ? t : .half, c: c, weights: w, bt: bt, bw: bw, bk: 64, nsg: 0,
                                 threads: wt * ww * 32, note: note))
        }
        return list
    }
}

// MARK: - Замер

/// Совпадает с NAArgs в NABench.metal.
struct NABenchArgs {
    var M: Int32 = 0, N: Int32 = 0, K: Int32 = 0
    var ldx: Int32 = 0, ldw: Int32 = 0, ldy: Int32 = 0
    var wrow: Int32 = 0, iters: Int32 = 0
}

final class NABench {

    struct Library {
        let label: String
        let library: MTLLibrary
        let hasTensor: Bool
    }

    private let cfg: NABenchConfig
    private let resources: URL?
    private let outDir: URL?
    private let log: (String) -> Void
    private let progress: (String) -> Void

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var logLines: [String] = []
    private var rows: [[String: Any]] = []
    private var fillPSO: [String: MTLComputePipelineState] = [:]
    private var buffers: [String: MTLBuffer] = [:]
    private var rowCache: [String: [Float]] = [:]
    private var failures = 0
    private var psoCache: [String: MTLComputePipelineState] = [:]

    /// - resources: папка, где лежат NABench.metallib и NABench.metal (nil — главный бандл).
    /// - outDir: куда писать na-bench.log и na-results.*; nil — только в журнал.
    init(config: NABenchConfig, resources: URL? = nil, outDir: URL?,
         log: @escaping (String) -> Void, progress: @escaping (String) -> Void) {
        cfg = config
        self.resources = resources
        self.outDir = outDir
        self.log = log
        self.progress = progress
    }

    // Настройки по умолчанию.
    private var warmup: Int { max(1, cfg.warmup ?? 3) }
    private var nSamples: Int { max(1, cfg.samples ?? 10) }
    private var targetMs: Double { max(5, cfg.targetMs ?? 60) }
    private var pause: Double { max(0, cfg.pauseSeconds ?? 2) }
    private var checkPoints: Int { max(4, cfg.checkPoints ?? 64) }
    private var peakGroups: Int { max(32, cfg.peakGroups ?? 1024) }
    private var peakIters: Int { max(4, (cfg.peakIters ?? 256) / 4 * 4) }
    static let defaultShapes: [[Int]] = [
        [4096, 4096, 1024], [12288, 4096, 1024], [4096, 4096, 4096],
        [4096, 4096, 1054], [12288, 4096, 1054], [4096, 12288, 1054],
    ]

    /// Весь замер. Возвращает сводку (она же уходит в na-results.json). Долго — звать не с главного потока.
    func run() -> [String: Any] {
        let started = Date()
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
            say("❌ нет видеочипа Metal")
            return finish(started: started, info: [:], summary: ["error": "нет Metal"])
        }
        device = dev
        queue = q
        let info = deviceInfo()
        say("Видеочип: \(dev.name); семейства: \(info["families"] ?? "?"); "
            + "общая память группы до \(dev.maxThreadgroupMemoryLength / 1024) КБ; "
            + "рабочий набор \(dev.recommendedMaxWorkingSetSize / 1_048_576) МБ; ОС \(info["os"] ?? "?")")

        // Библиотеки
        var libs: [Library] = []
        for label in cfg.libraries ?? ["offline", "src4.1"] {
            if let lib = loadLibrary(label) { libs.append(lib) }
        }
        guard let fillLib = libs.first else {
            say("❌ ни одна библиотека ядер не загрузилась — замер невозможен")
            return finish(started: started, info: info, summary: ["error": "нет библиотеки ядер"])
        }
        prepareFill(fillLib.library)

        let groups = Set((cfg.groups ?? ["peak", "gemm"]).map { $0.lowercased() })
        let kernels = NABenchKernels.all.filter(selected)
        say("Ядер в плане: \(kernels.count) (после фильтров only/skip)")

        var summary: [String: Any] = [:]

        // Пики K0–K4 — на каждой библиотеке
        if groups.contains("peak") {
            let peaks = kernels.filter { $0.kind != .gemm }
            for lib in libs {
                coolDownIfAsked("пики, библиотека \(lib.label)")
                say("── Пики K0–K4, библиотека «\(lib.label)» (\(peaks.count) ядер) ──")
                for (i, kr) in peaks.enumerated() {
                    progress("пики «\(lib.label)» \(i + 1)/\(peaks.count): \(kr.name)")
                    runPeak(kr, lib: lib)
                    sleepPause()
                }
            }
            summary["peaks"] = peakSummary()
        }

        // GEMM — на одной библиотеке
        if groups.contains("gemm") {
            let gl = libs.first { $0.label == (cfg.gemmLibrary ?? libs[0].label) } ?? libs[0]
            let gemms = kernels.filter { $0.kind == .gemm }
            let shapes = (cfg.shapes ?? Self.defaultShapes).filter { $0.count == 3 }
            for (si, s) in shapes.enumerated() {
                let (m, k, n) = (s[0], s[1], s[2])
                guard m > 0, k > 0, n > 0, m % 128 == 0, k % 256 == 0 else {
                    say("⚠️ форма \(s) пропущена: M должно делиться на 128, K — на 256")
                    continue
                }
                coolDownIfAsked("форма \(m)×\(k)×\(n)")
                say("── GEMM \(m)×\(k)×\(n) (M веса × K × N токены), библиотека «\(gl.label)» ──")
                for (i, kr) in gemms.enumerated() {
                    progress("форма \(si + 1)/\(shapes.count) \(m)×\(k)×\(n): \(i + 1)/\(gemms.count) \(kr.name)")
                    runGemm(kr, lib: gl, m: m, k: k, n: n)
                    sleepPause()
                }
                releaseShapeBuffers()
            }
            summary["gemm"] = gemmSummary()
        }
        return finish(started: started, info: info, summary: summary)
    }

    // MARK: Библиотеки

    private func loadLibrary(_ label: String) -> Library? {
        let t0 = Date()
        let lib: MTLLibrary
        do {
            if label == "offline" {
                guard let url = resourceURL("NABench", "metallib") else {
                    say("❌ библиотека «offline»: нет NABench.metallib в приложении (шаг сборки не отработал?)")
                    return nil
                }
                lib = try device.makeLibrary(URL: url)
            } else if label.hasPrefix("src") {
                let ver = String(label.dropFirst(3))          // "4.1"
                let parts = ver.split(separator: ".").compactMap { Int($0) }
                guard parts.count == 2 else { say("❌ библиотека «\(label)»: не понял версию языка"); return nil }
                guard let url = resourceURL("NABench", "metal"),
                      let src = try? String(contentsOf: url, encoding: .utf8) else {
                    say("❌ библиотека «\(label)»: нет текста NABench.metal в приложении")
                    return nil
                }
                let opts = MTLCompileOptions()
                let raw = UInt((parts[0] << 16) + parts[1])
                guard let lv = MTLLanguageVersion(rawValue: raw) else {
                    say("❌ библиотека «\(label)»: система не знает язык \(ver)")
                    return nil
                }
                opts.languageVersion = lv
                lib = try device.makeLibrary(source: src, options: opts)
            } else {
                say("❌ библиотека «\(label)»: не знаю такой (offline, src4.1, src4.0)")
                return nil
            }
        } catch {
            say("❌ библиотека «\(label)» не собралась: \(String(describing: error).prefix(1500))")
            return nil
        }
        let names = Set(lib.functionNames)
        let hasTensor = names.contains("na_has_tensor")
        say("Библиотека «\(label)»: \(names.count) функций, тензоры \(hasTensor ? "ЕСТЬ" : "НЕТ (ядра MPP пропадут)"), "
            + "\(ms(Date().timeIntervalSince(t0))) мс")
        return Library(label: label, library: lib, hasTensor: hasTensor)
    }

    private func resourceURL(_ name: String, _ ext: String) -> URL? {
        if let dir = resources {
            let u = dir.appendingPathComponent("\(name).\(ext)")
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    private func selected(_ k: NAKernel) -> Bool {
        if let only = cfg.only, !only.isEmpty, !only.contains(where: { k.name.contains($0) || k.k == $0 }) {
            return false
        }
        if let skip = cfg.skip, skip.contains(where: { k.name.contains($0) || k.k == $0 }) { return false }
        return true
    }

    // MARK: Буферы и заполнение

    private func prepareFill(_ lib: MTLLibrary) {
        for name in ["na_fill_half", "na_fill_float", "na_fill_bf16", "na_fill_i8",
                     "na_fill_q4a", "na_fill_q40", "na_fill_q80", "na_fill_q4k"] {
            if let f = lib.makeFunction(name: name), let p = try? device.makeComputePipelineState(function: f) {
                fillPSO[name] = p
            } else {
                say("⚠️ нет ядра заполнения \(name)")
            }
        }
    }

    /// Буфер, заполненный на видеочипе: count — число элементов (или блоков для блочных форматов).
    private func filled(_ key: String, bytes: Int, fill: String, count: Int, seed: UInt32) -> MTLBuffer? {
        if let b = buffers[key] { return b }
        guard let buf = device.makeBuffer(length: max(bytes, 16), options: .storageModeShared) else {
            say("❌ не хватило памяти на буфер \(key) (\(bytes / 1_048_576) МБ)")
            return nil
        }
        guard let pso = fillPSO[fill], let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return nil }
        var s = seed
        enc.setComputePipelineState(pso)
        enc.setBuffer(buf, offset: 0, index: 0)
        enc.setBytes(&s, length: 4, index: 1)
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(256, pso.maxTotalThreadsPerThreadgroup),
                                                           height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        buffers[key] = buf
        return buf
    }

    private func typedFill(_ t: NAType) -> String {
        switch t {
        case .half: return "na_fill_half"
        case .bf16: return "na_fill_bf16"
        case .float: return "na_fill_float"
        case .int8, .int32: return "na_fill_i8"
        }
    }

    /// X — N_pad × K элементов типа t.
    private func xBuffer(_ t: NAType, npad: Int, k: Int) -> MTLBuffer? {
        filled("x.\(t.rawValue)", bytes: npad * k * t.size, fill: typedFill(t), count: npad * k, seed: 11)
    }

    /// W — M × K элементов типа t, или блочный формат.
    private func wBuffer(_ kr: NAKernel, m: Int, k: Int) -> MTLBuffer? {
        if let w = kr.weights, w != .f16, let fill = w.fillKernel {
            let blocks = m * k / w.qk
            return filled("w.\(w.rawValue)", bytes: blocks * w.blockBytes, fill: fill, count: blocks, seed: 23)
        }
        let t = kr.weights == .f16 ? NAType.half : kr.b
        return filled("w.\(t.rawValue)", bytes: m * k * t.size, fill: typedFill(t), count: m * k, seed: 23)
    }

    private func yBuffer(bytes: Int) -> MTLBuffer? {
        if let b = buffers["y"], b.length >= bytes { return b }
        buffers["y"] = nil
        let b = device.makeBuffer(length: bytes, options: .storageModeShared)
        buffers["y"] = b
        return b
    }

    private func releaseShapeBuffers() {
        buffers = buffers.filter { $0.key.hasPrefix("peak.") }
        rowCache.removeAll()
    }

    // MARK: Пики K0–K4

    private func runPeak(_ kr: NAKernel, lib: Library) {
        var row = baseRow(kr, lib: lib.label)
        row["groups"] = peakGroups
        row["iters"] = peakIters
        guard let pso = pipeline(kr, lib: lib, row: &row) else { return }

        // Входы: маленькие буферы по 4096 элементов каждого типа (A и B — разные семена).
        func small(_ t: NAType, _ tag: String, _ seed: UInt32) -> MTLBuffer? {
            filled("peak.\(tag).\(t.rawValue)", bytes: 4096 * t.size, fill: typedFill(t), count: 4096, seed: seed)
        }
        guard let bufA = small(kr.a, "A", 101), let bufB = small(kr.b, "B", 202) else {
            return fail(&row, "не выделились входы")
        }
        let outBytes: Int
        let flopPerDispatch: Double
        switch kr.kind {
        case .k0peak:
            outBytes = peakGroups * 4 * 512 * 4
            flopPerDispatch = Double(peakGroups) * 4 * Double(peakIters) * 8 * 1024
        case .k4:
            outBytes = peakGroups * 4 * 1024 * 4
            flopPerDispatch = Double(peakGroups) * 4 * Double(peakIters) * 4 * 16384
        default:
            outBytes = peakGroups * kr.bt * kr.bw * max(4, kr.c.size)
            flopPerDispatch = Double(peakGroups) * Double(peakIters) * 2 * Double(kr.bt * kr.bw * kr.bk)
        }
        guard let out = filled("peak.out", bytes: 16 * 1_048_576, fill: "na_fill_float", count: 16, seed: 1),
              out.length >= outBytes else { return fail(&row, "не выделился буфер результата") }

        func encoder(iters: Int) -> (MTLComputeCommandEncoder) -> Void {
            var args = NABenchArgs()
            args.iters = Int32(iters)
            let tpg = MTLSize(width: kr.threads, height: 1, depth: 1)
            let grid = MTLSize(width: peakGroups, height: 1, depth: 1)
            return { enc in
                enc.setComputePipelineState(pso)
                enc.setBuffer(bufA, offset: 0, index: 0)
                enc.setBuffer(bufB, offset: 0, index: 1)
                enc.setBuffer(out, offset: 0, index: 2)
                enc.setBytes(&args, length: MemoryLayout<NABenchArgs>.stride, index: 3)
                enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tpg)
            }
        }

        // Сверка: короткий прогон (4 повтора) и эталон по первой группе.
        do {
            _ = try runCB(encoder(iters: 4), count: 1)
            let err = checkPeak(kr, a: bufA, b: bufB, out: out, iters: 4)
            row.merge(err) { $1 }
        } catch {
            return fail(&row, "сверка упала: \(error)")
        }
        measureAndLog(&row, kr: kr, flop: flopPerDispatch, encode: encoder(iters: peakIters))
    }

    private func checkPeak(_ kr: NAKernel, a: MTLBuffer, b: MTLBuffer, out: MTLBuffer, iters: Int) -> [String: Any] {
        var ref: [Double] = []
        var got: [Double] = []
        let it = Double(iters)
        switch kr.kind {
        case .k0peak:
            // c[0] группы 0, SIMD-группы 0 = iters · x0 · y0 (8×8, строки — i, столбцы — j).
            for i in 0..<8 {
                for j in 0..<8 {
                    var s = 0.0
                    for kk in 0..<8 { s += read(a, .half, i * 8 + kk) * read(a, .half, 256 + kk * 8 + j) }
                    ref.append(s * it)
                    got.append(read(out, .float, i * 8 + j))
                }
            }
        case .k4:
            // «токены» — A[0..1023] 32×32, «веса» — A[1024..2047] 32×32, результат [токен][вес].
            for r in stride(from: 0, to: 32, by: 3) {
                for c in stride(from: 0, to: 32, by: 5) {
                    var s = 0.0
                    for kk in 0..<32 { s += read(a, kr.a, r * 32 + kk) * read(a, kr.a, 1024 + c * 32 + kk) }
                    ref.append(s * it)
                    got.append(read(out, kr.c, r * 32 + c))
                }
            }
        default:
            // Результат группы 0: [строка A][строка B], extents (NT, MT) — B подряд.
            for r in 0..<kr.bt {
                for c in stride(from: r % 3, to: kr.bw, by: 3) {
                    var s = 0.0
                    for kk in 0..<kr.bk { s += read(a, kr.a, r * kr.bk + kk) * read(b, kr.b, c * kr.bk + kk) }
                    ref.append(s * it)
                    got.append(read(out, kr.c, r * kr.bw + c))
                }
            }
        }
        return compare(ref, got, kr: kr)
    }

    // MARK: GEMM

    private func runGemm(_ kr: NAKernel, lib: Library, m: Int, k: Int, n: Int) {
        var row = baseRow(kr, lib: lib.label)
        let npad = (n + 127) / 128 * 128
        let tagK = (m == k && k == n) ? "K5" : "K6"
        row["k"] = kr.path == "simd" ? "K0" : tagK
        row["shape"] = [m, k, n]
        row["npad"] = npad
        guard m % kr.bw == 0, k % max(kr.bk, 64) == 0 else {
            return skip(&row, "форма не делится на плитку \(kr.tile)")
        }
        guard let pso = pipeline(kr, lib: lib, row: &row) else { return }
        guard let x = xBuffer(kr.a, npad: npad, k: k), let w = wBuffer(kr, m: m, k: k),
              let y = yBuffer(bytes: npad * m * kr.c.size) else {
            return fail(&row, "не выделились буферы")
        }
        var args = NABenchArgs()
        args.M = Int32(m); args.N = Int32(npad); args.K = Int32(k)
        args.ldx = Int32(k); args.ldw = Int32(k); args.ldy = Int32(m)
        args.wrow = Int32((kr.weights ?? .f16).rowBytes(k))
        if kr.weights == .f16 { args.wrow = Int32(k * 2) }
        let grid = MTLSize(width: (n + kr.bt - 1) / kr.bt, height: m / kr.bw, depth: 1)
        let tpg = MTLSize(width: kr.threads, height: 1, depth: 1)
        let encode: (MTLComputeCommandEncoder) -> Void = { enc in
            enc.setComputePipelineState(pso)
            enc.setBuffer(x, offset: 0, index: 0)
            enc.setBuffer(w, offset: 0, index: 1)
            enc.setBuffer(y, offset: 0, index: 2)
            enc.setBytes(&args, length: MemoryLayout<NABenchArgs>.stride, index: 3)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tpg)
        }

        // Сверка с процессором: результат обнулён, один прогон, точки только в настоящих N.
        do {
            memset(y.contents(), 0, npad * m * kr.c.size)
            _ = try runCB(encode, count: 1)
            row.merge(checkGemm(kr, x: x, w: w, y: y, m: m, k: k, n: n)) { $1 }
        } catch {
            return fail(&row, "сверка упала: \(error)")
        }
        let flop = 2.0 * Double(m) * Double(n) * Double(k)
        row["flopPaddedRatio"] = Double(grid.width * kr.bt) / Double(n)
        measureAndLog(&row, kr: kr, flop: flop, encode: encode)
    }

    private func checkGemm(_ kr: NAKernel, x: MTLBuffer, w: MTLBuffer, y: MTLBuffer,
                           m: Int, k: Int, n: Int) -> [String: Any] {
        var rng = SplitMix(seed: UInt64(m * 31 + k * 7 + n))
        var pts: [(Int, Int)] = [(0, 0), (n - 1, m - 1), (n - 1, 0), (0, m - 1)]
        while pts.count < checkPoints { pts.append((Int(rng.next() % UInt64(n)), Int(rng.next() % UInt64(m)))) }
        var ref: [Double] = [], got: [Double] = []
        for (t, r) in pts {
            let wrow = weightRow(kr, w: w, row: r, k: k)
            var s = 0.0
            for kk in 0..<k { s += read(x, kr.a, t * k + kk) * Double(wrow[kk]) }
            ref.append(s)
            got.append(read(y, kr.c, t * m + r))
        }
        return compare(ref, got, kr: kr)
    }

    /// Строка весов в Float — для эталона. Для блочных форматов — развёртка тем же порядком,
    /// что na_deq16 в NABench.metal (в float, а не в half — отсюда небольшая разница).
    private func weightRow(_ kr: NAKernel, w: MTLBuffer, row: Int, k: Int) -> [Float] {
        let fmt = kr.weights
        let key = "\(fmt?.rawValue ?? kr.b.rawValue).\(row)"
        if let c = rowCache[key] { return c }
        var out = [Float](repeating: 0, count: k)
        if fmt == nil || fmt == .f16 {
            let t = fmt == .f16 ? NAType.half : kr.b
            for kk in 0..<k { out[kk] = Float(read(w, t, row * k + kk)) }
        } else if let fmt {
            let base = w.contents().assumingMemoryBound(to: UInt8.self) + row * fmt.rowBytes(k)
            NABenchWeights.dequantRow(fmt, base, k, &out)
        }
        rowCache[key] = out
        return out
    }

    // MARK: Общее: конвейер, время, сверка

    private func pipeline(_ kr: NAKernel, lib: Library, row: inout [String: Any]) -> MTLComputePipelineState? {
        guard let f = lib.library.makeFunction(name: kr.name) else {
            skip(&row, lib.hasTensor || kr.nsg < 0 ? "нет в библиотеке" : "нет в библиотеке (нет тензоров)")
            return nil
        }
        let t0 = Date()
        do {
            // Конвейер собирается один раз на библиотеку: у ядер MPP сборка идёт на телефоне
            // и небыстрая, а форм — шесть.
            let key = "\(lib.label)/\(kr.name)"
            let pso: MTLComputePipelineState
            if let cached = psoCache[key] {
                pso = cached
            } else {
                pso = try device.makeComputePipelineState(function: f)
                psoCache[key] = pso
                row["psoMs"] = ms(Date().timeIntervalSince(t0))
            }
            row["maxThreads"] = pso.maxTotalThreadsPerThreadgroup
            row["tgMemBytes"] = pso.staticThreadgroupMemoryLength
            guard pso.maxTotalThreadsPerThreadgroup >= kr.threads else {
                fail(&row, "ядру нужно \(kr.threads) нитей в группе, конвейер даёт \(pso.maxTotalThreadsPerThreadgroup)")
                return nil
            }
            guard pso.staticThreadgroupMemoryLength <= device.maxThreadgroupMemoryLength else {
                fail(&row, "общей памяти нужно \(pso.staticThreadgroupMemoryLength), есть \(device.maxThreadgroupMemoryLength)")
                return nil
            }
            return pso
        } catch {
            fail(&row, "конвейер не собрался: \(String(describing: error).prefix(600))")
            return nil
        }
    }

    /// Один буфер команд с count одинаковыми диспатчами; время видеочипа, с.
    private func runCB(_ encode: (MTLComputeCommandEncoder) -> Void, count: Int) throws -> Double {
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
            throw NABenchError("не создался буфер команд")
        }
        for _ in 0..<count { encode(enc) }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw e }
        if cb.status != .completed { throw NABenchError("буфер команд: статус \(cb.status.rawValue)") }
        return cb.gpuEndTime - cb.gpuStartTime
    }

    private func measureAndLog(_ row: inout [String: Any], kr: NAKernel, flop: Double,
                               encode: (MTLComputeCommandEncoder) -> Void) {
        row["thermalBefore"] = Self.heat()
        do {
            var t1 = Double.infinity
            for _ in 0..<warmup { t1 = min(t1, try runCB(encode, count: 1)) }
            let reps = max(1, min(400, Int((targetMs / 1000) / max(t1, 1e-7))))
            var times: [Double] = []
            for _ in 0..<nSamples { times.append(try runCB(encode, count: reps) / Double(reps)) }
            times.sort()
            let median = times[times.count / 2]
            let best = times[0]
            row["reps"] = reps
            row["msMedian"] = round3(median * 1000)
            row["msBest"] = round3(best * 1000)
            row["tflops"] = round3(flop / median / 1e12)
            row["tflopsBest"] = round3(flop / best / 1e12)
            if let r = row["flopPaddedRatio"] as? Double {
                row["tflopsPadded"] = round3(flop * r / median / 1e12)
            }
        } catch {
            row["thermalAfter"] = Self.heat()
            return fail(&row, "замер упал: \(error)")
        }
        row["thermalAfter"] = Self.heat()
        emit(row)
    }

    private func compare(_ ref: [Double], _ got: [Double], kr: NAKernel) -> [String: Any] {
        var maxAbs = 0.0, sq = 0.0, bad = 0
        for (r, g) in zip(ref, got) {
            if !g.isFinite { bad += 1; continue }
            maxAbs = max(maxAbs, abs(r - g))
            sq += r * r
        }
        let rms = (sq / Double(max(1, ref.count))).squareRoot()
        let rel = rms > 0 ? maxAbs / rms : maxAbs
        // Допуски: int8 — точно; half-результат — грубее; остальное — накопление в float.
        let tol: Double
        switch (kr.a, kr.c) {
        case (.int8, _): tol = 0
        case (_, .half): tol = 3e-2
        default: tol = kr.weights == nil || kr.weights == .f16 ? 1e-2 : 2e-2
        }
        let ok = bad == 0 && rel <= tol && rms > 0
        return ["ok": ok, "relErr": rel, "maxAbsErr": maxAbs, "refRms": rms, "nonFinite": bad, "tolerance": tol]
    }

    private func read(_ buf: MTLBuffer, _ t: NAType, _ i: Int) -> Double {
        let p = buf.contents()
        switch t {
        case .half: return Double(Float(Float16(bitPattern: p.load(fromByteOffset: i * 2, as: UInt16.self))))
        case .bf16: return Double(Float(bitPattern: UInt32(p.load(fromByteOffset: i * 2, as: UInt16.self)) << 16))
        case .float: return Double(p.load(fromByteOffset: i * 4, as: Float.self))
        case .int8: return Double(p.load(fromByteOffset: i, as: Int8.self))
        case .int32: return Double(p.load(fromByteOffset: i * 4, as: Int32.self))
        }
    }

    // MARK: Строки итогов

    private func baseRow(_ kr: NAKernel, lib: String) -> [String: Any] {
        ["kernel": kr.name, "k": kr.k, "path": kr.path,
         "types": "\(kr.a.rawValue)×\(kr.weightsLabel)→\(kr.c.rawValue)",
         "weights": kr.weightsLabel, "tile": kr.tile, "nsg": kr.nsg, "threads": kr.threads,
         "library": lib, "note": kr.note, "time": ISO8601DateFormatter().string(from: Date())]
    }

    private func fail(_ row: inout [String: Any], _ why: String) {
        failures += 1
        row["error"] = why
        emit(row)
    }

    private func skip(_ row: inout [String: Any], _ why: String) {
        row["skipped"] = why
        emit(row)
    }

    private func emit(_ row: [String: Any]) {
        rows.append(row)
        appendJSONL(row)
        say(Self.line(row))
    }

    static func line(_ r: [String: Any]) -> String {
        let k = r["k"] as? String ?? "?"
        let name = r["kernel"] as? String ?? "?"
        let shape = (r["shape"] as? [Int]).map { " [\($0.map(String.init).joined(separator: "×"))]" } ?? ""
        if let s = r["skipped"] as? String { return "\(k) \(name)\(shape): пропуск — \(s)" }
        if let e = r["error"] as? String { return "\(k) \(name)\(shape): ❌ \(e)" }
        let tf = r["tflops"] as? Double ?? 0
        let msm = r["msMedian"] as? Double ?? 0
        let ok = (r["ok"] as? Bool ?? false) ? "✓" : "✗ НЕВЕРНО"
        let rel = r["relErr"] as? Double ?? 0
        let heat = "\(r["thermalBefore"] ?? "?")→\(r["thermalAfter"] ?? "?")"
        return String(format: "%@ %@%@: %.2f трлн/с (%.3f мс) %@ ош %.1e, %@", k, name, shape, tf, msm, ok, rel, heat)
    }

    // MARK: Сводки

    private func okRows(_ f: (([String: Any]) -> Bool)) -> [[String: Any]] {
        rows.filter { ($0["ok"] as? Bool) == true && $0["tflops"] != nil && f($0) }
    }

    private func best(_ rs: [[String: Any]]) -> [String: Any]? {
        rs.max { ($0["tflops"] as? Double ?? 0) < ($1["tflops"] as? Double ?? 0) }
    }

    private func brief(_ r: [String: Any]?) -> Any {
        guard let r else { return NSNull() }
        return ["kernel": r["kernel"] ?? "", "library": r["library"] ?? "", "tflops": r["tflops"] ?? 0]
    }

    private func peakSummary() -> [String: Any] {
        var out: [String: Any] = [:]
        let libsSeen = Array(Set(rows.compactMap { $0["library"] as? String })).sorted()
        for lib in libsSeen {
            func b(_ f: @escaping ([String: Any]) -> Bool) -> [String: Any]? {
                best(okRows { ($0["library"] as? String) == lib && f($0) })
            }
            let k0 = b { ($0["k"] as? String) == "K0" && $0["shape"] == nil }
            let k1 = b { ($0["k"] as? String) == "K1" }
            let k2 = b { ($0["k"] as? String) == "K2" }
            let k4 = b { ($0["k"] as? String) == "K4" && ($0["kernel"] as? String) == "na_k4_hf" }
            let v0 = k0?["tflops"] as? Double ?? 0, v1 = k1?["tflops"] as? Double ?? 0
            let v2 = k2?["tflops"] as? Double ?? 0
            var s: [String: Any] = ["K0": brief(k0), "K1": brief(k1), "K2": brief(k2), "K4": brief(k4)]
            if v0 > 0 { s["K1/K0"] = round3(v1 / v0) }
            if v1 > 0 { s["K2/K1"] = round3(v2 / v1) }
            var k3: [String: Any] = [:]
            for r in okRows({ ($0["library"] as? String) == lib && ($0["k"] as? String) == "K3" }) {
                k3[r["kernel"] as? String ?? "?"] = r["tflops"]
            }
            s["K3"] = k3
            let verdict: String
            if v0 > 0 && v1 >= 2 * v0 {
                verdict = "блоки РАБОТАЮТ: K1 = \(fmt2(v1)) против K0 = \(fmt2(v0)) трлн/с"
            } else if v0 > 0 && v1 > 0 {
                verdict = "блоки НЕ видны: K1 = \(fmt2(v1)) ≈ K0 = \(fmt2(v0)) трлн/с"
            } else {
                verdict = "нечего сравнить (K0 или K1 не померены)"
            }
            s["verdict"] = verdict
            say("ИТОГ пики «\(lib)»: \(verdict); K2/K1 = \(v1 > 0 ? fmt2(v2 / v1) : "—")")
            out[lib] = s
        }
        return out
    }

    private func gemmSummary() -> [String: Any] {
        var out: [String: Any] = [:]
        let shapes = Array(Set(rows.compactMap { ($0["shape"] as? [Int]).map { $0.map(String.init).joined(separator: "x") } }))
            .sorted()
        for sh in shapes {
            let inShape = { (r: [String: Any]) -> Bool in
                ((r["shape"] as? [Int]).map { $0.map(String.init).joined(separator: "x") }) == sh
            }
            func b(_ f: @escaping ([String: Any]) -> Bool) -> [String: Any]? { best(okRows { inShape($0) && f($0) }) }
            let path = { (r: [String: Any]) in r["path"] as? String ?? "" }
            let types = { (r: [String: Any]) in r["types"] as? String ?? "" }
            let wts = { (r: [String: Any]) in r["weights"] as? String ?? "" }
            let simd = b { path($0) == "simd" && wts($0) == "half" }
            // Блочные веса — отдельно обычный путь (simd) и путь через блоки (tg/reg).
            func q(_ w: String, _ label: String) -> [(String, [String: Any]?)] {
                [("\(label) обычный путь", b { path($0) == "simd" && wts($0) == w }),
                 ("\(label) через блоки", b { path($0) != "simd" && wts($0) == w })]
            }
            let cats: [(String, [String: Any]?)] = [
                ("simd (обычный путь)", simd),
                ("MPP half, операнды из памяти", b { path($0) == "dev" && types($0) == "half×half→float" }),
                ("MPP half, через общую память", b { path($0) == "tg" && types($0) == "half×half→float" }),
                ("MLX half без общей памяти", b { path($0) == "reg" && ($0["weights"] as? String) == "half" }),
                ("half→half", b { types($0) == "half×half→half" }),
                ("bf16", b { types($0).hasPrefix("bf16") }),
                ("int8", b { types($0).hasPrefix("int8") }),
                ("f16 через общую память", b { wts($0) == "f16" }),
            ] + q("q4a", "q4a (MLX affine)") + q("q40", "q4_0") + q("q80", "q8_0") + q("q4k", "q4_K")
            var s: [String: Any] = [:]
            let base = simd?["tflops"] as? Double ?? 0
            var parts: [String] = []
            for (label, r) in cats {
                s[label] = brief(r)
                if let v = r?["tflops"] as? Double {
                    parts.append("\(label) \(fmt2(v))" + (base > 0 && label != "simd (обычный путь)" ? " (×\(fmt2(v / base)))" : ""))
                }
            }
            say("ИТОГ \(sh): " + parts.joined(separator: "; "))
            out[sh] = s
        }
        return out
    }

    // MARK: Файлы и мелочи

    private func finish(started: Date, info: [String: Any], summary: [String: Any]) -> [String: Any] {
        let wrong = rows.filter { ($0["ok"] as? Bool) == false }.count
        var all: [String: Any] = ["device": info, "summary": summary, "rows": rows,
                                  "seconds": Int(Date().timeIntervalSince(started)),
                                  "failures": failures, "wrongResults": wrong,
                                  "settings": ["warmup": warmup, "samples": nSamples, "targetMs": targetMs,
                                               "pauseSeconds": pause, "checkPoints": checkPoints,
                                               "peakGroups": peakGroups, "peakIters": peakIters]]
        all["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        say("Замер нейроблоков закончен за \(Int(Date().timeIntervalSince(started))) с: "
            + "замеров \(rows.count), ошибок \(failures), неверных результатов \(wrong)")
        if let dir = outDir, let data = try? JSONSerialization.data(withJSONObject: all,
                                                                     options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("na-results.json"), options: .atomic)
        }
        return ["summary": summary, "failures": failures, "wrongResults": wrong, "rows": rows.count,
                "seconds": Int(Date().timeIntervalSince(started))]
    }

    private func deviceInfo() -> [String: Any] {
        var fams: [String] = []
        for (name, raw) in [("apple7", 1007), ("apple8", 1008), ("apple9", 1009), ("apple10", 1010),
                            ("metal3", 5001), ("metal4", 5002)] {
            if let f = MTLGPUFamily(rawValue: raw), device.supportsFamily(f) { fams.append(name) }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ["name": device.name, "families": fams.joined(separator: ","),
                "os": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                "maxThreadgroupMemory": device.maxThreadgroupMemoryLength,
                "recommendedMaxWorkingSetMB": Int(device.recommendedMaxWorkingSetSize / 1_048_576),
                "thermal": Self.heat()]
    }

    private func coolDownIfAsked(_ what: String) {
        guard cfg.coolDown ?? true else { return }
        let limit = cfg.coolDownTimeoutSeconds ?? 600
        let t0 = Date()
        guard ProcessInfo.processInfo.thermalState != .nominal else { return }
        say("Остываю перед «\(what)»: сейчас \(Self.heat())")
        while ProcessInfo.processInfo.thermalState != .nominal && Date().timeIntervalSince(t0) < limit {
            progress("остываю перед «\(what)»: \(Self.heat()), \(Int(Date().timeIntervalSince(t0))) с")
            Thread.sleep(forTimeInterval: 5)
        }
        say("Остывание: \(Int(Date().timeIntervalSince(t0))) с, теперь \(Self.heat())")
    }

    private func sleepPause() {
        if pause > 0 { Thread.sleep(forTimeInterval: pause) }
    }

    private func say(_ text: String) {
        logLines.append(text)
        log(text)
        if let dir = outDir {
            try? Data((logLines.joined(separator: "\n") + "\n").utf8)
                .write(to: dir.appendingPathComponent("na-bench.log"), options: .atomic)
        }
    }

    private func appendJSONL(_ row: [String: Any]) {
        guard let dir = outDir,
              var line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let url = dir.appendingPathComponent("na-results.jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    static func heat() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "нормально"
        case .fair: return "тёплый"
        case .serious: return "горячий"
        case .critical: return "критично"
        @unknown default: return "?"
        }
    }

    private func ms(_ s: Double) -> Int { Int((s * 1000).rounded()) }
    private func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }
}

struct NABenchError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Простой генератор для выбора точек сверки (воспроизводимо между запусками).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Эталонная развёртка весов (порядок — как na_deq16 в NABench.metal)

enum NABenchWeights {

    static func half(_ p: UnsafePointer<UInt8>) -> Float {
        Float(Float16(bitPattern: UInt16(p[0]) | (UInt16(p[1]) << 8)))
    }

    static func dequantRow(_ f: NAWeights, _ row: UnsafePointer<UInt8>, _ k: Int, _ out: inout [Float]) {
        let nb = k / f.qk
        for bi in 0..<nb {
            let blk = row + bi * f.blockBytes
            let o = bi * f.qk
            switch f {
            case .f16:
                for j in 0..<16 { out[o + j] = half(blk + 2 * j) }
            case .q4a:
                let s = half(blk), b = half(blk + 2)
                for j in 0..<64 {
                    let q = (blk[4 + j / 2] >> (UInt8(j & 1) * 4)) & 0xF
                    out[o + j] = s * Float(q) + b
                }
            case .q40:
                let d = half(blk)
                for j in 0..<16 {
                    out[o + j] = d * Float(Int(blk[2 + j] & 0xF) - 8)
                    out[o + 16 + j] = d * Float(Int(blk[2 + j] >> 4) - 8)
                }
            case .q80:
                let d = half(blk)
                for j in 0..<32 { out[o + j] = d * Float(Int8(bitPattern: blk[2 + j])) }
            case .q4k:
                let d = half(blk), dmin = half(blk + 2)
                let sc = blk + 4, qs = blk + 16
                for j64 in 0..<4 {
                    for sub in 0..<2 {
                        let isc = 2 * j64 + sub
                        let sv: UInt8, mv: UInt8
                        if isc < 4 {
                            sv = sc[isc] & 63
                            mv = sc[isc + 4] & 63
                        } else {
                            sv = (sc[isc + 4] & 0xF) | ((sc[isc - 4] >> 6) << 4)
                            mv = (sc[isc + 4] >> 4) | ((sc[isc] >> 6) << 4)
                        }
                        let dl = d * Float(sv), ml = dmin * Float(mv)
                        for l in 0..<32 {
                            let q = sub == 0 ? (qs[32 * j64 + l] & 0xF) : (qs[32 * j64 + l] >> 4)
                            out[o + 64 * j64 + 32 * sub + l] = dl * Float(q) - ml
                        }
                    }
                }
            }
        }
    }
}

#endif
