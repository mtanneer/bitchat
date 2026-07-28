import SwiftUI

struct ContentHeaderView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @EnvironmentObject private var boardAlertsModel: BoardAlertsModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    @Binding var showSidebar: Bool
    @Binding var showVerifySheet: Bool
    var isNicknameFieldFocused: FocusState<Bool>.Binding

    let headerHeight: CGFloat
    let headerPeerIconSize: CGFloat
    let headerPeerCountFontSize: CGFloat

    /// Courier envelopes this device is carrying for offline third parties.
    @State private var carriedMailCount = 0

    /// Board posts mirrored from the store so the pin icon can show when the
    /// current scope has notices.
    @State private var boardPosts: [BoardPostPacket] = []

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "PlaneChat/")
                .bitchatFont(size: 18, weight: .medium)
                .lineLimit(1)
                .foregroundColor(palette.primary)
                // When icons crowd the header, squeeze the nickname first
                // (priority 0) and the logo only as a last resort; the icon
                // cluster at priority 3 never gives up width.
                .layoutPriority(2)
                .onTapGesture(count: 3) {
                    appChromeModel.panicClearAllData()
                }
                .onTapGesture(count: 1) {
                    appChromeModel.presentAppInfo()
                }
                // This is the only entry point to App Info, but it reads as
                // static text; surface the tap. (The triple-tap panic wipe
                // stays undiscoverable on purpose — it's destructive.)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(
                    String(localized: "content.accessibility.app_info_hint", comment: "Accessibility hint on the bitchat/ logo explaining a tap opens app info")
                )
                .accessibilityAction {
                    appChromeModel.presentAppInfo()
                }

            HStack(spacing: 0) {
                Text(verbatim: "@")
                    .bitchatFont(size: 14)
                    .foregroundColor(palette.secondary)
                    // Keep the sigil whole while the field beside it shrinks.
                    .fixedSize()

                TextField(
                    "content.input.nickname_placeholder",
                    text: Binding(
                        get: { appChromeModel.nickname },
                        set: { appChromeModel.setNickname($0) }
                    )
                )
                .textFieldStyle(.plain)
                .bitchatFont(size: 14)
                .frame(maxWidth: 80)
                .foregroundColor(palette.primary)
                .focused(isNicknameFieldFocused)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .modifier(FocusEffectDisabledModifier())
                .onChange(of: isNicknameFieldFocused.wrappedValue) { isFocused in
                    if !isFocused {
                        appChromeModel.validateAndSaveNickname()
                    }
                }
                .onSubmit {
                    appChromeModel.validateAndSaveNickname()
                }
            }

            Spacer()

            let countAndColor = channelPeopleCountAndColor()
            let headerCountColor = countAndColor.1
            let headerOtherPeersCount = countAndColor.0

            HStack(spacing: 2) {
                if carriedMailCount > 0 {
                    Image(systemName: "figure.walk")
                        .font(.bitchatSystem(size: 12))
                        .foregroundColor(palette.secondary.opacity(0.8))
                        .headerTapTarget()
                        .accessibilityLabel(
                            String(
                                format: String(localized: "content.accessibility.carrying_mail", defaultValue: "Carrying %lld sealed messages for friends", comment: "Accessibility label for the courier mail indicator"),
                                locale: .current,
                                carriedMailCount
                            )
                        )
                        .help(
                            String(localized: "content.header.carrying_mail", defaultValue: "Carrying sealed messages for friends to deliver", comment: "Tooltip for the courier mail indicator")
                        )
                }

                if appChromeModel.hasUnreadPrivateMessages {
                    Button(action: { appChromeModel.openMostRelevantPrivateChat() }) {
                        Image(systemName: "envelope.fill")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(Color.orange)
                            .headerTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.open_unread_private_chat", comment: "Accessibility label for the unread private chat button")
                    )
                }

                Button(action: {
                    boardAlertsModel.markSeen(forScopes: [""])
                    appChromeModel.presentNotices()
                }) {
                    // Filled whenever the current scope has notices at all
                    // (matching the orange tint); hollow means nothing here.
                    Image(systemName: scopeHasNotices || unseenNoticesCount > 0 ? "pin.fill" : "pin")
                        .font(.bitchatSystem(size: 12))
                        .foregroundColor(
                            scopeHasNotices || unseenNoticesCount > 0
                                ? Color.orange.opacity(0.8)
                                : palette.secondary.opacity(0.9)
                        )
                        .headerTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(localized: "content.accessibility.notices", defaultValue: "Notices", comment: "Accessibility label for the notices button")
                )
                .accessibilityValue(
                    unseenNoticesCount > 0
                        ? String(
                            format: String(localized: "content.accessibility.notices_new", defaultValue: "%lld new", comment: "Accessibility value for the notices button when unseen pins arrived"),
                            locale: .current,
                            unseenNoticesCount
                        )
                        : ""
                )
                .help(
                    String(localized: "content.header.notices", defaultValue: "Notices: pinned posts for this area and the mesh", comment: "Tooltip for the notices button")
                )

                Text(verbatim: "#mesh")
                    .bitchatFont(size: 14)
                    .foregroundColor(Color(hue: 0.60, saturation: 0.85, brightness: 0.82))
                    .lineLimit(headerLineLimit)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity)

                Button(action: {
                    withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                        showSidebar.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: headerPeerIconSize, weight: .regular))
                        Text("\(headerOtherPeersCount)")
                            .font(.system(size: headerPeerCountFontSize, weight: .regular, design: theme.bodyFontDesign))
                            .accessibilityHidden(true)
                    }
                    .foregroundColor(headerCountColor)
                    .lineLimit(headerLineLimit)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(
                        format: String(localized: "content.accessibility.people_count", comment: "Accessibility label announcing number of people in header"),
                        locale: .current,
                        headerOtherPeersCount
                    )
                )
                // Connected-vs-nobody is otherwise encoded only in the icon's
                // color; say it.
                .accessibilityValue(
                    headerPeersReachable
                    ? String(localized: "content.accessibility.peers_connected", comment: "Accessibility value when peers are reachable")
                    : String(localized: "content.accessibility.peers_none", comment: "Accessibility value when no peers are reachable")
                )
            }
            .layoutPriority(3)
            .sheet(isPresented: $showVerifySheet) {
                VerificationSheetView(isPresented: $showVerifySheet)
                    .environmentObject(verificationModel)
            }
        }
        // Fixed height is load-bearing: children fill the bar with
        // .frame(maxHeight: .infinity) tap targets, so an open-ended
        // minHeight lets the header expand to swallow the whole screen.
        // headerHeight is a @ScaledMetric, so it still grows with Dynamic
        // Type.
        .frame(height: headerHeight)
        .padding(.horizontal, 12)
        .onReceive(CourierStore.shared.$carriedCount) { count in
            carriedMailCount = count
        }
        .onReceive(BoardStore.shared.$postsSnapshot) { posts in
            boardPosts = posts
        }
        .sheet(isPresented: $appChromeModel.isNoticesSheetPresented) {
            NoticesView(
                senderNickname: appChromeModel.nickname,
                board: appChromeModel.boardManager
            )
        }
        .alert("content.alert.screenshot.title", isPresented: $appChromeModel.showScreenshotPrivacyWarning) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("content.alert.screenshot.message")
        }
        .themedChromePanel(edge: .top)
    }
}

private extension View {
    /// Expands a small header icon to a comfortably tappable, full-bar-height
    /// hit area without changing its visual size.
    func headerTapTarget() -> some View {
        frame(minWidth: 30, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

private extension ContentHeaderView {
    var headerLineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? 2 : 1
    }

    /// Whether the mesh-local board has any notices pinned.
    var scopeHasNotices: Bool {
        boardPosts.contains { $0.geohash.isEmpty }
    }

    /// New pins since the notices sheet was last opened.
    var unseenNoticesCount: Int {
        boardAlertsModel.unseenCount(forGeohash: "")
    }

    /// Whether anyone is actually reachable on the mesh — the state the
    /// count icon's color encodes visually.
    var headerPeersReachable: Bool {
        peerListModel.connectedMeshPeerCount > 0
    }

    func channelPeopleCountAndColor() -> (Int, Color) {
        let meshBlue = Color(hue: 0.60, saturation: 0.85, brightness: 0.82)
        let color: Color = peerListModel.connectedMeshPeerCount > 0 ? meshBlue : palette.secondary
        return (peerListModel.reachableMeshPeerCount, color)
    }
}
