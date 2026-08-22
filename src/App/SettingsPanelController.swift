import AppKit

@MainActor
final class SettingsPanelController: NSObject {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("usageink.settings")
    static let preferenceIdentifiers = [
        "settings.displayStyle",
        "settings.modules.title",
        "settings.modules.plan",
        "settings.modules.quota",
        "settings.modules.today",
        "settings.modules.weekTokens",
        "settings.modules.cache",
        "settings.modules.tps",
        "settings.modules.updated",
        "settings.modules.status",
        "settings.quotaOrder",
        "settings.title",
        "settings.tpsWindowMinutes",
        "settings.dateFormat",
        "settings.redAccent",
        "settings.redThreshold",
        "settings.language",
        "settings.customCodexPath",
        "settings.save",
    ]
    static let disclosureIdentifier = "settings.disclosure"
    static let storageStatusIdentifier = "settings.storageStatus"
    static let validationErrorIdentifier = "settings.validationError"

    private let panel: NSPanel
    private let disclosureView: NSTextView
    private let disclosureScroll: NSScrollView
    private let storageStatusField: NSTextField
    private let validationErrorField: NSTextField
    private let displayStyleButton: NSPopUpButton
    private let quotaOrderButton: NSPopUpButton
    private let tpsWindowButton: NSPopUpButton
    private let dateFormatButton: NSPopUpButton
    private let redAccentButton: NSPopUpButton
    private let languageButton: NSPopUpButton
    private let titleField: NSTextField
    private let pathField: NSTextField
    private let thresholdField: NSTextField
    private let thresholdStepper: NSStepper
    private let saveButton: NSButton
    private var moduleBoxes: [String: NSButton] = [:]
    private var draft = DisplayPreferences.default
    private var isWritable = true
    private var isDraftDirty = false
    private var pendingSave: DisplayPreferences?
    var submit: ((RuntimeCommand) -> Void)?

    override init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.identifier = Self.windowIdentifier
        panel.isExcludedFromWindowsMenu = true

        disclosureView = NSTextView()
        disclosureView.isEditable = false
        disclosureView.isSelectable = true
        disclosureView.drawsBackground = false
        disclosureView.font = NSFont.systemFont(ofSize: 11)
        disclosureView.string = FirstRunDisclosure.bilingualText
        disclosureView.identifier = NSUserInterfaceItemIdentifier(Self.disclosureIdentifier)
        disclosureView.isVerticallyResizable = true
        disclosureView.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        disclosureView.textContainer?.widthTracksTextView = true
        disclosureView.frame = NSRect(x: 0, y: 0, width: 500, height: 160)
        disclosureScroll = NSScrollView()
        disclosureScroll.translatesAutoresizingMaskIntoConstraints = false
        disclosureScroll.hasVerticalScroller = true
        disclosureScroll.documentView = disclosureView
        disclosureScroll.identifier = NSUserInterfaceItemIdentifier(Self.disclosureIdentifier)
        disclosureScroll.heightAnchor.constraint(equalToConstant: 160).isActive = true

        storageStatusField = NSTextField(wrappingLabelWithString: "")
        storageStatusField.identifier = NSUserInterfaceItemIdentifier(Self.storageStatusIdentifier)
        storageStatusField.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        storageStatusField.isHidden = true

        validationErrorField = NSTextField(wrappingLabelWithString: "")
        validationErrorField.identifier = NSUserInterfaceItemIdentifier(Self.validationErrorIdentifier)
        validationErrorField.textColor = .systemRed
        validationErrorField.font = NSFont.systemFont(ofSize: 11)
        validationErrorField.isHidden = true

        displayStyleButton = Self.popUp(
            identifier: "settings.displayStyle",
            items: DisplayStyle.allCases.map(\.menuTitle)
        )
        quotaOrderButton = Self.popUp(
            identifier: "settings.quotaOrder",
            items: ["Quota first", "Activity first"]
        )
        tpsWindowButton = Self.popUp(
            identifier: "settings.tpsWindowMinutes",
            items: ["3", "15", "60"]
        )
        dateFormatButton = Self.popUp(
            identifier: "settings.dateFormat",
            items: ["Relative", "Absolute"]
        )
        redAccentButton = Self.popUp(
            identifier: "settings.redAccent",
            items: ["Off", "Threshold", "Always"]
        )
        languageButton = Self.popUp(
            identifier: "settings.language",
            items: ["System", "English", "简体中文"]
        )
        titleField = Self.field(identifier: "settings.title")
        pathField = Self.field(identifier: "settings.customCodexPath")
        thresholdField = Self.field(identifier: "settings.redThreshold")
        thresholdStepper = NSStepper()
        thresholdStepper.identifier = NSUserInterfaceItemIdentifier("settings.redThreshold")
        thresholdStepper.minValue = 50
        thresholdStepper.maxValue = 100
        thresholdStepper.increment = 5
        thresholdStepper.valueWraps = false
        saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.identifier = NSUserInterfaceItemIdentifier("settings.save")
        saveButton.bezelStyle = .rounded
        self.panel = panel

        super.init()

        displayStyleButton.target = self
        displayStyleButton.action = #selector(controlChanged)
        quotaOrderButton.target = self
        quotaOrderButton.action = #selector(controlChanged)
        tpsWindowButton.target = self
        tpsWindowButton.action = #selector(controlChanged)
        dateFormatButton.target = self
        dateFormatButton.action = #selector(controlChanged)
        redAccentButton.target = self
        redAccentButton.action = #selector(controlChanged)
        languageButton.target = self
        languageButton.action = #selector(controlChanged)
        titleField.target = self
        titleField.action = #selector(controlChanged)
        pathField.target = self
        pathField.action = #selector(controlChanged)
        thresholdField.target = self
        thresholdField.action = #selector(controlChanged)
        thresholdStepper.target = self
        thresholdStepper.action = #selector(stepperChanged)
        saveButton.target = self
        saveButton.action = #selector(save)

        let moduleStack = NSStackView()
        moduleStack.orientation = .vertical
        moduleStack.alignment = .leading
        moduleStack.spacing = 4
        for (key, title) in [
            ("title", "Title"),
            ("plan", "Plan"),
            ("quota", "Quota"),
            ("today", "Today"),
            ("weekTokens", "Week tokens"),
            ("cache", "Cache"),
            ("tps", "TPS"),
            ("updated", "Updated"),
            ("status", "Status"),
        ] {
            let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(controlChanged))
            box.identifier = NSUserInterfaceItemIdentifier("settings.modules.\(key)")
            moduleBoxes[key] = box
            moduleStack.addArrangedSubview(box)
        }

        let thresholdRow = NSStackView(views: [thresholdField, thresholdStepper])
        thresholdRow.orientation = .horizontal
        thresholdRow.spacing = 8

        let form = NSStackView()
        form.translatesAutoresizingMaskIntoConstraints = false
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.addArrangedSubview(storageStatusField)
        form.addArrangedSubview(disclosureScroll)
        form.addArrangedSubview(Self.labeled("Display style", displayStyleButton))
        form.addArrangedSubview(Self.labeled("Modules", moduleStack))
        form.addArrangedSubview(Self.labeled("Quota order", quotaOrderButton))
        form.addArrangedSubview(Self.labeled("Title", titleField))
        form.addArrangedSubview(Self.labeled("TPS lookback (minutes)", tpsWindowButton))
        form.addArrangedSubview(Self.labeled("Date format", dateFormatButton))
        form.addArrangedSubview(Self.labeled("Red accent", redAccentButton))
        form.addArrangedSubview(Self.labeled("Red threshold", thresholdRow))
        form.addArrangedSubview(Self.labeled("Language", languageButton))
        form.addArrangedSubview(Self.labeled("Custom Codex path", pathField))
        form.addArrangedSubview(validationErrorField)
        form.addArrangedSubview(saveButton)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.documentView = form
        panel.contentView = scroll
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: content.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                form.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 20),
                form.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -20),
                form.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 16),
                form.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor, constant: -40),
            ])
        }
        apply(draft: .default, writable: true, showDisclosure: true)
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var hostedPanel: NSPanel {
        panel
    }

    var panelCount: Int {
        NSApp.windows.filter { window in
            window.identifier == Self.windowIdentifier
        }.count
    }

    var isDisclosureVisible: Bool {
        !disclosureScroll.isHidden
    }

    var disclosureText: String {
        disclosureView.string
    }

    var storageStatusText: String {
        storageStatusField.stringValue
    }

    var isStorageStatusVisible: Bool {
        !storageStatusField.isHidden
    }

    var validationErrorText: String {
        validationErrorField.stringValue
    }

    var isValidationErrorVisible: Bool {
        !validationErrorField.isHidden
    }

    var currentDraftTitle: String {
        collectDraft()
        return draft.title
    }

    func view(withIdentifier identifier: String) -> NSView? {
        func search(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier {
                return view
            }
            for child in view.subviews {
                if let found = search(child) {
                    return found
                }
            }
            if let document = (view as? NSScrollView)?.documentView, let found = search(document) {
                return found
            }
            return nil
        }
        return panel.contentView.flatMap(search)
    }

    func apply(_ snapshot: RuntimeSnapshot) {
        isWritable = snapshot.isPersistenceWritable
        updateStorageStatus(snapshot.storageClassification)
        disclosureScroll.isHidden = !snapshot.showsFirstRunDisclosure
        setControlsEnabled(snapshot.isPersistenceWritable)

        if let pending = pendingSave,
           snapshot.storageClassification != .stateWriteFailed,
           snapshot.preferences.displayStyle == pending.displayStyle,
           snapshot.preferences.title == pending.title {
            pendingSave = nil
            isDraftDirty = false
            apply(draft: snapshot.preferences, writable: snapshot.isPersistenceWritable, showDisclosure: snapshot.showsFirstRunDisclosure)
            return
        }

        if isDraftDirty {
            if snapshot.storageClassification == .stateWriteFailed {
                return
            }
            draft.displayStyle = snapshot.preferences.displayStyle
            displayStyleButton.selectItem(at: DisplayStyle.allCases.firstIndex(of: draft.displayStyle) ?? 1)
            return
        }

        apply(
            draft: snapshot.preferences,
            writable: snapshot.isPersistenceWritable,
            showDisclosure: snapshot.showsFirstRunDisclosure
        )
    }

    func show() {
        NSApp.activate()
        if !panel.isVisible {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func apply(draft: DisplayPreferences, writable: Bool, showDisclosure: Bool) {
        self.draft = draft
        disclosureScroll.isHidden = !showDisclosure
        displayStyleButton.selectItem(at: DisplayStyle.allCases.firstIndex(of: draft.displayStyle) ?? 1)
        quotaOrderButton.selectItem(at: draft.quotaOrder == .quotaFirst ? 0 : 1)
        tpsWindowButton.selectItem(withTitle: String(draft.tpsWindowMinutes))
        dateFormatButton.selectItem(at: draft.dateFormat == .relative ? 0 : 1)
        redAccentButton.selectItem(at: ["off", "threshold", "always"].firstIndex(of: draft.redAccent.rawValue) ?? 1)
        languageButton.selectItem(
            at: [InterfaceLanguagePreference.system, .english, .simplifiedChinese].firstIndex(of: draft.language) ?? 0
        )
        titleField.stringValue = draft.title
        pathField.stringValue = draft.customCodexPath ?? ""
        thresholdField.stringValue = String(draft.redThreshold)
        thresholdStepper.integerValue = draft.redThreshold
        moduleBoxes["title"]?.state = draft.modules.title ? .on : .off
        moduleBoxes["plan"]?.state = draft.modules.plan ? .on : .off
        moduleBoxes["quota"]?.state = draft.modules.quota ? .on : .off
        moduleBoxes["today"]?.state = draft.modules.today ? .on : .off
        moduleBoxes["weekTokens"]?.state = draft.modules.weekTokens ? .on : .off
        moduleBoxes["cache"]?.state = draft.modules.cache ? .on : .off
        moduleBoxes["tps"]?.state = draft.modules.tps ? .on : .off
        moduleBoxes["updated"]?.state = draft.modules.updated ? .on : .off
        moduleBoxes["status"]?.state = draft.modules.status ? .on : .off
        setControlsEnabled(writable)
    }

    private func setControlsEnabled(_ writable: Bool) {
        let controls: [NSControl] = [
            displayStyleButton, quotaOrderButton, tpsWindowButton, dateFormatButton,
            redAccentButton, languageButton, titleField, pathField, thresholdField,
            thresholdStepper, saveButton,
        ] + Array(moduleBoxes.values)
        for control in controls {
            control.isEnabled = writable
        }
    }

    private func updateStorageStatus(_ classification: StorageClassification?) {
        if let classification, let text = StorageStatusCopy.bilingual(for: classification) {
            storageStatusField.stringValue = text
            storageStatusField.isHidden = false
        } else {
            storageStatusField.stringValue = ""
            storageStatusField.isHidden = true
        }
    }

    @objc private func controlChanged() {
        collectDraft()
        isDraftDirty = true
        validationErrorField.isHidden = true
    }

    @objc private func stepperChanged() {
        var value = thresholdStepper.integerValue
        let snapped = Int((Double(value) / 5.0).rounded()) * 5
        value = min(100, max(50, snapped))
        thresholdStepper.integerValue = value
        thresholdField.stringValue = String(value)
        collectDraft()
        isDraftDirty = true
    }

    @objc private func save() {
        collectDraft()
        guard isWritable else {
            return
        }
        do {
            let preferences = try draft.validated()
            validationErrorField.isHidden = true
            pendingSave = preferences
            submit?(.savePreferences(preferences))
        } catch {
            validationErrorField.stringValue = SettingsValidationCopy.bilingual
            validationErrorField.isHidden = false
        }
    }

    private func collectDraft() {
        let styles = DisplayStyle.allCases
        draft.displayStyle = styles[max(0, displayStyleButton.indexOfSelectedItem)]
        draft.quotaOrder = quotaOrderButton.indexOfSelectedItem == 1 ? .activityFirst : .quotaFirst
        let minutes = [3, 15, 60]
        let tpsIndex = max(0, tpsWindowButton.indexOfSelectedItem)
        draft.tpsWindowMinutes = minutes[min(tpsIndex, minutes.count - 1)]
        draft.dateFormat = dateFormatButton.indexOfSelectedItem == 1 ? .absolute : .relative
        let accents: [RedAccent] = [.off, .threshold, .always]
        draft.redAccent = accents[max(0, redAccentButton.indexOfSelectedItem)]
        let languages: [InterfaceLanguagePreference] = [.system, .english, .simplifiedChinese]
        draft.language = languages[max(0, languageButton.indexOfSelectedItem)]
        draft.title = titleField.stringValue
        let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.customCodexPath = path.isEmpty ? nil : path
        if let threshold = Int(thresholdField.stringValue) {
            draft.redThreshold = threshold
        }
        draft.modules.title = moduleBoxes["title"]?.state == .on
        draft.modules.plan = moduleBoxes["plan"]?.state == .on
        draft.modules.quota = moduleBoxes["quota"]?.state == .on
        draft.modules.today = moduleBoxes["today"]?.state == .on
        draft.modules.weekTokens = moduleBoxes["weekTokens"]?.state == .on
        draft.modules.cache = moduleBoxes["cache"]?.state == .on
        draft.modules.tps = moduleBoxes["tps"]?.state == .on
        draft.modules.updated = moduleBoxes["updated"]?.state == .on
        draft.modules.status = moduleBoxes["status"]?.state == .on
    }

    private static func popUp(identifier: String, items: [String]) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.addItems(withTitles: items)
        return button
    }

    private static func field(identifier: String) -> NSTextField {
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        return field
    }

    private static func labeled(_ title: String, _ view: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: 11)
        let stack = NSStackView(views: [label, view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }
}
