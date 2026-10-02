/// The events Open Island's installers write. The lists are private upstream, so they are repeated here and
/// HookEventListDriftTests fails when an upstream change makes them differ.
public enum ClaudeHookEvents {
    public static let all = [
        "UserPromptSubmit", "SessionStart", "SessionEnd", "Stop", "StopFailure", "SubagentStart", "SubagentStop",
        "Notification", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "PermissionDenied",
        "PreCompact",
    ]
}

public enum CodexHookEvents {
    public static let all = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"]
}
