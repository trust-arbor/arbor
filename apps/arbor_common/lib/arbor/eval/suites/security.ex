defmodule Arbor.Eval.Suites.Security do
  @moduledoc """
  Security-focused static analysis suite — the L0 (per-file) detector layer of
  the Security Sentinel.

  This suite groups the per-file security checks that look for the classes of
  bug surfaced in the 2026-06-09 security reviews. Each check is conservative
  (low false-positive) and reports `:warning`-severity violations in this first,
  advisory phase.

  The Sentinel's `RunStaticDetectors` action drives this suite over a path or a
  diff, then translates the violations into structured
  `Arbor.Contracts.Security.Finding`s. The suite can also run standalone:

      {:ok, result} = Arbor.Eval.Suites.Security.check_directory("apps/arbor_security/lib/")

  ## Checks

  - `AuthorizationSmells` — fail-open patterns in authorization/verification code.

  Future checks (planned): Ed25519 hash-mode, `String.to_atom` on input,
  security config defaulting open. Whole-tree checks (signed-field coverage,
  regression-test presence, URI-registration coverage) live in analysis actions
  rather than here, since `Arbor.Eval` checks are per-file only.
  """

  use Arbor.Eval.Suite,
    name: "security",
    description: "Static security checks (fail-open authz and related smells)"

  alias Arbor.Eval.Checks.AuthorizationSmells

  @impl Arbor.Eval.Suite
  def evals do
    [
      AuthorizationSmells
    ]
  end

  @impl Arbor.Eval.Suite
  def filter_files(files) do
    Enum.reject(files, fn file ->
      String.contains?(file, "/test/") or
        String.contains?(file, "_test.exs") or
        String.ends_with?(file, ".exs")
    end)
  end
end
