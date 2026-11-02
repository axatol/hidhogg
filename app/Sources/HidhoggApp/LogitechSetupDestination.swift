import Foundation

enum LogitechSetupDestination: Equatable {
    case newRegistration
    case reassociate(UUID)
}
