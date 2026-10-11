//
//  ProviderAccount.swift
//  Pecunia
//
//  Accounts that get their data from a provider instead of a bank connection.
//

import Foundation
import CoreData

extension BankAccount {
    // Creates the account below the bank node of its provider. The bank node is created on first use.
    class func createProviderAccount(provider: String, providerAccountId: String?, bankCode: String,
                                     bankName: String, name: String) -> BankAccount? {
        guard let context = MOAssistant.shared().context, let root = BankingCategory.bankRoot() else {
            return nil;
        }

        var bankNode = BankAccount.bankRoot(forCode: bankCode);
        if bankNode == nil {
            let node = NSEntityDescription.insertNewObject(forEntityName: "BankAccount", into: context) as! BankAccount;
            node.bankCode = bankCode;
            node.bankName = bankName;
            node.name = bankName;
            node.currency = "EUR";
            node.isBankAcc = NSNumber(value: true);
            node.parent = root;
            bankNode = node;
        }

        let account = NSEntityDescription.insertNewObject(forEntityName: "BankAccount", into: context) as! BankAccount;
        account.bankCode = bankCode;
        account.bankName = bankNode!.bankName;
        account.name = name;
        account.isManual = NSNumber(value: true);
        account.setValue(BankAccount.findFreeAccountNumber(), forKey: "accountNumber");
        account.currency = "EUR";
        account.balance = NSDecimalNumber.zero;
        account.isBankAcc = NSNumber(value: true);
        account.provider = provider;
        account.providerAccountId = providerAccountId;
        account.parent = bankNode;
        return account;
    }
}
