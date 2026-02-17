defmodule Arbor.Common.SkillLibrary.DotCache do
  @moduledoc """
  Content-hash-based cache for JIT-compiled DOT graphs.

  Stores compiled DOT files alongside their source SKILL.md files.
  Uses a header comment with content hash and timestamp to detect staleness.

  ## Cache Layout

  For a skill at `.arbor/skills/efficiency/SKILL.md`, the compiled DOT
  is stored at `.arbor/skills/efficiency/COMPILED.dot` with a header:

      // arbor:content_hash=abc123... compiled_at=2026-02-17T00:00:00Z
      digraph efficiency {
        ...
      }

  ## Usage

      # Check if cache is stale
      DotCache.stale?("efficiency", "abc123...")

      # Get cached DOT path
      {:ok, path} = DotCache.get("efficiency", "abc123...")

      # Store compiled DOT
      {:ok, path} = DotCache.put("efficiency", "abc123...", dot_content)
  """

  @compiled_filename "COMPILED.dot"

  @doc """
  Get the path to the cached DOT file for a skill.

  Returns `{:ok, path}` if the cache exists and hash matches,
  `{:error, :not_found}` otherwise.
  """
  @spec get(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found | :stale}
  def get(skill_name, content_hash) do
    case find_skill_dir(skill_name) do
      {:ok, dir} ->
        dot_path = Path.join(dir, @compiled_filename)

        if File.exists?(dot_path) do
          case read_header_hash(dot_path) do
            ^content_hash -> {:ok, dot_path}
            _ -> {:error, :stale}
          end
        else
          {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Store a compiled DOT graph in the cache.

  Writes the DOT content with a header comment containing the content hash
  and compilation timestamp.
  """
  @spec put(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def put(skill_name, content_hash, dot_content) do
    {:ok, dir} = find_or_create_skill_dir(skill_name)
    dot_path = Path.join(dir, @compiled_filename)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    header = "// arbor:content_hash=#{content_hash} compiled_at=#{timestamp}\n"
    full_content = header <> dot_content

    case File.write(dot_path, full_content) do
      :ok -> {:ok, dot_path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if the cached DOT for a skill is stale (hash mismatch or missing).
  """
  @spec stale?(String.t(), String.t()) :: boolean()
  def stale?(skill_name, content_hash) do
    case get(skill_name, content_hash) do
      {:ok, _} -> false
      _ -> true
    end
  end

  # -- Private ----------------------------------------------------------------

  # Find the directory containing the skill's SKILL.md
  defp find_skill_dir(skill_name) do
    lib = Arbor.Common.SkillLibrary

    if Code.ensure_loaded?(lib) and function_exported?(lib, :get, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(lib, :get, [skill_name]) do
        {:ok, skill} ->
          path = Map.get(skill, :path)

          if path do
            {:ok, Path.dirname(path)}
          else
            # Fall back to default skill directory
            default_dir(skill_name)
          end

        {:error, _} ->
          default_dir(skill_name)
      end
    else
      default_dir(skill_name)
    end
  rescue
    _ -> default_dir(skill_name)
  catch
    :exit, _ -> default_dir(skill_name)
  end

  defp find_or_create_skill_dir(skill_name) do
    dir =
      case find_skill_dir(skill_name) do
        {:ok, d} -> d
        :error -> Path.join([File.cwd!(), ".arbor", "skills", skill_name])
      end

    File.mkdir_p(dir)
    {:ok, dir}
  end

  defp default_dir(skill_name) do
    dir = Path.join([File.cwd!(), ".arbor", "skills", skill_name])

    if File.dir?(dir) do
      {:ok, dir}
    else
      :error
    end
  end

  # Read the content hash from the DOT file's header comment
  defp read_header_hash(dot_path) do
    case File.read(dot_path) do
      {:ok, content} ->
        case Regex.run(~r/^\/\/ arbor:content_hash=(\S+)/, content) do
          [_, hash] -> hash
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end
end
