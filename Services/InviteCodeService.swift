import Foundation

struct InviteCodeService {
    static func generate() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let groups = (0..<4).map { _ in
            String((0..<4).map { _ in chars.randomElement()! })
        }
        return "U/" + groups.joined(separator: "-")
    }
    
    static func isValid(_ code: String) -> Bool {
        let pattern = "^U/[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$"
        return code.uppercased().range(of: pattern, options: .regularExpression) != nil
    }
    
    static func networkName(from code: String) -> String {
        return code.uppercased()
            .replacingOccurrences(of: "U/", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}