import Foundation

/// svc31, smartglasses_settings: write-only. Type 2 SettingsSyncData carries one field; type 3 SettingsAck answers
/// with status 2 whatever happened, so a write is settled only by reading it back on svc33. Port of Visor's
/// `GlassesSettings.kt`, `SettingSpec.kt` and the curated rows of its settings screen.
public enum SettingsService {
    public static let serviceId = 31
    public static let syncData = 2
    public static let ack = 3
}

// MARK: - Values

/// A setting's value as the web UI sees it: a plain JSON scalar.
public enum SettingRaw: Codable, Equatable, CustomStringConvertible {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(SettingRaw.self, .init(codingPath: decoder.codingPath, debugDescription: "expected a bool, number or string"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        }
    }

    public var description: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return SettingText.number(d)
        case .string(let s): return s
        }
    }
}

/// The wire kind of a key in the firmware's tables (`settings.tsv`).
enum SettingWireKind { case bool, int, str, float }

/// Where a key lives and how svc31 takes it.
struct SettingWire {
    let field: Int?
    let kind: SettingWireKind
    /// The firmware schema default, as RLDrive text.
    let defaultText: String
    /// The RLDrive namespace before device scoping.
    let namespace: String
    /// This firmware's settings service has a handler for the field.
    let parsed: Bool

    /// No svc31 field, or one this firmware drops: written as a kv object into RLDrive instead.
    var viaDrive: Bool { field == nil || !parsed }
}

/// Text as RLDrive keeps it, and the comparisons a read back needs.
enum SettingText {
    static func asBool(_ text: String?) -> Bool { ["true", "1"].contains(text?.trimmingCharacters(in: .whitespaces).lowercased() ?? "") }

    /// As Visor's `number()`: whole numbers without a point, the rest to two places, trailing zeros cut.
    static func number(_ x: Double) -> String {
        if x == x.rounded(.down), abs(x) < 1e15 { return String(Int64(x)) }
        var s = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func text(_ value: SettingRaw, _ kind: SettingWireKind) -> String {
        switch (value, kind) {
        case (.bool(let b), .int): return b ? "1" : "0"
        case (.bool(let b), _): return b ? "true" : "false"
        case (.int(let i), .float): return number(Double(i))
        case (.int(let i), _): return String(i)
        case (.double(let d), _): return number(d)
        case (.string(let s), _): return s
        }
    }

    /// True when the stored `have` means the same as `want`, compared by kind.
    static func same(_ kind: SettingWireKind, _ have: String?, _ want: String) -> Bool {
        guard let have else { return false }
        let h = have.trimmingCharacters(in: .whitespaces), w = want.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .bool: return asBool(have) == asBool(want)
        case .int: return Int64(h) != nil && Int64(h) == Int64(w)
        case .float: return Double(h) != nil && Double(h) == Double(w)
        case .str: return have == want
        }
    }
}

// MARK: - Catalogue

public struct SettingOption: Encodable, Equatable {
    public let value: SettingRaw
    public let label: String
}

/// One user-facing setting, as the web UI shows it.
public struct SettingDescriptor: Encodable {
    public let key: String
    public let label: String
    public let help: String?
    public let category: String
    /// "bool", "int", "double", "enum" or "string".
    public let kind: String
    public let options: [SettingOption]?
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let unit: String?
    /// For "string": the longest value accepted, in characters.
    public let maxLength: Int?
    /// The firmware default, shown while the glasses hold nothing for the key.
    public let defaultValue: SettingRaw?
    public let writable: Bool

    let wire: SettingWire

    enum CodingKeys: String, CodingKey {
        case key, label, help, category, kind, options, min, max, step, unit, maxLength, writable
        case defaultValue = "default"
    }

    /// RLDrive text read as this setting's value; text that does not parse comes back as a string.
    func value(fromText text: String) -> SettingRaw {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch wire.kind {
        case .bool: return .bool(SettingText.asBool(text))
        case .int:
            if kind == "bool" { return .bool(SettingText.asBool(text)) }
            return Int64(t).map(SettingRaw.int) ?? .string(text)
        case .float: return Double(t).map(SettingRaw.double) ?? .string(text)
        case .str: return .string(text)
        }
    }
}

public enum SettingsCatalog {
    /// The model the rows and options are chosen for: Ray-Ban Meta Gen 2 (greathammerhead). Rows the Meta app keeps for
    /// other models (touchpad lock, listen while recording, auto review) are left out.
    public static let product = 266

    /// The settings worth showing, in display order.
    public static let all: [SettingDescriptor] = assistant + notifications + controls + audio + camera + privacy + system

    public static let byKey: [String: SettingDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    public static func descriptor(_ key: String) -> SettingDescriptor? { byKey[key] }

    // MARK: rows

    private static let ind = "individual_device_settings"
    private static let local = "local_device_settings"
    private static let shared = "shared_settings_namespace_1"

    private static func w(_ field: Int?, _ kind: SettingWireKind, _ def: String, _ ns: String, parsed: Bool) -> SettingWire {
        SettingWire(field: field, kind: kind, defaultText: def, namespace: ns, parsed: parsed)
    }

    private static func make(
        _ key: String, _ label: String, _ help: String?, _ category: String, kind: String, _ wire: SettingWire,
        options: [SettingOption]? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil, unit: String? = nil,
        maxLength: Int? = nil, writable: Bool
    ) -> SettingDescriptor {
        let d = SettingDescriptor(
            key: key, label: label, help: help, category: category, kind: kind, options: options, min: min, max: max, step: step,
            unit: unit, maxLength: maxLength, defaultValue: nil, writable: writable, wire: wire
        )
        let def: SettingRaw? = wire.defaultText.isEmpty && wire.kind != .str ? nil : d.value(fromText: wire.defaultText)
        return SettingDescriptor(
            key: key, label: label, help: help, category: category, kind: kind, options: options, min: min, max: max, step: step,
            unit: unit, maxLength: maxLength, defaultValue: def, writable: writable, wire: wire
        )
    }

    private static func toggle(_ key: String, _ label: String, _ help: String?, _ category: String, _ wire: SettingWire, writable: Bool = true) -> SettingDescriptor {
        make(key, label, help, category, kind: "bool", wire, writable: writable)
    }

    private static func choice(_ key: String, _ label: String, _ help: String?, _ category: String, _ wire: SettingWire, _ options: [(Int64, String)], writable: Bool = true) -> SettingDescriptor {
        make(key, label, help, category, kind: "enum", wire, options: options.map { SettingOption(value: .int($0.0), label: $0.1) }, writable: writable)
    }

    private static func choice(_ key: String, _ label: String, _ help: String?, _ category: String, _ wire: SettingWire, _ options: [(String, String)], writable: Bool = true) -> SettingDescriptor {
        make(key, label, help, category, kind: "enum", wire, options: options.map { SettingOption(value: .string($0.0), label: $0.1) }, writable: writable)
    }

    private static let assistant: [SettingDescriptor] = {
        let c = "Assistant"
        return [
            toggle("assistant_enabled", "Meta AI", "Active ou désactive l'assistant Meta AI sur les lunettes.", c, w(2, .bool, "false", ind, parsed: true)),
            toggle("wakeword_enabled", "« Hey Meta »", "Dites « Hey Meta » pour lancer une commande vocale.", c, w(36, .bool, "true", ind, parsed: true)),
            toggle("wakeword_sound_enabled", "Son d'activation", "Les lunettes émettent un son après « Hey Meta ».", c, w(37, .bool, "true", ind, parsed: true)),
            toggle("assistant_follow_up_enabled", "Répondre sans « Hey Meta »", "Le micro reste ouvert un court instant après une réponse pour une autre question.", c, w(52, .bool, "true", ind, parsed: true)),
            toggle("natural_invocation_enabled", "Parler sans mot d'activation", "Permet de parler à l'assistant sans dire « Hey Meta » d'abord.", c, w(74, .bool, "false", ind, parsed: true)),
            toggle("cloud_ai_understanding_enabled", "Photo pour Meta AI", "Quand vous parlez à Meta AI, une photo peut être prise pour répondre.", c, w(39, .bool, "true", ind, parsed: true)),
            toggle("live_ai_enabled", "Live AI", "Active ou désactive Live AI.", c, w(93, .bool, "false", ind, parsed: true)),
            toggle("detailed_responses_live_ai_enabled", "Réponses Live AI détaillées", "Live AI donne des réponses plus complètes.", c, w(154, .bool, "false", ind, parsed: true)),
            toggle("live_ai_voice_only", "Live AI en vocal seulement", "Live AI répond à la voix, sans utiliser la caméra.", c, w(107, .bool, "false", ind, parsed: true)),
            toggle("blv_scene_reader_enabled", "Descriptions détaillées", "Décrit davantage les objets, panneaux et personnes. Ne remplace pas une aide à la mobilité.", c, w(89, .bool, "false", ind, parsed: true)),
            choice("tts_speak_speed", "Vitesse de la voix", "La vitesse à laquelle les lunettes parlent.", c, w(43, .int, "100", ind, parsed: true),
                   [(75, "0,75×"), (100, "1× (normale)"), (125, "1,25×"), (150, "1,5×"), (175, "1,75×")]),
        ]
    }()

    private static let notifications: [SettingDescriptor] = {
        let c = "Notifications"
        return [
            toggle("sg_do_not_disturb", "Ne pas déranger", "Coupe la sonnerie des appels sur les lunettes.", c, w(nil, .bool, "false", local, parsed: false)),
            toggle("attention_deferral_user_enabled", "Moins d'interruptions", "Attend que vous ayez fini de parler pour lire une notification.", c, w(231, .bool, "false", ind, parsed: false)),
            choice("notification_led_brightness", "Luminosité du voyant", "Luminosité du voyant de notification.", c, w(14, .int, "3", ind, parsed: true),
                   [(1, "Automatique"), (2, "Faible"), (3, "Moyenne"), (4, "Élevée")]),
            toggle("smart_reply_enabled", "Réponses suggérées", "Propose des réponses rapides selon la conversation.", c, w(165, .bool, "true", ind, parsed: false)),
            toggle("user_setup_ica_toggle_enabled", "Annoncer les appels", "Les lunettes disent qui vous appelle.", c, w(176, .bool, "false", ind, parsed: true)),
            choice("mute_announcements_default_duration", "Durée de pause des annonces", "Durée par défaut quand vous mettez les annonces en pause.", c, w(90, .int, "3600", ind, parsed: true),
                   [(3600, "1 heure"), (7200, "2 heures"), (14400, "4 heures"), (28800, "8 heures")]),
            toggle("enable_calendar_event_alert", "Alertes d'agenda", "Prévient des événements à venir de votre agenda.", c, w(133, .bool, "false", shared, parsed: true)),
            toggle("enable_calendar_event_alert_announce_details", "Lire les détails des événements", "Lit à voix haute les détails de l'événement.", c, w(167, .bool, "false", ind, parsed: false)),
        ]
    }()

    private static let controls: [SettingDescriptor] = {
        let c = "Commandes"
        // Which physical control the "action button" is on Gen 2 is unconfirmed, so its mapping is shown, not changed.
        let actions: [(Int64, String)] = [
            (1, "Aucune"), (2, "Meta AI"), (4, "Photo ou vidéo"), (5, "Appeler"), (6, "Requête Meta AI personnalisée"), (7, "Live AI"),
            (11, "Capture automatique"), (13, "Traduction en direct"), (20, "Couper ou réactiver le micro"), (21, "Musique"),
        ]
        return [
            choice("capture_button_short_long_press", "Bouton de capture", "Photo d'abord : un appui prend une photo, un appui long filme. Vidéo d'abord : l'inverse.", c,
                   w(7, .int, "0", ind, parsed: true), [(0, "Photo d'abord"), (1, "Vidéo d'abord")]),
            choice("capture_mode", "Autre mode de capture", "Le mode de capture supplémentaire proposé par le bouton.", c, w(105, .int, "3", ind, parsed: true),
                   [(3, "Hyperlapse"), (6, "Ralenti"), (5, "Capture automatique")]),
            choice("tap_and_hold_mapping", "Appui long sur le pavé tactile", "Ce que fait un appui prolongé sur la branche.", c, w(29, .int, "2", ind, parsed: true),
                   [(1, "Rien"), (2, "Meta AI"), (3, "Spotify Tap"), (4, "Amazon Music"), (5, "Apple Music"), (7, "Mise au point sur la conversation"),
                    (8, "Actions rapides"), (10, "Requête Meta AI personnalisée"), (11, "Live AI"), (12, "Be My Eyes"), (13, "Traduction en direct"), (19, "Musique")]),
            choice("quick_actions", "Action rapide", "Ce que fait l'action rapide : un message, un message vocal ou un appel.", c, w(106, .str, "", ind, parsed: true),
                   [("text", "Message"), ("voice", "Message vocal"), ("call", "Appel")]),
            make("action_button_assistant_custom_prompt", "Requête personnalisée", "Le texte envoyé à Meta AI par le raccourci de requête personnalisée.", c,
                 kind: "string", w(110, .str, "what is the weather", ind, parsed: true), maxLength: 100, writable: true),
            toggle("sg_captouch_invert_swipe_direction_horizontal", "Inverser le balayage avant/arrière", "Inverse le sens des balayages horizontaux sur le pavé tactile.", c, w(nil, .bool, "false", ind, parsed: false)),
            toggle("sg_captouch_invert_swipe_direction_vertical", "Inverser le balayage haut/bas", "Inverse le sens des balayages verticaux sur le pavé tactile.", c, w(nil, .bool, "false", ind, parsed: false)),
            toggle("spotify_tap_enabled", "Spotify Tap", "Un appui prolongé lance Spotify.", c, w(3, .bool, "false", ind, parsed: true)),
            choice("assignable_action_button_short_press_mapping", "Bouton d'action (appui)", "Lecture seule : sur ce modèle, on ne sait pas quel bouton cela concerne.", c,
                   w(101, .int, "4", ind, parsed: true), actions, writable: false),
            choice("assignable_action_button_long_press_mapping", "Bouton d'action (appui long)", "Lecture seule : sur ce modèle, on ne sait pas quel bouton cela concerne.", c,
                   w(102, .int, "0", ind, parsed: true), actions, writable: false),
        ]
    }()

    private static let audio: [SettingDescriptor] = {
        let c = "Audio"
        return [
            make("notification_volume", "Volume des notifications", "Niveau des sons de notification.", c, kind: "int", w(5, .int, "90", ind, parsed: true),
                 min: 55, max: 127, step: 1, unit: "", writable: true),
            make("audio_balance", "Balance gauche/droite", "Répartition du son entre les haut-parleurs gauche (-1) et droit (1).", c, kind: "double",
                 w(225, .float, "0.0", ind, parsed: true), min: -1, max: 1, step: 0.2, unit: "", writable: true),
            toggle("avc_enabled", "Volume adaptatif", "Ajuste le volume selon le bruit ambiant.", c, w(80, .bool, "false", ind, parsed: true)),
            toggle("mono_audio_enabled", "Audio mono", "Le même son dans les deux haut-parleurs.", c, w(228, .bool, "false", ind, parsed: true)),
            choice("spatial_media_enabled", "Son spatial", "Musique et vidéos en stéréo ou en son immersif.", c, w(158, .int, "0", ind, parsed: true),
                   [(0, "Stéréo"), (1, "Spatial")]),
            toggle("leak_crusher_enabled", "Audio discret", "Limite le son entendu par les personnes autour de vous.", c, w(160, .bool, "false", ind, parsed: true)),
            choice("leak_crusher_intensity", "Niveau d'audio discret", "Plus le niveau est haut, moins le son s'entend autour de vous.", c, w(161, .int, "2", ind, parsed: true),
                   [(0, "1"), (1, "2"), (2, "3"), (3, "4"), (4, "5")]),
            toggle("sg_headphone_mode_enabled", "Mode casque", "Passe le son des lunettes en mode casque.", c, w(nil, .bool, "false", ind, parsed: false)),
            toggle("auto_play_pause_on_don_doff", "Pause quand on retire les lunettes", "Met la musique en pause quand vous enlevez les lunettes.", c, w(6, .bool, "true", ind, parsed: true)),
        ]
    }()

    private static let camera: [SettingDescriptor] = {
        let c = "Caméra"
        return [
            choice("resolution_and_framerate", "Résolution vidéo", "Plus de qualité réduit l'autonomie, l'espace libre et la durée d'enregistrement.", c,
                   w(109, .int, "0", ind, parsed: true), [(0, "Standard (1080p, 30 i/s)"), (2, "Fluide (1080p, 60 i/s)"), (1, "Haute résolution (3K, 30 i/s)")]),
            choice("video_duration_ms", "Durée maximale des vidéos", "5 minutes seulement en résolution standard.", c, w(17, .int, "180000", ind, parsed: true),
                   [(30000, "30 secondes"), (60000, "1 minute"), (180000, "3 minutes"), (300000, "5 minutes"), (600000, "10 minutes")]),
            choice("eis_mode", "Stabilisation vidéo", "Le niveau de stabilisation des vidéos.", c, w(108, .int, "2", ind, parsed: true),
                   [(0, "Automatique"), (1, "Forte"), (2, "Moyenne"), (3, "Faible")]),
            choice("capture_aspect_ratio", "Orientation des photos et vidéos", "Portrait (3:4) ou paysage (4:3).", c, w(252, .int, "0", ind, parsed: false),
                   [(0, "Portrait"), (1, "Paysage")]),
            toggle("quick_clips_photo_capture_enabled", "Photo dynamique", "Prend plusieurs images à chaque photo pour choisir la meilleure.", c, w(100, .bool, "false", ind, parsed: true)),
            toggle("media_auto_leveling_enabled", "Mise à niveau automatique", "Redresse automatiquement les photos et vidéos.", c, w(151, .bool, "false", ind, parsed: false)),
            toggle("media_occlusion_removal_enabled", "Recadrage des obstacles", "Recadre quand une casquette ou des cheveux cachent une partie de l'image.", c, w(152, .bool, "false", ind, parsed: false)),
            toggle("music_concurrency_enabled", "Musique pendant l'enregistrement", "La musique continue pendant une vidéo et peut être enregistrée.", c, w(183, .bool, "false", ind, parsed: true)),
            toggle("motion_blur_reduction_enabled", "Réduction du flou de mouvement", "Réduit le flou dans les vidéos.", c, w(220, .bool, "true", ind, parsed: true)),
            toggle("occlusion_detection_enabled", "Détection d'objectif masqué", "Prévient quand quelque chose cache la caméra.", c, w(12, .bool, "true", ind, parsed: true)),
        ]
    }()

    private static let privacy: [SettingDescriptor] = {
        let c = "Confidentialité"
        let readOnly = "Lecture seule ici : ce réglage touche au déverrouillage ou à la sécurité."
        return [
            toggle("location_global_enabled", "Localisation", "Autorise la localisation pour les lunettes.", c, w(15, .bool, "false", ind, parsed: false)),
            toggle("location_chatbot_enabled", "Localisation pour Meta AI", "Meta AI peut utiliser la position du téléphone pour répondre.", c, w(35, .bool, "false", ind, parsed: false)),
            toggle("assistant_store_voice_recordings", "Conserver les enregistrements vocaux", "Meta garde l'audio de ce que vous dites à Meta AI.", c, w(10, .bool, "true", ind, parsed: true)),
            toggle("assistant_store_voice_transcripts", "Conserver les transcriptions", "Meta garde le texte de ce que vous dites à Meta AI.", c, w(9, .bool, "true", ind, parsed: true)),
            toggle("cloud_media_processing_enabled", "Traitement des médias dans le cloud", "Vos photos et vidéos peuvent être envoyées au cloud de Meta pour être traitées.", c, w(56, .bool, "false", shared, parsed: true)),
            toggle("device_share_additional_data_enabled", "Partager des données supplémentaires", "Envoie à Meta plus de données d'utilisation que le strict nécessaire.", c, w(79, .bool, "false", ind, parsed: true)),
            toggle("media_cloud_enabled", "Fonctions cloud pour les médias", "Lecture seule : effet mal connu.", c, w(32, .bool, "false", ind, parsed: false), writable: false),
            toggle("passive_visual_capture_enabled", "Capture visuelle passive", "Lecture seule : effet mal connu.", c, w(187, .bool, "true", ind, parsed: true), writable: false),
            toggle("passive_phone_unlock_enabled", "Déverrouillage passif du téléphone", readOnly, c, w(51, .bool, "false", ind, parsed: true), writable: false),
            toggle("verified_session_enabled", "Sessions vérifiées", readOnly, c, w(8, .bool, "false", ind, parsed: true), writable: false),
        ]
    }()

    private static let system: [SettingDescriptor] = {
        let c = "Système"
        return [
            toggle("wear_detection_enabled", "Détection du port", "Met les fonctions en pause quand vous retirez les lunettes.", c, w(38, .bool, "true", ind, parsed: true)),
            toggle("cloud_ota_enabled", "Mises à jour automatiques", "Lecture seule : les mises à jour du logiciel ne se changent pas ici.", c, w(19, .bool, "false", shared, parsed: true), writable: false),
        ]
    }()
}

// MARK: - Errors

public enum SettingsError: Error, CustomStringConvertible, Equatable {
    case unknownKey(String)
    case readOnly(String)
    case wrongType(key: String, expected: String)
    case invalidValue(key: String, reason: String)
    case noDeviceUuid
    case noAnswer(String)
    case notApplied(key: String, stored: String?)

    public var description: String {
        switch self {
        case .unknownKey(let k): return "\(k) is not in the settings catalogue"
        case .readOnly(let k): return "\(k) is read-only"
        case .wrongType(let k, let e): return "\(k) takes a \(e)"
        case .invalidValue(let k, let r): return "\(k): \(r)"
        case .noDeviceUuid: return "the glasses did not give their device id, so their settings cannot be found"
        case .noAnswer(let what): return "the glasses did not answer \(what)"
        case .notApplied(let k, let s): return "the glasses kept \(k) at \(s ?? "its default")"
        }
    }
}

// MARK: - Encoding and checks

extension SettingDescriptor {
    /// The value checked against the kind, options and bounds, and normalized (an int for a double setting becomes a double).
    func validate(_ value: SettingRaw) throws -> SettingRaw {
        switch kind {
        case "bool":
            guard case .bool = value else { throw SettingsError.wrongType(key: key, expected: "bool") }
            return value
        case "enum":
            guard let options, options.contains(where: { $0.value == value }) else {
                throw SettingsError.invalidValue(key: key, reason: "\(value) is not one of the options")
            }
            return value
        case "int":
            guard case .int(let i) = value else { throw SettingsError.wrongType(key: key, expected: "int") }
            let x = Double(i)
            if let min, x < min { throw SettingsError.invalidValue(key: key, reason: "\(i) is below \(SettingText.number(min))") }
            if let max, x > max { throw SettingsError.invalidValue(key: key, reason: "\(i) is above \(SettingText.number(max))") }
            if let step, step > 0, (x - (min ?? 0)).truncatingRemainder(dividingBy: step) != 0 {
                throw SettingsError.invalidValue(key: key, reason: "\(i) is not on a step of \(SettingText.number(step))")
            }
            return value
        case "double":
            let x: Double
            switch value {
            case .double(let d): x = d
            case .int(let i): x = Double(i)
            default: throw SettingsError.wrongType(key: key, expected: "number")
            }
            guard x.isFinite else { throw SettingsError.invalidValue(key: key, reason: "not a finite number") }
            if let min, x < min - 1e-9 { throw SettingsError.invalidValue(key: key, reason: "\(x) is below \(SettingText.number(min))") }
            if let max, x > max + 1e-9 { throw SettingsError.invalidValue(key: key, reason: "\(x) is above \(SettingText.number(max))") }
            if let step, step > 0 {
                let n = (x - (min ?? 0)) / step
                guard abs(n - n.rounded()) < 1e-6 else { throw SettingsError.invalidValue(key: key, reason: "\(x) is not on a step of \(SettingText.number(step))") }
                // Snap to the step, so 0.6000000001 goes out as 0.6.
                return .double((((min ?? 0) + n.rounded() * step) * 1e6).rounded() / 1e6)
            }
            return .double(x)
        case "string":
            guard case .string(let s) = value else { throw SettingsError.wrongType(key: key, expected: "string") }
            if let maxLength, s.count > maxLength { throw SettingsError.invalidValue(key: key, reason: "longer than \(maxLength) characters") }
            if s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw SettingsError.invalidValue(key: key, reason: "control characters are not allowed")
            }
            return value
        default:
            throw SettingsError.readOnly(key)
        }
    }

    /// SettingsSyncData with one field, as Visor's `encodeWrite` builds it. Nil for a key with no svc31 field.
    func svc31Payload(_ value: SettingRaw) -> [UInt8]? {
        guard let field = wire.field else { return nil }
        switch (wire.kind, value) {
        case (.bool, .bool(let b)), (.int, .bool(let b)):
            return Wire.fieldVarint(field, b ? 1 : 0)
        case (.int, .int(let i)):
            // Unsigned on the wire, so a negative int goes out as the ten-byte two's complement.
            return Wire.fieldVarint(field, UInt64(bitPattern: i))
        case (.str, .string(let s)):
            return Wire.fieldString(field, s)
        case (.float, .double(let d)):
            // SettingsSyncData keeps these as double: fixed64, wire type 1, little-endian. The glasses drop fixed32.
            return Wire.varint((UInt64(field) << 3) | 1) + withUnsafeBytes(of: d.bitPattern.littleEndian) { Array($0) }
        case (.float, .int(let i)):
            return svc31Payload(.double(Double(i)))
        default:
            return nil
        }
    }

    func text(_ value: SettingRaw) -> String { SettingText.text(value, wire.kind) }
}

/// Check a write without the glasses: the key must be in the catalogue and writable, and the value must fit.
/// Returns the descriptor and the value to send.
func checkSettingWrite(_ key: String, _ value: SettingRaw) throws -> (SettingDescriptor, SettingRaw) {
    guard let d = SettingsCatalog.byKey[key] else { throw SettingsError.unknownKey(key) }
    guard d.writable else { throw SettingsError.readOnly(key) }
    let v = try d.validate(value)
    if !d.wire.viaDrive, d.svc31Payload(v) == nil { throw SettingsError.wrongType(key: key, expected: d.kind) }
    return (d, v)
}

/// A value for a key outside the catalogue, guessed from its text.
func guessSetting(_ text: String) -> SettingRaw {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t == "true" { return .bool(true) }
    if t == "false" { return .bool(false) }
    if let i = Int64(t) { return .int(i) }
    if t.contains("."), let d = Double(t), d.isFinite { return .double(d) }
    return .string(text)
}

// MARK: - Session

extension GlassesSession {
    /// The namespaces to read for `keys`: all four, or those the keys live in.
    private func settingsNamespaces(_ keys: [String]?, deviceUuid: String) -> [String] {
        let all = RlDrive.scopedNamespaces + RlDrive.deviceNamespaces
        var bases: [String] = all
        if let keys {
            let known = keys.map { SettingsCatalog.byKey[$0]?.wire.namespace }
            if !known.contains(where: { $0 == nil }) { bases = all.filter { b in known.contains { $0 == b } } }
        }
        return bases.map { RlDrive.namespace($0, deviceUuid: deviceUuid) }
    }

    private func settingsDeviceUuid(_ given: String?, timeout: TimeInterval) async throws -> String {
        if let given, !given.isEmpty { return given }
        let uuid = try await peerDeviceInfo(timeout: timeout).deviceUuid
        guard !uuid.isEmpty else { throw SettingsError.noDeviceUuid }
        return uuid
    }

    /// Every kv the glasses hold in `namespaces`, merged. Throws when a namespace never answered.
    private func readStored(_ namespaces: [String], push: [String: [DrivePush]] = [:], timeout: TimeInterval) async throws -> [String: String] {
        let reads = try await driveSync(namespaces, push: push, timeout: timeout)
        let silent = namespaces.filter { reads[$0]?.answered != true }
        if !silent.isEmpty { throw SettingsError.noAnswer("the settings read of \(silent.joined(separator: ", "))") }
        var stored: [String: String] = [:]
        for namespace in namespaces { stored.merge(reads[namespace]?.kv ?? [:]) { _, new in new } }
        return stored
    }

    /// Read settings on svc33 (RLDrive, message type 1, rounds 0 to 3 per namespace). With `keys` nil, every catalogue
    /// key; a key the glasses hold nothing for comes back as its firmware default. A requested key outside the
    /// catalogue comes back only when stored, its type guessed from the text.
    /// `deviceUuid` names the scoped namespaces; when nil it is asked for on svc100 first.
    public func readSettings(keys: [String]? = nil, deviceUuid: String? = nil, timeout: TimeInterval) async throws -> [String: SettingRaw] {
        try await driveGate.withLock {
            let uuid = try await settingsDeviceUuid(deviceUuid, timeout: timeout)
            let stored = try await readStored(settingsNamespaces(keys, deviceUuid: uuid), timeout: timeout)
            var out: [String: SettingRaw] = [:]
            for key in keys ?? SettingsCatalog.all.map(\.key) {
                if let d = SettingsCatalog.byKey[key] {
                    if let text = stored[key] { out[key] = d.value(fromText: text) } else if let def = d.defaultValue { out[key] = def }
                } else if let text = stored[key] {
                    out[key] = guessSetting(text)
                }
            }
            return out
        }
    }

    /// Write one catalogue setting. Refuses, before sending anything, a key not in the catalogue, a read-only one, and a
    /// value of the wrong type or out of range. A key with a parsed svc31 field goes out on svc31 type 2 and waits for
    /// the type 3 ack; the rest go as a kv object in round 2 of an svc33 sync. Either way the value is then read back
    /// on svc33, and an svc31 write the glasses did not apply is sent once more through RLDrive, as Visor does.
    /// `timeout` bounds each exchange with the glasses.
    public func writeSetting(_ key: String, _ value: SettingRaw, deviceUuid: String? = nil, timeout: TimeInterval) async throws {
        let (d, v) = try checkSettingWrite(key, value)
        let want = d.text(v)
        try await driveGate.withLock {
            let uuid = try await settingsDeviceUuid(deviceUuid, timeout: timeout)
            let namespace = RlDrive.namespace(d.wire.namespace, deviceUuid: uuid)

            func readBack() async throws -> String? { try await readStored([namespace], timeout: timeout)[key] }
            func settled(_ have: String?) -> Bool { SettingText.same(d.wire.kind, have ?? d.wire.defaultText, want) }

            if !d.wire.viaDrive, let payload = d.svc31Payload(v) {
                let started = Date()
                _ = try await request(service: SettingsService.serviceId, type: SettingsService.syncData, payload: payload,
                                      expect: [SettingsService.ack], timeout: timeout)
                // The ack is always SUCCESS. Give the settings service the time Visor does to store the value.
                while true {
                    if settled(try await readBack()) { return }
                    if Date().timeIntervalSince(started) > settleSeconds { break }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                log?("svc31 left \(key) as it was; writing it into RLDrive")
            }
            _ = try await readStored([namespace], push: [namespace: [.kv(key, want)]], timeout: timeout)
            let have = try await readBack()
            if !settled(have) { throw SettingsError.notApplied(key: key, stored: have) }
        }
    }
}

/// How long an svc31 write may take to show in RLDrive before it counts as not applied.
private let settleSeconds: TimeInterval = 3
