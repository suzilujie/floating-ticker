import Foundation

/// 价格报警的配置项。
///
/// 设计取舍：
/// - 阈值、容差、方向、时长、冷却全部可配，并持久化到 UserDefaults，
///   重启 App 不丢（免费证书每 7 天要重签，重设配置会很烦）。
/// - 用「容差」把"到达 xxx 附近"量化成一个价格带，避免用浮点数相等判定
///   （行情是浮点值，几乎不可能正好等于 69000）。
struct AlertConfig: Codable, Equatable {

    /// 是否启用报警
    var isEnabled: Bool = true

    /// 目标价（触发基准）
    var targetPrice: Double = 69000

    /// 容差：价格进入 [目标−容差, 目标+容差] 即视为「到达附近」
    var tolerance: Double = 50

    /// 触发方向：true = 仅向下跌破；false = 双向（涨到或跌到都报）
    var onlyDown: Bool = true

    /// 单次报警持续时长（秒）
    var duration: TimeInterval = 20

    /// 报警结束后的冷却时长（秒）——防止价格在阈值附近徘徊时反复轰炸
    var cooldown: TimeInterval = 60

    /// 解除冷却所需的「离开距离」倍数：价格必须离开目标超过 容差×该倍数，
    /// 才重新武装。这是迟滞（hysteresis）设计，是防轰炸的关键。
    var resetMultiplier: Double = 2

    /// 触发带上沿
    var upperBand: Double { targetPrice + tolerance }

    /// 触发带下沿
    var lowerBand: Double { targetPrice - tolerance }

    /// 目标价文本：取整、不加千分位，短而醒目（悬浮窗内要一眼看清）
    var targetText: String { String(format: "%.0f", targetPrice) }
}

// MARK: - 持久化

extension AlertConfig {

    private static let storageKey = "alert.config.v1"

    /// 旧版本的冷却默认值（5 分钟）。仅用于迁移判断，**不要再改动**：
    /// 存档里若仍是这个值，说明它来自旧默认值、而非用户的自选值。
    private static let legacyCooldown: TimeInterval = 300

    static func load() -> AlertConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var decoded = try? JSONDecoder().decode(AlertConfig.self, from: data) else {
            return AlertConfig()
        }

        // 迁移：把"仍是旧默认值"的冷却从 300 秒改为新的 60 秒。
        // 必须显式迁移 —— 已装机的设备会继续沿用存档里的值，
        // 只改代码里的默认值等于没改（UserDefaults 存档的典型坑）。
        if decoded.cooldown == legacyCooldown {
            decoded.cooldown = AlertConfig().cooldown
            decoded.save()
            LogCollector.shared.append("alert: 冷却默认值迁移为 \(Int(decoded.cooldown)) 秒")
        }

        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
