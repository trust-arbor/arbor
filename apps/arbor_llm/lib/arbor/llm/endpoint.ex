defmodule Arbor.LLM.Endpoint do
  @moduledoc false

  @max_endpoint_bytes 4_096
  @host_regex ~r/^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$/
  @provider_base_paths %{
    "amazon_bedrock" => [""],
    "anthropic" => [""],
    "azure" => ["", "/openai"],
    "cerebras" => ["/v1"],
    "google" => ["/v1", "/v1beta"],
    "google_vertex" => [""],
    "groq" => ["/openai/v1"],
    "lm_studio" => ["/v1"],
    "ollama" => ["/v1"],
    "openai" => ["/v1"],
    "openrouter" => ["/api/v1"],
    "venice" => ["/api/v1"],
    "vllm" => ["/v1"],
    "xai" => ["/v1"],
    "zai" => ["/api/paas/v4"],
    "zai_coder" => ["/api/coding/paas/v4"],
    "zai_coding_plan" => ["/api/coding/paas/v4"],
    "zenmux" => ["/api/v1"]
  }
  @endpoint_suffixes ["chat/completions", "embeddings", "responses", "models"]
  @official_origins %{
    "anthropic" => ["https://api.anthropic.com"],
    "cerebras" => ["https://api.cerebras.ai"],
    "google" => ["https://generativelanguage.googleapis.com"],
    "groq" => ["https://api.groq.com"],
    "openai" => ["https://api.openai.com"],
    "openrouter" => ["https://openrouter.ai"],
    "venice" => ["https://api.venice.ai"],
    "xai" => ["https://api.x.ai"],
    "zai" => ["https://api.z.ai", "https://open.bigmodel.cn"],
    "zai_coder" => ["https://api.z.ai", "https://open.bigmodel.cn"],
    "zai_coding_plan" => ["https://api.z.ai", "https://open.bigmodel.cn"],
    "zenmux" => ["https://zenmux.ai"]
  }
  @default_eval_origin "http://localhost:11434"
  @oauth_response_endpoints [
    "https://chatgpt.com/backend-api/codex/responses",
    "https://api.x.ai/v1/responses"
  ]
  @oauth_discovery_endpoints ["https://auth.x.ai/.well-known/openid-configuration"]
  @oauth_token_origins ["https://auth.openai.com", "https://auth.x.ai"]
  @eval_http_paths ["/api/embeddings", "/api/chat", "/v1/embeddings"]

  @type policy ::
          :root
          | :embedding
          | :lm_studio
          | :eval_http
          | :oauth_responses
          | :oauth_discovery
          | :oauth_token
          | :oauth_xai_token
          | :req_llm_base
          | {:req_llm_base, atom() | String.t()}

  @spec validate(term(), policy()) :: {:ok, String.t()} | {:error, atom()}
  def validate(value, policy)
      when is_binary(value) and byte_size(value) <= @max_endpoint_bytes do
    with {:ok, path_policy} <- normalize_policy(policy),
         :ok <- validate_text(value),
         {:ok, scheme, authority, path} <- split_original(value),
         {:ok, host, port, explicit_port?} <- parse_authority(authority),
         {:ok, canonical_host} <- validate_host(host),
         {:ok, canonical_path} <- validate_path(path, path_policy),
         :ok <- verify_uri_parse(value, scheme, host, port),
         canonical <- canonical(scheme, canonical_host, port, explicit_port?, canonical_path),
         :ok <- verify_canonical(canonical, scheme, canonical_host, port, canonical_path),
         :ok <- authorize_endpoint(canonical, path_policy) do
      {:ok, canonical}
    end
  end

  def validate(_value, _policy), do: {:error, :bounded_string_required}

  defp normalize_policy(policy)
       when policy in [
              :root,
              :embedding,
              :lm_studio,
              :eval_http,
              :oauth_responses,
              :oauth_discovery,
              :oauth_token,
              :oauth_xai_token,
              :req_llm_base
            ],
       do: {:ok, policy}

  defp normalize_policy({:req_llm_base, provider})
       when (is_atom(provider) or is_binary(provider)) and not is_nil(provider) do
    with {:ok, provider} <- normalize_provider_name(provider),
         {:ok, configured} <- configured_provider_endpoints(provider) do
      {:ok, {:operator_req_llm_base, provider, configured}}
    end
  end

  defp normalize_policy(_policy), do: {:error, :invalid_endpoint_policy}

  defp normalize_provider_name(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> normalize_provider_name()

  defp normalize_provider_name(provider)
       when is_binary(provider) and byte_size(provider) > 0 and byte_size(provider) <= 256 do
    if String.valid?(provider),
      do: {:ok, Arbor.LLM.ProviderRegistry.normalize(provider)},
      else: {:error, :invalid_endpoint_policy}
  end

  defp normalize_provider_name(_provider), do: {:error, :invalid_endpoint_policy}

  defp validate_text(value) do
    cond do
      value == "" -> {:error, :endpoint_required}
      not String.valid?(value) -> {:error, :valid_utf8_required}
      value =~ ~r/[\x00-\x20\x7f\\]/ -> {:error, :invalid_endpoint_character}
      true -> :ok
    end
  end

  # Splitting the original text is intentional. URI.parse/1 repairs malformed
  # ports and bracket suffixes, which can silently change the authority.
  defp split_original(value) do
    case Regex.run(~r/\A(https?):\/\/([^\/?#]*)([^?#]*)(?:\?[^#]*)?(?:#.*)?\z/s, value) do
      [_, scheme, authority, path] ->
        cond do
          authority == "" -> {:error, :host_required}
          String.contains?(value, "?") -> {:error, :query_forbidden}
          String.contains?(value, "#") -> {:error, :fragment_forbidden}
          true -> {:ok, scheme, authority, path}
        end

      _ ->
        {:error, :absolute_http_endpoint_required}
    end
  end

  defp parse_authority(authority) do
    cond do
      String.contains?(authority, "@") ->
        {:error, :userinfo_forbidden}

      String.contains?(authority, "%") ->
        {:error, :encoded_authority_forbidden}

      String.starts_with?(authority, "[") ->
        parse_bracketed_authority(authority)

      String.contains?(authority, ["[", "]"]) ->
        {:error, :invalid_bracketed_host}

      true ->
        parse_named_authority(authority)
    end
  end

  defp parse_bracketed_authority("[" <> rest) do
    case :binary.match(rest, "]") do
      :nomatch ->
        {:error, :invalid_bracketed_host}

      {index, 1} ->
        host = binary_part(rest, 0, index)
        suffix_size = byte_size(rest) - index - 1
        suffix = binary_part(rest, index + 1, suffix_size)

        with true <- host != "" or {:error, :host_required},
             {:ok, port, explicit?} <- parse_port_suffix(suffix),
             {:ok, _} <- parse_ip(host),
             true <- String.contains?(host, ":") or {:error, :brackets_require_ipv6} do
          {:ok, host, port, explicit?}
        else
          {:error, _} = error -> error
          false -> {:error, :invalid_bracketed_host}
        end
    end
  end

  defp parse_port_suffix(""), do: {:ok, nil, false}
  defp parse_port_suffix(":" <> digits), do: parse_port(digits)
  defp parse_port_suffix(_suffix), do: {:error, :invalid_authority_suffix}

  defp parse_named_authority(authority) do
    case :binary.split(authority, ":", [:global]) do
      [host] when host != "" -> {:ok, host, nil, false}
      [host, digits] when host != "" -> parse_port(digits, host)
      [""] -> {:error, :host_required}
      _ -> {:error, :unbracketed_ipv6_forbidden}
    end
  end

  defp parse_port(digits), do: parse_port(digits, nil)

  defp parse_port(digits, host)
       when byte_size(digits) in 1..5 do
    if digits =~ ~r/\A[0-9]+\z/ do
      port = String.to_integer(digits)

      if port in 1..65_535 do
        if host, do: {:ok, host, port, true}, else: {:ok, port, true}
      else
        {:error, :valid_port_required}
      end
    else
      {:error, :numeric_port_required}
    end
  end

  defp parse_port(_digits, _host), do: {:error, :numeric_port_required}

  defp validate_host(host) do
    case parse_ip(host) do
      {:ok, address} ->
        canonical_ip_host(host, address)

      {:error, _reason} ->
        if byte_size(host) <= 253 and not ambiguous_numeric_host?(host) and
             Regex.match?(@host_regex, host),
           do: {:ok, String.downcase(host)},
           else: {:error, :valid_host_required}
    end
  end

  # `:inet.parse_address/1` accepts legacy IPv4 aliases such as `127.1`,
  # integer dwords, octal, and hex. Requiring the dotted-decimal round trip
  # prevents endpoint text from naming a different authority than it appears to.
  defp canonical_ip_host(host, {_, _, _, _} = address) do
    canonical = address |> :inet.ntoa() |> List.to_string()

    if host == canonical,
      do: {:ok, canonical},
      else: {:error, :canonical_ipv4_required}
  end

  defp canonical_ip_host(_host, address) when tuple_size(address) == 8,
    do: {:ok, address |> :inet.ntoa() |> List.to_string() |> String.downcase()}

  defp parse_ip(host), do: :inet.parse_address(String.to_charlist(host))

  defp ambiguous_numeric_host?(host),
    do: Regex.match?(~r/\A[0-9.]+\z/, host) or Regex.match?(~r/\A0[xX][0-9A-Fa-f]+\z/, host)

  defp validate_path(path, :root) when path in ["", "/"], do: {:ok, ""}
  defp validate_path("/v1/embeddings", :embedding), do: {:ok, "/v1/embeddings"}
  defp validate_path(path, :lm_studio) when path in ["", "/", "/v1", "/v1/"], do: {:ok, "/v1"}

  defp validate_path(path, :req_llm_base) when path in ["", "/"], do: {:ok, ""}
  defp validate_path(path, :req_llm_base) when path in ["/v1", "/v1/"], do: {:ok, "/v1"}

  defp validate_path(path, :eval_http) do
    with {:ok, canonical} <- canonical_endpoint_path(path),
         true <- canonical in @eval_http_paths or {:error, :eval_http_path_not_allowed} do
      {:ok, canonical}
    end
  end

  defp validate_path(path, :oauth_responses), do: canonical_endpoint_path(path)
  defp validate_path(path, :oauth_discovery), do: canonical_endpoint_path(path)
  defp validate_path(path, :oauth_token), do: canonical_endpoint_path(path)
  defp validate_path(path, :oauth_xai_token), do: canonical_endpoint_path(path)

  defp validate_path(path, {:operator_req_llm_base, provider, configured}) do
    with {:ok, canonical} <- canonical_endpoint_path(path) do
      configured_paths = Enum.map(configured, &endpoint_path/1)
      allowed = Map.get(@provider_base_paths, provider, []) ++ configured_paths

      cond do
        endpoint_suffix?(canonical) -> {:error, :endpoint_suffix_must_not_be_in_base_url}
        canonical in allowed -> {:ok, canonical}
        true -> {:error, :base_path_not_allowed_for_provider}
      end
    end
  end

  defp validate_path(_path, :root), do: {:error, :base_path_must_be_root}
  defp validate_path(_path, :embedding), do: {:error, :embedding_path_must_be_v1_embeddings}
  defp validate_path(_path, :lm_studio), do: {:error, :base_path_must_be_v1}
  defp validate_path(_path, :req_llm_base), do: {:error, :ambiguous_base_path}

  defp canonical_path("/"), do: ""
  defp canonical_path(path), do: String.trim_trailing(path, "/")

  defp canonical_endpoint_path(path) do
    segments = String.split(path, "/", trim: true)

    cond do
      String.contains?(path, ["%", "\\", "//"]) -> {:error, :ambiguous_base_path}
      Enum.any?(segments, &(&1 in [".", ".."])) -> {:error, :path_traversal_forbidden}
      String.ends_with?(path, "//") -> {:error, :ambiguous_base_path}
      true -> {:ok, canonical_path(path)}
    end
  end

  defp endpoint_suffix?(path) do
    Enum.any?(@endpoint_suffixes, fn suffix ->
      path == "/" <> suffix or String.ends_with?(path, "/" <> suffix)
    end)
  end

  defp verify_uri_parse(value, scheme, host, port) do
    uri = URI.parse(value)
    expected_port = port || default_port(scheme)

    cond do
      uri.scheme != scheme -> {:error, :authority_parse_mismatch}
      not is_binary(uri.host) -> {:error, :authority_parse_mismatch}
      String.downcase(uri.host) != String.downcase(host) -> {:error, :authority_parse_mismatch}
      uri.port != expected_port -> {:error, :authority_parse_mismatch}
      not is_nil(uri.userinfo) -> {:error, :userinfo_forbidden}
      not is_nil(uri.query) -> {:error, :query_forbidden}
      not is_nil(uri.fragment) -> {:error, :fragment_forbidden}
      true -> :ok
    end
  end

  defp canonical(scheme, host, port, explicit_port?, path) do
    rendered_host =
      if String.contains?(host, ":"),
        do: "[#{String.downcase(host)}]",
        else: String.downcase(host)

    rendered_port = if explicit_port?, do: ":#{port}", else: ""
    scheme <> "://" <> rendered_host <> rendered_port <> path
  end

  defp verify_canonical(value, scheme, host, port, path) do
    uri = URI.parse(value)

    if uri.scheme == scheme and is_binary(uri.host) and
         String.downcase(uri.host) == String.downcase(host) and
         uri.port == (port || default_port(scheme)) and uri.path in [path, nil] do
      :ok
    else
      {:error, :canonical_authority_mismatch}
    end
  end

  defp authorize_endpoint(canonical, :root) do
    if canonical == @default_eval_origin,
      do: :ok,
      else: authorize_configured_eval_origin(canonical)
  end

  defp authorize_endpoint(canonical, :embedding) do
    if canonical == @default_eval_origin <> "/v1/embeddings",
      do: :ok,
      else: authorize_configured_eval_origin(canonical)
  end

  defp authorize_endpoint(canonical, :eval_http), do: authorize_configured_eval_origin(canonical)

  defp authorize_endpoint(canonical, :lm_studio) do
    configured =
      Application.get_env(:arbor_llm, :lm_studio_base_url, "http://localhost:1234/v1")

    with {:ok, trusted} <- canonical_operator_endpoint(configured, false),
         true <- canonical == trusted or {:error, :endpoint_origin_not_trusted} do
      :ok
    end
  end

  defp authorize_endpoint(_canonical, :req_llm_base),
    do: {:error, :provider_owned_endpoint_policy_required}

  defp authorize_endpoint(canonical, {:operator_req_llm_base, provider, configured}) do
    official = Map.get(@official_origins, provider, [])
    canonical_origin = endpoint_origin(canonical)

    cond do
      canonical in configured -> :ok
      canonical_origin in official -> :ok
      true -> {:error, :endpoint_origin_not_trusted}
    end
  end

  defp authorize_endpoint(canonical, :oauth_responses) do
    with {:ok, configured} <- configured_endpoint_list(:trusted_oauth_response_endpoints, true) do
      if canonical in @oauth_response_endpoints or canonical in configured,
        do: :ok,
        else: {:error, :endpoint_origin_not_trusted}
    end
  end

  defp authorize_endpoint(canonical, :oauth_discovery) do
    if canonical in @oauth_discovery_endpoints,
      do: :ok,
      else: {:error, :endpoint_origin_not_trusted}
  end

  defp authorize_endpoint(canonical, :oauth_token) do
    with {:ok, configured} <- configured_endpoint_list(:trusted_oauth_token_endpoints, true) do
      allowed_origins = @oauth_token_origins ++ Enum.map(configured, &endpoint_origin/1)

      if endpoint_origin(canonical) in allowed_origins,
        do: :ok,
        else: {:error, :endpoint_origin_not_trusted}
    end
  end

  defp authorize_endpoint(canonical, :oauth_xai_token) do
    if endpoint_origin(canonical) == "https://auth.x.ai",
      do: :ok,
      else: {:error, :endpoint_origin_not_trusted}
  end

  defp authorize_configured_eval_origin(canonical) do
    with {:ok, configured} <- configured_endpoint_list(:trusted_eval_endpoints, true) do
      trusted_origins = [@default_eval_origin | Enum.map(configured, &endpoint_origin/1)]

      if endpoint_origin(canonical) in trusted_origins,
        do: :ok,
        else: {:error, :endpoint_origin_not_trusted}
    end
  end

  defp configured_provider_endpoints(provider) do
    configured = Application.get_env(:arbor_llm, :trusted_proxy_endpoints, %{})

    with {:ok, configured_values} <- provider_config_values(configured, provider),
         {:ok, configured_endpoints} <- canonical_endpoint_list(configured_values, false),
         {:ok, local_endpoints} <- local_provider_endpoints(provider) do
      {:ok, Enum.uniq(configured_endpoints ++ local_endpoints)}
    end
  end

  defp provider_config_values(configured, provider) when is_map(configured) do
    value =
      Map.get(configured, provider) ||
        Enum.find_value(configured, fn
          {key, value} when is_atom(key) -> if Atom.to_string(key) == provider, do: value
          _entry -> nil
        end)

    {:ok, value || []}
  end

  defp provider_config_values(_configured, _provider),
    do: {:error, :invalid_trusted_endpoint_config}

  defp local_provider_endpoints(provider) do
    if Arbor.LLM.ProviderRegistry.local?(provider) do
      case Arbor.LLM.ProviderRegistry.default_base_url(provider) do
        value when is_binary(value) ->
          case canonical_operator_endpoint(value, false) do
            {:ok, canonical} -> {:ok, [canonical]}
            {:error, _reason} -> {:error, :invalid_local_provider_endpoint}
          end

        _other ->
          {:error, :invalid_local_provider_endpoint}
      end
    else
      {:ok, []}
    end
  end

  defp configured_endpoint_list(key, allow_endpoint_suffix?) do
    key
    |> then(&Application.get_env(:arbor_llm, &1, []))
    |> canonical_endpoint_list(allow_endpoint_suffix?)
  end

  defp canonical_endpoint_list(value, allow_endpoint_suffix?) when is_binary(value),
    do: canonical_endpoint_list([value], allow_endpoint_suffix?)

  defp canonical_endpoint_list(value, allow_endpoint_suffix?) do
    canonical_endpoint_list(value, allow_endpoint_suffix?, [], 0)
  end

  defp canonical_endpoint_list([], _allow_endpoint_suffix?, acc, _count),
    do: {:ok, Enum.reverse(acc)}

  defp canonical_endpoint_list(_values, _allow_endpoint_suffix?, _acc, count) when count >= 32,
    do: {:error, :too_many_trusted_endpoints}

  defp canonical_endpoint_list([value | rest], allow_endpoint_suffix?, acc, count)
       when is_binary(value) do
    case canonical_operator_endpoint(value, allow_endpoint_suffix?) do
      {:ok, canonical} ->
        canonical_endpoint_list(rest, allow_endpoint_suffix?, [canonical | acc], count + 1)

      {:error, _reason} ->
        {:error, :invalid_trusted_endpoint_config}
    end
  end

  defp canonical_endpoint_list(_improper_or_invalid, _allow_endpoint_suffix?, _acc, _count),
    do: {:error, :invalid_trusted_endpoint_config}

  defp canonical_operator_endpoint(value, allow_endpoint_suffix?)
       when is_binary(value) and byte_size(value) <= @max_endpoint_bytes do
    with :ok <- validate_text(value),
         {:ok, scheme, authority, path} <- split_original(value),
         {:ok, host, port, explicit_port?} <- parse_authority(authority),
         {:ok, canonical_host} <- validate_host(host),
         {:ok, canonical_path} <- canonical_endpoint_path(path),
         true <-
           allow_endpoint_suffix? or not endpoint_suffix?(canonical_path) or
             {:error, :endpoint_suffix_must_not_be_in_base_url},
         :ok <- verify_uri_parse(value, scheme, host, port),
         canonical <- canonical(scheme, canonical_host, port, explicit_port?, canonical_path),
         :ok <- verify_canonical(canonical, scheme, canonical_host, port, canonical_path) do
      {:ok, canonical}
    end
  end

  defp canonical_operator_endpoint(_value, _allow_endpoint_suffix?),
    do: {:error, :bounded_string_required}

  defp endpoint_origin(value) do
    uri = URI.parse(value)
    host = if String.contains?(uri.host || "", ":"), do: "[#{uri.host}]", else: uri.host
    port = uri.port || default_port(uri.scheme)
    rendered_port = if port == default_port(uri.scheme), do: "", else: ":#{port}"
    "#{uri.scheme}://#{host}#{rendered_port}"
  end

  defp endpoint_path(value), do: URI.parse(value).path || ""

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
end
