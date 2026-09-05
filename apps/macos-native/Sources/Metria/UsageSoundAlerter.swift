import AppKit
import Foundation
import MetriaCore

/// Plays a sound once when a provider's usage percent crosses one of the menu bar alert
/// thresholds upward between refresh ticks.
///
/// UserDefaults keys read and written here (the Settings sound block shares them):
/// - "soundAlertsEnabled" (Bool, default `false`): master switch.
/// - "soundAlertCautionEnabled" / "soundAlertWarningEnabled" / "soundAlertCriticalEnabled"
///   (Bool, default `true`): per-level switches.
/// - "soundAlertName" (String, default `"Glass"`): one of "Glass", "Ping", "Submarine",
///   or "custom" (a user-picked file copied into Application Support).
/// - "soundAlertVolume" (Double, default `1.0`): playback volume, 0...1.
/// - "soundAlertMutedUntil" (Double, default `0`): epoch seconds the mute lasts until;
///   0 means not muted.
///
/// Thresholds come from the shared menu bar alert keys ("menuBarCautionThreshold",
/// "menuBarWarningThreshold", "menuBarCriticalThreshold") with the same fallbacks as
/// `MenuBarAlertSettings.default`.
@MainActor
final class UsageSoundAlerter {
    static let systemSoundNames = ["Glass", "Ping", "Submarine"]
    static let customName = "custom"

    private static let enabledKey = "soundAlertsEnabled"
    private static let soundNameKey = "soundAlertName"
    private static let volumeKey = "soundAlertVolume"
    private static let mutedUntilKey = "soundAlertMutedUntil"

    /// Provider + level pair that has already announced itself; cleared when the percent
    /// falls back below that level's threshold, so a window reset can alert again.
    private struct FiredKey: Hashable {
        let kind: ProviderKind
        let level: Level
    }

    private enum Level: Int, CaseIterable {
        case caution
        case warning
        case critical

        var thresholdKey: String {
            switch self {
            case .caution: return "menuBarCautionThreshold"
            case .warning: return "menuBarWarningThreshold"
            case .critical: return "menuBarCriticalThreshold"
            }
        }

        var fallbackThreshold: Int {
            switch self {
            case .caution: return MenuBarAlertSettings.default.cautionThreshold
            case .warning: return MenuBarAlertSettings.default.warningThreshold
            case .critical: return MenuBarAlertSettings.default.criticalThreshold
            }
        }

        var enabledKey: String {
            switch self {
            case .caution: return "soundAlertCautionEnabled"
            case .warning: return "soundAlertWarningEnabled"
            case .critical: return "soundAlertCriticalEnabled"
            }
        }

        var threshold: Double {
            Double(UserDefaults.standard.object(forKey: thresholdKey) as? Int ?? fallbackThreshold)
        }
    }

    private var lastPercent: [ProviderKind: Double] = [:]
    private var fired: Set<FiredKey> = []
    private var isSessionActive = true
    private var sessionObservers: [NSObjectProtocol] = []
    /// NSSound plays asynchronously; keep the last one alive until it finishes.
    private var playingSound: NSSound?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        sessionObservers.append(
            center.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isSessionActive = false }
            })
        sessionObservers.append(
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isSessionActive = true }
            })
    }

    deinit {
        for observer in sessionObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Called on every `UsageStore.providers` publish. The first snapshot only records a
    /// baseline; later snapshots fire at most one sound for the highest upward crossing.
    func process(_ providers: [ProviderUsage]) {
        var candidates: [(kind: ProviderKind, level: Level)] = []
        var current: [ProviderKind: Double] = [:]
        for provider in providers {
            guard let percent = provider.primary?.percent else {
                lastPercent.removeValue(forKey: provider.kind)
                continue
            }
            current[provider.kind] = percent
            // A provider never seen before is baseline only: never beep on arrival.
            guard let previous = lastPercent[provider.kind] else { continue }
            for level in Level.allCases {
                let key = FiredKey(kind: provider.kind, level: level)
                if previous < level.threshold && percent >= level.threshold {
                    if !fired.contains(key) {
                        fired.insert(key)
                        candidates.append((provider.kind, level))
                    }
                } else if previous >= level.threshold && percent < level.threshold {
                    // Re-arm: the level may fire again on the next upward crossing.
                    fired.remove(key)
                }
            }
        }
        lastPercent = current

        // At most one sound per refresh tick, for the most severe crossing.
        let best = candidates.reduce(into: nil as (kind: ProviderKind, level: Level)?) { best, candidate in
            if best == nil || candidate.level.rawValue > best!.level.rawValue { best = candidate }
        }
        guard let best else { return }
        play(level: best.level)
    }

    /// Called when thresholds change in Settings so every level can fire again.
    func settingsDidChange() {
        fired.removeAll()
    }

    // MARK: Mute

    var isMuted: Bool {
        mutedUntil > Date().timeIntervalSince1970
    }

    func mute(untilInterval interval: Double) {
        UserDefaults.standard.set(interval, forKey: Self.mutedUntilKey)
    }

    func clearMute() {
        UserDefaults.standard.set(0, forKey: Self.mutedUntilKey)
    }

    private var mutedUntil: Double {
        UserDefaults.standard.object(forKey: Self.mutedUntilKey) as? Double ?? 0
    }

    // MARK: Playback

    private func play(level: Level) {
        guard
            UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false,
            UserDefaults.standard.object(forKey: level.enabledKey) as? Bool ?? true,
            isSessionActive,
            !isMuted,
            let sound = Self.makeSound()
        else { return }
        sound.volume = Float(Self.configuredVolume)
        sound.play()
        playingSound = sound
    }

    /// Plays the currently selected sound (system or custom) at the configured volume,
    /// for the Settings "Test" button.
    static func playTestSound() {
        guard let sound = makeSound() else { return }
        sound.volume = Float(configuredVolume)
        sound.play()
        testSound = sound
    }

    /// Retained so async playback isn't cut short by deallocation.
    private static var testSound: NSSound?

    private static var configuredVolume: Double {
        min(max(UserDefaults.standard.object(forKey: volumeKey) as? Double ?? 1.0, 0), 1)
    }

    /// The configured sound, or "Glass" when the custom file is missing or unreadable.
    private static func makeSound() -> NSSound? {
        let name = UserDefaults.standard.string(forKey: soundNameKey) ?? systemSoundNames[0]
        if name == customName, let url = existingCustomSoundURL() {
            return NSSound(contentsOf: url, byReference: false)
        }
        return NSSound(named: NSSound.Name(name == customName ? systemSoundNames[0] : name))
            ?? NSSound(named: systemSoundNames[0])
    }

    // MARK: Custom sound file

    static var customSoundDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Metria/Sounds", isDirectory: true)
    }

    static func existingCustomSoundURL() -> URL? {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: customSoundDirectory, includingPropertiesForKeys: nil)
        return contents?.first { $0.lastPathComponent.hasPrefix("custom-alert.") }
    }

    /// Copies the picked file to Application Support as `custom-alert.<original extension>`,
    /// replacing any previously imported custom sound. Returns success.
    @discardableResult
    static func importCustomSound(from url: URL) -> Bool {
        do {
            let directory = customSoundDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for existing in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
            where existing.lastPathComponent.hasPrefix("custom-alert.") {
                try? FileManager.default.removeItem(at: existing)
            }
            let destination = directory.appendingPathComponent("custom-alert.\(url.pathExtension)")
            // The cleanup loop above already removed same-named files; a leftover can only
            // exist if that removal failed silently, so tolerate its absence here.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            return true
        } catch {
            return false
        }
    }
}
