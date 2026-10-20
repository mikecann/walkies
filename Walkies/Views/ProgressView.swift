import SwiftUI

struct ProgressionSheet: View {
    enum Section: String, CaseIterable {
        case level = "Level", quests = "Quests", shop = "Shop", wardrobe = "Wardrobe", spyglass = "Spyglass"
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var initialSection: Section = .level
    @State private var purchase: Progression.Item?
    @State private var notice: String?
    @State private var noticeID = UUID()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Section.allCases, id: \.self) { section in
                                Button(section.rawValue) {
                                    withAnimation { proxy.scrollTo(section, anchor: .top) }
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.cream, in: .capsule)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    // The model deliberately has no timer. Keep quests and ring expiry
                    // current while this sheet stays open over midnight or a week rollover.
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        ScrollView {
                            VStack(spacing: 22) {
                                levelSection.id(Section.level)
                                questsSection(now: timeline.date).id(Section.quests)
                                shopSection.id(Section.shop)
                                wardrobeSection.id(Section.wardrobe)
                                spyglassSection(now: timeline.date).id(Section.spyglass)
                            }
                            .padding()
                        }
                    }
                }
                .task { proxy.scrollTo(initialSection, anchor: .top) }
            }
            .background(Color.sand.opacity(0.45))
            .foregroundStyle(Color.ink)
            .navigationTitle("Your progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ShellBalance(balance: model.balance) }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(16)
                        .stickerCard(in: .rect(cornerRadius: 18))
                        .padding()
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .task(id: noticeID) {
                guard notice != nil else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                withAnimation { notice = nil }
            }
            .confirmationDialog(
                purchase.map { "Buy \($0.name) for \($0.price) shells?" } ?? "Buy item?",
                isPresented: Binding(get: { purchase != nil }, set: { if !$0 { purchase = nil } }),
                titleVisibility: .visible, presenting: purchase
            ) { item in
                Button("Buy for \(item.price) shells") {
                    if model.buy(item.id) {
                        celebrate(item.group == nil ? "Spyglass added" : "\(item.name) equipped")
                    } else { showNotice("Couldn't buy that just now. Check your shells and try again.") }
                }
                Button("Not now", role: .cancel) {}
            } message: { item in
                Text(item.group == nil ? "One hint for your next secret hunt." : "You'll own it and wear it straight away.")
            }
        }
        .tint(.burnt)
        .environment(\.colorScheme, .light)
    }

    private var levelSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ProgressArt("progress-level-star", size: 72)
                VStack(alignment: .leading, spacing: 5) {
                    title("Level \(model.level)")
                    Text("\(model.xp) XP earned by walking")
                        .font(.subheadline)
                    ProgressBar(value: LevelMeter(xp: model.xp).fraction)
                    Text("\(model.xpToNextLevel) XP to Level \(model.level + 1)")
                        .font(.caption)
                }
            }
            Text("Every shell you earn on a walk adds XP. Spending shells keeps your XP.")
                .font(.footnote)
                .foregroundStyle(Color.ink.opacity(0.7))
            VStack(spacing: 8) {
                earnedRow("Tiles", model.earnedBreakdown.tiles)
                earnedRow("Secrets", model.earnedBreakdown.secrets)
                earnedRow("Place milestones", model.earnedBreakdown.milestones)
                earnedRow("Walking streaks", model.earnedBreakdown.streaks)
                earnedRow("Quests", model.earnedBreakdown.quests)
            }
            ForEach(model.pendingPicks, id: \.self) { level in
                rewardCard(level: level)
            }
        }
        .padding(18)
        .stickerCard(in: .rect(cornerRadius: 24))
    }

    private func rewardCard(level: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Level \(level) reward: choose one")
                .font(.system(.headline, design: .rounded, weight: .heavy))
            // Slot identity matters: the fallback menu can contain two shell bags.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                ForEach(Array(model.picks(for: level).enumerated()), id: \.offset) { _, choice in
                    let duplicate = model.owned.contains(choice)
                    let reward = duplicate ? Progression.shellBag : choice
                    Button {
                        if model.claim(level: level, choice: choice) {
                            celebrate("\(rewardName(reward)) chosen")
                        } else { showNotice("That reward has already been chosen.") }
                    } label: {
                        VStack(spacing: 8) {
                            ProgressItemArt(id: reward).frame(height: 62)
                            Text(rewardName(reward))
                                .font(.caption.weight(.bold))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 34)
                            if duplicate {
                                Text("Already owned, so a shell bag instead")
                                    .font(.caption2)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color.cream, in: .rect(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.burnt.opacity(0.4)))
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Choose \(rewardName(reward)) for level \(level)")
                }
            }
        }
        .padding(12)
        .background(Color.sand.opacity(0.6), in: .rect(cornerRadius: 20))
    }

    private func questsSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("This week's quests", art: "progress-quest-scroll")
            ForEach(model.weeklyQuests) { quest in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(quest.name).font(.headline)
                        Spacer()
                        ShellBalance(balance: quest.reward, prefix: "+")
                        if quest.isComplete {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.badgeTeal)
                                .accessibilityLabel("Complete")
                        }
                    }
                    ProgressBar(value: min(1, quest.progress / quest.target))
                    Text(QuestProgressText.value(quest.progress, kind: quest.kind))
                        .font(.caption)
                }
            }
            let reset = Progression.week(containing: now, calendar: .current).end
            Text("New quests \(reset.formatted(.dateTime.weekday(.wide).hour().minute()))")
                .font(.footnote)
                .foregroundStyle(Color.ink.opacity(0.65))
        }
        .padding(18)
        .stickerCard(in: .rect(cornerRadius: 24))
    }

    private var shopSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Shell shop", art: "progress-shop")
            Text("A different look for your next walk. Shells buy looks and hints; walking uncovers the map.")
                .font(.footnote).foregroundStyle(Color.ink.opacity(0.7))
            ForEach(Progression.Group.allCases, id: \.self) { group in
                Text(group.displayName).font(.headline).padding(.top, 4)
                ForEach(Progression.catalog.filter { $0.group == group }) { item in
                    shopRow(item)
                }
            }
            if let item = Progression.item("spyglass") {
                Text("Spyglasses · \(model.spyglasses) left").font(.headline)
                shopRow(item)
            }
        }
        .padding(18)
        .stickerCard(in: .rect(cornerRadius: 24))
    }

    private func shopRow(_ item: Progression.Item) -> some View {
        HStack(spacing: 12) {
            ProgressItemArt(id: item.id).frame(width: 54, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.subheadline.weight(.semibold))
                if item.isFree { Text("Free").font(.caption) }
                else { ShellBalance(balance: item.price) }
                if !model.owned.contains(item.id), model.balance < item.price {
                    Text("\(item.price - model.balance) more shells needed")
                        .font(.caption2).foregroundStyle(Color.ink.opacity(0.65))
                }
            }
            Spacer(minLength: 0)
            if let group = item.group, model.equipped[group] == item.id {
                Label("Equipped", systemImage: "checkmark")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.badgeTeal)
            } else if model.owned.contains(item.id) {
                Text("Owned").font(.caption.weight(.semibold))
            } else {
                Button("Buy") { purchase = item }
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.sand, in: .capsule)
                    .disabled(model.balance < item.price)
                    .opacity(model.balance < item.price ? 0.5 : 1)
            }
        }
        .padding(.vertical, 3)
    }

    private var wardrobeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Your wardrobe")
            Text("Tap something you own to wear it.").font(.footnote)
            ForEach(Progression.Group.allCases, id: \.self) { group in
                Text(group.displayName).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                    ForEach(Progression.catalog.filter { $0.group == group && model.owned.contains($0.id) }) { item in
                        let equipped = model.equipped[group] == item.id
                        Button {
                            if model.equip(item.id) {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showNotice("\(item.name) equipped")
                            } else { showNotice("Couldn't equip that just now.") }
                        } label: {
                            VStack(spacing: 6) {
                                ProgressItemArt(id: item.id).frame(height: 58)
                                Text(item.name).font(.caption.weight(.semibold))
                                Text(equipped ? "Equipped" : "Wear this")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(equipped ? Color.badgeTeal : .burnt)
                            }
                            .frame(maxWidth: .infinity, minHeight: 112)
                            .padding(8)
                            .background(equipped ? Color.badgeGreen.opacity(0.25) : Color.sand.opacity(0.35), in: .rect(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(equipped ? Color.badgeTeal : .clear, lineWidth: 2))
                        }
                        .buttonStyle(PressScale())
                        .accessibilityAddTraits(equipped ? [.isSelected] : [])
                    }
                }
            }
        }
        .padding(18)
        .stickerCard(in: .rect(cornerRadius: 24))
    }

    private func spyglassSection(now: Date) -> some View {
        let ring = model.activeSpyglassRing
        let hasSecret = model.selectedCity?.stickers?.keys.contains { model.foundStickers[$0] == nil } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Spyglass", art: "progress-spyglass")
            Text("\(model.spyglasses) left").font(.headline)
            Text("Shows a gold ring somewhere round an unfound secret in your selected place. It lasts for 3 hours, or until you find the secret. You'll still need to walk there.")
                .font(.subheadline)
            if let ring {
                Label("Hint active · \(Format.duration(max(0, ring.expiresAt.timeIntervalSince(now)))) left", systemImage: "clock")
                    .font(.subheadline.weight(.semibold))
            } else {
                Button("Use a spyglass") {
                    if model.useSpyglass() { celebrate("Your hint is on the map") }
                    else { showNotice("Couldn't use that just now. Check your selected place.") }
                }
                .buttonStyle(StickerButtonStyle())
                .disabled(model.spyglasses <= 0 || !hasSecret)
                .opacity(model.spyglasses <= 0 || !hasSecret ? 0.5 : 1)
                if model.selectedCity == nil {
                    Text("Add or select a place on the map first.").font(.footnote)
                } else if !hasSecret {
                    Text("No unfound secrets in \(model.selectedCity?.name ?? "this place").").font(.footnote)
                } else if model.spyglasses <= 0 {
                    Text("Pick one up in the shell shop above.").font(.footnote)
                } else {
                    Text("Looking in \(model.selectedCity?.name ?? "your selected place")").font(.footnote)
                }
            }
        }
        .padding(18)
        .stickerCard(in: .rect(cornerRadius: 24))
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(.title2, design: .rounded, weight: .heavy))
    }

    private func sectionTitle(_ text: String, art: String) -> some View {
        HStack(spacing: 12) {
            ProgressArt(art, size: 52)
            title(text)
        }
    }

    private func earnedRow(_ text: String, _ value: Int) -> some View {
        HStack { Text(text); Spacer(); Text("\(value)").monospacedDigit() }
            .font(.subheadline)
    }

    private func rewardName(_ id: String) -> String {
        switch id {
        case Progression.shellBag: "50 shells"
        case Progression.spyglassPair: "2 spyglasses"
        default: Progression.item(id)?.name ?? "Reward"
        }
    }

    private func celebrate(_ text: String) {
        SoundFX.shared.play(.chime)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showNotice(text)
    }

    private func showNotice(_ text: String) {
        withAnimation(.spring(response: 0.3)) {
            notice = text
            noticeID = UUID()
        }
    }
}

struct ShellBalance: View {
    let balance: Int
    var prefix = ""
    var body: some View {
        HStack(spacing: 3) {
            ProgressArt("progress-shell", size: 23)
            Text("\(prefix)\(balance)").font(.subheadline.weight(.bold)).monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(prefix)\(balance) shells")
    }
}

struct ShellsChip: View {
    @Environment(AppModel.self) private var model
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Button(action: action) {
                HStack(spacing: 8) {
                    ShellBalance(balance: model.balance)
                    Text("Lv \(model.level)").font(.caption.weight(.heavy))
                    if !model.pendingPicks.isEmpty {
                        Circle().fill(Color.walkiesOrange).frame(width: 7, height: 7)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .stickerCard(in: .capsule)
            }
            .buttonStyle(PressScale())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model.balance) shells, level \(model.level)\(model.pendingPicks.isEmpty ? "" : ", reward waiting")")
            .accessibilityHint("Opens your progress")
        }
    }
}

struct ProgressArt: View {
    let name: String
    var size: CGFloat = 54
    init(_ name: String, size: CGFloat = 54) { self.name = name; self.size = size }
    var body: some View {
        Image(name).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

extension Progression.Group {
    var displayName: String {
        switch self {
        case .marker: "Map marker"
        case .trail: "Trail"
        case .clouds: "Clouds"
        case .cover: "Secrets book cover"
        case .celebration: "Celebration"
        }
    }
}

/// Tiny previews use the actual item art, or a drawn sample for styles without artwork.
struct ProgressItemArt: View {
    let id: String

    private var artwork: String? {
        switch id {
        case Progression.shellBag: "progress-shell-bag"
        case Progression.spyglassPair, "spyglass": "progress-spyglass"
        case "marker.sneaker": "progress-marker-sneaker"
        case "marker.boat": "progress-marker-boat"
        case "marker.hat": "progress-marker-hat"
        case "marker.lighthouse": "progress-marker-lighthouse"
        case "cover.seashell": "progress-cover-seashell"
        case "cover.map": "progress-cover-map"
        case "cover.gold": "progress-cover-gold"
        default: nil
        }
    }

    var body: some View {
        if let artwork {
            Image(artwork).resizable().scaledToFit().accessibilityHidden(true)
        } else {
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                switch Progression.item(id)?.group {
                case .marker:
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - 11, y: centre.y - 11, width: 22, height: 22)), with: .color(.white))
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - 7, y: centre.y - 7, width: 14, height: 14)), with: .color(.walkiesOrange))
                case .trail: drawTrail(in: &context, size: size)
                case .clouds: drawCloud(in: &context, centre: centre)
                case .cover:
                    let rect = CGRect(x: centre.x - 18, y: centre.y - 24, width: 36, height: 48)
                    context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(.burnt))
                    context.stroke(Path(CGRect(x: rect.minX + 6, y: rect.minY + 3, width: 27, height: 42)), with: .color(.sand), lineWidth: 1)
                case .celebration: drawCelebration(in: &context, centre: centre)
                case nil: break
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func drawTrail(in context: inout GraphicsContext, size: CGSize) {
        let colours: [Color] = id == "trail.rainbow" ? [.burnt, .walkiesOrange, .badgeGreen, .badgeTeal, .purple] : [.badgeTeal]
        for i in 0..<7 {
            let point = CGPoint(x: size.width * (0.14 + Double(i) * 0.12), y: size.height * (0.5 + sin(Double(i)) * 0.2))
            if id == "trail.footprints" {
                context.draw(context.resolve(Image("progress-footprint")), in: CGRect(x: point.x - 6, y: point.y - 7, width: 12, height: 14))
            } else if id == "trail.sparkles" {
                context.draw(Text("✦").font(.system(size: 14)).foregroundStyle(Color.walkiesOrange), at: point)
            } else {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 3, width: 10, height: 6)), with: .color(colours[i % colours.count]))
            }
        }
    }

    private func drawCloud(in context: inout GraphicsContext, centre: CGPoint) {
        let colours: [Color] = switch id {
        case "clouds.sunset": [.orange, .pink, .yellow]
        case "clouds.storm": [.gray, .indigo, .gray]
        case "clouds.candy": [.pink, .cyan, .purple]
        default: [.white, .white, .white]
        }
        for i in 0..<3 {
            let rect = CGRect(x: centre.x - 26 + Double(i) * 12, y: centre.y - 8 - (i == 1 ? 9 : 0), width: 28, height: 25)
            context.fill(Path(ellipseIn: rect), with: .color(colours[i].opacity(0.8)))
        }
    }

    private func drawCelebration(in context: inout GraphicsContext, centre: CGPoint) {
        let colours: [Color] = [.walkiesOrange, .badgeTeal, .badgeGreen, .pink]
        for i in 0..<12 {
            let angle = Double(i) * .pi / 6
            let radius = Double(i % 3 + 1) * 7
            let point = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            if id == "celebration.bubbles" {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(colours[i % 4].opacity(0.25)))
                context.stroke(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(colours[i % 4].opacity(0.6)), lineWidth: 1)
            } else if id == "celebration.fireworks" {
                var ray = Path()
                ray.move(to: CGPoint(x: centre.x + cos(angle) * 10, y: centre.y + sin(angle) * 10))
                ray.addLine(to: CGPoint(x: centre.x + cos(angle) * 25, y: centre.y + sin(angle) * 25))
                context.stroke(ray, with: .color(colours[i % 4]), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else {
                context.fill(Path(CGRect(x: point.x - 3, y: point.y - 2, width: 6, height: 4)), with: .color(colours[i % 4]))
            }
        }
    }
}

enum QuestProgressText {
    static func value(_ progress: Double, kind: Progression.QuestKind) -> String {
        if kind == .metres5000 { return "\(Format.distance(min(progress, kind.target))) of 5 km" }
        if kind == .anotherPlace { return progress >= 1 ? "Another place explored" : "Try a place beyond your usual one" }
        return "\(Int(min(progress, kind.target))) of \(Int(kind.target))"
    }
}
