//
//  ModelFileHelpCard.swift
//  PocketAgent
//
//  Карточка «Где взять файл модели».
//
//  Зачем она отдельно. Кнопка «Из файла» предполагает, что файл у человека УЖЕ есть.
//  А чтобы он появился, нужно знать три вещи: какой файл подойдёт, где его взять
//  и куда положить. Без этого «Из файла» — кнопка в никуда: человек нажмёт, увидит
//  «Файлы» и не поймёт, что там искать.
//
//  ⚠️ ПЕРЕПИСАНА ПОСЛЕ ЖАЛОБЫ ВЛАДЕЛЬЦА. Прежняя карточка называла ОДНО точное имя
//  файла и один точный размер, потому что приложение принимало ровно один файл. Владелец
//  положил другую модель Gemma — годную, уже скачанную приложением Google AI Edge
//  Gallery, — и получил отказ «весит 3,66 ГБ, а нужен ровно 2,01 ГБ». Теперь подойдёт
//  любая модель Gemma в виде файла .litertlm, и карточка говорит именно это, а точное
//  имя показывает лишь как пример «с чего начать, если не знаете, что качать».
//
//  ⚠️ ПЕРЕЕХАЛА С ЭКРАНА «Модели» (09.08.2026). Раньше стояла прямо там и занимала
//  треть экрана при каждой прокрутке — жалоба владельца: «бесит, когда листаешь
//  что-то, а она на треть экрана». Теперь живёт на отдельной странице
//  `ModelFileHelpSheet`, которая открывается из меню «…» → «Взять готовый файл».
//  Саму карточку это не изменило — изменилось только то, кто её показывает.
//
//  Вставляется в `ModelFileHelpSheet` одной строкой:
//
//      ModelFileHelpCard(recommendedName: recommendedName,
//                        recommendedFileName: recommendedFileName,
//                        pageURL: pageURL)
//
//  Дизайн: обычная карточка контента, стекла нет — оно живёт только на плавающем слое.
//

import SwiftUI

struct ModelFileHelpCard: View {

    /// Имя модели, которую советуем новичку: «Gemma 4 E2B».
    let recommendedName: String
    /// Имя её файла — как пример, а не как требование.
    /// ⚠️ Приходит от выбранной модели, а не пишется здесь текстом: сменится выбор —
    /// карточка расскажет про новый файл сама, и врать человеку ей будет нечем.
    let recommendedFileName: String
    /// Страница модели, если она есть.
    let pageURL: URL?

    /// Кружок с номером шага растёт вместе с цифрой внутри: она набрана ролью,
    /// и в жёстких 24 точках при крупном системном шрифте вылезала за круг.
    @ScaledMetric(relativeTo: .footnote) private var stepBadgeSize: CGFloat
        = Theme.Metrics.stepBadgeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Где взять файл")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.textPrimary)

            // Главное правило — одной фразой и первым делом.
            // Человек должен понять, что его файл, скорее всего, УЖЕ подходит.
            //
            // ⚠️ Про папку сказано здесь же, а не отдельным разделом: модель для движка
            // Apple — это папка из нескольких файлов, и человек, не знающий этого,
            // ищет в «Файлах» файл, которого не существует.
            Text("""
            Подойдёт любая модель Gemma в виде файла с окончанием \
            .litertlm\u{00A0}— и та, что вы скачаете сами, и та, что уже лежит \
            на\u{00A0}телефоне. Модель для движка Apple лежит папкой — её выбирайте целиком.
            """)
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 12) {
                way(icon: "iphone.and.arrow.forward",
                    title: "Уже пользуетесь Google AI Edge Gallery?",
                    text: """
                    Модель, скачанная в нём, подойдёт как есть. Перекладывать её никуда \
                    не нужно — выберите её прямо там, где она лежит.
                    """)

                way(icon: "arrow.down.circle",
                    title: "Ничего ещё не скачано?",
                    text: """
                    Начните с \(recommendedName): файл \(recommendedFileName). \
                    Скачать его проще всего на компьютере — файл большой.
                    """)
            }

            // ⚠️ РАНЬШЕ ЗДЕСЬ БЫЛИ ЧЕТЫРЕ ШАГА «куда положить файл»: «Файлы» → «На iPhone» →
            // папка «Карманный агент» → перетащить. Это был единственный работавший путь,
            // потому что окно выбора показывало ТОЛЬКО файлы .litertlm и всё прочее гасило.
            // Теперь выбрать можно что угодно и откуда угодно, и длинная возня с перетас-
            // киванием стала лишней — она осталась одной строкой ниже, как второй способ.
            VStack(alignment: .leading, spacing: 10) {
                Text("Как выбрать")
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.textPrimary)

                step(number: "1", text: "Нажмите «Выбрать файл или папку» внизу.")
                step(number: "2", text: "Откройте любое место: «На iPhone», iCloud Drive, папку другого приложения.")
                step(number: "3", text: "Нажмите на модель. Если это папка — зайдите в неё и подтвердите выбор папки.")
            }

            Text("""
            Можно и наоборот: положить файл в папку «Карманный агент» \
            («Файлы» → «Обзор» → «На iPhone») — тогда он появится в списке сам.
            """)
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)

            if let pageURL {
                Link("Открыть страницу модели", destination: pageURL)
                    .font(.footnote.bold())
                    // Площадь касания по норме Apple: сама надпись высотой около
                    // 18 точек, а это первый экран приложения — промахиваться нельзя.
                    .frame(minHeight: Theme.Metrics.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }

        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Единственное описание поверхности карточки — Theme.cardSurface().
        .cardSurface()
    }

    /// Один из двух путей получить файл: с иконкой и заголовком-вопросом.
    private func way(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: stepBadgeSize, height: stepBadgeSize)
                .background(Theme.surfaceHigh, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.footnote.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func step(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.footnote.bold().monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(width: stepBadgeSize, height: stepBadgeSize)
                .background(Theme.surfaceHigh, in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
