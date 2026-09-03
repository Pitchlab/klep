/// Het geschiedenisvenster (PL-757): terugzoeken wat je gedicteerd hebt, en het geheel
/// weggooien.
///
/// De knop in de voetrij stond uit zolang er niets bewaard werd. Nu er wél rijen in de
/// database landen, is dit de plek waar je erbij komt — zonder die ingang is opslaan
/// alleen een bestand dat groeit.
///
/// Twee dingen die de taak eist en die hier zitten: zoeken op woord, en alles wissen.
/// De lijst is een mensentest (een venster vraagt een runloop, ROE §2); de queries
/// erachter staan in `TranscriptStore` en zijn wél gedekt door de gate.
#if canImport(AppKit)
import AppKit

@MainActor
public final class HistoryWindowController: NSWindowController {
    private let store: TranscriptStore
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var rows: [TranscriptRecord] = []

    private static let contentWidth: CGFloat = 560
    private static let inset: CGFloat = 20

    public init(store: TranscriptStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Geschiedenis"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContentView()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is niet ondersteund") }

    public override func showWindow(_ sender: Any?) {
        reload()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
    }

    // MARK: Opbouw

    private func buildContentView() -> NSView {
        searchField.placeholderString = "Zoek in wat je gezegd hebt"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        // Doorlopend: de lijst filtert terwijl je typt, niet pas op Return.
        searchField.sendsSearchStringImmediately = true

        let wipe = NSButton(title: "Alles wissen", target: self, action: #selector(wipeTapped(_:)))
        wipe.bezelStyle = .rounded

        let top = NSStackView(views: [searchField, wipe])
        top.orientation = .horizontal
        top.spacing = 10
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureTable()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let column = NSStackView(views: [top, scroll, emptyLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(
            top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        column.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * Self.inset),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            top.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        return container
    }

    private func configureTable() {
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22

        for (identifier, title, width) in [
            ("moment", "Wanneer", CGFloat(140)),
            ("duur", "Duur", CGFloat(60)),
            ("route", "Route", CGFloat(110)),
            ("tekst", "Wat je zei", CGFloat(230)),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
    }

    // MARK: Vullen

    /// Leest opnieuw uit de database, met de huidige zoekterm. Een leesfout maakt de
    /// lijst leeg met een melding in plaats van te crashen — de geschiedenis is een
    /// naslagwerk, geen kritiek pad.
    private func reload() {
        do {
            rows = try store.search(searchField.stringValue)
            emptyLabel.stringValue = rows.isEmpty
                ? (searchField.stringValue.isEmpty
                    ? "Nog niets bewaard. Zet hands-free aan en zeg iets."
                    : "Niets gevonden voor '\(searchField.stringValue)'.")
                : "\(rows.count) \(rows.count == 1 ? "uiting" : "uitingen") · \(TranscriptStore.retentionDays) dagen bewaard"
        } catch {
            rows = []
            emptyLabel.stringValue = "Geschiedenis kon niet gelezen worden."
        }
        table.reloadData()
    }

    @objc private func searchChanged(_ sender: NSSearchField) { reload() }

    /// Alles wissen vraagt eerst, want dit is onomkeerbaar.
    @objc private func wipeTapped(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Hele geschiedenis wissen?"
        alert.informativeText =
            "Alle bewaarde transcripten worden verwijderd. Dit kan niet ongedaan gemaakt worden."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Wissen")
        alert.addButton(withTitle: "Annuleren")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.deleteAll()
        } catch {
            emptyLabel.stringValue = "Wissen mislukte."
        }
        reload()
    }
}

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < rows.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let record = rows[row]
        let text: String
        switch identifier {
        case "moment": text = Self.moment.string(from: record.recordedAt)
        case "duur": text = SpeechFormat.seconds(record.duration)
        case "route": text = record.mode
        default: text = record.text
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    /// Eén formatter voor de kolom, net als `SpeechFormat` voor de secondewaarden.
    private static let moment: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = "d MMM HH:mm:ss"
        return formatter
    }()
}
#endif
