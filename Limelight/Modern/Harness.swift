//
//  Harness.swift
//  Moonlight Duo
//
//  DEBUG only. Lays the whole app out at a chosen size (the iPhone Duo inner display,
//  the outer display in landscape, ...) and scales it into the simulator's window, so
//  every display and pose can be screenshotted without Device Hub. Renders, not captures:
//  the system's own bars and safe areas for that display are not simulated.
//

#if DEBUG
import UIKit
import SwiftUI

final class HarnessViewController: UIViewController {
    static weak var current: HarnessViewController?

    private let content: UIViewController
    private let size: CGSize
    private let root = UIView()

    init(content: UIViewController, size: CGSize) {
        self.content = content
        self.size = size
        super.init(nibName: nil, bundle: nil)
        Self.current = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)
        root.accessibilityIdentifier = "MLHarnessRoot"
        root.bounds = CGRect(origin: .zero, size: size)
        root.clipsToBounds = true
        root.backgroundColor = .black
        view.addSubview(root)
        embed(content)
        if let hosting = content as? UIHostingController<RootView> {
            hosting.safeAreaRegions = []
        }
    }

    func embed(_ child: UIViewController) {
        applyTraits(to: child)
        addChild(child)
        child.view.frame = root.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(child.view)
        child.didMove(toParent: self)
    }

    private func applyTraits(to child: UIViewController) {
        let large = min(size.width, size.height) >= 560
        child.traitOverrides.horizontalSizeClass = large ? .regular : .compact
        child.traitOverrides.verticalSizeClass = (large || size.height > size.width) ? .regular : .compact
        child.traitOverrides.userInterfaceStyle = .dark
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Fit inside the window's safe area so no safe-area inset leaks into the render.
        let area = view.safeAreaLayoutGuide.layoutFrame
        let scale = min(area.width / size.width, area.height / size.height)
        root.transform = CGAffineTransform(scaleX: scale, y: scale)
        root.center = CGPoint(x: area.midX, y: area.midY)
        let f = root.frame
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let text = String(format: "%.2f %.2f %.2f %.2f %.4f", f.minX, f.minY, f.width, f.height, scale)
            try? text.write(to: docs.appendingPathComponent("harness-frame.txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
