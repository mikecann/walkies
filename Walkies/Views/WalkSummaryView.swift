import SwiftUI

struct WalkSummaryView: View {
    let walk: Walk
    let city: City?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shoeprints.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.walkiesOrange)

            VStack(spacing: 6) {
                Text(walk.newTiles == 0 ? "Walk done" : "+\(walk.newTiles) new \(walk.newTiles == 1 ? "tile" : "tiles")")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(walk.newTiles == 0
                     ? "Nothing new this time. Try a street you haven't been down yet."
                     : "Nice one. A few more clouds have cleared.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 40) {
                summaryStat(Format.distance(walk.distance), "Distance")
                summaryStat(Format.duration(walk.duration), "Time")
            }

            if let city {
                VStack(spacing: 8) {
                    Text("\(city.name) is \(city.progress.percentText) explored")
                        .font(.headline)
                    ProgressBar(value: city.progress)
                }
                .padding(.horizontal)
            }

            Button("Done") { dismiss() }
                .buttonStyle(StickerButtonStyle())
        }
        .padding(24)
        .presentationBackground(Color.cream)
        .presentationDetents([.medium])
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
