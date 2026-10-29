defmodule Arbor.Common.InstructionTrust do
  @moduledoc """
  Classifies instruction and context files as trusted or untrusted.

  Approved folders are configured trusted roots plus the agent's own config
  directory (`ARBOR_HOME` or `~/.arbor`). Paths are canonicalized with
  symlinks resolved and compared segment-safely, so a neighbor such as
  `/tmp/approved-evil` is never treated as inside `/tmp/approved`.
  """

  alias Arbor.Common.Config
  alias Arbor.Common.SafePath

  @type classify_opt ::
          {:trusted_roots, [String.t()]}
          | {:agent_config_dir, String.t() | nil}
          | {:additional_roots, [String.t()]}

  @doc """
  Canonicalize `path` with `~` expansion and symlink resolution.

  Returns `{:error, :not_found}` when the path does not exist.
  """
  @spec canonicalize(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded = Path.expand(path)

    with :ok <- SafePath.validate(expanded) do
      SafePath.resolve_real(expanded)
    end
  end

  def canonicalize(_path), do: {:error, :invalid_path}

  @doc """
  Segment-safe containment for already-canonical paths.

  Rejects the filesystem root as an approved folder.
  """
  @spec contained_in?(String.t(), String.t()) :: boolean()
  def contained_in?(path, root) when is_binary(path) and is_binary(root) do
    root != "/" and root != "" and
      (path == root or String.starts_with?(path, root <> "/"))
  end

  def contained_in?(_path, _root), do: false

  @doc """
  Approved instruction roots: configured trusted roots, optional extra roots,
  and the agent's config directory.
  """
  @spec approved_roots([classify_opt()]) :: [String.t()]
  def approved_roots(opts \\ []) do
    configured = Keyword.get(opts, :trusted_roots, Config.instruction_trusted_roots())
    additional = Keyword.get(opts, :additional_roots, [])
    agent_dir = Keyword.get(opts, :agent_config_dir) || default_agent_config_dir()

    [agent_dir | List.wrap(configured) ++ List.wrap(additional)]
    |> Enum.flat_map(&canonicalize_root/1)
    |> Enum.uniq()
  end

  @doc "Classify a file or directory path as `:trusted` or `:untrusted`."
  @spec classify(Path.t(), [classify_opt()]) :: :trusted | :untrusted
  def classify(path, opts \\ []) do
    roots = approved_roots(opts)

    case canonicalize(path) do
      {:ok, real} ->
        if Enum.any?(roots, &contained_in?(real, &1)), do: :trusted, else: :untrusted

      _ ->
        :untrusted
    end
  end

  @doc "True when `path` resolves inside an approved folder."
  @spec trusted?(Path.t(), [classify_opt()]) :: boolean()
  def trusted?(path, opts \\ []), do: classify(path, opts) == :trusted

  defp canonicalize_root(path) when is_binary(path) do
    case canonicalize(path) do
      {:ok, real} when real != "/" ->
        case File.lstat(real) do
          {:ok, %File.Stat{type: :directory}} -> [real]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp canonicalize_root(_path), do: []

  defp default_agent_config_dir do
    System.get_env("ARBOR_HOME") || Path.expand("~/.arbor")
  end
end
