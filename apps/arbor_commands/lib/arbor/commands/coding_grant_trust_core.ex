defmodule Arbor.Commands.CodingGrantTrustCore do
  @moduledoc """
  Pure install/skip/refuse decisions for coding-grant trust rules.

  `decide/1` takes required resources plus explain results and sibling rules.
  `show/1` formats the operator section. The mix task is the only shell.
  """

  alias Arbor.Contracts.Security.CapabilityUri
  alias Arbor.Contracts.Security.TrustRule

  @coding_prefix "arbor://action/coding"
  @coding_root_segments ["action", "coding"]
  @allowed_modes [:block, :ask, :allow, :auto]
  @mode_names Map.new(@allowed_modes, fn mode -> {Atom.to_string(mode), mode} end)

  @type mode :: :block | :ask | :allow | :auto

  @type decision :: %{
          action: :install | :skip | :refuse,
          uri: String.t(),
          mode: mode() | nil,
          reason: atom()
        }

  @type result :: %{
          principal_id: String.t(),
          decisions: [decision()],
          dry_run: boolean()
        }

  @doc """
  Decide install/skip/refuse for each required URI.

  Required keys: `:principal_id`, `:required_resources`, `:explanations`,
  `:sibling_rules`. Unknown shape is `{:error, :invalid_input}`.
  """
  @spec decide(map()) :: {:ok, result()} | {:error, :invalid_input}
  def decide(input) when is_map(input) and not is_struct(input) do
    principal_id = Map.get(input, :principal_id)
    required = Map.get(input, :required_resources)
    explanations = Map.get(input, :explanations)
    sibling_rules = Map.get(input, :sibling_rules)

    cond do
      not (is_binary(principal_id) and principal_id != "") ->
        {:error, :invalid_input}

      not is_map(explanations) or is_struct(explanations) ->
        {:error, :invalid_input}

      not is_map(sibling_rules) or is_struct(sibling_rules) ->
        {:error, :invalid_input}

      true ->
        case extract_uris(required) do
          {:ok, uris} ->
            decisions = Enum.map(uris, &decide_uri(&1, explanations, sibling_rules))

            {:ok,
             %{
               principal_id: principal_id,
               decisions: decisions,
               dry_run: Map.get(input, :dry_run) == true
             }}

          :error ->
            {:error, :invalid_input}
        end
    end
  end

  def decide(_input), do: {:error, :invalid_input}

  @doc "Format a trust-rule result for operator output."
  @spec show(result() | map()) :: String.t()
  def show(result) when is_map(result) do
    dry_run = Map.get(result, :dry_run) == true
    principal_id = Map.get(result, :principal_id, "")
    decisions = list_or(Map.get(result, :decisions), [])
    header = if dry_run, do: "trust rules (dry-run):", else: "trust rules:"
    install_label = if dry_run, do: "would install:", else: "installed:"

    installs = Enum.filter(decisions, &match?(%{action: :install}, &1))
    refuses = Enum.filter(decisions, &match?(%{action: :refuse}, &1))

    Enum.join(
      [
        header,
        "execution_principal (#{principal_id}):",
        format_decision_section(install_label, installs, &format_install/1),
        format_decision_section("refused:", refuses, &format_refuse/1)
      ],
      "\n"
    )
  end

  def show(_result), do: show(%{principal_id: "", decisions: []})

  defp extract_uris(required) when is_list(required) do
    if Enum.all?(required, &is_binary/1) do
      {:ok, dedupe(required)}
    else
      :error
    end
  end

  defp extract_uris(%{"resource_uris" => uris}) when is_list(uris) do
    extract_uris(uris)
  end

  defp extract_uris(_required), do: :error

  defp dedupe(uris) do
    {kept, _seen} =
      Enum.reduce(uris, {[], MapSet.new()}, fn uri, {acc, seen} ->
        if MapSet.member?(seen, uri) do
          {acc, seen}
        else
          {[uri | acc], MapSet.put(seen, uri)}
        end
      end)

    Enum.reverse(kept)
  end

  defp decide_uri(uri, explanations, sibling_rules) do
    cond do
      wildcard_or_root?(uri) ->
        refuse(uri, :wildcard_or_root)

      not coding_leaf?(uri) ->
        refuse(uri, :non_coding_namespace)

      true ->
        decide_from_explain(uri, explanations, sibling_rules)
    end
  end

  defp decide_from_explain(uri, explanations, sibling_rules) do
    case explanation_for(explanations, uri) do
      {:error, _reason} ->
        refuse(uri, :explain_failed)

      :missing ->
        refuse(uri, :explain_failed)

      {:ok, _mode, user_match} when user_match != nil ->
        skip(uri, normalize_mode(match_mode(user_match)), :existing_rule)

      {:ok, effective_mode, nil} ->
        decide_unmatched(uri, effective_mode, sibling_rules)
    end
  end

  defp decide_unmatched(uri, effective_mode, sibling_rules) do
    case normalize_mode(effective_mode) do
      mode when mode in [:block, :ask] ->
        decide_mirror(uri, sibling_rules)

      mode when mode in @allowed_modes ->
        skip(uri, mode, :already_permitted)

      _other ->
        refuse(uri, :explain_failed)
    end
  end

  defp decide_mirror(uri, sibling_rules) do
    case mirrored_sibling_mode(uri, sibling_rules) do
      {:ok, mode} ->
        install(uri, mode, :mirrored_sibling)

      {:error, reason} ->
        refuse(uri, reason)
    end
  end

  defp mirrored_sibling_mode(uri, sibling_rules) do
    modes =
      sibling_rules
      |> Enum.flat_map(fn {prefix, mode} ->
        if same_parent_sibling?(uri, prefix) do
          case normalize_mode(mode) do
            nil -> []
            allowed -> [allowed]
          end
        else
          []
        end
      end)
      |> Enum.uniq()

    case modes do
      [mode] -> {:ok, mode}
      [] -> {:error, :no_siblings}
      _conflict -> {:error, :conflicting_siblings}
    end
  end

  defp same_parent_sibling?(candidate, other) when is_binary(candidate) and is_binary(other) do
    with true <- candidate != other,
         false <- TrustRule.glob?(other),
         {:ok, cand} <- CapabilityUri.parse(candidate),
         {:ok, sib} <- CapabilityUri.parse(other),
         true <- coding_leaf_parsed?(sib),
         true <- same_depth_segments?(cand.segments, sib.segments),
         true <- List.delete_at(cand.segments, -1) == List.delete_at(sib.segments, -1) do
      true
    else
      _other -> false
    end
  end

  defp same_parent_sibling?(_candidate, _other), do: false

  defp same_depth_segments?(left, right) when is_list(left) and is_list(right) do
    equal_length_nonempty?(left, right)
  end

  defp same_depth_segments?(_left, _right), do: false

  defp equal_length_nonempty?([_ | left], [_ | right]), do: equal_length?(left, right)
  defp equal_length_nonempty?(_left, _right), do: false

  defp equal_length?([], []), do: true
  defp equal_length?([_ | left], [_ | right]), do: equal_length?(left, right)
  defp equal_length?(_left, _right), do: false

  defp wildcard_or_root?(uri) when is_binary(uri) do
    cond do
      uri == @coding_prefix ->
        true

      TrustRule.glob?(uri) ->
        true

      true ->
        case CapabilityUri.parse(uri) do
          {:ok, parsed} ->
            parsed.wildcard != :none or parsed.segments == ["**"] or ".." in parsed.segments

          {:error, _reason} ->
            true
        end
    end
  end

  defp wildcard_or_root?(_uri), do: true

  defp coding_leaf?(uri) when is_binary(uri) do
    case CapabilityUri.parse(uri) do
      {:ok, parsed} -> coding_leaf_parsed?(parsed)
      {:error, _reason} -> false
    end
  end

  defp coding_leaf?(_uri), do: false

  defp coding_leaf_parsed?(parsed) do
    CapabilityUri.prefix_match?(@coding_prefix, parsed.uri) and
      deeper_than_coding_root?(parsed.segments)
  end

  defp deeper_than_coding_root?([_, _ | [_ | _]] = segments) do
    List.starts_with?(segments, @coding_root_segments)
  end

  defp deeper_than_coding_root?(_segments), do: false

  defp explanation_for(explanations, uri) do
    case Map.get(explanations, uri) || Map.get(explanations, to_string(uri)) do
      nil ->
        :missing

      exp when is_map(exp) ->
        if Map.has_key?(exp, :error) or Map.has_key?(exp, "error") do
          {:error, :explain_error}
        else
          mode = Map.get(exp, :effective_mode) || Map.get(exp, "effective_mode")
          user_match = Map.get(exp, :user_match) || Map.get(exp, "user_match")
          {:ok, mode, user_match}
        end

      _other ->
        :missing
    end
  end

  defp match_mode({_prefix, mode}), do: mode
  defp match_mode(_other), do: nil

  defp normalize_mode(mode) when mode in @allowed_modes, do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    Map.get(@mode_names, mode)
  end

  defp normalize_mode(_mode), do: nil

  defp install(uri, mode, reason) do
    %{action: :install, uri: uri, mode: mode, reason: reason}
  end

  defp skip(uri, mode, reason) do
    %{action: :skip, uri: uri, mode: mode, reason: reason}
  end

  defp refuse(uri, reason) do
    %{action: :refuse, uri: uri, mode: nil, reason: reason}
  end

  defp list_or(value, _default) when is_list(value), do: value
  defp list_or(_value, default), do: default

  defp format_decision_section(label, [], _formatter), do: "#{label} (none)"

  defp format_decision_section(label, items, formatter) do
    "#{label}\n#{Enum.map_join(items, "\n", formatter)}"
  end

  defp format_install(%{uri: uri, mode: mode}), do: "#{uri} => #{mode}"
  defp format_install(other), do: inspect(other)

  defp format_refuse(%{uri: uri, reason: reason}), do: "#{uri} (#{reason})"
  defp format_refuse(other), do: inspect(other)
end
