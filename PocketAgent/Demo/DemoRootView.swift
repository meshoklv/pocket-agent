//
//  DemoRootView.swift
//  PocketAgent / Demo
//
//  Сборка демонстрации: те же экраны, что и в бою, но поверх поддельных данных.
//
//  Это зеркало композиционного корня (Agent/AgentAssembly.swift) — единственное место,
//  где демонстрационные части встречаются друг с другом. Сам боевой корень при этом
//  не меняется и про эту папку ничего не знает.
//

// ⚠️ ВЕСЬ ФАЙЛ — ТОЛЬКО ОТЛАДОЧНАЯ СБОРКА.
// Демонстрационный режим нужен ради снимков экранов на симуляторе, и в сборку
// для магазина ему попадать незачем: там это мёртвый код и выдуманные тексты.
// Конвейер снимков собирает конфигурацию Debug, поэтому съёмке скобки не мешают.
#if DEBUG

import SwiftUI

// MARK: - Сборка

@MainActor
final class DemoAssembly: ObservableObject {

    /// То, что видят экраны. Внутри — поддельный движок, поддельная папка
    /// и поддельная сессия агента, всё остальное настоящее.
    let viewModel: AppViewModel

    /// Сессию держим отдельно: интерфейс просит её через замыкание, а замыкание
    /// обязано каждый раз отдавать ОДИН И ТОТ ЖЕ объект, иначе переписка обнулится
    /// при первой же пересборке сессии.
    private let agent: DemoAgent

    init(screen: DemoScreen) {
        let agent = DemoAgent(screen: screen)
        self.agent = agent

        let viewModel = AppViewModel(
            runtime: DemoRuntime(status: DemoAssembly.modelStatus(for: screen)),
            // ⚠️ У площадки папка НАСТОЯЩАЯ, и это не отступление от правил
            // демонстрации. Площадка показывает файлы своими глазами: обходит
            // папку, запускает страницу в WebKit, ловит её ошибки. Подделать ей
            // нечего — поэтому демонстрация кладёт примеры в свою временную папку
            // и отдаёт её как папку проекта (PocketAgent/Demo/DemoPlaygroundPages.swift).
            folderStore: DemoFolderStore(folder: DemoAssembly.folder(for: screen)),
            modelInfo: DemoScenario.modelInfo,
            freeBytesProvider: { DemoScenario.freeBytes },
            // ⚠️ ОТДЕЛЬНЫЙ ЯЩИК НАСТРОЕК — не общий с боевым приложением.
            // Демонстрация показывает готовую модель, а на готовую модель интерфейс
            // ставит у себя пометку «модель уже готовили». Попади она в настоящие
            // настройки — обычный запуск на телефоне после демонстрации сам полез бы
            // качать 2,6 ГБ, без кнопки. Свой ящик означает: демонстрация вообще
            // ничего не оставляет после себя в боевом поведении.
            // Пустое имя набора невозможно, но если система вдруг откажет —
            // откатываемся на общий: показать экраны важнее, чем упасть.
            defaults: UserDefaults(suiteName: "pocketagent.demo") ?? .standard,
            makeAgent: { agent }
        )
        self.viewModel = viewModel

        // Экран выбора папки показываем поверх уже готовой работы — так на снимке
        // видно не только правила, но и карточку выбранной папки с её путём.
        if screen == .folder {
            viewModel.isChangingFolder = true
        }

        // Площадка живёт на своей вкладке, и открыть её нажатием в симуляторе
        // некому — выбираем вкладку сразу.
        //
        // ⚠️ Именно `selectTab`, а не присваивание: он же снимает пометку «человека
        // сюда привели мы», из-за которой приложение через секунду вернуло бы его
        // обратно в чат.
        if screen.isPlayground {
            viewModel.selectTab(.playground)
        }
    }

    /// Какую папку проекта показываем. У площадки — настоящая витрина с примерами,
    /// у остальных экранов — выдуманная папка сценария.
    private static func folder(for screen: DemoScreen) -> ProjectFolder {
        screen.isPlayground ? DemoPlayground.prepared.folder : DemoScenario.folder
    }

    /// Состояние движка под нужный экран: только для экрана подготовки модель
    /// «ещё качается», во всех остальных случаях она уже готова.
    private static func modelStatus(for screen: DemoScreen) -> ModelRuntimeStatus {
        switch screen {
        case .model:
            return .downloading(progress: 0.46)
        case .folder, .chat, .approval, .about,
             .playgroundList, .playgroundScene, .playgroundGame, .playgroundBroken:
            return .ready
        }
    }
}

// MARK: - Корневой экран демонстрации

struct DemoRootView: View {

    @StateObject private var assembly = DemoAssembly(screen: DemoMode.screen)

    private let screen = DemoMode.screen

    var body: some View {
        switch screen {
        case .about:
            // «О программе» в бою открывается отдельной страницей поверх экрана.
            // Для снимка показываем ту же страницу сразу и целиком: так кадр
            // получается предсказуемым, без ожидания анимации открытия.
            // Кнопка закрытия на ней есть, но закрывать в демонстрации нечего.
            AboutView(model: DemoScenario.modelInfo,
                      storage: DemoScenario.modelStorage)
                .preferredColorScheme(.dark)

        case .playgroundScene:
            // Открытая страница — это тот же самый просмотрщик, что и в бою.
            // Заходим в него сразу: проверять страницу перед показом здесь незачем,
            // мы её сами и написали, а лишние две секунды проверки только
            // добавили бы снимку шанс поймать кружок ожидания вместо сцены.
            DemoPlaygroundStage(page: .scene)

        case .playgroundGame:
            DemoPlaygroundStage(page: .game)

        case .playgroundBroken:
            // Разбор поломки в бою поднимается страницей поверх списка площадки —
            // ровно так его и показываем, вместе с тем, что видно за ним.
            DemoPlaygroundRepair(app: assembly.viewModel)

        case .model, .folder, .chat, .approval, .playgroundList:
            // Тот же самый корневой экран, что и в бою: какой из экранов он покажет,
            // решает состояние — «модель качается», «папка меняется» или «всё готово».
            // Для площадки вкладка уже выбрана в сборке демонстрации.
            ContentView(app: assembly.viewModel)
        }
    }
}

// MARK: - Открытая страница площадки

/// Одна страница витрины, открытая во весь экран боевым просмотрщиком.
private struct DemoPlaygroundStage: View {

    let page: DemoPlaygroundPage

    var body: some View {
        if let item = DemoPlayground.item(page) {
            PlaygroundStageView(item: item,
                                rootURL: DemoPlayground.prepared.folder.url,
                                // Чинить в демонстрации нечего: помощник здесь
                                // поддельный, а страницы мы написали сами.
                                onFix: { _ in },
                                // ⚠️ «Человек уже предупреждён» — чтобы поверх сцены
                                // не всплыла полоска про ошибку. Она про НАСТОЯЩИЕ
                                // поломки чужих страниц, а этот кадр показывает,
                                // как выглядит рабочая страница.
                                alreadyWarned: true)
                .preferredColorScheme(.dark)
        } else {
            // ⚠️ Молчаливого пустого кадра быть не должно: если файл не записался,
            // снимок обязан сказать об этом словами, а не чернотой.
            DemoPlaygroundFailure(text: "Пример «\(page.fileName)» не записался во временную папку.")
        }
    }
}

// MARK: - Разбор поломки

/// Список площадки, поверх которого поднят разбор сломанной страницы.
private struct DemoPlaygroundRepair: View {

    let app: AppViewModel

    @State private var isSheetShown = false

    /// ⚠️ ОШИБКИ ЗАДАНЫ ЗДЕСЬ, А НЕ ПОЙМАНЫ ЖИВЬЁМ, И ЭТО ОСОЗНАННО.
    /// В бою сломанную страницу приложение сперва пробует починить само и уводит
    /// человека в чат — разбор с кнопками остаётся ЗАПАСНЫМ выходом, когда попыток
    /// не хватило (PlaygroundView). Дождаться этого случая на снимке нельзя, а
    /// показать его надо. Тексты взяты те самые, которыми ругается движок на
    /// нашей же странице «сломанная-страница.html»: пропавший холст и пропавшая картинка.
    private let issues: [PlaygroundIssue] = [
        PlaygroundIssue(kind: .script,
                        text: "TypeError: null is not an object (evaluating 'document.getElementById(...).getContext')",
                        line: 18),
        PlaygroundIssue(kind: .missingResource,
                        text: "img: фон-часов.png",
                        line: nil)
    ]

    var body: some View {
        ZStack {
            ContentView(app: app)
        }
        .sheet(isPresented: $isSheetShown) {
            if let item = DemoPlayground.item(.broken) {
                PlaygroundRepairSheet(item: item,
                                      issues: issues,
                                      onFix: { },
                                      onShowAnyway: { })
            } else {
                DemoPlaygroundFailure(text: "Сломанный пример не записался во временную папку.")
            }
        }
        // ⚠️ Не в момент появления, а чуть позже: список площадки должен успеть
        // обойти папку и нарисовать карточки, иначе за страницей разбора на снимке
        // будет пустой экран «смотрю, что есть в папке».
        .task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            isSheetShown = true
        }
    }
}

/// Честная надпись вместо пустого кадра.
private struct DemoPlaygroundFailure: View {

    let text: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text(text)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(32)
        }
        .preferredColorScheme(.dark)
    }
}

#endif
