//
//  ImageBench.swift
//  PocketAgent / Bench
//
//  УДАЛЁННЫЙ ЗАМЕР КАРТИНОК: приложение запускают с Мака, оно само рисует серию
//  картинок с заданными настройками и кладёт журналы, картинки и числа файлами.
//  Человек в это время ничего не нажимает.
//
//  ЗАЧЕМ. Владелец: «айфон в твоем распоряжении — делай
//  тесты, проверяй гипотезы». Гипотезы ускорения (Q8_0 вместо Q4_K_S, переменные
//  движка, держать ли модель открытой, холодный телефон против горячего) проверяются
//  только числом на ЕГО телефоне: на мини (M1) другой видеочип, и там ответ не тот.
//
//  КАК ЗАПУСКАТЬ — `tools/phone-image-bench.sh` (из контейнера). Вручную:
//
//      # 1) положить план на телефон
//      xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer \
//          --domain-identifier pocket-agent --source plan.json \
//          --destination "Library/Application Support/ImageGen/bench/<имя>.json"
//      # 2) запустить
//      xcrun devicectl device process launch --device <UDID> --terminate-existing \
//          pocket-agent -paImageBench <имя>
//      # 3) ждать файл bench-out/<имя>/DONE и забрать папку bench-out/<имя>
//
//  Запасной путь для плана — переменная окружения PA_IMAGE_BENCH_PLAN_B64 (план
//  в base64): если `copy to` не сможет создать папку на свежей установке.
//
//  ⚠️ ИТОГИ ЛЕЖАТ В `bench-out`, А НЕ РЯДОМ С ПЛАНОМ. Первый живой прогон 24.09.2026:
//  папки итогов bench/q8a на телефоне не оказалось вовсе, хотя замер шёл, — папку `bench`
//  создаёт и переписывает `devicectl copy to`, и нашу подпапку в ней стёрло. Теперь
//  `bench/` — только для планов, а свою папку приложение заводит само и больше никто её
//  не трогает. Не создалась — это пишется в системный журнал и на экран, а не глотается.
//
//  ЧТО ПОЛУЧАЕТСЯ в `ImageGen/bench-out/<имя>/`:
//    run-NN.log      — журнал движка целиком (тот же, что last-run.log)
//    run-NN.png      — картинка (проверить глазами, что не белая и не мусор)
//    results.jsonl   — по строке на картинку: настройки, секунды, нагрев, память
//    progress.txt    — где замер сейчас (читается снаружи, пока идёт)
//    DONE            — последний файл: итог замера. Пока его нет — замер идёт.
//
//  ⚠️ ПРИЛОЖЕНИЕ ДОЛЖНО БЫТЬ НА ЭКРАНЕ: видеочип в фоне iOS не даёт. Экран не гаснет
//  (isIdleTimerDisabled), но если телефон свернут руками — прогон помечается.
//
//  ⚠️ ЧАТ-МОДЕЛЬ В ЗАМЕРЕ НЕ ГРУЗИТСЯ, если план сам этого не попросил ("chat":
//  "release" / "keep"). Обычный запуск поднимает её сам (`AppViewModel.start`), а здесь
//  экран чата не создаётся вовсе. Грузилась ли она хоть раз за замер — пишется в каждую
//  строку results.jsonl и в DONE.
//
//  ⚠️ Только отладочная сборка, как и замер помощника (BenchMode.swift).
//

#if DEBUG

import Combine
import Foundation
import SwiftUI
import UIKit
import os

// MARK: - Выключатель

enum ImageBenchMode {

    /// Имя плана из аргумента `-paImageBench <имя>` или переменной PA_IMAGE_BENCH.
    /// Только буквы, цифры, «-», «_», «.» — имя становится именем папки.
    static let planName: String? = {
        let raw = UserDefaults.standard.string(forKey: "paImageBench")
            ?? ProcessInfo.processInfo.environment["PA_IMAGE_BENCH"]
        guard let raw, !raw.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let clean = String(raw.unicodeScalars.filter { allowed.contains($0) })
        return clean.isEmpty || clean.hasPrefix(".") ? nil : clean
    }()

    static var isEnabled: Bool { planName != nil }

    /// `Library/Application Support/ImageGen/bench` — сюда кладут планы.
    static var root: URL? {
        ImageGenEngine.lastRunLogURL?.deletingLastPathComponent()
            .appendingPathComponent("bench", isDirectory: true)
    }

    /// `Library/Application Support/ImageGen/bench-out` — сюда замер пишет итоги.
    static var outRoot: URL? {
        ImageGenEngine.lastRunLogURL?.deletingLastPathComponent()
            .appendingPathComponent("bench-out", isDirectory: true)
    }
}

// MARK: - План

struct ImageBenchPlan: Decodable {

    /// Что делать с чат-моделью: "off" — не грузить вовсе (по умолчанию); "release" —
    /// загрузить и выгрузить перед картинками, как делает экран «Картинки»; "keep" —
    /// загрузить и ДЕРЖАТЬ во время картинок (проверка «две модели в памяти»).
    var chat: String?
    /// Сколько ждать остывания телефона по умолчанию, секунд.
    var cooldownTimeoutSeconds: Double?
    /// Сколько терпеть загрузку без единого нового байта, секунд (по умолчанию 600).
    var downloadStallSeconds: Double?
    var downloads: [Download]?
    var runs: [Run]
    /// Микрозамер матричных блоков A19. Есть — идёт до
    /// картинок; `runs` при этом может быть пустым.
    var naBench: NABenchConfig?

    struct Download: Decodable {
        /// Ссылка вида https://huggingface.co/<автор>/<репо>/resolve/<версия>/<путь>.
        var url: String
        var sha256: String?
        /// Имя в папке моделей картинок (QwenImage21). Пусто — имя из ссылки.
        var fileName: String?
        /// Размер в байтах. Пусто — спросим у сервера.
        var bytes: Int64?
    }

    struct Run: Decodable {
        var label: String?
        /// Семейство (`ImageModelRegistry`), по умолчанию qwen-image-2.1.
        var family: String?
        /// "turbo" (v0.1, 4 шага) · "lora" (турбо v0.2.1) · "normal" · "precise".
        var mode: String?
        /// Файл рисующей части в папке семейства (например qwen_image_2.1_turbo_Q8_0.gguf).
        var dit: String?
        var width: Int?
        var height: Int?
        var steps: Int?
        var prompt: String?
        var seed: Int64?
        var repeats: Int?
        /// Переменные движка поверх обычных. "" — снять переменную.
        var env: [String: String]?
        /// Ждать, пока телефон остынет до «нормально», перед каждой картинкой.
        var cooldown: Bool?
        var cooldownTimeoutSeconds: Double?
        /// Держать модель открытой между повторами (по умолчанию да, как экран).
        var keepContext: Bool?
        /// Закрыть модель перед первым повтором — честный «первый запуск».
        var freshContext: Bool?
        /// Черновик по шагам, как на экране (по умолчанию да).
        var preview: Bool?
        /// Пауза перед каждой картинкой, секунд.
        var pauseSeconds: Double?
        /// Вместо картинки — «Проверить ядро»: отчёт
        /// в `kernel-NN.log`, итог строкой в results.jsonl. `env` действует на время проверки
        /// (PA_KERNEL_BENCH_MODES, PA_KERNEL_BENCH_TYPES, GGML_METAL_NAXA_SWZ …); остальные поля
        /// прогона не нужны. Без этого проверку можно было запустить только кнопкой.
        var kernelCheck: Bool?

        enum CodingKeys: String, CodingKey {
            case label, family, mode, dit, width, height, steps, prompt, seed
            case repeats = "repeat"
            case env, cooldown, cooldownTimeoutSeconds, keepContext, freshContext, preview, pauseSeconds
            case kernelCheck
        }
    }

    /// Разобрать план. `defaults` (если есть) подмешивается в каждый прогон;
    /// `env` — слиянием, а не заменой.
    static func parse(_ data: Data) throws -> ImageBenchPlan {
        guard var top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlanError("план — не объект JSON")
        }
        let defaults = top["defaults"] as? [String: Any] ?? [:]
        let runs = top["runs"] as? [[String: Any]] ?? []
        guard !runs.isEmpty || top["naBench"] is [String: Any] else {
            throw PlanError("в плане нет ни одного прогона (runs) и нет naBench")
        }
        top["runs"] = runs.map { run -> [String: Any] in
            var merged = defaults.merging(run) { $1 }
            if let a = defaults["env"] as? [String: Any], let b = run["env"] as? [String: Any] {
                merged["env"] = a.merging(b) { $1 }
            }
            return merged
        }
        top.removeValue(forKey: "defaults")
        let clean = try JSONSerialization.data(withJSONObject: top)
        return try JSONDecoder().decode(ImageBenchPlan.self, from: clean)
    }

    struct PlanError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}

// MARK: - Прогон

@MainActor
final class ImageBenchRunner: ObservableObject {

    @Published private(set) var title = "Замер картинок"
    @Published private(set) var line = "Готовлюсь…"
    @Published private(set) var log: [String] = []
    @Published private(set) var lastImage: UIImage?
    @Published private(set) var isDone = false
    @Published private(set) var failed = false

    private var outDir: URL?
    private var chatWatch: AnyCancellable?
    /// Грузилась ли чат-модель хоть раз за замер (фаза «грузится» или «готова»).
    private var chatEverLoaded = false
    private var chatEvents: [String] = []
    private var backgroundCount = 0
    private var backgroundWatch: NSObjectProtocol?
    /// Переменные окружения процесса до замера — чтобы вернуть снятые подмены.
    private let originalEnv = ProcessInfo.processInfo.environment
    private var appliedEnvKeys: Set<String> = []

    private static let liveLog = Logger(subsystem: "com.example.pocket-agent", category: "image-bench")
    private static let gib = 1_073_741_824.0

    func run(assembly: AgentAssembly) async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let name = ImageBenchMode.planName, let root = ImageBenchMode.root,
              let outRoot = ImageBenchMode.outRoot else { return }
        title = "Замер картинок «\(name)»"
        let dir = outRoot.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        // Прошлые итоги под тем же именем стираем: иначе DONE прошлого прогона
        // скрипт снаружи принял бы за сегодняшний.
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            outDir = dir
        } catch {
            // Молча глотать нельзя: без папки замер идёт вслепую — снаружи ни строки.
            say("❌ папка итогов \(dir.path) не создалась: \(error)")
        }
        writeText("STARTED", ISO8601DateFormatter().string(from: Date()) + "\n")
        writeText("progress.txt", "старт\n")
        say("Итоги: ImageGen/bench-out/\(name)/")

        let app = assembly.viewModel
        chatWatch = app.$modelStatus.sink { [weak self] status in
            MainActor.assumeIsolated { self?.noteChat(status) }
        }
        backgroundWatch = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.backgroundCount += 1
                    self?.say("⚠️ приложение свернули — видеочип в фоне не работает")
                }
            }
        say("Старт. Сборка \(Self.buildNumber). Чат-модель сейчас: \(app.chatModelNoteForImageLog)")
        snap("старт замера")

        let plan: ImageBenchPlan
        do {
            plan = try loadPlan(name: name, root: root)
        } catch {
            finish(ok: false, runs: 0, failures: 0, note: "план не прочитан: \(error)")
            return
        }
        say("План: прогонов \(plan.runs.count), картинок \(plan.runs.reduce(0) { $0 + max(1, $1.repeats ?? 1) })")

        // Микрозамер матричных блоков — до картинок и загрузок: ему ничего не нужно.
        var naExtra: [String: Any] = [:]
        if let na = plan.naBench {
            naExtra = await runNABench(na)
            if plan.runs.isEmpty {
                let bad = (naExtra["failures"] as? Int ?? 0) + (naExtra["wrongResults"] as? Int ?? 0)
                finish(ok: naExtra["error"] == nil, runs: 0, failures: bad,
                       note: "замер нейроблоков: замеров \(naExtra["rows"] ?? 0), ошибок \(naExtra["failures"] ?? 0), "
                           + "неверных \(naExtra["wrongResults"] ?? 0)", extra: ["naBench": naExtra])
                return
            }
        }

        // Загрузки — до всякого рисования.
        for d in plan.downloads ?? [] {
            await download(d, stallLimit: plan.downloadStallSeconds ?? 600)
        }

        // Чат-модель — только если план попросил.
        let chatMode = (plan.chat ?? "off").lowercased()
        if chatMode == "release" || chatMode == "keep" {
            say("Чат-модель: гружу (режим «\(chatMode)»)")
            app.prepareModel()
            let loaded = await waitChatReady(timeout: 300)
            say(loaded ? "Чат-модель в памяти" : "⚠️ чат-модель не поднялась за 5 мин: \(app.chatModelNoteForImageLog)")
        } else {
            say("Чат-модель не грузим (режим «off»)")
        }

        var index = 0
        var failures = 0
        let engine = ImageGenEngine.shared
        for (runNo, run) in plan.runs.enumerated() {
            let repeats = max(1, run.repeats ?? 1)
            for rep in 0..<repeats {
                index += 1
                let ok = run.kernelCheck == true
                    ? await kernelCheck(run: run, index: index, plan: plan)
                    : await one(run: run, runNo: runNo, rep: rep, index: index, plan: plan,
                                chatMode: chatMode, app: app)
                if !ok { failures += 1 }
            }
        }
        engine.setOverrides(.init())
        restoreEnv(keeping: [])
        engine.releaseContext(reason: "замер закончен")
        finish(ok: failures == 0, runs: index, failures: failures,
               note: failures == 0 ? "все картинки нарисованы" : "с ошибками: \(failures)",
               extra: naExtra.isEmpty ? [:] : ["naBench": naExtra])
    }

    // MARK: Микрозамер матричных блоков

    /// Гоняет NABench на фоновом потоке (замер синхронный и долгий), журнал — на экран,
    /// в bench.log и progress.txt. Файлы na-* пишет сам NABench в папку итогов.
    private func runNABench(_ cfg: NABenchConfig) async -> [String: Any] {
        say("Замер нейроблоков A19 (NABench): старт")
        writeText("progress.txt", "замер нейроблоков: старт\n")
        let dir = outDir
        let result: [String: Any] = await Task.detached(priority: .userInitiated) {
            let bench = NABench(config: cfg, outDir: dir, log: { text in
                Task { @MainActor in ImageBenchRunner.current?.say("[NA] " + text) }
            }, progress: { text in
                Task { @MainActor in
                    ImageBenchRunner.current?.writeText("progress.txt", "замер нейроблоков: " + text + "\n")
                    ImageBenchRunner.current?.line = text
                }
            })
            return bench.run()
        }.value
        // Сводку целиком не тащим в DONE — только счётчики и вердикты.
        var extra: [String: Any] = [:]
        for key in ["failures", "wrongResults", "rows", "seconds"] { extra[key] = result[key] }
        if let summary = result["summary"] as? [String: Any] {
            if let e = summary["error"] { extra["error"] = e }
            if let peaks = summary["peaks"] as? [String: Any] {
                extra["verdicts"] = peaks.mapValues { ($0 as? [String: Any])?["verdict"] ?? "" }
            }
        }
        return extra
    }

    // MARK: Проверка ядра

    /// Прогон с `"kernelCheck": true`: та же «Проверить ядро», что по кнопке, но из плана —
    /// чтобы сравнить режимы ядра умножения (GGML_METAL_NAX 0..7: 3..6 — инженер A, 7 — инженер B) без рук владельца.
    /// Модель картинок закрывается (у проверки свой контекст видеочипа), отчёт — `kernel-NN.log`.
    /// Провал — только когда проверка сама сказала «НЕВЕРНО» или «уронило видеочип».
    private func kernelCheck(run: ImageBenchPlan.Run, index: Int, plan: ImageBenchPlan) async -> Bool {
        let nn = String(format: "%02d", index)
        let engine = ImageGenEngine.shared
        var row: [String: Any] = ["run": index, "label": run.label ?? "", "kernelCheck": true,
                                  "time": ISO8601DateFormatter().string(from: Date())]
        let env = run.env ?? [:]
        restoreEnv(keeping: Set(env.keys))
        appliedEnvKeys = Set(env.keys)
        for (name, value) in env.sorted(by: { $0.key < $1.key }) {
            if value.isEmpty { unsetenv(name) } else { setenv(name, value, 1) }
        }
        row["env"] = env
        engine.releaseContext(reason: "замер: проверка ядра")
        // Нагретый телефон сбавляет частоту — режимы ядра сравниваем только холодными.
        if run.cooldown == true {
            row["cooldownWaitSeconds"] = await coolDown(
                timeout: run.cooldownTimeoutSeconds ?? plan.cooldownTimeoutSeconds ?? 600, nn: nn)
        }
        row["thermalBefore"] = Self.heat()
        guard engine.reserve() else {
            say("❌ \(nn): проверка ядра — движок занят")
            row["error"] = "движок занят"
            appendResult(row)
            return false
        }
        say("\(nn): проверка ядра…")
        let started = Date()
        let line = await Task.detached(priority: .userInitiated) { () -> String in
            let l = ImageGenEngine.shared.checkKernel()
            ImageGenEngine.shared.release()
            return l
        }.value
        row["seconds"] = Date().timeIntervalSince(started)
        row["thermalAfter"] = Self.heat()
        row["summary"] = line
        if let dir = outDir, let src = ImageGenEngine.kernelCheckLogURL {
            let dst = dir.appendingPathComponent("kernel-\(nn).log")
            try? FileManager.default.removeItem(at: dst)
            do {
                try FileManager.default.copyItem(at: src, to: dst)
            } catch {
                say("⚠️ \(nn): отчёт проверки не скопировался: \(error)")
            }
        }
        appendResult(row)
        say("\(nn): \(line)")
        return !line.contains("НЕВЕРНО") && !line.contains("уронило")
    }

    // MARK: Одна картинка

    private func one(run: ImageBenchPlan.Run, runNo: Int, rep: Int, index: Int,
                     plan: ImageBenchPlan, chatMode: String, app: AppViewModel) async -> Bool {
        let nn = String(format: "%02d", index)
        let engine = ImageGenEngine.shared
        var row: [String: Any] = ["run": index, "planRun": runNo + 1, "repeat": rep + 1,
                                  "label": run.label ?? "", "time": ISO8601DateFormatter().string(from: Date())]
        func fail(_ text: String) -> Bool {
            say("❌ \(nn): \(text)")
            row["error"] = text
            row["chatEverLoaded"] = chatEverLoaded
            appendResult(row)
            snap("ошибка \(nn)")
            return false
        }

        guard let family = ImageModelRegistry.family(id: run.family ?? ImageModelRegistry.qwenImage21.id) else {
            return fail("нет семейства «\(run.family ?? "")»")
        }
        let mode = (run.mode ?? (family.turbo != nil ? "turbo" : "normal")).lowercased()
        let preset = family.preset(mode == "precise" ? .max : .normal)
        let defaultSteps: Int
        switch mode {
        case "turbo": defaultSteps = family.turbo?.steps ?? preset.steps
        case "lora": defaultSteps = family.turboLoRA?.steps ?? preset.steps
        default: defaultSteps = preset.steps
        }
        let width = run.width ?? preset.baseSide
        let height = run.height ?? run.width ?? preset.baseSide
        let steps = run.steps ?? defaultSteps
        let prompt = run.prompt ?? "Рыжий кот сидит на подоконнике, за окном вечерний город"
        let seed = run.seed ?? 42
        let env = run.env ?? [:]

        var ditURL: URL?
        if let dit = run.dit, !dit.isEmpty {
            guard let url = try? ModelStorage.modelsDirectory()
                .appendingPathComponent(dit.contains("/") ? dit : "\(family.folderName)/\(dit)"),
                  FileManager.default.fileExists(atPath: url.path) else {
                return fail("нет файла рисующей части «\(dit)» в папке \(family.folderName)")
            }
            ditURL = url
        }
        row.merge(["family": family.id, "mode": mode, "dit": run.dit ?? "", "width": width,
                   "height": height, "steps": steps, "prompt": prompt, "seed": seed, "env": env,
                   "keepContext": run.keepContext ?? true]) { $1 }

        // Подмены: снятые с прошлого прогона — вернуть как были до замера.
        restoreEnv(keeping: Set(env.keys))
        appliedEnvKeys = Set(env.keys)
        engine.setOverrides(.init(diffusionURL: ditURL, env: env))

        if (rep == 0 && run.freshContext == true) || (rep > 0 && run.keepContext == false) {
            engine.releaseContext(reason: "замер: свежий контекст")
            say("\(nn): модель закрыта — откроется заново")
        }
        if let pause = run.pauseSeconds, pause > 0 {
            say("\(nn): пауза \(Int(pause)) с")
            try? await Task.sleep(nanoseconds: UInt64(pause * 1e9))
        }
        var waited = 0.0
        if run.cooldown == true {
            waited = await coolDown(timeout: run.cooldownTimeoutSeconds ?? plan.cooldownTimeoutSeconds ?? 600, nn: nn)
        }
        row["cooldownWaitSeconds"] = (waited * 10).rounded() / 10
        row["thermalBefore"] = Self.heat()
        row["footprintBeforeGB"] = Self.gb(ProcessMemory.footprintBytes())
        row["availableBeforeGB"] = Self.gb(ProcessMemory.availableBytes())
        let backgroundBefore = backgroundCount

        var request = ImageGenRequest(prompt: prompt, width: width, height: height, steps: steps,
                                      seed: seed, preciseWeights: mode == "precise", references: [],
                                      familyID: family.id)
        request.useTurbo = mode == "turbo"
        request.useTurboLoRA = mode == "lora"

        say("\(nn): \(run.label ?? mode) \(width)×\(height), \(steps) шагов, "
            + "\(run.dit ?? "файл по умолчанию"), нагрев \(Self.heat())")
        writeText("progress.txt", "\(nn) идёт: \(run.label ?? mode) \(width)×\(height) \(steps) шагов\n")
        snap("прогон \(nn)")

        guard engine.reserve() else { return fail("движок занят") }
        // Как на экране «Картинки»: чат-модель отпускаем перед рисованием — кроме «keep».
        if chatMode != "keep" { await app.releaseChatModelForImages() }
        let chatNote = app.chatModelNoteForImageLog
        engine.setChatModelNote(chatNote + " (замер, режим «\(chatMode)»)")
        row["chatModelAtStart"] = chatNote

        // Черновик по шагам движок считает на процессоре — как на экране, по умолчанию включён.
        var previewSink: (@Sendable (ImageGenPixels) -> Void)?
        if run.preview ?? true { previewSink = { (_: ImageGenPixels) in } }
        let wallStart = Date()
        let req = request
        let sink = previewSink
        let outcome: Result<ImageGenResult, Error> = await Task.detached(priority: .userInitiated) {
            Result {
                try engine.generate(req, onPreview: sink) { step, of in
                    Task { @MainActor in
                        ImageBenchRunner.current?.line = "\(nn): шаг \(step) из \(of)"
                    }
                }
            }
        }.value
        engine.release()
        row["wallSeconds"] = Self.round1(Date().timeIntervalSince(wallStart))
        row["thermalAfter"] = Self.heat()
        row["footprintAfterGB"] = Self.gb(ProcessMemory.footprintBytes())
        row["backgrounded"] = backgroundCount - backgroundBefore
        row["chatEverLoaded"] = chatEverLoaded
        row["chatModelAfter"] = app.chatModelNoteForImageLog

        // Журнал движка — каким бы ни был исход.
        if let dir = outDir, let src = ImageGenEngine.lastRunLogURL {
            let dst = dir.appendingPathComponent("run-\(nn).log")
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            row["log"] = dst.lastPathComponent
        }

        switch outcome {
        case .failure(let error):
            let e = (error as? ImageGenError) ?? .failed(detail: String(describing: error))
            row["errorDetail"] = e.detail ?? ""
            return fail(e.humanText)
        case .success(let r):
            row.merge(["diffusionName": r.diffusionName,
                       "prepareSeconds": Self.round1(r.prepareSeconds),
                       "stepSeconds": r.stepSeconds.map(Self.round1),
                       "decodeSeconds": Self.round1(r.decodeSeconds),
                       "totalSeconds": Self.round1(r.totalSeconds),
                       "contextReused": r.contextReused,
                       "contextOpenSeconds": Self.round1(r.contextOpenSeconds),
                       "promptFromCache": r.promptFromCache,
                       "peakFootprintGB": Self.gb(r.peakFootprintBytes),
                       "minAvailableGB": Self.gb(r.minAvailableBytes),
                       "seedUsed": r.seed]) { $1 }
            let stats = Self.pixelStats(r.image)
            let blank = stats.stddev < 3
            row["image"] = ["mean": Self.round1(stats.mean), "stddev": Self.round1(stats.stddev),
                            "blank": blank, "width": r.image.width, "height": r.image.height]
            let image = ImageStudioModel.image(from: r.image)
            lastImage = image
            if let dir = outDir, let png = image?.pngData() {
                try? png.write(to: dir.appendingPathComponent("run-\(nn).png"), options: .atomic)
                row["png"] = "run-\(nn).png"
            }
            appendResult(row)
            say(String(format: "✅ %@: всего %.1f с (подготовка %.1f · шаги %@ · проявка %.1f)%@",
                       nn, r.totalSeconds, r.prepareSeconds,
                       r.stepSeconds.map { String(format: "%.1f", $0) }.joined(separator: "/"),
                       r.decodeSeconds, blank ? " · ⚠️ картинка пустая" : ""))
            snap("картинка \(nn)")
            return !blank
        }
    }

    /// Ссылка на идущий замер — для строки шагов с потока движка.
    static weak var current: ImageBenchRunner?

    // MARK: План, загрузки, остывание

    private func loadPlan(name: String, root: URL) throws -> ImageBenchPlan {
        let file = root.appendingPathComponent("\(name).json")
        if let data = try? Data(contentsOf: file) {
            say("План из файла \(file.lastPathComponent)")
            return try ImageBenchPlan.parse(data)
        }
        if let b64 = ProcessInfo.processInfo.environment["PA_IMAGE_BENCH_PLAN_B64"],
           let data = Data(base64Encoded: b64) {
            say("План из переменной окружения")
            // Копию — рядом с итогами, чтобы по папке было видно, что именно мерили.
            try? data.write(to: file, options: .atomic)
            return try ImageBenchPlan.parse(data)
        }
        throw ImageBenchPlan.PlanError("нет файла bench/\(name).json и нет PA_IMAGE_BENCH_PLAN_B64")
    }

    private func download(_ d: ImageBenchPlan.Download, stallLimit: Double) async {
        guard let url = URL(string: d.url), url.host == "huggingface.co" else {
            say("❌ загрузка: понимаю только ссылки huggingface.co — \(d.url)")
            return
        }
        // /<автор>/<репо>/resolve/<версия>/<путь внутри репо>
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 5, parts[2] == "resolve" else {
            say("❌ загрузка: ссылка не вида …/resolve/<версия>/<файл> — \(d.url)")
            return
        }
        let repo = parts[0] + "/" + parts[1]
        let revision = parts[3]
        let repoPath = parts[4...].joined(separator: "/")
        let fileName = d.fileName ?? (repoPath as NSString).lastPathComponent
        var bytes = d.bytes ?? 0
        if bytes <= 0 { bytes = await Self.remoteSize(url) }
        guard bytes > 0 else {
            say("❌ загрузка \(fileName): сервер не назвал размер — впишите bytes в план")
            return
        }
        let part = ModelDescriptor(
            id: "image-bench-\(fileName)", displayName: fileName, repoID: repo, repoCommit: revision,
            fileName: "\(ImageModelCatalog.folderName)/\(fileName)", byteSize: bytes,
            sha256: d.sha256 ?? "", summary: "Файл для замера картинок.", repoPath: repoPath)
        if let local = try? ModelStorage.fileURL(for: part), ModelStorage.byteSize(of: local) == bytes {
            say("Загрузка \(fileName): уже на телефоне")
            return
        }
        if ModelDownloader.shared.isDownloading {
            say("❌ загрузка \(fileName): загрузчик занят другой моделью")
            return
        }
        say("Качаю \(fileName) (\(HumanFormat.bytes(bytes))). Недокачанное лежит в "
            + "Models/\(part.id).partial, а не в папке \(ImageModelCatalog.folderName)")
        writeText("progress.txt", "качаю \(fileName): 0 из \(HumanFormat.bytes(bytes))\n")
        let started = Date()
        let partialURL = try? ModelDownloadPlanStore.partialURL(for: part.id)
        // Прошлый запуск мог оставить собранное — оно продолжится; скорость считаем по приросту.
        let base = partialURL.map(ModelStorage.byteSize(of:)) ?? 0
        if base > 0 { say("Продолжаю: уже собрано \(HumanFormat.bytes(base))") }
        downloadBytes = 0
        downloadDiskBytes = base
        downloadMovedAt = started
        do {
            try ImageModelCatalog.ensureFolder(ImageModelRegistry.qwenImage21)
            // Загрузка — в отдельной задаче: пока она идёт, здесь сторожим ход и пишем
            // байты и скорость. ⚠️ Раньше на экране висело «0%» по шесть минут: 1% файла
            // в 7,6 ГБ — это 76 МБ, а при 0,2 МБ/с до первого процента четыре минуты.
            // Загрузка шла, а выглядела мёртвой (живой прогон 24.09.2026).
            let total = Double(bytes)
            let work = Task { () throws -> URL in
                try await ModelDownloader.shared.download(part) { p in
                    let got = Int64(p * total)
                    Task { @MainActor in ImageBenchRunner.current?.noteDownload(got) }
                }
            }
            downloadFinished = false
            Task { @MainActor [weak self] in
                _ = try? await work.value
                self?.downloadFinished = true
            }
            var lastReport = started
            var stalled = false
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if downloadFinished { break }
                let now = Date()
                // С диска — тоже: загрузчик сообщает ход не всегда часто, а собранные
                // куски лежат в .partial и растут независимо от сообщений.
                let onDisk = partialURL.map(ModelStorage.byteSize(of:)) ?? 0
                if onDisk > downloadDiskBytes { downloadDiskBytes = onDisk; downloadMovedAt = now }
                let got = max(downloadBytes, downloadDiskBytes)
                let secs = now.timeIntervalSince(started)
                let speed = secs > 0 ? Double(max(0, got - base)) / secs : 0
                let text = String(format: "Качаю %@: %@ из %@ · %.2f МБ/с · %.0f с",
                                  fileName, HumanFormat.bytes(got), HumanFormat.bytes(bytes),
                                  speed / 1_048_576, secs)
                line = text
                if now.timeIntervalSince(lastReport) >= 30 {
                    lastReport = now
                    writeText("progress.txt", text + "\n")
                    say(text)
                }
                if now.timeIntervalSince(downloadMovedAt) > stallLimit {
                    stalled = true
                    work.cancel()   // загрузчик считает это паузой — скачанное не пропадёт
                    _ = try? await work.value
                    break
                }
            }
            if stalled {
                say("❌ загрузка \(fileName): \(Int(stallLimit)) с ни одного нового байта — останавливаю. "
                    + "Скачано \(HumanFormat.bytes(max(downloadBytes, downloadDiskBytes))), "
                    + "следующий запуск продолжит с того же места")
                return
            }
            let done = try await work.value
            say(String(format: "Скачано \(fileName) за %.0f с", Date().timeIntervalSince(started)))
            // С официального адреса загрузчик сумму не сверяет (это делает подготовка
            // чат-модели) — сверяем сами, если план её дал.
            if let sha = d.sha256, !sha.isEmpty {
                say("Сверяю сумму \(fileName)…")
                writeText("progress.txt", "сверяю сумму \(fileName)\n")
                let size = bytes
                let hex = try await Task.detached { try ModelVerifier.checksum(done, expectedBytes: size) }.value
                if hex.caseInsensitiveCompare(sha) == .orderedSame {
                    say("Сумма \(fileName) сошлась")
                } else {
                    try? FileManager.default.removeItem(at: done)
                    say("❌ сумма \(fileName) НЕ сошлась — файл стёрт")
                }
            }
        } catch {
            say("❌ загрузка \(fileName) оборвалась: \(error)")
        }
    }

    private var downloadFinished = false
    private var downloadBytes: Int64 = 0
    private var downloadDiskBytes: Int64 = 0
    private var downloadMovedAt = Date()

    fileprivate func noteDownload(_ got: Int64) {
        guard got > downloadBytes else { return }
        downloadBytes = got
        downloadMovedAt = Date()
    }

    /// Размер файла у сервера (запрос заголовков). 0 — не назвал.
    private static func remoteSize(_ url: URL) async -> Int64 {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 30
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return 0 }
        if let linked = http.value(forHTTPHeaderField: "X-Linked-Size").flatMap(Int64.init) { return linked }
        return max(0, http.expectedContentLength)
    }

    /// Ждать, пока телефон остынет до «нормально». Возвращает, сколько ждали.
    private func coolDown(timeout: Double, nn: String) async -> Double {
        let started = Date()
        guard ProcessInfo.processInfo.thermalState != .nominal else { return 0 }
        say("\(nn): жду остывания (сейчас \(Self.heat()), не дольше \(Int(timeout)) с)")
        while ProcessInfo.processInfo.thermalState != .nominal,
              Date().timeIntervalSince(started) < timeout {
            line = "\(nn): остываю — \(Self.heat()), \(Int(Date().timeIntervalSince(started))) с"
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let waited = Date().timeIntervalSince(started)
        say("\(nn): ждал \(Int(waited)) с, нагрев \(Self.heat())")
        return waited
    }

    private func waitChatReady(timeout: Double) async -> Bool {
        let app = ImageBenchRunner.appRef
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if case .ready = app?.modelStatus { return true }
            if case .failed = app?.modelStatus { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    static weak var appRef: AppViewModel?

    // MARK: Чат-модель, переменные

    private func noteChat(_ status: ModelRuntimeStatus) {
        let phase = status.phase
        if phase == .loading || phase == .ready {
            if !chatEverLoaded { say("⚠️ чат-модель: \(phase.rawValue) — она в памяти во время замера") }
            chatEverLoaded = true
        }
        if chatEvents.last != phase.rawValue { chatEvents.append(phase.rawValue) }
    }

    /// Вернуть переменные, подменённые прошлым прогоном и не нужные этому.
    private func restoreEnv(keeping: Set<String>) {
        for key in appliedEnvKeys.subtracting(keeping) {
            if let v = originalEnv[key] { setenv(key, v, 1) } else { unsetenv(key) }
        }
    }

    // MARK: Файлы и журнал

    private func finish(ok: Bool, runs: Int, failures: Int, note: String, extra: [String: Any] = [:]) {
        failed = !ok
        isDone = true
        say(ok ? "Замер закончен: \(note)" : "❌ Замер: \(note)")
        snap("конец замера")
        var done: [String: Any] = [
            "ok": ok, "runs": runs, "failures": failures, "note": note,
            "chatEverLoaded": chatEverLoaded, "chatPhases": chatEvents,
            "backgrounded": backgroundCount, "build": Self.buildNumber,
            "finishedAt": ISO8601DateFormatter().string(from: Date())
        ]
        done.merge(extra) { $1 }
        writeText("progress.txt", "конец: \(note)\n")
        writeText("bench.log", log.joined(separator: "\n") + "\n")
        if let data = try? JSONSerialization.data(withJSONObject: done, options: [.prettyPrinted, .sortedKeys]) {
            // DONE — последним: снаружи его появление значит «всё остальное уже на месте».
            writeText("DONE", String(decoding: data, as: UTF8.self) + "\n")
        }
        chatWatch = nil
        if let w = backgroundWatch { NotificationCenter.default.removeObserver(w) }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("com.example.pocket-agent.imagebench.finished" as CFString),
                                             nil, nil, true)
    }

    private func appendResult(_ row: [String: Any]) {
        guard let dir = outDir,
              let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        let url = dir.appendingPathComponent("results.jsonl")
        var line = data
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    fileprivate func writeText(_ name: String, _ text: String) {
        guard let dir = outDir else { return }
        do {
            try Data(text.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
        } catch where !writeFailureShown {
            // Один раз — на экран и в системный журнал (не через `say`: он сам пишет файл).
            writeFailureShown = true
            let msg = "❌ не записался \(name) в \(dir.path): \(error)"
            log.append(msg)
            line = msg
            Self.liveLog.error("[замер картинок] \(msg, privacy: .public)")
        } catch {}
    }

    private var writeFailureShown = false

    private func snap(_ label: String) {
        RemoteSnapshot.take(label: label)
    }

    fileprivate func say(_ text: String) {
        line = text
        log.append(text)
        if log.count > 400 { log.removeFirst(log.count - 400) }
        print("[замер картинок] \(text)")
        Self.liveLog.notice("[замер картинок] \(text, privacy: .public)")
        // Журнал замера на диске — по ходу, а не только в конце: оборванный прогон
        // тоже должен что-то рассказать.
        writeText("bench.log", log.joined(separator: "\n") + "\n")
    }

    // MARK: Мелочи

    static func heat() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "нормально"
        case .fair: return "тёплый"
        case .serious: return "горячий"
        case .critical: return "критично"
        @unknown default: return "?"
        }
    }

    private static func gb(_ v: UInt64) -> Double { (Double(v) / gib * 100).rounded() / 100 }
    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    private static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// Среднее и разброс яркости по каналам цвета (без прозрачности). Разброс около
    /// нуля — картинка одного цвета: белая, чёрная или серая, то есть сбой.
    static func pixelStats(_ px: ImageGenPixels) -> (mean: Double, stddev: Double) {
        let ch = max(1, px.channels)
        let colour = min(3, ch)
        var sum = 0.0, sq = 0.0, n = 0.0
        px.bytes.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            let pixels = b.count / ch
            // Каждая четвёртая точка — хватает для разброса, и быстро на 1024².
            var i = 0
            while i < pixels {
                for c in 0..<colour {
                    let v = Double(b[i * ch + c])
                    sum += v; sq += v * v; n += 1
                }
                i += 4
            }
        }
        guard n > 0 else { return (0, 0) }
        let mean = sum / n
        return (mean, max(0, sq / n - mean * mean).squareRoot())
    }

    init() {}

    /// Подключить к приложению: ссылки для колбэков с чужих потоков.
    func attach(_ app: AppViewModel) {
        ImageBenchRunner.current = self
        ImageBenchRunner.appRef = app
    }
}

// MARK: - Экран

/// Экран замера. Служебный, как `BenchRootView`: не для человека, а чтобы со снимка
/// было видно, что идёт и что нарисовалось.
struct ImageBenchRootView: View {

    let assembly: AgentAssembly
    @StateObject private var runner = ImageBenchRunner()
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(runner.isDone ? (runner.failed ? "❌ \(runner.title): с ошибками" : "\(runner.title): закончен")
                               : runner.title)
                .font(.headline)
                .foregroundStyle(runner.failed ? Color.red : Color.primary)
            Text(runner.line)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            if let image = runner.lastImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .frame(maxWidth: .infinity)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(runner.log.enumerated()), id: \.offset) { i, entry in
                            Text(entry)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                }
                .onChange(of: runner.log.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .padding()
        .task {
            guard !started else { return }
            started = true
            runner.attach(assembly.viewModel)
            // Экран не гаснет: погасший экран — фон, а в фоне видеочип не работает.
            UIApplication.shared.isIdleTimerDisabled = true
            await runner.run(assembly: assembly)
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

#endif
