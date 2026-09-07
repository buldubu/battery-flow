import SwiftUI

/// Shared macOS text roles: 13 pt interface text, 12 pt supporting text, 15 pt readings.
enum AppTypography {
    static let body = Font.body
    static let secondary = Font.callout
    static let section = Font.body.weight(.semibold)
    static let reading = Font.title3.weight(.medium).monospacedDigit()
    static let icon = Font.system(size: 18)
}
