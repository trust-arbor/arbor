defmodule Arbor.Security.Store.RecordAuthenticator do
  @moduledoc false

  alias Arbor.Contracts.Coding.CanonicalJson
  alias Arbor.Contracts.Security.TaintEnvelope

  @algorithm "hmac-sha256"
  @key_id "master-key-v1"
  @domain "arbor.security.authority_store.record.v1\0"
  @allowed_auth_keys MapSet.new(["algorithm", "key_id", "tag"])
  @test_env Mix.env() == :test

  @type purpose :: :authority_record | :capability_revocation_ledger

  @spec seal(map(), purpose(), keyword()) :: {:ok, map()} | {:error, atom()}
  def seal(projection, purpose, opts) when is_map(projection) and is_list(opts) do
    with {:ok, bytes} <- canonical_bytes(projection, purpose),
         {:ok, tag} <- authenticate(bytes, purpose, opts) do
      {:ok,
       %{
         "algorithm" => @algorithm,
         "key_id" => @key_id,
         "tag" => Base.encode16(tag, case: :lower)
       }}
    end
  rescue
    _ -> {:error, :record_authentication_unavailable}
  catch
    _, _ -> {:error, :record_authentication_unavailable}
  end

  def seal(_projection, _purpose, _opts),
    do: {:error, :record_authentication_unavailable}

  @spec verify(map(), term(), purpose(), keyword()) :: :ok | {:error, atom()}
  def verify(projection, auth, purpose, opts)
      when is_map(projection) and is_map(auth) and is_list(opts) do
    with :ok <- admit_auth(auth),
         {:ok, supplied} <- Base.decode16(auth["tag"], case: :mixed),
         true <- byte_size(supplied) == 32,
         {:ok, bytes} <- canonical_bytes(projection, purpose),
         :ok <- verify_tag(bytes, supplied, purpose, opts) do
      :ok
    else
      {:error, :record_authentication_unavailable} = error -> error
      _ -> {:error, :record_authentication_failed}
    end
  rescue
    _ -> {:error, :record_authentication_failed}
  catch
    _, _ -> {:error, :record_authentication_failed}
  end

  def verify(_projection, _auth, _purpose, _opts),
    do: {:error, :record_authentication_failed}

  defp admit_auth(auth) do
    keys = Map.keys(auth)

    cond do
      map_size(auth) != 3 -> {:error, :record_authentication_failed}
      not Enum.all?(keys, &is_binary/1) -> {:error, :record_authentication_failed}
      MapSet.new(keys) != @allowed_auth_keys -> {:error, :record_authentication_failed}
      auth["algorithm"] != @algorithm -> {:error, :record_authentication_failed}
      auth["key_id"] != @key_id -> {:error, :record_authentication_failed}
      not valid_tag?(auth["tag"]) -> {:error, :record_authentication_failed}
      true -> :ok
    end
  end

  defp valid_tag?(tag) when is_binary(tag),
    do: byte_size(tag) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, tag)

  defp valid_tag?(_tag), do: false

  defp canonical_bytes(projection, :authority_record) do
    with {:ok, bytes} <- TaintEnvelope.canonical_json(projection) do
      {:ok, domain_separate(:authority_record, bytes)}
    else
      _ -> {:error, :record_authentication_failed}
    end
  end

  # Revocation ledgers admit as many as 100,000 strictly validated digest keys.
  # TaintEnvelope deliberately caps a generic object's key count at 256, so it
  # cannot encode this bounded persistence format once the 257th capability is
  # revoked. CanonicalJson preserves bytewise key ordering for maps of any size;
  # RevocationLedger validates this projection before verification and builds it
  # itself before sealing.
  defp canonical_bytes(projection, :capability_revocation_ledger) do
    with {:ok, bytes} <- CanonicalJson.encode(projection) do
      {:ok, domain_separate(:capability_revocation_ledger, bytes)}
    else
      _ -> {:error, :record_authentication_failed}
    end
  end

  defp canonical_bytes(_projection, _purpose),
    do: {:error, :record_authentication_failed}

  defp domain_separate(purpose, bytes),
    do: @domain <> Atom.to_string(purpose) <> <<0>> <> bytes

  defp authenticate(bytes, purpose, opts) do
    case Keyword.fetch(opts, :record_authentication_token) do
      {:ok, token} -> owner_authenticate(token, purpose, bytes, opts)
      :error -> test_backend_authenticate(bytes, opts)
    end
  end

  defp verify_tag(bytes, supplied, purpose, opts) do
    case Keyword.fetch(opts, :record_authentication_token) do
      {:ok, token} -> owner_verify(token, purpose, bytes, supplied, opts)
      :error -> test_backend_verify(bytes, supplied, opts)
    end
  end

  defp owner_authenticate(token, purpose, bytes, opts) do
    case master_key_authenticate(token, purpose, bytes, opts) do
      {:ok, tag} when is_binary(tag) and byte_size(tag) == 32 -> {:ok, tag}
      _ -> {:error, :record_authentication_unavailable}
    end
  end

  defp owner_verify(token, purpose, bytes, supplied, opts) do
    case master_key_verify(token, purpose, bytes, supplied, opts) do
      :ok -> :ok
      {:error, :master_key_access_unavailable} -> {:error, :record_authentication_unavailable}
      {:error, _reason} -> {:error, :record_authentication_failed}
    end
  end

  defp master_key_authenticate(token, purpose, bytes, opts) do
    case Keyword.get(opts, :security_supervisor_pid) do
      supervisor when is_pid(supervisor) ->
        Arbor.Security.MasterKeyAccessOwner.authenticate_from_supervisor(
          supervisor,
          token,
          purpose,
          bytes
        )

      _other ->
        Arbor.Security.MasterKeyAccessOwner.authenticate(token, purpose, bytes)
    end
  end

  defp master_key_verify(token, purpose, bytes, supplied, opts) do
    case Keyword.get(opts, :security_supervisor_pid) do
      supervisor when is_pid(supervisor) ->
        Arbor.Security.MasterKeyAccessOwner.verify_from_supervisor(
          supervisor,
          token,
          purpose,
          bytes,
          supplied
        )

      _other ->
        Arbor.Security.MasterKeyAccessOwner.verify(token, purpose, bytes, supplied)
    end
  end

  if @test_env do
    # Backend modules are called synchronously by fixture stores in tests. This
    # compatibility path never exists in production and rejects direct public
    # RecordAuthenticator calls, even when a caller supplies the fixture key.
    defp test_backend_authenticate(bytes, opts) do
      with true <- fixture_backend_call?(),
           {:ok, key} <- test_key(opts) do
        {:ok, :crypto.mac(:hmac, :sha256, key, bytes)}
      else
        _ -> {:error, :record_authentication_unavailable}
      end
    end

    defp test_backend_verify(bytes, supplied, opts) do
      with true <- fixture_backend_call?(),
           {:ok, key} <- test_key(opts),
           expected = :crypto.mac(:hmac, :sha256, key, bytes),
           true <- :crypto.hash_equals(supplied, expected) do
        :ok
      else
        {:error, _reason} = error -> error
        _ -> {:error, :record_authentication_failed}
      end
    end

    defp fixture_backend_call? do
      case Process.info(self(), :current_stacktrace) do
        {:current_stacktrace, stacktrace} ->
          Enum.any?(stacktrace, fn
            {Arbor.Security.Store.JSONFile, _function, _arity, _location} -> true
            {Arbor.Security.Store.RevocationLedger, _function, _arity, _location} -> true
            _frame -> false
          end)

        _ ->
          false
      end
    end

    defp test_key(opts) do
      case Keyword.get(opts, :record_auth_key) do
        key when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
        nil -> {:ok, :crypto.hash(:sha256, "arbor-security-json-file-test-auth-key")}
        _ -> {:error, :record_authentication_unavailable}
      end
    end
  else
    defp test_backend_authenticate(_bytes, _opts),
      do: {:error, :record_authentication_unavailable}

    defp test_backend_verify(_bytes, _supplied, _opts),
      do: {:error, :record_authentication_unavailable}
  end
end
