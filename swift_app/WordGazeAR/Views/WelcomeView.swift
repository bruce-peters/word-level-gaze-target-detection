import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Read with your eyes")
                .font(.title2).bold()
                .foregroundColor(.white)

            Text("This uses ARKit's TrueDepth eye tracking (each eye's leftEyeTransform / rightEyeTransform) to estimate where you're looking on screen, and highlights the word and line you're reading as you go.")
                .font(.subheadline)
                .foregroundColor(Color(white: 0.75))

            VStack(alignment: .leading, spacing: 6) {
                numbered(1, "Allow camera access. Nothing leaves this device.")
                numbered(2, "Follow the moving dot with just your eyes for about 15 seconds -- keep your head still.")
                numbered(3, "Stare at one more dot for a few seconds to measure your gaze noise.")
                numbered(4, "Just read. Tracking starts automatically once that's done.")
                numbered(5, "Double-tap any word any time to jump the reading position there by hand.")
            }

            if !ARGazeEstimator.isSupported {
                Text("⚠️ This device has no TrueDepth camera. Face tracking needs a physical iPhone X/iPad Pro (Face ID) or newer — it also won't run in the Simulator.")
                    .font(.footnote)
                    .foregroundColor(.orange)
            } else {
                Text("Hold the device about 30–50cm away, keep your face in frame, and use even lighting.")
                    .font(.footnote)
                    .foregroundColor(Color(red: 0.984, green: 0.749, blue: 0.141))
            }

            Button {
                model.beginCalibration()
            } label: {
                Text("Start calibration")
                    .bold()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.145, green: 0.388, blue: 0.922))
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(!ARGazeEstimator.isSupported)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .background(Color(red: 0.082, green: 0.094, blue: 0.133))
        .cornerRadius(16)
    }

    private func numbered(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").foregroundColor(.gray)
            Text(text).foregroundColor(Color(white: 0.9))
        }
        .font(.footnote)
    }
}
