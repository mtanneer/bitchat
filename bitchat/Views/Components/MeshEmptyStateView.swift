//
// MeshEmptyStateView.swift
// bitchat
//
// The empty mesh timeline, upgraded from a dead end into a live surface:
// a sonar shows the radio scanning and the daily sightings tally proves the
// spot isn't dead.
// This is free and unencumbered software released into the public domain.
//

import SwiftUI

struct MeshEmptyStateView: View {
    /// Visible chat height to fill; the radar centers in the space left
    /// below the narration. Zero (previews) keeps a compact layout.
    var fillHeight: CGFloat = 0
    /// Ambient-footer mode, appended below archived echoes: skips the
    /// intro/help narration (the timeline isn't empty) and shrinks the
    /// radar, keeping the sightings tally visible.
    var compact: Bool = false

    @EnvironmentObject private var peerListModel: PeerListModel
    @ObservedObject private var sightingsTracker = MeshSightingsTracker.shared

    @ThemedPalette private var palette

    /// The activity window is evaluated at render time; without new events
    /// nothing would trigger a re-render, so a stale relative time could
    /// linger. A slow tick keeps the tally's day-rollover honest.
    @State private var refreshTick = 0
    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private enum Strings {
        static let meshIntro = String(localized: "content.empty.mesh_intro", comment: "First line of the empty mesh timeline explaining what the mesh channel is")
        static let switchHint = String(localized: "content.empty.switch_hint", comment: "Empty timeline hint pointing at the channel switcher and the help screen")
        static let sightingsOne = String(localized: "content.empty.sightings_one", comment: "Empty mesh timeline stat when exactly one device came within range today")

        static func sightingsMany(_ count: Int) -> String {
            String(
                format: String(localized: "content.empty.sightings_many", comment: "Empty mesh timeline stat counting devices that came within range today"),
                locale: .current,
                count
            )
        }
    }

    /// The radar means "searching for people": once anyone is connected or
    /// reachable on the mesh, the search is over and the sweep goes away.
    private var isSearchingForPeers: Bool {
        peerListModel.connectedMeshPeerCount == 0 && peerListModel.reachableMeshPeerCount == 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if compact {
                if isSearchingForPeers {
                    radarBlock
                }
            } else {
                // The radar + tally already say "scanning, nobody yet", so
                // the narration stays to two lines.
                narrationLine(Strings.meshIntro)
                narrationLine(Strings.switchHint)

                // The radar centers in whatever space is left below the
                // text — the flexible spacers split it evenly.
                if isSearchingForPeers {
                    Spacer(minLength: 24)
                    radarBlock
                    Spacer(minLength: 12)
                }
            }
        }
        .frame(minHeight: compact ? 0 : fillHeight, alignment: .top)
        .onReceive(refreshTimer) { _ in
            refreshTick += 1
            // Roll the tally over if the local day changed while idle.
            sightingsTracker.refreshForDisplay()
        }
    }

    /// The radar with today's tally as its caption — the stat belongs to
    /// the scanning visual, not the narration lines.
    private var radarBlock: some View {
        VStack(spacing: 4) {
            MeshRadarView(height: compact ? 44 : 72)
            if sightingsTracker.todayCount > 0 {
                Text(verbatim: sightingsText)
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private extension MeshEmptyStateView {
    var sightingsText: String {
        sightingsTracker.todayCount == 1
            ? Strings.sightingsOne
            : Strings.sightingsMany(sightingsTracker.todayCount)
    }

    func narrationLine(_ text: String) -> some View {
        emptyStateLine(text, color: palette.secondary.opacity(0.9))
    }

    func emptyStateLine(_ text: String, color: Color) -> some View {
        // Non-breaking space before the closing asterisk so a tight wrap
        // can't orphan a lone "*" onto its own line.
        Text(verbatim: "* \(text)\u{00A0}*")
            .bitchatFont(size: 13)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
