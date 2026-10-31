# Standalone LLM consumer

This caller-owned fixture uses the installed public LLM SDK and an explicit
loopback HTTP/SSE server. Run-specific qualification receipts determine whether
its checks passed. Source review and the presence of this fixture do not qualify
a build, release, product authority, or external provider.

The entry point is `LLMStandaloneConsumer.run!(require_no_mix: false)`. The
source-hidden release invokes the same entry with `require_no_mix: true`; it
requires both Mix code and Mix application metadata to be absent and all code
paths to originate inside the embedded ERTS release. The returned JSON-safe map
contains check names, exact first-party app sets, module owners/BEAM origins,
resource hashes, and bounded group counts. It does not return request bodies,
credentials, opaque authority, or process handles.

The consumer's direct dependencies use public version requirements. Five
build-only `ARBOR_KERNEL_PATH`, `ARBOR_SUPPORT_PATH`, `ARBOR_OAUTH_PATH`,
`ARBOR_SIGNALS_PATH`, and `ARBOR_LLM_PATH` overrides select unpacked archives in
qualification. Its lock contains the exact 31 public production/Boundary
records of the reviewed SDK closure. The enclosing qualifier owns archive
verification, offline public sources, each unpacked project's private lock,
pinned tools and SDK/native preflight, fresh compilation, release assembly,
source hiding and preservation guards. Repository fallback paths are for local
source development; they are not evidence of installed-package independence.

The fixture requires `LLM_COLD_STATE_ROOT` to name an existing canonical absolute
0700 directory owned by the runner. Each fresh VM receives a fresh directory.
The fixture places the OAuth store and acknowledgement path there, binds the
OpenAI import selector to a private absent file, snapshots configuration before
mutating it and restores it in `after`. The runner must scrub ambient provider
credentials, source/CLI selectors and proxies and provide private Arbor, XDG and
TMP paths without changing HOME. No public internet request is intended.

The compiled and loaded first-party set must be exactly Kernel, Support, OAuth,
Signals and LLM. The started set must be exactly Kernel, Support, OAuth and LLM.
Kernel, Support and OAuth have no application callback or registered owner;
Signals is an explicit code dependency with `runtime: false` and is included in
the release as `:load`. LLM owns its historical active application, supervisor,
PendingStore, RecoveryProofStore and complete loopback supervisor tree. Stop and
restart must replace that actual supervisor; no listener may exist before an
explicit login. Historical `Arbor.AI.LLMError` and
`Arbor.Orchestrator.ToolHooks` retain their SDK owner while their product
applications and root modules remain absent.

The real ReqLLM/Req/Finch path handles public `generate/1`, `stream/1`,
`generate_object/1`, `stream_object/1` and `embed_batch/4`. The wire captures
method, path, selected model, embedding input order and the tool-result message.
Synthetic SSE fragments assemble one complete tool argument before dispatch.
The explicit finite policy admits only the four declared models on the exact
currently bound loopback origin and explicit `/v1`, `/v1/chat/completions` or
`/v1/embeddings` path, public/internal sensitivity and `:arbor` runtime. Userinfo,
queries, fragments and other paths are refused.
The caller-owned executor and auditor bind one synthetic operation, principal,
session, task and provider call. One real executor effect must have exactly one
audit observation. These ports qualify library composition; they do not replace
or claim product Security authorization or durable audit.

Missing policy, denied model, unknown route, private fixture selection and
missing executor must make no HTTP request. Missing auditor must make no tool
effect; the existing ToolLoop still carries its refusal through a provider
continuation. Halting after the first real streamed delta must close the TCP
stream before the scripted remaining chunks are sent. Every owned wire socket,
server task and port-state Agent is retired on success or assertion failure;
configuration is restored before the invocation exits.

This fixture also reads the installed OpenCode admission resource and LLMDB
snapshot. It does not grant credit for those resources' historical provider
admission claims. Deep OAuth login/state/PKCE/replay/cancellation coverage and the
complete malformed/deep/oversized/deadline/redirect transport matrix remain
owning-suite gates. This bounded cold fixture proves actual OAuth topology and
no premature listener, rather than a full cold OAuth login. Enclosing family
acceptance also requires product port integration, independent package tests,
source conservation and final-tip review.
