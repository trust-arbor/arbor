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

  alias Arbor.Actions.Security.Detectors.Common
  alias Arbor.Contracts.Security.CapabilityUri

  @doc_attrs [:moduledoc, :doc, :shortdoc, :typedoc]
  @uri_regex ~r{arbor://[A-Za-z0-9_/.*\-]+}

  # Functions that take a resource URI to authorize, and variable names that
  # hold a resource being authorized — used to detect "reaches authorize".
  @authz_fns ~w(authorize can? validate authorize_file_op authorize_and_execute)a
  @resource_vars ~w(resource resource_uri uri)a

  @type row :: %{
          namespace: String.t(),
          in_registry: boolean(),
          action_backed: boolean(),
          authorized_at_callsite: boolean(),
          uncovered: [String.t()],
          count: non_neg_integer(),
          files: [String.t()],
          recommendation: String.t()
        }

  @type dead_registry_prefix :: %{
          prefix: String.t(),
          recommendation: String.t()
        }

  @doc "Build the inventory rows for `.ex` files under `root`. Gaps sorted first."
  @spec build(String.t()) :: [row()]
  def build(root \\ "apps") do
    prefixes = canonical_prefixes()
    reg_ns = prefixes |> Enum.map(&ns/1) |> MapSet.new()
    action_ns = action_namespaces()
    authz_ns = authorized_namespaces(root)

    scan(root)
    |> Enum.group_by(fn {uri, _file} -> ns(uri) end)
    |> Enum.map(fn {namespace, occ} ->
      uncovered =
        occ |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.reject(&covered?(&1, prefixes))

      in_reg = MapSet.member?(reg_ns, namespace)
      backed = MapSet.member?(action_ns, namespace)
      authorized = MapSet.member?(authz_ns, namespace)

      %{
        namespace: namespace,
        in_registry: in_reg,
        action_backed: backed,
        authorized_at_callsite: authorized,
        uncovered: uncovered,
        count: length(occ),
        files: occ |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.take(3),
        recommendation: recommend(uncovered, in_reg, backed, authorized)
      }
    end)
    |> Enum.sort_by(fn r -> {r.uncovered == [], r.namespace} end)
  end

  @doc """
  Return registered URI prefixes that have no matching code literal under `root`.

  This is a triage report rather than a hard failure: some prefixes are
  intentionally reserved for runtime bridges, and action prefixes can be
  generated from action declarations rather than repeated as literals.
  """
  @spec dead_registry_prefixes(String.t(), [String.t()] | nil, keyword()) :: [
          dead_registry_prefix()
        ]
  def dead_registry_prefixes(root \\ "apps", prefixes \\ nil, opts \\ []) do
    prefixes = prefixes || canonical_prefixes()
    generated_prefixes = Keyword.get_lazy(opts, :generated_prefixes, &action_uri_prefixes/0)

    used_uris =
      root
      |> scan()
      |> Enum.map(fn {uri, _file} -> normalize(uri) end)
      |> Enum.uniq()

    prefixes
    |> Enum.uniq()
    |> Enum.reject(&(&1 in generated_prefixes))
    |> Enum.reject(fn prefix ->
      Enum.any?(used_uris, &CapabilityUri.prefix_match?(prefix, &1))
    end)
    |> Enum.map(fn prefix ->
      %{
        prefix: prefix,
        recommendation: "TRIAGE (registered prefix has no code literal usage)"
      }
    end)
    |> Enum.sort_by(& &1.prefix)
  end

  defp recommend([], _reg, _backed, _authz), do: "ok"
  defp recommend(_unc, _reg, true, _authz), do: "REGISTER (action-backed)"
  defp recommend(_unc, true, _backed, _authz), do: "REGISTER sub-path (partial gap)"

  defp recommend(_unc, false, false, true),
    do: "REGISTER (authorized at call-site — denied in dev/prod)"

  defp recommend(_unc, false, false, false),
    do: "TRIAGE (grant-only, no call-site — likely stale)"

  # ---------------------------------------------------------------------------

  defp canonical_prefixes do
    security_prefixes =
      if Code.ensure_loaded?(Arbor.Security) and
           function_exported?(Arbor.Security, :canonical_uri_prefixes, 0) do
        Arbor.Security.canonical_uri_prefixes()
      else
        []
      end

    action_prefixes =
      if Code.ensure_loaded?(Arbor.Actions) and
           function_exported?(Arbor.Actions, :action_namespace_uri_prefixes, 0) do
        Arbor.Actions.action_namespace_uri_prefixes()
      else
        []
      end

    Enum.uniq(security_prefixes ++ action_prefixes)
  rescue
    _ -> []
  end

  defp action_uri_prefixes do
    if Code.ensure_loaded?(Arbor.Actions) and
         function_exported?(Arbor.Actions, :action_namespace_uri_prefixes, 0) do
      Arbor.Actions.action_namespace_uri_prefixes()
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

  # Namespaces whose URIs appear as an argument to an authz function
  # (authorize/can?/validate/...) or as the RHS of an assignment to a
  # resource-ish variable — i.e. URIs that reach `authorize`/`validate` and so
  # are subject to enforcement. A positive signal (absence ≠ not-authorized,
  # since many call sites build the URI through variables).
  defp authorized_namespaces(root) do
    root
    |> Common.elixir_source_files()
    |> Enum.flat_map(fn file ->
      case Common.parse(file) do
        {:ok, ast} -> authz_uris(ast)
        _ -> []
      end
    end)
    |> Enum.map(&ns/1)
    |> MapSet.new()
  end

  defp authz_uris(ast) do
    {_, uris} =
      Macro.prewalk(ast, [], fn
        {fun, _, args} = node, acc when fun in @authz_fns and is_list(args) ->
          {node, uris_in(args) ++ acc}

        {{:., _, [_mod, fun]}, _, args} = node, acc when fun in @authz_fns and is_list(args) ->
          {node, uris_in(args) ++ acc}

        {:=, _, [{var, _, ctx}, rhs]} = node, acc when var in @resource_vars and is_atom(ctx) ->
          {node, uris_in([rhs]) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(uris)
  end

  defp uris_in(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        s, acc when is_binary(s) -> {s, extract(s) ++ acc}
        n, acc -> {n, acc}
      end)

    found
  end

  defp covered?(uri, prefixes) do
    s = normalize(uri)

    Enum.any?(prefixes, fn p ->
      CapabilityUri.prefix_match?(p, s) or CapabilityUri.prefix_match?(s, p)
    end)
  end

  defp normalize(uri) do
    uri |> String.replace(~r{/\*+$}, "/") |> String.replace(~r{\*+$}, "")
  end

  # Returns [{uri, file}] for every arbor:// literal in code (doc strings excluded).
  defp scan(root) do
    root
    |> Common.elixir_source_files()
    |> Enum.flat_map(&scan_file/1)
  end

  defp scan_file(file) do
    case Common.parse(file) do
      {:ok, ast} ->
        excluded = MapSet.union(doc_uris(ast), source_uris(ast))

        ast
        |> code_uris()
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(excluded, &1))
        |> Enum.map(&{&1, file})

      _ ->
        []
    end
  end

  # Provenance/source-label URIs (a `*_source` function body) — not capabilities.
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
