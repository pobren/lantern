// Out of office: Fastmail's automatic reply (JMAP VacationResponse), turned on and off from Settings.

import SwiftUI

struct OutOfOfficeView: View {
    let state: AccountState
    @Environment(\.dismiss) private var dismiss
    @State private var v = Vacation()
    @State private var loaded = false
    @State private var saving = false
    @State private var problem: String?
    @State private var hasStart = false
    @State private var hasEnd = false

    var body: some View {
        NavigationStack {
            Form {
                if !loaded {
                    ProgressView()
                } else {
                    Toggle("Send an automatic reply", isOn: $v.on)
                    Section {
                        Toggle("Start on a date", isOn: $hasStart)
                        if hasStart {
                            DatePicker("From", selection: Binding(get: { v.from ?? Date() }, set: { v.from = $0 }))
                        }
                        Toggle("End on a date", isOn: $hasEnd)
                        if hasEnd {
                            DatePicker("Until", selection: Binding(get: { v.to ?? Date().addingTimeInterval(7 * 86400) }, set: { v.to = $0 }))
                        }
                    } footer: {
                        Text("Without dates, the reply goes out from now until you turn it off.")
                    }
                    Section("Reply") {
                        TextField("Subject (optional)", text: $v.subject)
                        TextEditor(text: $v.text)
                            .frame(minHeight: 140)
                            .overlay(alignment: .topLeading) {
                                if v.text.isEmpty {
                                    Text("I'm away until Monday and will reply when I'm back.")
                                        .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                                }
                            }
                    }
                }
                if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
            }
            .formStyle(.grouped)
            .navigationTitle("Out of office")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { Label(saving ? "Saving" : "Save", systemImage: "checkmark") }
                        .disabled(!loaded || saving || (v.on && v.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
            }
        }
        .task {
            do {
                v = try await state.client.vacationResponse()
                hasStart = v.from != nil
                hasEnd = v.to != nil
            } catch { problem = Self.explain(error) }
            loaded = true
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private func save() async {
        saving = true; problem = nil
        var out = v
        if !hasStart { out.from = nil } else if out.from == nil { out.from = Date() }
        if !hasEnd { out.to = nil } else if out.to == nil { out.to = Date().addingTimeInterval(7 * 86400) }
        do {
            try await state.client.setVacationResponse(out)
            dismiss()
        } catch { problem = Self.explain(error) }
        saving = false
    }

    static func explain(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("forbidden") || text.localizedCaseInsensitiveContains("capability") {
            return "Your Fastmail API token doesn't allow this. You can set an out of office reply in Fastmail on the web, under Settings, then Vacation response."
        }
        return text
    }
}
