import Foundation

struct RoomHistory: Identifiable {
    let id = UUID()
    let inviteCode: String
    let joinDate: Date
}