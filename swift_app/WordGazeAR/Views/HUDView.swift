// Debug HUD -- same fields as ui/hud.py's Hud panel: line/word position,
// Z-cut diagnostics, and huge-jump distance/threshold, so the Z-cut and
// jump-relocation mechanics stay legible while testing on device.

import SwiftUI

struct HUDView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Debug HUD").font(.caption).bold().foregroundColor(.white)
                Spacer()
                Text(model.faceVisible ? "face ok" : "face lost")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(model.faceVisible ? Color(red: 0.133, green: 0.773, blue: 0.369)
                                                          : Color(red: 0.937, green: 0.267, blue: 0.267))
            }
            ForEach(Array(model.hudLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.85))
            }
            HStack(spacing: 4) {
                Text("Z-cut:").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                Text(model.zcutFlash ? "YES \u{21A9}" : "-")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(model.zcutFlash ? Color(red: 0.133, green: 0.773, blue: 0.369) : Color(white: 0.85))
            }
        }
        .padding(8)
        .background(Color(red: 0.067, green: 0.078, blue: 0.094).opacity(0.92))
        .cornerRadius(8)
        .frame(maxWidth: 230, alignment: .leading)
    }
}
