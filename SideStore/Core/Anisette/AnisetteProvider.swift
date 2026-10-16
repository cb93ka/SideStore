//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import Network
import SideSign

enum AnisetteProvider {
    static func fetch(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        if let data = await fetchFromMac() {
            return data
        }
        if UserDefaults.standard.useOnDeviceAnisette {
            debugLog("[AnisetteProvider] Attempting On-Device Anisette (ODA)...")
            do {
                let data = try await OnDeviceAnisetteManager.shared.fetchAnisetteData()
                debugLog("[AnisetteProvider] On-Device Anisette succeeded.")
                return data
            } catch {
                debugLog("[AnisetteProvider] On-Device Anisette failed (\(error.localizedDescription)). Seamlessly falling back to remote Anisette servers...")
                return try await fetchRemote(handler: handler)
            }
        } else {
            debugLog("[AnisetteProvider] Fetching anisette via remote server...")
            return try await fetchRemote(handler: handler)
        }
    }

    /// A Mac on the same network running mac-anisette (an _http._tcp Bonjour service named "MacAnisette-…") serves its
    /// own anisette, which Apple accepts where it refuses the remote servers' identities. nil when there is none.
    /// The request goes over a connection to the Bonjour endpoint itself: the address it resolves to is often an IPv6
    /// link-local one, which is unusable once its interface scope is dropped.
    private static func fetchFromMac() async -> ALTAnisetteData? {
        guard let body = await MacAnisetteRequest().run(timeout: 4) else { return nil }
        do {
            guard let headers = try JSONSerialization.jsonObject(with: body) as? [String: String] else {
                debugLog("[AnisetteProvider] Mac anisette gave no headers")
                return nil
            }
            let anisette = try SideSign.AnisetteDataManager.validateAndCreateAnisetteData(from: headers)
            debugLog("[AnisetteProvider] Using this network's Mac anisette (\(anisette.clientInfo))")
            return anisette
        } catch {
            debugLog("[AnisetteProvider] Mac anisette failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        let serverUrlStrings = await AnisetteServersManager.shared.getActiveServerURLs()
        let servers = serverUrlStrings.compactMap { URL(string: $0) }
        guard !servers.isEmpty else {
            throw AnisetteError.noServersConfigured
        }

        let lastServer = UserDefaults.standard.menuAnisetteURL
        let startIndex = servers.firstIndex(where: { $0.absoluteString == lastServer }) ?? 0

        let provider = SideSign.AnisetteDataManager.shared
        let existingBlob = AnisetteConfigManager.shared.anisetteAdiBlob.flatMap { Data(base64Encoded: $0) }
        let identifier = await AnisetteConfigManager.shared.resolveDeviceIdentifier()
        let headers = await AnisetteConfigManager.shared.makeRequestHeaders()

        let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteDataWithFailover(
            servers: UserDefaults.standard.disableAnisetteRotation ? [servers[startIndex]] : servers,
            startIndex: startIndex,
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers,
            onError: { error in
                if let anisetteError = error as? SideSign.AnisetteError,
                   case .outdatedV1Server(let serverURL, _) = anisetteError {
                    if UserDefaults.standard.defaultServerURL == serverURL.absoluteString {
                        return true
                    }
                    if let handler = handler {
                        let shouldContinue = try await handler.warnOutdatedAnisetteServer()
                        if shouldContinue {
                            UserDefaults.standard.defaultServerURL = serverURL.absoluteString
                        }
                        return shouldContinue
                    }
                }
                return false
            },
            onSuccess: { successfulServer in
                UserDefaults.standard.menuAnisetteURL = successfulServer.absoluteString
                debugLog("[AnisetteProvider] Successfully fetched Anisette data from \(successfulServer.absoluteString)")
            }
        )

        if let freshBlob = newAdiBlob {
            AnisetteConfigManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
        }

        return anisetteData
    }
}

/// Finds the first "MacAnisette-…" Bonjour service and GETs "/" from it over a connection to that endpoint, giving the
/// response body, or nil on no service, an error or the timeout.
private final class MacAnisetteRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacAnisetteRequest")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var received = Data()
    private var continuation: CheckedContinuation<Data?, Never>?

    func run(timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    debugLog("[AnisetteProvider] No Mac anisette on this network within \(timeout)s")
                    self.finish(nil)
                }
                let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
                browser.browseResultsChangedHandler = { results, _ in
                    guard self.connection == nil, let mac = results.first(where: {
                        if case .service(let name, _, _, _) = $0.endpoint { return name.hasPrefix("MacAnisette") }
                        return false
                    }) else { return }
                    debugLog("[AnisetteProvider] Found Mac anisette \(mac.endpoint)")
                    self.request(mac.endpoint)
                }
                self.browser = browser
                browser.start(queue: self.queue)
            }
        }
    }

    private func request(_ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let get = "GET / HTTP/1.1\r\nHost: mac-anisette\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(get.utf8), completion: .contentProcessed { _ in self.receive() })
            case .failed(let error):
                debugLog("[AnisetteProvider] Mac anisette connection failed: \(error)")
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data { self.received.append(data) }
            if isComplete || error != nil {
                self.finish(self.body())
            } else {
                self.receive()
            }
        }
    }

    /// The body of a 200 response in `received`.
    private func body() -> Data? {
        guard let split = received.range(of: Data("\r\n\r\n".utf8)),
              let status = String(data: received[..<split.lowerBound], encoding: .utf8)?.split(separator: " ").dropFirst().first,
              status == "200" else {
            debugLog("[AnisetteProvider] Mac anisette answered without a 200")
            return nil
        }
        return received[split.upperBound...]
    }

    private func finish(_ result: Data?) {
        guard let continuation else { return }
        self.continuation = nil
        browser?.cancel()
        connection?.cancel()
        continuation.resume(returning: result)
    }
}

