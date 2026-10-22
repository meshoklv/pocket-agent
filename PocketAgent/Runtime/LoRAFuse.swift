//
//  LoRAFuse.swift
//  PocketAgent / Runtime
//
//  Переписывает дополнение-LoRA турбо v0.2.1 от Viggle (Qwen-Image 2.1) под раскладку
//  нашего рисующего файла. Порт `tools/lora/convert_qwen_lora.py` один в один. ROADMAP §24.4.
//
//  Зачем. У Qwen-Image 2.1 слой MLP картинки в файлах GGUF (leejet, Abiray) хранится
//  ОДНОЙ слитой матрицей `img_mlp.gate_up` = [gate_layer; proj], а LoRA от Viggle
//  обучена на ДВУХ отдельных (`img_mlp.gate_layer`, `img_mlp.proj`). Движку некуда
//  положить 128 из 454 частей, и он их молча пропускает — картинка выходит мыльной
//  (замер на мини 24.09.2026: 326 из 454). После слияния — 390 из 390.
//
//  Слияние ТОЧНОЕ, без единого умножения — только перестановка байт:
//    A_слитая = [A_gate; A_proj]                   (одна над другой)
//    B_слитая = [[B_gate, 0], [0, B_proj]]         (по диагонали блоками)
//  B_слитая · A_слитая даёт ту же добавку, что две отдельные пары, бит в бит.
//  Ранг складывается (128 + 128), поэтому файл растёт: 680 МБ → 881 МБ.
//
//  Порядок половин (сначала gate, потом proj) — тот же, что у самой Viggle в узле
//  ComfyUI для слитого MLP (`comfyui/viggle_turbo.py`: gate_up = [gate_layer; proj]).
//

import Foundation

public enum LoRAFuse {

    public struct Summary: Sendable, Equatable {
        public let tensorsIn: Int
        public let tensorsOut: Int
        public let fusedBlocks: Int
        public let bytesOut: Int64
    }

    public enum Failure: Error, LocalizedError {
        case notSafetensors
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .notSafetensors:
                return "Файл дополнения повреждён — удалите его и скачайте заново."
            case .unsupported(let why):
                return "Это дополнение не подходит к модели: \(why)."
            }
        }
    }

    private struct Tensor {
        let dtype: String
        let shape: [Int]
        let range: Range<Int>   // байты данных внутри файла (уже со сдвигом на заголовок)
    }

    /// Откуда брать байты тензора на выходе.
    private enum Source {
        case copy(Range<Int>)
        case stack(Range<Int>, Range<Int>)
        case blockDiagonal(gate: Range<Int>, proj: Range<Int>, rows: Int, rowBytes: Int)
    }

    private static let elementSize = ["BF16": 2, "F16": 2, "F32": 4, "F64": 8]

    /// Слить `input` в `output`. Пишет во временный файл рядом и переименовывает в конце:
    /// оборванная на середине запись не оставит «готовый» файл-огрызок.
    @discardableResult
    public static func fuseQwenImageMLP(input: URL, output: URL) throws -> Summary {
        let data = try Data(contentsOf: input, options: .alwaysMapped)
        guard data.count >= 8 else { throw Failure.notSafetensors }
        let headerLen = data.prefix(8).enumerated()
            .reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * UInt64($1.offset))) }
        guard headerLen > 1, 8 + Int(headerLen) <= data.count,
              let header = try JSONSerialization.jsonObject(
                with: data.subdata(in: 8..<(8 + Int(headerLen)))) as? [String: Any]
        else { throw Failure.notSafetensors }
        let dataStart = 8 + Int(headerLen)

        var metadata: Any?
        var tensors: [String: Tensor] = [:]
        for (name, value) in header {
            if name == "__metadata__" { metadata = value; continue }
            guard let info = value as? [String: Any],
                  let dtype = info["dtype"] as? String,
                  let shape = info["shape"] as? [Int],
                  let offsets = info["data_offsets"] as? [Int], offsets.count == 2,
                  offsets[0] <= offsets[1], dataStart + offsets[1] <= data.count
            else { throw Failure.notSafetensors }
            tensors[name] = Tensor(dtype: dtype, shape: shape,
                                   range: (dataStart + offsets[0])..<(dataStart + offsets[1]))
        }

        // Отдельный масштаб у частей MLP сломал бы слияние (половины с разным множителем).
        // У Viggle alpha = rank, отдельных .alpha в файле нет — проверяем фактом.
        if let odd = tensors.keys.first(where: {
            $0.contains("img_mlp") && ($0.hasSuffix(".alpha") || $0.hasSuffix(".scale"))
        }) {
            throw Failure.unsupported("у части \(odd) свой масштаб")
        }

        let suffix = ".gate_layer.lora_A.weight"
        let prefixes = tensors.keys
            .filter { $0.hasSuffix(".img_mlp" + suffix) }
            .map { String($0.dropLast(suffix.count)) }

        var out: [String: (dtype: String, shape: [Int], source: Source)] = [:]
        for (name, t) in tensors { out[name] = (t.dtype, t.shape, .copy(t.range)) }

        var fused = 0
        for prefix in prefixes {
            guard let aGate = tensors["\(prefix).gate_layer.lora_A.weight"],
                  let bGate = tensors["\(prefix).gate_layer.lora_B.weight"],
                  let aProj = tensors["\(prefix).proj.lora_A.weight"],
                  let bProj = tensors["\(prefix).proj.lora_B.weight"] else { continue }
            guard aGate.dtype == aProj.dtype, bGate.dtype == bProj.dtype,
                  let esB = elementSize[bGate.dtype],
                  aGate.shape.count == 2, aProj.shape.count == 2,
                  bGate.shape.count == 2, bProj.shape.count == 2 else {
                throw Failure.unsupported("\(prefix): непривычные типы или формы")
            }
            let r = aGate.shape[0], inFeatures = aGate.shape[1]
            let outHalf = bGate.shape[0]
            guard aProj.shape == [r, inFeatures], bGate.shape == [outHalf, r],
                  bProj.shape == [outHalf, r],
                  bGate.range.count == outHalf * r * esB, bProj.range.count == outHalf * r * esB
            else { throw Failure.unsupported("\(prefix): половины разного размера") }

            for part in ["gate_layer", "proj"] {
                out["\(prefix).\(part).lora_A.weight"] = nil
                out["\(prefix).\(part).lora_B.weight"] = nil
            }
            out["\(prefix).gate_up.lora_A.weight"] =
                (aGate.dtype, [2 * r, inFeatures], .stack(aGate.range, aProj.range))
            out["\(prefix).gate_up.lora_B.weight"] =
                (bGate.dtype, [2 * outHalf, 2 * r],
                 .blockDiagonal(gate: bGate.range, proj: bProj.range, rows: outHalf, rowBytes: r * esB))
            fused += 1
        }
        guard fused > 0 else {
            throw Failure.unsupported("раздельных частей MLP не нашлось — это не LoRA Qwen-Image 2.1 от Viggle")
        }

        // Заголовок: имена по алфавиту, данные в том же порядке.
        func size(_ s: Source) -> Int {
            switch s {
            case .copy(let r): return r.count
            case .stack(let a, let b): return a.count + b.count
            case .blockDiagonal(_, _, let rows, let rowBytes): return 2 * rows * 2 * rowBytes
            }
        }
        let names = out.keys.sorted()
        var json: [String: Any] = [:]
        var offset = 0
        for name in names {
            let e = out[name]!
            let n = size(e.source)
            json[name] = ["dtype": e.dtype, "shape": e.shape, "data_offsets": [offset, offset + n]]
            offset += n
        }
        if let metadata { json["__metadata__"] = metadata }
        var headerOut = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        // Формат допускает добивку пробелами до кратного 8 — начало данных выровнено.
        while headerOut.count % 8 != 0 { headerOut.append(0x20) }

        let fm = FileManager.default
        let temp = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).part")
        try? fm.removeItem(at: temp)
        guard fm.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let fh = try FileHandle(forWritingTo: temp)
            defer { try? fh.close() }
            var len = UInt64(headerOut.count).littleEndian
            try fh.write(contentsOf: Data(bytes: &len, count: 8))
            try fh.write(contentsOf: headerOut)
            for name in names {
                switch out[name]!.source {
                case .copy(let r):
                    try fh.write(contentsOf: data.subdata(in: r))
                case .stack(let a, let b):
                    try fh.write(contentsOf: data.subdata(in: a))
                    try fh.write(contentsOf: data.subdata(in: b))
                case .blockDiagonal(let gate, let proj, let rows, let rowBytes):
                    // Строка слитой B — вдвое длиннее: [B_gate | 0] сверху, [0 | B_proj] снизу.
                    var buf = Data(count: 2 * rows * 2 * rowBytes)
                    buf.withUnsafeMutableBytes { dst in
                        data.withUnsafeBytes { src in
                            for i in 0..<rows {
                                dst.baseAddress!.advanced(by: i * 2 * rowBytes).copyMemory(
                                    from: src.baseAddress!.advanced(by: gate.lowerBound + i * rowBytes),
                                    byteCount: rowBytes)
                                dst.baseAddress!.advanced(by: (rows + i) * 2 * rowBytes + rowBytes).copyMemory(
                                    from: src.baseAddress!.advanced(by: proj.lowerBound + i * rowBytes),
                                    byteCount: rowBytes)
                            }
                        }
                    }
                    try fh.write(contentsOf: buf)
                }
            }
            try fh.synchronize()
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        let expected = Int64(8 + headerOut.count + offset)
        let written = ((try? fm.attributesOfItem(atPath: temp.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard written == expected else {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
        try? fm.removeItem(at: output)
        try fm.moveItem(at: temp, to: output)
        return Summary(tensorsIn: tensors.count, tensorsOut: out.count, fusedBlocks: fused,
                       bytesOut: expected)
    }
}
