import AppKit
@preconcurrency import ScreenCaptureKit

/// System window picker (SCContentSharingPicker) for window picture-in-picture.
/// The user chooses the window in Apple's UI, so no window list is needed here.
@MainActor
final class WindowPicker: NSObject, SCContentSharingPickerObserver {
    static let shared = WindowPicker()

    private var isObserving = false

    func present() {
        let picker = SCContentSharingPicker.shared
        if !isObserving {
            picker.add(self)
            isObserving = true
        }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present(using: .window)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // Only new picks open windows; updates for an existing stream are ignored.
        guard stream == nil else { return }
        let title = filter.includedWindows.first.map { window in
            [window.owningApplication?.applicationName, window.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        } ?? "Window"
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                DisplayStore.shared.showWindowPreview(filter: filter, title: title)
            }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {}

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async {
            MainActor.assumeIsolated { DisplayStore.shared.lastError = "Window picker: \(message)" }
        }
    }
}
