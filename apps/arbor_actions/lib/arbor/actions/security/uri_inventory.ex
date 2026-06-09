defmodule Arbor.Actions.Security.UriInventory do
  @moduledoc """
  Cross-references every `arbor://` URI namespace used in the codebase against
  the canonical registry and the set of Arbor actions, so registry gaps can be
  triaged: which namespaces *must* be registered (action-backed or otherwise
  reaching `authorize`), which are partial sub-path gaps in an already-registered
  namespace, and which are grant-only (candidates for registration or removal).

  Built for the Security Sentinel's URI-registration triage. Re-run after adding
  an action, grant, or namespace to catch drift.
  """

  @doc_attrs [:moduledoc, :doc, :shortdoc, :typedoc]
  @uri_regex ~r{arbor://[A-Za-z0-9_/.*\-]+}

  @type row :: %{
          namespace: String.t(),
          in_registry: boolean(),
          action_backed: boolean(),
          uncovered: [String.t()],
          count: non_neg_integer(),
          files: [String.t()],
          recommendation: String.t()
        }

  @doc "Build the inventory rows for `.ex` files under `root`. Gaps sorted first."
  @spec build(String.t()) :: [row()]
  def build(root \\ "apps") do
    prefixes = canonical_prefixes()
    reg_ns = prefixes |> Enum.map(&ns/1) |> MapSet.new()
    action_ns = action_namespaces()

    scan(root)
    |> Enum.group_by(fn {uri, _file} -> ns(uri) end)
    |> Enum.map(fn {namespace, occ} ->
      uncovered =
        occ |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.reject(&covered?(&1, prefixes))

      in_reg = MapSet.member?(reg_ns, namespace)
      backed = MapSet.member?(action_ns, namespace)

      %{
        namespace: namespace,
        in_registry: in_reg,
        action_backed: backed,
        uncovered: uncovered,
        count: length(occ),
        files: occ |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.take(3),
        recommendation: recommend(uncovered, in_reg, backed)
      }
    end)
    |> Enum.sort_by(fn r -> {r.uncovered == [], r.namespace} end)
  end

  defp recommend([], _in_reg, _backed), do: "ok"
  defp recommend(_unc, _in_reg, true), do: "REGISTER (action-backed)"
  defp recommend(_unc, true, _backed), do: "REGISTER sub-path (partial gap)"
  defp recommend(_unc, false, false), do: "TRIAGE (grant-only: register or remove)"

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

  defp action_namespaces do
    if Code.ensure_loaded?(Arbor.Actions) and
         function_exported?(Arbor.Actions, :all_actions, 0) do
      Arbor.Actions.all_actions()
      |> Enum.map(fn m ->
        try do
          Arbor.Actions.canonical_uri_for(m, %{})
        rescue
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&ns/1)
      |> MapSet.new()
    else
      MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  defp ns(uri) do
    case String.split(uri, "/") do
      ["arbor:", "", segment | _] -> segment
      _ -> uri
    end
  end

  defp covered?(uri, prefixes) do
    s = normalize(uri)
    Enum.any?(prefixes, fn p -> String.starts_with?(s, p) or String.starts_with?(p, s) end)
  end

  defp normalize(uri) do
    uri |> String.replace(~r{/\*+$}, "/") |> String.replace(~r{\*+$}, "")
  end

  # Returns [{uri, file}] for every arbor:// literal in code (doc strings excluded).
  defp scan(root) do
    Path.wildcard(Path.join(root, "**/*.ex"))
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.flat_map(&scan_file/1)
  end

  defp scan_file(file) do
    case parse(file) do
      {:ok, ast} ->
        doc = doc_uris(ast)

        ast
        |> code_uris()
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(doc, &1))
        |> Enum.map(&{&1, file})

      _ ->
        []
    end
  end

  defp parse(file) do
    with {:ok, code} <- File.read(file), do: Code.string_to_quoted(code)
  end

  defp code_uris(ast) do
    {_, uris} =
      Macro.prewalk(ast, [], fn
        str, acc when is_binary(str) -> {str, extract(str) ++ acc}
        node, acc -> {node, acc}
      end)

    uris
  end

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
end
