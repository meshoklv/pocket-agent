//
//  MainTabBar.swift
//  PocketAgent
//
//  Нижние вкладки — единственный способ ходить между разделами.
//
//  ⚠️ ЗАЧЕМ ОНИ ПОЯВИЛИСЬ. Приложение было одностраничником: попав в чат, человек
//  не мог из него выйти, а экран с моделями показывался только пока рабочей модели
//  нет — сменить модель после загрузки было нечем вообще.
//
//  ⚠️⚠️ ЗДЕСЬ БЫЛА САМОДЕЛЬНАЯ ПАНЕЛЬ. ОНА УБРАНА НАМЕРЕННО, НЕ ВОЗВРАЩАТЬ.
//
//  До 09.08.2026 панель рисовалась руками: четыре кнопки внутри нашей же стеклянной
//  капсулы (`FloatingGlassBar`), а корневой экран подкладывал её через
//  `.safeAreaInset(edge: .bottom)`. Выглядело похоже на настоящую, вело себя иначе:
//
//  • панель ездила вверх вместе с клавиатурой (она лежала в безопасной зоне контента),
//    поэтому пришлось заводить признак «человек печатает» и прятать её вручную;
//  • появление и исчезновение панели меняло высоту контента, и лента подпрыгивала;
//  • ничего из нового поведения системы у неё не было: она не сжимается при прокрутке,
//    не морфится, не подхватывает системные настройки доступности для панели вкладок;
//  • переключение вкладок мы анимировали сами — а система переключает их мгновенно,
//    и это правильно: анимация между вкладками только заставляет ждать.
//
//  Начиная с iOS 26 система рисует нижнюю панель ровно тем, чего мы добивались руками:
//  плавающая стеклянная капсула с зазором от краёв, живое стекло, сжатие при прокрутке.
//  Повторять это самим — значит каждый год отставать от системы и ловить свои же баги
//  (один такой уже был: самодельный слой поверх системного жеста таскал текст вбок,
//  design notes). Поэтому здесь теперь РОДНОЙ `TabView`, а этот файл — только
//  тонкая обёртка над ним: имена вкладок, значок загрузки и совместимость со старыми iOS.
//
//  Что даёт система сама, бесплатно и правильно:
//  • стекло и «плавающий» вид панели (iOS 26+);
//  • сжатие панели при прокрутке вниз — `.tabBarMinimizeBehavior(.onScrollDown)`;
//  • резервирование места под панель: `.safeAreaInset(edge: .bottom)` ВНУТРИ вкладки
//    (поле ввода в чате, «Скачать» на моделях) ложится ровно над ней;
//  • мгновенное переключение вкладок и сохранение состояния каждой из них.
//

import SwiftUI
import UIKit

/// Короткое имя для вкладок: `AppViewModel.Tab` в разметке читается тяжело.
typealias AppTab = AppViewModel.Tab

/// Красим ОТМЕТКУ на вкладке в наш синий, а не в тревожный системный красный.
///
/// ⚠️ ПОЧЕМУ ОТДЕЛЬНЫЙ ТИП, А НЕ static let ВНУТРИ `MainTabBar`. `MainTabBar`
/// обобщён по `TabContent`, а у обобщённых типов Swift запрещает статические
/// хранимые свойства (каждая специализация растила бы свою копию) — вынесено сюда,
/// в обычный enum без параметров.
///
/// ⚠️ ПОЧЕМУ ТАК, А НЕ СВОЯ НАКЛАДКА. Панель вкладок — родная, системная
/// (см. предупреждение в шапке файла), а сама отметка с процентом — это
/// `.badge()`, у SwiftUI нет параметра цвета для неё напрямую. Но цвет ВСЕХ
/// отметок в приложении красится через UIKit `UITabBarItem.appearance()` —
/// это официальный, не хакерский путь, ничего своего поверх панели не рисуется,
/// и он работает и для старых вкладок (`.tabItem`), и для новых (`Tab`).
///
/// ⚠️ Владелец приложения написал прямо: «сделай бейдж загрузки синим а не
/// красным пж а то триггерит» — красный на ровном месте читается как беда,
/// а обычная загрузка модели — это не беда. Красный не убираем совсем: он
/// остаётся за настоящей поломкой — кольцом хода у кнопки «…» на экране
/// «Модели» (`ModelWorkRingView`, случай `.failed`, красится в
/// `Theme.Colors.danger`). Этой отметки на панели вкладок красный не касается:
/// она гаснет вместе с прогрессом, как только загрузка обрывается
/// (`AppViewModel.downloadProgress` не знает состояния «упало», только «идёт»
/// или «ничего не качается»), и красной никогда не была.
private enum TabBadgeAppearance {

    /// `UITabBarItem.appearance()` — единственная точка настройки на всё
    /// приложение (в нём всего одна отметка), поэтому красим один раз за жизнь
    /// процесса, а не при каждой перерисовке панели.
    static let recolorOnce: Void = {
        UITabBarItem.appearance().badgeColor = UIColor(Theme.Colors.accent)
    }()
}

/// Как вкладка выглядит и называется. Отдельно от `MainTabBar`, потому что сама панель
/// обобщена по содержимому вкладки, а подписи нужны и без него.
enum AppTabLook {

    /// Короткие слова, а не термины: человек читает их одним взглядом.
    static func title(for tab: AppTab) -> String {
        switch tab {
        case .chat:     return "Чат"
        case .tasks:    return "Задачи"
        case .playground: return "Площадка"
        case .models:   return "Модели"
        case .projects: return "Папки"
        }
    }

    static func icon(for tab: AppTab) -> String {
        switch tab {
        case .chat:     return "bubble.left"
        case .tasks:    return "list.bullet"
        // ⚠️ Значок нарочно «несерьёзный»: площадка — единственное место в приложении
        // для игр и приколов, и по значку это должно читаться раньше подписи.
        case .playground: return "sparkles"
        case .models:   return "brain.head.profile"
        case .projects: return "folder"
        }
    }
}

/// Корневая панель вкладок. Внутри — родной `TabView`, снаружи — четыре раздела,
/// которые строит корневой экран.
///
/// Содержимое приходит замыканием, а не готовыми вьюхами: так корневой экран остаётся
/// единственным местом, где решается, что показать в разделе, а этот файл ничего
/// не знает ни про модель, ни про чат.
struct MainTabBar<TabContent: View>: View {

    let selection: AppTab
    let select: (AppTab) -> Void

    /// Прогресс загрузки модели 0…1. nil — сейчас ничего не качается.
    ///
    /// ⚠️ ЗАЧЕМ ОН ЗДЕСЬ. Загрузка весит гигабайты, идёт минутами и продолжается в фоне,
    /// даже когда человек ушёл со вкладки «Модели». Раньше узнать, что она всё ещё идёт,
    /// можно было только вернувшись туда. Теперь система сама рисует значок на вкладке
    /// «Модели» — своего кольца поверх системной панели мы не рисуем и не можем: чужие
    /// слои поверх панели вкладок — это ровно тот самый самодельный слой, от которого
    /// мы здесь и уходим.
    var downloadProgress: Double? = nil

    /// Спрятать панель вкладок совсем (человек печатает задачу в чате).
    ///
    /// ⚠️ Родная панель НЕ едет вверх вместе с клавиатурой — её просто закрывает
    /// клавиатура. То есть скрытие тут — страховка, а не обязанность: если система
    /// когда-нибудь начнёт панель поднимать, две капсулы над клавиатурой всё равно
    /// не встретятся.
    var isHidden: Bool = false

    private let content: (AppTab) -> TabContent

    init(selection: AppTab,
         select: @escaping (AppTab) -> Void,
         downloadProgress: Double? = nil,
         isHidden: Bool = false,
         @ViewBuilder content: @escaping (AppTab) -> TabContent) {
        self.selection = selection
        self.select = select
        self.downloadProgress = downloadProgress
        self.isHidden = isHidden
        self.content = content
        // Один раз за жизнь процесса, здесь (а не в `body`) — `body` целиком
        // читается компилятором как ViewBuilder-DSL, и одиночное «пустое»
        // выражение там же он пытается сложить в View и не может.
        _ = TabBadgeAppearance.recolorOnce
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            ModernTabs(selection: selectionBinding,
                       badge: downloadBadge,
                       isHidden: isHidden,
                       minimizesOnScroll: minimizesOnScroll,
                       content: content)
        } else {
            LegacyTabs(selection: selectionBinding,
                       badge: downloadBadge,
                       isHidden: isHidden,
                       content: content)
        }
    }

    /// ⚠️ Пропускаем только НАСТОЯЩУЮ смену вкладки.
    /// `TabView` имеет право записать в связку то же самое значение (при построении,
    /// при возврате из фона). А `selectTab` — это ещё и «человек пришёл сюда сам»:
    /// лишний вызов стирал бы память о том, что на вкладку его привело приложение,
    /// и обратно в чат оно бы его уже не вернуло.
    private var selectionBinding: Binding<AppTab> {
        Binding(get: { selection },
                set: { newValue in
                    guard newValue != selection else { return }
                    select(newValue)
                })
    }

    /// Сжимать ли панель при прокрутке — везде, КРОМЕ чата.
    ///
    /// ⚠️ В чате это выключено намеренно. Лента сама прокручивается вниз на каждое
    /// новое сообщение и на каждый шаг работы агента — а сжатие панели срабатывает
    /// как раз на прокрутку вниз. Получилось бы, что панель дёргается туда-обратно
    /// весь разговор: это ровно то мигание, которого в приложении быть не должно.
    /// На спокойных списках (задачи, модели, папки) сжатие, наоборот, только помогает.
    private var minimizesOnScroll: Bool { selection != .chat }

    /// Значок на вкладке «Модели»: сколько процентов уже скачано.
    ///
    /// Проценты, а не точка: точка сообщает «что-то есть», а человеку в этот момент
    /// важно ровно одно — далеко ли ещё. nil — значка нет вовсе.
    private var downloadBadge: Text? {
        guard let downloadProgress else { return nil }
        let percent = Int((max(0, min(1, downloadProgress)) * 100).rounded())
        return Text("\(percent) %")
    }
}

// MARK: - iOS 18 и новее: родные вкладки через тип Tab

/// ⚠️ Двух реализаций не избежать: `Tab` — это КОНТЕЙНЕР вокруг содержимого,
/// а старый `.tabItem` — МОДИФИКАТОР на содержимом. Одно в другое не сворачивается,
/// и попытка спрятать разницу за одной вьюхой упирается в то, что `Tab` разрешён
/// только непосредственно внутри `TabView`. Когда нижней границей станет iOS 18,
/// вторая реализация просто удаляется.
@available(iOS 18.0, *)
private struct ModernTabs<TabContent: View>: View {

    @Binding var selection: AppTab
    let badge: Text?
    let isHidden: Bool
    let minimizesOnScroll: Bool
    let content: (AppTab) -> TabContent

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppTabLook.title(for: .chat),
                systemImage: AppTabLook.icon(for: .chat),
                value: AppTab.chat) {
                content(.chat)
                    // Прячем панель только на вкладке чата и только пока печатают.
                    .toolbar(isHidden ? Visibility.hidden : Visibility.visible, for: .tabBar)
            }

            Tab(AppTabLook.title(for: .tasks),
                systemImage: AppTabLook.icon(for: .tasks),
                value: AppTab.tasks) {
                content(.tasks)
            }

            Tab(AppTabLook.title(for: .playground),
                systemImage: AppTabLook.icon(for: .playground),
                value: AppTab.playground) {
                content(.playground)
            }

            Tab(AppTabLook.title(for: .models),
                systemImage: AppTabLook.icon(for: .models),
                value: AppTab.models) {
                content(.models)
            }
            .badge(badge)

            Tab(AppTabLook.title(for: .projects),
                systemImage: AppTabLook.icon(for: .projects),
                value: AppTab.projects) {
                content(.projects)
            }
        }
        .tabBarMinimizesOnScroll(minimizesOnScroll)
    }
}

// MARK: - iOS 17: старый способ описания вкладок

private struct LegacyTabs<TabContent: View>: View {

    @Binding var selection: AppTab
    let badge: Text?
    let isHidden: Bool
    let content: (AppTab) -> TabContent

    var body: some View {
        TabView(selection: $selection) {
            content(.chat)
                .tabItem { Label(AppTabLook.title(for: .chat),
                                 systemImage: AppTabLook.icon(for: .chat)) }
                .tag(AppTab.chat)
                .toolbar(isHidden ? Visibility.hidden : Visibility.visible, for: .tabBar)

            content(.tasks)
                .tabItem { Label(AppTabLook.title(for: .tasks),
                                 systemImage: AppTabLook.icon(for: .tasks)) }
                .tag(AppTab.tasks)

            content(.playground)
                .tabItem { Label(AppTabLook.title(for: .playground),
                                 systemImage: AppTabLook.icon(for: .playground)) }
                .tag(AppTab.playground)

            content(.models)
                .tabItem { Label(AppTabLook.title(for: .models),
                                 systemImage: AppTabLook.icon(for: .models)) }
                .tag(AppTab.models)
                .badge(badge)

            content(.projects)
                .tabItem { Label(AppTabLook.title(for: .projects),
                                 systemImage: AppTabLook.icon(for: .projects)) }
                .tag(AppTab.projects)
        }
    }
}

// MARK: - Совместимость

private extension View {

    /// Сжатие панели при прокрутке вниз — поведение iOS 26.
    ///
    /// Панель уезжает к краю и ужимается до одной иконки, освобождая экран под чтение,
    /// и возвращается, стоит потянуть вверх. Делает это система, покадрово и вместе
    /// с прокруткой, — сами мы такое повторить не смогли бы.
    /// На iOS 17–18 такого поведения нет; там панель просто стоит на месте.
    ///
    /// ⚠️ Если на телефоне окажется, что сжатие дёргает нижние панели экранов
    /// («Скачать», «Добавить папку»), выключается оно ровно здесь: заменить
    /// `.onScrollDown` на `.never`.
    @ViewBuilder
    func tabBarMinimizesOnScroll(_ isEnabled: Bool) -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(isEnabled
                                        ? TabBarMinimizeBehavior.onScrollDown
                                        : TabBarMinimizeBehavior.never)
        } else {
            self
        }
    }
}
