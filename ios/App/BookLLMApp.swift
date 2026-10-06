import SwiftUI

@main struct BookLLMApp: App {
    @State private var studio = StudioStore()
    @State private var importer = ImportCoordinator()
    @State private var account = CloudAccount()
    @State private var purchases = PurchaseStore()
    var body: some Scene {
        WindowGroup {
            AppShell().environment(studio).environment(importer).environment(account).environment(purchases).tint(Ink.orange).preferredColorScheme(.light)
                .onOpenURL { url in
                    if let id = WorkLink.identifier(url.absoluteString) { studio.incomingWorkID = id; return }
                    importer.start(url, studio: studio)
                }
                .task { await purchases.load(); if account.isLoggedIn { try? await account.refresh(); await purchases.recover(account: account) } }
                .task { await purchases.listen(account: account) }
                .onChange(of: account.session) { _, _ in Task { await purchases.recover(account: account) } }
        }
    }
}
struct AppShell: View {
    @Environment(StudioStore.self) private var studio
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.scenePhase) private var phase
    @AppStorage("onboardingCompleted") private var onboarded = false
    var body: some View {
        @Bindable var studio = studio
        TabView {
            NavigationStack { LibraryView() }.tabItem { Label("书房", systemImage: "books.vertical") }
            NavigationStack { StylesView() }.tabItem { Label("风格", systemImage: "paintbrush.pointed") }
            NavigationStack { SettingsView() }.tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .alert("译间", isPresented: Binding(get: { studio.message != nil }, set: { if !$0 { studio.message = nil } })) { Button("知道了") { studio.message = nil } } message: { Text(studio.message ?? "") }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) { OnboardingView() }
        .sheet(isPresented: Binding(get: { studio.incomingWorkID != nil && onboarded }, set: { if !$0 { studio.incomingWorkID = nil } })) { if let id = studio.incomingWorkID { NavigationStack { WorkPurchaseView(workID: id).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { studio.incomingWorkID = nil } } } } } }
        .fullScreenCover(isPresented: Binding(get: { importer.presented && onboarded }, set: { importer.presented = $0 })) { ImportSessionView() }
        .onChange(of: phase) { _, value in if value == .background { studio.pause(); importer.pause(); studio.persist() } }
    }
}
#Preview { AppShell().environment(StudioStore()).environment(ImportCoordinator()).environment(CloudAccount()).environment(PurchaseStore()) }
