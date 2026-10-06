# Main Agent production gates without Mix

This fixture packages the actual Main Agent/Orchestrator source closure in a
production release, loads its applications without starting product services,
and calls the real TaskStore, GuardedRestore and supervised witness boundaries.
It asserts Mix code/application metadata are absent. Forged runtime environment,
Application settings and caller options must not enable test collaborators,
inventory substitutions, force-ready behavior or witness delays.

Use the repository's pinned `bin/mix`, an isolated checkout with locked private
dependencies, distinct absolute production build paths, and private
`ARBOR_HOME`, `ARBOR_DATA_DIR`, `ARBOR_SECURITY_STATE_DIR` and `ARBOR_ENV_PATH`
(the latter points to an empty file). Do not use a live database or configuration.
From this directory, run `bin/mix compile --warnings-as-errors`, then
`bin/mix release arbor_agent_release_gate`, then the generated release's
`eval 'Arbor.Agent.ReleaseGate.Proof.run()'`. Resolve `bin/mix` against the
repository root. The release is never published or used to start Arbor.

The same fixture must run against the predecessor source and candidate source;
retain the actual commands, separate stdout/stderr, statuses and source hashes.
A Mix-hosted VM with Mix removed from its code path is not the acceptance proof.
