//
//  DemoData.swift
//  Moonlight Duo
//
//  DEBUG only: launch with -MLDemo YES for sample PCs and games without a network,
//  so layouts can be checked on every iPhone Duo display and pose. Starting a game
//  opens the stream screen with a test pattern instead of video.
//

#if DEBUG
import UIKit

enum DemoData {
    static func makeHosts() -> [TemporaryHost] {
        let desk = host(name: "Gaming PC", uuid: "demo-desk", state: .online, paired: true,
                        apps: ["Steam Big Picture", "Desktop", "Cyberpunk 2077", "Forza Horizon 5",
                               "Hades II", "Hollow Knight: Silksong", "Elden Ring", "Balatro",
                               "Baldur's Gate 3", "Stardew Valley", "Rocket League", "Celeste"],
                        running: "3")
        let mini = host(name: "Mac mini (Lumen)", uuid: "demo-mini", state: .online, paired: true,
                        apps: ["Desktop", "Dolphin", "Ryujinx"], running: nil)
        let laptop = host(name: "Living Room", uuid: "demo-tv", state: .online, paired: false, apps: [], running: nil)
        let office = host(name: "Office Tower", uuid: "demo-office", state: .offline, paired: true, apps: ["Desktop"], running: nil)
        return [desk, mini, laptop, office]
    }

    private static func host(name: String, uuid: String, state: State, paired: Bool,
                             apps: [String], running: String?) -> TemporaryHost {
        let host = TemporaryHost()
        host.name = name
        host.uuid = uuid
        host.state = state
        host.pairState = paired ? .paired : .unpaired
        host.currentGame = running ?? "0"
        host.mac = "00:11:22:33:44:55"
        var list: [TemporaryApp] = []
        for (index, title) in apps.enumerated() {
            let app = TemporaryApp()
            app.id = "\(index + 1)"
            app.name = title
            app.host = host
            app.hidden = title == "Desktop" && uuid == "demo-desk"
            list.append(app)
        }
        host.appList = Set(list.map { $0 as AnyHashable })
        return host
    }
}
#endif
