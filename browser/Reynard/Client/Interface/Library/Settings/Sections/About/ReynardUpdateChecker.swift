//
//  ReynardUpdateChecker.swift
//  Reynard
//
//  Manual upstream release checks for the experimental native video build.
//

import Foundation
import UIKit

final class ReynardUpdateChecker {
    private static let metadataURL = URL(string: "https://api.github.com/repos/minh-ton/reynard-browser/releases/latest")!
    private static let releasesURL = "https://github.com/minh-ton/reynard-browser/releases"

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case prerelease
        }
    }

    private struct Version: Comparable {
        let components: [Int]

        init?(_ value: String) {
            var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.hasPrefix("v") {
                normalized.removeFirst()
            }
            // Development builds use the same upstream version with this suffix.
            if normalized.hasSuffix("-dev") {
                normalized.removeLast(4)
            }
            let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ part in
                !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
            }) else { return nil }
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == parts.count else { return nil }
            components = numbers
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            for index in 0..<max(lhs.components.count, rhs.components.count) {
                let left = index < lhs.components.count ? lhs.components[index] : 0
                let right = index < rhs.components.count ? rhs.components[index] : 0
                if left != right { return left < right }
            }
            return false
        }

        static func == (lhs: Version, rhs: Version) -> Bool {
            return !(lhs < rhs) && !(rhs < lhs)
        }
    }

    private enum CheckError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case invalidRelease
        case invalidInstalledVersion

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return NSLocalizedString("The release server returned an invalid response.", comment: "")
            case let .httpStatus(status):
                return String(format: NSLocalizedString("The release server returned HTTP %d. Please try again later.", comment: ""), status)
            case .invalidRelease:
                return NSLocalizedString("The latest official release could not be read. No version comparison was made.", comment: "")
            case .invalidInstalledVersion:
                return NSLocalizedString("This build's installed version could not be read. No version comparison was made.", comment: "")
            }
        }
    }

    private var activeTask: URLSessionDataTask?
    private var activeSession: URLSession?
    private var activeRequestID: UUID?

    deinit {
        activeSession?.invalidateAndCancel()
    }

    func check(from viewController: UIViewController) {
        guard activeTask == nil, viewController.presentedViewController == nil else { return }

        let requestID = UUID()
        activeRequestID = requestID
        let alert = UIAlertController(
            title: NSLocalizedString("Checking for Reynard Updates", comment: ""),
            message: NSLocalizedString("Checking the latest official release…", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { [weak self] _ in
            self?.activeRequestID = nil
            self?.activeTask?.cancel()
            self?.activeTask = nil
            self?.activeSession?.invalidateAndCancel()
            self?.activeSession = nil
        })

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: Self.metadataURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Reynard-Manual-Update-Check", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { [weak self, weak viewController, weak alert] data, response, error in
            session.finishTasksAndInvalidate()
            let result: Result<Release, Error>
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse else { throw CheckError.invalidResponse }
                guard (200..<300).contains(response.statusCode) else { throw CheckError.httpStatus(response.statusCode) }
                guard let data, let release = try? JSONDecoder().decode(Release.self, from: data),
                      !release.draft, !release.prerelease, Version(release.tagName) != nil else {
                    throw CheckError.invalidRelease
                }
                result = .success(release)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self, self.activeRequestID == requestID else { return }
                self.activeRequestID = nil
                self.activeTask = nil
                self.activeSession = nil
                guard let viewController, let alert else { return }
                SettingsViewUtils.dismissPresentedAlert(alert, from: viewController) {
                    guard viewController.viewIfLoaded?.window != nil else { return }
                    self.show(result, from: viewController)
                }
            }
        }
        activeTask = task
        activeSession = session
        viewController.present(alert, animated: true) { [weak self, weak task] in
            guard self?.activeRequestID == requestID else { return }
            task?.resume()
        }
    }

    private func show(_ result: Result<Release, Error>, from viewController: UIViewController) {
        switch result {
        case let .failure(error):
            showError(error, from: viewController)
        case let .success(release):
            guard let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let installedVersion = Version(installed) else {
                showError(CheckError.invalidInstalledVersion, from: viewController)
                return
            }
            guard let latestVersion = Version(release.tagName) else {
                showError(CheckError.invalidRelease, from: viewController)
                return
            }
            let isNewer = latestVersion > installedVersion
            let versions = String(
                format: NSLocalizedString("Latest official release: %@\nInstalled version: %@", comment: ""),
                release.tagName, installed
            )
            let introduction = isNewer ? "" : NSLocalizedString("No newer official release is available.\n\n", comment: "")
            let process = NSLocalizedString("This button checks releases only. Updating this AVKit build requires merging upstream on the Mac, rebuilding, and sideloading a new custom IPA.", comment: "")
            let installation = (Bundle.main.object(forInfoDictionaryKey: "ReynardURLScheme") as? String) == "reynard-avkit"
                ? NSLocalizedString("Official IPAs update ordinary Reynard, not this separate AVKit preview, and do not include these video changes.", comment: "")
                : NSLocalizedString("Installing an official IPA replaces this custom build and omits its video changes until they are merged upstream.", comment: "")
            let explanation = introduction + process + "\n\n" + installation
            let alert = UIAlertController(
                title: isNewer ? NSLocalizedString("Reynard Update Available", comment: "") : NSLocalizedString("Reynard Update Check", comment: ""),
                message: versions + "\n\n" + explanation,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: NSLocalizedString("View Release", comment: ""), style: .default) { [weak viewController] _ in
                guard let viewController else { return }
                LibrarySharedUtils.openLinkInBrowser(Self.releasesURL, from: viewController)
            })
            alert.addAction(UIAlertAction(title: NSLocalizedString("Done", comment: ""), style: .cancel))
            viewController.present(alert, animated: true)
        }
    }

    private func showError(_ error: Error, from viewController: UIViewController) {
        let alert = UIAlertController(
            title: NSLocalizedString("Could Not Check for Updates", comment: ""),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Try Again", comment: ""), style: .default) { [weak self, weak viewController, weak alert] _ in
            guard let self, let viewController, let alert else { return }
            SettingsViewUtils.dismissPresentedAlert(alert, from: viewController) {
                self.check(from: viewController)
            }
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        viewController.present(alert, animated: true)
    }
}
