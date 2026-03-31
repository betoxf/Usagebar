//
//  UsageData.swift
//  JustaUsageBar
//

import Foundation

// MARK: - API Response Models

struct UsageResponse: Codable {
    let dailyUsage: DailyUsage?
    let messageLimit: MessageLimit?

    enum CodingKeys: String, CodingKey {
        case dailyUsage = "daily_usage"
        case messageLimit = "message_limit"
    }
}

struct DailyUsage: Codable {
    let used: Int
    let limit: Int
    let resetAt: String?

    enum CodingKeys: String, CodingKey {
        case used
        case limit
        case resetAt = "reset_at"
    }

    var percentage: Double {
        guard limit > 0 else { return 0 }
        return Double(used) / Double(limit) * 100
    }
}

struct MessageLimit: Codable {
    let remaining: Int?
    let type: String?
}

// MARK: - App Models

struct UsageData {
    // 5-hour window
    var fiveHourUsed: Int = 0
    var fiveHourLimit: Int = 100
    var fiveHourResetAt: Date?

    // Weekly limit
    var weeklyUsed: Int = 0
    var weeklyLimit: Int = 100
    var weeklyResetAt: Date?

    var fiveHourPercentage: Double {
        guard fiveHourLimit > 0 else { return 0 }
        return min(Double(fiveHourUsed) / Double(fiveHourLimit) * 100, 100)
    }

    var weeklyPercentage: Double {
        guard weeklyLimit > 0 else { return 0 }
        return min(Double(weeklyUsed) / Double(weeklyLimit) * 100, 100)
    }

    var timeUntilFiveHourReset: String {
        guard let resetAt = fiveHourResetAt else { return "--" }
        return formatTimeUntil(resetAt)
    }

    var timeUntilWeeklyReset: String {
        guard let resetAt = weeklyResetAt else { return "--" }
        return formatTimeUntil(resetAt)
    }

    private func formatTimeUntil(_ date: Date) -> String {
        let now = Date()
        guard date > now else { return "Now" }

        let interval = date.timeIntervalSince(now)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "\(days)d \(remainingHours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    // For menu bar display
    var menuBarText: String {
        let pct = Int(fiveHourPercentage)
        let reset = timeUntilWeeklyReset
        return "\(pct)% | \(reset)"
    }

    static let placeholder = UsageData()
}

// MARK: - Usage Color

import SwiftUI

extension UsageData {
    var statusColor: Color {
        let pct = fiveHourPercentage
        if pct < 50 {
            return .green
        } else if pct < 80 {
            return .yellow
        } else {
            return .red
        }
    }
}
