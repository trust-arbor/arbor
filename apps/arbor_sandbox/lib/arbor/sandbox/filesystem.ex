defmodule Arbor.Sandbox.Filesystem do
  @moduledoc """
  Filesystem sandbox for per-agent isolation.

  Provides scoped filesystem access with path validation
  to prevent directory traversal and unauthorized access.
  """

  @default_base_path "/tmp/arbor/agents"

  @type t :: %{
          agent_id: String.t(),
          base_path: String.t(),
          level: atom()
        }

  @doc """
  Create a filesystem sandbox for an agent.
  """
  @spec create(String.t(), atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def create(agent_id, level, opts \\ []) do
    base = Keyword.get(opts, :base_path, @default_base_path)
    agent_path = Path.join(base, sanitize_agent_id(agent_id))

    # Ensure the directory exists
    case File.mkdir_p(agent_path) do
      :ok ->
        {:ok,
         %{
           agent_id: agent_id,
           base_path: agent_path,
           level: level
         }}

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  @doc """
  Check if an operation is allowed on a path.
  """
  @spec check(t() | nil, String.t(), :read | :write | :delete, atom()) ::
          :ok | {:error, term()}
  def check(nil, _path, _operation, _level), do: {:error, :no_filesystem_sandbox}

  def check(fs, path, operation, level) do
    with :ok <- validate_path(fs, path) do
      check_level_permission(level, operation)
    end
  end

  @doc """
  Resolve a relative path to its sandboxed absolute path.
  """
  @spec resolve_path(t() | nil, String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_path(nil, _path), do: {:error, :no_filesystem_sandbox}

  def resolve_path(fs, relative_path) do
    # Remove leading slash if present
    clean_path = String.trim_leading(relative_path, "/")

    # Build absolute path
    absolute = Path.join(fs.base_path, clean_path)

    # Expand to resolve any .. or . components
    expanded = Path.expand(absolute)

    # Verify it's still within the sandbox
    if String.starts_with?(expanded, fs.base_path) do
      {:ok, expanded}
    else
      {:error, :path_traversal_blocked}
    end
  end

  @doc """
  Clean up sandbox resources.
  """
  @spec cleanup(t() | nil) :: :ok
  def cleanup(nil), do: :ok

  def cleanup(fs) do
    # Optionally remove the agent's directory
    # For safety, we just leave it for now
    _ = fs
    :ok
  end

  @doc """
  List files in the sandbox.
  """
  @spec list_files(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_files(fs, relative_path \\ "/") do
    with {:ok, absolute} <- resolve_path(fs, relative_path) do
      case File.ls(absolute) do
        {:ok, files} -> {:ok, files}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Check if a path exists in the sandbox.
  """
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(fs, relative_path) do
    case resolve_path(fs, relative_path) do
      {:ok, absolute} -> File.exists?(absolute)
      {:error, _} -> false
    end
  end

  # Private functions

  defp sanitize_agent_id(agent_id) do
    # Remove any path-unsafe characters
    agent_id
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> String.slice(0, 64)
  end

  defp validate_path(fs, path) do
    case resolve_path(fs, path) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp check_level_permission(:pure, :read), do: :ok
  defp check_level_permission(:pure, _), do: {:error, :write_not_allowed_in_pure_mode}
  defp check_level_permission(:limited, _), do: :ok
  defp check_level_permission(:full, _), do: :ok
  defp check_level_permission(:container, _), do: :ok
  defp check_level_permission(_, _), do: {:error, :unknown_level}
end
