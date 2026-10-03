//
//  ExternalSceneDelegate.swift
//  ManicEmu
//
//  Created by Daiuno on 2025/3/9.
//  Copyright c 2025 Manic EMU. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-or-later
import RealmSwift

/// ???????????????
class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    static var isAirPlaying = false
    var window: UIWindow?
    private var settingsUpdateToken: Any? = nil
    private var membershipNotification: Any? = nil
    private var startPlayGameNotification: Any? = nil
    private var stopPlayGameNotification: Any? = nil
    static weak var airPlayViewController: AirPlayViewController?
    static weak var externalWindow: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let windowScene = scene as? UIWindowScene {
            ExternalSceneDelegate.isAirPlaying = true
            window = UIWindow(windowScene: windowScene)
            ExternalSceneDelegate.externalWindow = window
            window?.tintColor = R.Color.Main
            let airPlayViewController = AirPlayViewController()
            window?.rootViewController = airPlayViewController
            ExternalSceneDelegate.airPlayViewController = airPlayViewController
            window?.makeKeyAndVisible()
            updateScene()
            //????airPlay??
            settingsUpdateToken = Settings.defalut.observe(keyPaths: [\Settings.airPlay]) { [weak self] change in
                guard let self = self else { return }
                switch change {
                case .change(_, _):
                    Log.debug("airPlay????,??Scene")
                    self.updateScene()
                default:
                    break
                }
            }
            
            //????????
            membershipNotification = NotificationCenter.default.addObserver(forName: R.NotificationName.MembershipChange, object: nil, queue: .main) { [weak self] notification in
                self?.updateScene()
            }
            //??????
            startPlayGameNotification = NotificationCenter.default.addObserver(forName: R.NotificationName.StartPlayGame, object: nil, queue: .main) { [weak self] notification in
                self?.updateScene()
            }
            //??????
            stopPlayGameNotification = NotificationCenter.default.addObserver(forName: R.NotificationName.StopPlayGame, object: nil, queue: .main) { [weak self] notification in
                self?.updateScene()
            }
        }
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {
        window?.isHidden = true
        window?.removeFromSuperview()
        window = nil
        settingsUpdateToken = nil
        if let membershipNotification = membershipNotification {
            NotificationCenter.default.removeObserver(membershipNotification)
        }
        if let startPlayGameNotification = startPlayGameNotification {
            NotificationCenter.default.removeObserver(startPlayGameNotification)
        }
        if let stopPlayGameNotification = stopPlayGameNotification {
            NotificationCenter.default.removeObserver(stopPlayGameNotification)
        }
        membershipNotification = nil
        ExternalSceneDelegate.isAirPlaying = false
        ExternalSceneDelegate.airPlayViewController = nil
        ExternalSceneDelegate.externalWindow = nil
        PlayViewController.updateAirPlay()
    }

    func windowScene(_ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace,
                     interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
                     traitCollection previousTraitCollection: UITraitCollection) {
        // Recalculate the external view's aspect fit after display rotation or a size change.
        PlayViewController.updateAirPlay()
    }
    
    private func updateScene() {
        if PurchaseManager.isMember, Settings.defalut.airPlay, PlayViewController.isGaming, PlayViewController.enableAirplay {
            window?.isHidden = false
        } else {
            // Mirror the phone instead
            window?.isHidden = true
        }
        // Re-route after the external controller exists and whenever AirPlay or
        // membership changes; a scene notification may arrive before this point.
        PlayViewController.updateAirPlay()
    }
}

