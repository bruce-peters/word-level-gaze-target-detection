// First screen of the data-collection flow: capture participant metadata
// and let the tester pick which bundled passage (passages.json via
// PassageStore) to run. "Continue" hands both off to
// AppModel.beginSession(participant:passage:), which swaps the passage text
// into LayoutModel and moves on to the existing WelcomeView/calibration flow.

import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel

    @State private var name: String = ""
    @State private var ageText: String = ""
    @State private var proficiency: ReadingProficiency = .medium
    @State private var selectedPassageID: String?

    private var selectedPassage: Passage? {
        model.passages.first { $0.id == selectedPassageID }
    }

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(ageText) != nil
            && selectedPassage != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Reading Session Setup")
                    .font(.title2).bold()
                    .foregroundColor(.white)

                Text("Enter the participant's details and pick a passage before calibrating.")
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.75))

                Button {
                    model.beginQuickTest()
                } label: {
                    Text("Quick test — skip straight to Winnie-the-Pooh")
                        .font(.footnote).bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(PillButtonStyle(color: Color.gray.opacity(0.35)))

                field("Name") {
                    TextField("Participant name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                field("Age") {
                    TextField("Age", text: $ageText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                }

                field("Reading proficiency") {
                    Picker("Reading proficiency", selection: $proficiency) {
                        ForEach(ReadingProficiency.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                field("Passage") {
                    if model.passages.isEmpty {
                        Text("No passages found -- check that passages.json is bundled with the app target (see swift_app/README.md).")
                            .font(.footnote)
                            .foregroundColor(Color(red: 0.97, green: 0.44, blue: 0.44))
                    } else {
                        VStack(spacing: 8) {
                            ForEach(model.passages) { passage in
                                passageRow(passage)
                            }
                        }
                    }
                }

                if model.pendingUploadCount > 0 {
                    Button {
                        model.retryPendingUploads()
                    } label: {
                        Text("\(model.pendingUploadCount) session\(model.pendingUploadCount == 1 ? "" : "s") pending upload — Retry")
                            .font(.footnote)
                    }
                    .buttonStyle(PillButtonStyle(color: Color.gray.opacity(0.35)))
                }

                Button {
                    guard let age = Int(ageText), let passage = selectedPassage else { return }
                    let participant = ParticipantInfo(
                        name: name.trimmingCharacters(in: .whitespaces),
                        age: age,
                        proficiency: proficiency
                    )
                    model.beginSession(participant: participant, passage: passage)
                } label: {
                    Text("Continue")
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(canContinue ? Color(red: 0.145, green: 0.388, blue: 0.922) : Color.gray.opacity(0.3))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(!canContinue)
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 520)
            .background(Color(red: 0.082, green: 0.094, blue: 0.133))
            .cornerRadius(16)
            .padding(.vertical, 40)
        }
        .onAppear(perform: prefill)
    }

    private func prefill() {
        if let p = model.participant {
            name = p.name
            ageText = String(p.age)
            proficiency = p.proficiency
        }
        selectedPassageID = model.selectedPassage?.id ?? model.passages.first?.id
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(Color(white: 0.6))
            content()
        }
    }

    private func passageRow(_ passage: Passage) -> some View {
        let isSelected = passage.id == selectedPassageID
        let wordCount = passage.text.split(separator: " ").count
        return Button {
            selectedPassageID = passage.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(passage.title)
                        .foregroundColor(.white)
                        .font(.subheadline).bold()
                    Text("\(passage.difficulty.label) • \(wordCount) words")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.65))
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(red: 0.133, green: 0.773, blue: 0.369))
                }
            }
            .padding(10)
            .background(isSelected ? Color(red: 0.145, green: 0.388, blue: 0.922).opacity(0.25) : Color.black.opacity(0.2))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}
