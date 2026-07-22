defmodule Arbor.Orchestrator.CodingPlan.ReadinessLiveCore do
  @moduledoc false

  alias Arbor.Contracts.LLM.ProviderObservation

  @acp_source "acp_provider_readiness"
  @acp_runtime "acp"
  @toolchain_fields ~w(
    schema_version platform architecture otp_release elixir_version
    mix_wrapper_path runtime_roots identity_digest
  )
  @runtime_root_fields ~w(erlang_root elixir_root)

  @doc false
  @spec acp(term(), String.t(), String.t() | nil, DateTime.t()) ::
          {:ok, :passed | :degraded, String.t() | nil, DateTime.t()}
          | {:error, :malformed | :unavailable | :model_mismatch | :missing_executable}
  def acp(envelope, provider, requested_model, observed_at)
      when is_binary(provider) and is_struct(observed_at, DateTime) do
    with true <- json_clean?(envelope),
         {:ok, observation, digest} <- normalize_envelope(envelope),
         :ok <- validate_acp_identity(observation, provider),
         :ok <- validate_model(observation, requested_model),
         {:ok, decision} <- decision(observation),
         {:ok, expires_at} <- provider_expiry(observation, observed_at) do
      {:ok, decision, digest, expires_at}
    else
      {:error, reason} when reason in [:model_mismatch, :missing_executable, :unavailable] ->
        {:error, reason}

      _ ->
        {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  def acp(_envelope, _provider, _requested_model, _observed_at), do: {:error, :malformed}

  @doc false
  @spec toolchain(term()) :: {:ok, String.t()} | {:error, :malformed}
  def toolchain(identity) when is_map(identity) and not is_struct(identity) do
    with :ok <- validate_toolchain(identity),
         digest when is_binary(digest) <- Map.fetch!(identity, "identity_digest"),
         true <- valid_digest?(digest) do
      {:ok, "sha256:" <> digest}
    else
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  def toolchain(_identity), do: {:error, :malformed}

  @doc false
  @spec expiry(DateTime.t(), String.t() | nil) :: DateTime.t()
  def expiry(observed_at, provider_expiry) when is_struct(observed_at, DateTime) do
    maximum = DateTime.add(observed_at, 30, :second)

    case parse_datetime(provider_expiry) do
      {:ok, provider_expiry} ->
        if DateTime.compare(provider_expiry, observed_at) == :gt and
             DateTime.compare(provider_expiry, maximum) == :lt,
           do: provider_expiry,
           else: maximum

      :error ->
        maximum
    end
  end

  defp normalize_envelope(%{"observation" => observation, "digest" => digest} = envelope)
       when map_size(envelope) == 2 and is_map(observation) and not is_struct(observation) and
              is_binary(digest) do
    with {:ok, normalized} <- ProviderObservation.normalize(observation),
         {:ok, expected_digest} <- ProviderObservation.digest(normalized),
         true <- normalized == observation,
         true <- digest == expected_digest do
      {:ok, normalized, digest}
    else
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  defp normalize_envelope(_envelope), do: {:error, :malformed}

  defp validate_acp_identity(observation, provider) do
    if observation["provider"] == provider and observation["source"] == @acp_source and
         observation["runtime"] == @acp_runtime and is_binary(observation["availability"]) and
         is_binary(observation["auth_health"]) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp validate_model(observation, requested_model) do
    failure_code = observation["failure_code"]
    requested = observation["requested_model_id"]
    launch_bound = observation["launch_bound_model_id"]

    cond do
      failure_code == "model_mismatch" ->
        {:error, :model_mismatch}

      failure_code == "model_absent" ->
        {:error, :unavailable}

      is_binary(requested_model) and requested != requested_model ->
        {:error, :model_mismatch}

      is_binary(requested) and is_binary(launch_bound) and requested != launch_bound ->
        {:error, :model_mismatch}

      true ->
        :ok
    end
  end

  defp decision(%{"availability" => availability, "auth_health" => auth_health} = observation) do
    case {availability, auth_health, Map.get(observation, "failure_code")} do
      {"unavailable", _, "model_mismatch"} ->
        {:error, :model_mismatch}

      {"unavailable", _, "transport_error"} ->
        {:error, :missing_executable}

      {availability, _, _} when availability in ["unavailable", "unknown"] ->
        {:error, :unavailable}

      {availability, auth_health, _}
      when availability in ["degraded", "available"] and
             auth_health in ["expired", "invalid", "unavailable"] ->
        {:error, :unavailable}

      {"available", "healthy", nil} ->
        {:ok, :passed}

      {availability, auth_health, nil}
      when availability in ["degraded", "available"] and auth_health in ["healthy", "unknown"] ->
        {:ok, :degraded}

      _ ->
        {:error, :malformed}
    end
  end

  defp decision(_observation), do: {:error, :malformed}

  defp provider_expiry(%{"expires_at" => provider_expiry}, observed_at) do
    {:ok, expiry(observed_at, provider_expiry)}
  end

  defp provider_expiry(_observation, observed_at), do: {:ok, expiry(observed_at, nil)}

  defp validate_toolchain(identity) do
    base_identity = Map.delete(identity, "identity_digest")

    with true <- exact_keys?(identity, @toolchain_fields),
         true <- identity["schema_version"] == 1,
         :ok <- bounded_text(identity["platform"], 128),
         :ok <- bounded_text(identity["architecture"], 128),
         :ok <- bounded_text(identity["otp_release"], 128),
         :ok <- bounded_text(identity["elixir_version"], 128),
         :ok <- bounded_path(identity["mix_wrapper_path"]),
         :ok <- validate_runtime_roots(identity["runtime_roots"]),
         true <- valid_digest?(identity["identity_digest"]),
         true <- json_clean?(identity),
         true <- identity["identity_digest"] == sha256(canonical_json(base_identity)) do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp validate_runtime_roots(roots) when is_map(roots) and not is_struct(roots) do
    with true <- exact_keys?(roots, @runtime_root_fields),
         :ok <- bounded_path(roots["erlang_root"]),
         :ok <- bounded_path(roots["elixir_root"]) do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp validate_runtime_roots(_roots), do: {:error, :malformed}

  defp exact_keys?(map, expected) do
    Enum.all?(Map.keys(map), &is_binary/1) and Enum.sort(Map.keys(map)) == Enum.sort(expected)
  end

  defp bounded_path(value) when is_binary(value) and byte_size(value) <= 4_096 do
    if byte_size(value) > 0 and String.valid?(value) and Path.type(value) == :absolute,
      do: :ok,
      else: {:error, :malformed}
  end

  defp bounded_path(_value), do: {:error, :malformed}

  defp bounded_text(value, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes do
    if String.valid?(value) and String.trim(value) != "" and
         not String.match?(value, ~r/[\x00-\x1F\x7F]/),
       do: :ok,
       else: {:error, :malformed}
  end

  defp bounded_text(_value, _max_bytes), do: {:error, :malformed}

  defp valid_digest?(value) when is_binary(value) and byte_size(value) == 64 do
    String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  end

  defp valid_digest?(_value), do: false

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _nested} -> key end)
    |> Enum.map(fn {key, nested} -> [Jason.encode!(key), ":", canonical_json(nested)] end)
    |> then(&["{", Enum.intersperse(&1, ","), "}"])
  end

  defp canonical_json(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &canonical_json/1), ","), "]"]

  defp canonical_json(value), do: Jason.encode!(value)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    if map_size(value) <= 64 do
      Enum.all?(value, fn {key, nested} -> is_binary(key) and json_clean?(nested) end)
    else
      false
    end
  end

  defp json_clean?(value) when is_list(value) and length(value) <= 64,
    do: Enum.all?(value, &json_clean?/1)

  defp json_clean?(value)
       when is_binary(value) and byte_size(value) <= 16_384,
       do: String.valid?(value)

  defp json_clean?(value)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_clean?(_value), do: false
end
