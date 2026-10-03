import Foundation
import Security

public enum EnergyHelperIdentity {
    public static let service = "com.dynamicnotch.energy-helper"
    public static let plist = "com.dynamicnotch.energy-helper.plist"
    public static let app = "com.dynamicnotch.app"

    /// Both peers must be signed by Apple and carry our own signing team.
    /// Missing signing information fails closed, including raw SwiftPM runs.
    public static func requirement(for identifier: String) -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let data = information as? [String: Any],
              let team = data[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}

@objc public protocol EnergyModeHelperProtocol {
    func apply(batteryFlag: String, batteryValue: Int, adapterFlag: String, adapterValue: Int,
               reply: @escaping (Bool) -> Void)
}

public enum EnergyHelperArguments {
    /// Only energy-mode flags and bounded integers cross the privilege boundary.
    /// No shell, executable path, sleep setting, or arbitrary command is accepted.
    public static func make(profile: String, flag: String, value: Int) -> [String]? {
        guard profile == "-b" || profile == "-c" else { return nil }
        let maximum: Int
        switch flag {
        case "lowpowermode": maximum = 1
        case "powermode": maximum = 2
        default: return nil
        }
        guard (0...maximum).contains(value) else { return nil }
        return [profile, flag, String(value)]
    }
}
