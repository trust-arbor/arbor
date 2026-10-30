# Standalone consumer

This independent Mix project exercises Signals with its passive Kernel dependency.
It requires exactly `arbor_signals` and `arbor_kernel` in the loaded, started and
compiled Arbor application closure. It checks canonical Kernel taint ownership,
monotonic propagation, absorbing invalid provenance, frozen durable v1 bytes,
delivery, retained history, restricted subscriptions and stop/restart. It needs
no host taint provider overrides.

The cold qualifier builds **both** Hex archives, checks their published source
bytes and metadata, and compiles this consumer using overrides pointing at both
unpacked archives. It copies only third-party **sources** from an explicitly
reviewed private production cache. It never runs `deps.get`, downloads tools,
seeds compiled application caches, or uses the umbrella build. Producer packages
are not compiled merely to assemble their archives. After fresh consumer
dependency compilation, it forces strict compilation of unpacked Kernel and
Signals in that order, using the same private consumer build and dependencies.
Both use `compile --no-deps-check --force --warnings-as-errors`; the consumer then
compiles strictly with normal dependency checks. This makes warnings in either
artifact fail qualification as well as warnings in the consumer.

Run from a clean, reviewed branch in a worktree separate from Main. Supply the
exact reviewed commits and pinned tool locations; all arguments are required:

```sh
python3 packages/arbor_signals/scripts/qualify_standalone.py \
  --work-dir /absolute/fresh/private/qualification-directory \
  --mix /absolute/reviewed/worktree/bin/mix \
  --erlang-root /absolute/pinned/erlang/28.4.1 \
  --elixir-root /absolute/pinned/elixir/1.19.5-otp-28 \
  --hex-archive /absolute/pinned/elixir/1.19.5-otp-28/.mix/archives/hex-VERSION \
  --rebar3 /absolute/pinned/rebar3 \
  --deps-source-cache /absolute/reviewed/private/production-dependency-sources \
  --main-root /absolute/path/to/arbor-main \
  --main-head REVIEWED_MAIN_COMMIT \
  --head REVIEWED_BRANCH_COMMIT \
  --branch REVIEWED_BRANCH_NAME
```

The source cache must contain locked `boundary`, `jason`, `telemetry` and
`typed_struct` source directories, including their Hex checkout markers. The Hex
archive is a pinned installed build tool; Rebar is needed by Telemetry. Private
Mix/Hex homes and an owned foreground loopback EPMD with one synthetic cookie
isolate every invocation. Main and branch inputs, Main's build, stash, operator
node identity and cookie metadata are guarded before and after commands.

Finally the qualifier assembles an ERTS release, hides only its exclusive source
and dependency copies, and repeats the public probes with Mix absent. It checks
release-owned code paths and a non-distributed VM. All artifacts and logs remain
in the new work directory; errors stop qualification without retries or repairs.
It does not modify historical adoption evidence. An implementation change is
not qualification evidence: success requires executing this command and retaining
its passing `results.json`, including both real archive metadata checks.
