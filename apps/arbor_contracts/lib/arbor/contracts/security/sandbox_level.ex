defmodule Arbor.Contracts.Security.SandboxLevel do
  @moduledoc """
  Canonical agent isolation level — the single sandbox posture an agent carries
  (declared in its template), replacing the old trust-tier → sandbox derivation
  (`TrustBounds.sandbox_for_tier` / `Arbor.Sandbox.level_for_trust`).

  Ordered most→least restrictive: `:strict` > `:standard` > `:permissive` > `:none`.
  A canonical level maps to the concrete vocabulary of each enforcement subsystem:

  | canonical    | shell (`Arbor.Shell.Sandbox`) | code (`Arbor.Sandbox`) |
  |--------------|-------------------------------|------------------------|
  | `:strict`    | `:strict` (allowlist)         | `:pure`  (read-only)   |
  | `:standard`  | `:basic` (blocklist)          | `:limited` (scoped)    |
  | `:permissive`| `:basic`                      | `:full`                |
  | `:none`      | `:none`                       | `:full`                |

  `:strict` is the fail-safe default — used whenever the level is missing or
  unrecognized. Coercion/translation degrade DOWN to it, never widen.
  """

  @type t :: :strict | :standard | :permissive | :none
  @type shell_level :: :strict | :basic | :none
  @type code_level :: :pure | :limited | :full

  @levels [:strict, :standard, :permissive, :none]
  @default :strict

  @doc "The fail-safe default level (most restrictive)."
  @spec default() :: t()
  def default, do: @default

  @doc "All canonical levels, most→least restrictive."
  @spec levels() :: [t()]
  def levels, do: @levels

  @doc "Whether `level` is a recognized canonical level."
  @spec valid?(term()) :: boolean()
  def valid?(level), do: level in @levels

  @doc """
  Coerce any input to a canonical level, fail-safe to `:strict`. Accepts the atom
  or its string form (templates/JSON carry strings).
  """
  @spec coerce(term()) :: t()
  def coerce(level) when level in @levels, do: level

  def coerce(level) when is_binary(level) do
    case level do
      "strict" -> :strict
      "standard" -> :standard
      "permissive" -> :permissive
      "none" -> :none
      _ -> @default
    end
  end

  def coerce(_), do: @default

  @doc "Translate a canonical level to the shell sandbox vocabulary."
  @spec to_shell(t()) :: shell_level()
  def to_shell(:strict), do: :strict
  def to_shell(:standard), do: :basic
  def to_shell(:permissive), do: :basic
  def to_shell(:none), do: :none
  def to_shell(_), do: to_shell(@default)

  @doc "Translate a canonical level to the code sandbox vocabulary."
  @spec to_code(t()) :: code_level()
  def to_code(:strict), do: :pure
  def to_code(:standard), do: :limited
  def to_code(:permissive), do: :full
  def to_code(:none), do: :full
  def to_code(_), do: to_code(@default)
end
