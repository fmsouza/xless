import XlessCore

extension ASCError: StageReportableError {
    public func stageError(_ stage: Stage) -> XlessError {
        if stage == .account { return accountError() }
        let fix: String
        switch status {
        case 401:
            fix = "App Store Connect rejected the API key: check that ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 belong to the same active key, and that this machine's clock is correct"
        case 403:
            fix = "the API key lacks permission for this request: use a key with the Admin role (App Store Connect → Users and Access → Integrations)"
        case 429, 500...:
            fix = "App Store Connect is unavailable or rate-limiting (already retried); wait a few minutes and re-run"
        default:
            fix = KnownIssues.explain(description) ?? "see the App Store Connect error above"
        }
        return XlessError(stage, description, fix: fix)
    }

    /// The account commands' reading: the request named, and a fix for what Apple's status and error source say.
    func accountError() -> XlessError {
        let request = [method, path].compactMap { $0 }.joined(separator: " ")
        let cause = request.isEmpty ? description : "\(request): \(description)"
        let fix: String
        switch status {
        case 401:
            fix = "App Store Connect rejected the API key: it may have been revoked, ASC_ISSUER_ID may not be the issuer of ASC_KEY_ID, or this machine's clock is off; check the key under App Store Connect → Users and Access → Integrations"
        case 403:
            let role = ASCRoles.needed(path: path ?? "")
            let argument = role.uppercased().replacingOccurrences(of: " ", with: "_")
            fix = "the API key's role does not allow this request: it needs the \(role) role\(role == "Admin" ? "" : " (or Admin)"); create a key with that role (`xless auth api-key create --role \(argument)`, or App Store Connect → Users and Access → Integrations) and use it"
        case 404:
            fix = "App Store Connect has no such resource: check the ID and the path (and that the key's team owns it)"
        case 409:
            if let field = conflictField {
                fix = "App Store Connect refused the value of `\(field)` (it conflicts with an existing resource or is not allowed): change it, or update the existing resource instead"
            } else {
                fix = "App Store Connect refused the request as conflicting with the resource's current state; see the detail above"
            }
        case 429:
            if let retryAfter {
                let minutes = (retryAfter + 59) / 60
                fix = "the API key's hourly request budget is spent: wait \(minutes) minute\(minutes == 1 ? "" : "s"), then re-run"
            } else {
                fix = "App Store Connect is rate-limiting (already retried); wait a few minutes and re-run"
            }
        case 500...:
            fix = "App Store Connect is unavailable (already retried); wait a few minutes and re-run"
        default:
            fix = "see the App Store Connect error above"
        }
        return XlessError(.account, cause, fix: fix)
    }

    /// The attribute or relationship a 409 points at (`/data/attributes/name` → `name`).
    var conflictField: String? {
        for item in items {
            if let pointer = item.source?.pointer, let last = pointer.split(separator: "/").last, pointer.hasPrefix("/data/") { return String(last) }
            if let parameter = item.source?.parameter { return parameter }
        }
        return nil
    }
}

extension ASCPagingError: StageReportableError {
    public func stageError(_ stage: Stage) -> XlessError {
        XlessError(stage, description, fix: "report this as an xless bug")
    }
}
