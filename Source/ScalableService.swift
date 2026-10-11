//
//  ScalableService.swift
//  Pecunia
//
//  Scalable Capital accounts, read from the Scalable MCP server ("Agentic Investing"). The user enables
//  MCP access in the Scalable web app under Profile > Security > Agentic Investing. Pecunia registers
//  itself as an OAuth client and receives the login on a loopback port, because Scalable accepts no
//  custom URL schemes as redirect. The bank list shows the connection as a BankUser with
//  SecMethod_Scalable, which BankUser.allUsers leaves out of all HBCI work.
//

import AuthenticationServices
import Cocoa
import CryptoKit
import Network

private enum ScalableError: LocalizedError {
    case loginRequired
    case loginCancelled
    case callbackPortUnavailable
    case loginTimeout
    case server(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .loginRequired:
            return NSLocalizedString("AP2345", comment: "Anmeldung erforderlich");
        case .loginCancelled:
            return NSLocalizedString("AP2353", comment: "Anmeldung abgebrochen");
        case .callbackPortUnavailable:
            return String(format: NSLocalizedString("AP2349", comment: "Port belegt"), Int(ScalableService.callbackPort));
        case .loginTimeout:
            return NSLocalizedString("AP2350", comment: "Anmeldung nicht abgeschlossen");
        case .server(let message):
            return message;
        case .invalidResponse(let detail):
            return String(format: NSLocalizedString("AP2351", comment: "Unerwartete Antwort"), detail);
        }
    }
}

@MainActor
@objc class ScalableService: NSObject {
    @objc static let provider = "scalable";
    @objc static let bankCode = "SCALABLE";

    nonisolated static let callbackPort: UInt16 = 8765;
    nonisolated fileprivate static let resource = "https://mcp.scalable.capital/mcp";
    private static let issuer = "https://mcp.scalable.capital";
    private static let scope = "openid profile offline_access";
    private static let redirectURI = "http://127.0.0.1:\(callbackPort)/callback";
    private static let clientIdKey = "scalableClientId";
    private static let keychainService = "Pecunia Scalable";

    private static let centRounding = NSDecimalNumberHandler(roundingMode: .plain, scale: 2,
                                                             raiseOnExactness: false, raiseOnOverflow: true,
                                                             raiseOnUnderflow: true, raiseOnDivideByZero: true);

    private static var cachedAccessToken: String?;
    private static var accessTokenExpiry = Date.distantPast;
    private static var pendingLogin: Task<Void, Error>?;

    // Kind of a Scalable account, stored in BankAccount.providerAccountId as "<kind>:<Scalable id>".
    private enum Kind {
        case depot(portfolioId: String)
        case cash(portfolioId: String)
        case overnight(savingsAccountId: String)

        init?(_ providerAccountId: String?) {
            guard let parts = providerAccountId?.split(separator: ":", maxSplits: 1), parts.count == 2 else {
                return nil;
            }
            let id = String(parts[1]);
            switch parts[0] {
            case "depot": self = .depot(portfolioId: id);
            case "cash": self = .cash(portfolioId: id);
            case "overnight": self = .overnight(savingsAccountId: id);
            default: return nil;
            }
        }

        var providerAccountId: String {
            switch self {
            case .depot(let id): return "depot:" + id;
            case .cash(let id): return "cash:" + id;
            case .overnight(let id): return "overnight:" + id;
            }
        }
    }

    // MARK: - Accounts

    @objc class func isDepotAccount(_ account: BankAccount) -> Bool {
        if account.provider == provider, case .depot = Kind(account.providerAccountId) {
            return true;
        }
        return false;
    }

    @objc class func bankUser() -> BankUser? {
        guard let context = MOAssistant.shared().context else {
            return nil;
        }
        let request = NSFetchRequest<BankUser>(entityName: "BankUser");
        request.predicate = NSPredicate(format: "secMethod = %d", Int(SecMethod_Scalable.rawValue));
        return (try? context.fetch(request))?.first;
    }

    // Removes the login. The accounts stay, but are no longer refreshed.
    @objc class func disconnect() {
        if let clientId = UserDefaults.standard.string(forKey: clientIdKey) {
            Security.deletePasswordForService(keychainService, account: clientId);
        }
        UserDefaults.standard.removeObject(forKey: clientIdKey);
        cachedAccessToken = nil;
        accessTokenExpiry = Date.distantPast;
    }

    class func scalableAccounts() -> [BankAccount] {
        guard let context = MOAssistant.shared().context else {
            return [];
        }
        let request = NSFetchRequest<BankAccount>(entityName: "BankAccount");
        request.predicate = NSPredicate(format: "provider = %@ AND accountNumber != nil", provider);
        return (try? context.fetch(request)) ?? [];
    }

    // Logs in, creates the bank user and the accounts that do not exist yet and refreshes the accounts.
    // The completion runs before the refresh and gets true if something was created.
    @objc class func connect(completion: @escaping (Bool) -> Void) {
        Task {
            do {
                let created = try await createAccounts();
                let createdUser = updateBankUser();
                completion(created || createdUser);
                await refresh(scalableAccounts(), interactive: true);
            } catch ScalableError.loginCancelled {
                completion(false);
            } catch {
                logError("Scalable connection failed: %@", arguments: error.localizedDescription as NSString);
                let alert = NSAlert();
                alert.alertStyle = .warning;
                alert.messageText = NSLocalizedString("AP2348", comment: "Verbindung fehlgeschlagen");
                alert.informativeText = error.localizedDescription;
                alert.runModal();
                completion(false);
            }
        }
    }

    // Without interaction, a missing login only shows a status message instead of opening the browser.
    @objc class func refreshAccounts(_ accounts: [BankAccount]?, interactive: Bool) {
        let targets = (accounts ?? scalableAccounts()).filter { $0.provider == provider && $0.isProviderAccount() };
        if targets.isEmpty {
            return;
        }
        Task {
            await refresh(targets, interactive: interactive);
        }
    }

    private class func createAccounts() async throws -> Bool {
        let session = try await McpSession.open(token: try await accessToken(interactive: true));

        var accounts: [(kind: Kind, name: String)] = [];
        let portfolios = try await session.call("list_accessible_portfolios")["portfolios"] as? [[String: Any]] ?? [];
        let portfolioIds = portfolios.compactMap { $0["portfolioId"] as? String };
        for (index, portfolioId) in portfolioIds.enumerated() {
            let suffix = portfolioIds.count > 1 ? " \(index + 1)" : "";
            accounts.append((.depot(portfolioId: portfolioId), NSLocalizedString("AP2341", comment: "Depot") + suffix));
            accounts.append((.cash(portfolioId: portfolioId), NSLocalizedString("AP2342", comment: "Verrechnungskonto") + suffix));
        }
        // Without an argument, the server resolves the overnight account if there is exactly one.
        if let overnight = try? await session.call("get_overnight_summary"),
           let savingsAccountId = overnight["savingsAccountId"] as? String {
            let displayName = (overnight["account"] as? [String: Any])?["displayName"] as? String ?? "Tagesgeld";
            accounts.append((.overnight(savingsAccountId: savingsAccountId),
                             String(format: NSLocalizedString("AP2343", comment: "Scalable %@"), displayName)));
        }

        let existing = Set(scalableAccounts().compactMap { $0.providerAccountId });
        var created = false;
        for account in accounts where !existing.contains(account.kind.providerAccountId) {
            let bankAccount = BankAccount.createProviderAccount(provider: provider, providerAccountId: account.kind.providerAccountId,
                                                                bankCode: bankCode,
                                                                bankName: NSLocalizedString("AP2340", comment: "Scalable Capital"),
                                                                name: account.name);
            created = created || bankAccount != nil;
        }
        return created;
    }

    // Returns true if the bank user was created.
    private class func updateBankUser() -> Bool {
        guard let context = MOAssistant.shared().context else {
            return false;
        }
        var user = bankUser();
        let created = user == nil;
        if user == nil {
            user = NSEntityDescription.insertNewObject(forEntityName: "BankUser", into: context) as? BankUser;
            user?.name = NSLocalizedString("AP2340", comment: "Scalable Capital");
            user?.bankName = user?.name;
            user?.bankCode = bankCode;
            user?.bankURL = resource;
            user?.secMethod = NSNumber(value: SecMethod_Scalable.rawValue);
        }
        if let email = cachedAccessToken.flatMap(loginEmail) {
            user?.userId = email;
        }
        return created;
    }

    private class func loginEmail(fromAccessToken token: String) -> String? {
        let parts = token.split(separator: ".");
        guard parts.count > 1 else {
            return nil;
        }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/");
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4);
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil;
        }
        return claims["https://de.scalable.capital/email"] as? String;
    }

    private class func refresh(_ accounts: [BankAccount], interactive: Bool) async {
        do {
            let session = try await McpSession.open(token: try await accessToken(interactive: interactive));
            var cashAccounts: [(account: BankAccount, balance: NSDecimalNumber?, transactions: [Transaction])] = [];
            for account in accounts {
                guard account.managedObjectContext != nil, !account.isDeleted, let kind = Kind(account.providerAccountId) else {
                    continue;
                }
                switch kind {
                case .overnight(let savingsAccountId):
                    let overnight = try await session.call("get_overnight_summary", ["savingsAccountId": savingsAccountId]);
                    if let balance = decimal((overnight["summary"] as? [String: Any])?["balance"]) {
                        account.updateBalance(withValue: balance.rounding(accordingToBehavior: centRounding));
                    }
                case .cash(let portfolioId):
                    let breakdown = try await session.call("get_portfolio_cash_breakdown", ["portfolioId": portfolioId]);
                    let balance = decimal((breakdown["cash"] as? [String: Any])?["cashBalance"])?.rounding(accordingToBehavior: centRounding);
                    // The overlap catches transactions that settled after the last fetch.
                    let from = account.latestTransferDate.map { $0.addingTimeInterval(-60 * 24 * 3600) };
                    let transactions = try await self.transactions(session, portfolioId: portfolioId, from: from);
                    cashAccounts.append((account, balance, transactions));
                case .depot(let portfolioId):
                    let holdings = try await session.call("get_portfolio_holdings", ["portfolioId": portfolioId]);
                    let overview = try await session.call("get_portfolio_overview", ["portfolioId": portfolioId]);
                    updateDepot(account, holdings: holdings, overview: overview);
                }
            }
            // Without an await in between, a bank request cannot reset the memory context while the
            // statements are built.
            var results: [BankQueryResult] = [];
            for cash in cashAccounts where cash.account.managedObjectContext != nil && !cash.account.isDeleted {
                results.append(queryResult(for: cash.account, balance: cash.balance, transactions: cash.transactions));
            }
            if !results.isEmpty {
                let count = BankingController.controller().processProviderResults(results);
                if count > 0 {
                    StatusBarController.controller().setMessage(String(format: NSLocalizedString("AP218", comment: ""), Int32(count)),
                                                                removeAfter: 120);
                }
            }
            BankingCategory.bankRoot().updateSums();
            _ = BankingController.controller().save();
        } catch ScalableError.loginRequired where !interactive {
            StatusBarController.controller().setMessage(NSLocalizedString("AP2345", comment: ""), removeAfter: 120);
        } catch ScalableError.loginCancelled {
            StatusBarController.controller().setMessage(NSLocalizedString("AP2353", comment: ""), removeAfter: 30);
        } catch {
            logError("Scalable refresh failed: %@", arguments: error.localizedDescription as NSString);
            StatusBarController.controller().setMessage(String(format: NSLocalizedString("AP2346", comment: ""),
                                                               error.localizedDescription), removeAfter: 120);
        }
    }

    // MARK: - Transactions

    fileprivate struct Transaction {
        let id: String;
        let date: Date;
        let status: String;
        let type: String;
        let amount: NSDecimalNumber?;
        let quantity: NSDecimalNumber?;
        let isin: String?;
        let description: String;
        let currency: String;
        let isCancellation: Bool;
    }

    // Transaction types that move cash, with the sign of the booking. The sign comes from the type, so it does
    // not depend on the sign of the amounts. Securities transfers, swaps, currency switches and reinvestments
    // leave the cash balance alone and are left out.
    private static let cashTypes: [String: (sign: Int, text: String)] = [
        "BUY": (-1, NSLocalizedString("AP2354", comment: "Kauf")),
        "SAVINGS_PLAN": (-1, NSLocalizedString("AP2355", comment: "Sparplan")),
        "SELL": (1, NSLocalizedString("AP2356", comment: "Verkauf")),
        "DEPOSIT": (1, NSLocalizedString("AP2357", comment: "Einzahlung")),
        "WITHDRAWAL": (-1, NSLocalizedString("AP2358", comment: "Auszahlung")),
        "CASH_TRANSFER_IN": (1, NSLocalizedString("AP2359", comment: "Übertrag Eingang")),
        "CASH_TRANSFER_OUT": (-1, NSLocalizedString("AP2360", comment: "Übertrag Ausgang")),
        "DISTRIBUTION": (1, NSLocalizedString("AP2361", comment: "Ausschüttung")),
        "INTEREST": (1, NSLocalizedString("AP2362", comment: "Zinsen")),
        "FEE": (-1, NSLocalizedString("AP2363", comment: "Gebühr")),
        "TAX": (-1, NSLocalizedString("AP2364", comment: "Steuer")),
        "TAX_RETURN": (1, NSLocalizedString("AP2365", comment: "Steuererstattung"))
    ];
    private static let droppedStatuses: Set<String> = ["CANCELLED", "CANCEL_REQUESTED", "EXPIRED", "REJECTED"];

    private static let quantityFormatter: NumberFormatter = {
        let formatter = NumberFormatter();
        formatter.numberStyle = .decimal;
        formatter.maximumFractionDigits = 6;
        return formatter;
    }();

    // Broker and crypto transactions page separately, so each list is read to its end. The first page
    // comes twice, the id removes the duplicates.
    fileprivate class func transactions(_ session: McpSession, portfolioId: String, from: Date?,
                                        types: [String]? = nil) async throws -> [Transaction] {
        var arguments: [String: Any] = ["portfolioId": portfolioId, "pageSize": 100];
        if let from = from {
            arguments["fromTime"] = ISO8601DateFormatter().string(from: from);
        }
        if let types = types {
            arguments["transactionTypes"] = types;
        }
        var transactions: [String: Transaction] = [:];
        for cursorKey in ["cursor", "cryptoCursor"] {
            var cursor: String? = nil;
            repeat {
                var pageArguments = arguments;
                if let cursor = cursor {
                    pageArguments[cursorKey] = cursor;
                }
                let page = try await session.call("list_portfolio_transactions", pageArguments);
                let isCrypto = cursorKey == "cryptoCursor";
                let list = isCrypto ? page["crypto"] as? [String: Any] ?? [:] : page;
                for item in list["transactions"] as? [[String: Any]] ?? [] {
                    if let transaction = isCrypto ? cryptoTransaction(item) : brokerTransaction(item) {
                        transactions[transaction.id] = transaction;
                    }
                }
                cursor = (list["page"] as? [String: Any])?["nextCursor"] as? String;
            } while cursor != nil;
        }
        return Array(transactions.values);
    }

    private class func brokerTransaction(_ item: [String: Any]) -> Transaction? {
        guard let id = item["id"] as? String, let date = date(item["lastEventAt"]) else {
            return nil;
        }
        // The details of a transaction are in the object of its kind.
        let details = ["security", "cash", "nonTradeSecurity", "eltif"].lazy.compactMap { item[$0] as? [String: Any] }.first ?? [:];
        let type = (details["transactionType"] as? String).flatMap { cashTypes[$0] != nil ? $0 : nil }
            ?? (details["side"] as? String) ?? (details["transactionType"] as? String) ?? (item["category"] as? String) ?? "";
        return Transaction(id: id, date: date, status: item["status"] as? String ?? "", type: type,
                           amount: decimal(details["amount"]), quantity: decimal(details["quantity"]),
                           isin: details["isin"] as? String ?? details["relatedIsin"] as? String,
                           description: item["description"] as? String ?? "", currency: item["currency"] as? String ?? "EUR",
                           isCancellation: item["isCancellation"] as? Bool ?? false);
    }

    private class func cryptoTransaction(_ item: [String: Any]) -> Transaction? {
        guard let id = item["id"] as? String, let date = date(item["lastEventAt"]) else {
            return nil;
        }
        let type = (item["transactionType"] as? String).flatMap { cashTypes[$0] != nil ? $0 : nil }
            ?? (item["side"] as? String) ?? (item["transactionType"] as? String) ?? "";
        return Transaction(id: "crypto:" + id, date: date, status: item["status"] as? String ?? "", type: type,
                           amount: decimal(item["amount"]), quantity: decimal(item["coinQuantity"]), isin: nil,
                           description: item["description"] as? String ?? item["ticker"] as? String ?? "",
                           currency: item["currency"] as? String ?? "EUR", isCancellation: false);
    }

    // Statements of the cash account, oldest first. Transactions that have not settled yet become preliminary
    // statements, which the next fetch replaces.
    private class func queryResult(for account: BankAccount, balance: NSDecimalNumber?, transactions: [Transaction]) -> BankQueryResult {
        let context = MOAssistant.shared().memContext!;
        let result = BankQueryResult();
        result.account = account;
        result.balance = balance;

        for transaction in transactions.sorted(by: { $0.date < $1.date }) where !droppedStatuses.contains(transaction.status) {
            guard let cashType = cashTypes[transaction.type], var amount = transaction.amount else {
                logDebug("Scalable transaction %@ of type %@ does not move cash", arguments: transaction.id as NSString, transaction.type as NSString);
                continue;
            }
            if amount.compare(NSDecimalNumber.zero) == .orderedAscending {
                amount = amount.multiplying(by: NSDecimalNumber(value: -1));
            }
            let sign = transaction.isCancellation ? -cashType.sign : cashType.sign;

            let statement = NSEntityDescription.insertNewObject(forEntityName: "BankStatement", into: context) as! BankStatement;
            statement.localAccount = account.accountNumber();
            statement.localBankCode = account.bankCode;
            statement.bankReference = transaction.id;
            statement.currency = transaction.currency;
            statement.date = transaction.date;
            statement.valutaDate = transaction.date;
            statement.value = amount.multiplying(by: NSDecimalNumber(value: sign), withBehavior: centRounding);
            statement.remoteName = transaction.description;
            statement.transactionText = cashType.text;
            statement.transactionCode = "999";
            var purpose = cashType.text;
            if let quantity = transaction.quantity, let text = quantityFormatter.string(from: quantity) {
                purpose += " " + text;
            }
            if let isin = transaction.isin {
                purpose += " " + isin;
            }
            statement.purpose = purpose;
            statement.isStorno = NSNumber(value: transaction.isCancellation);
            statement.isPreliminary = NSNumber(value: transaction.status != "SETTLED");
            result.statements.append(statement);
        }
        account.evaluateQueryResult(result);
        return result;
    }

    // Holdings carry no buy price, so the depot view shows no change for them. Crypto at Scalable counts in
    // the depot value but has no position rows, since the server gives no prices for it.
    private class func updateDepot(_ account: BankAccount, holdings: [String: Any], overview: [String: Any]) {
        guard let context = account.managedObjectContext else {
            return;
        }
        let valuation = overview["valuation"] as? [String: Any];
        let total = decimal(valuation?["total"])?.rounding(accordingToBehavior: centRounding) ?? NSDecimalNumber.zero;
        let timestamps = overview["timestamps"] as? [String: Any];
        let valuationDate = date(timestamps?["valuationTimestampUtc"]) ?? Date();

        if let oldEntry = account.depotValueEntry {
            context.delete(oldEntry);
        }
        let entry = NSEntityDescription.insertNewObject(forEntityName: "DepotValueEntry", into: context) as! DepotValueEntry;
        entry.accountNumber = account.accountNumber();
        entry.bankCode = account.bankCode;
        entry.date = valuationDate;
        let day = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: valuationDate);
        entry.day = Int32(day.year! * 10000 + day.month! * 100 + day.day!);
        entry.depotValue = total;
        entry.depotValueCurrency = "EUR";

        for holding in holdings["holdings"] as? [[String: Any]] ?? [] {
            guard let position = holding["position"] as? [String: Any], let quantity = decimal(position["filled"]),
                  quantity.compare(NSDecimalNumber.zero) == .orderedDescending else {
                continue;
            }
            let instrument = NSEntityDescription.insertNewObject(forEntityName: "Instrument", into: context) as! Instrument;
            instrument.isin = holding["isin"] as? String;
            instrument.name = holding["name"] as? String;
            instrument.totalNumber = quantity;
            if let quote = holding["currentQuote"] as? [String: Any], let price = decimal(quote["midPrice"]) {
                let currency = quote["currency"] as? String;
                instrument.currentPrice = price;
                instrument.currentPriceCurrency = currency;
                instrument.priceDate = date(quote["timestamp"]);
                instrument.depotValue = price.multiplying(by: quantity, withBehavior: centRounding);
                instrument.depotValueCurrency = currency;
            }
            entry.addToInstruments(instrument);
        }

        entry.account = account;
        account.updateBalance(withValue: total);
    }

    // JSON numbers arrive as binary floating point. Their shortest decimal form is the value Scalable sent.
    private class func decimal(_ value: Any?) -> NSDecimalNumber? {
        let text: String;
        switch value {
        case let string as String:
            text = string;
        case let number as NSNumber:
            text = String(number.doubleValue);
        default:
            return nil;
        }
        let result = NSDecimalNumber(string: text, locale: Locale(identifier: "en_US_POSIX"));
        return result.decimalValue.isNaN ? nil : result;
    }

    private class func date(_ value: Any?) -> Date? {
        guard let text = value as? String else {
            return nil;
        }
        let formatter = ISO8601DateFormatter();
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds];
        if let date = formatter.date(from: text) {
            return date;
        }
        formatter.formatOptions = [.withInternetDateTime];
        return formatter.date(from: text);
    }

    // MARK: - Login

    private class func accessToken(interactive: Bool) async throws -> String {
        if let token = cachedAccessToken, accessTokenExpiry.timeIntervalSinceNow > 60 {
            return token;
        }
        if let clientId = UserDefaults.standard.string(forKey: clientIdKey),
           let refreshToken = Security.passwordForService(keychainService, account: clientId) {
            do {
                try await requestTokens(["grant_type": "refresh_token", "refresh_token": refreshToken,
                                         "client_id": clientId, "resource": resource],
                                        clientId: clientId, isRefresh: true);
                return cachedAccessToken!;
            } catch ScalableError.loginRequired {
                // The refresh token expired or was revoked, a new login follows.
            }
        }
        guard interactive else {
            throw ScalableError.loginRequired;
        }
        if let login = pendingLogin {
            try await login.value;
        } else {
            let login = Task { try await self.login() };
            pendingLogin = login;
            defer { pendingLogin = nil; }
            try await login.value;
        }
        guard let token = cachedAccessToken else {
            throw ScalableError.loginRequired;
        }
        return token;
    }

    private class func login() async throws {
        let clientId = try await registeredClientId();
        let verifier = randomURLSafeString(byteCount: 48);
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))));
        let state = randomURLSafeString(byteCount: 16);

        let listener = try CallbackListener(port: callbackPort);
        defer { listener.stop(); }

        var components = URLComponents(string: issuer + "/authorize")!;
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resource)
        ];
        // The login sheet never sees its own callback URL scheme, so only cancel() ends it. Closing the
        // sheet cancels the login.
        let presentation = LoginPresentation();
        let authentication = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: nil) { _, error in
            if error != nil {
                listener.cancel();
            }
        };
        authentication.presentationContextProvider = presentation;
        authentication.prefersEphemeralWebBrowserSession = false;
        guard authentication.start() else {
            throw ScalableError.loginCancelled;
        }
        defer { authentication.cancel(); }

        let callback = try await listener.waitForCallback(timeout: 600);
        guard callback["state"] == state else {
            throw ScalableError.invalidResponse("state");
        }
        if let error = callback["error"] {
            throw ScalableError.server(callback["error_description"] ?? error);
        }
        guard let code = callback["code"] else {
            throw ScalableError.invalidResponse("code");
        }
        try await requestTokens(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                                 "client_id": clientId, "code_verifier": verifier, "resource": resource],
                                clientId: clientId, isRefresh: false);
    }

    // Scalable allows dynamic client registration, one client per Pecunia installation.
    private class func registeredClientId() async throws -> String {
        if let clientId = UserDefaults.standard.string(forKey: clientIdKey) {
            return clientId;
        }
        var request = URLRequest(url: URL(string: issuer + "/register")!, timeoutInterval: 30);
        request.httpMethod = "POST";
        request.setValue("application/json", forHTTPHeaderField: "Content-Type");
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Pecunia",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": scope
        ]);
        let (data, _) = try await URLSession.shared.data(for: request);
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any];
        guard let clientId = json?["client_id"] as? String else {
            throw ScalableError.server(json?["error_description"] as? String ?? "client registration");
        }
        UserDefaults.standard.set(clientId, forKey: clientIdKey);
        return clientId;
    }

    // Scalable rotates the refresh token, so each token response replaces the stored one.
    private class func requestTokens(_ form: [String: String], clientId: String, isRefresh: Bool) async throws {
        var request = URLRequest(url: URL(string: issuer + "/token")!, timeoutInterval: 30);
        request.httpMethod = "POST";
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type");
        var allowed = CharacterSet.alphanumerics;
        allowed.insert(charactersIn: "-._~");
        request.httpBody = form.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").data(using: .utf8);

        let (data, response) = try await URLSession.shared.data(for: request);
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0;
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:];
        guard status == 200, let accessToken = json["access_token"] as? String else {
            if isRefresh && (status == 400 || status == 401) {
                Security.deletePasswordForService(keychainService, account: clientId);
                throw ScalableError.loginRequired;
            }
            throw ScalableError.server(json["error_description"] as? String ?? "HTTP \(status)");
        }
        cachedAccessToken = accessToken;
        accessTokenExpiry = Date(timeIntervalSinceNow: json["expires_in"] as? Double ?? 600);
        if let refreshToken = json["refresh_token"] as? String {
            Security.deletePasswordForService(keychainService, account: clientId);
            _ = Security.setPassword(refreshToken, forService: keychainService, account: clientId, store: true);
        }
    }

    private class func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount);
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes);
        return base64URL(Data(bytes));
    }

    private class func base64URL(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "");
    }
}

// Receives the OAuth redirect on the loopback interface. Browsers also request /favicon.ico from it,
// which must not end the wait. All callbacks run on the main queue.
private final class CallbackListener: @unchecked Sendable {
    private let listener: NWListener;
    private var continuation: CheckedContinuation<[String: String], Error>?;
    private var result: Result<[String: String], Error>?;

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp;
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!);
        parameters.allowLocalEndpointReuse = true;
        do {
            listener = try NWListener(using: parameters);
        } catch {
            throw ScalableError.callbackPortUnavailable;
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.finish(.failure(ScalableError.callbackPortUnavailable));
            }
        };
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection);
        };
        listener.start(queue: .main);
    }

    func stop() {
        listener.cancel();
    }

    func cancel() {
        finish(.failure(ScalableError.loginCancelled));
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        if let result = result {
            return try result.get();
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(ScalableError.loginTimeout));
        };
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation;
        };
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard self.result == nil else {
            return;
        }
        self.result = result;
        continuation?.resume(with: result);
        continuation = nil;
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main);
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? "";
            let target = request.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first;
            var query: [String: String] = [:];
            if let target = target, let components = URLComponents(string: String(target)), components.path == "/callback" {
                for item in components.queryItems ?? [] {
                    query[item.name] = item.value ?? "";
                }
            }
            let isCallback = query["code"] != nil || query["error"] != nil;
            let html = "<!DOCTYPE html><meta charset=\"utf-8\"><title>Pecunia</title><p>"
                + (isCallback ? NSLocalizedString("AP2347", comment: "Anmeldung erhalten") : "") + "</p>";
            let response = "HTTP/1.1 " + (isCallback ? "200 OK" : "404 Not Found") + "\r\n"
                + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html;
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel();
            });
            if isCallback {
                self?.finish(.success(query));
            }
        };
    }
}

private final class LoginPresentation: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow();
    }
}

// Minimal MCP client for the Streamable HTTP transport. A JSON-RPC response arrives either as JSON or as
// an event stream.
private final class McpSession {
    private let token: String;
    private var sessionId: String?;
    private var protocolVersion = "2025-06-18";
    private var nextId = 1;

    private init(token: String) {
        self.token = token;
    }

    static func open(token: String) async throws -> McpSession {
        let session = McpSession(token: token);
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "";
        let result = try await session.request("initialize", [
            "protocolVersion": session.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Pecunia", "version": version]
        ]);
        if let protocolVersion = result["protocolVersion"] as? String {
            session.protocolVersion = protocolVersion;
        }
        _ = try await session.post(["jsonrpc": "2.0", "method": "notifications/initialized"], id: nil);
        return session;
    }

    // Returns the structured content of a tool result. Scalable reports failures inside it.
    func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let result = try await request("tools/call", ["name": tool, "arguments": arguments]);
        guard let content = result["structuredContent"] as? [String: Any] else {
            throw ScalableError.invalidResponse(tool);
        }
        if let error = content["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "";
            if code == "auth_required" || code == "auth_invalid" {
                throw ScalableError.loginRequired;
            }
            throw ScalableError.server(error["message"] as? String ?? code);
        }
        return content;
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextId;
        nextId += 1;
        guard let response = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params], id: id) else {
            throw ScalableError.invalidResponse(method);
        }
        if let error = response["error"] as? [String: Any] {
            throw ScalableError.server(error["message"] as? String ?? method);
        }
        guard let result = response["result"] as? [String: Any] else {
            throw ScalableError.invalidResponse(method);
        }
        return result;
    }

    private func post(_ message: [String: Any], id: Int?) async throws -> [String: Any]? {
        var request = URLRequest(url: URL(string: ScalableService.resource)!, timeoutInterval: 30);
        request.httpMethod = "POST";
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization");
        request.setValue("application/json", forHTTPHeaderField: "Content-Type");
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept");
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version");
        if let sessionId = sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id");
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message);

        let (data, response) = try await URLSession.shared.data(for: request);
        guard let http = response as? HTTPURLResponse else {
            throw ScalableError.invalidResponse("HTTP");
        }
        if http.statusCode == 401 {
            throw ScalableError.loginRequired;
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ScalableError.server("HTTP \(http.statusCode)");
        }
        if let sessionId = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            self.sessionId = sessionId;
        }
        guard let id = id else {
            return nil;
        }
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) where line.hasPrefix("data:") {
                if let object = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any],
                   object["id"] as? Int == id {
                    return object;
                }
            }
            throw ScalableError.invalidResponse("event stream");
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any];
    }
}
