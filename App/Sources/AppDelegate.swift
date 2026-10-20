import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var loginWindow: NSWindow?
    private let model = DysonModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        model.onStateChange = { [weak self] in self?.updateMenuBar() }
        model.onSignInRequired = { [weak self] in self?.showLogin() }
        // The socket does not survive sleep; reconnect right away on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.reconnectNow() }
        }
        model.start()
        updateMenuBar()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    // MARK: - status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = MenuBarIcon.image()
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let view = PopoverView(onSignIn: { [weak self] in self?.showLogin() })
            .environmentObject(model)
        let hosting = NSHostingController(rootView: view)
        // Resize the popover when content changes (e.g. controls appear on power-on).
        hosting.sizingOptions = .preferredContentSize
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = hosting
        popover = pop
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        if model.session != nil {
            menu.addItem(item("Refresh", #selector(refreshAction)))
            if model.devices.count > 1 {
                let devicesItem = NSMenuItem(title: "Device", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for device in model.devices {
                    let entry = item(device.name, #selector(selectDeviceAction(_:)))
                    entry.representedObject = device.serial
                    entry.state = device.serial == model.device?.serial ? .on : .off
                    submenu.addItem(entry)
                }
                devicesItem.submenu = submenu
                menu.addItem(devicesItem)
            }
            menu.addItem(.separator())
            let account = NSMenuItem(title: model.session?.email ?? "", action: nil, keyEquivalent: "")
            account.isEnabled = false
            menu.addItem(account)
            menu.addItem(item("Sign Out", #selector(signOutAction)))
        } else {
            menu.addItem(item("Sign In…", #selector(signInAction)))
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit DysonBar", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func refreshAction() { model.requestState() }
    @objc private func signInAction() { showLogin() }

    @objc private func signOutAction() {
        popover?.performClose(nil)
        model.signOut()
    }

    @objc private func selectDeviceAction(_ sender: NSMenuItem) {
        if let serial = sender.representedObject as? String { model.selectDevice(serial) }
    }

    private func togglePopover() {
        guard let popover = popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.requestState()
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateMenuBar() {
        guard let button = statusItem?.button else { return }
        let title = model.menuBarText
        if button.title != title { button.title = title }
    }

    // MARK: - sign-in window

    private func showLogin() {
        popover?.performClose(nil)
        if loginWindow == nil {
            let flow = LoginFlow(model: model)
            flow.onFinished = { [weak self] in
                self?.loginWindow?.close()
                self?.loginWindow = nil  // next sign-in starts from a fresh flow
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: LoginView(flow: flow)))
            window.title = "DysonBar"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            loginWindow = window
        }
        NSApp.activate()
        loginWindow?.makeKeyAndOrderFront(nil)
    }
}
