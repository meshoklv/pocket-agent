//
//  ReadHistory.swift
//  PocketAgent
//
//  Память о том, какие строки какого файла модель УЖЕ получила в этом разговоре.
//
//  ⚠️ ЗАЧЕМ ЭТО ВООБЩЕ ЕСТЬ. Разобранная переписка с телефона владельца (09.08.2026),
//  файл README.md на 147 строк, три хода подряд:
//      ход 24 — «строки 1–32 из 147»
//      ход 27 — «строки 3–33 из 147»
//      ход 30 — «строки 4–33 из 147»
//  Модель сдвигала начало на одну-две строки вместо перехода на следующую страницу,
//  и почти одно и то же содержимое уезжало в память разговора ТРИ раза. Память —
//  4096 токенов, страница — 700; два лишних повтора съели больше половины окна.
//  Кончилось это «Памяти разговора не хватало — свернул переписку», а задача так
//  и не была сделана. То есть память тратилась не на работу, а на топтание на месте.
//
//  Отсюда правило: одно и то же содержимое второй раз в модель не уходит. Вместо
//  повтора отдаём СЛЕДУЮЩИЙ непрочитанный кусок и одной короткой строкой говорим
//  правду — что начало она уже видела.
//
//  ⚠️ ЭКОНОМИЯ ЗДЕСЬ ВСЕГДА ВТОРАЯ ПО ВАЖНОСТИ. Перечитать файл модель имеет полное
//  право: она сама его только что изменила, или файл поправили снаружи. Поэтому
//  память о прочитанном держится на отпечатке файла (размер + дата) и умирает
//  вместе с ним: изменился файл — забыли всё, что о нём помнили. Отдать устаревший
//  текст страшнее, чем лишний раз заплатить за страницу.
//

import Foundation

/// Что делать с просьбой прочитать файл, часть которого модель уже видела.
public enum ReadAdvice: Equatable, Sendable {

    /// Читать ровно то, о чём просили. Обычный случай.
    case asAsked

    /// Это место уже показано: читать с `from`, а к ответу приписать `note` —
    /// короткое объяснение для модели, почему она получила не то начало, что просила.
    case skipAhead(from: Int, note: String)

    /// Непрочитанного в файле не осталось. `note` — что сказать модели.
    case nothingLeft(note: String)

    /// Модель ходит по кругу: подряд просит только то, что уже прочитано целиком.
    /// Ход обязан быть засчитан как НЕУДАЧНЫЙ — иначе круг не кончится никогда.
    ///
    /// ⚠️ ЗАЧЕМ ОТДЕЛЬНЫЙ СЛУЧАЙ. Ответ «читать нечего» — успех: ход прошёл, ошибки нет.
    /// Значит счётчик кривых ходов в цикле агента сбрасывается, и модель может просить
    /// одно и то же до самого предела шагов, а человек смотрит на крутящийся индикатор.
    /// Начиная с третьей такой просьбы подряд говорим прямо и считаем ход неудачным —
    /// дальше срабатывает обычная честная остановка цикла.
    case stuck(note: String)
}

/// Кто и что уже получил из файлов за этот разговор.
///
/// Один экземпляр на сессию агента: его держат вместе инструмент чтения (пополняет
/// и спрашивает) и инструмент записи (забывает файл после правки).
public final class ReadHistory: @unchecked Sendable {

    /// Отпечаток файла на диске. Нужен ровно для одного вопроса: «это всё ещё тот
    /// самый текст, который мы показывали?»
    public struct Fingerprint: Equatable, Sendable {
        public let byteSize: Int
        public let modified: Date?

        public init(byteSize: Int, modified: Date?) {
            self.byteSize = byteSize
            self.modified = modified
        }

        /// Совпадение даты — с точностью до секунды: у файл-провайдера (iCloud,
        /// Working Copy) дробная часть плавает. Тот же приём уже используется
        /// при сверке файла перед записью.
        func isSameFile(as other: Fingerprint) -> Bool {
            guard byteSize == other.byteSize else { return false }
            switch (modified, other.modified) {
            case (nil, nil):
                return true
            case let (mine?, theirs?):
                return abs(mine.timeIntervalSince(theirs)) < 1.0
            default:
                return false
            }
        }
    }

    private struct Record {
        var fingerprint: Fingerprint
        var totalLines: Int
        /// Показанные куски: отсортированы и склеены, пересечений нет.
        var seen: [ClosedRange<Int>]
        /// Оглавление этого файла модель уже видела.
        var sawOutline: Bool
    }

    /// Сколько файлов помним одновременно. Запись крошечная (несколько чисел),
    /// но предел нужен: за длинный разговор агент трогает десятки файлов,
    /// а держать всё подряд незачем.
    private static let capacity = 24

    /// Сколько раз подряд можно ответить «читать нечего», прежде чем считать ход
    /// неудачным. Тот же счёт, что у толчков «прочитай файлы, по именам не суди»
    /// в цикле агента: пара мягких напоминаний, потом честная остановка.
    private static let stallLimit = 2

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    /// Порядок появления — чтобы вытеснять самый старый файл, а не случайный.
    private var order: [String] = []
    /// Сколько раз ПОДРЯД мы ответили «это уже прочитано, читать нечего».
    /// Любая настоящая страница обнуляет счёт — значит работа сдвинулась.
    private var stallStreak = 0

    /// Как всё выглядело ДО последней пометки — чтобы её можно было отменить.
    ///
    /// ⚠️ ЗАЧЕМ ВООБЩЕ ОТМЕНА. Пометка «это модель уже видела» ставится ВНУТРИ
    /// инструмента, а дойдёт ли текст до модели, решается позже: цикл агента примеряет
    /// ответ к остатку памяти разговора и, если страница не влезает, заменяет её
    /// сообщением «файл не помещается в память разговора» — самого текста модель
    /// не получает ВООБЩЕ. Пометка при этом оставалась, и дальше выходило страшное:
    /// на повторную просьбу мы отвечали «строки 1–66 ты уже видел» и вели модель
    /// на 67-ю, то есть начало файла становилось недостижимым до конца задачи.
    /// Теперь пометка держится «на честном слове» до конца хода, и цикл агента
    /// отменяет её, когда сам же выбросил содержимое.
    private var pendingNote: (key: String, record: Record?, order: [String], stallStreak: Int)?

    public init() {}

    // MARK: - Совет перед чтением

    /// Что отдать модели на эту просьбу.
    ///
    /// - Parameters:
    ///   - key: канонический путь файла (один и тот же для «./a.md» и «a.md»).
    ///   - fingerprint: файл на диске ПРЯМО СЕЙЧАС.
    ///   - from: с какой строки просила модель (nil — не просила).
    ///   - to: по какую строку просила модель (nil — не просила).
    public func advice(for key: String,
                       fingerprint: Fingerprint,
                       from: Int?,
                       to: Int?) -> ReadAdvice {
        lock.lock(); defer { lock.unlock() }

        guard let record = records[key] else { return .asAsked }

        // Файл на диске уже другой — всё, что мы о нём помнили, врёт. Забываем.
        guard record.fingerprint.isSameFile(as: fingerprint) else {
            forgetLocked(key)
            return .asAsked
        }

        // ⚠️ Названы ОБА номера — это осознанная просьба «покажи ровно это место»,
        // и мешать ей нельзя: так модель перечитывает кусок, который сама правит.
        // Топтание на месте выглядит иначе — модель называет только начало.
        //
        // ⚠️ НО НЕ БЕСКОНЕЧНО. Пока это была единственная дорога, по которой одна и та же
        // страница могла уходить в память разговора сколько угодно раз: показанный кусок
        // отдавался снова, ход считался удачным, счётчик кривых ходов обнулялся. Правку
        // своего же куска это не задевает — после записи файл забывается целиком, — а вот
        // круг из одинаковых просьб теперь упирается в тот же предел, что и все остальные.
        if let from, let to {
            let asked = min(from, to)...max(from, to)
            guard isFullySeen(record, asked) else { return .asAsked }
            stallStreak += 1
            guard stallStreak > Self.stallLimit else { return .asAsked }
            return .stuck(note: Self.goingInCirclesNote)
        }

        // Первое обращение без номеров к большому файлу отдаёт оглавление.
        // Второе такое же обращение — это круг: оглавление уже в памяти разговора,
        // и платить за него снова нечем. Отдаём первую непрочитанную страницу.
        if from == nil, to == nil, record.sawOutline {
            guard let next = firstUnseen(in: record, notBefore: 1) else {
                return stalledLocked(totalLines: record.totalLines)
            }
            return .skipAhead(from: next, note: Self.outlineNote)
        }

        let start = max(1, from ?? 1)
        // Начало, о котором просит модель, ей ещё не показывали — обычное чтение.
        guard let block = self.block(in: record, containing: start) else { return .asAsked }

        // Дальше по файлу непрочитанное есть — туда и ведём.
        if let next = firstUnseen(in: record, notBefore: start) {
            return .skipAhead(from: next, note: Self.seenNote(block))
        }
        // За этим местом всё показано, но раньше остались пропуски — ведём в них.
        if let earlier = firstUnseen(in: record, notBefore: 1) {
            return .skipAhead(from: earlier, note: Self.seenNote(block))
        }
        return stalledLocked(totalLines: record.totalLines)
    }

    /// Читать нечего — но ВАЖНО, в который раз подряд мы это говорим.
    ///
    /// ⚠️ ЭТО И ЕСТЬ ВЫХОД ИЗ ТУПИКА. Одного «читать больше нечего» маленькой модели
    /// мало: она честно пробует ещё раз тем же вызовом. Поэтому текст с каждым разом
    /// жёстче и прямо называет два оставшихся пути — записать результат или закончить, —
    /// а после второго раза ход перестаёт считаться удачным, и цикл агента
    /// останавливает задачу сам, вместо того чтобы крутиться до предела шагов.
    ///
    /// Зовётся только под уже взятым замком.
    private func stalledLocked(totalLines: Int) -> ReadAdvice {
        stallStreak += 1
        if stallStreak > Self.stallLimit {
            return .stuck(note: Self.goingInCirclesNote)
        }
        return .nothingLeft(note: stallStreak == 1
                            ? Self.wholeFileNote(totalLines)
                            : Self.enoughReadingNote)
    }

    // MARK: - Пополнение

    /// Запомнить то, что мы прямо сейчас отдали модели.
    public func note(_ file: WorkspaceFile, key: String) {
        lock.lock(); defer { lock.unlock() }

        // Снимок «как было» на случай, если страница до модели так и не доедет.
        // Стоит он трёх чисел и списка из двух десятков путей — дешевле любой копии текста.
        pendingNote = (key: key, record: records[key], order: order, stallStreak: stallStreak)

        let fingerprint = Fingerprint(byteSize: file.byteSize, modified: file.modificationDate)

        var record: Record
        if let existing = records[key], existing.fingerprint.isSameFile(as: fingerprint) {
            record = existing
        } else {
            // Файл видим впервые (или он изменился) — память о нём начинается заново.
            record = Record(fingerprint: fingerprint,
                            totalLines: file.totalLineCount,
                            seen: [],
                            sawOutline: false)
        }
        record.totalLines = file.totalLineCount

        // Файл, который читают прямо сейчас, вытесняться не должен — поэтому
        // при каждом пополнении он уходит в конец очереди на вытеснение.
        order.removeAll { $0 == key }
        order.append(key)

        switch file.view {
        case .outline:
            // Оглавление — это номера объявлений, а не текст файла. Строк оно не даёт,
            // и считать их прочитанными нельзя: модель их не видела.
            // ⚠️ Работой считаем только ПЕРВОЕ оглавление файла: второе такое же —
            // это и есть круг, ради которого весь счёт и заведён.
            if !record.sawOutline { stallStreak = 0 }
            record.sawOutline = true
        case .page, .whole:
            // Пустой файл и пустой ответ прочитанными строками не считаем.
            if file.totalLineCount > 0, file.shownLineCount > 0 {
                let shown = file.firstLine...file.lastLine
                // ⚠️ ПОЧЕМУ СЧЁТ СБРАСЫВАЕТ НЕ ЛЮБОЕ ЧТЕНИЕ, А ТОЛЬКО НОВЫЙ ТЕКСТ.
                // Повторная выдача уже показанного куска (модель назвала оба номера)
                // проходит здесь же и обнуляла бы счёт хождения по кругу — то есть
                // сама себя и оправдывала бы. Сдвиг с места — это новые строки.
                if !isFullySeen(record, shown) { stallStreak = 0 }
                record.seen = Self.merged(record.seen, with: shown)
            }
        }

        records[key] = record
        while order.count > Self.capacity {
            let oldest = order.removeFirst()
            records.removeValue(forKey: oldest)
        }
    }

    // MARK: - Отмена последней пометки

    /// Страница до модели не дошла — снять пометку «показано», как будто чтения не было.
    ///
    /// `key` — тот же файл, о котором пометка ставилась. Не совпал (или пометки уже нет) —
    /// не делаем ничего: отменять чужую пометку опаснее, чем не отменить свою.
    ///
    /// ⚠️ ВОЗВРАЩАЕМ ИМЕННО ПРЕЖНЕЕ СОСТОЯНИЕ, А НЕ «ЗАБЫВАЕМ ФАЙЛ ЦЕЛИКОМ». Забудь мы
    /// файл целиком — вместе с несостоявшейся страницей пропали бы и те, что модель
    /// честно получила раньше, и она пошла бы перечитывать их заново за полную цену.
    /// А это ровно та беда, ради которой вся эта память и заведена.
    public func undoNote(key: String) {
        lock.lock(); defer { lock.unlock() }
        guard let pending = pendingNote, pending.key == key else { return }
        pendingNote = nil
        if let record = pending.record {
            records[key] = record
        } else {
            records.removeValue(forKey: key)
        }
        order = pending.order
        stallStreak = pending.stallStreak
    }

    // MARK: - Забывание

    /// Забыть один файл. Зовётся после КАЖДОЙ записи: на диске теперь другой текст,
    /// и всё, что мы о нём помним, стало неправдой.
    public func forget(key: String) {
        lock.lock(); defer { lock.unlock() }
        forgetLocked(key)
    }

    /// Забыть всё. Разговор с моделью начат заново — значит показанных страниц
    /// у неё в памяти больше нет, и говорить «ты это уже видел» стало ложью.
    public func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        records.removeAll()
        order.removeAll()
        stallStreak = 0
        pendingNote = nil
    }

    private func forgetLocked(_ key: String) {
        records.removeValue(forKey: key)
        order.removeAll { $0 == key }
        // Отменять уже нечего: файл забыт целиком, и «вернуть как было» означало бы
        // воскресить память о тексте, который на диске мог измениться.
        if pendingNote?.key == key { pendingNote = nil }
        // Файл забыт — значит его снова можно читать целиком, и прежние отказы
        // «читать нечего» к новому положению дел отношения не имеют.
        stallStreak = 0
    }

    // MARK: - Тексты для модели
    //
    // ⚠️ Они короткие НАМЕРЕННО: каждый лишний токен здесь — из того же кармана,
    // ради которого всё это и затевалось.

    private static func seenNote(_ block: ClosedRange<Int>) -> String {
        "Строки \(block.lowerBound)–\(block.upperBound) ты уже видел. "
    }

    private static let outlineNote = "Оглавление ты уже видел. "

    private static func wholeFileNote(_ totalLines: Int) -> String {
        "Файл прочитан целиком (\(HumanFormat.lines(totalLines))) — читать больше нечего. "
            + "Отвечай по прочитанному и вызови finish."
    }

    /// Второй отказ подряд. Первый текст модель уже прочитала и не послушалась,
    /// поэтому здесь названы ОБА оставшихся пути — иначе она снова просит чтение.
    ///
    /// ⚠️ Имена действий тут обязательны: без них модель на 2 млрд параметров
    /// отвечает словами «хорошо, приступаю» и остаётся на месте.
    /// ⚠️ ПОРЯДОК ДЕЙСТВИЙ ЗДЕСЬ ПОМЕНЯН 09.09.2026, И ЭТО НЕ КОСМЕТИКА. Раньше первой
    /// стояла ЗАПИСЬ ФАЙЛА — то есть наш собственный текст велел модели править файл
    /// всякий раз, когда она перечитывала прочитанное. А владелец в этот момент чаще
    /// всего просто спрашивал, что за проект. Отсюда и росли карточки «записать
    /// index.html» на вопрос-объяснение, за которые он ответил матом: их подсказывали
    /// не модель и не пользователь, а мы сами. Теперь первым идёт finish, а запись —
    /// только если правку и правда просили.
    private static let enoughReadingNote =
        "Ты снова просишь уже прочитанное. Нового текста нет и не будет. "
        + "Хватит читать: ответь по прочитанному и вызови finish. "
        + "Файл меняй только если тебя об этом просили."

    /// Третий отказ подряд — ход засчитывается как неудачный.
    private static let goingInCirclesNote =
        "Ты третий раз подряд просишь прочитанное. Чтение ничего не добавит — ты ходишь по кругу. "
        + "Сделай следующий шаг: finish с итогом по прочитанному. "
        + "Правку файла предлагай, только если тебя просили что-то изменить."

    // MARK: - Работа с кусками

    /// Кусок, внутри которого лежит строка `line`. nil — строку ещё не показывали.
    private func block(in record: Record, containing line: Int) -> ClosedRange<Int>? {
        record.seen.first { $0.contains(line) }
    }

    /// Весь названный кусок модель уже получала.
    private func isFullySeen(_ record: Record, _ range: ClosedRange<Int>) -> Bool {
        guard let next = firstUnseen(in: record, notBefore: range.lowerBound) else { return true }
        return next > range.upperBound
    }

    /// Первая строка, которую модель ещё не видела, начиная с `start`.
    /// nil — от этого места и до конца файла всё показано.
    private func firstUnseen(in record: Record, notBefore start: Int) -> Int? {
        guard record.totalLines > 0 else { return nil }
        var candidate = max(1, start)
        // Куски отсортированы и склеены, поэтому достаточно одного прохода:
        // пока очередной кусок накрывает кандидата — перепрыгиваем через него.
        for range in record.seen {
            if range.upperBound < candidate { continue }
            guard range.lowerBound <= candidate else { break }
            candidate = range.upperBound + 1
        }
        return candidate <= record.totalLines ? candidate : nil
    }

    /// Добавить кусок к уже показанным, склеив соседние.
    /// Соседними считаем и смежные (…30 и 31…): дырок между страницами не бывает.
    private static func merged(_ ranges: [ClosedRange<Int>],
                               with new: ClosedRange<Int>) -> [ClosedRange<Int>] {
        let all = (ranges + [new]).sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Int>] = []
        for range in all {
            if let last = out.last, range.lowerBound <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }
}
