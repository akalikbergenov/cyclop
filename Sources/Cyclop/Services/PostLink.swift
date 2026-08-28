import Foundation

/// A link to one post on X, recognised in copied text.
///
/// Everything the panel knows about a post is parsed from the URL itself —
/// the author's handle and the status id both live in the path — because
/// asking x.com for more would be a network request, and the project promises
/// not to make any. What a link cannot carry, the feature does without.
struct PostLink: Equatable {
    /// Author handle from the path, without the `@`. Absent on the
    /// `/i/status/…` forms, where X does not name the author in the URL.
    let handle: String?
    let statusID: String

    /// One spelling per post, whatever spelling was copied: tracking
    /// parameters dropped, `twitter.com` renamed, `/photo/1` trimmed. The id
    /// is the identity, but the stored URL should not leak `?s=20&t=…` either.
    var url: URL {
        URL(string: "https://x.com/\(handle ?? "i")/status/\(statusID)")!
    }

    /// Hosts that serve posts. Matched exactly, not by suffix: `fakex.com`
    /// ends in `x.com` and belongs to whoever registered it.
    private static let hosts: Set<String> = [
        "x.com", "www.x.com", "mobile.x.com",
        "twitter.com", "www.twitter.com", "mobile.twitter.com",
    ]

    /// The whole trimmed text must be the link, not merely contain one:
    /// a copied paragraph that mentions a post is a copied paragraph.
    static func parse(_ text: String) -> PostLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              hosts.contains(host) else { return nil }

        let path = components.path.split(separator: "/").map(String.init)

        // `/i/web/status/…` and `/i/status/…` — a post without its author.
        if path.first == "i" {
            let rest = path[1...].drop { $0 == "web" }
            guard rest.count >= 2, rest.first == "status",
                  let id = statusID(rest.dropFirst().first) else { return nil }
            return PostLink(handle: nil, statusID: id)
        }

        // `/<handle>/status/<id>`, with `statuses` as the old spelling and
        // `/photo/1`-style suffixes ignored.
        guard path.count >= 3, isHandle(path[0]),
              path[1] == "status" || path[1] == "statuses",
              let id = statusID(path[2]) else { return nil }
        return PostLink(handle: path[0], statusID: id)
    }

    private static func statusID(_ component: String?) -> String? {
        guard let component, !component.isEmpty,
              component.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return component
    }

    /// Handles are ASCII word characters only, which conveniently excludes
    /// every non-profile path a status-shaped URL could start with.
    private static func isHandle(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}
