//
//  CryptoService.swift
//  Pecunia
//
//  Crypto accounts are manual accounts without any bank connection. Their balance is the EUR value
//  of their holdings, so they add up with all other accounts in the account tree.
//

import Foundation
import CoreData

@objc class CryptoService: NSObject {
    struct Coin {
        let symbol: String;
        let name: String;
        let krakenPair: String;
    }

    static let coins = [
        Coin(symbol: "BTC", name: "Bitcoin", krakenPair: "XBTEUR")
    ];

    @objc static let provider = "crypto";

    // Bank code of the bank node that groups all crypto accounts.
    @objc static let bankCode = "CRYPTO";

    @objc static let pricesUpdatedNotification = Notification.Name("CryptoPricesUpdated");

    static let centRounding = NSDecimalNumberHandler(roundingMode: .plain, scale: 2,
                                                     raiseOnExactness: false, raiseOnOverflow: true,
                                                     raiseOnUnderflow: true, raiseOnDivideByZero: true);

    class func coin(_ symbol: String) -> Coin? {
        return coins.first { $0.symbol == symbol };
    }

    // MARK: - Accounts

    @objc class func cryptoAccounts() -> [BankAccount] {
        guard let context = MOAssistant.shared().context else {
            return [];
        }
        let request = NSFetchRequest<BankAccount>(entityName: "BankAccount");
        request.predicate = NSPredicate(format: "provider = %@ AND accountNumber != nil", provider);
        do {
            return try context.fetch(request);
        } catch {
            logError("Fetching crypto accounts failed: %@", arguments: error.localizedDescription as NSString);
            return [];
        }
    }

    @objc class func createAccount(name: String) -> BankAccount? {
        guard let context = MOAssistant.shared().context, let root = BankingCategory.bankRoot() else {
            return nil;
        }

        var bankNode = BankAccount.bankRoot(forCode: bankCode);
        if bankNode == nil {
            let node = NSEntityDescription.insertNewObject(forEntityName: "BankAccount", into: context) as! BankAccount;
            node.bankCode = bankCode;
            node.bankName = NSLocalizedString("AP2300", comment: "Krypto");
            node.name = node.bankName;
            node.currency = "EUR";
            node.isBankAcc = NSNumber(value: true);
            node.parent = root;
            bankNode = node;
        }

        let account = NSEntityDescription.insertNewObject(forEntityName: "BankAccount", into: context) as! BankAccount;
        account.bankCode = bankCode;
        account.bankName = bankNode!.bankName;
        account.name = name;
        account.setValue(BankAccount.findFreeAccountNumber(), forKey: "accountNumber");
        account.currency = "EUR";
        account.balance = NSDecimalNumber.zero;
        account.isManual = NSNumber(value: true);
        account.provider = provider;
        account.isBankAcc = NSNumber(value: true);
        account.parent = bankNode;
        return account;
    }

    class func holdings(of account: BankAccount) -> [CryptoHolding] {
        let holdings = account.cryptoHoldings as? Set<CryptoHolding> ?? [];
        return holdings.sorted {
            if $0.symbol != $1.symbol {
                return $0.symbol < $1.symbol;
            }
            return ($0.label ?? "") < ($1.label ?? "");
        };
    }

    class func addHolding(to account: BankAccount, symbol: String, quantity: NSDecimalNumber, label: String?) {
        guard let context = account.managedObjectContext else {
            return;
        }
        let holding = NSEntityDescription.insertNewObject(forEntityName: "CryptoHolding", into: context) as! CryptoHolding;
        holding.symbol = symbol;
        holding.quantity = quantity;
        holding.label = label;

        // Start with the newest known price of that coin, so the value shows up before the next fetch.
        let request = NSFetchRequest<CryptoHolding>(entityName: "CryptoHolding");
        request.predicate = NSPredicate(format: "symbol = %@ AND price != nil", symbol);
        request.sortDescriptors = [NSSortDescriptor(key: "priceDate", ascending: false)];
        request.fetchLimit = 1;
        if let known = (try? context.fetch(request))?.first {
            holding.price = known.price;
            holding.priceDate = known.priceDate;
        }

        holding.account = account;
        revalue(account);
    }

    class func removeHolding(_ holding: CryptoHolding) {
        guard let account = holding.account, let context = holding.managedObjectContext else {
            return;
        }
        holding.account = nil;
        context.delete(holding);
        revalue(account);
    }

    // Sets the account balance to the EUR value of all holdings. Holdings without a price count as 0.
    @objc class func revalue(_ account: BankAccount) {
        var total = NSDecimalNumber.zero;
        for holding in holdings(of: account) {
            if let value = holding.value {
                total = total.adding(value);
            }
        }
        account.updateBalance(withValue: total);
        BankingCategory.bankRoot().updateSums();
    }

    // MARK: - Prices

    // Fetches the current EUR prices of all coins in the given accounts (all crypto accounts if nil),
    // revalues the accounts and saves. The completion runs on the main thread and gets false if any
    // price could not be fetched. Holdings keep their last price in that case.
    @objc class func refreshPrices(for accounts: [BankAccount]?, completion: ((Bool) -> Void)?) {
        let targets = (accounts ?? cryptoAccounts()).filter { $0.isCryptoAccount() };
        let symbols = Set(targets.flatMap { holdings(of: $0).map { $0.symbol } });
        if symbols.isEmpty {
            completion?(true);
            return;
        }

        var prices: [String: NSDecimalNumber] = [:];
        let group = DispatchGroup();
        for symbol in symbols {
            guard let coin = coin(symbol) else {
                logWarning("No price source for crypto currency %@", arguments: symbol as NSString);
                continue;
            }
            group.enter();
            fetchPrice(coin) { price in
                if let price = price {
                    prices[symbol] = price;
                }
                group.leave();
            }
        }

        group.notify(queue: .main) {
            let now = Date();
            for account in targets {
                for holding in holdings(of: account) {
                    if let price = prices[holding.symbol] {
                        holding.price = price;
                        holding.priceDate = now;
                    }
                }
                revalue(account);
            }
            _ = BankingController.controller().save();
            NotificationCenter.default.post(name: pricesUpdatedNotification, object: nil);

            let success = prices.count == symbols.count;
            if !success {
                StatusBarController.controller().setMessage(NSLocalizedString("AP2301", comment: ""), removeAfter: 60);
            }
            completion?(success);
        }
    }

    // Calls back on the main thread, with nil if the price could not be fetched.
    private class func fetchPrice(_ coin: Coin, completion: @escaping (NSDecimalNumber?) -> Void) {
        let url = URL(string: "https://api.kraken.com/0/public/Ticker?pair=" + coin.krakenPair)!;
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15);
        URLSession.shared.dataTask(with: request) { data, response, error in
            var price: NSDecimalNumber? = nil;
            if let error = error {
                logError("Price request for %@ failed: %@", arguments: coin.symbol as NSString, error.localizedDescription as NSString);
            } else if let data = data {
                price = parseKrakenPrice(data);
                if price == nil {
                    logError("Unexpected price response for %@: %@", arguments: coin.symbol as NSString,
                             (String(data: data, encoding: .utf8) ?? "") as NSString);
                }
            }
            DispatchQueue.main.async {
                completion(price);
            }
        }.resume();
    }

    // Kraken names the result after its own pair name (XBTEUR -> XXBTZEUR), so take the only entry.
    // "c" is the last trade as [price, volume]. Prices are strings, which keeps them exact.
    class func parseKrakenPrice(_ data: Data) -> NSDecimalNumber? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = json["result"] as? [String: Any], result.count == 1,
              let ticker = result.values.first as? [String: Any],
              let lastTrade = ticker["c"] as? [String],
              let text = lastTrade.first else {
            return nil;
        }
        let price = NSDecimalNumber(string: text, locale: Locale(identifier: "en_US_POSIX"));
        if price.decimalValue.isNaN || price.compare(NSDecimalNumber.zero) != .orderedDescending {
            return nil;
        }
        return price;
    }
}
