//
//  CoreSelectionView.swift
//  ManicEmu
//
//  Created by Daiuno on 2025/6/28.
//  Copyright © 2025 Manic EMU. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

class CoreSelectionView: BaseView {
    static func show(games: [Game], completion: (() -> Void)? = nil) {
        guard let firstGame = games.first else {
            return
        }
        
        let games = games.filter({ $0.gameType == firstGame.gameType })
        
        let detailString = games.reduce("", {
            $0 + ($0.isEmpty ? "" : ", ") + $1.displayName
        })
        
        //We've made sure that all incoming games are of the same game type.
        let supportCores = firstGame.gameType.supportCores
        let options = supportCores.filter({ !$0.isEmpty })
        
        var selectedIndex: Int? = nil
        if (games.count == 1 || (games.count > 1 && games.allSatisfy({ $0.defaultCore == firstGame.defaultCore }))),
            firstGame.defaultCore < supportCores.count,
            let index = options.firstIndex(where: { $0 == supportCores[firstGame.defaultCore] }) {
            selectedIndex = index
        }
        
        var detail = R.string.localizable.switchEmulationCoreDetail(detailString)
        if firstGame.gameType == ._3ds {
            detail += "\nAzahar FastInterp uses separate save states. In-game saves stay in the same 3DS folder; switch back to Azahar to use its existing states."
        }
        OptionsSheetView.show(icon: GameOption.switchCore.icon,
                               title: R.string.localizable.switchEmulationCore(),
                               detail: detail,
                               options: options,
                               selectedIndex: selectedIndex,
                               completion: { index in
            if let index,
               let coreIndex = supportCores.firstIndex(of: options[index]) {
                for game in games {
                    game.changeDefaultCore(coreIndex: coreIndex)
                }
                completion?()
            }
        })
    }
}
