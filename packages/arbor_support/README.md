# Arbor Support

Filesystem safety, safe atom conversion, sensitive-data screening and
pagination cursors for Elixir. This passive package owns the existing
`Arbor.Common.SafePath`, `Arbor.Common.SafeAtom`, `Arbor.Common.SensitiveData`
and `Arbor.Common.Pagination.Cursor` modules. Their public functions, error
vocabulary, nested struct and exception identities, and algorithms are unchanged.

```elixir
{:arbor_support, "~> 0.1.0-dev"}
```

The library has no first-party dependencies, application callback, supervisor,
provider gate or background process. Each helper subtree is an independent
strict Boundary root. SafePath exports its existing `RootBinding` and
`TraversalError` identities; the generated native artifact remains internal.

`SafeAtom` converts only existing or explicitly admitted atoms and preserves
its collection handling. `SensitiveData` retains the existing PII and
secret detection/redaction patterns. `SafePath` retains path validation,
symlink-aware resolution, root bindings and descriptor-bound read operations.
Callers still own authorization and the lifetime of each read operation.

`Arbor.Common.Pagination.Cursor` provides timestamp/ID cursor encoding and
ordered filtering, including microsecond DateTime comparisons. Invalid cursor
strings fail closed with `:error` when parsed and an empty list when filtering;
an empty ID is invalid. A nil filter cursor retains the existing unfiltered result.
The higher-level `Arbor.Common.Pagination` module remains in Kernel Runtime.

## Native reader

The package builds its reader from `c_src/arbor_safe_path_reader.c` using the
host C compiler (`cc`). A C compiler and the existing POSIX facilities are
build prerequisites. No prebuilt executable is published, downloaded or
resolved from another Arbor application's build or `priv` directory.

The custom compiler embeds the resulting bytes and their source/binary hashes
in the unchanged `Arbor.Common.SafePath.NativeReaderArtifact` module. Compiler
output is non-executable build data. The runtime materializes and seals the
helper for its own bounded descriptor operation, retaining the existing
materialization cleanup, path/root identity, timeout and protocol protections.

Generated data and Elixir source live under
`Mix.Project.build_path()/generated/arbor_support`. The compiler registers
that source directory after Mix applies dependency build-path overrides. This
uses the pinned build-only `Mix.ProjectStack.merge_config/1` internal to
append and deduplicate the generated directory without discarding existing
`elixirc_paths`. It changes no configuration when invoked for another app;
`clean/0` only removes this package's generated and legacy outputs. Runtime
code has no Mix dependency.

## Adoption and tests

Source, owning tests, native reader and compiler are adopted from Arbor Main
`14c2566fb`. `ADOPTION_SOURCE_MAP.json` records the original source hashes and
the bounded relocation changes. Original Kernel Runtime source ownership is
removed in the same adoption; no parallel helper implementation is introduced.

The cursor and its unchanged owning tests are adopted separately from Main
`655a0528f`. `CURSOR_ADOPTION.json` records their original Git blob identities
and source/target hashes. The only source addition is its independent strict
Boundary declaration; the original Support adoption map remains historical.

The owning suites live in `test/arbor/common`. Test-only SafePath race hooks
are compiled only when `:arbor_support, :expose_test_fixtures` is explicitly
true. The package's test configuration enables them; production defaults do
not. Consumer apps retain their current `Arbor.Common.*` calls and add the
package dependency instead of compiling another copy.

The Hex payload contains only `lib`, `c_src`, `mix.exs`, this README and the
license. Tests, configuration, source-map evidence, generated artifacts and
qualification fixtures are excluded. Publication remains a separate decision.
