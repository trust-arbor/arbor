defmodule Arbor.Common.SkillImporter do
  @moduledoc """
  Import external skills with security validation and taint tagging.

  All imported skills receive `taint: :untrusted` by default. The importer
  validates SKILL.md format per the Agent Skills spec, records provenance
  metadata, and runs reflex checks on skill names and bodies.

  ## Two-Phase Import

  1. **Preview** (`approve: false`) — scan and validate, return summaries
  2. **Import** (`approve: true`) — register skills in the library as untrusted

  ## Usage

      # Preview what would be imported
      {:ok, result} = SkillImporter.import_from_directory("/path/to/skills")
      # => %{count: 3, skills: [%{name: ..., taint: :untrusted}, ...], preview: true}

      # Actually import
      {:ok, result} = SkillImporter.import_from_directory("/path/to/skills", approve: true)
      # => %{count: 3, skills: [...], preview: false}
  """

  alias Arbor.Common.SkillLibrary.SkillAdapter

  require Logger

  @doc """
  Scan a directory for SKILL.md files and optionally import them.

  ## Options

  - `:approve` — if true, register skills in library (default: false, preview only)
  - `:overwrite` — overwrite existing skills (default: false)
  """
  @spec import_from_directory(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_from_directory(path, opts \\ []) do
    approve = Keyword.get(opts, :approve, false)

    with :ok <- validate_path(path),
         {:ok, files} <- scan_directory(path) do
      results =
        files
        |> Enum.map(&parse_and_tag/1)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, skill} -> skill end)
        |> Enum.filter(&passes_reflex_checks?/1)

      if approve do
        registered = register_skills(results, opts)
        {:ok, %{count: length(registered), skills: summarize(registered), preview: false}}
      else
        {:ok, %{count: length(results), skills: summarize(results), preview: true}}
      end
    end
  end

  @doc """
  Import skills from a git repository.

  Clones the repo to a temporary directory, scans for skills, and optionally
  imports them. The temporary directory is cleaned up after import.

  ## Options

  Same as `import_from_directory/2` plus:
  - `:branch` — git branch to clone (default: "main")
  """
  @spec import_from_git(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_from_git(repo_url, opts \\ []) do
    branch = Keyword.get(opts, :branch, "main")

    tmp_dir =
      System.tmp_dir!() |> Path.join("arbor_skill_import_#{:erlang.unique_integer([:positive])}")

    try do
      case System.cmd("git", ["clone", "--depth", "1", "--branch", branch, repo_url, tmp_dir],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          result = import_from_directory(tmp_dir, opts)
          result

        {output, _code} ->
          {:error, {:git_clone_failed, output}}
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  @doc """
  Validate and tag a skill with taint and provenance metadata.
  """
  @spec validate_and_tag(map() | struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_and_tag(skill, opts \\ []) do
    taint = Keyword.get(opts, :taint, :untrusted)
    source_url = Keyword.get(opts, :source_url)

    with :ok <- validate_name_format(skill) do
      tagged =
        skill
        |> maybe_to_map()
        |> Map.put(:taint, taint)
        |> Map.put(:provenance, %{
          source_url: source_url,
          imported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          content_hash: Map.get(skill, :content_hash) || compute_hash(skill)
        })

      {:ok, tagged}
    end
  end

  # -- Private ----------------------------------------------------------------

  defp validate_path(path) do
    safe_path_mod = Arbor.Common.SafePath

    if Code.ensure_loaded?(safe_path_mod) and
         function_exported?(safe_path_mod, :resolve_within, 2) do
      # Validate the path doesn't escape allowed roots
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(safe_path_mod, :resolve_within, [path, File.cwd!()]) do
        {:ok, _resolved} -> :ok
        {:error, _} -> validate_path_basic(path)
      end
    else
      validate_path_basic(path)
    end
  end

  defp validate_path_basic(path) do
    expanded = Path.expand(path)

    cond do
      not File.dir?(expanded) -> {:error, {:not_a_directory, path}}
      String.contains?(path, "..") -> {:error, {:path_traversal, path}}
      true -> :ok
    end
  end

  defp scan_directory(path) do
    expanded = Path.expand(path)
    files = SkillAdapter.list(expanded)
    {:ok, files}
  end

  defp parse_and_tag(file_path) do
    case SkillAdapter.parse(file_path) do
      {:ok, skill} ->
        skill
        |> maybe_to_map()
        |> Map.put(:taint, :untrusted)
        |> Map.put(:provenance, %{
          source_path: file_path,
          imported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          content_hash: Map.get(skill, :content_hash) || compute_hash(skill)
        })
        |> then(&{:ok, &1})

      {:error, reason} ->
        Logger.debug("[SkillImporter] Skipping #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp passes_reflex_checks?(skill) do
    reflex_mod = Arbor.Security.Reflex

    if Code.ensure_loaded?(reflex_mod) and function_exported?(reflex_mod, :check, 2) do
      name = Map.get(skill, :name, "")
      body = Map.get(skill, :body, "")

      # Check skill name against reflex patterns
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      name_ok =
        case apply(reflex_mod, :check, [:command, %{command: name}]) do
          :ok -> true
          {:blocked, _} -> false
        end

      # Check body for suspicious content (using url context as closest fit)
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      body_ok =
        case apply(reflex_mod, :check, [:url, %{url: body}]) do
          :ok -> true
          {:blocked, _} -> false
        end

      if not name_ok do
        Logger.warning("[SkillImporter] Reflex blocked skill name: #{name}")
      end

      name_ok and body_ok
    else
      # No reflex system — allow all
      true
    end
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  defp validate_name_format(skill) do
    name = Map.get(skill, :name, "")

    if Regex.match?(~r/\A[a-z0-9][a-z0-9\-]{0,63}\z/, name) do
      :ok
    else
      {:error, {:invalid_name, name, "must be lowercase alphanumeric with hyphens, 1-64 chars"}}
    end
  end

  defp register_skills(skills, opts) do
    lib = Arbor.Common.SkillLibrary
    overwrite = Keyword.get(opts, :overwrite, false)

    if Code.ensure_loaded?(lib) and function_exported?(lib, :register, 1) do
      Enum.filter(skills, &register_skill(&1, lib, overwrite))
    else
      []
    end
  end

  defp register_skill(skill, lib, overwrite) do
    case build_skill_struct(skill) do
      {:ok, struct} ->
        do_register(struct, skill, lib, overwrite)

      {:error, _} ->
        false
    end
  end

  defp do_register(struct, _skill, lib, true = _overwrite) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(lib, :register, [struct]) == :ok
  end

  defp do_register(struct, skill, lib, false = _overwrite) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(lib, :get, [Map.get(skill, :name)]) do
      {:error, :not_found} -> apply(lib, :register, [struct]) == :ok
      _ -> false
    end
  end

  defp build_skill_struct(attrs) do
    skill_mod = Arbor.Contracts.Skill

    if Code.ensure_loaded?(skill_mod) and function_exported?(skill_mod, :new, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(skill_mod, :new, [attrs])
    else
      {:ok, attrs}
    end
  end

  defp summarize(skills) do
    Enum.map(skills, fn skill ->
      %{
        name: Map.get(skill, :name),
        description: Map.get(skill, :description),
        taint: to_string(Map.get(skill, :taint, :untrusted)),
        content_hash: Map.get(skill, :content_hash) || get_in(skill, [:provenance, :content_hash])
      }
    end)
  end

  defp maybe_to_map(skill) when is_struct(skill), do: Map.from_struct(skill)
  defp maybe_to_map(skill) when is_map(skill), do: skill

  defp compute_hash(skill) do
    body = Map.get(skill, :body) || ""
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end
end
