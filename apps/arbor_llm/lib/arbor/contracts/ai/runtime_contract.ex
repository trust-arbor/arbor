defmodule Arbor.Contracts.AI.RuntimeContract do
  @moduledoc """
  Declarative struct describing what an LLM provider needs to run.

  Each provider adapter declares its runtime requirements via a
  `%RuntimeContract{}` struct. This enables:

  - `mix arbor.doctor` diagnostics ("missing: codex CLI, run: npm i -g @openai/codex")
  - Unified provider discovery (check env vars, CLI binaries, HTTP probes)
  - Install hints for setup guidance

  ## Provider Types

  - `:api` — Cloud API accessed via HTTP (requires API key env var)
  - `:cli` — CLI tool accessed via Port (requires binary in PATH)
  - `:local` — Local server accessed via HTTP (requires running service)

  ## Usage

      contract = RuntimeContract.new(
        provider: "claude_cli",
        display_name: "Claude CLI",
        type: :cli,
        env_vars: [%{name: "ANTHROPIC_API_KEY", required: false}],
        cli_tools: [%{name: "claude", install_hint: "npm i -g @anthropic-ai/claude-code"}],
        capabilities: Capabilities.new(streaming: true, thinking: true, tool_calls: true)
      )

      RuntimeContract.check(contract)
      # => {:ok, %{env_vars: :ok, cli_tools: :ok, probes: :skipped}}
      # or
      # => {:error, [cli_tools: {:missing, "claude", "npm i -g @anthropic-ai/claude-code"}]}
  """

  alias Arbor.Contracts.AI.Capabilities

  @type probe :: %{
          type: :http,
          url: String.t(),
          timeout_ms: pos_integer()
        }

  @type env_var :: %{
          name: String.t(),
          required: boolean()
        }

  @type cli_tool :: %{
          name: String.t(),
          install_hint: String.t() | nil
        }

  @type provider_type :: :api | :cli | :local

  @type t :: %__MODULE__{
          provider: String.t(),
          display_name: String.t(),
          type: provider_type(),
          env_vars: [env_var()],
          cli_tools: [cli_tool()],
          probes: [probe()],
          capabilities: Capabilities.t() | nil
        }

  defstruct provider: nil,
            display_name: nil,
            type: :api,
            env_vars: [],
            cli_tools: [],
            probes: [],
            capabilities: nil

  @valid_types [:api, :cli, :local]

  @doc """
  Create a new RuntimeContract from a keyword list or map.

  ## Required Fields

  - `:provider` — Provider identifier string (e.g., `"claude_cli"`, `"anthropic"`)
  - `:display_name` — Human-readable name (e.g., `"Claude CLI"`)
  - `:type` — One of `:api`, `:cli`, `:local`

  ## Optional Fields

  - `:env_vars` — List of `%{name: "VAR_NAME", required: true/false}`
  - `:cli_tools` — List of `%{name: "binary", install_hint: "..."}`
  - `:probes` — List of `%{type: :http, url: "...", timeout_ms: 2000}`
  - `:capabilities` — `%Capabilities{}` struct

  ## Examples

      iex> {:ok, c} = Arbor.Contracts.AI.RuntimeContract.new(
      ...>   provider: "anthropic",
      ...>   display_name: "Anthropic API",
      ...>   type: :api,
      ...>   env_vars: [%{name: "ANTHROPIC_API_KEY", required: true}]
      ...> )
      iex> c.provider
      "anthropic"
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required(attrs),
         :ok <- validate_type(attrs) do
      contract = %__MODULE__{
        provider: get_attr(attrs, :provider),
        display_name: get_attr(attrs, :display_name),
        type: get_attr(attrs, :type) || :api,
        env_vars: get_attr(attrs, :env_vars) || [],
        cli_tools: get_attr(attrs, :cli_tools) || [],
        probes: get_attr(attrs, :probes) || [],
        capabilities: get_attr(attrs, :capabilities)
      }

      {:ok, contract}
    end
  end

  @doc """
  Check if all runtime requirements are satisfied.

  Returns `{:ok, results}` when all required checks pass, or
  `{:error, failures}` with a list of what's missing.

  ## Options

  - `:probe_fn` — Custom function `(url, timeout_ms) -> boolean()` for HTTP probes.
    Defaults to an `:httpc`-based check. Higher-level callers can inject a
    `Req`-based implementation.

  ## Results Map

  Each check category returns one of:
  - `:ok` — all items satisfied
  - `:skipped` — no items to check
  - `{:missing, details}` — one or more items missing

  ## Examples

      RuntimeContract.check(contract)
      # => {:ok, %{env_vars: :ok, cli_tools: :ok, probes: :skipped}}

      RuntimeContract.check(contract)
      # => {:error, [cli_tools: {:missing, "claude", "npm i -g @anthropic-ai/claude-code"}]}
  """
  @spec check(t(), keyword()) :: {:ok, map()} | {:error, [{atom(), term()}]}
  def check(%__MODULE__{} = contract, opts \\ []) do
    probe_fn = Keyword.get(opts, :probe_fn, &default_probe/2)

    results = %{
      env_vars: check_env_vars(contract.env_vars),
      cli_tools: check_cli_tools(contract.cli_tools),
      probes: check_probes(contract.probes, probe_fn)
    }

    failures =
      Enum.filter(results, fn
        {_key, {:missing, _, _}} -> true
        {_key, {:failed, _, _}} -> true
        _ -> false
      end)

    if failures == [] do
      {:ok, results}
    else
      {:error, failures}
    end
  end

  @doc """
  Returns true if all required runtime requirements are satisfied.
  """
  @spec available?(t(), keyword()) :: boolean()
  def available?(%__MODULE__{} = contract, opts \\ []) do
    match?({:ok, _}, check(contract, opts))
  end

  # ============================================================================
  # Private — Checks
  # ============================================================================

  defp check_env_vars([]), do: :skipped

  defp check_env_vars(vars) do
    missing =
      vars
      |> Enum.filter(fn var -> var.required && blank?(System.get_env(var.name)) end)
      |> Enum.map(fn var -> var.name end)

    if missing == [] do
      :ok
    else
      {:missing, Enum.join(missing, ", "), "Set the required environment variable(s)"}
    end
  end

  defp check_cli_tools([]), do: :skipped

  defp check_cli_tools(tools) do
    missing =
      tools
      |> Enum.reject(fn tool -> System.find_executable(tool.name) != nil end)

    case missing do
      [] ->
        :ok

      [first | _] ->
        {:missing, first.name, first.install_hint || "Install #{first.name}"}
    end
  end

  defp check_probes([], _probe_fn), do: :skipped

  defp check_probes(probes, probe_fn) do
    failed =
      Enum.reject(probes, fn probe ->
        timeout = Map.get(probe, :timeout_ms, 2_000)
        probe_fn.(probe.url, timeout)
      end)

    case failed do
      [] -> :ok
      [first | _] -> {:failed, first.url, "Service not responding at #{first.url}"}
    end
  end

  defp default_probe(url, timeout_ms) do
    # Use Erlang :httpc for zero-dependency HTTP probing
    :inets.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: timeout_ms], []) do
      {:ok, {{_, status, _}, _, _}} when status >= 200 and status < 300 -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_required(attrs) do
    cond do
      blank?(get_attr(attrs, :provider)) ->
        {:error, {:missing_required_field, :provider}}

      blank?(get_attr(attrs, :display_name)) ->
        {:error, {:missing_required_field, :display_name}}

      true ->
        :ok
    end
  end

  defp validate_type(attrs) do
    case get_attr(attrs, :type) do
      nil -> :ok
      type when type in @valid_types -> :ok
      other -> {:error, {:invalid_type, other}}
    end
  end

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  defp get_attr(attrs, key) when is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key))
      value -> value
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
