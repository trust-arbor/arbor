defmodule Arbor.LLM.OAuth.ModelCatalog do
  @moduledoc false

  alias Arbor.Contracts.LLM.ProviderModelCatalog
  alias Arbor.LLM.{Deadline, Endpoint, OAuth, ResponseBudget}
  alias Arbor.LLM.OAuth.{CredentialReceipt, ModelCatalogFailure}

  @openai_catalog_path "https://chatgpt.com/backend-api/codex/models"
  @openai_client_version "0.0.0"
  @xai_catalog_url "https://cli-chat-proxy.grok.com/v1/models"
  @catalog_ttl_seconds 300
  @max_response_bytes 1_048_576
  @max_models 512
  @max_model_id_bytes 256
  @default_timeout_ms 15_000
  @max_timeout_ms 60_000
  @max_access_token_bytes 65_536
  @max_account_id_bytes 512
  @max_generation 1_000_000_000_000
  @max_options 32

  @json_limits [
    max_bytes: @max_response_bytes,
    max_nodes: 50_000,
    max_depth: 16,
    max_map_keys: 2048,
    max_list_items: 1_024
  ]

  @allowed_option_keys [
    :timeout_ms,
    :now_fn,
    :clock,
    :credential_receipt_fun,
    :reread_source_credential_fun,
    :request_fun
  ]

  @forbidden_option_keys [
    :url,
    :endpoint,
    :base_url,
    :client_version,
    :headers,
    :token,
    :access_token,
    :path,
    :trusted_endpoints,
    :oauth_model_catalog_endpoints,
    :oauth_response_endpoints,
    :ttl_ms
  ]

  @plus_json_media_type ~r/\A[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+\+json\z/

  @doc """
  Fetch provider-reported subscription model catalog for one exact OAuth route.
  """
  @spec fetch(atom() | String.t(), keyword()) ::
          {:ok, ProviderModelCatalog.t()} | {:error, term()}
  def fetch(route, opts \\ [])

  def fetch(route, opts) when is_list(opts) do
    with {:ok, opts} <- normalize_options(opts),
         {:ok, identity} <- resolve_identity(route),
         {:ok, receipt} <- Deadline.receipt(timeout_ms: opts.timeout_ms) do
      Deadline.run(
        fn -> do_fetch(identity, opts) end,
        receipt,
        ModelCatalogFailure.transport(identity.route, identity.backend, :deadline_exceeded)
      )
    end
  end

  def fetch(_route, _opts), do: {:error, ModelCatalogFailure.options(:keyword_options_required)}

  defp do_fetch(identity, opts) do
    with {:ok, url} <- catalog_url(identity.backend),
         {:ok, credential} <- read_credential(identity.backend, opts) do
      request_with_credential(identity, credential, url, opts)
    end
  end

  defp request_with_credential(identity, credential, url, opts) do
    case request_once(identity, credential, url, opts) do
      {{:error, %ModelCatalogFailure{code: :unauthorized, status: 401}},
       %CredentialReceipt{provider: :openai, owner: "source_owned"} = used} ->
        retry_source_once(identity, used, url, opts)

      {result, _credential} ->
        result
    end
  end

  defp retry_source_once(identity, used, url, opts) do
    reread = opts.reread_source_credential_fun || (&OAuth.reread_source_credential/1)

    case safe_reread(reread, used) do
      {:ok, %CredentialReceipt{} = latest} ->
        case validate_retry_receipt(used, latest) do
          {:ok, valid} ->
            case request_once(identity, valid, url, opts) do
              {{:error, %ModelCatalogFailure{code: :unauthorized, status: 401}}, _} ->
                {:error, :oauth_source_reauthentication_required}

              {result, _} ->
                result
            end

          {:error, _reason} ->
            {:error, :oauth_source_reauthentication_required}
        end

      _malformed_or_error ->
        # Unchanged, invalid, raised, or non-tuple reread → closed reauth; no second request.
        {:error, :oauth_source_reauthentication_required}
    end
  end

  defp safe_reread(reread, used) when is_function(reread, 1) do
    reread.(used)
  rescue
    _ -> {:error, :oauth_source_reauthentication_required}
  catch
    _, _ -> {:error, :oauth_source_reauthentication_required}
  end

  defp validate_retry_receipt(%CredentialReceipt{} = used, %CredentialReceipt{} = latest) do
    with {:ok, valid} <- validate_receipt(:openai, latest),
         true <- valid.provider == :openai,
         true <- valid.owner == "source_owned",
         true <- valid.generation == used.generation,
         true <- valid.account_id == used.account_id,
         true <- valid.access_token != used.access_token do
      {:ok, valid}
    else
      _ -> {:error, :oauth_source_reauthentication_required}
    end
  end

  defp request_once(identity, credential, url, opts) do
    headers = headers(identity.backend, credential)

    request_spec = %{
      method: :get,
      url: url,
      headers: headers,
      redirect: false,
      compressed: false
    }

    result =
      case perform_request(request_spec, opts) do
        {:ok, response} ->
          handle_response(identity, credential, response, opts)

        {:error, %ModelCatalogFailure{} = failure} ->
          {:error, failure}

        {:error, :response_bytes_exceeded} ->
          {:error, protocol_failure(identity, :response_bytes_exceeded)}

        {:error, :deadline_exceeded} ->
          {:error, transport_failure(identity, :deadline_exceeded)}

        {:error, :request_timeout} ->
          {:error, transport_failure(identity, :request_timeout)}

        {:error, _reason} ->
          {:error, transport_failure(identity, :connection_failed)}
      end

    {result, credential}
  end

  defp handle_response(identity, credential, response, opts) do
    with :ok <- validate_status_branch(identity, response),
         :ok <- transport_envelope(identity, response),
         {:ok, body} <- collect_raw_body(identity, response),
         :ok <- validate_response_headers(identity, response.headers),
         {:ok, model_ids} <- parse_catalog(identity, body),
         {:ok, catalog} <- build_catalog(identity, credential, model_ids, opts) do
      {:ok, catalog}
    end
  end

  defp transport_envelope(identity, response) do
    private = Map.get(response, :private, %{})

    cond do
      match?(%{arbor_response_overflow: _}, private) ->
        {:error, protocol_failure(identity, :response_bytes_exceeded)}

      match?(%{arbor_response_error: _}, private) ->
        {:error, protocol_failure(identity, :malformed_catalog)}

      true ->
        :ok
    end
  end

  defp validate_status_branch(_identity, %{status: 200}), do: :ok

  defp validate_status_branch(identity, %{status: status})
       when is_integer(status) and status >= 100 and status <= 599 do
    # Non-200: classify by status only; never parse or retain body.
    {:error, ModelCatalogFailure.from_status(identity.route, identity.backend, status)}
  end

  defp validate_status_branch(identity, _response),
    do: {:error, protocol_failure(identity, :malformed_catalog)}

  defp perform_request(request_spec, %{request_fun: fun}) when is_function(fun, 1) do
    case fun.(request_spec) do
      {:ok, %{status: status, body: body} = response}
      when is_integer(status) and is_binary(body) ->
        headers = Map.get(response, :headers, [])
        private = Map.get(response, :private, %{})
        {:ok, %{status: status, body: body, headers: headers, private: private}}

      {:error, %ModelCatalogFailure{} = failure} ->
        {:error, failure}

      {:error, reason}
      when reason in [
             :connection_failed,
             :deadline_exceeded,
             :request_timeout,
             :response_bytes_exceeded
           ] ->
        {:error, reason}

      _other ->
        {:error, :connection_failed}
    end
  end

  defp perform_request(request_spec, opts) do
    timeout = remaining_timeout_ms(opts)

    request =
      Req.new(
        url: request_spec.url,
        method: :get,
        headers: request_spec.headers,
        receive_timeout: timeout,
        redirect: false,
        compressed: false,
        decode_body: false,
        into: ResponseBudget.bounded_req_into(@max_response_bytes)
      )

    case Req.request(request) do
      {:ok, %Req.Response{} = response} ->
        {:ok,
         %{
           status: response.status,
           body: response.body,
           headers: response.headers,
           private: response.private
         }}

      {:error, _reason} ->
        {:error, :connection_failed}
    end
  rescue
    _ -> {:error, :connection_failed}
  catch
    _, _ -> {:error, :connection_failed}
  end

  defp remaining_timeout_ms(%{timeout_ms: timeout_ms}) do
    case Deadline.receipt(timeout_ms: timeout_ms) do
      {:ok, receipt} -> max(receipt.deadline_ms - System.monotonic_time(:millisecond), 1)
      _ -> timeout_ms
    end
  end

  defp collect_raw_body(identity, response) do
    private = Map.get(response, :private, %{})

    cond do
      Map.has_key?(private, :arbor_response_chunks) ->
        case private.arbor_response_chunks do
          chunks when is_list(chunks) ->
            if chunks_binary?(chunks) do
              body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
              admit_raw_body(identity, body)
            else
              {:error, protocol_failure(identity, :malformed_catalog)}
            end

          _malformed ->
            {:error, protocol_failure(identity, :malformed_catalog)}
        end

      is_binary(Map.get(response, :body)) ->
        admit_raw_body(identity, response.body)

      true ->
        {:error, protocol_failure(identity, :malformed_catalog)}
    end
  rescue
    _ -> {:error, protocol_failure(identity, :malformed_catalog)}
  catch
    _, _ -> {:error, protocol_failure(identity, :malformed_catalog)}
  end

  defp chunks_binary?([]), do: true
  defp chunks_binary?([chunk | rest]) when is_binary(chunk), do: chunks_binary?(rest)
  defp chunks_binary?(_malformed), do: false

  defp admit_raw_body(identity, body) when is_binary(body) do
    size = byte_size(body)

    cond do
      size == 0 ->
        {:error, protocol_failure(identity, :empty_raw_body)}

      size > @max_response_bytes ->
        {:error, protocol_failure(identity, :response_bytes_exceeded)}

      true ->
        {:ok, body}
    end
  end

  defp validate_response_headers(identity, headers) do
    with :ok <- identity_content_encoding(identity, headers),
         :ok <- json_content_type(identity, headers) do
      :ok
    end
  end

  defp identity_content_encoding(identity, headers) do
    case header_values(headers, "content-encoding") do
      :missing ->
        :ok

      {:ok, []} ->
        :ok

      {:ok, [value]} ->
        if String.downcase(String.trim(value)) in ["", "identity"],
          do: :ok,
          else: {:error, protocol_failure(identity, :invalid_response_headers)}

      {:ok, _multiple} ->
        # Duplicate content-encoding fails closed even when all are identity/empty.
        {:error, protocol_failure(identity, :invalid_response_headers)}

      reason when reason in [:duplicate, :malformed] ->
        {:error, protocol_failure(identity, :invalid_response_headers)}
    end
  end

  defp json_content_type(identity, headers) do
    case header_values(headers, "content-type") do
      {:ok, [value]} when is_binary(value) ->
        if admitted_json_media_type?(value),
          do: :ok,
          else: {:error, protocol_failure(identity, :invalid_response_headers)}

      _missing_duplicate_or_malformed ->
        {:error, protocol_failure(identity, :invalid_response_headers)}
    end
  end

  defp admitted_json_media_type?(value) when is_binary(value) do
    media_type =
      value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    media_type == "application/json" or Regex.match?(@plus_json_media_type, media_type)
  end

  defp admitted_json_media_type?(_value), do: false

  # Collect every case-insensitive occurrence of `name`.
  # Returns:
  #   {:ok, [binary values]} — zero or more well-formed binary values from one logical name
  #   :missing — no occurrence
  #   :duplicate — multi-value, case-insensitive duplicate map keys, or conflicting pairs
  #   :malformed — non-binary / non-list value, improper entry shape
  defp header_values(headers, name) when is_list(headers) do
    name_down = String.downcase(name)
    collect_list_header_values(headers, name_down, [], 0)
  end

  defp header_values(headers, name) when is_map(headers) do
    name_down = String.downcase(name)
    collect_map_header_values(Map.to_list(headers), name_down, [], 0)
  end

  defp header_values(_headers, _name), do: :malformed

  defp collect_list_header_values([], _name, [], _matches), do: :missing

  defp collect_list_header_values([], _name, acc, 1),
    do: finalize_header_values(Enum.reverse(acc))

  defp collect_list_header_values([], _name, _acc, matches) when matches > 1, do: :duplicate

  defp collect_list_header_values([{key, value} | rest], name, acc, matches) do
    case header_key_string(key) do
      {:ok, key_string} ->
        if String.downcase(key_string) == name do
          case normalize_header_value(value) do
            {:ok, values} ->
              collect_list_header_values(rest, name, values ++ acc, matches + 1)

            :malformed ->
              :malformed
          end
        else
          collect_list_header_values(rest, name, acc, matches)
        end

      :malformed ->
        # Key cannot be compared; skip non-target entries that are not string/atom keys.
        collect_list_header_values(rest, name, acc, matches)
    end
  end

  defp collect_list_header_values([_bad | _rest], _name, _acc, _matches), do: :malformed
  defp collect_list_header_values(_improper, _name, _acc, _matches), do: :malformed

  defp collect_map_header_values([], _name, [], _matches), do: :missing
  defp collect_map_header_values([], _name, acc, 1), do: finalize_header_values(Enum.reverse(acc))
  defp collect_map_header_values([], _name, _acc, matches) when matches > 1, do: :duplicate

  defp collect_map_header_values([{key, value} | rest], name, acc, matches) do
    case header_key_string(key) do
      {:ok, key_string} ->
        if String.downcase(key_string) == name do
          case normalize_header_value(value) do
            {:ok, values} ->
              # Each case-insensitive matching map key is a separate occurrence.
              collect_map_header_values(rest, name, values ++ acc, matches + 1)

            :malformed ->
              :malformed
          end
        else
          collect_map_header_values(rest, name, acc, matches)
        end

      :malformed ->
        collect_map_header_values(rest, name, acc, matches)
    end
  end

  defp collect_map_header_values(_improper, _name, _acc, _matches), do: :malformed

  defp header_key_string(key)
       when is_binary(key) and byte_size(key) > 0 and byte_size(key) <= 256 do
    if String.valid?(key), do: {:ok, key}, else: :malformed
  end

  defp header_key_string(key) when is_atom(key) and not is_nil(key) do
    {:ok, Atom.to_string(key)}
  rescue
    _ -> :malformed
  end

  defp header_key_string(_key), do: :malformed

  defp normalize_header_value(value) when is_binary(value), do: {:ok, [value]}

  defp normalize_header_value(values) when is_list(values) do
    normalize_header_value_list(values, [])
  end

  defp normalize_header_value(_value), do: :malformed

  defp normalize_header_value_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_header_value_list([value | rest], acc) when is_binary(value),
    do: normalize_header_value_list(rest, [value | acc])

  defp normalize_header_value_list(_malformed, _acc), do: :malformed

  defp finalize_header_values([]), do: {:ok, []}
  defp finalize_header_values([value]), do: {:ok, [value]}
  defp finalize_header_values(_multiple), do: :duplicate

  defp parse_catalog(identity, body) do
    result =
      case identity.backend do
        :openai ->
          with {:ok, json} <- ResponseBudget.decode_json(body, @json_limits),
               {:ok, models} <- fetch_list(json, "models"),
               :ok <- non_empty_list(models),
               {:ok, ids} <- parse_openai_models(models, [], MapSet.new(), 0) do
            {:ok, ids}
          end

        :xai ->
          with {:ok, json} <- ResponseBudget.decode_json(body, @json_limits),
               {:ok, data} <- fetch_list(json, "data"),
               :ok <- non_empty_list(data),
               {:ok, ids} <- parse_xai_models(data, [], MapSet.new(), 0) do
            {:ok, ids}
          end
      end

    case result do
      {:ok, ids} -> {:ok, ids}
      {:error, :empty_catalog} -> {:error, protocol_failure(identity, :empty_catalog)}
      {:error, :duplicate_model_id} -> {:error, protocol_failure(identity, :duplicate_model_id)}
      {:error, :catalog_too_large} -> {:error, protocol_failure(identity, :catalog_too_large)}
      {:error, :malformed_catalog} -> {:error, protocol_failure(identity, :malformed_catalog)}
      {:error, _reason} -> {:error, protocol_failure(identity, :malformed_catalog)}
    end
  end

  defp fetch_list(%{} = json, key) do
    case Map.fetch(json, key) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:error, :malformed_catalog}
    end
  end

  defp fetch_list(_json, _key), do: {:error, :malformed_catalog}

  defp non_empty_list([]), do: {:error, :empty_catalog}
  defp non_empty_list(list) when is_list(list), do: :ok

  defp parse_openai_models([], selectable, _seen, _count), do: {:ok, Enum.reverse(selectable)}

  defp parse_openai_models(_rest, _selectable, _seen, count) when count >= @max_models,
    do: {:error, :catalog_too_large}

  defp parse_openai_models([entry | rest], selectable, seen, count) when is_map(entry) do
    with {:ok, slug} <- required_model_id(entry, "slug"),
         {:ok, supported?} <- required_boolean(entry, "supported_in_api") do
      if MapSet.member?(seen, slug) do
        {:error, :duplicate_model_id}
      else
        seen = MapSet.put(seen, slug)
        selectable = if supported?, do: [slug | selectable], else: selectable
        parse_openai_models(rest, selectable, seen, count + 1)
      end
    end
  end

  defp parse_openai_models(_improper, _selectable, _seen, _count),
    do: {:error, :malformed_catalog}

  defp parse_xai_models([], ids, _seen, _count), do: {:ok, Enum.reverse(ids)}

  defp parse_xai_models(_rest, _ids, _seen, count) when count >= @max_models,
    do: {:error, :catalog_too_large}

  defp parse_xai_models([entry | rest], ids, seen, count) when is_map(entry) do
    with {:ok, id} <- required_model_id(entry, "id") do
      if MapSet.member?(seen, id) do
        {:error, :duplicate_model_id}
      else
        parse_xai_models(rest, [id | ids], MapSet.put(seen, id), count + 1)
      end
    end
  end

  defp parse_xai_models(_improper, _ids, _seen, _count), do: {:error, :malformed_catalog}

  defp required_model_id(entry, key) do
    case Map.get(entry, key) do
      id when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_model_id_bytes ->
        if String.valid?(id) and String.trim(id) != "" and
             not String.match?(id, ~r/[\x00-\x1F\x7F]/) do
          {:ok, id}
        else
          {:error, :malformed_catalog}
        end

      _ ->
        {:error, :malformed_catalog}
    end
  end

  defp required_boolean(entry, key) do
    case Map.get(entry, key) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :malformed_catalog}
    end
  end

  defp build_catalog(identity, credential, model_ids, opts) do
    now = opts.now_fn.()

    if match?(%DateTime{}, now) do
      expires = DateTime.add(now, @catalog_ttl_seconds, :second)

      case ProviderModelCatalog.new(%{
             version: ProviderModelCatalog.schema_version(),
             route: Atom.to_string(identity.route),
             backend: Atom.to_string(identity.backend),
             runtime: "arbor",
             model_ids: model_ids,
             observed_at: DateTime.to_iso8601(now),
             expires_at: DateTime.to_iso8601(expires),
             credential_generation: credential.generation
           }) do
        {:ok, catalog} ->
          {:ok, catalog}

        {:error, _reason} ->
          {:error, protocol_failure(identity, :malformed_catalog)}
      end
    else
      {:error, protocol_failure(identity, :malformed_catalog)}
    end
  end

  defp headers(:openai, %CredentialReceipt{} = credential) do
    [
      {"authorization", "Bearer " <> credential.access_token},
      {"user-agent", "codex_cli_rs/0.0.0 (Arbor)"},
      {"originator", "codex_cli_rs"},
      {"chatgpt-account-id", credential.account_id || ""}
    ]
  end

  defp headers(:xai, %CredentialReceipt{} = credential) do
    [{"authorization", "Bearer " <> credential.access_token}]
  end

  defp catalog_url(:openai) do
    with {:ok, base} <- Endpoint.validate(@openai_catalog_path, :oauth_model_catalog),
         true <-
           client_version_valid?(@openai_client_version) or
             {:error, :endpoint_origin_not_trusted} do
      {:ok, base <> "?client_version=" <> @openai_client_version}
    end
  end

  defp catalog_url(:xai), do: Endpoint.validate(@xai_catalog_url, :oauth_model_catalog)

  defp client_version_valid?(version)
       when is_binary(version) and byte_size(version) in 1..64 do
    version =~ ~r/\A[A-Za-z0-9._-]+\z/
  end

  defp client_version_valid?(_version), do: false

  defp read_credential(backend, %{credential_receipt_fun: fun}) when is_function(fun, 1) do
    case fun.(backend) do
      {:ok, receipt} -> validate_receipt(backend, receipt)
      {:error, reason} -> {:error, reason}
      _ -> {:error, ModelCatalogFailure.options(:invalid_credential_receipt)}
    end
  end

  defp read_credential(backend, _opts) do
    case OAuth.credential_receipt(backend) do
      {:ok, receipt} -> validate_receipt(backend, receipt)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_receipt(backend, %CredentialReceipt{} = receipt) do
    with :ok <- validate_provider(backend, receipt.provider),
         :ok <- validate_owner(backend, receipt.owner),
         :ok <- validate_generation(receipt.generation),
         :ok <- validate_token(receipt.access_token),
         :ok <- validate_account_id(backend, receipt.owner, receipt.account_id) do
      {:ok, receipt}
    else
      {:error, :oauth_source_owned_unsupported} = error ->
        error

      {:error, _reason} ->
        {:error, ModelCatalogFailure.options(:invalid_credential_receipt)}
    end
  end

  defp validate_receipt(_backend, _receipt),
    do: {:error, ModelCatalogFailure.options(:invalid_credential_receipt)}

  defp validate_provider(backend, backend) when backend in [:openai, :xai], do: :ok
  defp validate_provider(_backend, _provider), do: {:error, :mismatched_provider}

  defp validate_owner(:openai, owner) when owner in ["arbor_owned", "source_owned"], do: :ok
  defp validate_owner(:xai, "arbor_owned"), do: :ok
  defp validate_owner(:xai, "source_owned"), do: {:error, :oauth_source_owned_unsupported}
  defp validate_owner(_backend, _owner), do: {:error, :invalid_owner}

  defp validate_generation(value)
       when is_integer(value) and value >= 0 and value <= @max_generation,
       do: :ok

  defp validate_generation(_value), do: {:error, :invalid_generation}

  defp validate_token(token)
       when is_binary(token) and byte_size(token) > 0 and
              byte_size(token) <= @max_access_token_bytes do
    if String.valid?(token) and not String.match?(token, ~r/[\x00-\x1F\x7F]/),
      do: :ok,
      else: {:error, :invalid_token}
  end

  defp validate_token(_token), do: {:error, :invalid_token}

  defp validate_account_id(:openai, "source_owned", account_id)
       when is_binary(account_id) and byte_size(account_id) > 0 and
              byte_size(account_id) <= @max_account_id_bytes do
    if String.valid?(account_id) and String.trim(account_id) != "" and
         not String.match?(account_id, ~r/[\x00-\x1F\x7F]/),
       do: :ok,
       else: {:error, :invalid_account_id}
  end

  defp validate_account_id(:openai, "source_owned", _account_id),
    do: {:error, :invalid_account_id}

  defp validate_account_id(:openai, "arbor_owned", nil), do: :ok

  defp validate_account_id(:openai, "arbor_owned", account_id)
       when is_binary(account_id) and byte_size(account_id) > 0 and
              byte_size(account_id) <= @max_account_id_bytes do
    if String.valid?(account_id) and not String.match?(account_id, ~r/[\x00-\x1F\x7F]/),
      do: :ok,
      else: {:error, :invalid_account_id}
  end

  defp validate_account_id(:openai, "arbor_owned", _account_id),
    do: {:error, :invalid_account_id}

  defp validate_account_id(:xai, _owner, nil), do: :ok
  defp validate_account_id(:xai, _owner, _account_id), do: {:error, :invalid_account_id}
  defp validate_account_id(_backend, _owner, _account_id), do: {:error, :invalid_account_id}

  defp resolve_identity(route) do
    with {:ok, %{route: route, backend: backend}} <- OAuth.route_only(route) do
      {:ok, %{route: route, backend: backend}}
    end
  end

  defp normalize_options(opts) when is_list(opts) do
    with :ok <- validate_option_shape(opts),
         :ok <- reject_forbidden_options(opts),
         :ok <- reject_unknown_options(opts),
         {:ok, timeout_ms} <-
           bounded_int(opts, :timeout_ms, @default_timeout_ms, 1, @max_timeout_ms),
         {:ok, now_fn} <- now_fn(opts),
         {:ok, credential_receipt_fun} <- optional_fun(opts, :credential_receipt_fun, 1),
         {:ok, reread_source_credential_fun} <-
           optional_fun(opts, :reread_source_credential_fun, 1),
         {:ok, request_fun} <- optional_fun(opts, :request_fun, 1) do
      {:ok,
       %{
         timeout_ms: timeout_ms,
         now_fn: now_fn,
         credential_receipt_fun: credential_receipt_fun,
         reread_source_credential_fun: reread_source_credential_fun,
         request_fun: request_fun
       }}
    end
  end

  defp validate_option_shape(opts), do: validate_keyword_pairs(opts, 0)

  defp validate_keyword_pairs([], _count), do: :ok

  defp validate_keyword_pairs(_opts, count) when count >= @max_options,
    do: {:error, ModelCatalogFailure.options(:invalid_options)}

  defp validate_keyword_pairs([{key, _value} | rest], count) when is_atom(key),
    do: validate_keyword_pairs(rest, count + 1)

  defp validate_keyword_pairs(_improper, _count),
    do: {:error, ModelCatalogFailure.options(:invalid_options)}

  defp reject_forbidden_options(opts) do
    if Enum.any?(@forbidden_option_keys, &Keyword.has_key?(opts, &1)) do
      {:error, ModelCatalogFailure.options(:forbidden_option)}
    else
      :ok
    end
  end

  defp reject_unknown_options(opts) do
    unknown =
      Enum.reject(Keyword.keys(opts), fn key ->
        key in @allowed_option_keys
      end)

    if unknown == [],
      do: :ok,
      else: {:error, ModelCatalogFailure.options(:forbidden_option)}
  end

  defp bounded_int(opts, key, default, min, max) do
    case Keyword.fetch(opts, key) do
      :error ->
        {:ok, default}

      {:ok, value} when is_integer(value) and value >= min and value <= max ->
        {:ok, value}

      _ ->
        {:error, ModelCatalogFailure.options(:invalid_options)}
    end
  end

  defp now_fn(opts) do
    cond do
      is_function(Keyword.get(opts, :now_fn), 0) ->
        {:ok, Keyword.fetch!(opts, :now_fn)}

      is_function(Keyword.get(opts, :clock), 0) ->
        {:ok, Keyword.fetch!(opts, :clock)}

      Keyword.has_key?(opts, :now_fn) or Keyword.has_key?(opts, :clock) ->
        {:error, ModelCatalogFailure.options(:invalid_options)}

      true ->
        {:ok, fn -> DateTime.utc_now() |> DateTime.truncate(:second) end}
    end
  end

  defp optional_fun(opts, key, arity) do
    case Keyword.fetch(opts, key) do
      :error ->
        {:ok, nil}

      {:ok, fun} when is_function(fun, arity) ->
        {:ok, fun}

      _ ->
        {:error, ModelCatalogFailure.options(:invalid_options)}
    end
  end

  defp transport_failure(identity, code),
    do: ModelCatalogFailure.transport(identity.route, identity.backend, code)

  defp protocol_failure(identity, code),
    do: ModelCatalogFailure.protocol(identity.route, identity.backend, code)
end
