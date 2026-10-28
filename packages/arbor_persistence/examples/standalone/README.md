# Independent Core consumer

This normal Mix application depends only on `arbor_persistence` and its locked
public dependencies. It exercises the public `Arbor.Persistence.Core` facade:
Agent and ETS Record put/get, CAS, delete/reinsert generation fencing, stale CAS
rejection, compare-delete, and Agent EventLog append/read with idempotent replay.
The stores are owned explicitly by the caller; starting the Core application
has no callback and creates no supervisor or stores.

The canary checks compiled, loaded and started applications, rejecting every
other Arbor application. The original Host facade `Arbor.Persistence`, Host Repo,
Kernel contracts, Security and Signals modules must also be unavailable.

From the repository root, choose a fresh absolute directory outside all Arbor
checkouts:

```sh
python3 packages/arbor_persistence/scripts/qualify_standalone.py \
  --work-dir /absolute/fresh/private/persistence-qualification \
  --mix "$PWD/bin/mix"
```

The script copies production source and this consumer, checks their SHA-256
manifest before and after every command, resolves the three immutable public
lock records with `deps.get --only prod --check-locked`, compiles with warnings
as errors, and runs the canary. It builds a production release and runs the same
canary with both Mix code and its application directory absent. Dependencies,
builds, runtime paths, separate stdout/stderr logs and results all stay in the
chosen directory, including on failure. Existing attempts are never reused.
`--offline` restricts dependency resolution to the existing public Hex cache.
