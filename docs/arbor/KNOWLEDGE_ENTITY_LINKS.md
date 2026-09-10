# Exact knowledge entity links

`Arbor.Memory.find_knowledge_by_name/2` resolves case-insensitive exact matches
against a node's full content, explicit `metadata.name`, or a string member of
`metadata.aliases`. The resolver recognizes atom and string metadata keys;
use string keys for extensible durable metadata such as `"aliases"`. Whole-content
lookup remains supported. A name matching multiple distinct nodes returns
`{:error, :ambiguous}`; absence returns `{:error, :not_found}`. Invalid or blank
query names return `{:error, :invalid_name}`. Malformed metadata names/alias
entries do not become inferred names. Matching does not use substrings,
embeddings, inferred identities, or automatic placeholder nodes.

For example, a node whose content is `The BEAM executes concurrent processes`
can declare `%{"name" => "BEAM", "aliases" => ["Erlang VM"]}`. Both `beam` and
`erlang vm` resolve that node. `Ann` cannot resolve `Anna` or `Joanne`.

`memory_remember` preserves the existing node ID, `stored`, `indexed`,
`already_existed`, and duplicate outcome fields. Its `linked_count` counts only
edge writes acknowledged by the public Memory facade. The additive
`entity_links` list reports each supplied name:

- `linked`: the resolved target ID and `related_to` edge were acknowledged.
- `duplicate`: this target already had an attempt during the same invocation;
  no additional write occurred, even if that earlier attempt failed.
- `unresolved`: exact lookup was absent, ambiguous, or invalid.
- `failed`: lookup or edge persistence returned an error; the bounded reason
  is retained and the count does not increase.

Different names/aliases resolving to one target trigger one edge attempt per
Remember invocation. A subsequent Remember invocation can still reinforce an
existing edge once, matching the existing graph behavior. `linked_count` is
therefore an acknowledged-operation count, not a count of newly created edges.
A stored source node remains stored when an optional entity link fails; this
partial outcome is explicit in `entity_links`.

The durable codec already accepts `related_to` and `relates_to`. This repair
keeps `related_to` for Remember. The full accepted vocabulary remains
`associated_with`, `causes`, `contradicts`, `depends_on`, `derived_from`,
`enables`, `example_of`, `follows`, `part_of`, `precedes`, `related_to`,
`relates_to`, `supports`, and `uses`. Unknown types remain rejected at the
real write boundary. No contract vocabulary expansion is included.

This is an agent-graph operation. Metadata names are ordinary entity labels,
not human ownership evidence. Private-turn write restrictions remain in force;
there is no private-memory read expansion or semantic entity guessing.

The regression tests exercise public Memory and Actions with real synchronous
persistence acknowledgments. A test-owned backend rejects edge CAS while
allowing the source node commit, demonstrating that a failed edge cannot be
reported as linked. Storage-owner restart tests retain the explicit fixture
backend and evict the test agent's projection. They do not claim SQLite/disk,
whole-BEAM, or physical-host durability.
