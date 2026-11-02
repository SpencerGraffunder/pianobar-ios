//
// SettingsSheet.swift — settings opened from the gear next to Help.
//
// One section for now: the Playback Cache. Choose the size cap (or Off),
// choose whether every song or only loved songs get stored, and see how
// full the cache is: a horizontal usage bar where the orange segment is
// cached audio older than a month — the part eviction is allowed to
// reclaim for new songs. Also shows the number of songs cached.
//
// Copyright (c) 2025 Spencer Graffunder
// MIT licensed.
//

import SwiftUI
import Combine

struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Keeps the usage bar honest while background caching fills it in.
    private let ticker = Timer.publish(every: 3, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Cache size", selection: $model.cacheSizeMB) {
                        Text("Off").tag(0)
                        Text("250 MB").tag(250)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1000)
                        Text("2 GB").tag(2000)
                        Text("5 GB").tag(5000)
                        Text("10 GB").tag(10000)
                    }
                    Picker("Songs to cache", selection: $model.cachePolicy) {
                        Text("Every song").tag(CachePolicy.anySongs)
                        Text("Only loved songs").tag(CachePolicy.lovedOnly)
                    }
                    cacheUsage
                } header: {
                    Text("Playback Cache")
                } footer: {
                    Text("Cached songs start instantly and play even with no network. When the cache is full, the oldest songs make room for new ones once they are more than a month old. Tapping Ban or Tired on a cached song removes it from the cache right away.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Background caching runs while this is open; re-read usage.
            .onReceive(ticker) { _ in model.refreshCacheStats() }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Usage bar

    private var cacheUsage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(usageLine)
                .font(.subheadline)
            usageBar
                .frame(height: 10)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
                .clipShape(Capsule())
            HStack(spacing: 14) {
                legendDot(.accentColor, "Under a month")
                legendDot(.orange, "Over a month (replaceable)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// Horizontal bar: full width = the size cap. Filled with the used
    /// portion, split by age — accent for songs accessed within a month,
    /// orange for month-plus songs (the ones eviction may reclaim).
    private var usageBar: some View {
        GeometryReader { geo in
            let s = model.cacheStats
            let fresh = max(Int64(0), s.bytes - s.agedBytes)
            let usedFrac = s.capBytes > 0
                ? min(1.0, Double(s.bytes) / Double(s.capBytes)) : 0
            let scale = geo.size.width * usedFrac
            let denom = max(Int64(1), s.bytes)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: scale * Double(fresh) / Double(denom))
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: scale * Double(s.agedBytes) / Double(denom))
                Spacer(minLength: 0)
            }
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private var usageLine: String {
        let s = model.cacheStats
        if s.capBytes == 0 {
            return "Cache is off — pick a size to start saving songs."
        }
        let songs = s.count == 1 ? "song" : "songs"
        return "\(s.count) \(songs) cached · \(Self.fmt(s.bytes)) of \(Self.fmt(s.capBytes))"
    }

    private static func fmt(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 950
            ? String(format: "%.1f GB", mb / 1000)
            : String(format: "%.0f MB", mb)
    }
}

#Preview {
    SettingsSheet(model: AppModel())
}
