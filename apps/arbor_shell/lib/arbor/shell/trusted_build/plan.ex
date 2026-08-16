defmodule Arbor.Shell.TrustedBuild.Plan do
  @moduledoc false

  alias Arbor.Common.SafeAtom

  @phases [:deps_get, :compile, :release]
  @phase_order %{deps_get: 0, compile: 1, release: 2}

  @argv %{
    deps_get: ["deps.get", "--only", "prod"],
    compile: ["compile", "--warnings-as-errors"],
    release: ["release", "--overwrite"]
  }

  @timeout_ms %{
    deps_get: 300_000,
    compile: 600_000,
    release: 600_000
  }

  @writable_names ~w(home tmp build deps hex mix cache release)
  @env_keys ~w(
    MIX_ENV HEX_OFFLINE ARBOR_MIX_CONTAINED ARBOR_ERLANG_ROOT ARBOR_ELIXIR_ROOT
    HOME TMPDIR TMP HEX_HOME MIX_HOME MIX_ARCHIVES MIX_DEPS_PATH MIX_BUILD_PATH
    ELIXIR_MAKE_CACHE_DIR ERL_CRASH_DUMP PATH LANG LC_ALL
  )
  # Locked to trusted_build_replace_environ() Darwin PATH suffix.
  @darwin_utility_path "/usr/bin:/bin"

  @spec admit_phase(term()) :: {:ok, atom()} | {:error, :trusted_build_phase_rejected}
  def admit_phase(phase) do
    case SafeAtom.to_allowed(phase, @phases) do
      {:ok, allowed} -> {:ok, allowed}
      _other -> {:error, :trusted_build_phase_rejected}
    end
  end

  @spec next_phase([atom()]) :: {:ok, atom()} | {:error, :trusted_build_phase_rejected}
  def next_phase([]), do: {:ok, :deps_get}
  def next_phase([:deps_get]), do: {:ok, :compile}
  def next_phase([:deps_get, :compile]), do: {:ok, :release}
  def next_phase(_completed), do: {:error, :trusted_build_phase_rejected}

  @spec admit_order(atom(), [atom()]) :: :ok | {:error, :trusted_build_phase_rejected}
  def admit_order(phase, completed) when is_atom(phase) and is_list(completed) do
    case next_phase(completed) do
      {:ok, ^phase} -> :ok
      _other -> {:error, :trusted_build_phase_rejected}
    end
  end

  def admit_order(_phase, _completed), do: {:error, :trusted_build_phase_rejected}

  @spec argv(atom()) :: [String.t()]
  def argv(phase) when is_map_key(@argv, phase), do: Map.fetch!(@argv, phase)

  @spec timeout_ms(atom()) :: pos_integer()
  def timeout_ms(phase) when is_map_key(@timeout_ms, phase), do: Map.fetch!(@timeout_ms, phase)

  @spec writable_names() :: [String.t()]
  def writable_names, do: @writable_names

  @spec env_keys() :: [String.t()]
  def env_keys, do: @env_keys

  @spec phase_index(atom()) :: non_neg_integer()
  def phase_index(phase), do: Map.fetch!(@phase_order, phase)

  @spec source_root(String.t()) :: String.t()
  def source_root(identity_path) when is_binary(identity_path),
    do: Path.join(identity_path, "source")

  @spec wrapper_path(String.t()) :: String.t()
  def wrapper_path(identity_path) when is_binary(identity_path),
    do: Path.join([identity_path, "source", "bin", "mix"])

  @spec closed_env(map(), map()) :: %{String.t() => String.t()}
  def closed_env(roots, binding) do
    erlang = binding.erlang_root.path
    elixir = binding.elixir_root.path
    tmp = roots.tmp.path

    %{
      "MIX_ENV" => "prod",
      "HEX_OFFLINE" => "1",
      "ARBOR_MIX_CONTAINED" => "1",
      "ARBOR_ERLANG_ROOT" => erlang,
      "ARBOR_ELIXIR_ROOT" => elixir,
      "HOME" => roots.home.path,
      "TMPDIR" => tmp,
      "TMP" => tmp,
      "HEX_HOME" => roots.hex.path,
      "MIX_HOME" => roots.mix.path,
      "MIX_ARCHIVES" => roots.archives.path,
      "MIX_DEPS_PATH" => roots.deps.path,
      "MIX_BUILD_PATH" => roots.build.path,
      "ELIXIR_MAKE_CACHE_DIR" => roots.cache.path,
      "ERL_CRASH_DUMP" => Path.join(tmp, "erl_crash.dump"),
      "PATH" => closed_path(erlang, elixir),
      "LANG" => "C",
      "LC_ALL" => "C"
    }
  end

  defp closed_path(erlang, elixir) do
    toolchain = Path.join(erlang, "bin") <> ":" <> Path.join(elixir, "bin")

    case :os.type() do
      {:unix, :darwin} -> toolchain <> ":" <> @darwin_utility_path
      _other -> toolchain
    end
  end
end
