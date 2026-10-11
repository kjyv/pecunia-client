//
//  CryptoOverviewController.swift
//  Pecunia
//
//  Account page for crypto accounts: lists the holdings with their amount in coins and their EUR value.
//

import Cocoa

@objc class CryptoOverviewController: NSObject, PecuniaSectionItem, NSTableViewDataSource, NSTableViewDelegate {
    var mainView: NSView!;
    var selectedCategory: BankingCategory! {
        didSet {
            reload();
        }
    }

    // nil also for an account that was deleted while another page was shown.
    private var account: BankAccount? {
        guard let account = selectedCategory as? BankAccount, account.managedObjectContext != nil,
              !account.isDeleted, account.isCryptoAccount() else {
            return nil;
        }
        return account;
    }

    private var holdings: [CryptoHolding] = [];

    private let titleField = NSTextField(labelWithString: "");
    private let valueField = NSTextField(labelWithString: "");
    private let summaryField = NSTextField(wrappingLabelWithString: "");
    private let tableView = NSTableView();
    private var editButton: NSButton!;
    private var removeButton: NSButton!;
    private var refreshButton: NSButton!;

    private static let euroFormatter: NumberFormatter = {
        let formatter = NumberFormatter();
        formatter.numberStyle = .currency;
        formatter.currencyCode = "EUR";
        return formatter;
    }();

    private static let quantityFormatter: NumberFormatter = {
        let formatter = NumberFormatter();
        formatter.numberStyle = .decimal;
        formatter.minimumFractionDigits = 2;
        formatter.maximumFractionDigits = 8;
        return formatter;
    }();

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter();
        formatter.dateStyle = .short;
        formatter.timeStyle = .short;
        return formatter;
    }();

    override init() {
        super.init();
        buildView();
        NotificationCenter.default.addObserver(self, selector: #selector(pricesUpdated(_:)),
                                               name: CryptoService.pricesUpdatedNotification, object: nil);
    }

    deinit {
        NotificationCenter.default.removeObserver(self);
    }

    // MARK: - PecuniaSectionItem

    func activate() {
        reload();
    }

    func deactivate() {
    }

    func setTimeRangeFrom(_ from: ShortDate!, to: ShortDate!) {
    }

    func print() {
    }

    func terminate() {
    }

    // MARK: - View

    private func buildView() {
        let view = BackgroundView(frame: NSRect(x: 0, y: 0, width: 800, height: 600));
        view.autoresizingMask = [.width, .height];

        titleField.font = NSFont.boldSystemFont(ofSize: 18);
        titleField.lineBreakMode = .byTruncatingTail;
        valueField.font = NSFont.boldSystemFont(ofSize: 18);
        valueField.alignment = .right;
        summaryField.font = NSFont.systemFont(ofSize: 13);
        summaryField.textColor = NSColor.secondaryLabelColor;

        let columns: [(String, String, CGFloat)] = [
            ("coin", NSLocalizedString("AP2305", comment: "Währung"), 70),
            ("label", NSLocalizedString("AP2306", comment: "Bezeichnung"), 180),
            ("quantity", NSLocalizedString("AP2307", comment: "Menge"), 140),
            ("price", NSLocalizedString("AP2308", comment: "Kurs"), 110),
            ("value", NSLocalizedString("AP2309", comment: "Wert"), 110),
            ("priceDate", NSLocalizedString("AP2310", comment: "Kursdatum"), 130)
        ];
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier));
            column.title = title;
            column.width = width;
            column.headerCell.alignment = CryptoOverviewController.isTextColumn(identifier) ? .left : .right;
            tableView.addTableColumn(column);
        }
        tableView.dataSource = self;
        tableView.delegate = self;
        tableView.usesAlternatingRowBackgroundColors = true;
        tableView.allowsEmptySelection = true;
        tableView.allowsMultipleSelection = false;
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle;
        tableView.target = self;
        tableView.doubleAction = #selector(editHolding(_:));

        let scrollView = NSScrollView();
        scrollView.documentView = tableView;
        scrollView.hasVerticalScroller = true;
        scrollView.borderType = .bezelBorder;

        let addButton = NSButton(title: NSLocalizedString("AP2311", comment: "Hinzufügen…"), target: self, action: #selector(addHolding(_:)));
        editButton = NSButton(title: NSLocalizedString("AP2312", comment: "Bearbeiten…"), target: self, action: #selector(editHolding(_:)));
        removeButton = NSButton(title: NSLocalizedString("AP2313", comment: "Entfernen"), target: self, action: #selector(removeHolding(_:)));
        refreshButton = NSButton(title: NSLocalizedString("AP2314", comment: "Kurse aktualisieren"), target: self, action: #selector(refreshPrices(_:)));
        let buttons = NSStackView(views: [addButton, editButton, removeButton]);
        buttons.spacing = 8;

        for subview in [titleField, valueField, summaryField, scrollView, buttons, refreshButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false;
            view.addSubview(subview);
        }
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal);

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            valueField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            valueField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 20),
            valueField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            summaryField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 6),
            summaryField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            summaryField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: summaryField.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            refreshButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            refreshButton.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            refreshButton.leadingAnchor.constraint(greaterThanOrEqualTo: buttons.trailingAnchor, constant: 20)
        ]);

        mainView = view;
    }

    private func reload() {
        if let account = account {
            holdings = CryptoService.holdings(of: account);
            titleField.stringValue = account.name ?? "";
            valueField.stringValue = euro(account.balance);
        } else {
            holdings = [];
            titleField.stringValue = "";
            valueField.stringValue = "";
        }
        summaryField.stringValue = summary();
        tableView.reloadData();
        updateButtons();
    }

    // One line per coin, e.g. "0,0125 BTC zu 74.673,80 € (Stand 11.10.26, 21:30)".
    private func summary() -> String {
        if account == nil {
            return "";
        }
        if holdings.isEmpty {
            return NSLocalizedString("AP2324", comment: "Noch kein Bestand erfasst");
        }
        var lines: [String] = [];
        for coin in CryptoService.coins {
            let coinHoldings = holdings.filter { $0.symbol == coin.symbol };
            if coinHoldings.isEmpty {
                continue;
            }
            let total = coinHoldings.reduce(NSDecimalNumber.zero) { $0.adding($1.quantity) };
            let amount = quantity(total) + " " + coin.symbol;
            let latest = coinHoldings.filter { $0.price != nil }.max { ($0.priceDate ?? .distantPast) < ($1.priceDate ?? .distantPast) };
            if let price = latest?.price, let date = latest?.priceDate {
                lines.append(String(format: NSLocalizedString("AP2325", comment: "%@ zu %@ (Stand %@)"),
                                    amount, euro(price), CryptoOverviewController.dateFormatter.string(from: date)));
            } else {
                lines.append(String(format: NSLocalizedString("AP2326", comment: "%@ (noch kein Kurs)"), amount));
            }
        }
        return lines.joined(separator: "\n");
    }

    private func updateButtons() {
        let hasSelection = tableView.selectedRow >= 0;
        editButton.isEnabled = hasSelection;
        removeButton.isEnabled = hasSelection;
        refreshButton.isEnabled = !holdings.isEmpty;
    }

    private var selectedHolding: CryptoHolding? {
        let row = tableView.selectedRow;
        return row >= 0 && row < holdings.count ? holdings[row] : nil;
    }

    private func euro(_ value: NSDecimalNumber?) -> String {
        guard let value = value else {
            return "–";
        }
        return CryptoOverviewController.euroFormatter.string(from: value) ?? "";
    }

    private func quantity(_ value: NSDecimalNumber) -> String {
        return CryptoOverviewController.quantityFormatter.string(from: value) ?? "";
    }

    private class func isTextColumn(_ identifier: String) -> Bool {
        return identifier == "coin" || identifier == "label";
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        return holdings.count;
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, row < holdings.count else {
            return nil;
        }
        var field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField;
        if field == nil {
            field = NSTextField(labelWithString: "");
            field!.identifier = identifier;
            field!.lineBreakMode = .byTruncatingTail;
            field!.alignment = CryptoOverviewController.isTextColumn(identifier.rawValue) ? .left : .right;
        }

        let holding = holdings[row];
        switch identifier.rawValue {
        case "coin":
            field!.stringValue = holding.symbol;
        case "label":
            field!.stringValue = holding.label ?? "";
        case "quantity":
            field!.stringValue = quantity(holding.quantity);
        case "price":
            field!.stringValue = euro(holding.price);
        case "value":
            field!.stringValue = euro(holding.value);
        case "priceDate":
            field!.stringValue = holding.priceDate.map { CryptoOverviewController.dateFormatter.string(from: $0) } ?? "–";
        default:
            field!.stringValue = "";
        }
        return field;
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons();
    }

    // MARK: - Actions

    @objc func addHolding(_ sender: Any?) {
        guard let account = account, let input = runHoldingDialog(nil) else {
            return;
        }
        CryptoService.addHolding(to: account, symbol: input.symbol, quantity: input.quantity, label: input.label);
        _ = BankingController.controller().save();
        reload();
        CryptoService.refreshPrices(for: [account], completion: nil);
    }

    @objc func editHolding(_ sender: Any?) {
        guard let account = account, let holding = selectedHolding, let input = runHoldingDialog(holding) else {
            return;
        }
        holding.quantity = input.quantity;
        holding.label = input.label;
        CryptoService.revalue(account);
        _ = BankingController.controller().save();
        reload();
    }

    @objc func removeHolding(_ sender: Any?) {
        guard let holding = selectedHolding else {
            return;
        }
        let alert = NSAlert();
        alert.alertStyle = .warning;
        alert.messageText = NSLocalizedString("AP2322", comment: "Bestand entfernen?");
        alert.informativeText = String(format: NSLocalizedString("AP2323", comment: ""),
                                       quantity(holding.quantity) + " " + holding.symbol);
        alert.addButton(withTitle: NSLocalizedString("AP2313", comment: "Entfernen"));
        alert.addButton(withTitle: NSLocalizedString("AP2", comment: "Abbrechen"));
        if alert.runModal() != .alertFirstButtonReturn {
            return;
        }
        CryptoService.removeHolding(holding);
        _ = BankingController.controller().save();
        reload();
    }

    @objc func refreshPrices(_ sender: Any?) {
        guard let account = account else {
            return;
        }
        refreshButton.isEnabled = false;
        CryptoService.refreshPrices(for: [account]) { [weak self] _ in
            self?.updateButtons();
        };
    }

    @objc func pricesUpdated(_ notification: Notification) {
        reload();
    }

    // MARK: - Dialogs

    @objc class func runCreateAccountDialog() -> BankAccount? {
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22));
        nameField.stringValue = CryptoService.coins[0].name;

        let alert = NSAlert();
        alert.messageText = NSLocalizedString("AP2302", comment: "Neues Krypto-Konto");
        alert.informativeText = NSLocalizedString("AP2303", comment: "");
        alert.accessoryView = nameField;
        alert.addButton(withTitle: NSLocalizedString("AP1", comment: "Ok"));
        alert.addButton(withTitle: NSLocalizedString("AP2", comment: "Abbrechen"));
        alert.window.initialFirstResponder = nameField;
        if alert.runModal() != .alertFirstButtonReturn {
            return nil;
        }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces);
        return CryptoService.createAccount(name: name.isEmpty ? CryptoService.coins[0].name : name);
    }

    // The coin of an existing holding cannot be changed, since its price belongs to that coin.
    private func runHoldingDialog(_ holding: CryptoHolding?) -> (symbol: String, quantity: NSDecimalNumber, label: String?)? {
        let coinPopup = NSPopUpButton();
        for coin in CryptoService.coins {
            coinPopup.addItem(withTitle: "\(coin.name) (\(coin.symbol))");
            coinPopup.lastItem?.representedObject = coin.symbol;
        }
        if let holding = holding {
            if CryptoService.coin(holding.symbol) == nil {
                coinPopup.addItem(withTitle: holding.symbol);
                coinPopup.lastItem?.representedObject = holding.symbol;
            }
            coinPopup.selectItem(at: coinPopup.indexOfItem(withRepresentedObject: holding.symbol));
            coinPopup.isEnabled = false;
        }

        let quantityField = NSTextField(string: holding.map { quantity($0.quantity) } ?? "");
        quantityField.placeholderString = NSLocalizedString("AP2327", comment: "z. B. 0,0125");
        let labelField = NSTextField(string: holding?.label ?? "");
        labelField.placeholderString = NSLocalizedString("AP2328", comment: "z. B. Hardware-Wallet");

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: NSLocalizedString("AP2319", comment: "Währung:")), coinPopup],
            [NSTextField(labelWithString: NSLocalizedString("AP2317", comment: "Menge:")), quantityField],
            [NSTextField(labelWithString: NSLocalizedString("AP2318", comment: "Bezeichnung:")), labelField]
        ]);
        grid.rowSpacing = 8;
        grid.column(at: 0).xPlacement = .trailing;
        grid.rowAlignment = .firstBaseline;
        quantityField.widthAnchor.constraint(equalToConstant: 220).isActive = true;
        labelField.widthAnchor.constraint(equalToConstant: 220).isActive = true;
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize);

        let alert = NSAlert();
        alert.messageText = holding == nil ? NSLocalizedString("AP2315", comment: "Bestand hinzufügen")
                                           : NSLocalizedString("AP2316", comment: "Bestand bearbeiten");
        alert.accessoryView = grid;
        alert.addButton(withTitle: NSLocalizedString("AP1", comment: "Ok"));
        alert.addButton(withTitle: NSLocalizedString("AP2", comment: "Abbrechen"));
        alert.window.initialFirstResponder = quantityField;

        while alert.runModal() == .alertFirstButtonReturn {
            guard let symbol = coinPopup.selectedItem?.representedObject as? String else {
                return nil;
            }
            if let amount = CryptoOverviewController.parseQuantity(quantityField.stringValue) {
                let label = labelField.stringValue.trimmingCharacters(in: .whitespaces);
                return (symbol, amount, label.isEmpty ? nil : label);
            }
            let error = NSAlert();
            error.messageText = NSLocalizedString("AP2320", comment: "Ungültige Menge");
            error.informativeText = NSLocalizedString("AP2321", comment: "");
            error.runModal();
        }
        return nil;
    }

    // Accepts "0,0125" as well as "0.0125". Coin amounts have no thousands separators, and more than
    // 8 decimals (1 satoshi) are rejected.
    class func parseQuantity(_ text: String) -> NSDecimalNumber? {
        let input = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".");
        guard !input.isEmpty,
              input.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }),
              input.filter({ $0 == "." }).count <= 1 else {
            return nil;
        }
        if let separator = input.firstIndex(of: "."), input.distance(from: separator, to: input.endIndex) - 1 > 8 {
            return nil;
        }
        let value = NSDecimalNumber(string: input, locale: Locale(identifier: "en_US_POSIX"));
        if value.decimalValue.isNaN || value.compare(NSDecimalNumber.zero) != .orderedDescending {
            return nil;
        }
        return value;
    }
}

private class BackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill();
        dirtyRect.fill();
    }
}
