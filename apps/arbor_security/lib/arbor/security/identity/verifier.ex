defmodule Arbor.Security.Identity.Verifier do
  @moduledoc """
  Verification pipeline for signed requests.

  Verifies authenticity by checking (in order of cost):
  1. Timestamp freshness (cheapest — pure computation)
  2. Public key lookup from Registry (GenServer call)
  3. Ed25519 signature verification (crypto operation)
  4. Nonce uniqueness via NonceCache (GenServer call)
  """

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security.Config
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.NonceCache
  alias Arbor.Security.Identity.Registry

  @doc """
  Verify a signed request's authenticity.

  Returns `{:ok, agent_id}` on success, or `{:error, reason}` with a specific
  verification error.
  """
  @spec verify(term()) :: {:ok, String.t()} | {:error, atom()}
  def verify(request) do
    with {:ok, request} <- canonicalize_request(request),
         :ok <- check_timestamp_freshness(request),
         {:ok, public_key} <- lookup_agent_key(request.agent_id),
         :ok <- verify_signature(request, public_key),
         :ok <- check_nonce_uniqueness(request.nonce) do
      {:ok, request.agent_id}
    end
  rescue
    _ -> {:error, :verification_failed}
  catch
    :exit, _ -> {:error, :verification_unavailable}
  end

  defp canonicalize_request(request) do
    case SignedRequest.canonicalize(request) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _reason} -> {:error, :malformed_request}
    end
  end

  # Step 1: Timestamp freshness (cheapest check)
  defp check_timestamp_freshness(%SignedRequest{timestamp: timestamp}) do
    max_drift = Config.timestamp_max_drift_seconds()
    now = DateTime.utc_now()
    diff_seconds = abs(DateTime.diff(now, timestamp, :second))

    if diff_seconds <= max_drift do
      :ok
    else
      {:error, :expired_timestamp}
    end
  end

  # Step 2: Look up public key from registry
  defp lookup_agent_key(agent_id) do
    case Registry.lookup(agent_id) do
      {:ok, public_key} when is_binary(public_key) and byte_size(public_key) == 32 ->
        {:ok, public_key}

      {:ok, _malformed_public_key} ->
        {:error, :invalid_public_key}

      {:error, :not_found} ->
        {:error, :unknown_agent}

      {:error, :identity_suspended} ->
        {:error, :identity_suspended}

      {:error, :identity_revoked} ->
        {:error, :identity_revoked}

      {:error, _reason} ->
        {:error, :verification_unavailable}
    end
  catch
    :exit, _ -> {:error, :verification_unavailable}
  end

  # Step 3: Verify Ed25519 signature
  defp verify_signature(%SignedRequest{} = request, public_key) do
    message = SignedRequest.signing_payload(request)

    case Crypto.verify(message, request.signature, public_key) do
      true -> :ok
      false -> {:error, :invalid_signature}
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  catch
    :exit, _ -> {:error, :invalid_signature}
  end

  # Step 4: Nonce uniqueness
  defp check_nonce_uniqueness(nonce) do
    ttl = Config.nonce_ttl_seconds()
    NonceCache.check_and_record(nonce, ttl)
  catch
    :exit, _ -> {:error, :verification_unavailable}
  end
end
