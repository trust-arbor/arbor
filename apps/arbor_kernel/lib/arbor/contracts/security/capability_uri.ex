defmodule Arbor.Contracts.Security.CapabilityUri do
  @moduledoc """
  Parsed, validated Arbor capability URI.

  Capability URIs are addresses, not risk classifiers. This type gives the
  kernel and policy layers one segment-aware parser so prefix checks do not fall
  back to raw string matching. In particular, `arbor://action` must not match
  the retired plural namespace `arbor://actions/execute/...`.
  """

  use TypedStruct

  @scheme_prefix "arbor://"
  @domain_or_operation ~r/^[a-z][a-z0-9_]*$/

  @type wildcard :: :none | :single | :recursive

  typedstruct enforce: true do
    field(:uri, String.t())
    field(:scheme, String.t(), default: "arbor")
    field(:segments, [String.t()])
    field(:domain, String.t() | nil, default: nil)
    field(:operation, String.t() | nil, default: nil)
    field(:path, String.t() | nil, default: nil)
    field(:wildcard, wildcard(), default: :none)
  end

  @doc "Build a parsed capability URI from an `arbor://...` string."
  @spec new(String.t()) :: {:ok, t()} | {:error, term()}
  def new(uri), do: parse(uri)

  @doc "Parse and validate an Arbor capability URI."
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(uri) when is_binary(uri) do
    with {:ok, rest} <- strip_scheme(uri),
         {:ok, raw_segments} <- split_segments(rest),
         {:ok, wildcard} <- validate_wildcard(raw_segments),
         {:ok, body_segments} <- validate_domain_and_operation(raw_segments, wildcard) do
      {:ok,
       %__MODULE__{
         uri: uri,
         segments: raw_segments,
         domain: Enum.at(body_segments, 0),
         operation: Enum.at(body_segments, 1),
         path: path_from(body_segments),
         wildcard: wildcard
       }}
    end
  end

  def parse(_), do: {:error, :not_binary}

  @doc "Parse an Arbor capability URI, raising `ArgumentError` on failure."
  @spec parse!(String.t()) :: t()
  def parse!(uri) do
    case parse(uri) do
      {:ok, parsed} ->
        parsed

      {:error, reason} ->
        raise ArgumentError, "invalid Arbor capability URI #{inspect(uri)}: #{inspect(reason)}"
    end
  end

  @doc "True when `uri` parses as a valid Arbor capability URI."
  @spec valid?(String.t()) :: boolean()
  def valid?(uri), do: match?({:ok, _}, parse(uri))

  @doc """
  Return true when `prefix` matches `uri` on segment boundaries.

  This is registry-prefix matching, not capability wildcard authorization. A
  non-wildcard prefix matches itself and any descendant URI by whole segments.
  Terminal `/*` and `/**` in the prefix are accepted as wildcard prefixes.
  """
  @spec prefix_match?(String.t(), String.t()) :: boolean()
  def prefix_match?(prefix, uri) when is_binary(prefix) and is_binary(uri) do
    with {:ok, parsed_prefix} <- parse(prefix),
         {:ok, parsed_uri} <- parse(uri) do
      prefix_segments = match_segments(parsed_prefix)

      root_wildcard?(parsed_prefix) or segment_prefix?(prefix_segments, parsed_uri.segments)
    else
      _ -> false
    end
  end

  def prefix_match?(_, _), do: false

  @doc "Return the canonical string form for a parsed URI."
  @spec canonical(t()) :: String.t()
  def canonical(%__MODULE__{segments: segments}), do: @scheme_prefix <> Enum.join(segments, "/")

  @doc """
  Return true when a capability URI pattern grants access to a resource URI.

  Unlike registry-prefix matching, a concrete capability URI only grants its
  exact resource. Subtree grants require an explicit terminal wildcard. Invalid
  URIs and traversal-like `..` segments fail closed.
  """
  @spec capability_match?(String.t(), String.t()) :: boolean()
  def capability_match?(capability_uri, resource_uri)
      when is_binary(capability_uri) and is_binary(resource_uri) do
    with false <- traversal_segment?(capability_uri),
         false <- traversal_segment?(resource_uri),
         {:ok, capability} <- parse(capability_uri),
         {:ok, resource} <- parse(resource_uri) do
      capability_matches_parsed?(capability, resource)
    else
      _ -> false
    end
  end

  def capability_match?(_, _), do: false

  @doc """
  Return true when every resource granted by `child` is also granted by `parent`.

  Used for delegation and issuer-envelope attenuation. This follows
  `capability_match?/2` semantics: concrete parent URIs are exact, not subtree
  prefixes.
  """
  @spec capability_subset?(String.t(), String.t()) :: boolean()
  def capability_subset?(child, parent) when is_binary(child) and is_binary(parent) do
    with false <- traversal_segment?(child),
         false <- traversal_segment?(parent),
         {:ok, child_uri} <- parse(child),
         {:ok, parent_uri} <- parse(parent) do
      capability_subset_parsed?(child_uri, parent_uri)
    else
      _ -> false
    end
  end

  def capability_subset?(_, _), do: false

  defp strip_scheme(uri) do
    if String.starts_with?(uri, @scheme_prefix) do
      rest = String.replace_prefix(uri, @scheme_prefix, "")

      if rest == "" do
        {:error, :missing_domain}
      else
        {:ok, rest}
      end
    else
      {:error, :invalid_scheme}
    end
  end

  defp split_segments(rest) do
    raw = String.split(rest, "/", trim: false)
    last_index = length(raw) - 1

    cond do
      internal_empty_segment?(raw, last_index) ->
        {:error, :empty_segment}

      raw == [""] ->
        {:error, :missing_domain}

      true ->
        segments = Enum.reject(raw, &(&1 == ""))

        if segments == [] do
          {:error, :missing_domain}
        else
          {:ok, segments}
        end
    end
  end

  defp internal_empty_segment?(segments, last_index) do
    segments
    |> Enum.with_index()
    |> Enum.any?(fn
      {"", ^last_index} -> false
      {"", _index} -> true
      {_segment, _index} -> false
    end)
  end

  defp validate_wildcard(["**"]), do: {:ok, :recursive}

  defp validate_wildcard(segments) do
    wildcard =
      case List.last(segments) do
        "**" -> :recursive
        "*" -> :single
        _ -> :none
      end

    body = body_segments(segments, wildcard)

    if Enum.any?(body, &String.contains?(&1, "*")) do
      {:error, :non_terminal_wildcard}
    else
      {:ok, wildcard}
    end
  end

  defp validate_domain_and_operation(["**"], :recursive), do: {:ok, []}

  defp validate_domain_and_operation(segments, wildcard) do
    body = body_segments(segments, wildcard)

    cond do
      body == [] ->
        {:error, :missing_domain}

      invalid_domain_or_operation?(Enum.at(body, 0)) ->
        {:error, {:invalid_domain, Enum.at(body, 0)}}

      invalid_domain_or_operation?(Enum.at(body, 1)) ->
        {:error, {:invalid_operation, Enum.at(body, 1)}}

      Enum.any?(body, &String.match?(&1, ~r/\s/)) ->
        {:error, :whitespace_segment}

      true ->
        {:ok, body}
    end
  end

  defp invalid_domain_or_operation?(nil), do: false
  defp invalid_domain_or_operation?(segment), do: not Regex.match?(@domain_or_operation, segment)

  defp body_segments(segments, :none), do: segments
  defp body_segments(segments, _wildcard), do: Enum.drop(segments, -1)

  defp path_from(body_segments) do
    case Enum.drop(body_segments, 2) do
      [] -> nil
      path_segments -> Enum.join(path_segments, "/")
    end
  end

  defp match_segments(%__MODULE__{segments: segments, wildcard: :none}), do: segments
  defp match_segments(%__MODULE__{segments: ["**"], wildcard: :recursive}), do: []
  defp match_segments(%__MODULE__{segments: segments}), do: Enum.drop(segments, -1)

  defp root_wildcard?(%__MODULE__{segments: ["**"], wildcard: :recursive}), do: true
  defp root_wildcard?(_), do: false

  defp capability_matches_parsed?(%__MODULE__{wildcard: :none} = capability, resource) do
    capability.segments == resource.segments
  end

  defp capability_matches_parsed?(%__MODULE__{} = capability, resource) do
    root_wildcard?(capability) or segment_prefix?(match_segments(capability), resource.segments)
  end

  defp capability_subset_parsed?(_child, %__MODULE__{segments: ["**"], wildcard: :recursive}) do
    true
  end

  defp capability_subset_parsed?(
         %__MODULE__{wildcard: :none} = child,
         %__MODULE__{
           wildcard: :none
         } = parent
       ) do
    child.segments == parent.segments
  end

  defp capability_subset_parsed?(%__MODULE__{wildcard: :none} = child, %__MODULE__{} = parent) do
    segment_prefix?(match_segments(parent), child.segments)
  end

  defp capability_subset_parsed?(%__MODULE__{} = child, %__MODULE__{wildcard: :single} = parent) do
    segment_prefix?(match_segments(parent), match_segments(child)) and
      child.wildcard != :recursive
  end

  defp capability_subset_parsed?(%__MODULE__{} = child, %__MODULE__{wildcard: :none}) do
    # A wildcard child grants more than one exact resource, so it cannot fit
    # inside a concrete parent. The equal concrete/concrete case is handled above.
    child.wildcard == :none
  end

  defp capability_subset_parsed?(%__MODULE__{} = child, %__MODULE__{} = parent) do
    segment_prefix?(match_segments(parent), match_segments(child))
  end

  defp segment_prefix?([], _segments), do: false

  defp segment_prefix?(prefix_segments, segments) do
    prefix_length = length(prefix_segments)
    prefix_length <= length(segments) and Enum.take(segments, prefix_length) == prefix_segments
  end

  defp traversal_segment?(uri) when is_binary(uri) do
    case parse(uri) do
      {:ok, %__MODULE__{segments: segments}} -> ".." in segments
      {:error, _} -> true
    end
  end

  defp traversal_segment?(_), do: true
end
