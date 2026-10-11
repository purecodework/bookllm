import SwiftUI

@main struct BookLLMApp: App {
    #if DEBUG
    @State private var studio = PaperUITestSupport.store()
    #else
    @State private var studio = StudioStore()
    #endif
    @State private var importer = ImportCoordinator()
    @State private var pasteDrafts = PasteDraftCoordinator()
    @State private var account = CloudAccount()
    @State private var purchases = PurchaseStore()
    private var uiTesting: Bool {
        #if DEBUG
        PaperUITestSupport.enabled
        #else
        false
        #endif
    }
    private var automatedTest: Bool {
        #if DEBUG
        uiTesting || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        #else
        false
        #endif
    }
    var body: some Scene {
        WindowGroup {
            AppShell().modifier(PaperUITestLayout()).environment(studio).environment(importer).environment(pasteDrafts).environment(account).environment(purchases).tint(Ink.accent).preferredColorScheme(.light)
                .onOpenURL { url in
                    if uiTesting { return }; if let id = WorkLink.identifier(url.absoluteString) { studio.incomingWorkID = id; return }
                    importer.start(url, studio: studio)
                }
                .task { if automatedTest { return }; await purchases.load(); if account.isLoggedIn { try? await account.refresh(); await purchases.recover(account: account) } }
                .task { if !automatedTest { await purchases.listen(account: account) } }
                .onChange(of: account.session) { _, _ in if !automatedTest { Task { await purchases.recover(account: account) } } }
        }
    }
}
struct AppShell: View {
    @Environment(StudioStore.self) private var studio
    @Environment(ImportCoordinator.self) private var importer
    @Environment(PasteDraftCoordinator.self) private var pasteDrafts
    @Environment(\.scenePhase) private var phase
    @AppStorage("onboardingCompleted") private var onboarded = false
    private var needsOnboarding: Bool {
        #if DEBUG
        if PaperUITestSupport.enabled { return false }
        #endif
        return !onboarded
    }
    var body: some View {
        @Bindable var studio = studio
        NavigationStack { LibraryView() }
        .alert("译间", isPresented: Binding(get: { studio.message != nil }, set: { if !$0 { studio.message = nil } })) { Button("知道了") { studio.message = nil } } message: { Text(studio.message ?? "") }
        .fullScreenCover(isPresented: Binding(get: { needsOnboarding }, set: { if !$0 { onboarded = true } })) { OnboardingView() }
        .sheet(isPresented: Binding(get: { studio.incomingWorkID != nil && onboarded }, set: { if !$0 { studio.incomingWorkID = nil } })) { if let id = studio.incomingWorkID { NavigationStack { WorkPurchaseView(workID: id).toolbar { PaperToolbarItem(placement: .cancellationAction) { Button("关闭") { studio.incomingWorkID = nil } } } } } }
        .fullScreenCover(isPresented: Binding(get: { importer.presented && !needsOnboarding }, set: { importer.presented = $0 })) { ImportSessionView() }
        .onChange(of: phase) { _, value in if value == .background { _ = pasteDrafts.flush(); studio.pause(reason: "进入后台，已暂停"); importer.pause(); studio.persist() } }
    }
}
#Preview {
    let root = URL.temporaryDirectory.appendingPathComponent("BookLLMPreview/" + UUID().uuidString)
    AppShell().environment(StudioStore(storageURL: root.appendingPathComponent("studio.json")))
        .environment(ImportCoordinator(rootURL: root.appendingPathComponent("imports")))
        .environment(PasteDraftCoordinator(storageURL: root.appendingPathComponent("paste-draft.json")))
        .environment(CloudAccount()).environment(PurchaseStore())
}
