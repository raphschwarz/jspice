// A rules file checked as KiCad's Board Setup checks one (KiCad 10.0.7: pcbnew/dialogs/panel_setup_rules.cpp,
// PANEL_SETUP_RULES::OnCompile and checkPlausibility: the text's variables expanded, DRC_RULES_PARSER::Parse with a
// reporter, a PARSE_ERROR said at its place, then the rules' shared conditions, undefined net classes and layers;
// common/common.cpp, ExpandTextVars). GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

public enum DesignRulesCheck {
    /// What KiCad's "Check rule syntax" says of `text`, a .kicad_dru (for `board`, its layers and their names, and its
    /// project, its net classes and text variables): each error with the line and column its link goes to, in the
    /// order KiCad finds them, then its warnings; "No errors found." if the parser said nothing
    public static func check(_ text: String, board: KiCadBoard? = nil, project: [String: Any]? = nil) -> [RulesMessage] {
        let expanded = expandTextVariables(text, project: project)
        var parser = DesignRulesParser(expanded, reporting: true)
        for entry in board?.root["layers"]?.arguments ?? [] {
            guard let name = entry.text(at: 0), let id = KiLayer.id(name), let user = entry.text(at: 2), !user.isEmpty else { continue }
            parser.userLayerNames[id] = user
        }
        var rules: [DesignRule] = []
        var messages: [RulesMessage] = []
        do {
            rules = try parser.parse()
            messages = parser.messages ?? []
        } catch let e as RulesError {
            // (the lexer's PARSE_ERROR, an unterminated string: said where it is, after what the parser said)
            messages = (parser.messages ?? []) + [RulesMessage(.error, e.message, line: e.line, column: e.offset)]
        } catch {
            messages = parser.messages ?? []
        }
        return messages + plausibility(rules, board: board, project: project)
    }

    /// checkPlausibility: rules of the same condition and layers, conditions of net classes the project has not,
    /// layers the board has not
    static func plausibility(_ rules: [DesignRule], board: KiCadBoard?, project: [String: Any]?) -> [RulesMessage] {
        var out: [RulesMessage] = []
        var seen: [String: String] = [:]
        let classes = Set((((project?["net_settings"] as? [String: Any])?["classes"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
        let pattern = try? NSRegularExpression(pattern: #"NetClass\s*[!=]=\s*'"?([^"\s]+)'"?"#)
        let table = board?.root["layers"]?.arguments ?? []
        let enabled = KiLayerSet(table.compactMap { $0.text(at: 0).flatMap(KiLayer.id) })
        var names: [Int: String] = [:]
        for entry in table {
            guard let name = entry.text(at: 0), let id = KiLayer.id(name) else { continue }
            names[id] = entry.text(at: 2).flatMap { $0.isEmpty ? nil : $0 } ?? name
        }
        for rule in rules {
            let condition = (rule.condition?.expression ?? "").trimmingCharacters(in: .whitespaces)
            let key = condition + "\u{1}" + rule.layerSource
            if let other = seen[key] {
                out.append(RulesMessage(.warning, "Rules '\(rule.name)' and '\(other)' share the same condition."))
            } else {
                seen[key] = rule.name
            }
            let ns = condition as NSString
            for m in pattern?.matches(in: condition, range: NSRange(location: 0, length: ns.length)) ?? [] {
                let name = ns.substring(with: m.range(at: 1))
                if name != "Default" && !classes.contains(name) {
                    out.append(RulesMessage(.warning, "Rule '\(rule.name)' references undefined netclass '\(name)'."))
                }
            }
            let source = rule.layerSource.lowercased()
            if board != nil, !rule.layerSource.isEmpty, source != "'inner'", source != "'outer'" {
                let invalid = (0..<KiLayer.count).filter { rule.layerCondition.contains($0) && !enabled.contains($0) }
                if !invalid.isEmpty {
                    let bad = invalid.map { names[$0] ?? KiLayer.name($0) }.joined(separator: ", ")
                    out.append(RulesMessage(.warning, "Rule '\(rule.name)' references undefined layer(s): \(bad)."))
                }
            }
        }
        return out
    }

    /// ExpandTextVars with the project's text variables: each ${NAME} it has replaced, the others (and a component
    /// class's ${CLASS:...}) left
    static func expandTextVariables(_ text: String, project: [String: Any]?) -> String {
        guard let vars = project?["text_variables"] as? [String: Any], !vars.isEmpty, text.contains("${") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "${") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let name = String(rest[open.upperBound..<close])
            if let value = vars[name] as? String, !name.uppercased().hasPrefix("CLASS:") {
                out += value
            } else {
                out += rest[open.lowerBound...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
