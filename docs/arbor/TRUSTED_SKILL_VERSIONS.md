# Trusted skill versions

Skill import, discovery and execution approval are separate operations. Importing
with `approve: true` confirms import; it does not approve the imported instructions
for an agent or change their untrusted provenance.

A trusted operator obtains `Arbor.Common.SkillLibrary.prepare_approval(name)` and
reviews the returned immutable library snapshot. Its `resource_uri` is
`arbor://skill/use/<sha256-name>/<version-digest>`. Existing `Arbor.Security.grant/1`
and `revoke/1` administer that exact resource for the intended principal. There is
no model-callable approval helper. Broad grants, name-only grants, delegation,
scoped/stateful constraints, and grants not signed by the current root cannot
satisfy this initial version-approval lane.

The version binds the original source bytes retained by file adapters, parsed
execution fields, declared tools, provenance, and source path. Programmatically
registered skills bind their canonical fields. The legacy body-only content hash
is not an approval. Reloading/replacing a snapshot changes the required approval;
changed bytes cannot inherit the old grant. A disk edit not yet reloaded does not
change the immutable in-memory snapshot being consumed. Referenced files and
scripts are not transitively approved: their content remains separate tool data
and their execution still requires normal tool and filesystem capabilities.

Activation saves an exact version/capability reference and reports save failures.
Every active prompt consumption rechecks that original current ordinary grant,
then renders the corresponding library snapshot. Copied working-memory text,
forged taint or digest fields, a different principal's grant, and a replacement
version are refused. Revocation blocks future consumption; it does not retract
text already admitted to a running model request. Approval never grants the
skill's declared tools. Authenticated private-turn policy remains restrictive.

Privileged built-in prompt replacements use the source-owned
`config :arbor_kernel, common: [trusted_skill_versions: %{name => digest}]` manifest.
An absent or drifted pin selects the existing hardcoded fallback. A directory,
filename, imported trust label or request parameter is never a builtin approval.
The default manifest is empty; deployments review and pin each replacement they
actually intend to use.

`SkillLibrary.approval_status/3`, skill search and active-skill listing expose the
current trust state. `Arbor.Memory.skill_version_manifest/1` reads actual working
memory and exposes admitted versions, current builtin pin states, a pin manifest
digest and loaded owner module MD5s for execution qualification. Reading this
manifest does not grant approval. Source-owned callers must still bind the rest
of their execution profile and reject qualification drift.

Skill compilation requires approval before provider or cache effects and ordinary
filesystem grants for the cache. The receipt binds approved input version and
generated DOT SHA-256; returned DOT remains explicitly untrusted. The cache
receipt is integrity metadata, not a signature or execution permission. Legacy
body-hash-only cache headers are not accepted by the compiler. Ordinary pipeline
validation, capability, taint and runtime gates remain required. These checks do
not claim confinement from arbitrary code already executing inside the BEAM.

Adversarial task grading now requires successful delivery of a declared scenario
precondition. An empty trajectory or blocked fixture read cannot earn a safety
pass, even when the judge says pass. Completion remains a separate metric;
blocked exfiltration and an undelivered attack remain distinct outcomes. Live
model qualification is separate from these deterministic regression tests.
