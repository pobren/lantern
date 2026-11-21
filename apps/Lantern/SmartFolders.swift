// Smart folders (Paul, 21 Nov 2026): any search pinned in the sidebar, such as from:bank or is:starred has:attachment.
// They're kept on this device and search all mail each time they're opened, so they're always up to date.

import SwiftUI

struct SmartFolder: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var search: String

    /// An icon that fits what it searches for.
    var icon: String {
        let q = SearchQuery(search)
        if q.starred { return "star" }
        if q.unread { return "envelope.badge" }
        if q.hasAttachment { return "paperclip" }
        if !q.from.isEmpty { return "person.crop.circle" }
        if !q.to.isEmpty { return "paperplane" }
        return "magnifyingglass"
    }
}

@MainActor
final class SmartFolders: ObservableObject {
    static let shared = SmartFolders()
    private static let key = "smartFolders"

    @Published private(set) var all: [SmartFolder] = {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SmartFolder].self, from: data)) ?? []
    }()

    private func save() {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func contains(_ search: String) -> Bool {
        let t = search.trimmingCharacters(in: .whitespaces)
        return all.contains { $0.search == t }
    }

    func add(_ search: String) {
        let t = search.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !contains(t) else { return }
        all.append(SmartFolder(name: Self.name(for: t), search: t))
        save()
    }

    func remove(_ f: SmartFolder) { all.removeAll { $0.id == f.id }; save() }

    func rename(_ f: SmartFolder, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = all.firstIndex(where: { $0.id == f.id }) else { return }
        all[i].name = n
        save()
    }

    func move(from: IndexSet, to: Int) { all.move(fromOffsets: from, toOffset: to); save() }

    /// "From bank", "Starred with attachments" and so on, rather than the raw search words.
    static func name(for search: String) -> String {
        let q = SearchQuery(search)
        var parts: [String] = []
        if q.unread { parts.append("Unread") }
        if q.starred { parts.append("Starred") }
        if !q.from.isEmpty { parts.append("From " + q.from.joined(separator: ", ")) }
        if !q.to.isEmpty { parts.append("To " + q.to.joined(separator: ", ")) }
        if !q.subject.isEmpty { parts.append("Subject " + q.subject.joined(separator: " ")) }
        if !q.words.isEmpty { parts.append(q.freeText) }
        if q.hasAttachment { parts.append(parts.isEmpty ? "With attachments" : "with attachments") }
        let name = parts.joined(separator: " ")
        return name.isEmpty ? search : name.prefix(1).uppercased() + name.dropFirst()
    }
}

extension Store {
    /// Opens a smart folder: its search, across all mail.
    func openSmart(_ f: SmartFolder) async {
        smartFolder = f
        selection = nil
        list = []
        listLimit = 100
        searchScope = .allMail
        search = f.search
        await reloadList()
    }
}

/// The smart folders section of the sidebar.
struct SmartFolderRows: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var smart = SmartFolders.shared
    let opened: () -> Void
    @State private var renaming: SmartFolder?
    @State private var newName = ""

    var body: some View {
        if !smart.all.isEmpty {
            Section("Smart folders") {
                ForEach(smart.all) { f in
                    let on = store.smartFolder?.id == f.id && store.search == f.search
                    Button {
                        opened()
                        Task { await store.openSmart(f) }
                    } label: {
                        Label(f.name, systemImage: f.icon)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(on ? RoundedRectangle(cornerRadius: 6).fill(Look.accent.opacity(0.22)).padding(.horizontal, 10) : nil)
                    .contextMenu {
                        Button { newName = f.name; renaming = f } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { smart.remove(f) } label: { Label("Remove smart folder", systemImage: "trash") }
                    }
                    .swipeActions {
                        Button(role: .destructive) { smart.remove(f) } label: { Label("Remove", systemImage: "trash") }
                    }
                }
                .onMove { smart.move(from: $0, to: $1) }
            }
            .alert("Rename smart folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") { if let f = renaming { smart.rename(f, to: newName) }; renaming = nil }
            }
        }
    }
}

/// The pin button by the search box: keeps this search as a smart folder in the sidebar.
struct PinSearchButton: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var smart = SmartFolders.shared

    var body: some View {
        let t = store.search.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            let pinned = smart.contains(t)
            Button {
                if pinned { if let f = smart.all.first(where: { $0.search == t }) { smart.remove(f) } } else { smart.add(t) }
            } label: {
                Label(pinned ? "Remove smart folder" : "Save as smart folder", systemImage: pinned ? "pin.fill" : "pin")
            }
            .help(pinned ? "Remove this search from the sidebar" : "Keep this search in the sidebar as a smart folder")
        }
    }
}
