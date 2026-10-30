defmodule Arbor.Security.Identity.Verifier do
  @moduledoc """
  Verification pipeline for signed requests.

  Verifies authenticity by checking (in order of cost):
  1. Cluster replay protection (deny when peers are present without
     authenticated security-sync transport)
  2. Timestamp freshness (cheapest — pure computation)
  3. Public key lookup from Registry (GenServer call)
  4. Ed25519 signature verification (crypto operation)
  5. Nonce uniqueness via NonceCache (GenServer call)
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
  def verify(request), do: do_verify(request, true)

  @doc """
  Verify a proof that was minted by THIS node and never transmitted.

  Identical to `verify/1` — timestamp freshness, key lookup, signature, and
  single-use nonce all still apply — except that it does not consult the
  cluster replay gate.

  That gate exists because a `SignedRequest` captured *in transit* could be
  replayed against a peer whose nonce cache has not seen it. A local
  possession proof never crosses the network: it is built in-process by
  `build_signing_authority_acquisition_proof/3` and bound to a `purpose` and
  an `owner` pid on this node, so no peer could act on a copy of it.

  Applying the inbound gate here deadlocked startup. `Scheduler.Identity`
  opens its signing authority during `init/1`, and while any peer was
  connected — including the ephemeral `mix` node that `mix arbor.start` uses
  to observe readiness — the gate refused, `arbor_scheduler` failed to start,
  and the whole boot cascaded down with
  `{:signing_authority_open_failed, :cluster_replay_protection_unavailable}`.
  Found 2026-08-19 on a fresh Debian 13 box.
  """
  @spec verify_local_possession_proof(term()) :: {:ok, String.t()} | {:error, atom()}
  def verify_local_possession_proof(request), do: do_verify(request, false)

  defp do_verify(request, gate_cluster_replay?) do
    with :ok <- maybe_admit_cluster_replay(gate_cluster_replay?),
         {:ok, request} <- canonicalize_request(request),
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

  defp maybe_admit_cluster_replay(true),
    do: Config.admit_cluster_signed_request_replay_protection()

  defp maybe_admit_cluster_replay(false), do: :ok

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
