import Foundation

enum AppVersion {
    static let current = "2026-04-08"

    static func validationError(for version: String = current) -> String? {
        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        guard version.range(of: pattern, options: .regularExpression) != nil else {
            return "版本号格式无效：\(version)。期望 YYYY-MM-DD，例如 2026-04-08。"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        guard let date = formatter.date(from: version),
              formatter.string(from: date) == version else {
            return "版本号日期无效：\(version)。请使用真实存在的 YYYY-MM-DD 日期。"
        }

        return nil
    }
}
