# Historian leaf cold consumer

Qualification requires reviewed source, fresh strict compilation and separate
normal/source-hidden ERTS execution receipts. Source presence is not runtime
evidence; each attempt retains its inputs, logs and required gate results.

API: `HistorianStandaloneConsumer.verify!(require_no_mix: false)` for the fresh
unpacked archive consumer; `require_no_mix: true` for the assembled source-hidden
ERTS release. Return value is a bounded metadata/check-groups map, never event
payloads, keys or authority material. The runner supplies the four absolute
`ARBOR_KERNEL_PATH`, `ARBOR_SUPPORT_PATH`, `ARBOR_PERSISTENCE_PATH` and
`ARBOR_HISTORIAN_PATH` paths, each pointing only to a distinct unpacked public
artifact. The consumer has no parent config/build helper, wildcard source loading,
product provider, optional SQL adapter or ambient first-party path. Its lock has
only the existing unmodified Boundary/Jason/telemetry/typed_struct public records.

Seven groups cover canonical application callback/direct projection+registry+puller
metadata and module ownership; ordinary append/read/query with an actual
caller-owned public ETS backend; public timeline reconstruction/summary;
exact ordinary stream purge/absence with prefix-related survivor and reserved audit
stream refusal; absent/missing/crashed/malformed authorizer/source denials;
callback execution in the actual caller/registered puller PID without granting
any authority; the distinct legacy two-child public facade startup followed by
canonical OTP restart. Compiled/loaded/started first-party closure is exactly
Kernel, Support, Persistence and Historian before and after. Product/test fixture
modules remain unavailable. The qualifier owns source hiding; this consumer never
renames, hides or deletes sources.

The real Persistence Core inventory contains only EventLog.ETS and EventLog.Agent,
both reporting `:process_lifetime`; Snapshotter is a helper, not a node-restart
EventLog implementation. No DiskLog/File backend is invented. Ordinary history
APIs admit a real authoritative ETS target. Their exact deletion/absence result
proves only that live process-lifetime authority, not restart durability.
`security_audit_identity/0` and `security_invocation/1` must refuse this volatile
target. The callback Observer returns no intents and denies authorization; its
PID observation proves the port boundary only. It is not a production journal,
capability provider or durability substitute.

Outside this leaf lane's scope: production Capabilities authority
consumer provenance, node-restart invocation/audit acknowledgement, real SQL
readback-before-ACK, lost acknowledgements, content conflict/outage handling,
retirement after whole-BEAM restart, or compatible-state rollback. Those are
mandatory separately executed composed-lane gates, using real production Core
and the public SQL package. An eventual passing leaf result must retain
`node_restart_audit_qualified: false` and the composed-required list.

The runner must compile every unpacked artifact freshly using only its private
third-party sources/build/cache, verify real Hex checksums/members/public metadata,
and assemble the ERTS release with no Mix. It may hide only its owned copied
inputs/tools. The final no-Mix eval must prove code paths, source roots and actual
first-party `.app` closure from the release; no warmed product BEAMs qualify this.
