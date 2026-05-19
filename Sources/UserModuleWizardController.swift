import AppKit
import IOKit
import IOKit.usb
import IOBluetooth

// MARK: - UserModuleWizardController

final class UserModuleWizardController: NSWindowController {

    /// Called with the finished config when the user saves. nil = cancelled / deleted.
    var onSave:   ((UserModuleConfig) -> Void)?
    var onDelete: ((String) -> Void)?  // passes module ID

    private let configManager: ConfigManager
    // nil = creating a new module; non-nil = editing an existing one
    private var editing: UserModuleConfig?

    init(configManager: ConfigManager, editing: UserModuleConfig? = nil) {
        self.configManager = configManager
        self.editing       = editing
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window == nil { buildWindow() }
        loadEditingValues()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        goToStep(0)
    }

    // MARK: - Step management

    private var stepViews: [NSView] = []
    private var currentStep = 0

    private var backButton:  NSButton!
    private var nextButton:  NSButton!
    private var stepLabel:   NSTextField!
    private var contentBox:  NSView!

    // Step 0 — Name
    private var nameField: NSTextField!

    // Step 1 — Event type
    private var usbRadio:       NSButton!
    private var bluetoothRadio: NSButton!
    private var thunderboltRadio: NSButton!

    // Step 2 — Device detection
    private var devicePickerLabel:  NSTextField!
    private var detectStatusLabel:  NSTextField!
    private var detectButton:       NSButton!
    private var anyDeviceCheckbox:  NSButton!
    private var tbNoteLabel:        NSTextField!

    // IOKit detect state (USB)
    private var wizardDetectPort:    IONotificationPortRef?
    private var wizardDetectIter:    io_iterator_t = IO_OBJECT_NULL
    private var wizardDetectCtx:     UnsafeMutableRawPointer?
    private var wizardDetectTimeout: DispatchWorkItem?
    // BT detect state
    private var wizardBTObserver:    IOBluetoothUserNotification?

    // Detected device result
    private var detectedVendorID:   Int?
    private var detectedProductID:  Int?
    private var detectedBTAddress:  String?
    private var detectedDeviceName: String?

    // Step 3 — On-connect action
    private var connectActionSegment: NSSegmentedControl!
    private var connectAppField:      NSTextField!
    private var connectAppBrowse:     NSButton!
    private var connectScriptField:   NSTextField!
    private var connectScriptBrowse:  NSButton!
    private var connectCommandField:  NSTextField!
    private var connectAppBundleID:   String?
    private var connectAppName:       String?

    // Step 4 — On-disconnect action
    private var disconnectActionSegment: NSSegmentedControl!
    private var disconnectAppField:      NSTextField!
    private var disconnectAppBrowse:     NSButton!
    private var disconnectScriptField:   NSTextField!
    private var disconnectScriptBrowse:  NSButton!
    private var disconnectCommandField:  NSTextField!
    private var disconnectAppBundleID:   String?
    private var disconnectAppName:       String?

    // Step 5 — Notifications
    private var notifyConnectCheck:    NSButton!
    private var notifyDisconnectCheck: NSButton!

    // Step 6 — Review
    private var reviewLabel: NSTextField!

    // MARK: - Build

    private func buildWindow() {
        let w = NSWindow(
            contentRect: .zero,
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        w.title = "New Latch"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let content = w.contentView!

        // Step label (e.g. "Step 1 of 7")
        stepLabel = NSTextField(labelWithString: "")
        stepLabel.font = .systemFont(ofSize: 11)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stepLabel)

        // Content area — swapped out per step
        contentBox = NSView()
        contentBox.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentBox)

        // Divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)

        // Navigation buttons
        backButton = NSButton(title: "Back", target: self, action: #selector(backTapped))
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(backButton)

        nextButton = NSButton(title: "Next", target: self, action: #selector(nextTapped))
        nextButton.bezelStyle    = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(nextButton)

        // Delete button — only visible when editing
        if editing != nil {
            let deleteButton = NSButton(title: "Delete Module", target: self, action: #selector(deleteTapped))
            deleteButton.bezelStyle = .rounded
            deleteButton.contentTintColor = .systemRed
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(deleteButton)

            NSLayoutConstraint.activate([
                deleteButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
                deleteButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            ])
        }

        NSLayoutConstraint.activate([
            stepLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stepLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            contentBox.topAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 8),
            contentBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            contentBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            contentBox.heightAnchor.constraint(equalToConstant: 260),

            divider.topAnchor.constraint(equalTo: contentBox.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            nextButton.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            nextButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            nextButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            backButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            backButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),

            content.widthAnchor.constraint(equalToConstant: 460),
        ])

        stepViews = [
            buildStepName(),
            buildStepEventType(),
            buildStepDevice(),
            buildStepAction(isConnect: true),
            buildStepAction(isConnect: false),
            buildStepNotifications(),
            buildStepReview(),
        ]

        self.window = w
    }

    // MARK: - Step builders

    private func buildStepName() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let title = stepTitle("Name your latch")
        v.addSubview(title)

        let sub = stepSubtitle("Give this latch a short, descriptive name.")
        v.addSubview(sub)

        nameField = NSTextField()
        nameField.placeholderString = "e.g. Studio Monitor"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(nameField)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            nameField.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 16),
            nameField.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        return v
    }

    private func buildStepEventType() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let title = stepTitle("Choose hardware event type")
        v.addSubview(title)

        let sub = stepSubtitle("What kind of device triggers this automation?")
        v.addSubview(sub)

        usbRadio         = radioButton("USB device",         tag: 0, action: #selector(eventTypeChanged(_:)))
        bluetoothRadio   = radioButton("Bluetooth device",   tag: 1, action: #selector(eventTypeChanged(_:)))
        thunderboltRadio = radioButton("Thunderbolt device", tag: 2, action: #selector(eventTypeChanged(_:)))
        usbRadio.state   = .on

        [usbRadio, bluetoothRadio, thunderboltRadio].forEach { v.addSubview($0!) }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            usbRadio.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 16),
            usbRadio.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            bluetoothRadio.topAnchor.constraint(equalTo: usbRadio.bottomAnchor, constant: 8),
            bluetoothRadio.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            thunderboltRadio.topAnchor.constraint(equalTo: bluetoothRadio.bottomAnchor, constant: 8),
            thunderboltRadio.leadingAnchor.constraint(equalTo: v.leadingAnchor),
        ])
        return v
    }

    private func buildStepDevice() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let title = stepTitle("Select device")
        v.addSubview(title)

        devicePickerLabel = stepSubtitle("")
        v.addSubview(devicePickerLabel)

        detectStatusLabel = NSTextField(labelWithString: "No device detected yet.")
        detectStatusLabel.font = .systemFont(ofSize: 13)
        detectStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(detectStatusLabel)

        detectButton = NSButton(title: "Detect Device…", target: self, action: #selector(detectTapped))
        detectButton.bezelStyle = .rounded
        detectButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(detectButton)

        anyDeviceCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(anyDeviceToggled(_:)))
        anyDeviceCheckbox.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(anyDeviceCheckbox)

        // Thunderbolt note — shown instead of detect UI for TB triggers
        tbNoteLabel = NSTextField(wrappingLabelWithString:
            "Thunderbolt triggers fire whenever any Thunderbolt device connects or disconnects. " +
            "Specific device matching is not supported in this release.")
        tbNoteLabel.font      = .systemFont(ofSize: 13)
        tbNoteLabel.textColor = .secondaryLabelColor
        tbNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        tbNoteLabel.isHidden  = true
        v.addSubview(tbNoteLabel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            devicePickerLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            devicePickerLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            detectStatusLabel.topAnchor.constraint(equalTo: devicePickerLabel.bottomAnchor, constant: 20),
            detectStatusLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            detectStatusLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            detectButton.topAnchor.constraint(equalTo: detectStatusLabel.bottomAnchor, constant: 12),
            detectButton.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            anyDeviceCheckbox.topAnchor.constraint(equalTo: detectButton.bottomAnchor, constant: 16),
            anyDeviceCheckbox.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            tbNoteLabel.topAnchor.constraint(equalTo: devicePickerLabel.bottomAnchor, constant: 12),
            tbNoteLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            tbNoteLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        return v
    }

    private func buildStepAction(isConnect: Bool) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let event = isConnect ? "connects" : "disconnects"
        let title = stepTitle("Action when device \(event)")
        v.addSubview(title)

        let sub = stepSubtitle("What should latch do when the device \(event)?")
        v.addSubview(sub)

        // Segment: None | Launch App | Quit App | Run Script | Run Command
        let seg = NSSegmentedControl(
            labels: ["None", "Launch App", "Quit App", "Run Script", "Run Command"],
            trackingMode: .selectOne,
            target: self,
            action: isConnect ? #selector(connectActionChanged) : #selector(disconnectActionChanged)
        )
        seg.selectedSegment = 0
        seg.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(seg)
        if isConnect { connectActionSegment = seg } else { disconnectActionSegment = seg }

        // App row
        let appField = NSTextField()
        appField.isEditable   = false
        appField.isSelectable = false
        appField.placeholderString = "Choose an app…"
        appField.translatesAutoresizingMaskIntoConstraints = false
        appField.isHidden = true
        v.addSubview(appField)

        let appBrowse = NSButton(title: "Browse…", target: self,
                                 action: isConnect ? #selector(browseConnectApp) : #selector(browseDisconnectApp))
        appBrowse.bezelStyle = .rounded
        appBrowse.translatesAutoresizingMaskIntoConstraints = false
        appBrowse.isHidden = true
        v.addSubview(appBrowse)

        // Script row
        let scriptField = NSTextField()
        scriptField.isEditable   = false
        scriptField.isSelectable = true
        scriptField.placeholderString = "Choose a script…"
        scriptField.translatesAutoresizingMaskIntoConstraints = false
        scriptField.isHidden = true
        v.addSubview(scriptField)

        let scriptBrowse = NSButton(title: "Browse…", target: self,
                                    action: isConnect ? #selector(browseConnectScript) : #selector(browseDisconnectScript))
        scriptBrowse.bezelStyle = .rounded
        scriptBrowse.translatesAutoresizingMaskIntoConstraints = false
        scriptBrowse.isHidden = true
        v.addSubview(scriptBrowse)

        // Command row (inline editable text field)
        let commandField = NSTextField()
        commandField.isEditable        = true
        commandField.isSelectable      = true
        commandField.placeholderString = "e.g. open -a Safari"
        commandField.translatesAutoresizingMaskIntoConstraints = false
        commandField.isHidden = true
        v.addSubview(commandField)

        if isConnect {
            connectAppField = appField; connectAppBrowse = appBrowse
            connectScriptField = scriptField; connectScriptBrowse = scriptBrowse
            connectCommandField = commandField
        } else {
            disconnectAppField = appField; disconnectAppBrowse = appBrowse
            disconnectScriptField = scriptField; disconnectScriptBrowse = scriptBrowse
            disconnectCommandField = commandField
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            seg.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 16),
            seg.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            appField.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 14),
            appField.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            appField.trailingAnchor.constraint(equalTo: appBrowse.leadingAnchor, constant: -8),

            appBrowse.centerYAnchor.constraint(equalTo: appField.centerYAnchor),
            appBrowse.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            appBrowse.widthAnchor.constraint(equalToConstant: 80),

            scriptField.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 14),
            scriptField.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scriptField.trailingAnchor.constraint(equalTo: scriptBrowse.leadingAnchor, constant: -8),

            scriptBrowse.centerYAnchor.constraint(equalTo: scriptField.centerYAnchor),
            scriptBrowse.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scriptBrowse.widthAnchor.constraint(equalToConstant: 80),

            commandField.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 14),
            commandField.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            commandField.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        return v
    }

    private func buildStepNotifications() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let title = stepTitle("Notifications")
        v.addSubview(title)

        let sub = stepSubtitle("Choose when latch should send a notification.")
        v.addSubview(sub)

        notifyConnectCheck    = NSButton(checkboxWithTitle: "Notify when device connects",
                                         target: nil, action: nil)
        notifyDisconnectCheck = NSButton(checkboxWithTitle: "Notify when device disconnects",
                                          target: nil, action: nil)
        notifyConnectCheck.state    = .on
        notifyDisconnectCheck.state = .on
        notifyConnectCheck.translatesAutoresizingMaskIntoConstraints    = false
        notifyDisconnectCheck.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(notifyConnectCheck)
        v.addSubview(notifyDisconnectCheck)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            notifyConnectCheck.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 16),
            notifyConnectCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor),

            notifyDisconnectCheck.topAnchor.constraint(equalTo: notifyConnectCheck.bottomAnchor, constant: 10),
            notifyDisconnectCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor),
        ])
        return v
    }

    private func buildStepReview() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false

        let title = stepTitle("Review")
        v.addSubview(title)

        reviewLabel = NSTextField(wrappingLabelWithString: "")
        reviewLabel.font = .systemFont(ofSize: 13)
        reviewLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(reviewLabel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            reviewLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            reviewLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            reviewLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        return v
    }

    // MARK: - Step navigation

    private func goToStep(_ step: Int) {
        // Stop device detection if navigating away from step 2
        if currentStep == 2 && step != 2 { stopWizardDetection() }
        currentStep = step

        // Swap content
        contentBox.subviews.forEach { $0.removeFromSuperview() }
        let view = stepViews[step]
        contentBox.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentBox.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
        ])

        stepLabel.stringValue = "Step \(step + 1) of \(stepViews.count)"
        backButton.isHidden   = (step == 0)

        let isLast = step == stepViews.count - 1
        nextButton.title        = isLast ? "Save" : "Next"
        nextButton.keyEquivalent = "\r"

        // Step-specific prep
        if step == 2 { prepareDeviceStep() }
        if step == stepViews.count - 1 { updateReview() }

        window?.title = editing != nil ? "Edit Latch" : "New Latch"
    }

    @objc private func backTapped() {
        guard currentStep > 0 else { return }
        goToStep(currentStep - 1)
    }

    @objc private func nextTapped() {
        guard validate(step: currentStep) else { return }
        if currentStep == stepViews.count - 1 {
            save()
        } else {
            goToStep(currentStep + 1)
        }
    }

    // MARK: - Device step prep

    private func prepareDeviceStep() {
        let eventType = selectedEventType()
        stopWizardDetection()

        switch eventType {
        case .thunderbolt:
            tbNoteLabel.isHidden       = false
            detectButton.isHidden      = true
            anyDeviceCheckbox.isHidden = true
            detectStatusLabel.isHidden = true
            devicePickerLabel.stringValue = "Thunderbolt trigger"
            return

        case .usb:
            tbNoteLabel.isHidden       = true
            detectButton.isHidden      = false
            anyDeviceCheckbox.isHidden = false
            detectStatusLabel.isHidden = false
            devicePickerLabel.stringValue = "Plug in the USB device you want to trigger this latch."
            anyDeviceCheckbox.title = "Match any USB device"

        case .bluetooth:
            tbNoteLabel.isHidden       = true
            detectButton.isHidden      = false
            anyDeviceCheckbox.isHidden = false
            detectStatusLabel.isHidden = false
            devicePickerLabel.stringValue = "Connect the Bluetooth device you want to trigger this latch."
            anyDeviceCheckbox.title = "Match any Bluetooth device"
        }

        // Pre-populate from edit config, or reset for new module
        if let mod = editing, mod.trigger.eventType == eventType {
            let hasSpecific = (eventType == .usb && mod.trigger.deviceVendorID != nil)
                           || (eventType == .bluetooth && mod.trigger.bluetoothAddress != nil)
            if hasSpecific {
                detectedVendorID   = mod.trigger.deviceVendorID
                detectedProductID  = mod.trigger.deviceProductID
                detectedBTAddress  = mod.trigger.bluetoothAddress
                detectedDeviceName = mod.trigger.deviceName
                detectStatusLabel.stringValue = "✓ \(mod.trigger.deviceName)"
                anyDeviceCheckbox.state = .off
                detectButton.isEnabled  = true
            } else {
                // "any device" was configured
                anyDeviceCheckbox.state = .on
                detectButton.isEnabled  = false
                detectStatusLabel.stringValue = "Any \(eventType.rawValue.capitalized) device"
            }
        } else {
            detectedVendorID = nil; detectedProductID = nil
            detectedBTAddress = nil; detectedDeviceName = nil
            anyDeviceCheckbox.state = .off
            detectButton.isEnabled  = true
            detectStatusLabel.stringValue = "No device detected yet."
        }
    }

    // MARK: - Action segment callbacks

    @objc private func connectActionChanged() {
        updateActionVisibility(segment: connectActionSegment,
                                appField: connectAppField, appBrowse: connectAppBrowse,
                                scriptField: connectScriptField, scriptBrowse: connectScriptBrowse,
                                commandField: connectCommandField)
    }

    @objc private func disconnectActionChanged() {
        updateActionVisibility(segment: disconnectActionSegment,
                                appField: disconnectAppField, appBrowse: disconnectAppBrowse,
                                scriptField: disconnectScriptField, scriptBrowse: disconnectScriptBrowse,
                                commandField: disconnectCommandField)
    }

    private func updateActionVisibility(segment: NSSegmentedControl,
                                         appField: NSTextField, appBrowse: NSButton,
                                         scriptField: NSTextField, scriptBrowse: NSButton,
                                         commandField: NSTextField) {
        let sel = segment.selectedSegment
        // 0=None, 1=Launch App, 2=Quit App, 3=Run Script, 4=Run Command
        let showApp     = sel == 1 || sel == 2
        let showScript  = sel == 3
        let showCommand = sel == 4
        appField.isHidden     = !showApp
        appBrowse.isHidden    = !showApp
        scriptField.isHidden  = !showScript
        scriptBrowse.isHidden = !showScript
        commandField.isHidden = !showCommand
    }

    // MARK: - App / Script browse

    @objc private func browseConnectApp()      { browseApp(isConnect: true) }
    @objc private func browseDisconnectApp()   { browseApp(isConnect: false) }
    @objc private func browseConnectScript()   { browseScript(isConnect: true) }
    @objc private func browseDisconnectScript() { browseScript(isConnect: false) }

    private func browseApp(isConnect: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles       = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes  = [.applicationBundle]
        panel.directoryURL         = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let name     = url.deletingPathExtension().lastPathComponent
            let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
            if isConnect {
                self.connectAppBundleID  = bundleID
                self.connectAppName      = name
                self.connectAppField.stringValue = name
            } else {
                self.disconnectAppBundleID  = bundleID
                self.disconnectAppName      = name
                self.disconnectAppField.stringValue = name
            }
        }
    }

    private func browseScript(isConnect: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles       = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if isConnect {
                self.connectScriptField.stringValue = url.path
            } else {
                self.disconnectScriptField.stringValue = url.path
            }
        }
    }

    // MARK: - Validation

    private func validate(step: Int) -> Bool {
        switch step {
        case 0:
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                showError("Please enter a name for this latch.")
                return false
            }
            // Unique name check (allow same name when editing the same module)
            let existing = configManager.config.userModules
                .filter { $0.id != editing?.id }
                .map    { $0.name }
            if existing.contains(name) {
                showError("A latch named \"\(name)\" already exists. Choose a different name.")
                return false
            }
            return true

        case 2:
            let eventType = selectedEventType()
            if eventType == .thunderbolt { return true }
            if anyDeviceCheckbox.state == .on { return true }
            guard detectedDeviceName != nil else {
                showError("Please detect a specific device, or check \"Match any\" to continue.")
                return false
            }
            return true

        case 3, 4:
            let isConnect = (step == 3)
            let segment   = isConnect ? connectActionSegment! : disconnectActionSegment!
            let sel       = segment.selectedSegment
            if sel == 1 || sel == 2 {
                let bundleID = isConnect ? connectAppBundleID : disconnectAppBundleID
                guard let bid = bundleID, !bid.isEmpty else {
                    showError("Please select an app.")
                    return false
                }
            } else if sel == 3 {
                let path = isConnect
                    ? connectScriptField.stringValue
                    : disconnectScriptField.stringValue
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
                    showError("Script not found at the specified path.")
                    return false
                }
                guard access(path, X_OK) == 0 else {
                    showError("Script is not executable. Run: chmod +x \"\(path)\"")
                    return false
                }
            } else if sel == 4 {
                let cmd = isConnect
                    ? connectCommandField.stringValue
                    : disconnectCommandField.stringValue
                guard !cmd.trimmingCharacters(in: .whitespaces).isEmpty else {
                    showError("Please enter a command to run.")
                    return false
                }
            }
            return true

        default:
            return true
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText     = "Cannot continue"
        alert.informativeText = message
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "OK")
        if let w = window { alert.beginSheetModal(for: w) }
    }

    // MARK: - Review text

    private func updateReview() {
        let eventType = selectedEventType()
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)

        let lines: [String] = [
            "Name:        \(name)",
            "Trigger:     \(eventType.rawValue.capitalized) — \(deviceDisplayName())",
            "On connect:  \(actionSummary(isConnect: true))",
            "On disconn:  \(actionSummary(isConnect: false))",
            "Notify:      \(notificationSummary())",
        ]
        reviewLabel.stringValue = lines.joined(separator: "\n")
    }

    private func deviceDisplayName() -> String {
        let eventType = selectedEventType()
        if eventType == .thunderbolt { return "Any Thunderbolt device" }
        if anyDeviceCheckbox.state == .on { return "Any \(eventType.rawValue.capitalized) device" }
        return detectedDeviceName ?? "Any \(eventType.rawValue.capitalized) device"
    }

    private func actionSummary(isConnect: Bool) -> String {
        let seg = isConnect ? connectActionSegment! : disconnectActionSegment!
        switch seg.selectedSegment {
        case 0: return "None"
        case 1:
            let name = isConnect ? connectAppName : disconnectAppName
            return "Launch \(name ?? "app")"
        case 2:
            let name = isConnect ? connectAppName : disconnectAppName
            return "Quit \(name ?? "app")"
        case 3:
            let path = isConnect ? connectScriptField.stringValue : disconnectScriptField.stringValue
            return "Run \(URL(fileURLWithPath: path).lastPathComponent)"
        case 4:
            let cmd = isConnect ? connectCommandField.stringValue : disconnectCommandField.stringValue
            let preview = String(cmd.prefix(30))
            return "Command: \(preview)\(cmd.count > 30 ? "…" : "")"
        default: return "None"
        }
    }

    private func notificationSummary() -> String {
        let c = notifyConnectCheck.state == .on
        let d = notifyDisconnectCheck.state == .on
        if c && d  { return "Connect + Disconnect" }
        if c       { return "Connect only" }
        if d       { return "Disconnect only" }
        return "Off"
    }

    // MARK: - Save

    private func save() {
        let id = editing?.id ?? UUID().uuidString
        let eventType = selectedEventType()

        let trigger = buildTrigger(eventType: eventType)
        let onConnect    = buildAction(isConnect: true)
        let onDisconnect = buildAction(isConnect: false)

        let module = UserModuleConfig(
            id:                 id,
            name:               nameField.stringValue.trimmingCharacters(in: .whitespaces),
            enabled:            editing?.enabled ?? true,
            trigger:            trigger,
            onConnect:          onConnect,
            onDisconnect:       onDisconnect,
            notifyOnConnect:    notifyConnectCheck.state == .on,
            notifyOnDisconnect: notifyDisconnectCheck.state == .on
        )

        window?.close()
        onSave?(module)
    }

    private func buildTrigger(eventType: TriggerEventType) -> UserModuleTrigger {
        let anyDevice = (eventType != .thunderbolt) && (anyDeviceCheckbox.state == .on)
        let vid:    Int?    = anyDevice ? nil : detectedVendorID
        let pid:    Int?    = anyDevice ? nil : detectedProductID
        let btAddr: String? = anyDevice ? nil : detectedBTAddress
        let devName: String = anyDevice || eventType == .thunderbolt
            ? "Any \(eventType.rawValue.capitalized) device"
            : (detectedDeviceName ?? "Any \(eventType.rawValue.capitalized) device")

        return UserModuleTrigger(
            eventType:        eventType,
            deviceVendorID:   vid,
            deviceProductID:  pid,
            bluetoothAddress: btAddr,
            deviceName:       devName
        )
    }

    private func buildAction(isConnect: Bool) -> UserModuleAction {
        let seg = isConnect ? connectActionSegment! : disconnectActionSegment!
        switch seg.selectedSegment {
        case 1:
            return UserModuleAction(
                kind:        .launchApp,
                appBundleID: isConnect ? connectAppBundleID : disconnectAppBundleID,
                appName:     isConnect ? connectAppName     : disconnectAppName
            )
        case 2:
            return UserModuleAction(
                kind:        .quitApp,
                appBundleID: isConnect ? connectAppBundleID : disconnectAppBundleID,
                appName:     isConnect ? connectAppName     : disconnectAppName
            )
        case 3:
            return UserModuleAction(
                kind:       .runScript,
                scriptPath: isConnect ? connectScriptField.stringValue : disconnectScriptField.stringValue
            )
        case 4:
            return UserModuleAction(
                kind:    .runCommand,
                command: isConnect ? connectCommandField.stringValue : disconnectCommandField.stringValue
            )
        default:
            return .none
        }
    }

    // MARK: - Delete

    @objc private func deleteTapped() {
        guard let mod = editing else { return }
        let alert = NSAlert()
        alert.messageText     = "Delete latch \"\(mod.name)\"?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard let w = window else { return }
        alert.beginSheetModal(for: w) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.window?.close()
                self?.onDelete?(mod.id)
            }
        }
    }

    // MARK: - Load editing values

    private func loadEditingValues() {
        guard let mod = editing else { return }

        nameField?.stringValue = mod.name

        switch mod.trigger.eventType {
        case .usb:         usbRadio?.state         = .on
        case .bluetooth:   bluetoothRadio?.state   = .on
        case .thunderbolt: thunderboltRadio?.state  = .on
        }

        loadActionValues(mod.onConnect, isConnect: true)
        loadActionValues(mod.onDisconnect, isConnect: false)

        notifyConnectCheck?.state    = mod.notifyOnConnect    ? .on : .off
        notifyDisconnectCheck?.state = mod.notifyOnDisconnect ? .on : .off
    }

    private func loadActionValues(_ action: UserModuleAction, isConnect: Bool) {
        let seg: NSSegmentedControl? = isConnect ? connectActionSegment : disconnectActionSegment
        switch action.kind {
        case .none:       seg?.selectedSegment = 0
        case .launchApp:
            seg?.selectedSegment = 1
            if isConnect { connectAppBundleID = action.appBundleID; connectAppName = action.appName
                           connectAppField?.stringValue = action.appName ?? "" }
            else         { disconnectAppBundleID = action.appBundleID; disconnectAppName = action.appName
                           disconnectAppField?.stringValue = action.appName ?? "" }
        case .quitApp:
            seg?.selectedSegment = 2
            if isConnect { connectAppBundleID = action.appBundleID; connectAppName = action.appName
                           connectAppField?.stringValue = action.appName ?? "" }
            else         { disconnectAppBundleID = action.appBundleID; disconnectAppName = action.appName
                           disconnectAppField?.stringValue = action.appName ?? "" }
        case .runScript:
            seg?.selectedSegment = 3
            if isConnect { connectScriptField?.stringValue    = action.scriptPath ?? "" }
            else         { disconnectScriptField?.stringValue = action.scriptPath ?? "" }
        case .runCommand:
            seg?.selectedSegment = 4
            if isConnect { connectCommandField?.stringValue    = action.command ?? "" }
            else         { disconnectCommandField?.stringValue = action.command ?? "" }
        }
        if let s = seg { updateActionVisibility(
            segment: s,
            appField:      isConnect ? connectAppField     : disconnectAppField,
            appBrowse:     isConnect ? connectAppBrowse    : disconnectAppBrowse,
            scriptField:   isConnect ? connectScriptField  : disconnectScriptField,
            scriptBrowse:  isConnect ? connectScriptBrowse : disconnectScriptBrowse,
            commandField:  isConnect ? connectCommandField : disconnectCommandField
        )}
    }

    // MARK: - Helpers

    private func selectedEventType() -> TriggerEventType {
        if bluetoothRadio.state   == .on { return .bluetooth }
        if thunderboltRadio.state == .on { return .thunderbolt }
        return .usb
    }

    private func stepTitle(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .boldSystemFont(ofSize: 14)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func stepSubtitle(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 12)
        f.textColor = .secondaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    @objc private func eventTypeChanged(_ sender: NSButton) {
        // Enforce mutual exclusion — AppKit doesn't auto-group standalone radio buttons
        usbRadio.state         = (sender === usbRadio)         ? .on : .off
        bluetoothRadio.state   = (sender === bluetoothRadio)   ? .on : .off
        thunderboltRadio.state = (sender === thunderboltRadio) ? .on : .off
    }

    private func radioButton(_ title: String, tag: Int, action: Selector) -> NSButton {
        let b = NSButton(radioButtonWithTitle: title, target: self, action: action)
        b.tag = tag
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}

// MARK: - Device detection

extension UserModuleWizardController {

    @objc func detectTapped() {
        if wizardDetectPort != nil || wizardBTObserver != nil {
            stopWizardDetection()
            detectButton.title = "Detect Device…"
            detectStatusLabel.stringValue = "Detection cancelled."
            return
        }
        startWizardDetection()
    }

    @objc func anyDeviceToggled(_ sender: NSButton) {
        if sender.state == .on {
            stopWizardDetection()
            detectedVendorID = nil; detectedProductID = nil
            detectedBTAddress = nil; detectedDeviceName = nil
            detectButton.isEnabled = false
            let eventType = selectedEventType()
            detectStatusLabel.stringValue = "Any \(eventType.rawValue.capitalized) device"
        } else {
            detectButton.isEnabled = true
            detectStatusLabel.stringValue = "No device detected yet."
        }
    }

    private func startWizardDetection() {
        let eventType = selectedEventType()
        detectButton.title = "Cancel"
        detectStatusLabel.stringValue = eventType == .bluetooth
            ? "Connect your Bluetooth device now…"
            : "Plug in your USB device now…"

        switch eventType {
        case .usb:       startUSBDetection()
        case .bluetooth: startBTDetection()
        case .thunderbolt: return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            stopWizardDetection()
            detectButton.title = "Detect Device…"
            if detectedDeviceName == nil {
                detectStatusLabel.stringValue = "No device detected — try again."
            }
        }
        wizardDetectTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func startUSBDetection() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        wizardDetectPort = port

        let rawCtx = Unmanaged.passRetained(self).toOpaque()
        wizardDetectCtx = rawCtx

        let dict = IOServiceMatching(kIOUSBDeviceClassName)! as NSMutableDictionary
        IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, dict as CFMutableDictionary,
            { ctx, iter in
                var svc = IOIteratorNext(iter)
                var last: io_object_t = IO_OBJECT_NULL
                while svc != IO_OBJECT_NULL {
                    if last != IO_OBJECT_NULL { IOObjectRelease(last) }
                    last = svc
                    svc  = IOIteratorNext(iter)
                }
                guard last != IO_OBJECT_NULL, let ctx else { return }
                Unmanaged<UserModuleWizardController>.fromOpaque(ctx)
                    .takeUnretainedValue().usbDeviceDetected(last)
                IOObjectRelease(last)
            },
            rawCtx, &wizardDetectIter
        )

        // Drain already-connected devices so only new plug-ins fire the callback
        var svc = IOIteratorNext(wizardDetectIter)
        while svc != IO_OBJECT_NULL { IOObjectRelease(svc); svc = IOIteratorNext(wizardDetectIter) }
    }

    private func startBTDetection() {
        wizardBTObserver = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(btDeviceConnected(_:device:))
        )
    }

    @objc private func btDeviceConnected(_ notification: IOBluetoothUserNotification,
                                          device: IOBluetoothDevice) {
        let name = device.name ?? device.addressString ?? "Bluetooth device"
        let addr = device.addressString ?? ""
        deviceDetected(vendorID: nil, productID: nil, btAddress: addr, name: name)
    }

    private func usbDeviceDetected(_ service: io_object_t) {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict      = props?.takeRetainedValue() as? [String: Any],
              let vendorID  = (dict[kUSBVendorID]  as? NSNumber)?.intValue ?? dict[kUSBVendorID]  as? Int,
              let productID = (dict[kUSBProductID] as? NSNumber)?.intValue ?? dict[kUSBProductID] as? Int
        else {
            stopWizardDetection()
            detectButton.title = "Detect Device…"
            detectStatusLabel.stringValue = "Could not read device — try again."
            return
        }

        var name = dict[kUSBProductString] as? String ?? ""
        if name.isEmpty {
            var buf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &buf)
            name = String(cString: buf)
        }
        if name.isEmpty { name = "USB Device \(vendorID):\(productID)" }

        deviceDetected(vendorID: vendorID, productID: productID, btAddress: nil, name: name)
    }

    private func deviceDetected(vendorID: Int?, productID: Int?, btAddress: String?, name: String) {
        stopWizardDetection()
        detectedVendorID   = vendorID
        detectedProductID  = productID
        detectedBTAddress  = btAddress
        detectedDeviceName = name
        anyDeviceCheckbox.state = .off
        detectButton.title = "Detect Device…"
        detectStatusLabel.stringValue = "✓ \(name)"
    }

    func stopWizardDetection() {
        wizardDetectTimeout?.cancel(); wizardDetectTimeout = nil
        if let port = wizardDetectPort {
            IONotificationPortDestroy(port)
            wizardDetectPort = nil
        }
        if wizardDetectIter != IO_OBJECT_NULL {
            IOObjectRelease(wizardDetectIter)
            wizardDetectIter = IO_OBJECT_NULL
        }
        if let ctx = wizardDetectCtx {
            Unmanaged<UserModuleWizardController>.fromOpaque(ctx).release()
            wizardDetectCtx = nil
        }
        wizardBTObserver?.unregister()
        wizardBTObserver = nil
    }
}

// MARK: - NSWindowDelegate

extension UserModuleWizardController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        stopWizardDetection()
    }
}
