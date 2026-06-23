import Foundation

struct SessionDaySection: Identifiable {
    var day: Date
    var sessions: [CaptureSessionSummary]

    var id: Date {
        day
    }
}
