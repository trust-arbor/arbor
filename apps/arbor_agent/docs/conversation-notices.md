# Native private conversation notices

This finite host feature appends separate notices to an existing private human
conversation. It does not add assistant transcript turns or initiate voice
playback. Legacy `NotifySession` observability behavior is unchanged.

The implementation is being qualified in an isolated image. A prepared action
or storage-only test is not evidence that an actual Session/Heartbeat publication
has passed; the joined native journey is the acceptance boundary.

## Operator provisioning

Mailbox provisioning is an explicit trusted operator operation through existing
public Agent APIs. `Lifecycle.create/2` options and `mix arbor.profile` do not
currently expose `notice_mailboxes`; they default to no mailbox. There is no
implicit latest-user recipient, UI convenience grant, or mailbox creation during
publication/read.

First establish an ordinary authorized private conversation. Obtain its exact
canonical owner and engagement from the authenticated conversation window. The
recipient is the original active human subject, which may differ from the
canonical owner after identity linking. Use those existing facts below; these
values are not arbitrary selectors that create a conversation.

```elixir
{:ok, profile} = Arbor.Agent.load_profile(target_agent_id)
mailbox = %{
  "mailbox_id" => "owner",
  "recipient_subject_id" => original_human_subject_id,
  "owner_id" => canonical_owner_id,
  "engagement_id" => existing_engagement_id
}
:ok = Arbor.Agent.store_profile(%{profile | notice_mailboxes: [mailbox]})

resource =
  "arbor://comms/notice/publish/#{target_agent_id}/#{original_human_subject_id}/#{canonical_owner_id}/#{existing_engagement_id}"
{:ok, _capability} = Arbor.Security.grant(
  principal: target_agent_id,
  resource: resource,
  constraints: %{rate_limit: 10}
)
{:ok, _profile} = Arbor.Trust.ensure_trust_profile(target_agent_id)
{:ok, _profile} = Arbor.Trust.set_rule(target_agent_id, resource, :allow)
```

The operator must separately hold authority to provision profiles, capabilities,
and trust policy. Existing human chat permission remains required at acquisition,
publication, reconciliation and read. System ceilings and capability approval
requirements still apply: this slice refuses `:notice_approval_required` without
creating an unscoped approval. It cannot autonomously answer an `:ask` gate.
Finite `max_uses` grants are unsupported and refused before consuming an allowance;
rate-limited reusable grants are supported. The example does not grant transcript,
provider, peer-export, or voice-playback permission.

Each mailbox has exactly four string keys as above. Mailbox IDs are distinct,
nonblank bounded ASCII selectors, at most 16 mailboxes per profile. Rewriting,
deleting or applying a profile authority mutation retires existing native sources
before acknowledged backend effects. A failed/unknown write leaves old sources
retired. The fixed synchronous Profile authority owner serializes durable writes,
insert-only legacy migrations and notice acquisition snapshots; a stale legacy
file cannot overwrite a newer durable revocation.

## Native action in a DOT pipeline

Use the ordinary fixed Jido business action in a Session or Heartbeat graph:

```dot
digraph PrivateNotice {
  start [shape=Mdiamond]
  publish [type=exec, target=action, action="comms_publish_conversation_notice",
    max_retries=0, output_prefix=notice,
    arg.mailbox_id="owner",
    arg.notice_id="notice_0123456789abcdef0123456789abcdef",
    arg.kind="notification", arg.text="The scheduled check is complete."]
  exit [shape=Msquare]
  start -> publish -> exit
}
```

A notice ID is `notice_` plus 32 lowercase hexadecimal digits. The producer keeps
an ID stable for reconciliation of the same effect; new work gets a new ID. Kind
is `notification` or `progress`. Text is nonblank UTF-8, at most 32 KiB; encoded
value limits also apply, so heavily escaped text may be refused before SQL.
Exactly four action parameters are accepted. Source, recipient, scope, proof,
policy, taint and signer options are never action parameters.

Direct `Action.run/2`, caller-built context maps, a signing key or transferable
SigningAuthority do not establish native notice authority. Actual acknowledged
BranchSupervisor Session/Heartbeat ownership, durable configured mailbox facts,
and a fixed native worker's private custody are required. The source owner and
worker become sensitive before private broker RPCs; bootstrap release waits for
the receiver's sensitive-ready acknowledgment. This diagnostic visibility flag
remains set for those process lifetimes. Broker/worker private ETS custody is not
exposed through ordinary state/status or process mailbox inspection. This protects
ordinary local API/protocol traffic; trusted compiled BEAM code execution, tracing,
and state replacement are outside this feature's isolation claim.

## Commit, reconciliation and read

Publication is a local durable mailbox operation. After SQLite writer acquisition
(or the PostgreSQL engagement lock), the transaction calls the real native gate
in the original worker PID immediately before the first INSERT. Identical existing
facts are reconciled read-only with current authority and no second rate charge.
Changed text, kind, recipient, scope or provenance conflicts. The original ordinal
and server timestamp survive reconciliation; worker/source generations and retry
time are not immutable content facts.

Security allowance consumption and SQL commit are distinct effects. An uncertain
storage/commit reply remains uncertain; there is no hidden retry, second allowance,
or automatic refund. Only explicit same-ID reconciliation may determine whether
the original effect is stored. Admission reflects current authority at the SQL
gate; later revocation does not retroactively remove an accepted durable notice.

```elixir
Arbor.Agent.conversation_notices(human_subject_id, target_agent_id,
  session_token: server_issued_token,
  expected_engagement_id: existing_engagement_id,
  limit: 20
)
```

The expected engagement is mandatory and compare-only. The authenticated operation
payload is `arbor.conversation.notices.v1`; fresh proof cannot be reused for another
operation. The page is newest-first by scoped positive ordinal, default 20/max 50,
with strict-older `before` and a pinned `through` watermark. The page hard limit is
129,024 encoded bytes, reserving 2,048 bytes for its wire frame. Records are neither
truncated nor skipped to fit. Empty pages still carry exact authenticated scope
and correlation facts. Notice pagination is independent from history/activity.

Release is limited to the current exact private human owner/alias, exact chat
grant and live lease, and existing engagement. A post-read check prevents revoked
or relinked authority from releasing a newly read page. Original recipient and
conservative source-derived taint provenance remain readonly authenticated facts;
semantic display removes those private facts and preserves hostile/restricted
source labels without claiming clean provenance. This visual release is not a
policy for another modality or destination.

Fresh authorized nonhuman signed chat readers receive `:notice_subject_required`,
an unsupported feature-domain result with no rate/use effects. Revoked human
reads remain authorization failures. A malformed same-scope notice page is a
notice-only failure; a foreign scope or lost authority clears private conversation
access. No notice text, recipient, source proof or custody is emitted on generic
`action.*` or `agent.*` observability topics.

Native Session and Heartbeat parents create an execution snapshot only for a
wholly unbound compiled graph containing an actual action declaration of
`authorization_admission_owner: :actions_facade`. They use the real ActionCatalog
and ExecutionManifest, pinning graph, handlers, loaded action code, and owner
metadata before releasing the worker. This snapshot is neither operator review
approval nor permission; all actual grant, trust, taint and native source checks
still run. Supplied bindings remain untouched and incomplete bindings fail
closed. Owner-absent graphs retain ordinary behavior. Use the exact published
Jido/catalog identifier (`comms_publish_conversation_notice`) in this DOT: the
existing manifest grammar does not normalize dot-separated action aliases.
The resolver uses the same argument preparation procedure as execution; deadline
budgets may resample time, while final admission signs and rechecks the actual
prepared exact resource. No private custody is placed in the snapshot.
