import Foundation

/// 价格报警的配置项。
///
/// **语义（2026-09-21 简化，去掉容差与冷却）**：
/// 不再用「目标价 ± 容差」的触发带，而是**直接用目标价作为硬阈值**：
///
/// - 价格处于「触发侧」（默认：低于目标价）→ 报警，并持续响
/// - 价格回到另一侧 → **自动停止**
/// - 报警期间可手动停止；手动停止后进入静默，**需价格先回到另一侧、再次进入触发侧**才重新报警
///
/// 这样"配置 69000，跌到 69000 以下就一直报"的直觉得以直接实现，
/// 也避免了容差带来的"到底 69000 还是 68950 才算"的含糊。
///
/// 保留 `onlyDown` 只是为了支持反向用法（涨破某价位时报警）。
struct AlertConfig: Codable, Equatable {

    /// 是否启用报警
    var isEnabled: Bool = true

    /// 目标价（硬阈值，不再有容差）
    var targetPrice: Double = 69000

    /// 触发方向：
    /// - `true`（默认）：**跌破**目标价（价格 &lt; 目标价）时报警
    /// - `false`：**涨破**目标价（价格 &gt; 目标价）时报警
    var onlyDown: Bool = true

    /// 目标价文本：取整、不加千分位，短而醒目（悬浮窗内要一眼看清）
    var targetText: String { String(format: "%.0f", targetPrice) }

    /// 当前价格是否处于「触发侧」
    func isTriggeredSide(_ price: Double) -> Bool {
        onlyDown ? price < targetPrice : price > targetPrice
    }

    /// 「非触发侧」的方位描述（仅用于日志与界面文案）
    var safeSideText: String { onlyDown ? "上方" : "下方" }
}

// MARK: - 持久化

extension AlertConfig {

    private static let storageKey = "alert.config.v1"

    /// 读取配置。
    ///
    /// 向后兼容说明：旧存档里还有 `tolerance` / `cooldown` / `resetMultiplier` 字段，
    /// 它们在新结构里已不存在 —— `JSONDecoder` 会直接忽略这些多余键，
    /// 而 `isEnabled` / `targetPrice` / `onlyDown` 三个键名未变，会正常还原。
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
