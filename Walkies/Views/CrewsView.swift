import SwiftUI

extension Color {
    static func crew(_ value: String) -> Color {
        switch value {
        case "teal": .badgeTeal
        case "orange": .walkiesOrange
        case "purple": Color(red: 0.58, green: 0.43, blue: 0.76)
        case "rose": Color(red: 0.84, green: 0.43, blue: 0.53)
        case "blue": Color(red: 0.32, green: 0.57, blue: 0.81)
        case "green": .badgeGreen
        default: Color(red: 0.52, green: 0.54, blue: 0.57)
        }
    }
}

enum CrewSheet: Identifiable {
    case start, join, settings(String)
    var id: String {
        switch self { case .start: "start"; case .join: "join"; case .settings(let id): id }
    }

    @ViewBuilder var destination: some View {
        switch self {
        case .start: StartCrewView()
        case .join: JoinCrewView()
        case .settings(let id): CrewSettingsView(crewID: id)
        }
    }
}

/// Reused in the expanded place chip and in the full places panel.
struct MapChoices: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: CrewSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Maps").font(.headline)
            mapButton("My map", id: nil, members: [])
            ForEach(model.crews) { crew in
                HStack {
                    mapButton(crew.name, id: crew.id, members: crew.members)
                    Button { sheet = .settings(crew.id) } label: {
                        Image(systemName: "gearshape")
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Settings for \(crew.name)")
                }
            }
            Button { sheet = .start } label: {
                Text("Start a team map")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            Button { sheet = .join } label: {
                Text("Join with a code")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
        }
        .font(.subheadline)
        .buttonStyle(.plain)
    }

    private func mapButton(_ name: String, id: String?, members: [CrewMember]) -> some View {
        Button {
            model.currentCrewID = id
        } label: {
            HStack(spacing: 6) {
                Text(name).lineLimit(1)
                ForEach(members.prefix(8)) { member in
                    Circle().fill(Color.crew(member.colour)).frame(width: 8, height: 8)
                        .accessibilityLabel(member.name)
                }
                Spacer(minLength: 2)
                if model.currentCrewID == id { Image(systemName: "checkmark").fontWeight(.bold) }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.currentCrewID == id ? .isSelected : [])
    }
}

struct MapsAndPlacesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addingPlace = false
    @State private var crewSheet: CrewSheet?

    var body: some View {
        NavigationStack {
            // Keep these independent controls out of List's row tap handling.
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    MapChoices(sheet: $crewSheet)
                        .padding(18)
                        .stickerCard(in: .rect(cornerRadius: 24))

                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.mapName).font(.headline)
                        ForEach(model.mapCities) { city in
                            Button {
                                model.select(city.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(city.name)
                                    Spacer()
                                    Text(city.progress.percentText).monospacedDigit()
                                    if model.selectedCityID == city.id { Image(systemName: "checkmark") }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(model.selectedCityID == city.id ? .isSelected : [])
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .stickerCard(in: .rect(cornerRadius: 24))

                    Button { addingPlace = true } label: {
                        Label("Add a place", systemImage: "plus")
                    }
                    .buttonStyle(StickerButtonStyle())
                }
                .padding()
            }
            .background(Color.sand.opacity(0.45))
            .foregroundStyle(Color.ink)
            .navigationTitle("Maps and places")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $addingPlace) {
                AddCityView { dismiss() }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        // Presentation belongs to the stable sheet host, not a row or button group.
        .sheet(item: $crewSheet) { $0.destination }
        .tint(.burnt)
        .environment(\.colorScheme, .light)
    }
}

private struct CrewPreferences: View {
    @Binding var colour: String
    @Binding var sharing: CrewSharing

    var body: some View {
        Section("Your colour") {
            HStack(spacing: 16) {
                ForEach(CrewColour.allCases, id: \.rawValue) { option in
                    Button { colour = option.rawValue } label: {
                        Circle().fill(Color.crew(option.rawValue))
                            .frame(width: 32, height: 32)
                            .overlay {
                                if colour == option.rawValue { Image(systemName: "checkmark").foregroundStyle(.white).fontWeight(.bold) }
                            }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(option.rawValue.capitalized)
                    .accessibilityAddTraits(colour == option.rawValue ? .isSelected : [])
                }
            }
        }
        Section("What to share") {
            Picker("Sharing", selection: $sharing) {
                ForEach(CrewSharing.allCases, id: \.rawValue) { choice in Text(choice.title).tag(choice) }
            }
            .pickerStyle(.segmented)
            ForEach(CrewSharing.allCases, id: \.rawValue) { choice in
                Text("\(choice.title): \(choice.detail)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CrewInviteCard: View {
    let crew: CrewMap
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invite someone to \(crew.name)").font(.headline)
            Text(crew.inviteCode).font(.system(.title, design: .monospaced, weight: .bold)).textSelection(.enabled)
            Text("They can enter this code in Walkies, or open the link on their phone.")
                .font(.subheadline).foregroundStyle(.secondary)
            ShareLink(item: crew.inviteURL) { Label("Share invite link", systemImage: "square.and.arrow.up") }
            if crew.members.count >= 8 { Text("This team is full (8 members).").font(.subheadline) }
            Text(crew.inviteURL.absoluteString).font(.caption).textSelection(.enabled)
        }
        .padding(16)
        .stickerCard(in: .rect(cornerRadius: 20))
    }
}

struct StartCrewView: View {
    @Environment(AppModel.self) private var model
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colour = CrewColour.teal.rawValue
    @State private var sharing = CrewSharing.tiles
    @State private var createdID: String?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    private var canCreate: Bool { !busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if let id = createdID, let crew = model.crews.first(where: { $0.id == id }) {
                    CrewInviteCard(crew: crew).listRowBackground(Color.clear)
                    Text("Add a place from Maps and places, then your past walks there will count too.")
                } else {
                    Section("Team name") {
                        TextField("Mike & Dad", text: $name)
                            .textInputAutocapitalization(.words)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { nameFocused = false }
                    }
                    CrewPreferences(colour: $colour, sharing: $sharing)
                    Section {
                        Button(action: create) {
                            Text("Start team map").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreate)
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("Your walks count on My map and this team map. Shells and levels stay yours.")
                    }
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden).background(Color.cream)
            .navigationTitle("Start a team map").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { nameFocused = false }
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func create() {
        let crewName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !crewName.isEmpty else { return }
        nameFocused = false
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let api = try await model.crewAPI()
                // Keep the id immediately. A failed first pull must not create a second crew on retry.
                if createdID == nil {
                    createdID = try await api.create(name: crewName, colour: colour, sharing: sharing).crewId
                    if let createdID { model.joinedCrew(createdID) }
                }
                if let id = createdID {
                    try await model.refreshCrew(id, api: api)
                    model.currentCrewID = id
                }
                sync.schedule()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct JoinCrewView: View {
    var initialCode = ""
    @Environment(AppModel.self) private var model
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CrewInviteDraft()
    @State private var checkTask: Task<Void, Never>?
    @State private var colour = CrewColour.blue.rawValue
    @State private var sharing = CrewSharing.tiles
    @State private var busy = false
    @State private var error: String?
    private var normalisedCode: String { draft.normalisedCode }

    var body: some View {
        NavigationStack {
            Form {
                Section("Invite code") {
                    TextField("ABCD2345", text: $draft.code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Check code", action: check).disabled(!CrewInviteCode.isValid(normalisedCode) || busy)
                }
                if let preview = draft.preview, draft.checkedCode == normalisedCode {
                    Section(preview.name) {
                        Text("Past walks in the team's places count too.").font(.subheadline)
                    }
                    CrewPreferences(colour: $colour, sharing: $sharing)
                    Button("Join \(preview.name)", action: join).disabled(busy)
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .scrollContentBackground(.hidden).background(Color.cream)
            .navigationTitle("Join a team map").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .onAppear { if draft.code.isEmpty { draft.replace(with: initialCode) }; if CrewInviteCode.isValid(normalisedCode) { check() } }
            .onChange(of: initialCode) {
                checkTask?.cancel()
                draft.replace(with: initialCode)
                if CrewInviteCode.isValid(normalisedCode) { check() }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func check() {
        busy = true
        error = nil
        let input = normalisedCode
        draft.preview = nil
        draft.checkedCode = ""
        checkTask?.cancel()
        checkTask = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                let api = try await model.crewAPI()
                let result = try await api.preview(input)
                guard !Task.isCancelled, draft.receive(result, for: input) else { return }
                if result == nil { error = "That code doesn't match a team map." }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func join() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let api = try await model.crewAPI()
                let id = try await api.join(code: normalisedCode, colour: colour, sharing: sharing)
                model.joinedCrew(id)
                try await model.refreshCrew(id, api: api)
                model.currentCrewID = id
                sync.schedule()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CrewSettingsView: View {
    let crewID: String
    @Environment(AppModel.self) private var model
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colour = CrewColour.teal.rawValue
    @State private var sharing = CrewSharing.tiles
    @State private var walksCount = true
    @State private var busy = false
    @State private var error: String?
    @State private var removal: CrewMember?
    @State private var leaving = false
    private var crew: CrewMap? { model.crews.first { $0.id == crewID } }

    var body: some View {
        NavigationStack {
            Form {
                if let crew {
                    Section("Members (\(crew.members.count)/8)") {
                        ForEach(crew.members) { member in
                            HStack {
                                Circle().fill(Color.crew(member.colour)).frame(width: 14, height: 14)
                                VStack(alignment: .leading) {
                                    Text(member.name + (member.isYou ? " (you)" : ""))
                                    Text(member.sharing.title).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if crew.you?.userId == crew.createdBy, !member.isYou {
                                    Button("Remove", role: .destructive) { removal = member }.font(.caption)
                                }
                            }
                        }
                    }
                    CrewPreferences(colour: $colour, sharing: $sharing)
                    Section {
                        Toggle("My walks count here", isOn: $walksCount)
                        Button("Save my choices") {
                            run { api in
                                let replay = crew.you?.sharing != .tilesAndTrail && sharing == .tilesAndTrail
                                try await api.update(.init(crewId: crewID, colour: colour, sharing: sharing, walksCount: walksCount))
                                model.setCrewPreferences(crewID, colour: colour, sharing: sharing, walksCount: walksCount)
                                if replay { await model.replayCrewHistory(crewID, forceTrails: true) }
                            }
                        }
                    } footer: {
                        Text("Switch off to pause contributions. Tiles you've already shared stay on the team map. Tiles only removes your shared trails.")
                    }
                    CrewInviteCard(crew: crew).listRowBackground(Color.clear)
                    if let message = crew.syncMessage { Text(message).foregroundStyle(.red) }
                    if crew.you?.userId == crew.createdBy {
                        Section {
                            Button("New invite link") {
                                run { api in
                                    let code = try await api.newInviteCode(crewID)
                                    model.editCrew(crewID) { $0.inviteCode = code }
                                }
                            }
                        } footer: {
                            Text("Replaces the current link and allows previously removed members to join with the new one.")
                        }
                        Section("Team name") {
                            TextField("Name", text: $name)
                            Button("Rename team map") { run { try await $0.rename(crewID, name: name) } }
                                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Button("Leave team map", role: .destructive) { leaving = true }
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .scrollContentBackground(.hidden).background(Color.cream)
            .navigationTitle(crew?.name ?? "Team map").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .onAppear {
                if let crew, let you = crew.you { name = crew.name; colour = you.colour; sharing = you.sharing; walksCount = you.walksCount }
            }
            .confirmationDialog("Leave this team map?", isPresented: $leaving, titleVisibility: .visible) {
                Button("Leave team map", role: .destructive) {
                    run { api in
                        try await api.leave(crewID)
                        model.retainCrews(Set(model.crews.map(\.id)).subtracting([crewID]))
                        dismiss()
                    }
                }
            } message: { Text("Your uncovered tiles and secrets stay. Your shared trails are removed.") }
            .confirmationDialog("Remove \(removal?.name ?? "member")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                if let member = removal { Button("Remove member", role: .destructive) { run { try await $0.remove(crewID, userId: member.userId) } } }
            } message: { Text("Their shared trails will be removed and the invite link will change. They can only rejoin after you issue a new invite link.") }
        }
        .interactiveDismissDisabled(busy)
    }

    private func run(_ action: @escaping @MainActor (CrewsAPI) async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let api = try await model.crewAPI()
                try await action(api)
                if model.crews.contains(where: { $0.id == crewID }) { try await model.refreshCrew(crewID, api: api) }
                sync.schedule()
            } catch { self.error = error.localizedDescription }
        }
    }
}
