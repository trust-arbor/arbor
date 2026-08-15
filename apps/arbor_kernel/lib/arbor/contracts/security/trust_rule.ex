defmodule Arbor.Contracts.Security.TrustRule do
  @moduledoc """
  A validated trust-policy rule URI.

  Trust rules match by longest URI **prefix**, not glob — a bare
  `arbor://fs/read` already covers its whole subtree. A trailing `/**` or `/*`
  is a LITERAL that matches nothing, so such a rule silently never fires:
  fail-closed under a `:block` baseline, but fail-OPEN for a `:block` rule under
  an `:allow` baseline. Capabilities use `/**` for path scope; trust rules must
  not — the two forms look identical, which is the footgun.

  This type makes the distinction un-writable-wrong. `new/1` rejects a glob in a
  trust-rule URI (construction-time prevention), and `canonicalize/1` strips a
  trailing glob to the bare prefix for the forgiving write paths (which warn +
  canonicalize rather than crash). Mirrors `Arbor.Trust.Authority`'s runtime
  canonicalization; a test asserts they agree.

  See CLAUDE.md Applied Learning + `.arbor/roadmap/0-inbox/trust-rule-glob-footgun.md`.
  """

  @enforce_keys [:uri]
  defstruct [:uri]

  @type t :: %__MODULE__{uri: String.t()}

  @doc """
  Build a trust rule from a URI, rejecting any glob (`*`) — the footgun.

  Returns `{:ok, %TrustRule{}}` or `{:error, :glob_in_trust_rule}`.
  """
  @spec new(String.t()) :: {:ok, t()} | {:error, :glob_in_trust_rule}
  def new(uri) when is_binary(uri) do
    if glob?(uri) do
      {:error, :glob_in_trust_rule}
    else
      {:ok, %__MODULE__{uri: uri}}
    end
  end

  @doc "Like `new/1` but raises `ArgumentError` on a glob URI."
  @spec new!(String.t()) :: t()
  def new!(uri) do
    case new(uri) do
      {:ok, rule} ->
        rule

      {:error, :glob_in_trust_rule} ->
        raise ArgumentError,
              "trust rule #{inspect(uri)} contains a glob; trust rules match by PREFIX, not " <>
                "glob — use the bare prefix (e.g. \"arbor://fs/read\", not \"arbor://fs/read/**\")"
    end
  end

  @doc "True if the URI carries a glob that would make it a dead trust rule."
  @spec glob?(String.t()) :: boolean()
  def glob?(uri) when is_binary(uri), do: String.contains?(uri, "*")

  @doc """
  Canonicalize a trust-rule URI: strip a trailing `/**` or `/*` to the bare
  prefix the matcher actually uses. Must agree with
  `Arbor.Trust.Authority`'s runtime canonicalization.
  """
  @spec canonicalize(String.t()) :: String.t()
  def canonicalize(uri) when is_binary(uri) do
    uri
    |> String.replace_suffix("/**", "")
    |> String.replace_suffix("/*", "")
  end
end
