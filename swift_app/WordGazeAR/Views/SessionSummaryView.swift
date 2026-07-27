// Shown right after ReadingView's "Finish" button. Recaps what was just
// recorded (AppModel.lastSessionPayload) and surfaces the Supabase upload
// status -- the session's local JSON copy (SessionStorage) already exists
// by the time this view appears regardless of how the upload goes, so a
// failure here is "retry the network part," never "the data is gone."

import SwiftUI

struct SessionSummaryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Session complete")
                    .font(.title2).bold()
                    .foregroundColor(.white)

                if let payload = model.lastSessionPayload {
                    recap(payload)
                    uploadStatus
                    topWords(payload)
                } else {
                    Text("No session data recorded.")
                        .foregroundColor(Color(white: 0.75))
                }

                Button {
                    model.returnHomeAfterSummary()
                } label: {
                    Text("Done")
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.145, green: 0.388, blue: 0.922))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 520)
            .background(Color(red: 0.082, green: 0.094, blue: 0.133))
            .cornerRadius(16)
            .padding(.vertical, 40)
        }
    }

    private func recap(_ payload: ReadingSessionPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Participant", "\(payload.participantName), age \(payload.participantAge), \(payload.readingProficiency) proficiency")
            row("Passage", "\(payload.passageTitle) (\(payload.passageDifficulty))")
            row("Duration", String(format: "%.1fs", payload.durationSeconds))
            row("Words in passage", "\(payload.wordCount)")
            row("Words fixated", "\(payload.heatmap.count)")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.footnote)
                .foregroundColor(Color(white: 0.6))
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.footnote)
                .foregroundColor(.white)
        }
    }

    private var uploadStatus: some View {
        HStack(spacing: 8) {
            switch model.uploadState {
            case .idle:
                EmptyView()
            case .uploading:
                ProgressView().tint(.white)
                Text("Uploading to Supabase…")
                    .font(.footnote)
                    .foregroundColor(Color(white: 0.75))
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color(red: 0.133, green: 0.773, blue: 0.369))
                Text("Uploaded to Supabase")
                    .font(.footnote)
                    .foregroundColor(Color(white: 0.85))
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Color(red: 0.97, green: 0.44, blue: 0.44))
                        Text("Upload failed — saved on-device, safe to retry")
                            .font(.footnote)
                            .foregroundColor(Color(white: 0.85))
                    }
                    Text(message)
                        .font(.caption2)
                        .foregroundColor(Color(white: 0.55))
                    Button("Retry upload") { model.retryLastUpload() }
                        .buttonStyle(PillButtonStyle(color: Color.gray.opacity(0.4)))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func topWords(_ payload: ReadingSessionPayload) -> some View {
        let top = payload.heatmap.sorted { $0.seconds > $1.seconds }.prefix(5)
        return VStack(alignment: .leading, spacing: 6) {
            if !top.isEmpty {
                Text("Longest dwell times")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.6))
                ForEach(Array(top), id: \.wordIndex) { visit in
                    HStack {
                        Text("\"\(visit.word)\"")
                            .foregroundColor(.white)
                        Spacer()
                        Text(String(format: "%.2fs", visit.seconds))
                            .foregroundColor(Color(white: 0.7))
                            .monospacedDigit()
                    }
                    .font(.footnote)
                }
            }
        }
    }
}
