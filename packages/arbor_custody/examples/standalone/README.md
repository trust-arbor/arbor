# Independent Custody consumer

The qualifier copies this fixture into a new private directory and resolves
`arbor_custody` exclusively from the unpacked bytes of a locally built Hex tar.
It uses no host support, Kernel, Kernel Runtime or Signals source.

The application owns one supervised probe server. The probe exercises an
authenticated exchange, rejects an ordinary GenServer call, replaces visible
callback state without replacing private custody, and validates the server's
exact supervised owner. A separately registered impostor is refused. It also
checks a local private-state slot's create/read/replace/update/close lifecycle.

Every successful probe records compiled, loaded and started applications and
actual code paths. The production release probe requires Mix to be unavailable.
The qualifier moves its release out of the build tree and hides only its own
scratch source copies before running that probe from a neutral directory.

Prepare a fresh qualification directory without running Mix:

```sh
python3 packages/arbor_custody/scripts/qualify_standalone.py \
  --work-dir tmp/verification/custody-consumer-prepare
```

After reviewing the prepared sources, execute with another fresh directory:

```sh
python3 packages/arbor_custody/scripts/qualify_standalone.py \
  --work-dir tmp/verification/custody-consumer-run --run
```

The script uses the repository's pinned `bin/mix` by default, enforces offline
mode and keeps all attempts, logs, tar digests and source manifests. It never
publishes a package or removes a caller's source tree.
