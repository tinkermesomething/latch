import AppKit
import Carbon.HIToolbox

final class WelcomeWindowController: NSWindowController {

    private let configManager:  ConfigManager
    private let moduleRegistry: ModuleRegistry

    var onCompleted: (() -> Void)?

    // MARK: - Step management

    private enum Step { case modules, keyboard }
    private var steps:     [Step] = [.modules]
    private var stepIndex: Int    = 0

    // MARK: - Shared UI

    private var contentContainer: NSView!
    private var backButton:        NSButton!
    private var nextButton:        NSButton!
    private var stepLabel:         NSTextField!

    // MARK: - Module step

    private var checkboxes: [NSButton] = []

    // MARK: - Keyboard step

    private var macPopup:         NSPopUpButton!
    private var pcPopup:          NSPopUpButton!
    private var availableLayouts: [String] = []

    // MARK: - Init

    init(configManager: ConfigManager, moduleRegistry: ModuleRegistry) {
        self.configManager  = configManager
        self.moduleRegistry = moduleRegistry
        super.init(window: nil)
        buildWindow()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Window scaffold

    private func buildWindow() {
        let w = NSWindow(
            contentRect: .zero,
            styleMask:   [.titled],
            backing:     .buffered,
            defer:       false
        )
        w.title                = "Welcome to latch"
        w.isReleasedWhenClosed = false

        let content = w.contentView!

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        let divider         = NSBox()
        divider.boxType     = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        stepLabel = makeLabel("", bold: false)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.translatesAutoresizingMaskIntoConstraints = false

        backButton = NSButton(title: "Back", target: self, action: #selector(backTapped))
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton = NSButton(title: "Next", target: self, action: #selector(nextTapped))
        nextButton.bezelStyle     = .rounded
        nextButton.keyEquivalent  = "\r"
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        for sub in ([contentContainer, divider, stepLabel, backButton, nextButton] as [NSView]) {
            content.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: content.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            divider.topAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            stepLabel.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            stepLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),

            backButton.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            backButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),
            backButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            nextButton.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            nextButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            nextButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])

        self.window = w
        showStep(0)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Step routing

    private func showStep(_ index: Int) {
        stepIndex = index
        let step  = steps[index]

        // Swap content
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let stepView: NSView
        switch step {
        case .modules:  stepView = makeModulesView()
        case .keyboard: stepView = makeKeyboardView()
        }
        stepView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(stepView)
        NSLayoutConstraint.activate([
            stepView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            stepView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            stepView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            stepView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])

        // Nav state
        backButton.isHidden = (index == 0)
        let isLast = (index == steps.count - 1)
        nextButton.title        = isLast ? "Get Started" : "Next"
        nextButton.keyEquivalent = "\r"

        // Step indicator — hidden on step 0 (module selection)
        if steps.count > 1 && index > 0 {
            stepLabel.stringValue = "Step \(index) of \(steps.count - 1)"
        } else {
            stepLabel.stringValue = ""
        }

        // Resize window to fit new content
        window?.contentView?.layoutSubtreeIfNeeded()
        if let size = window?.contentView?.fittingSize {
            window?.setContentSize(size)
        }
        window?.center()
    }

    // MARK: - Navigation

    @objc private func backTapped() {
        showStep(stepIndex - 1)
    }

    @objc private func nextTapped() {
        switch steps[stepIndex] {
        case .modules:
            commitModuleSelection()
            buildRemainingSteps()
            if steps.count > 1 {
                showStep(1)
            } else {
                complete()
            }
        case .keyboard:
            commitKeyboardLayouts()
            advance()
        }
    }

    private func advance() {
        if stepIndex < steps.count - 1 {
            showStep(stepIndex + 1)
        } else {
            complete()
        }
    }

    private func complete() {
        window?.close()
        onCompleted?()
    }

    // MARK: - Module selection

    private func commitModuleSelection() {
        let selected = checkboxes
            .filter { $0.state == .on }
            .map    { ModuleRegistry.available[$0.tag].id }
        configManager.setRegisteredModules(selected)
    }

    private func buildRemainingSteps() {
        let selected = checkboxes.filter { $0.state == .on }.map { ModuleRegistry.available[$0.tag].id }
        steps = [.modules]
        if selected.contains("keyboard-switcher") { steps.append(.keyboard) }
    }

    private func makeModulesView() -> NSView {
        let iconView          = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive  = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let titleLabel    = NSTextField(labelWithString: "Welcome!")
        titleLabel.font   = .boldSystemFont(ofSize: 18)
        titleLabel.alignment = .center

        let subtitleLabel      = NSTextField(wrappingLabelWithString:
            "Choose which automations to enable. You can change this any time in Settings."
        )
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        checkboxes.removeAll()
        var moduleRows: [NSView] = []
        for (idx, desc) in ModuleRegistry.available.enumerated() {
            let checkbox   = NSButton(checkboxWithTitle: desc.displayName, target: nil, action: nil)
            checkbox.state = .on
            checkbox.tag   = idx

            let descLabel       = NSTextField(wrappingLabelWithString: desc.description)
            descLabel.textColor = .secondaryLabelColor
            descLabel.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)

            let row         = NSStackView(views: [checkbox, descLabel])
            row.orientation = .vertical
            row.alignment   = .leading
            row.spacing     = 3
            moduleRows.append(row)
            checkboxes.append(checkbox)
        }

        let stack         = NSStackView(views: [iconView, titleLabel, subtitleLabel] + moduleRows)
        stack.orientation = .vertical
        stack.alignment   = .centerX
        stack.spacing     = 12
        stack.edgeInsets  = NSEdgeInsets(top: 32, left: 32, bottom: 28, right: 32)

        // Module rows left-aligned within centred stack
        for row in moduleRows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                       constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
        subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                             constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        return stack
    }

    // MARK: - Keyboard setup

    private func makeKeyboardView() -> NSView {
        let header = NSTextField(labelWithString: "Keyboard Layout")
        header.font = .boldSystemFont(ofSize: 15)

        let body = NSTextField(wrappingLabelWithString:
            "The app switches your input layout automatically based on which keyboard is active. " +
            "Confirm the detected layouts below, or choose manually."
        )
        body.textColor = .secondaryLabelColor
        body.font      = .systemFont(ofSize: NSFont.systemFontSize)

        let divider         = NSBox()
        divider.boxType     = .separator

        let macLabel        = makeLabel("Mac / built-in:", bold: false)
        macLabel.alignment  = .right
        macLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true

        macPopup        = NSPopUpButton()
        macPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let macRow          = NSStackView(views: [macLabel, macPopup])
        macRow.orientation  = .horizontal
        macRow.spacing      = 8

        let pcLabel         = makeLabel("External keyboard:", bold: false)
        pcLabel.alignment   = .right
        pcLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true

        pcPopup        = NSPopUpButton()
        pcPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let pcRow          = NSStackView(views: [pcLabel, pcPopup])
        pcRow.orientation  = .horizontal
        pcRow.spacing      = 8

        let permNote = NSTextField(wrappingLabelWithString:
            "After setup completes, macOS will prompt for Input Monitoring permission. " +
            "This is required for keyboard detection — grant it in System Settings > Privacy & Security."
        )
        permNote.textColor = .secondaryLabelColor
        permNote.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let stack         = NSStackView(views: [header, body, divider, macRow, pcRow, permNote])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 14
        stack.edgeInsets  = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true

        for v in ([divider, macRow, pcRow, body, permNote] as [NSView]) {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                     constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }

        populateKeyboardPopups()
        return stack
    }

    private func populateKeyboardPopups() {
        guard macPopup != nil else { return }
        availableLayouts = fetchLayouts()
        let short = availableLayouts.map { shortLayoutName($0) }
        for popup in [macPopup!, pcPopup!] {
            popup.removeAllItems()
            popup.addItems(withTitles: short)
        }

        let cfg = configManager.config.keyboardSwitcher
        // Use saved config if present, otherwise auto-detect
        if let mac = cfg.macLayout, let idx = availableLayouts.firstIndex(of: mac) {
            macPopup.selectItem(at: idx)
        }
        if let pc = cfg.pcLayout, let idx = availableLayouts.firstIndex(of: pc) {
            pcPopup.selectItem(at: idx)
        }
        if cfg.macLayout == nil || cfg.pcLayout == nil, let detected = autoDetectLayouts() {
            if let idx = availableLayouts.firstIndex(of: detected.mac) { macPopup.selectItem(at: idx) }
            if let idx = availableLayouts.firstIndex(of: detected.pc)  { pcPopup.selectItem(at: idx) }
        }
    }

    private func commitKeyboardLayouts() {
        let mi = macPopup.indexOfSelectedItem
        let pi = pcPopup.indexOfSelectedItem
        guard mi >= 0, pi >= 0,
              mi < availableLayouts.count, pi < availableLayouts.count else { return }
        configManager.setKeyboardLayouts(mac: availableLayouts[mi], pc: availableLayouts[pi])
    }

    private func fetchLayouts() -> [String] {
        guard let listRef = TISCreateInputSourceList(nil, false) else { return [] }
        let sources = listRef.takeRetainedValue() as? [TISInputSource] ?? []
        return sources.compactMap { src -> String? in
            guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
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

    private func shortLayoutName(_ id: String) -> String {
        id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    }

    // MARK: - Helpers

    private func makeLabel(_ s: String, bold: Bool) -> NSTextField {
        let tf  = NSTextField(labelWithString: s)
        tf.font = bold ? .boldSystemFont(ofSize: NSFont.systemFontSize)
                       : .systemFont(ofSize: NSFont.systemFontSize)
        return tf
    }
}
