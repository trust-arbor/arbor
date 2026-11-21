# Arbor Kernel

The primitives every Arbor library shares. This application is passive: it has
no OTP callback and starts no process. It has no first-party dependencies; its
runtime dependencies are TypedStruct, Jason, and the OTP Logger and Crypto
applications.

## What lives here

Only modules that two or more unrelated libraries use:

- `Arbor.Types` and `Arbor.Identifiers`
- `Arbor.Contracts.Security.Taint`, `TaintEnvelope`, `TaintedValue` and
  `Classification`
- `Arbor.Contracts.Coding.CanonicalJson` and `SourceInventory`
- `Arbor.Contracts.Persistence.*`, the store port that Capabilities, Trust,
  Memory and the Persistence host implement or consume
- `Arbor.Contracts.Extension.Envelope`, verified at boot by Kernel Runtime and
  at activation by Capabilities

Domain contracts do not live here. Each library owns the behaviours and structs
for its own domain, under `lib/arbor/contracts/` in that library. See
[CONTRACT_RULES.md](../../docs/arbor/CONTRACT_RULES.md) for the ownership rule.

## Keeping it small

The contracts census counts the libraries that consume each contract file in
this package and fails when one has fewer than two:

```bash
./bin/mix arbor.contracts.census --fail-on-violation
```

A contract with a single consumer belongs to that consumer.

## Installation

```elixir
def deps do
  [
    {:arbor_kernel, "~> 2.0.0-dev"}
  ]
end
```

Inside Arbor, consumers resolve the application through its monorepo path
dependency and declare it directly when they use its modules. Publication
remains a separate decision.

## License

MIT
