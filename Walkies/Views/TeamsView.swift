import SwiftUI

extension Color {
    static func team(_ value: String) -> Color {
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

enum TeamSheet: Identifiable {
    case start, join, settings(String)
    var id: String {
        switch self { case .start: "start"; case .join: "join"; case .settings(let id): id }
    }

    @ViewBuilder var destination: some View {
        switch self {
        case .start: StartTeamView()
        case .join: JoinTeamView()
        case .settings(let id): TeamSettingsView(teamID: id)
        }
    }
}

/// Reused in the expanded place chip and in the full places panel.
struct MapChoices: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: TeamSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Maps").font(.headline)
            mapButton("My map", id: nil, members: [])
            ForEach(model.teams) { team in
                HStack {
                    mapButton(team.name, id: team.id, members: team.members)
                    Button { sheet = .settings(team.id) } label: {
                        Image(systemName: "gearshape")
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Settings for \(team.name)")
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

    private func mapButton(_ name: String, id: String?, members: [TeamMember]) -> some View {
        Button {
            model.currentTeamID = id
        } label: {
            HStack(spacing: 6) {
                Text(name).lineLimit(1)
                ForEach(members.prefix(8)) { member in
                    Circle().fill(Color.team(member.colour)).frame(width: 8, height: 8)
                        .accessibilityLabel(member.name)
                }
                Spacer(minLength: 2)
                if model.currentTeamID == id { Image(systemName: "checkmark").fontWeight(.bold) }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.currentTeamID == id ? .isSelected : [])
    }
}

struct MapsAndPlacesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addingPlace = false
    @State private var teamSheet: TeamSheet?

    var body: some View {
        NavigationStack {
            // Keep these independent controls out of List's row tap handling.
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    MapChoices(sheet: $teamSheet)
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
        .sheet(item: $teamSheet) { $0.destination }
        .tint(.burnt)
        .environment(\.colorScheme, .light)
    }
}

private struct TeamPreferences: View {
    @Binding var colour: String
    @Binding var sharing: TeamSharing

    var body: some View {
        Section("Your colour") {
            HStack(spacing: 16) {
                ForEach(TeamColour.allCases, id: \.rawValue) { option in
                    Button { colour = option.rawValue } label: {
                        Circle().fill(Color.team(option.rawValue))
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
                ForEach(TeamSharing.allCases, id: \.rawValue) { choice in Text(choice.title).tag(choice) }
            }
            .pickerStyle(.segmented)
            ForEach(TeamSharing.allCases, id: \.rawValue) { choice in
                Text("\(choice.title): \(choice.detail)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TeamInviteCard: View {
    let team: TeamMap
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invite someone to \(team.name)").font(.headline)
            Text(team.inviteCode).font(.system(.title, design: .monospaced, weight: .bold)).textSelection(.enabled)
            Text("They can enter this code in Walkies, or open the link on their phone.")
                .font(.subheadline).foregroundStyle(.secondary)
            ShareLink(item: team.inviteURL) { Label("Share invite link", systemImage: "square.and.arrow.up") }
            if team.members.count >= 8 { Text("This team is full (8 members).").font(.subheadline) }
            Text(team.inviteURL.absoluteString).font(.caption).textSelection(.enabled)
        }
        .padding(16)
        .stickerCard(in: .rect(cornerRadius: 20))
    }
}

struct StartTeamView: View {
    @Environment(AppModel.self) private var model
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colour = TeamColour.teal.rawValue
    @State private var sharing = TeamSharing.tiles
    @State private var createdID: String?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    private var canCreate: Bool { !busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if let id = createdID, let team = model.teams.first(where: { $0.id == id }) {
                    TeamInviteCard(team: team).listRowBackground(Color.clear)
                    Text("Add a place from Maps and places, then your past walks there will count too.")
                } else {
                    Section("Team name") {
                        TextField("Mike & Dad", text: $name)
                            .textInputAutocapitalization(.words)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { nameFocused = false }
                    }
                    TeamPreferences(colour: $colour, sharing: $sharing)
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
        let teamName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !teamName.isEmpty else { return }
        nameFocused = false
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let api = try await model.teamAPI()
                // Keep the id immediately. A failed first pull must not create a second team on retry.
                if createdID == nil {
                    createdID = try await api.create(name: teamName, colour: colour, sharing: sharing).teamId
                    if let createdID { model.joinedTeam(createdID) }
                }
                if let id = createdID {
                    try await model.refreshTeam(id, api: api)
                    model.currentTeamID = id
                }
                sync.schedule()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct JoinTeamView: View {
    var initialCode = ""
    @Environment(AppModel.self) private var model
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TeamInviteDraft()
    @State private var checkTask: Task<Void, Never>?
    @State private var colour = TeamColour.blue.rawValue
    @State private var sharing = TeamSharing.tiles
    @State private var busy = false
    @State private var error: String?
    private var normalisedCode: String { draft.normalisedCode }

    var body: some View {
        NavigationStack {
            Form {
                Section("Invite code") {
                    TextField("ABCD2345", text: $draft.code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Check code", action: check).disabled(!TeamInviteCode.isValid(normalisedCode) || busy)
                }
                if let preview = draft.preview, draft.checkedCode == normalisedCode {
                    Section(preview.name) {
                        Text("Past walks in the team's places count too.").font(.subheadline)
                    }
                    TeamPreferences(colour: $colour, sharing: $sharing)
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
            .onAppear { if draft.code.isEmpty { draft.replace(with: initialCode) }; if TeamInviteCode.isValid(normalisedCode) { check() } }
            .onChange(of: initialCode) {
                checkTask?.cancel()
                draft.replace(with: initialCode)
                if TeamInviteCode.isValid(normalisedCode) { check() }
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
                let api = try await model.teamAPI()
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
                let api = try await model.teamAPI()
                let id = try await api.join(code: normalisedCode, colour: colour, sharing: sharing)
                model.joinedTeam(id)
                try await model.refreshTeam(id, api: api)
                model.currentTeamID = id
                sync.schedule()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct TeamSettingsView: View {
    let teamID: String
    @Environment(AppModel.self) private var model
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colour = TeamColour.teal.rawValue
    @State private var sharing = TeamSharing.tiles
    @State private var walksCount = true
    @State private var busy = false
    @State private var error: String?
    @State private var removal: TeamMember?
    @State private var leaving = false
    private var team: TeamMap? { model.teams.first { $0.id == teamID } }

    var body: some View {
        NavigationStack {
            Form {
                if let team {
                    Section("Members (\(team.members.count)/8)") {
                        ForEach(team.members) { member in
                            HStack {
                                Circle().fill(Color.team(member.colour)).frame(width: 14, height: 14)
                                VStack(alignment: .leading) {
                                    Text(member.name + (member.isYou ? " (you)" : ""))
                                    Text(member.sharing.title).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if team.you?.userId == team.createdBy, !member.isYou {
                                    Button("Remove", role: .destructive) { removal = member }.font(.caption)
                                }
                            }
                        }
                    }
                    TeamPreferences(colour: $colour, sharing: $sharing)
                    Section {
                        Toggle("My walks count here", isOn: $walksCount)
                        Button("Save my choices") {
                            run { api in
                                let replay = team.you?.sharing != .tilesAndTrail && sharing == .tilesAndTrail
                                try await api.update(.init(teamId: teamID, colour: colour, sharing: sharing, walksCount: walksCount))
                                model.setTeamPreferences(teamID, colour: colour, sharing: sharing, walksCount: walksCount)
                                if replay { await model.replayTeamHistory(teamID, forceTrails: true) }
                            }
                        }
                    } footer: {
                        Text("Switch off to pause contributions. Tiles you've already shared stay on the team map. Tiles only removes your shared trails.")
                    }
                    TeamInviteCard(team: team).listRowBackground(Color.clear)
                    if let message = team.syncMessage { Text(message).foregroundStyle(.red) }
                    if team.you?.userId == team.createdBy {
                        Section {
                            Button("New invite link") {
                                run { api in
                                    let code = try await api.newInviteCode(teamID)
                                    model.editTeam(teamID) { $0.inviteCode = code }
                                }
                            }
                        } footer: {
                            Text("Replaces the current link and allows previously removed members to join with the new one.")
                        }
                        Section("Team name") {
                            TextField("Name", text: $name)
                            Button("Rename team map") { run { try await $0.rename(teamID, name: name) } }
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
            .navigationTitle(team?.name ?? "Team map").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .onAppear {
                if let team, let you = team.you { name = team.name; colour = you.colour; sharing = you.sharing; walksCount = you.walksCount }
            }
            .confirmationDialog("Leave this team map?", isPresented: $leaving, titleVisibility: .visible) {
                Button("Leave team map", role: .destructive) {
                    run { api in
                        try await api.leave(teamID)
                        model.retainTeams(Set(model.teams.map(\.id)).subtracting([teamID]))
                        dismiss()
                    }
                }
            } message: { Text("Your uncovered tiles and secrets stay. Your shared trails are removed.") }
            .confirmationDialog("Remove \(removal?.name ?? "member")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                if let member = removal { Button("Remove member", role: .destructive) { run { try await $0.remove(teamID, userId: member.userId) } } }
            } message: { Text("Their shared trails will be removed and the invite link will change. They can only rejoin after you issue a new invite link.") }
        }
        .interactiveDismissDisabled(busy)
    }

    private func run(_ action: @escaping @MainActor (TeamsAPI) async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let api = try await model.teamAPI()
                try await action(api)
                if model.teams.contains(where: { $0.id == teamID }) { try await model.refreshTeam(teamID, api: api) }
                sync.schedule()
            } catch { self.error = error.localizedDescription }
        }
    }
}
