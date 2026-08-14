import AppKit
import Foundation

/// Builds and owns the persistent menu bar icon and its menu. See
/// docs/mihomo_menubar_spec.md for the menu layout this implements and the
/// rationale for driving everything through `mihomo-cli` subprocesses.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let bridge: CLIBridge
    private let fetcher: MenuBarStateFetcher
    private let loginAgent: LoginItemAgent

    private var snapshot = MenuBarSnapshot()
    private var refreshTimer: Timer?
    private var isRefreshing = false

    // Rebuilt every refresh so checkmarks always reflect real state rather
    // than an optimistic guess made at click-time.
    private var outboundModeItems: [OutboundMode: NSMenuItem] = [:]
    private var systemProxyItem: NSMenuItem!
    private var tunItem: NSMenuItem!
    private var switchConfigMenu: NSMenu!
    private var reloadItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var cliMissingItem: NSMenuItem!

    init(bridge: CLIBridge, loginAgent: LoginItemAgent) {
        self.bridge = bridge
        self.fetcher = MenuBarStateFetcher(bridge: bridge)
        self.loginAgent = loginAgent
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureIcon()
        buildMenu()
        startPolling()
    }

    private func configureIcon() {
        // A plain, always-visible glyph — this app has no "connected/
        // disconnected" concept of its own (that belongs to `net status`,
        // reflected via the menu items instead), so the icon itself stays
        // static rather than trying to encode state that's already shown
        // one click away.
        if let image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "mihomo") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "mihomo"
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        cliMissingItem = NSMenuItem(title: "mihomo-cli not found — see MIHOMO_CLI_PATH", action: nil, keyEquivalent: "")
        cliMissingItem.isEnabled = false
        cliMissingItem.isHidden = true
        menu.addItem(cliMissingItem)

        let showWindow = NSMenuItem(title: "Show Main Window", action: #selector(showMainWindow), keyEquivalent: "")
        showWindow.target = self
        menu.addItem(showWindow)

        menu.addItem(.separator())

        let outboundModeMenu = NSMenu()
        for mode in [OutboundMode.direct, .global, .rule] {
            let item = NSMenuItem(title: title(for: mode), action: #selector(selectOutboundMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            outboundModeMenu.addItem(item)
            outboundModeItems[mode] = item
        }
        let outboundModeParent = NSMenuItem(title: "Outbound Mode", action: nil, keyEquivalent: "")
        outboundModeParent.submenu = outboundModeMenu
        menu.addItem(outboundModeParent)

        systemProxyItem = NSMenuItem(title: "Set as System Proxy", action: #selector(toggleSystemProxy), keyEquivalent: "")
        systemProxyItem.target = self
        menu.addItem(systemProxyItem)

        tunItem = NSMenuItem(title: "Enhanced Mode (TUN mode)", action: #selector(toggleTun), keyEquivalent: "")
        tunItem.target = self
        menu.addItem(tunItem)

        menu.addItem(.separator())

        switchConfigMenu = NSMenu()
        let switchConfigParent = NSMenuItem(title: "Switch Configuration", action: nil, keyEquivalent: "")
        switchConfigParent.submenu = switchConfigMenu
        menu.addItem(switchConfigParent)

        reloadItem = NSMenuItem(title: "Reload Configuration", action: #selector(reloadConfiguration), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func title(for mode: OutboundMode) -> String {
        switch mode {
        case .direct: return "Direct"
        case .global: return "Global"
        case .rule: return "Rule"
        }
    }

    // MARK: - Polling

    private func startPolling() {
        Task { await refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Also called on `menuNeedsUpdate` so the menu is guaranteed fresh the
    /// moment the user actually opens it, not just on the 5s cadence.
    func menuNeedsUpdate(_ menu: NSMenu) {
        Task { await refresh() }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        snapshot = await fetcher.fetch()
        applySnapshot()
    }

    private func applySnapshot() {
        cliMissingItem.isHidden = snapshot.cliAvailable

        for (mode, item) in outboundModeItems {
            item.state = (snapshot.outboundMode == mode) ? .on : .off
        }

        systemProxyItem.state = (snapshot.networkMode == .systemProxy) ? .on : .off
        tunItem.state = (snapshot.networkMode == .tun) ? .on : .off

        switchConfigMenu.removeAllItems()
        if snapshot.subscriptions.isEmpty {
            let empty = NSMenuItem(title: "No subscriptions configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            switchConfigMenu.addItem(empty)
        } else {
            for sub in snapshot.subscriptions {
                let item = NSMenuItem(title: sub.name, action: #selector(selectSubscription(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = sub.name
                item.state = sub.isActive ? .on : .off
                switchConfigMenu.addItem(item)
            }
        }

        launchAtLoginItem.state = loginAgent.isEnabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func showMainWindow() {
        guard let url = URL(string: "http://127.0.0.1:9090") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func selectOutboundMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? OutboundMode else { return }
        // `mode rule` takes no `--yes` flag (it's always allowed, no
        // behavior-change warning to suppress); `global`/`direct` do.
        let args = mode == .rule ? ["mode", "rule"] : ["mode", mode.rawValue, "--yes"]
        Task {
            let result = try? await bridge.run(args)
            await handle(result, action: "switch to \(mode.rawValue) mode")
        }
    }

    @objc private func toggleSystemProxy() {
        let turningOn = systemProxyItem.state != .on
        Task {
            guard turningOn else {
                let result = try? await bridge.run(["net", "system-proxy", "off"])
                await handle(result, action: "disable system proxy")
                return
            }

            let result = try? await bridge.run(["net", "system-proxy", "on", "--yes"])
            if let result, !result.succeeded, result.stderr.contains("multiple active network services") {
                await presentInterfacePicker()
                return
            }
            await handle(result, action: "enable system proxy")
        }
    }

    /// Fallback for the case `net system-proxy on --yes` can't resolve on
    /// its own: more than one network service is active and this app never
    /// passes `--interface` up front (see spec doc §2.5 — deliberately
    /// non-interactive by default). Mirrors the CLI's own terminal prompt
    /// ("Multiple active network services found... Which should carry the
    /// proxy?") as an NSAlert + popup button instead of a readline prompt.
    private func presentInterfacePicker() async {
        let services = NetworkServiceLister.listAllServiceNames()
        guard !services.isEmpty else {
            presentAlert(
                title: "Couldn't enable system proxy",
                message: "Multiple active network services were found, but none could be listed to choose from. Run 'mihomo net system-proxy on --interface <name>' from a terminal instead."
            )
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        popup.addItems(withTitles: services)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Which network service should carry the proxy?"
        alert.informativeText = "More than one active network service was found."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn,
              let chosen = popup.titleOfSelectedItem else { return }

        let result = try? await bridge.run(["net", "system-proxy", "on", "--interface", chosen, "--yes"])
        await handle(result, action: "enable system proxy on '\(chosen)'")
    }

    @objc private func toggleTun() {
        let turningOn = tunItem.state != .on
        Task {
            let args = turningOn ? ["net", "tun", "on", "--yes"] : ["net", "tun", "off"]
            let result = try? await bridge.run(args)
            await handle(result, action: turningOn ? "enable TUN mode" : "disable TUN mode")
        }
    }

    @objc private func selectSubscription(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Task {
            let result = try? await bridge.run(["sub", "use", name])
            await handle(result, action: "switch to '\(name)'")
        }
    }

    @objc private func reloadConfiguration() {
        // No dedicated "reload" subcommand exists (see spec doc §Reload
        // Configuration for why); `restart` is the tested atomic stop/start
        // of the kernel process, which is what actually re-reads config.
        Task {
            let result = try? await bridge.run(["restart"])
            await handle(result, action: "reload configuration")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = launchAtLoginItem.state != .on
        do {
            try loginAgent.setEnabled(enable)
            launchAtLoginItem.state = enable ? .on : .off
        } catch {
            presentAlert(title: "Couldn't update Launch at Login", message: "\(error)")
        }
    }

    // MARK: - Result handling

    private func handle(_ result: CLIResult?, action: String) async {
        await refresh()

        guard let result else {
            presentAlert(title: "Couldn't \(action)", message: CLIBridgeError.binaryNotFound.description)
            return
        }
        guard !result.succeeded else { return }

        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        presentAlert(title: "Couldn't \(action)", message: message.isEmpty ? "mihomo-cli exited with status \(result.exitCode)" : message)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
