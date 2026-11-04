//
//  SceneDelegate.swift
//  Moonlight Duo
//
//  UIScene life cycle (required by the iOS 27 SDK) hosting the SwiftUI shell.
//

import UIKit
import SwiftUI

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var model: MoonlightModel?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let appDelegate = UIApplication.shared.delegate as? AppDelegate

        if let shortcut = connectionOptions.shortcutItem, let uuid = shortcut.userInfo?["UUID"] as? String {
            appDelegate?.pcUuidToLoad = uuid
        }

        let model = MoonlightModel()
        let hosting = UIHostingController(rootView: RootView(model: model))
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = hosting
        model.presenter = hosting
#if DEBUG
        // -MLHarness 890x626: lay the app out at another size (iPhone Duo inner display, ...)
        // scaled into this window, for screenshots of displays the simulator isn't showing.
        if let spec = UserDefaults.standard.string(forKey: "MLHarness") {
            let parts = spec.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                window.rootViewController = HarnessViewController(content: hosting, size: CGSize(width: parts[0], height: parts[1]))
            }
        }
#endif

        self.model = model
        self.window = window
        appDelegate?.window = window
        window.makeKeyAndVisible()
#if DEBUG
        model.applyDebugLaunchActions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            SettingsSelfTest.runIfRequested(window: window)
        }
#endif
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        appDelegate?.pcUuidToLoad = shortcutItem.userInfo?["UUID"] as? String
        appDelegate?.shortcutCompletionHandler = completionHandler
        model?.handlePendingShortcut()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        model?.sceneDidBecomeActive()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        model?.sceneWillResignActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?.saveContext()
    }
}
