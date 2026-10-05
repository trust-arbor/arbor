# Conversation navigation

Home is the default Dashboard page at `/`. It lists the conversations available
to the signed-in human. The operator Console is at `/console`; its navigation
keeps the existing management and observability pages reachable.

| Link | Destination |
| --- | --- |
| `/` or `/home` | Conversation Home |
| `/c/<engagement_id>` | Home with that conversation reference selected |
| `/conversation/<agent_id>` | The selected agent's conversation |
| `/console` | Operator Console |
| `/chat?agent_id=<agent_id>` | Temporary redirect to the same agent's conversation |
| `/chat` without an agent target | Temporary redirect to Home |

The Agents page opens the canonical `/conversation/<agent_id>` link. Agent IDs
must be bounded route-safe agent identifiers. Invalid or duplicate legacy
selectors return a static error without choosing another conversation. Other
legacy query fields are discarded rather than forwarded. Redirects are temporary
and are not cached, allowing the migration to be reversed by restoring the old
route and navigation configuration.

A link names a target; it grants no access. Browser authentication remains ahead
of these routes, and the selected conversation still requires its existing
session proof and host authorization. `/home` and existing engagement and agent
deep links remain available.

Retained ChatLive behavior and security tests use an explicitly test-only
endpoint. Production `/chat` never mounts that legacy interface.
