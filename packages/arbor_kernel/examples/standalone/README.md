# Independent Kernel consumer

This fixture has one first-party dependency, `arbor_kernel`, supplied through
`KERNEL_PACKAGE_PATH`. Qualification should copy the fixture into a fresh
directory and point that variable at an unpacked, locally built package. The
fixture does not use the monorepo config, Kernel Runtime, Security, or a broker.

After its dependencies are prepared, run:

```sh
mix run -e 'IO.puts(Jason.encode!(KernelStandaloneConsumer.verify!()))'
```

The probe exercises the real SigningAuthority, SigningAuthorityBootstrap, and
Validator modules. It verifies accepting constructors, exact canonicalization,
redacted Inspect, refusal of JSON encoding, hostile struct-tagged partial maps,
duplicate/unknown attributes, invalid UTF-8, and embedded NUL principal IDs. It
also generates an identity and signs/verifies a SignedRequest, proving the
declared OTP Crypto dependency is available to a standalone caller.

The resulting JSON contains application inventories and actual module code
paths, never an authority token or private key. All compiled, loaded, and
started first-party applications must consist solely of `arbor_kernel`.

For a production release, copy the release outside its build tree, hide only
the qualifier's own source copies, and run it from a neutral working directory:

```sh
KERNEL_RELEASE_ROOT=/absolute/copied/release \
  /absolute/copied/release/bin/kernel_standalone_consumer eval \
  'IO.puts(Jason.encode!(KernelStandaloneConsumer.verify!(require_no_mix: true)))'
```

That probe also requires Mix to be unavailable and every tested module to be
loaded from the copied release. The executable fixture is retained in the
monorepo as qualification input; it is not part of the Kernel Hex payload.
