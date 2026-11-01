import SwiftUI

struct BatteryAlertThresholdControl: View {
    @Binding var threshold: Int
    @State private var draft: String
    @FocusState private var isEditing: Bool

    init(threshold: Binding<Int>) {
        _threshold = threshold
        _draft = State(initialValue: String(threshold.wrappedValue))
    }

    var body: some View {
        HStack {
            Text("Alert at or below")
            TextField("Percentage", text: $draft)
                .frame(width: 48)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .focused($isEditing)
                .onSubmit(commit)
                .accessibilityLabel("Low battery threshold")
                .help("Enter a percentage from 1 to 100. Press Return to apply.")
            Text("%")
            Stepper("Low battery threshold", value: $threshold, in: 1...100)
                .labelsHidden()
        }
        .onChange(of: isEditing) { _, editing in
            if !editing { commit() }
        }
        .onChange(of: threshold) { _, value in
            draft = String(value)
        }
        .task(id: draft) {
            guard let value = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...100).contains(value), value != threshold else { return }
            let previousThreshold = threshold
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard !Task.isCancelled, threshold == previousThreshold,
                  Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)) == value else { return }
            threshold = value
        }
    }

    private func commit() {
        if let value = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)), (1...100).contains(value) {
            threshold = value
        }
        draft = String(threshold)
    }
}
