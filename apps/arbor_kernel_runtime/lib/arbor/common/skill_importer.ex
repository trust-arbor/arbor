defmodule Arbor.Common.SkillImporter do
  @moduledoc """
  Import external skills with security validation and taint tagging.

  All imported skills receive `taint: :untrusted` by default. The importer
  validates SKILL.md format per the Agent Skills spec and records provenance
  metadata. A configured skill-import security module must approve the full
  parsed skill. Imports fail closed when that provider is absent or invalid.

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

  alias Arbor.Common.Config
  alias Arbor.Common.SkillLibrary.SkillAdapter

  require Logger

  @admitted_security_errors [
    :blocked,
    :invalid_skill,
    :malformed_reflex_result,
    :reflex_unavailable
  ]

  @max_security_payload_bytes 524_288

  @doc """
  Scan a directory for SKILL.md files and optionally import them.

  ## Options

  - `:approve` — if true, register skills in library (default: false, preview only)
  - `:overwrite` — overwrite existing skills (default: false)
  """
  @spec import_from_directory(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_from_directory(path, opts \\ []) do
    approve = Keyword.get(opts, :approve, false)

    allowed_root = Keyword.get(opts, :allowed_root, File.cwd!())

    with {:ok, resolved_path} <- validate_path(path, allowed_root),
         {:ok, provider} <- security_provider(),
         {:ok, files} <- scan_directory(resolved_path) do
      results =
        files
        |> Enum.map(&parse_and_tag/1)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, skill} -> skill end)
        |> Enum.filter(&passes_security_checks?(provider, &1))

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
      with :ok <- validate_git_url(repo_url),
           :ok <- validate_git_branch(branch) do
        case System.cmd(
               "git",
               ["clone", "--depth", "1", "--branch", branch, "--", repo_url, tmp_dir],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            import_from_directory(tmp_dir, Keyword.put(opts, :allowed_root, tmp_dir))

          {output, _code} ->
            {:error, {:git_clone_failed, output}}
        end
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

  defp validate_path(path, allowed_root)
       when is_binary(path) and is_binary(allowed_root) do
    with {:ok, resolved} <- Arbor.Common.SafePath.resolve_within(path, allowed_root),
         true <- File.dir?(resolved) do
      {:ok, resolved}
    else
      false -> {:error, {:not_a_directory, path}}
      {:error, reason} -> {:error, {reason, path}}
    end
  end

  defp validate_path(path, _allowed_root), do: {:error, {:invalid_path, path}}

  defp validate_git_url(repo_url) when is_binary(repo_url) do
    case URI.parse(repo_url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["https", "ssh"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, :unsupported_git_url}
    end
  end

  defp validate_git_url(_repo_url), do: {:error, :unsupported_git_url}

  defp validate_git_branch(branch) when is_binary(branch) do
    valid? =
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/, branch) and
        not String.contains?(branch, ["..", "@{", "//"]) and
        not String.ends_with?(branch, ["/", ".", ".lock"])

    if valid?, do: :ok, else: {:error, :invalid_git_branch}
  end

  defp validate_git_branch(_branch), do: {:error, :invalid_git_branch}

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

  defp security_provider do
    case Config.skill_import_security_module() do
      nil ->
        {:error, :security_scanner_unavailable}

      provider when is_atom(provider) ->
        if Code.ensure_loaded?(provider) and
             function_exported?(provider, :validate_imported_skill, 1),
           do: {:ok, provider},
           else: {:error, :security_scanner_unavailable}

      _invalid ->
        {:error, :security_scanner_unavailable}
    end
  end

  defp passes_security_checks?(provider, skill) do
    case security_view(skill) do
      {:ok, view} ->
        check_with_provider(provider, view)

      {:error, reason} ->
        log_reject(skill, reason)
        false
    end
  end

  # The current security port accepts one skill map and providers commonly
  # inspect `:body`. Fold every parsed field into that body so descriptions,
  # tags, metadata, and adapter-specific fields cannot bypass the screen.
  defp security_view(skill) do
    payload =
      skill
      |> Map.drop([:provenance, "provenance"])
      |> inspect(limit: :infinity, printable_limit: :infinity, width: 120)

    if byte_size(payload) <= @max_security_payload_bytes,
      do: {:ok, Map.put(skill, :body, payload)},
      else: {:error, :security_payload_too_large}
  end

  defp check_with_provider(provider, skill) do
    case provider.validate_imported_skill(skill) do
      :ok ->
        true

      {:error, reason} when reason in @admitted_security_errors ->
        log_reject(skill, reason)
        false

      {:error, _other} ->
        log_reject(skill, :malformed_result)
        false

      _other ->
        log_reject(skill, :malformed_result)
        false
    end
  rescue
    exception ->
      log_reject(skill, :provider_raised, exception.__struct__)
      false
  catch
    :throw, _ ->
      log_reject(skill, :provider_threw)
      false

    :exit, _ ->
      log_reject(skill, :provider_exited)
      false
  end

  defp log_reject(skill, reason) do
    Logger.warning("[SkillImporter] rejected imported skill #{skill_name(skill)}: #{reason}")
  end

  defp log_reject(skill, :provider_raised, exception_struct) do
    Logger.warning(
      "[SkillImporter] rejected imported skill #{skill_name(skill)}: provider_raised #{inspect(exception_struct)}"
    )
  end

  defp skill_name(skill) do
    case Map.get(skill, :name) || Map.get(skill, "name") do
      name when is_binary(name) ->
        if Regex.match?(~r/\A[a-z0-9][a-z0-9\-]{0,63}\z/, name) do
          name
        else
          "unknown"
        end

      _ ->
        "unknown"
    end
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

  defp do_register(struct, skill, lib, true = _overwrite) do
    # An import may replace only another untrusted runtime entry. Bundled,
    # operator, or otherwise elevated content cannot be shadowed by an import.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(lib, :get, [Map.get(skill, :name)]) do
      {:error, :not_found} -> apply(lib, :register, [struct]) == :ok
      {:ok, existing} -> untrusted?(existing) and apply(lib, :register, [struct]) == :ok
      _ -> false
    end
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

  defp untrusted?(skill) do
    taint = Map.get(skill, :taint) || Map.get(skill, "taint")
    taint in [:untrusted, "untrusted"]
  end

  defp compute_hash(skill) do
    body = Map.get(skill, :body) || ""
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end
end
