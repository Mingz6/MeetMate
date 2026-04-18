//
//  Item.swift
//  MeetMate
//
//  Created by Ming Zhu on 2026-04-18.
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
