//
// NoticesView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// The notices sheet behind the header's pin icon: pinned posts for the
/// mesh-local board.
struct NoticesView: View {
    let senderNickname: String
    @ObservedObject var board: BoardManager

    @ThemedPalette private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @State private var urgent = false
    @State private var expiryDays: Int = 7

    private var maxDraftLines: Int { dynamicTypeSize.isAccessibilitySize ? 5 : 3 }

    enum Strings {
        static let title = String(localized: "notices.title", defaultValue: "notices", comment: "Title prefix of the notices sheet")
        static let emptyTitle = String(localized: "board.empty_title", defaultValue: "no notices yet", comment: "Title shown when the board has no posts")
        static let emptySubtitle = String(localized: "board.empty_subtitle", defaultValue: "pin the first notice for people around here.", comment: "Subtitle shown when the board has no posts")
        static let urgentBadge = String(localized: "board.urgent_badge", defaultValue: "urgent", comment: "Badge shown on urgent board posts")
        static let urgentToggle = String(localized: "board.compose.urgent", defaultValue: "urgent", comment: "Label for the urgent toggle in the board composer")
        static let placeholder = String(localized: "board.compose.placeholder", defaultValue: "post a notice…", comment: "Placeholder for the board composer text field")
        static let send = String(localized: "board.accessibility.post", defaultValue: "Post notice", comment: "Accessibility label for the board post button")
        static let deleteAction = String(localized: "board.action.delete", defaultValue: "delete", comment: "Delete action for own board posts")
        static let expiryLabel = String(localized: "board.compose.expiry", defaultValue: "expires in", comment: "Label for the board post expiry picker")
        static let closeHint = String(localized: "notices.accessibility.close", defaultValue: "Close notices", comment: "Accessibility label for the notices close button")

        static func expiryDaysOption(_ days: Int) -> String {
            String(
                format: String(localized: "board.compose.expiry_days", defaultValue: "%lldd", comment: "Expiry picker option, number of days abbreviated"),
                locale: .current,
                days
            )
        }

        static func fades(_ expiresAt: Date) -> String {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return String(
                format: String(localized: "notices.fades", defaultValue: "fades %@", comment: "Shown on notices with an expiry; placeholder is a localized relative time like 'in 23h'"),
                locale: .current,
                formatter.localizedString(for: expiresAt, relativeTo: Date())
            )
        }

        static func rowAccessibilityLabel(author: String, content: String, urgent: Bool) -> String {
            let base = String(
                format: String(localized: "board.accessibility.post_row", defaultValue: "Notice from %@: %@", comment: "Accessibility label for a board post row"),
                locale: .current,
                author, content
            )
            return urgent ? "\(urgentBadge), \(base)" : base
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            NoticesList(
                items: board.posts(forGeohash: "").map(NoticeItem.init(post:)),
                board: board
            )
            composer
        }
        .themedSurface()
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 440, minHeight: 620, idealHeight: 680)
        #endif
        .themedSheetBackground()
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(Strings.title) @ #mesh")
                .bitchatFont(size: 18)
            Spacer()
            SheetCloseButton { dismiss() }
                .accessibilityLabel(Strings.closeHint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .themedSurface()
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                TextField(Strings.placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .bitchatFont(size: 14)
                    .lineLimit(maxDraftLines, reservesSpace: true)
                    .padding(.vertical, 6)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.bitchatSystem(size: 20))
                        .foregroundColor(sendEnabled ? palette.accent : .secondary)
                }
                .padding(.top, 2)
                .buttonStyle(.plain)
                .disabled(!sendEnabled)
                .accessibilityLabel(Strings.send)
            }
            HStack(spacing: 12) {
                Toggle(isOn: $urgent) {
                    Text(Strings.urgentToggle)
                        .bitchatFont(size: 12)
                        .foregroundColor(urgent ? palette.alertRed : palette.secondary)
                }
                .toggleStyle(.switch)
                .fixedSize()
                .accessibilityLabel(Strings.urgentToggle)
                Spacer()
                Text(Strings.expiryLabel)
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
                Picker(Strings.expiryLabel, selection: $expiryDays) {
                    ForEach([1, 3, 7], id: \.self) { days in
                        Text(Strings.expiryDaysOption(days)).tag(days)
                    }
                }
                .pickerStyle(.segmented)
                // macOS segmented pickers render their own label; the themed
                // Text alongside already carries it (and accessibility keeps
                // the explicit label below).
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(Strings.expiryLabel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .themedSurface()
        .overlay(Divider(), alignment: .top)
    }

    private var sendEnabled: Bool {
        let trimmed = draft.trimmed
        return !trimmed.isEmpty && trimmed.utf8.count <= BoardWireConstants.contentMaxBytes
    }

    private func send() {
        guard let content = draft.trimmedOrNilIfEmpty else { return }
        let sent = board.createPost(
            content: content,
            geohash: "",
            urgent: urgent,
            expiryDays: expiryDays,
            nickname: senderNickname
        )
        if sent {
            draft = ""
            urgent = false
        }
    }
}

/// One row in the notices sheet, normalized for display.
private struct NoticeItem: Identifiable, Equatable {
    let id: String
    let author: String
    let content: String
    let createdAt: Date
    let isUrgent: Bool
    let expiresAt: Date?
    let post: BoardPostPacket

    init(post: BoardPostPacket) {
        id = post.postID.hexEncodedString()
        author = post.authorNickname.trimmedOrNilIfEmpty ?? "anon"
        content = post.content
        createdAt = Date(timeIntervalSince1970: TimeInterval(post.createdAt) / 1000)
        isUrgent = post.isUrgent
        expiresAt = post.expiresAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(post.expiresAt) / 1000)
            : nil
        self.post = post
    }
}

/// Renders board posts with swipe-delete for own items.
private struct NoticesList: View {
    let items: [NoticeItem]
    let board: BoardManager

    @ThemedPalette private var palette

    private typealias Strings = NoticesView.Strings

    var body: some View {
        Group {
            if items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Strings.emptyTitle)
                            .bitchatFont(size: 13, weight: .semibold)
                        Text(Strings.emptySubtitle)
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            } else {
                let sorted = items.sorted {
                    if $0.isUrgent != $1.isUrgent { return $0.isUrgent }
                    return $0.createdAt > $1.createdAt
                }
                List {
                    ForEach(sorted) { item in
                        row(item)
                            .listRowBackground(palette.background)
                            .listRowSeparatorTint(palette.divider)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedSurface()
    }

    private func canDelete(_ item: NoticeItem) -> Bool {
        board.isOwnPost(item.post)
    }

    private func delete(_ item: NoticeItem) {
        board.deletePost(item.post)
    }

    private func row(_ item: NoticeItem) -> some View {
        let isOwn = canDelete(item)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if item.isUrgent {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.bitchatSystem(size: 11))
                        .foregroundColor(palette.alertRed)
                    Text(Strings.urgentBadge)
                        .bitchatFont(size: 11, weight: .semibold)
                        .foregroundColor(palette.alertRed)
                }
                Text(verbatim: "@\(item.author)")
                    .bitchatFont(size: 12, weight: .semibold)
                Text(Self.timestampText(for: item.createdAt))
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)
                if let expiresAt = item.expiresAt, expiresAt > Date() {
                    Text(Strings.fades(expiresAt))
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary.opacity(0.8))
                }
                Spacer()
                if isOwn {
                    Button {
                        delete(item)
                    } label: {
                        Image(systemName: "trash")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(palette.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Strings.deleteAction)
                }
            }
            Text(item.content)
                .bitchatFont(size: 14)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.rowAccessibilityLabel(author: item.author, content: item.content, urgent: item.isUrgent))
        .accessibilityActions {
            if isOwn {
                Button(Strings.deleteAction) { delete(item) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isOwn {
                Button(role: .destructive) {
                    delete(item)
                } label: {
                    Label(Strings.deleteAction, systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Timestamp Formatting

    private static func timestampText(for date: Date) -> String {
        let now = Date()
        if let days = Calendar.current.dateComponents([.day], from: date, to: now).day, days < 7 {
            // The whole "3 hr ago" phrase must come from the formatter —
            // gluing an English "ago" onto a localized duration ships the
            // wrong word order to most locales ("hace 3 h", "vor 3 Std").
            return relativeFormatter.localizedString(for: date, relativeTo: now)
        }
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return (sameYear ? absDateFormatter : absDateYearFormatter).string(from: date)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let absDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()

    private static let absDateYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d, y")
        return f
    }()
}
