defmodule Arbor.Actions.Security.Detectors.UriRegistration do
  @moduledoc """
  Whole-tree detector: every `arbor://` URI used in code should be covered by the
  canonical URI registry (`Arbor.Security.canonical_uri_prefixes/0`).

  A URI used in authorization but absent from the registry can be rejected when
  registry enforcement is enabled — exactly the gap that left
  `arbor://signals/subscribe` unregistered (Security Sentinel finding,
  2026-06-09). This detector generalizes that class.

  ## Heuristic (conservative, low false-positive)

  It extracts the static portion of each `arbor://` literal (the whole string for
  a plain literal, or the leading static segment for an interpolated one like
  `"arbor://fs/\#{op}"`). A static prefix `S` is flagged only when it is
  *definitely uncovered*: no canonical prefix `P` satisfies
  `starts_with?(S, P) or starts_with?(P, S)`. The `starts_with?(P, S)` arm gives
  interpolations the benefit of the doubt (e.g. `"arbor://fs/"` is covered by the
  more specific `"arbor://fs/read"`).

  URIs that appear only in `@moduledoc`/`@doc`/etc. (documentation examples) are
  excluded. Comments are dropped by the parser and never seen.
  """

  alias Arbor.Contracts.Security.Finding

  @doc_attrs [:moduledoc, :doc, :shortdoc, :typedoc]
  @uri_regex ~r{arbor://[A-Za-z0-9_/.*\-]+}

  @spec detect(keyword()) :: [Finding.t()]
  def detect(opts \\ []) do
    root = Keyword.get(opts, :root, "apps")
    git_sha = Keyword.get(opts, :git_sha)
    prefixes = canonical_prefixes()

    if prefixes == [] do
      []
    else
      Path.wildcard(Path.join(root, "**/*.ex"))
      |> Enum.reject(&String.contains?(&1, "/test/"))
      |> Enum.flat_map(&analyze_file(&1, prefixes, git_sha))
    end
  end

  # ---------------------------------------------------------------------------

  defp canonical_prefixes do
    if Code.ensure_loaded?(Arbor.Security) and
         function_exported?(Arbor.Security, :canonical_uri_prefixes, 0) do
      Arbor.Security.canonical_uri_prefixes()
    else
      []
    end
  rescue
    _ -> []
  end

  defp analyze_file(file, prefixes, git_sha) do
    case parse(file) do
      {:ok, ast} ->
        excluded = MapSet.union(doc_uris(ast), source_uris(ast))

        ast
        |> code_uris()
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(excluded, &1))
        |> Enum.reject(&covered?(&1, prefixes))
        |> Enum.map(&finding(file, &1, git_sha))

      _ ->
        []
    end
  end

  # arbor:// literals that are provenance/source identifiers, not capabilities —
  # the body of a `*_source` function (e.g. `bridge_source(id), do:
  # "arbor://bridge/\#{id}"`, used as a signal `source:` tag, never authorized).
  defp source_uris(ast) do
    {_, uris} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, [do: body]]} = node, acc when kind in [:def, :defp] ->
          case fun_name(head) do
            name when is_atom(name) ->
              if String.ends_with?(Atom.to_string(name), "_source"),
                do: {node, body_uris(body) ++ acc},
                else: {node, acc}

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    MapSet.new(uris)
  end

  defp fun_name({:when, _, [{n, _, _} | _]}) when is_atom(n), do: n
  defp fun_name({n, _, _}) when is_atom(n), do: n
  defp fun_name(_), do: nil

  defp body_uris(body) do
    {_, uris} =
      Macro.prewalk(body, [], fn
        str, acc when is_binary(str) -> {str, extract(str) ++ acc}
        node, acc -> {node, acc}
      end)

    uris
  end

  defp parse(file) do
    with {:ok, code} <- File.read(file) do
      Code.string_to_quoted(code)
    end
  end

  # Every arbor:// literal in code (plain strings + interpolation segments are
  # both bare binaries in the AST).
  defp code_uris(ast) do
    {_, uris} =
      Macro.prewalk(ast, [], fn
        str, acc when is_binary(str) -> {str, extract(str) ++ acc}
        node, acc -> {node, acc}
      end)

    uris
  end

  # arbor:// literals that appear in documentation attributes (to exclude).
  defp doc_uris(ast) do
    {_, uris} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{attr, _, [arg]}]} = node, acc when attr in @doc_attrs and is_binary(arg) ->
          {node, extract(arg) ++ acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.new(uris)
  end

  defp extract(str) do
    if String.contains?(str, "arbor://"),
      do: Regex.scan(@uri_regex, str) |> List.flatten(),
      else: []
  end

  defp covered?(uri, prefixes) do
    s = normalize(uri)

    Enum.any?(prefixes, fn p ->
      String.starts_with?(s, p) or String.starts_with?(p, s)
    end)
  end

  # Strip trailing capability wildcards (`/**`, `/*`) so a registered namespace
  # isn't flagged just because a grant uses a subtree wildcard
  # (e.g. `arbor://fs/**` → `arbor://fs/`, covered by `arbor://fs/read`).
  defp normalize(uri) do
    uri
    |> String.replace(~r{/\*+$}, "/")
    |> String.replace(~r{\*+$}, "")
  end

  defp finding(file, uri, git_sha) do
    Finding.new(
      category: :unregistered_uri,
      title: "arbor:// URI `#{uri}` is not covered by the canonical registry",
      git_sha: git_sha,
      detector: %{layer: "L0b", name: "uri_registration", version: "1"},
      severity: %{level: :medium},
      confidence: %{score: 0.6, rationale: "no canonical prefix covers this URI"},
      location: %{library: library_of(file), file: file, resource_uri: uri},
      invariant_violated:
        "Every arbor:// URI used in authorization must be in the canonical URI registry, or it can be rejected when registry enforcement is enabled.",
      evidence: %{uri: uri},
      recommendation: %{
        approach:
          "Register `#{uri}` (its prefix) in Arbor.Security.UriRegistry @canonical_prefixes, or confirm it is not an authorization URI."
      },
      actionability: %{auto_fixable: false, risk_class: :medium},
      verification: %{must_fail_on_revert: true}
    )
  end

  defp library_of(file) do
    case Regex.run(~r{apps/([^/]+)/}, file) do
      [_, lib] -> lib
      _ -> nil
    end
  end
end
