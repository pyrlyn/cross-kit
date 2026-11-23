import Foundation

/// How CrossKit draws a source file's icon: a macOS-style document (white page, folded top-right corner)
/// with a coloured language band and a short badge, like Finder's icons for Swift or C files.
/// The app renders it (`FileIconView`); this type only holds the data so it can be tested without AppKit.
public struct FileIconStyle: Equatable, Sendable {
    /// Short label on the band, e.g. `C++`, `TS`, `WAT`.
    public var badge: String
    /// Band colour, 0xRRGGBB.
    public var color: UInt32
    /// Badge text colour, 0xRRGGBB (white or a dark ink on light bands).
    public var textColor: UInt32
    /// A second band colour for a vertical gradient, 0xRRGGBB.
    public var secondaryColor: UInt32

    public init(badge: String, color: UInt32, textColor: UInt32 = 0xFFFFFF, secondaryColor: UInt32? = nil) {
        self.badge = badge
        self.color = color
        self.textColor = textColor
        self.secondaryColor = secondaryColor ?? Self.darken(color)
    }

    /// The icon for a file path or name, by extension (and a few well-known file names).
    public static func forFile(_ path: String) -> FileIconStyle {
        let name = (path as NSString).lastPathComponent
        switch name {
        case "CMakeLists.txt": return FileIconStyle(badge: "CMAKE", color: 0x064F8C)
        case "package.json", "package-lock.json": return FileIconStyle(badge: "NPM", color: 0xCB3837)
        case "tsconfig.json", "jsconfig.json": return FileIconStyle(badge: "TS", color: 0x3178C6)
        case "Cargo.toml", "Cargo.lock": return FileIconStyle(badge: "RS", color: 0xDEA584, textColor: 0x3B2416)
        case "build.zig", "build.zig.zon": return FileIconStyle(badge: "ZIG", color: 0xF7A41D, textColor: 0x2B1D05)
        case "build.gradle.kts", "settings.gradle.kts": return FileIconStyle(badge: "KTS", color: 0x7F52FF, secondaryColor: 0xC711E1)
        default: break
        }
        if name.hasSuffix(".d.ts") || name.hasSuffix(".d.mts") || name.hasSuffix(".d.cts") { return forExtension("d.ts") }
        return forExtension((name as NSString).pathExtension)
    }

    public static func forExtension(_ ext: String) -> FileIconStyle {
        switch ext.lowercased() {
        case "cpp", "cc", "cxx", "c++": return FileIconStyle(badge: "C++", color: 0x00599C, secondaryColor: 0x004482)
        case "hpp", "hh", "hxx", "ipp", "tpp": return FileIconStyle(badge: "H++", color: 0x659AD2, secondaryColor: 0x00599C)
        case "c": return FileIconStyle(badge: "C", color: 0x5C6BC0)
        case "h": return FileIconStyle(badge: "H", color: 0x8E99D6, secondaryColor: 0x5C6BC0)
        case "js", "mjs", "cjs": return FileIconStyle(badge: "JS", color: 0xF7DF1E, textColor: 0x1F1F1F, secondaryColor: 0xE5C700)
        case "jsx": return FileIconStyle(badge: "JSX", color: 0xF7DF1E, textColor: 0x1F1F1F, secondaryColor: 0x61DAFB)
        case "ts", "mts", "cts": return FileIconStyle(badge: "TS", color: 0x3178C6)
        case "tsx": return FileIconStyle(badge: "TSX", color: 0x3178C6, secondaryColor: 0x61DAFB)
        case "d.ts": return FileIconStyle(badge: "D.TS", color: 0x235A97)
        case "wat": return FileIconStyle(badge: "WAT", color: 0x654FF0)
        case "wast": return FileIconStyle(badge: "WAST", color: 0x654FF0, secondaryColor: 0x3D2BB8)
        case "wasm": return FileIconStyle(badge: "WASM", color: 0x4A3AC0, secondaryColor: 0x2A1F80)
        case "kt": return FileIconStyle(badge: "KT", color: 0x7F52FF, secondaryColor: 0xC711E1)
        case "kts": return FileIconStyle(badge: "KTS", color: 0x7F52FF, secondaryColor: 0xC711E1)
        case "zig", "zon": return FileIconStyle(badge: "ZIG", color: 0xF7A41D, textColor: 0x2B1D05)
        case "rs": return FileIconStyle(badge: "RS", color: 0xDEA584, textColor: 0x3B2416, secondaryColor: 0xB7410E)
        case "swift": return FileIconStyle(badge: "SWIFT", color: 0xF05138, secondaryColor: 0xFA7343)
        case "java": return FileIconStyle(badge: "JAVA", color: 0xE76F00, secondaryColor: 0x5382A1)
        case "json": return FileIconStyle(badge: "JSON", color: 0x6D6D6D)
        case "lcov", "info": return FileIconStyle(badge: "COV", color: 0x2E9E5B)
        default: return FileIconStyle(badge: ext.isEmpty ? "" : String(ext.uppercased().prefix(4)), color: 0x8E8E93)
        }
    }

    /// The icon for a language (its main file extension).
    public static func forLanguage(_ language: Language) -> FileIconStyle {
        switch language {
        case .kotlin: return forExtension("kt")
        case .zig: return forExtension("zig")
        case .rust: return forExtension("rs")
        case .cpp: return forExtension("cpp")
        case .javascript: return forExtension("js")
        case .typescript: return forExtension("ts")
        case .wasm: return forExtension("wat")
        }
    }

    /// Splits 0xRRGGBB into 0…1 components.
    public static func components(_ rgb: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255)
    }

    static func darken(_ rgb: UInt32, by factor: Double = 0.78) -> UInt32 {
        let (r, g, b) = components(rgb)
        func channel(_ value: Double) -> UInt32 { UInt32((value * factor * 255).rounded()) }
        return channel(r) << 16 | channel(g) << 8 | channel(b)
    }
}
