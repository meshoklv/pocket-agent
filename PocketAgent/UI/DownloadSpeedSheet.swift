//
//  DownloadSpeedSheet.swift
//  PocketAgent
//
//  Страница «Скорость загрузки»: чем качали в прошлый раз и чем качать дальше.
//
//  ⚠️ ПОЧЕМУ ОТДЕЛЬНАЯ СТРАНИЦА, А НЕ СТРОКА НА ЭКРАНЕ МОДЕЛЕЙ. Числом потоков
//  и размером куска человек трогает раз в жизни — а экран «Модели» и без них плотный,
//  и владелец ругался ровно на такой мусор («много визуального шума, много ненужного
//  текста»). Поэтому на самом экране эти настройки не занимают НИ ОДНОЙ строки:
//  вход — пункт «Скорость загрузки» в меню «…».
//
//  ⚠️ ЧТО ЗДЕСЬ ГЛАВНОЕ — ЦИФРА ПРОШЛОЙ ЗАГРУЗКИ, А НЕ ПЕРЕКЛЮЧАТЕЛИ. Скорость нельзя
//  улучшить рассуждением: без замера «было → стало» любая правка загрузчика — это
//  «кажется, стало быстрее». Приложение считает итог само (`ModelDownloader.lastRunLine`),
//  и он живёт между запусками — именно его человек и сравнивает после смены настроек.
//

import SwiftUI

struct DownloadSpeedSheet: View {

    @Environment(\.dismiss) private var dismiss

    /// Выбор храним в настройках телефона, а на экране держим его копию: без неё
    /// сегментированный переключатель не перерисуется — статическое свойство
    /// загрузчика SwiftUI не наблюдает.
    @State private var lanes = ModelDownloader.laneCount
    @State private var chunk = ModelDownloader.chunkMegabytes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                Text("Загрузка моделей")
                    .font(Theme.Fonts.screenTitle)
                    .foregroundStyle(Theme.textPrimary)

                nowCard
                lastRunCard
                settingsCard
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, Theme.Metrics.sheetBottomClearance)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { closeLayer }
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .screenBackground()
        .preferredColorScheme(.dark)
    }

    // MARK: - Замер: сейчас и в прошлый раз

    /// Что происходит ПРЯМО СЕЙЧАС: сколько прилетело из сети за этот заход и с какой
    /// скоростью. Карточки нет, когда ничего не качается, — считать нечего.
    ///
    /// ⚠️ ПОТОКИ И РАЗМЕР КУСКА ЗДЕСЬ СНОВА ЕСТЬ, НО ТОЛЬКО ПОТОМУ, ЧТО ЗАГРУЗЧИК СТАЛ
    /// ЗАПОМИНАТЬ ИХ В МОМЕНТ НАЧАЛА ЗАХОДА. Раньше он подставлял ТЕКУЩИЕ настройки:
    /// сменил человек потоки на ходу — и строка рапортовала новое число про уже идущую
    /// загрузку. Тогда эти два числа отсюда пришлось убрать, а вместе с ними ушёл
    /// и смысл замера: сравнить «4 потока по 16 МБ» с «3 по 32» стало не с чем.
    /// Теперь цифры относятся именно к этому заходу, и они вернулись.
    ///
    /// ⚠️ НОЛЬ ЗНАЧИТ «К ЭТОМУ ЗАХОДУ НЕПРИМЕНИМО» (мелкий файл поехал обычной загрузкой,
    /// без дорожек и кусков). Не проверишь на ноль — получишь «0 потоков по 0 МБ».
    ///
    /// ⚠️ «Качалось», а не «за»: время в замере теперь чистое, простои в него не идут.
    /// И «запись на диск» здесь по-прежнему нет: это телеметрия для того, кто чинит
    /// загрузчик, а человеку с телефоном в руке она не говорит ничего.
    @ViewBuilder
    private var nowCard: some View {
        if let speed = ModelDownloader.shared.speedNow {
            card {
                Text("Сейчас")
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(nowLine(speed))
                    .font(Theme.Fonts.counter)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// «1,2 ГБ, качалось 9 мин 30 с — 2,3 МБ/с, 4 потока по 16 МБ».
    private func nowLine(_ speed: ModelDownloadSpeed) -> String {
        var text = "\(HumanFormat.bytes(speed.arrivedBytes)), качалось "
            + "\(ModelDownloadSpeed.duration(speed.seconds))"
            + " — \(ModelDownloadSpeed.speed(speed.bytesPerSecond))"
        if speed.lanes > 0 {
            text += ", \(speed.lanes) \(HumanFormat.plural(speed.lanes, "поток", "потока", "потоков"))"
            if speed.chunkMegabytes > 0 { text += " по \(speed.chunkMegabytes) МБ" }
        }
        return text
    }

    /// Итог последней доехавшей загрузки: «Gemma 4 E4B: 2,55 ГБ за 18 мин 20 с —
    /// 2,3 МБ/с, 4 потока по 16 МБ». Пока ни одна загрузка не доехала — карточки нет
    /// вовсе: пустая строка «данных пока нет» ничего человеку не даёт.
    @ViewBuilder
    private var lastRunCard: some View {
        if let line = ModelDownloader.lastRunLine, !line.isEmpty {
            card {
                Text("Прошлая загрузка")
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(line)
                    .font(Theme.Fonts.counter)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Настройки

    private var settingsCard: some View {
        card {
            Text("Как качать")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.textPrimary)

            // ⚠️ ЗАЧЕМ ЭТО ТРОГАТЬ — ПЕРВОЙ ЖЕ ФРАЗОЙ. Без неё страница открывалась
            // заголовком над голыми числами «1 2 3 4 6», о которых человеку нельзя
            // догадаться. У всех настроек в «О программе» такая фраза есть.
            Text("Файл едет к вам сразу несколькими кусками. Больше кусков разом — обычно быстрее, но на слабой связи бывает наоборот. Трогать это стоит, только если качается медленно.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // ⚠️ Подпись стоит ОТДЕЛЬНОЙ строкой над переключателем: сегментированный
            // вид собственную подпись не рисует вовсе.
            choice(title: "Кусков разом",
                   values: ModelDownloader.laneChoices,
                   selection: laneBinding)

            choice(title: "Размер куска, МБ",
                   values: ModelDownloader.chunkChoicesMegabytes,
                   selection: chunkBinding)

            // ⚠️ ГОВОРИМ ТОЛЬКО ПОКА ЧТО-ТО КАЧАЕТСЯ, И ТОЛЬКО ПРО КУСОК. Когда загрузки
            // нет, обе настройки просто подействуют на следующую — предупреждать не о чем,
            // а фраза висела бы всегда. И про потоки здесь молчим: обещание «подействуют
            // сразу» верно не всегда (мелкий файл и продолжение с точки обрыва едут
            // обычной загрузкой, без дорожек), а размер куска записан в план сборки
            // и посреди работы поменяться не может — иначе скачанное не сошлось бы
            // с новыми границами.
            if ModelDownloader.shared.speedNow != nil {
                Text("Сейчас идёт загрузка: новый размер куска подействует со следующей.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choice(title: String,
                        values: [Int],
                        selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text(title))
        }
    }

    /// Пишем в настройки только по касанию человека — тем же приёмом, что и размер
    /// памяти разговора в «О программе».
    private var laneBinding: Binding<Int> {
        Binding(get: { lanes },
                set: { chosen in
                    lanes = chosen
                    ModelDownloader.laneCount = chosen
                })
    }

    private var chunkBinding: Binding<Int> {
        Binding(get: { chunk },
                set: { chosen in
                    chunk = chosen
                    ModelDownloader.chunkMegabytes = chosen
                })
    }

    // MARK: - Мелочи

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Круглая стеклянная кнопка закрытия — единственное стекло на странице.
    /// ⚠️ Подложка под ней живёт ТОЛЬКО на iOS 17–18: на iOS 26 непрозрачный фон
    /// позади стекла запрещён.
    @ViewBuilder
    private var closeLayer: some View {
        if GlassAvailability.isLiquidGlassAvailable {
            closeButtonRow
        } else {
            VStack(spacing: 0) {
                closeButtonRow
                    .background {
                        Theme.background
                            .ignoresSafeArea(edges: .top)
                            .allowsHitTesting(false)
                    }

                LinearGradient(colors: [Theme.background, Theme.background.opacity(0)],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: Theme.Metrics.topFadeHeight)
                    .allowsHitTesting(false)
            }
        }
    }

    private var closeButtonRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "xmark",
                              accessibilityTitle: "Закрыть") {
                dismiss()
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
    }
}

#Preview {
    DownloadSpeedSheet()
}
