// Shared button chrome used across the calibration/accuracy/reading/settings
// screens -- extracted so no single screen "owns" it (CalibrationView used
// to define it, but its whole implementation gets swapped out for pursuit
// calibration).

import SwiftUI

struct PillButtonStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption).bold()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
}
