defmodule Arbor.LLM.Sensitivity do
  @moduledoc false
  alias Arbor.Contracts.Security.{Taint, TaintedValue, TaintEnvelope}
  alias Arbor.LLM.{Call, Config, ProviderRegistry, Request}

  @levels [:public, :internal, :confidential, :restricted]
  @private_keys [:sensitivity, :taint, :agent_id]

  def options(opts) when is_list(opts), do: Keyword.take(opts, @private_keys)
  def options(opts) when is_map(opts), do: opts |> Map.take(@private_keys) |> Map.to_list()
  def options(_), do: []

  def carry(content, opts) do
    with {:ok, level} <- classify(content, opts),
         do: {:ok, Keyword.put(opts, :sensitivity, level)}
  end

  def authorize(provider, model, content, opts \\ []) do
    Call.new(:complete, {})
    |> Call.put_metadata(%{
      sensitivity_input: %{provider: provider, model: model, content: content, opts: opts}
    })
    |> Arbor.LLM.Plugs.Sensitivity.call()
    |> case do
      %Call{halted: true, result: result} -> result
      %Call{} -> :ok
    end
  end

  def decide(%{provider: provider, model: model, content: content, opts: opts}) do
    with true <- Keyword.keyword?(opts),
         {:ok, sensitivity} <- classify(content, opts),
         policy when is_atom(policy) and policy not in [nil, true, false] <-
           Config.sensitivity_policy(),
         true <-
           Code.ensure_loaded?(policy) and
             function_exported?(policy, :authorize_llm_sensitivity, 1) do
      destination = %{
        provider: normalize_provider(provider),
        model: model,
        sensitivity: sensitivity,
        base_url: Keyword.get(opts, :base_url) || default_endpoint(provider),
        runtime: Keyword.get(opts, :runtime, :arbor)
      }

      case apply(policy, :authorize_llm_sensitivity, [destination]) do
        :ok ->
          :ok

        {:error, reason} when reason in [:destination_disallowed, :invalid_destination] ->
          blocked(reason)

        _ ->
          blocked(:policy_unavailable)
      end
    else
      {:error, _} = error -> error
      _ -> blocked(:policy_unavailable)
    end
  rescue
    _ -> blocked(:policy_unavailable)
  catch
    _, _ -> blocked(:policy_unavailable)
  end

  # Scanning never lowers a recorded label. Classifier credentials are a
  # restricted egress category even when a UI classifier calls them confidential.
  def classify(content, opts \\ []) do
    with {:ok, floor} <- labels(opts),
         {:ok, content_floor} <- content_labels(content),
         {:ok, strings, _budget} <- text(content, [], 100_000, 0) do
      joined = strings |> Enum.reverse() |> Enum.join("\n")

      if byte_size(joined) > 16_777_216 do
        blocked(:classification_limit)
      else
        classifier = Config.sensitivity_classifier()
        result = apply(classifier, :classify, [joined])
        scanned = result.overall_sensitivity
        scanned = if result.taint_tags.credentials, do: :restricted, else: scanned

        if scanned in @levels,
          do: {:ok, maximum([floor, content_floor, scanned])},
          else: blocked(:classification_unavailable)
      end
    end
  rescue
    _ -> blocked(:classification_unavailable)
  catch
    _, _ -> blocked(:classification_unavailable)
  end

  defp labels(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Enum.filter(fn {key, _} -> key in [:sensitivity, :taint] end)
      |> Enum.reduce_while({:ok, :public}, fn {key, value}, {:ok, acc} ->
        case label(key, value) do
          {:ok, level} -> {:cont, {:ok, maximum([acc, level])}}
          error -> {:halt, error}
        end
      end)
    else
      blocked(:invalid_classification)
    end
  end

  defp labels(map) when is_map(map) do
    for key <- [:sensitivity, :taint],
        field <- [key, Atom.to_string(key)],
        {:ok, value} <- [Map.fetch(map, field)],
        reduce: {:ok, :public} do
      {:ok, acc} ->
        case label(key, value) do
          {:ok, level} -> {:ok, maximum([acc, level])}
          error -> error
        end

      error ->
        error
    end
  end

  defp label(:sensitivity, level) when level in @levels, do: {:ok, level}

  defp label(:sensitivity, level) when is_binary(level) do
    case Enum.find(@levels, &(Atom.to_string(&1) == level)) do
      nil -> blocked(:invalid_classification)
      value -> {:ok, value}
    end
  end

  defp label(:taint, %TaintedValue{taint: taint} = value) do
    if map_size(value) == 3,
      do: canonical_taint_label(taint),
      else: blocked(:invalid_classification)
  end

  defp label(:taint, %TaintEnvelope{} = envelope) do
    case TaintEnvelope.to_map(envelope) do
      {:ok, _persisted} -> canonical_taint_label(envelope.taint)
      _invalid -> blocked(:invalid_classification)
    end
  end

  defp label(:taint, legacy) when legacy in [:trusted, :derived, :untrusted, :hostile],
    do: {:ok, :restricted}

  defp label(:taint, value) when is_map(value) do
    case Taint.canonicalize(value) do
      {:ok, taint} ->
        {:ok, taint.sensitivity}

      _invalid ->
        case TaintEnvelope.decode_persisted(value) do
          {:ok, envelope} -> canonical_taint_label(envelope.taint)
          _invalid -> serialized_value_taint_label(value)
        end
    end
  end

  defp label(:taint, value), do: canonical_taint_label(value)
  defp label(_, _), do: blocked(:invalid_classification)

  defp canonical_taint_label(value) do
    case Taint.canonicalize(value) do
      {:ok, taint} -> {:ok, taint.sensitivity}
      _invalid -> blocked(:invalid_classification)
    end
  end

  defp serialized_value_taint_label(value) do
    keys = Map.keys(value) |> Enum.sort()

    cond do
      keys == [:taint, :value] -> canonical_taint_label(Map.fetch!(value, :taint))
      keys == ["taint", "value"] -> canonical_taint_label(Map.fetch!(value, "taint"))
      true -> blocked(:invalid_classification)
    end
  end

  defp content_labels(value), do: content_labels(value, 0)
  defp content_labels(_, depth) when depth > 64, do: blocked(:classification_limit)

  defp content_labels(%Taint{} = taint, _depth), do: canonical_taint_label(taint)
  defp content_labels(%TaintEnvelope{} = envelope, _depth), do: label(:taint, envelope)

  defp content_labels(%TaintedValue{value: value} = wrapped, depth) do
    with {:ok, floor} <- label(:taint, wrapped),
         {:ok, child} <- content_labels(value, depth + 1) do
      {:ok, maximum([floor, child])}
    end
  end

  defp content_labels(%Request{} = request, depth) do
    fields =
      for key <- [:sensitivity, :taint],
          value = Map.get(request, key),
          not is_nil(value),
          do: {key, value}

    with {:ok, floor} <- labels(fields),
         {:ok, children} <-
           content_labels(
             [request.messages, request.tools, request.provider_options],
             depth + 1
           ),
         do: {:ok, maximum([floor, children])}
  end

  defp content_labels(tuple, depth) when is_tuple(tuple),
    do: content_labels(Tuple.to_list(tuple), depth + 1)

  defp content_labels(list, depth) when is_list(list) do
    Enum.reduce_while(list, {:ok, :public}, fn value, {:ok, acc} ->
      case content_labels(value, depth + 1) do
        {:ok, level} -> {:cont, {:ok, maximum([acc, level])}}
        error -> {:halt, error}
      end
    end)
  end

  defp content_labels(map, depth) when is_map(map) do
    with {:ok, floor} <- labels(map),
         {:ok, children} <- content_map_labels(map, depth + 1) do
      {:ok, maximum([floor, children])}
    end
  end

  defp content_labels(_, _), do: {:ok, :public}

  defp content_map_labels(map, depth) do
    schema? = json_schema_object?(map)

    map
    |> Map.drop([:sensitivity, :taint, "sensitivity", "taint"])
    |> Map.to_list()
    |> Enum.reduce_while({:ok, :public}, fn {key, value}, {:ok, acc} ->
      # In an object schema, these keys name user fields. A property named
      # "taint" or "sensitivity" is not itself a source label. Recurse into
      # each property's schema so explicit nested metadata still contributes.
      child =
        if schema? and key in [:properties, "properties"] and is_map(value),
          do: Map.values(value),
          else: value

      case content_labels(child, depth) do
        {:ok, level} -> {:cont, {:ok, maximum([acc, level])}}
        error -> {:halt, error}
      end
    end)
  end

  defp json_schema_object?(map) do
    object? =
      Enum.any?([:type, "type"], fn key ->
        case Map.fetch(map, key) do
          {:ok, value} -> value in [:object, "object"]
          :error -> false
        end
      end)

    object? and
      Enum.any?([:properties, "properties"], fn key ->
        case Map.fetch(map, key) do
          {:ok, value} -> is_map(value)
          :error -> false
        end
      end)
  end

  defp text(_, _, remaining, depth) when remaining <= 0 or depth > 64,
    do: blocked(:classification_limit)

  defp text(value, acc, remaining, _) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, [value | acc], remaining - 1},
      else: blocked(:invalid_content)
  end

  defp text(%DateTime{} = value, acc, remaining, depth),
    do: text(DateTime.to_iso8601(value), acc, remaining, depth)

  defp text(%NaiveDateTime{} = value, acc, remaining, depth),
    do: text(NaiveDateTime.to_iso8601(value), acc, remaining, depth)

  defp text(%Date{} = value, acc, remaining, depth),
    do: text(Date.to_iso8601(value), acc, remaining, depth)

  defp text(%Time{} = value, acc, remaining, depth),
    do: text(Time.to_iso8601(value), acc, remaining, depth)

  defp text(value, acc, remaining, depth) when is_tuple(value),
    do: text(Tuple.to_list(value), acc, remaining, depth + 1)

  defp text(%Request{} = value, acc, remaining, depth),
    do: text([value.messages, value.tools, value.provider_options], acc, remaining, depth + 1)

  defp text(%Arbor.LLM.Tool{} = value, acc, remaining, depth),
    do: text(Arbor.LLM.Tool.as_definition(value), acc, remaining, depth + 1)

  defp text(%ReqLLM.Tool{} = value, acc, remaining, depth),
    do:
      text(
        Map.take(Map.from_struct(value), [:name, :description, :parameter_schema]),
        acc,
        remaining,
        depth + 1
      )

  defp text(value, acc, remaining, depth) when is_struct(value),
    do: text(Map.from_struct(value), acc, remaining, depth + 1)

  defp text(value, acc, remaining, depth) when is_map(value) do
    fields = Enum.flat_map(Map.to_list(value), fn {key, item} -> [key, item] end)
    text(fields, acc, remaining, depth + 1)
  end

  defp text(value, acc, remaining, depth) when is_list(value) do
    Enum.reduce_while(value, {:ok, acc, remaining - 1}, fn item, {:ok, texts, budget} ->
      case text(item, texts, budget, depth + 1) do
        {:ok, _, _} = result -> {:cont, result}
        error -> {:halt, error}
      end
    end)
  end

  defp text(value, acc, remaining, _) when is_atom(value) or is_number(value),
    do: {:ok, acc, remaining - 1}

  defp text(_, _, _, _), do: blocked(:invalid_content)

  defp maximum(levels),
    do: Enum.max_by(levels, fn level -> Enum.find_index(@levels, &(&1 == level)) end)

  defp normalize_provider(value) when is_atom(value) or is_binary(value),
    do: ProviderRegistry.normalize(value)

  defp normalize_provider(_), do: nil

  defp default_endpoint(value) when is_atom(value) or is_binary(value),
    do: ProviderRegistry.default_base_url(value)

  defp default_endpoint(_), do: nil
  defp blocked(reason), do: {:error, {:sensitivity_blocked, reason}}

  # A Req request step runs again on transport retries and redirects. Inspect
  # the actual URL after provider preparation, without putting labels in JSON.
  def protect_request(req, provider, model, content, opts) do
    admitted_url =
      Keyword.get(opts, :base_url) || Req.Request.get_option(req, :base_url) ||
        URI.to_string(req.url)

    opts = Keyword.put(opts, :sensitivity_admitted_url, admitted_url)

    Req.Request.append_request_steps(req,
      arbor_sensitivity: fn request ->
        actual = Keyword.put(opts, :base_url, URI.to_string(request.url))

        case authorize_wire(provider, model, content, actual, request.body) do
          :ok ->
            request

          {:error, reason} ->
            Req.Request.halt(request, %Req.Response{
              status: 403,
              private: %{arbor_sensitivity_error: reason}
            })
        end
      end
    )
  end

  def authorize_wire(provider, model, content, opts, body) do
    with :ok <- admit_origin(opts),
         {:ok, bytes} <- wire_bytes(body),
         {:ok, payload} <- wire_payload(bytes) do
      actual_model = if is_map(payload), do: Map.get(payload, "model", model), else: model
      authorize(provider, actual_model, [content, payload, bytes], opts)
    end
  end

  defp admit_origin(opts) do
    with {:ok, expected} <- origin(Keyword.get(opts, :sensitivity_admitted_url)),
         {:ok, actual} <- origin(Keyword.get(opts, :base_url)),
         true <- expected == actual do
      :ok
    else
      _ -> blocked(:destination_changed)
    end
  end

  defp origin(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and port in 1..65_535 ->
        {:ok, {scheme, String.downcase(host), port}}

      _ ->
        :error
    end
  end

  defp origin(_), do: :error

  defp wire_bytes(nil), do: {:ok, ""}
  defp wire_bytes(value) when is_binary(value), do: {:ok, value}

  defp wire_bytes(value) when is_list(value) do
    if :erlang.iolist_size(value) <= 16_777_216,
      do: {:ok, IO.iodata_to_binary(value)},
      else: blocked(:classification_limit)
  rescue
    _ -> blocked(:invalid_content)
  end

  defp wire_bytes(_), do: blocked(:invalid_content)
  defp wire_payload(""), do: {:ok, %{}}

  defp wire_payload(bytes) do
    case Arbor.LLM.ResponseBudget.decode_json(bytes,
           max_bytes: 16_777_216,
           max_nodes: 100_000,
           max_depth: 64,
           max_map_keys: 100_000,
           max_list_items: 100_000
         ) do
      {:ok, payload} -> {:ok, payload}
      _ -> blocked(:invalid_content)
    end
  end
end
