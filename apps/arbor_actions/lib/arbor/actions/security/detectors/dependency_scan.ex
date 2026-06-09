defmodule Arbor.Actions.Security.Detectors.DependencyScan do
  @moduledoc """
  Supply-chain dependency detector for the Security Sentinel.

  Two checks:

    * **Mutable git deps (static, fast, always on):** a dependency pulled from
      git pinned to a `branch:` — or to nothing (the default branch) — instead of
      an immutable `ref:` (commit SHA) or `tag:`. Such a dep floats with upstream:
      any push changes what you build, unreviewed. Parsed from `mix.exs` files.

    * **Retired / advisory packages (opt-in, `audit: true`):** runs `mix hex.audit`
      and flags packages the Hex registry has retired (security advisories,
      invalid releases). Off by default (subprocess + network) so the fast scan
      stays fast; the dependency action / daily pipeline enables it.

  Findings use the `:dependency_risk` category.
  """

  alias Arbor.Contracts.Security.Finding

  @doc """
  Detect dependency risks. Options:

    * `:mix_files` — explicit list of mix.exs paths (default: repo root + apps)
    * `:audit` — also run `mix hex.audit` (default `false`)
    * `:git_sha` — provenance
  """
  @spec detect(keyword()) :: [Finding.t()]
  def detect(opts \\ []) do
    git_sha = Keyword.get(opts, :git_sha)
    mix_files = Keyword.get(opts, :mix_files) || default_mix_files()

    mutable_git_findings(mix_files, git_sha) ++
      if(Keyword.get(opts, :audit, false), do: audit_findings(git_sha), else: [])
  end

  defp default_mix_files do
    Path.wildcard("mix.exs") ++ Path.wildcard("apps/*/mix.exs")
  end

  # -- mutable git deps -------------------------------------------------------

  defp mutable_git_findings(mix_files, git_sha) do
    Enum.flat_map(mix_files, fn file ->
      file
      |> deps_in_file()
      |> Enum.filter(&mutable_git_dep?/1)
      |> Enum.map(fn {name, _opts} -> git_finding(file, name, git_sha) end)
    end)
  end

  defp deps_in_file(file) do
    with {:ok, code} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(code),
         body when not is_nil(body) <- deps_body(ast) do
      collect_dep_tuples(body)
    else
      _ -> []
    end
  end

  defp deps_body(ast) do
    {_, body} =
      Macro.prewalk(ast, nil, fn
        {kind, _, [{:deps, _, ctx}, [do: b]]} = node, _acc
        when kind in [:def, :defp] and ctx in [nil, []] ->
          {node, b}

        node, acc ->
          {node, acc}
      end)

    body
  end

  # Returns [{name, opts_keyword_list}] for every dependency tuple in the body.
  defp collect_dep_tuples(body) do
    {_, deps} =
      Macro.prewalk(body, [], fn
        {name, opts} = node, acc when is_atom(name) and is_list(opts) ->
          {node, [{name, opts} | acc]}

        {:{}, _, [name, _version, opts]} = node, acc when is_atom(name) and is_list(opts) ->
          {node, [{name, opts} | acc]}

        node, acc ->
          {node, acc}
      end)

    deps
  end

  defp mutable_git_dep?({_name, opts}) do
    git? = Keyword.has_key?(opts, :git) or Keyword.has_key?(opts, :github)
    pinned? = Keyword.has_key?(opts, :ref) or Keyword.has_key?(opts, :tag)
    git? and not pinned?
  end

  defp git_finding(file, name, git_sha) do
    Finding.new(
      category: :dependency_risk,
      title: "Git dependency `#{name}` is not pinned to an immutable ref/tag",
      git_sha: git_sha,
      detector: %{layer: "L0b", name: "dependency_scan", version: "1"},
      severity: %{level: :medium},
      confidence: %{score: 0.85, rationale: "git dep with branch/default, no ref/tag"},
      location: %{library: library_of(file), file: file, function: "deps/0"},
      invariant_violated:
        "Git dependencies must be pinned to an immutable ref (commit SHA) or tag — a branch floats with upstream and changes the build unreviewed.",
      evidence: %{dependency: name},
      recommendation: %{
        approach:
          "Pin `#{name}` to `ref: \"<sha>\"` (or a `tag:`) instead of a branch, so upstream changes are reviewed before they enter the build."
      },
      actionability: %{auto_fixable: false, risk_class: :medium},
      verification: %{must_fail_on_revert: true}
    )
  end

  # -- hex.audit (retired packages) -------------------------------------------

  defp audit_findings(git_sha) do
    case System.cmd("mix", ["hex.audit"], stderr_to_stdout: true) do
      {output, _status} -> parse_audit(output, git_sha)
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp parse_audit(output, _git_sha) when is_binary(output) do
    if String.contains?(output, "No retired packages") do
      []
    else
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&audit_line/1)
    end
  end

  # A retired-package row from `mix hex.audit` looks like:
  #   "  package  1.2.3  (security) reason..."
  defp audit_line(line) do
    case Regex.run(~r/^\s*([a-z][a-z0-9_]+)\s+(\S+)\s+\((\w+)\)\s*(.*)$/, line) do
      [_, pkg, version, reason_kind, reason] ->
        [retired_finding(pkg, version, reason_kind, reason)]

      _ ->
        []
    end
  end

  defp retired_finding(pkg, version, reason_kind, reason) do
    Finding.new(
      category: :dependency_risk,
      title: "Dependency `#{pkg}` #{version} is retired (#{reason_kind})",
      detector: %{layer: "L0b", name: "dependency_scan", version: "1"},
      severity: %{level: if(reason_kind == "security", do: :high, else: :medium)},
      confidence: %{score: 0.95, rationale: "mix hex.audit"},
      location: %{file: "mix.lock", function: "hex.audit"},
      invariant_violated:
        "Dependencies must not be retired by the Hex registry (security advisory or invalid release).",
      evidence: %{dependency: pkg, version: version, reason: reason},
      recommendation: %{approach: "Upgrade `#{pkg}` past the retired #{version} (#{reason})."},
      actionability: %{auto_fixable: false, risk_class: :medium},
      verification: %{must_fail_on_revert: false}
    )
  end

  defp library_of(file) do
    case Regex.run(~r{apps/([^/]+)/}, file) do
      [_, lib] -> lib
      _ -> "umbrella"
    end
  end
end
