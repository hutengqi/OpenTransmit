import AppKit
import Combine
import Sparkle

/// Sparkle owns download verification, the out-of-sandbox installer and relaunch.
@MainActor final class AppUpdateStore: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var waitingForFileOperations = false
    @Published private(set) var startupError: String?
    private let transfers: TransferStore
    private var controller: SPUStandardUpdaterController!
    private var observation: AnyCancellable?
    private var deferredInstall: (() -> Void)?

    init(transfers: TransferStore, startAutomatically: Bool = true) {
        self.transfers = transfers
        super.init()
        transfers.onActivityChange = { [weak self] in self?.resumeInstallationIfIdle() }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        guard startAutomatically else { return }
        do {
            try controller.updater.start()
            if controller.updater.automaticallyChecksForUpdates {
                controller.updater.checkForUpdatesInBackground()
            }
        } catch { startupError = "无法启动更新检查：\(error.localizedDescription)" }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { availableVersion = nil }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard transfers.busyForApplicationUpdate else {
            transfers.installingApplicationUpdate = true
            return false
        }
        deferredInstall = installHandler
        waitingForFileOperations = true
        return true
    }

    func resumeInstallationIfIdle() {
        guard !transfers.busyForApplicationUpdate, let install = deferredInstall else { return }
        deferredInstall = nil
        waitingForFileOperations = false
        transfers.installingApplicationUpdate = true
        install()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        deferredInstall = nil
        waitingForFileOperations = false
        transfers.installingApplicationUpdate = false
    }
}
