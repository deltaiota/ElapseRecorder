//
//  Item.swift
//  ElapsedRecord
//
//  Created by KrLite on 2026/6/18.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
