//
//  CryptoHolding.swift
//  Pecunia
//
//  An amount of one crypto currency held in a crypto account.
//

import Foundation
import CoreData

@objc(CryptoHolding)
class CryptoHolding: NSManagedObject {
    @NSManaged var symbol: String;
    @NSManaged var label: String?;
    @NSManaged var quantity: NSDecimalNumber;
    @NSManaged var price: NSDecimalNumber?;      // EUR per coin
    @NSManaged var priceDate: Date?;
    @NSManaged var account: BankAccount?;

    // EUR value rounded to cents, nil as long as no price is known.
    var value: NSDecimalNumber? {
        guard let price = price else {
            return nil;
        }
        return quantity.multiplying(by: price, withBehavior: CryptoService.centRounding);
    }
}
