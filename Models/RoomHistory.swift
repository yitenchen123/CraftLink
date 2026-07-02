import Foundation

enum RoomRole: String, Codable {
    case host = "房主"
    case client = "加入者"
}

struct RoomHistory: Identifiable, Codable, Equatable {
    let id: UUID
    var inviteCode: String
    var role: RoomRole
    var port: String?
    var timestamp: Date
    var virtualIP: String

    init(id: UUID = UUID(), inviteCode: String, role: RoomRole, port: String? = nil, timestamp: Date = Date(), virtualIP: String) {
        self.id = id
        self.inviteCode = inviteCode
        self.role = role
        self.port = port
        self.timestamp = timestamp
        self.virtualIP = virtualIP
    }

    var formattedTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}

class RoomHistoryStore: ObservableObject {
    static let shared = RoomHistoryStore()
    @Published var histories: [RoomHistory] = []

    private let key = "roomHistory"
    private let maxCount = Constants.maxHistoryCount

    private init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RoomHistory].self, from: data) else {
            histories = []
            return
        }
        histories = decoded.sorted { $0.timestamp > $1.timestamp }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(histories) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ history: RoomHistory) {
        histories.removeAll { $0.inviteCode == history.inviteCode }
        histories.insert(history, at: 0)
        if histories.count > maxCount {
            histories = Array(histories.prefix(maxCount))
        }
        save()
    }

    func remove(at indexSet: IndexSet) {
        histories.remove(atOffsets: indexSet)
        save()
    }

    func removeAll() {
        histories.removeAll()
        save()
    }

    func remove(id: UUID) {
        histories.removeAll { $0.id == id }
        save()
    }

    var latest: RoomHistory? {
        histories.first
    }
}
