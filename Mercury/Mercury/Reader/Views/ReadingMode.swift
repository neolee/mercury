//
//  ReadingMode.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import SwiftUI

enum ReadingMode: String, CaseIterable, Identifiable {
    case reader
    case web
    case dual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reader:
            return "Reader"
        case .web:
            return "Web"
        case .dual:
            return "Dual"
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .reader:
            return "Reader"
        case .web:
            return "Web"
        case .dual:
            return "Dual"
        }
    }

    var iconSystemName: String {
        switch self {
        case .reader:
            return "doc.text"
        case .web:
            return "globe"
        case .dual:
            return "rectangle.split.2x1"
        }
    }
}
