import Foundation

/// A bounded arithmetic grammar. Model input must never reach Foundation's
/// predicate/expression parser, whose Objective-C exceptions bypass Swift catch.
enum ToolMathExpression {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func evaluate(_ expression: String) throws -> Double {
        guard expression.utf8.count <= 8_192 else {
            throw Failure(message: "Expression is too long.")
        }
        let normalized = expression
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "π", with: "pi")
        var parser = Parser(bytes: Array(normalized.utf8))
        let value = try parser.sum()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw Failure(message: "Unexpected input at position \(parser.index + 1).")
        }
        return try parser.finite(value)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        mutating func take(_ byte: UInt8) -> Bool {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        func finite(_ value: Double) throws -> Double {
            guard value.isFinite else {
                throw Failure(message: "Result is outside the finite real-number range.")
            }
            return value
        }

        mutating func sum() throws -> Double {
            var value = try product()
            while true {
                if take(43) { value = try finite(value + product()) }
                else if take(45) { value = try finite(value - product()) }
                else { return value }
            }
        }

        mutating func product() throws -> Double {
            var value = try unary()
            while true {
                if take(42) { value = try finite(value * unary()) }
                else if take(47) {
                    let divisor = try unary()
                    guard divisor != 0 else { throw Failure(message: "Division by zero.") }
                    value = try finite(value / divisor)
                } else if take(37) {
                    let divisor = try unary()
                    guard divisor != 0 else { throw Failure(message: "Remainder with zero divisor.") }
                    value = try finite(value.truncatingRemainder(dividingBy: divisor))
                } else { return value }
            }
        }

        mutating func unary() throws -> Double {
            guard depth < 64 else { throw Failure(message: "Expression is nested too deeply.") }
            depth += 1
            defer { depth -= 1 }
            if take(43) { return try unary() }
            if take(45) { return try finite(-unary()) }
            return try power()
        }

        mutating func power() throws -> Double {
            let base = try factorial()
            // Exponentiation is right associative and binds before unary minus.
            if take(94) { return try finite(pow(base, unary())) }
            return base
        }

        mutating func factorial() throws -> Double {
            var value = try atom()
            while take(33) {
                guard value >= 0, value <= 170, value.rounded(.towardZero) == value else {
                    throw Failure(message: "Factorial requires an integer from 0 to 170.")
                }
                let integer = Int(value)
                value = 1
                if integer >= 2 { for factor in 2...integer { value *= Double(factor) } }
                value = try finite(value)
            }
            return value
        }

        mutating func atom() throws -> Double {
            if take(40) {
                let value = try sum()
                guard take(41) else { throw Failure(message: "Missing closing parenthesis.") }
                return value
            }
            skipWhitespace()
            guard index < bytes.count else { throw Failure(message: "Expected a number or function.") }
            let byte = bytes[index]
            if (48...57).contains(byte) || byte == 46 { return try number() }
            guard (65...90).contains(byte) || (97...122).contains(byte) else {
                throw Failure(message: "Unsupported character at position \(index + 1).")
            }
            let start = index
            while index < bytes.count,
                  (65...90).contains(bytes[index]) || (97...122).contains(bytes[index]) { index += 1 }
            let name = String(decoding: bytes[start..<index], as: UTF8.self).lowercased()
            if name == "pi" { return Double.pi }
            if name == "e" { return exp(1) }
            guard ["sin", "cos", "tan", "sqrt", "ln", "abs", "floor", "ceil", "log"].contains(name) else {
                throw Failure(message: "Unsupported function. Use arithmetic or the documented math functions.")
            }
            guard take(40) else { throw Failure(message: "A function requires parentheses.") }
            let argument = try sum()
            guard take(41) else { throw Failure(message: "Expected one argument and a closing parenthesis.") }
            let value: Double
            switch name {
            case "sin": value = sin(argument)
            case "cos": value = cos(argument)
            case "tan": value = tan(argument)
            case "sqrt": value = sqrt(argument)
            case "ln": value = log(argument)
            case "log": value = log10(argument)
            case "abs": value = abs(argument)
            case "floor": value = floor(argument)
            case "ceil": value = ceil(argument)
            default: throw Failure(message: "Unsupported function.")
            }
            return try finite(value)
        }

        mutating func number() throws -> Double {
            let start = index
            var digits = 0
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1; digits += 1 }
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1; digits += 1 }
            }
            guard digits > 0 else { throw Failure(message: "Invalid number.") }
            if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
                index += 1
                if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
                let exponentStart = index
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                guard index > exponentStart else { throw Failure(message: "Invalid exponent.") }
            }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                throw Failure(message: "Invalid number.")
            }
            return try finite(value)
        }
    }
}
