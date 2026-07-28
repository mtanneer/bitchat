//
// BitchatApp.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import UserNotifications

@main
struct BitchatApp: App {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.planechat.ios"
    static let groupID = "group.\(bundleID)"

    @StateObject private var roomStore = RoomStore()
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.matrix.rawValue

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let session = roomStore.activeSession {
                    RoomRuntimeView(session: session, roomStore: roomStore)
                } else {
                    HomeView()
                }
            }
            .environment(\.appTheme, AppTheme(rawValue: appThemeRawValue) ?? .matrix)
            .environmentObject(roomStore)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        #endif
    }
}

/// Builds `AppRuntime` (and with it `ChatViewModel`/`BLEService`) only once a
/// room is chosen, scoped to that room's `roomId` — see RoomStore.swift.
private struct RoomRuntimeView: View {
    let session: ActiveRoomSession
    @ObservedObject var roomStore: RoomStore
    @StateObject private var runtime: AppRuntime
    @State private var showChat = false
    #if os(iOS)
    @Environment(\.scenePhase) var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate
    #endif

    init(session: ActiveRoomSession, roomStore: RoomStore) {
        self.session = session
        self.roomStore = roomStore
        _runtime = StateObject(wrappedValue: AppRuntime(roomId: session.roomId))
    }

    var body: some View {
        Group {
            if showChat {
                ContentView()
                    .overlay(alignment: .topTrailing) {
                        LeaveRoomControl(session: session, roomStore: roomStore)
                    }
            } else {
                LobbyView(roomName: session.roomName, onEnterChat: { showChat = true })
                    .overlay(alignment: .topTrailing) {
                        LeaveRoomControl(session: session, roomStore: roomStore)
                    }
            }
        }
            .environmentObject(runtime.publicChatModel)
            .environmentObject(runtime.privateInboxModel)
            .environmentObject(runtime.privateConversationModel)
            .environmentObject(runtime.verificationModel)
            .environmentObject(runtime.conversationUIModel)
            .environmentObject(runtime.peerListModel)
            .environmentObject(runtime.appChromeModel)
            .environmentObject(runtime.boardAlertsModel)
            .onAppear {
                appDelegate.runtime = runtime
                runtime.start()
            }
            .onOpenURL { url in
                runtime.handleOpenURL(url)
            }
            #if os(iOS)
            .onChange(of: scenePhase) { newPhase in
                runtime.handleScenePhaseChange(newPhase)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                runtime.handleDidBecomeActiveNotification()
            }
            #elseif os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                runtime.handleMacDidBecomeActiveNotification()
            }
            #endif
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var runtime: AppRuntime?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        runtime?.applicationWillTerminate()
    }
}
#endif

#if os(macOS)
import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: AppRuntime?

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.applicationWillTerminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    weak var runtime: AppRuntime?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        // Complete only after the response is handled: for a background
        // action (👋 wave) the system may suspend the app the moment the
        // completion handler runs, which would drop the queued send.
        Task { @MainActor in
            self.runtime?.handleNotificationResponse(
                identifier: identifier,
                actionIdentifier: actionIdentifier,
                userInfo: userInfo
            )
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        let userInfo = notification.request.content.userInfo

        Task {
            let options = await self.runtime?.presentationOptions(
                forNotificationIdentifier: identifier,
                userInfo: userInfo
            ) ?? [.banner, .sound]
            completionHandler(options)
        }
    }
}
