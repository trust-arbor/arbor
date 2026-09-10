# Historical format fixtures

These four records contain **synthetic data**, manually rendered from committed
serializer shapes after JSON transport. They are not exports of the affected
August database. IDs, text, and timestamps are deterministic test values;
`AGENT_ID` is replaced with a unique test agent. Do not regenerate these fixtures
using current serializers: that would stop testing compatibility with old input.

| Fixture | Historical source of its shape | Deliberate coverage |
| --- | --- | --- |
| `knowledge_graph.json` | [`f2da76be6`, `KnowledgeGraph.to_map/1`, lines 818–838](http://10.42.42.6:3000/trust-arbor/arbor/src/commit/f2da76be6c4e890d4d9c1039489f1819ebf82b6a/apps/arbor_memory/lib/arbor/memory/knowledge_graph.ex#L818) (parent of strict-codec change `741529261`) | Bare aggregate; two nodes, one edge, one pending learning, string enums and ISO timestamps. No maintenance/operation-receipt fields, which did not exist in that serializer. Node embeddings are omitted as the old serializer did. `auto_embed: false` keeps this fixture local. |
| `goal.json` | [`17fffe71c`, `GoalStore.persist_goal_async/2`, lines 582–593](http://10.42.42.6:3000/trust-arbor/arbor/src/commit/17fffe71c2bd71862cd447da4e084806ad98c5b3/apps/arbor_memory/lib/arbor/memory/goal_store.ex#L582) (parent of `6451bd464`) | One raw Goal struct payload, with created/deadline dates converted to ISO strings. Physical key is `goals:<agent>:<goal>`, not one aggregate per agent. |
| `intents.json` | [`1cb66dbd2`, `serialize_agent_data/1`, lines 625–676](http://10.42.42.6:3000/trust-arbor/arbor/src/commit/1cb66dbd289f41426123e2f99bc070b4b90406c6/apps/arbor_memory/lib/arbor/memory/intent_store.ex#L625) (parent of `268a34f5d`) | Aggregate with one intent, linked percept, and locked lifecycle status. No current provenance wrapper. |
| `chat_history.json` | [`34c8d6006`, `ChatHistory.persist_message_async/2`, lines 215–222](http://10.42.42.6:3000/trust-arbor/arbor/src/commit/34c8d6006fffeffdb50834dcf808ed12d87faf2f/apps/arbor_memory/lib/arbor/memory/chat_history.ex#L215) (parent of ChannelStore transition `145769a2e`) | One append-only message, formerly keyed `chat_history:<agent>:<message>`. Retained for disposition only; there is no current automatic legacy-chat importer to invoke. |

The JSON files intentionally contain no human-owner assertion. An agent storage
key, provenance taint, or successful format migration cannot establish a human's
ownership. The corresponding tests install fixtures only into an isolated store,
then exercise current public Memory reads/writes and owner-process restart.

See [the diagnosis and dry-run disposition](../../../../../docs/arbor/HISTORICAL_MEMORY_FORMAT_QUALIFICATION.md)
for the evidence limits and isolated validation selectors.
