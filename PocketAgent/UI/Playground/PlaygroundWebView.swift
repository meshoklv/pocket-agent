//
//  PlaygroundWebView.swift
//  PocketAgent
//
//  Видимый показ страницы из папки проекта — БЕЗ ЕДИНОГО ВЫХОДА В СЕТЬ.
//
//  ⚠️⚠️ ЭТО САМОЕ ОПАСНОЕ МЕСТО ВО ВСЁМ ПРИЛОЖЕНИИ, И ВОТ ПОЧЕМУ.
//  Обещание продукта дословно (CLAUDE.md): «Не отправляем файлы и содержимое папки
//  в сеть. Никогда, ни в каком режиме». А здесь мы своими руками запускаем ЧУЖОЙ код:
//  страницу, которую написала модель. В ней может оказаться `fetch()`, картинка
//  с чужого адреса, форма с отправкой — и содержимое папки уедет наружу, причём
//  человек этого даже не заметит. Один такой недосмотр перечёркивает весь смысл
//  приложения, поэтому защита здесь СЛОЙНАЯ, а не одна проверка.
//
//  ⚠️⚠️ ЧЕСТНО ПРО СЛОИ — И ЭТО ВАЖНЕЕ САМОГО КОДА. Здесь раньше было написано
//  «три независимых слоя, каждый ловит то, что пропустил предыдущий». Это было
//  НЕПРАВДОЙ, и неверный комментарий в самом опасном файле опаснее самой дыры:
//  следующий правщик опирается на него, а не на код.
//
//  Как на самом деле:
//
//  1. **Правила содержимого WebKit** — рубят загрузку по сетевым схемам внутри движка.
//     Для ПОДРЕСУРСОВ (картинки, скрипты, `fetch`, маяки) это ЕДИНСТВЕННЫЙ слой.
//     Поэтому не встали правила — страницу не показываем вовсе (fail-closed).
//  2. **Решение о переходе** — отменяет всё, что не наша схема внутри папки проекта.
//     Работает ТОЛЬКО на навигации фреймов; подресурсы через него не проходят.
//  3. **Обработчик схемы** (`PlaygroundSchemeHandler`) — ЕДИНСТВЕННЫЙ, кто вообще
//     даёт странице байты с диска, и он проверяет КАЖДЫЙ путь: границу папки, ссылки
//     наружу, служебные файлы. Это сильнее прежних «границ чтения» WebKit: те были
//     одной проверкой на всю загрузку, эта — на каждый файл, теми же примитивами
//     `SafePath`, которыми закрыты дыры в инструментах модели. К сети отношения не имеет.
//
//  Итого: от утечки данных защищает пункт 1; пункты 2 и 3 держат границу папки.
//  ⚠️ Чего мы НЕ закрываем и знаем об этом: WebRTC контентными правилами не режется
//  (в скрипте-наблюдателе стоит заглушка, но она обходима через пустой фрейм).
//
//  Настройка движка общая с невидимой проверкой — `PlaygroundWebKit`. Две копии
//  настройки безопасности разошлись бы, и однажды невидимая полезла бы в сеть.
//

import SwiftUI
import WebKit

/// Показ локальной страницы. Наружу — ничего.
struct PlaygroundWebView: UIViewRepresentable {

    /// Файл, который открываем.
    let fileURL: URL
    /// Корень папки проекта — граница, за которую движку читать нельзя.
    let rootURL: URL
    /// Сколько раз человек нажал «Заново». Меняется — перезагружаем страницу.
    let reloadToken: Int
    /// Страница пожаловалась (ошибка скрипта, не нашлась картинка, ломилась в сеть).
    let onIssue: (PlaygroundIssue) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(rootURL: rootURL, onIssue: onIssue)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = PlaygroundWebKit.makeConfiguration(handler: context.coordinator,
                                                               rootURL: rootURL)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // Игры часто рисуют во весь экран и сами обрабатывают жесты — системное
        // «оттягивание» ленты им только мешает.
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false

        webView.allowsLinkPreview = false
        PlaygroundWebKit.installBlocking(on: webView) { [weak webView] didInstall in
            guard let webView else { return }
            guard didInstall else {
                // ⚠️ Защита от выхода в интернет не встала — страницу НЕ показываем.
                // Для подресурсов это единственный слой; без него «показать» значит
                // «выпустить чужой код в сеть с содержимым папки».
                context.coordinator.onIssue(PlaygroundIssue(
                    kind: .failedToOpen,
                    text: "не смог включить защиту от выхода в интернет — показывать страницу нельзя",
                    line: nil))
                return
            }
            context.coordinator.isReady = true
            load(webView, coordinator: context.coordinator)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.isReady else { return }
        // ⚠️ Папку тоже сверяем: человек может выбрать другую, оставшись на той же
        // странице. Не заметь мы этого — обработчик схемы продолжил бы отдавать файлы
        // из СТАРОЙ папки, то есть площадка показывала бы чужой проект.
        guard context.coordinator.lastReloadToken != reloadToken
                || context.coordinator.lastFileURL != fileURL
                || context.coordinator.lastRootURL != rootURL else { return }
        load(webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // ⚠️ Обработчик сообщений держит на себе ссылку жёстко: не снять его —
        // и координатор вместе со страницей останется в памяти навсегда.
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: PlaygroundWebKit.issueChannel)
        webView.stopLoading()
    }

    private func load(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.lastReloadToken = reloadToken
        coordinator.lastFileURL = fileURL
        coordinator.lastRootURL = rootURL
        coordinator.rootURL = rootURL
        // ⚠️ Открываем СВОЕЙ СХЕМОЙ, а не `file://`. Причина не косметическая: у файлового
        // адреса нет происхождения, и браузер запрещает странице ровно то, из чего состоят
        // сайты, игры и трёхмерные сцены — модули, `fetch` к соседнему файлу, рабочие
        // потоки, текстуры из соседних картинок. Разбор — в шапке `PlaygroundSchemeHandler`.
        // Граница папки при этом не ослабла, а усилилась: файлы отдаёт наш обработчик,
        // и он проверяет каждый путь теми же проверками, что и инструменты модели.
        guard PlaygroundWebKit.loadPage(fileURL, root: rootURL, in: webView) else {
            coordinator.onIssue(PlaygroundIssue(
                kind: .failedToOpen,
                text: "файл лежит за пределами папки проекта — открыть его нельзя",
                line: nil))
            return
        }
    }

    // MARK: - Решения о переходах и жалобы страницы

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

        /// ⚠️ Не `let`: папку человек может сменить, не уходя с площадки, а решение
        /// о переходе обязано сверяться с ТЕКУЩЕЙ границей, а не с той, что была при
        /// создании экрана. Иначе проверка границы отвечала бы про чужой проект.
        var rootURL: URL
        /// ⚠️ Не private: замыкание установки правил зовёт его снаружи координатора,
        /// когда защита не встала и страницу показывать нельзя.
        let onIssue: (PlaygroundIssue) -> Void

        var lastReloadToken = -1
        var lastFileURL: URL?
        var lastRootURL: URL?
        var isReady = false

        init(rootURL: URL, onIssue: @escaping (PlaygroundIssue) -> Void) {
            self.rootURL = rootURL
            self.onIssue = onIssue
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            // ⚠️ ПРЕДЕЛ ОБЯЗАТЕЛЕН. Страница в цикле шлёт жалобы с меняющимся текстом
            // (номер кадра, время) — отсев дословных повторов её не удержит, и список
            // растёт без конца, пока человек играет. У невидимой проверки такой предел
            // был, у видимого показа — нет; тут стояло мёртвое поле-счётчик, которое
            // никто не увеличивал. Разбор надзирателя 10.09.2026.
            guard accepted < PlaygroundWebKit.maxIssuesPerRun else { return }
            guard let issue = PlaygroundWebKit.issue(from: message.body) else { return }
            accepted += 1
            onIssue(issue)
        }

        /// Сколько жалоб уже приняли от этой страницы.
        private var accepted = 0

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel); return
            }
            switch PlaygroundWebKit.mayNavigate(to: url, insideRoot: rootURL) {
            case .allow:
                decisionHandler(.allow)
            case .cancelQuietly:
                decisionHandler(.cancel)
            case .blockedNetwork(let where_):
                onIssue(PlaygroundIssue(kind: .blockedNetwork,
                                        text: "страница попыталась выйти в интернет: \(where_)",
                                        line: nil))
                decisionHandler(.cancel)
            case .outsideFolder:
                onIssue(PlaygroundIssue(kind: .blockedNetwork,
                                        text: "страница попыталась открыть файл за пределами папки",
                                        line: nil))
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            // Отменённый нами же переход — не поломка, о ней уже сказали отдельно.
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            onIssue(PlaygroundIssue(kind: .failedToOpen, text: error.localizedDescription, line: nil))
        }

        /// Страница попросила открыть новое окно — новых окон у нас нет.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, !url.isFileURL {
                onIssue(PlaygroundIssue(kind: .blockedNetwork,
                                        text: "страница попыталась открыть окно наружу: \(Self.hostText(of: url))",
                                        line: nil))
            }
            return nil
        }

        /// Что показать человеку вместо адреса: человеческое имя, а не ссылку целиком.
        private static func hostText(of url: URL) -> String {
            url.host ?? url.scheme ?? "неизвестный адрес"
        }

    }
}
