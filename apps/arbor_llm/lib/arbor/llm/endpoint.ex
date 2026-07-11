defmodule Arbor.LLM.Endpoint do
  @moduledoc false

  @max_endpoint_bytes 4_096
  @host_regex ~r/^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$/

  @type policy :: :root | :embedding | :lm_studio | :req_llm_base

  @spec validate(term(), policy()) :: {:ok, String.t()} | {:error, atom()}
  def validate(value, policy)
      when is_binary(value) and byte_size(value) <= @max_endpoint_bytes and
             policy in [:root, :embedding, :lm_studio, :req_llm_base] do
    with :ok <- validate_text(value),
         {:ok, scheme, authority, path} <- split_original(value),
         {:ok, host, port, explicit_port?} <- parse_authority(authority),
         {:ok, canonical_host} <- validate_host(host),
         {:ok, canonical_path} <- validate_path(path, policy),
         :ok <- verify_uri_parse(value, scheme, host, port),
         canonical <- canonical(scheme, canonical_host, port, explicit_port?, canonical_path),
         :ok <- verify_canonical(canonical, scheme, canonical_host, port, canonical_path) do
      {:ok, canonical}
    end
  end

  def validate(_value, _policy), do: {:error, :bounded_string_required}

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
  defp validate_path(_path, :root), do: {:error, :base_path_must_be_root}
  defp validate_path(_path, :embedding), do: {:error, :embedding_path_must_be_v1_embeddings}
  defp validate_path(_path, :lm_studio), do: {:error, :base_path_must_be_v1}
  defp validate_path(_path, :req_llm_base), do: {:error, :ambiguous_base_path}

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

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
end
