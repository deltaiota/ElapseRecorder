//
//  Binding+Extensions.swift
//  ElapseRecorder
//
//  Created by KrLite on 2026/6/19.
//

import SwiftUI

public extension Binding where Value == Bool {
    func negate() -> Binding<Bool> {
        Binding<Bool> {
            !wrappedValue
        } set: { newValue in
            wrappedValue = !newValue
        }
    }
}

public extension Binding where Value: SetAlgebra & Sendable, Value.Element: Sendable {
    subscript(contains element: Value.Element) -> Binding<Bool> {
        Binding<Bool> {
            wrappedValue.contains(element)
        } set: { newValue in
            if newValue {
                wrappedValue.insert(element)
            } else {
                wrappedValue.remove(element)
            }
        }
    }
}

public extension Binding where Value: RangeReplaceableCollection & Sendable, Value.Element: Equatable & Sendable {
    subscript(contains element: Value.Element) -> Binding<Bool> {
        Binding<Bool> {
            wrappedValue.contains(element)
        } set: { newValue in
            if newValue {
                wrappedValue.append(element)
            } else {
                wrappedValue.removeAll(where: { $0 == element })
            }
        }
    }
}

public extension Binding {
    subscript<Wrapped>(matches optional: Value) -> Binding<Bool> where Value == Wrapped?, Value: Sendable, Wrapped: Equatable {
        Binding<Bool> {
            wrappedValue == optional
        } set: { newValue in
            wrappedValue = newValue ? optional : nil
        }
    }
}
