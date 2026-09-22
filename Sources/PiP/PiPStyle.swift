import Combine
import Foundation

/// 浮窗画面样式（诊断用的可调项）。
///
/// **为什么要有「透明」这一档**：iOS 的画中画窗口由系统托管，官方从未提供
/// 「透明窗口 / 异形窗口」能力 —— 视频帧的 alpha 通道**是否会被系统用来「透视」
/// 到后面的 App**，无法从文档断定，只能真机实测。
///
/// 做成可切换项的理由：显存/画面是逐帧重绘的，**切换后立刻生效**（不必重开浮窗），
/// 因此一轮构建就能把两种形态对比完，不用为每种样式各等一次 CI。
///
/// 若透明实测有效，收益很大：可以让浮窗**只显示内容区那一小块底色**，
/// 视觉上等于把浮窗缩小到可接受的程度。
final class PiPStyle: ObservableObject {

    static let shared = PiPStyle()

    /// 浮窗背景形态
    enum Background: String, CaseIterable {
        /// 深色铺满整张画布（默认，现状）
        case dark
        /// 仅内容区绘深色圆角底，四周保持透明（实验档）
        case transparent
    }

    @Published var background: Background {
        didSet {
            guard background != oldValue else { return }
            UserDefaults.standard.set(background.rawValue, forKey: Self.storageKey)
            LogCollector.shared.append(
                "pip: 浮窗背景切换为 \(background == .dark ? "深色铺满" : "透明留白（实验）")"
            )
        }
    }

    private static let storageKey = "pip.background.v1"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        background = Background(rawValue: raw) ?? .dark
    }
}
