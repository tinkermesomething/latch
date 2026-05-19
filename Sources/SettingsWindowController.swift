import AppKit
import Carbon.HIToolbox

final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let configManager: ConfigManager
    private let moduleRegistry: ModuleRegistry

    // Sidebar
    private var tableView:   NSTableView!
    private var selectedRow: Int = 0

    // Detail container
    private var detailContainer:   NSView!
    private var currentDetailView: NSView?

    // Keyboard panel — refs preserved across rebuilds so populateKeyboardPanel() can reach them
    private var autoDetectCheckbox:     NSButton!
    private var macLayoutPopup:         NSPopUpButton!
    private var pcLayoutPopup:          NSPopUpButton!
    private var bluetoothCheckbox:          NSButton!
    private var activeDetectionCheckbox:    NSButton!
    private var keyboardUSBNotifCheckbox:   NSButton!
    private var keyboardBTNotifCheckbox:    NSButton!

    private var availableLayouts: [String] = []

    private enum SidebarItem: Equatable {
        case general, keyboard, notifications
        case userModule(id: String, name: String)

        var title: String {
            switch self {
            case .general:                    return "General"
            case .keyboard:                   return "Keyboard Layout"
            case .notifications:              return "Notifications"
            case .userModule(_, let name):    return name
            }
        }

        static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool {
            switch (lhs, rhs) {
            case (.general, .general),
                 (.keyboard, .keyboard),
                 (.notifications, .notifications):
                return true
            case (.userModule(let a, _), .userModule(let b, _)):
                return a == b
            default:
                return false
            }
        }
    }

    private var sidebarItems: [SidebarItem] {
        let active = moduleRegistry.active
        var items: [SidebarItem] = [.general]
        // Notifications tab appears when anything that can send a notification is active/configured
        let hasNotifications = active.contains(where: { $0.id == "keyboard-switcher" })
            || !configManager.config.userModules.isEmpty
        if hasNotifications { items.append(.notifications) }
        if active.contains(where: { $0.id == "keyboard-switcher" }) { items.append(.keyboard) }
        // One sidebar entry per user-defined latch (all, including disabled — so they remain editable)
        for mod in configManager.config.userModules {
            items.append(.userModule(id: mod.id, name: mod.name))
        }
        return items
    }

    private var sidebarTitles: [String] { sidebarItems.map { $0.title } }

    /// Set by AppDelegate — called when user clicks "Check for Updates" in General tab.
    var onCheckForUpdates: (() -> Void)?

    init(configManager: ConfigManager, moduleRegistry: ModuleRegistry) {
        self.configManager  = configManager
        self.moduleRegistry = moduleRegistry
        super.init()
    }

    func showWindow() {
        if window == nil { buildWindow() } else { selectRow(selectedRow) }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Window

    private func buildWindow() {
        let w = NSWindow(
            contentRect: .zero,
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        w.title                = "Settings — latch"
        w.delegate             = self
        w.isReleasedWhenClosed = false

        let content = w.contentView!

        let sidebarScroll = buildSidebarView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        let divider         = NSBox()
        divider.boxType     = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        detailContainer     = NSView()
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(sidebarScroll)
        content.addSubview(divider)
        content.addSubview(detailContainer)

        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 160),

            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            detailContainer.topAnchor.constraint(equalTo: content.topAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        self.window = w

        // Size the window to the most content-heavy registered panel so it adapts
        // to the user's font size and control sizes — no hardcoded pixels.
        // General uses a scroll view whose fittingSize is useless for sizing, so
        // prefer Keyboard for measurement; fall back to a sensible minimum.
        let items = sidebarItems
        if let sizingRow = items.lastIndex(of: .keyboard) {
            selectRow(sizingRow)
            content.layoutSubtreeIfNeeded()
            w.setContentSize(content.fittingSize)
        } else {
            w.setContentSize(NSSize(width: 560, height: 420))
        }
        // Show default tab
        selectRow(0)
    }

    private func buildSidebarView() -> NSScrollView {
        let col            = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.isEditable     = false

        tableView          = NSTableView()
        tableView.addTableColumn(col)
        tableView.headerView              = nil
        tableView.rowHeight               = 32
        tableView.style                   = .sourceList
        tableView.backgroundColor         = .clear
        tableView.dataSource              = self
        tableView.delegate                = self
        tableView.focusRingType           = .none
        tableView.intercellSpacing        = .zero

        let sv                     = NSScrollView()
        sv.documentView            = tableView
        sv.hasVerticalScroller     = false
        sv.hasHorizontalScroller   = false
        sv.drawsBackground         = true
        sv.backgroundColor         = NSColor(calibratedWhite: 0.12, alpha: 1)
        sv.appearance              = NSAppearance(named: .darkAqua)
        return sv
    }

    // MARK: - Detail switching

    private func selectRow(_ row: Int) {
        selectedRow = row
        tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        let items = sidebarItems
        let item  = row < items.count ? items[row] : .general
        let view: NSView
        switch item {
        case .general:                 view = makeGeneralPanel()
        case .keyboard:                view = makeKeyboardPanel()
        case .notifications:           view = makeNotificationsPanel()
        case .userModule(let id, _):   view = makeLatchPanel(id: id)
        }

        currentDetailView?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
        ])
        currentDetailView = view
    }

    // MARK: - General panel

    private func makeGeneralPanel() -> NSView {
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeAboutTab())
        tabView.addTabViewItem(makeModulesTab())
        tabView.addTabViewItem(makeLatchesTab())
        tabView.addTabViewItem(makeBackupTab())
        return tabView
    }

    private func makeAboutTab() -> NSTabViewItem {
        let iconView = NSImageView()
        iconView.image        = NSImage(named: NSImage.applicationIconName)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),
        ])

        let appName = NSTextField(labelWithString: "latch")
        appName.font = .boldSystemFont(ofSize: 15)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)
        versionLabel.textColor = .secondaryLabelColor

        let tagline = NSTextField(labelWithString: "Hardware-triggered automations for macOS")
        tagline.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tagline.textColor = .secondaryLabelColor

        let linkButton = NSButton(title: "", target: self, action: #selector(openRepoTapped))
        linkButton.attributedTitle = NSAttributedString(string: "View on GitHub", attributes: [
            .font:            NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle:  NSUnderlineStyle.single.rawValue,
        ])
        linkButton.isBordered = false

        let infoStack = NSStackView(views: [appName, versionLabel, tagline, linkButton])
        infoStack.orientation = .vertical
        infoStack.alignment   = .leading
        infoStack.spacing     = 2
        infoStack.setCustomSpacing(8, after: tagline)

        let aboutRow = NSStackView(views: [iconView, infoStack])
        aboutRow.orientation = .horizontal
        aboutRow.alignment   = .centerY
        aboutRow.spacing     = 16

        let divider = NSBox(); divider.boxType = .separator

        let loginCheckbox = NSButton(
            checkboxWithTitle: "Launch at Login",
            target: self, action: #selector(launchAtLoginToggled)
        )
        loginCheckbox.state = LaunchAtLogin.isEnabled() ? .on : .off

        let updateButton = NSButton(title: "Check for Updates...", target: self,
                                    action: #selector(checkForUpdatesTapped))
        updateButton.bezelStyle = .rounded

        let stack = NSStackView(views: [aboutRow, divider, loginCheckbox, updateButton])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 14
        stack.edgeInsets  = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let item = NSTabViewItem()
        item.label = "About"
        item.view  = stack
        return item
    }

    private func makeModulesTab() -> NSTabViewItem {
        var views:   [NSView]                        = []
        var entries: [(entry: NSStackView, label: NSTextField)] = []

        for (idx, desc) in ModuleRegistry.available.enumerated() {
            let isActive = moduleRegistry.active.contains(where: { $0.id == desc.id })
            let checkbox = NSButton(checkboxWithTitle: desc.displayName, target: self,
                                    action: #selector(moduleToggled(_:)))
            checkbox.state = isActive ? .on : .off
            checkbox.tag   = idx

            let descLabel = NSTextField(wrappingLabelWithString: desc.description)
            descLabel.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)
            descLabel.textColor = .secondaryLabelColor

            let entry = NSStackView(views: [checkbox, descLabel])
            entry.orientation = .vertical
            entry.alignment   = .leading
            entry.spacing     = 3
            views.append(entry)
            entries.append((entry, descLabel))
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 16
        stack.edgeInsets  = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.autoresizingMask = [.width, .height]
        wrapper.addSubview(stack)

        // Pin stack to wrapper so its widthAnchor is resolvable
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])

        // .leading stacks don't generate trailing constraints for children, so wrapping
        // labels never get a finite width to break at. Force entries and their labels
        // to span the full internal width of the stack (stack width minus 20+20 insets).
        for (entry, descLabel) in entries {
            entry.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            descLabel.widthAnchor.constraint(equalTo: entry.widthAnchor).isActive = true
        }

        let item = NSTabViewItem()
        item.label = "Modules"
        item.view  = wrapper
        return item
    }

    private func makeLatchesTab() -> NSTabViewItem {
        let header = NSTextField(labelWithString: "My Latches")
        header.font = .boldSystemFont(ofSize: 13)

        let sub = NSTextField(wrappingLabelWithString:
            "Create automations triggered by USB, Bluetooth, or Thunderbolt events.")
        sub.font      = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        // Low hugging so the width constraint below wins over intrinsic size
        sub.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let addButton = NSButton(title: "+ Add Latch", target: self, action: #selector(addLatchTapped))
        addButton.bezelStyle = .rounded

        let stack = NSStackView(views: [header, sub, addButton])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 12
        stack.edgeInsets  = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.autoresizingMask = [.width, .height]
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            // Constrain sub to the stack's internal width so it has a finite width to wrap at
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])

        let item = NSTabViewItem()
        item.label = "My Latches"
        item.view  = wrapper
        return item
    }

    private func makeBackupTab() -> NSTabViewItem {
        let exportButton = NSButton(title: "Export Config Backup...", target: self,
                                    action: #selector(exportConfigTapped))
        exportButton.bezelStyle = .rounded

        let importButton = NSButton(title: "Import Config...", target: self,
                                    action: #selector(importConfigTapped))
        importButton.bezelStyle = .rounded

        let note = NSTextField(labelWithString: "Import replaces all settings and latches.")
        note.font      = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [exportButton, importButton, note])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 12
        stack.edgeInsets  = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let item = NSTabViewItem()
        item.label = "Backup"
        item.view  = stack
        return item
    }

    @objc private func openRepoTapped() {
        NSWorkspace.shared.open(URL(string: "https://github.com/tinkermesomething/latch")!)
    }

    @objc private func exportConfigTapped() {
        let panel = NSSavePanel()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "latch-backup-\(df.string(from: Date())).json"
        panel.allowedContentTypes  = [.json]
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.configManager.exportConfig(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText     = "Export failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle      = .warning
                alert.addButton(withTitle: "OK")
                if let w = self.window { alert.beginSheetModal(for: w) }
            }
        }
    }

    @objc private func importConfigTapped() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes     = [.json]
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let imported: Config
            do {
                imported = try self.configManager.decodeImport(from: url)
            } catch {
                let alert = NSAlert()
                alert.messageText     = "Import failed"
                alert.informativeText = "The file is not a valid latch config: \(error.localizedDescription)"
                alert.alertStyle      = .warning
                alert.addButton(withTitle: "OK")
                if let w = self.window { alert.beginSheetModal(for: w) }
                return
            }
            let confirm = NSAlert()
            confirm.messageText     = "Replace all settings?"
            confirm.informativeText = "This will overwrite your current settings and all automations. Script paths may not work if this backup was made on a different machine."
            confirm.alertStyle      = .warning
            confirm.addButton(withTitle: "Replace")
            confirm.addButton(withTitle: "Cancel")
            confirm.buttons[0].hasDestructiveAction = true
            guard let w = self.window else { return }
            confirm.beginSheetModal(for: w) { [weak self] resp in
                guard let self, resp == .alertFirstButtonReturn else { return }
                self.configManager.applyImportedConfig(imported)
                // Rebuild sidebar to reflect new module list
                self.tableView.reloadData()
                self.selectRow(0)
            }
        }
    }

    @objc private func checkForUpdatesTapped() {
        onCheckForUpdates?()
    }

    @objc private func keyboardUSBNotifToggled(_ sender: NSButton) {
        configManager.setKeyboardUSBNotificationsEnabled(sender.state == .on)
    }

    @objc private func keyboardBTNotifToggled(_ sender: NSButton) {
        configManager.setKeyboardBluetoothNotificationsEnabled(sender.state == .on)
    }

    @objc private func latchConnectNotifToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              var mod = configManager.config.userModules.first(where: { $0.id == id }) else { return }
        mod.notifyOnConnect = sender.state == .on
        configManager.updateUserModule(mod)
    }

    @objc private func latchDisconnectNotifToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              var mod = configManager.config.userModules.first(where: { $0.id == id }) else { return }
        mod.notifyOnDisconnect = sender.state == .on
        configManager.updateUserModule(mod)
    }

    @objc private func bluetoothToggled(_ sender: NSButton) {
        configManager.setBluetoothEnabled(sender.state == .on)
        configManager.onChanged?()
    }

    @objc private func activeDetectionToggled(_ sender: NSButton) {
        configManager.setActiveDetectionEnabled(sender.state == .on)
        configManager.onChanged?()
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        LaunchAtLogin.setEnabled(sender.state == .on)
    }

    @objc private func moduleToggled(_ sender: NSButton) {
        let desc = ModuleRegistry.available[sender.tag]
        if sender.state == .on {
            moduleRegistry.activate(moduleId: desc.id)
        } else {
            moduleRegistry.deactivate(moduleId: desc.id)
        }
        // Rebuild sidebar — module tabs may appear or disappear
        tableView.reloadData()
        // If the currently-selected row no longer exists, fall back to General
        if selectedRow >= sidebarItems.count { selectRow(0) }
    }

    // MARK: - Keyboard panel (instant-apply)

    private func makeKeyboardPanel() -> NSView {
        let header = makeLabel("Keyboard Layout Switcher", bold: true)

        autoDetectCheckbox = NSButton(
            checkboxWithTitle: "Auto-detect from enabled input sources",
            target: self, action: #selector(autoDetectToggled)
        )

        let macLabel       = makeLabel("OSX layout:", bold: false)
        macLabel.alignment = .right
        macLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true

        macLayoutPopup        = NSPopUpButton()
        macLayoutPopup.target = self
        macLayoutPopup.action = #selector(layoutChanged)
        macLayoutPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let macRow          = NSStackView(views: [macLabel, macLayoutPopup])
        macRow.orientation  = .horizontal
        macRow.spacing      = 8

        let pcLabel            = makeLabel("External keyboard:", bold: false)
        pcLabel.alignment      = .right
        pcLabel.lineBreakMode  = .byWordWrapping
        pcLabel.maximumNumberOfLines = 2
        pcLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true

        pcLayoutPopup        = NSPopUpButton()
        pcLayoutPopup.target = self
        pcLayoutPopup.action = #selector(layoutChanged)
        pcLayoutPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let pcRow          = NSStackView(views: [pcLabel, pcLayoutPopup])
        pcRow.orientation  = .horizontal
        pcRow.alignment    = .top
        pcRow.spacing      = 8

        bluetoothCheckbox = NSButton(
            checkboxWithTitle: "Include Bluetooth keyboards",
            target: self, action: #selector(bluetoothToggled)
        )

        activeDetectionCheckbox = NSButton(
            checkboxWithTitle: "Switch layout based on active keyboard",
            target: self, action: #selector(activeDetectionToggled)
        )
        activeDetectionCheckbox.toolTip = "Switches layout when you start typing on a different keyboard, even if both are connected"

        let stack         = NSStackView(views: [header, autoDetectCheckbox, macRow, pcRow, bluetoothCheckbox, activeDetectionCheckbox])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Rows must fill the stack width so the popup buttons can expand
        NSLayoutConstraint.activate([
            macRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pcRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        // Minimum content width so fittingSize resolves correctly (greaterThanOrEqualTo
        // = floor only; large fonts still produce wider/taller results automatically).
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        // Wrapper provides 24pt padding on all sides
        let wrapper = NSView()
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor,          constant:  32),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor,   constant:  32),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -32),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor,     constant: -32),
        ])

        populateKeyboardPanel()
        return wrapper
    }

    private func populateKeyboardPanel() {
        guard autoDetectCheckbox != nil else { return }

        availableLayouts = fetchAvailableLayouts()
        let shortNames   = availableLayouts.map { shortName($0) }

        for popup in [macLayoutPopup!, pcLayoutPopup!] {
            popup.removeAllItems()
            popup.addItems(withTitles: shortNames)
        }

        let cfg    = configManager.config.keyboardSwitcher
        let isAuto = cfg.macLayout == nil && cfg.pcLayout == nil
        autoDetectCheckbox.state     = isAuto ? .on : .off
        bluetoothCheckbox.state       = cfg.includeBluetooth ? .on : .off
        activeDetectionCheckbox.state = cfg.activeDetection  ? .on : .off

        if !isAuto {
            if let mac = cfg.macLayout, let idx = availableLayouts.firstIndex(of: mac) { macLayoutPopup.selectItem(at: idx) }
            if let pc  = cfg.pcLayout,  let idx = availableLayouts.firstIndex(of: pc)  { pcLayoutPopup.selectItem(at: idx)  }
        } else if let detected = autoDetectLayouts() {
            if let idx = availableLayouts.firstIndex(of: detected.mac) { macLayoutPopup.selectItem(at: idx) }
            if let idx = availableLayouts.firstIndex(of: detected.pc)  { pcLayoutPopup.selectItem(at: idx)  }
        }

        setLayoutControlsEnabled(!isAuto)
    }

    @objc private func autoDetectToggled(_ sender: NSButton) {
        let isAuto = sender.state == .on
        setLayoutControlsEnabled(!isAuto)
        if isAuto {
            configManager.setKeyboardLayouts(mac: nil, pc: nil)
        } else {
            saveLayoutsFromPopups()
        }
        configManager.onChanged?()
    }

    @objc private func layoutChanged(_ sender: NSPopUpButton) {
        guard autoDetectCheckbox?.state == .off else { return }
        saveLayoutsFromPopups()
        configManager.onChanged?()
    }

    private func saveLayoutsFromPopups() {
        let selMac = macLayoutPopup.indexOfSelectedItem
        let selPc  = pcLayoutPopup.indexOfSelectedItem
        guard selMac >= 0, selPc >= 0,
              selMac < availableLayouts.count, selPc < availableLayouts.count else { return }
        configManager.setKeyboardLayouts(mac: availableLayouts[selMac], pc: availableLayouts[selPc])
    }

    private func setLayoutControlsEnabled(_ enabled: Bool) {
        macLayoutPopup?.isEnabled = enabled
        pcLayoutPopup?.isEnabled  = enabled
    }

    // MARK: - Notifications panel

    private func makeNotificationsPanel() -> NSView {
        let header = makeLabel("Notifications", bold: true)

        var views: [NSView] = [header]
        let active = moduleRegistry.active

        if active.contains(where: { $0.id == "keyboard-switcher" }) {
            let sectionLabel = makeLabel("Keyboard Layout Switcher", bold: false)
            sectionLabel.font      = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            sectionLabel.textColor = .secondaryLabelColor

            keyboardUSBNotifCheckbox = NSButton(
                checkboxWithTitle: "USB keyboard connected / disconnected",
                target: self, action: #selector(keyboardUSBNotifToggled)
            )
            keyboardUSBNotifCheckbox.state = configManager.config.keyboardSwitcher.notifyUSB ? .on : .off

            keyboardBTNotifCheckbox = NSButton(
                checkboxWithTitle: "Bluetooth keyboard connected / disconnected",
                target: self, action: #selector(keyboardBTNotifToggled)
            )
            keyboardBTNotifCheckbox.state = configManager.config.keyboardSwitcher.notifyBluetooth ? .on : .off

            let divider = NSBox(); divider.boxType = .separator
            views += [divider, sectionLabel, keyboardUSBNotifCheckbox, keyboardBTNotifCheckbox]
        }

        for mod in configManager.config.userModules {
            let sectionLabel = makeLabel(mod.name, bold: false)
            sectionLabel.font      = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            sectionLabel.textColor = .secondaryLabelColor

            let connectCheck = NSButton(
                checkboxWithTitle: "Notify when device connects",
                target: self, action: #selector(latchConnectNotifToggled(_:))
            )
            connectCheck.state      = mod.notifyOnConnect ? .on : .off
            connectCheck.identifier = NSUserInterfaceItemIdentifier(mod.id)

            let disconnectCheck = NSButton(
                checkboxWithTitle: "Notify when device disconnects",
                target: self, action: #selector(latchDisconnectNotifToggled(_:))
            )
            disconnectCheck.state      = mod.notifyOnDisconnect ? .on : .off
            disconnectCheck.identifier = NSUserInterfaceItemIdentifier(mod.id)

            let divider = NSBox(); divider.boxType = .separator
            views += [divider, sectionLabel, connectCheck, disconnectCheck]
        }

        let stack         = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        // Dividers span full width
        for v in views where (v as? NSBox)?.boxType == .separator {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let wrapper = NSView()
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor,          constant:  32),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor,   constant:  32),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -32),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor,     constant: -32),
        ])
        return wrapper
    }

    // MARK: - Latch panel (one per user-defined module)

    // Wizard controller kept alive for the window's lifetime
    private var wizardController: UserModuleWizardController?

    private func makeLatchPanel(id: String) -> NSView {
        guard let mod = configManager.config.userModules.first(where: { $0.id == id }) else {
            return NSView()
        }

        let nameLabel = NSTextField(labelWithString: mod.name)
        nameLabel.font = .boldSystemFont(ofSize: 15)

        let triggerLabel = NSTextField(labelWithString:
            "\(mod.trigger.eventType.rawValue.capitalized) — \(mod.trigger.deviceName)")
        triggerLabel.font      = .systemFont(ofSize: 12)
        triggerLabel.textColor = .secondaryLabelColor

        let divider     = NSBox()
        divider.boxType = .separator

        let toggle = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(latchToggled(_:)))
        toggle.state      = mod.enabled ? .on : .off
        toggle.identifier = NSUserInterfaceItemIdentifier(mod.id)

        let editButton = NSButton(title: "Edit Latch…", target: self, action: #selector(editLatchTapped(_:)))
        editButton.bezelStyle = .rounded
        editButton.identifier = NSUserInterfaceItemIdentifier(mod.id)

        let deleteButton = NSButton(title: "Delete Latch", target: self, action: #selector(deleteLatchTapped(_:)))
        deleteButton.bezelStyle        = .rounded
        deleteButton.contentTintColor  = .systemRed
        deleteButton.identifier        = NSUserInterfaceItemIdentifier(mod.id)

        let stack         = NSStackView(views: [nameLabel, triggerLabel, divider, toggle, editButton, deleteButton])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 16
        stack.edgeInsets  = NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)

        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    @objc private func addLatchTapped() {
        openWizard(editing: nil)
    }

    @objc private func editLatchTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let mod = configManager.config.userModules.first(where: { $0.id == id }) else { return }
        openWizard(editing: mod)
    }

    @objc private func latchToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        configManager.setUserModuleEnabled(id: id, enabled: sender.state == .on)
        moduleRegistry.reloadFromConfig()
    }

    @objc private func deleteLatchTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let mod = configManager.config.userModules.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText     = "Delete latch \"\(mod.name)\"?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard let w = window else { return }
        alert.beginSheetModal(for: w) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.configManager.deleteUserModule(id: id)
            self.moduleRegistry.reloadFromConfig()
            self.tableView.reloadData()
            self.selectRow(0)
        }
    }

    private func openWizard(editing: UserModuleConfig?) {
        // Close any existing wizard window before replacing the controller
        wizardController?.window?.close()
        wizardController = UserModuleWizardController(configManager: configManager, editing: editing)

        wizardController?.onSave = { [weak self] module in
            guard let self else { return }
            if editing != nil {
                self.configManager.updateUserModule(module)
            } else {
                self.configManager.addUserModule(module)
            }
            self.moduleRegistry.reloadFromConfig()
            self.tableView.reloadData()
            // Navigate to the saved latch's sidebar item
            if let idx = self.sidebarItems.firstIndex(where: {
                if case .userModule(let sid, _) = $0 { return sid == module.id }
                return false
            }) {
                self.selectRow(idx)
            }
        }

        wizardController?.onDelete = { [weak self] id in
            guard let self else { return }
            self.configManager.deleteUserModule(id: id)
            self.moduleRegistry.reloadFromConfig()
            self.tableView.reloadData()
            self.selectRow(0)
        }

        wizardController?.show()
    }

    // MARK: - Layout helpers

    private func fetchAvailableLayouts() -> [String] {
        guard let listRef = TISCreateInputSourceList(nil, false) else { return [] }
        let sources = listRef.takeRetainedValue() as? [TISInputSource] ?? []
        return sources.compactMap { source -> String? in
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            return id.hasPrefix("com.apple.keylayout.") ? id : nil
        }.sorted()
    }

    private func autoDetectLayouts() -> (mac: String, pc: String)? {
        guard let pc = availableLayouts.first(where: { $0.hasSuffix("-PC") }) else { return nil }
        let base = pc.replacingOccurrences(of: "-PC", with: "")
        let mac  = availableLayouts.first(where: { $0 == base })
                ?? availableLayouts.first(where: { !$0.hasSuffix("-PC") })
        guard let mac else { return nil }
        return (mac: mac, pc: pc)
    }

    private func shortName(_ id: String) -> String {
        id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    }

    private func makeLabel(_ title: String, bold: Bool) -> NSTextField {
        let tf   = NSTextField(labelWithString: title)
        tf.font  = bold
            ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return tf
    }

    func windowWillClose(_ notification: Notification) {}
}

// MARK: - NSTableViewDataSource / Delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarTitles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let tf   = NSTextField(labelWithString: sidebarTitles[row])
        tf.font  = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row != selectedRow else { return }
        selectRow(row)
    }
}
