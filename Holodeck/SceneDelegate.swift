//
//  SceneDelegate.swift
//  Holodeck
//
//  Created by Harold Martin on 10/7/26.
//

import UIKit
import Dependencies

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    #if DEBUG
    private var uiTestFixtures: UITestFixtures?
    #endif

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        #if DEBUG
        let fixtures = UITestFixtures()
        uiTestFixtures = fixtures
        #endif
        let controller = withDependencies {
            // XCTest still launches a real host scene before constructing scoped test controllers.
            let isTestHost = $0.context == .test
            $0.context = .live
            if isTestHost { $0.shaderPreferences = .inMemory() }
            #if DEBUG
            fixtures.configure(&$0)
            #endif
        } operation: {
            UIStoryboard(name: "Main", bundle: nil).instantiateInitialViewController() as? GameViewController
        }
        guard let controller else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        self.window = window
        #if DEBUG
        fixtures.installControls(on: controller)
        #endif
        window.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        (window?.rootViewController as? GameViewController)?.setSceneActive(true)
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        (window?.rootViewController as? GameViewController)?.setSceneActive(false)
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        (window?.rootViewController as? GameViewController)?.setSceneActive(false)
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }

}
