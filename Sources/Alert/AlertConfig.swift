import Foundation

/// 价格报警的配置项。
///
/// **语义（2026-09-21 简化后）**：
/// - **不设容差**：目标价就是硬阈值
/// - **不分方向**：向上、向下**穿过**都算 —— 所以不需要"方向"这个选项
/// - **穿一次报一次**：每次穿越触发一次报警
/// - 报警**不会自动停止**，一直响到用户手动按「停止」
///
/// 为什么不分方向：用户要的是「价格穿过 69000 就提醒」，两个方向同样有意义
/// （跌穿＝跌破关键位，涨穿＝重新站上）。指定方向反而丢了一半信息。
///
/// 反复轰炸的问题由"**穿越式**"本身化解：只有真的穿过才算数，
/// 价格在同一侧持续波动不会重复触发（详见 AlertEngine.crossed）。
struct AlertConfig: Codable, Equatable {

    /// 是否启用报警
    var isEnabled: Bool = true

    /// 目标价（硬阈值，无容差）
    var targetPrice: Double = 69000

    /// 目标价文本：取整、不加千分位，短而醒目（悬浮窗内要一眼看清）
    var targetText: String { String(format: "%.0f", targetPrice) }
}

// MARK: - 持久化

extension AlertConfig {

    private static let storageKey = "alert.config.v1"

    /// 读取配置。
    ///
    /// 向后兼容说明：旧存档里还有 `tolerance` / `cooldown` / `resetMultiplier` /
    /// `onlyDown` 等字段，它们在新结构里已不存在 —— `JSONDecoder` 会直接忽略这些
    /// 多余键；而 `isEnabled` / `targetPrice` 两个键名未变，会正常还原。
    /// 因此**无需迁移代码**。
    static func load() -> AlertConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(AlertConfig.self, from: data) else {
            return AlertConfig()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
