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

/// Membership lives below personal progress in the place chip.
struct TeamSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Account.self) private var account
    @Binding var sheet: TeamSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Team").font(.subheadline.weight(.semibold))
            ForEach(model.teams) { team in
                Button { sheet = .settings(team.id) } label: {
                    HStack(spacing: 8) {
                        AvatarStack(heads: Head.team(team, you: Head.you(account, teams: model.teams)))
                        Text(team.name).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            // Also available when you're already in a team, for a second group.
            Button("Start a team") { sheet = .start }
            Button("Join with a code") { sheet = .join }
        }
        .font(.subheadline)
        .buttonStyle(.plain)
    }
}

private struct TeamPreferences: View {
    @Binding var colour: String
    @Binding var name: String

    var body: some View {
        Section("Your name") {
            TextField("Name", text: $name).textInputAutocapitalization(.words)
        }
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
    }
}

struct TeamInviteCard: View {
    let team: Team
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
    @Environment(Account.self) private var account
    @Environment(AppModel.self) private var model
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colour = TeamColour.teal.rawValue
    @State private var memberName = ""
    @State private var createdID: String?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    private var canCreate: Bool { !busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !memberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if let id = createdID, let team = model.teams.first(where: { $0.id == id }) {
                    TeamInviteCard(team: team).listRowBackground(Color.clear)
                    Text("Your team can see each other here. Your clouds and secrets stay yours.")
                } else {
                    Section("Team name") {
                        TextField("Mike & Dad", text: $name)
                            .textInputAutocapitalization(.words)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { nameFocused = false }
                    }
                    TeamPreferences(colour: $colour, name: $memberName)
                    Section {
                        Button(action: create) {
                            Text("Start team").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreate)
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("Your team can see each other here. Your clouds and secrets stay yours.")
                    }
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden).background(Color.cream)
            .onAppear { if memberName.isEmpty { memberName = account.displayName ?? "Explorer" } }
            .navigationTitle("Start a team").navigationBarTitleDisplayMode(.inline)
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
                    let created = try await api.create(name: teamName, colour: colour, memberName: memberName)
                    createdID = created.teamId
                    model.joinedTeam(created.teamId)
                    model.editTeam(created.teamId) { team in
                        team.name = teamName
                        team.inviteCode = created.inviteCode
                    }
                }
                if let id = createdID {
                    try await model.refreshTeam(id, api: api)
                }
                sync.schedule()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct JoinTeamView: View {
    @Environment(Account.self) private var account
    var initialCode = ""
    @Environment(AppModel.self) private var model
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TeamInviteDraft()
    @State private var checkTask: Task<Void, Never>?
    @State private var colour = TeamColour.blue.rawValue
    @State private var memberName = ""
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
                        Text("Your team can see each other here. Your clouds and secrets stay yours.").font(.subheadline)
                    }
                    TeamPreferences(colour: $colour, name: $memberName)
                    Button("Join \(preview.name)", action: join).disabled(busy || memberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .scrollContentBackground(.hidden).background(Color.cream)
            .navigationTitle("Join a team").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .onAppear { if memberName.isEmpty { memberName = account.displayName ?? "Explorer" }; if draft.code.isEmpty { draft.replace(with: initialCode) }; if TeamInviteCode.isValid(normalisedCode) { check() } }
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
                if result == nil { error = "That code doesn't match a team." }
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
                let id = try await api.join(code: normalisedCode, colour: colour, name: memberName)
                model.joinedTeam(id)
                try await model.refreshTeam(id, api: api)
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
    @State private var memberName = ""
    @State private var busy = false
    @State private var error: String?
    @State private var removal: TeamMember?
    @State private var leaving = false
    private var team: Team? { model.teams.first { $0.id == teamID } }

    var body: some View {
        NavigationStack {
            Form {
                if let team {
                    Section("Members (\(team.members.count)/8)") {
                        ForEach(team.members) { member in
                            HStack {
                                Avatar(Head(id: member.id, name: member.name, picture: member.picture.flatMap(URL.init(string:)), colour: .team(member.colour)), size: 36)
                                Text(member.name + (member.isYou ? " (you)" : ""))
                                Spacer()
                                if team.you?.userId == team.createdBy, !member.isYou {
                                    Button("Remove", role: .destructive) { removal = member }.font(.caption)
                                }
                            }
                        }
                    }
                    TeamPreferences(colour: $colour, name: $memberName)
                    Section {
                        Button("Save my choices") {
                            run { api in
                                try await api.update(.init(teamId: teamID, colour: colour, name: memberName))
                                model.editTeam(teamID) { team in
                                    if let index = team.members.firstIndex(where: \.isYou) {
                                        team.members[index].colour = colour
                                        team.members[index].name = memberName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                }
                            }
                        }
                        .disabled(memberName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    TeamInviteCard(team: team).listRowBackground(Color.clear)
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
                            Button("Rename team") { run { try await $0.rename(teamID, name: name) } }
                                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Button("Leave team", role: .destructive) { leaving = true }
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .scrollContentBackground(.hidden).background(Color.cream)
            .navigationTitle(team?.name ?? "Team").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .onAppear {
                if let team, let you = team.you { name = team.name; colour = you.colour; memberName = you.name }
            }
            .confirmationDialog("Leave this team?", isPresented: $leaving, titleVisibility: .visible) {
                Button("Leave team", role: .destructive) {
                    run { api in
                        try await api.leave(teamID)
                        model.retainTeams(Set(model.teams.map(\.id)).subtracting([teamID]))
                        dismiss()
                    }
                }
            } message: { Text("You can join again with an invite code.") }
            .confirmationDialog("Remove \(removal?.name ?? "member")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                if let member = removal { Button("Remove member", role: .destructive) { run { try await $0.remove(teamID, userId: member.userId) } } }
            } message: { Text("The invite link will change. They can only rejoin after you issue a new invite link.") }
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
                model.editTeam(teamID) { _ in }
                if model.teams.contains(where: { $0.id == teamID }) { try await model.refreshTeam(teamID, api: api) }
                sync.schedule()
            } catch { self.error = error.localizedDescription }
        }
    }
}
