// Puts SESSION_ID into the environment of every shell command, which the
// agent uses as <session-id> in .tmp/sessions/<session-id>/ per AGENTS.md
// "Multi-Agent Working Tree Discipline" rule 3.
//
// It goes in the environment rather than in the system prompt because the
// system prompt is the one part of the request every turn and every session
// shares, and a prompt cache keys on exactly that. A per-session value inside
// it leaves no two sessions a reusable prefix, so the whole system block
// (instructions, AGENTS.md, tool definitions) is reprocessed at every session
// start. Turn-to-turn reuse within a session was never affected, which is why
// the cost hid: it falls entirely on session starts.
//
// Claude Code keeps the literal value in context instead, from the
// SessionStart hook in .claude/settings.json. That is not an oversight to be
// tidied away: its stdout joins the conversation ahead of the first prompt
// rather than the system block, so it sits outside the cached prefix, and its
// static "env" setting cannot carry a per-session value the way this hook can.

export const SessionIdInjector = async () => ({
    'shell.env': async (input, output) => {
        if (!input.sessionID) return;
        output.env.SESSION_ID = input.sessionID;
    },
});
