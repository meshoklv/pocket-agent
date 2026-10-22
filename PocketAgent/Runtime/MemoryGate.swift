//
//  MemoryGate.swift
//  PocketAgent / Runtime
//
//  Проверка памяти ПЕРЕД загрузкой весов. Entitlement увеличенного лимита
//  памяти ничего не гарантирует (Apple прямо это пишет), поэтому единственный
//  честный источник — os_proc_available_memory() в рантайме.
//
//  Лучше показать человеку «не хватает памяти», чем получить молчаливый
//  отстрел приложения системой на середине загрузки модели.
//

import Foundation
import os

public enum MemoryGate {

    /// Сколько мегабайт приложение ещё может занять, не будучи убитым системой.
    public static func availableMemoryMB() -> Int {
        #if os(iOS)
        let bytes = os_proc_available_memory()
        // На симуляторе и в некоторых конфигурациях функция возвращает 0 —
        // это «не знаю», а не «памяти нет». Тогда гейт не мешаем.
        guard bytes > 0 else { return Int.max }
        return Int(bytes / (1024 * 1024))
        #else
        // На macOS такой функции нет — считаем, что памяти достаточно.
        return Int.max
        #endif
    }

    /// Сколько всего памяти в устройстве (МБ) — справочно для диагностики.
    public static func physicalMemoryMB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
    }

    /// Хватит ли памяти, чтобы поднять модель хотя бы на CPU.
    public static func canLoad(_ model: ModelDescriptor) -> Bool {
        availableMemoryMB() >= model.cpuMemoryRequirementMB
    }

    /// Хватит ли памяти на GPU-бэкенд. Он просит почти вдвое больше, чем CPU,
    /// поэтому порог для него отдельный: не хватило — идём на CPU, а не падаем.
    public static func canUseGPU(_ model: ModelDescriptor) -> Bool {
        availableMemoryMB() >= model.gpuMemoryRequirementMB
    }

    /// Бросить понятную ошибку, если памяти мало даже под CPU. Зовётся перед созданием Engine.
    /// Читать так: «памяти НЕ хватает» — идём дальше и бросаем; хватает — молча выходим.
    /// - Note: ⚠️ Порог зависит от того, на чём модель вообще способна считать.
    ///   У сборки «только для видеочипа» процессорного пути нет, и мерить её процессорным
    ///   порогом — значит пропустить вперёд заведомо безнадёжный запуск: гейт молчит,
    ///   а движок потом падает с невнятным «не удалось запустить модель». Для такой сборки
    ///   спрашиваем ровно то, что ей нужно, — память видеочипа.
    public static func ensureEnoughMemory(for model: ModelDescriptor) throws {
        let available = availableMemoryMB()
        let required = model.hardware == .gpuOnly
            ? model.gpuMemoryRequirementMB
            : model.cpuMemoryRequirementMB
        guard available < required else { return }

        throw PocketAgentError.notEnoughMemory(availableMB: available,
                                               requiredMB: required)
    }

    /// Совет человеку, что сделать, когда памяти не хватает.
    public static var freeUpMemoryAdvice: String {
        "Закройте другие приложения и попробуйте снова. "
        + "Модель занимает много памяти и загружается один раз за запуск."
    }
}
