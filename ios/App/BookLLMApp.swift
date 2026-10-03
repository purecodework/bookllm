import SwiftUI

@main struct BookLLMApp: App {
    @State private var studio = StudioStore()
    @State private var account = CloudAccount()
    @State private var purchases = PurchaseStore()
    var body: some Scene {
        WindowGroup {
            AppShell().environment(studio).environment(account).environment(purchases).tint(Ink.orange).preferredColorScheme(.light)
                .onOpenURL { url in
                    Task {
                        do { let imported = try await Task.detached(priority: .userInitiated) { try DocumentIO.read(url) }.value; _ = studio.add(imported) }
                        catch { studio.message = error.localizedDescription }
                    }
                }
                .task { await purchases.load(); if account.isLoggedIn { try? await account.refresh(); await purchases.recover(account: account) } }
                .task { await purchases.listen(account: account) }
                .onChange(of: account.session) { _, _ in Task { await purchases.recover(account: account) } }
        }
    }
}
struct AppShell: View {
    @Environment(StudioStore.self) private var studio
    @Environment(\.scenePhase) private var phase
    var body: some View {
        @Bindable var studio = studio
        TabView {
            NavigationStack { LibraryView() }.tabItem { Label("书房", systemImage: "books.vertical") }
            NavigationStack { StylesView() }.tabItem { Label("风格", systemImage: "paintbrush.pointed") }
            NavigationStack { GlossaryLibraryView() }.tabItem { Label("术语", systemImage: "text.book.closed") }
            NavigationStack { SettingsView() }.tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .alert("译间", isPresented: Binding(get: { studio.message != nil }, set: { if !$0 { studio.message = nil } })) { Button("知道了") { studio.message = nil } } message: { Text(studio.message ?? "") }
        .onChange(of: phase) { _, value in if value == .background { studio.pause(); studio.persist() } }
    }
}
#Preview { AppShell().environment(StudioStore()).environment(CloudAccount()).environment(PurchaseStore()) }
