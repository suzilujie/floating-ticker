import Foundation

/// 简易环形日志：无调试器环境下，把关键状态收集起来，显示在应用内。
///
/// 设计文档第 9 章强调：无断点调试时日志质量直接决定排错效率。
/// M1 黑屏排查即依赖此日志定位「帧到底卡在哪一步」。
final class LogCollector {

    static let shared = LogCollector()

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 300

    private init() {}

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    /// 返回日志快照（按时间顺序，旧在前）
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines)
    }
}
