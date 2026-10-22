//
//  ShareSheet.swift
//  PocketAgent
//
//  Системное окно «Поделиться» для файла, который уже лежит в папке человека.
//
//  ⚠️ ЗАЧЕМ ОТДЕЛЬНАЯ ОБЁРТКА, КОГДА ЕСТЬ ShareLink.
//  `ShareLink` — это кнопка, и она хороша там, где кнопка и нужна (строка результата
//  в ленте). Но пункт меню по долгому нажатию кнопкой быть не может: меню сначала
//  закрывается, и только потом выполняется действие. Поэтому пункт меню лишь поднимает
//  флаг, а окно показывается обычной страницей — вот ею.
//
//  ⚠️ ПРИЛОЖЕНИЕ САМО НИКУДА НИЧЕГО НЕ ОТПРАВЛЯЕТ. Открывается системное окно,
//  и файл уносит человек — в «Файлы», в почту, в мессенджер. Никакой сети здесь нет.
//

import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {

    /// Файл, который человек забирает из папки проекта.
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        // Окно показывается один раз и ничего не перестраивает.
    }
}
