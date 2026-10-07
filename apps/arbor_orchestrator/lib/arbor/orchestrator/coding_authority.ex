defmodule Arbor.Orchestrator.CodingAuthority do
  @moduledoc false

  alias Arbor.Contracts.Security.{SigningAuthority, SigningAuthorityBootstrap}
  alias Arbor.Orchestrator.Config

  @spec acquire(module(), String.t(), atom()) ::
          {:ok, SigningAuthority.t(), SigningAuthorityBootstrap.t()} | {:error, term()}
  def acquire(security, principal_id, purpose)
      when is_atom(security) and is_binary(principal_id) and is_atom(purpose) do
    with {:ok, provider} <- authority_provider(),
         {:ok, bootstrap} <- provider.issue_signing_authority_bootstrap(principal_id, purpose),
         {:ok, canonical_bootstrap} <- SigningAuthorityBootstrap.canonicalize(bootstrap) do
      claim(security, principal_id, purpose, canonical_bootstrap)
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_authority_bootstrap_result, other}}
    end
  rescue
    exception -> {:error, {:authority_acquisition_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:authority_acquisition_exit, {kind, reason}}}
  end

  def acquire(_security, _principal_id, _purpose), do: {:error, :invalid_authority_request}

  @spec transfer(String.t(), atom(), pid(), map()) :: :ok | {:error, term()}
  def transfer(principal_id, purpose, claimant, context)
      when is_binary(principal_id) and is_atom(purpose) and is_pid(claimant) and
             is_map(context) do
    with {:ok, provider} <- authority_provider(),
         true <- function_exported?(provider, :transfer_signing_authority_handoff, 4) do
      provider.transfer_signing_authority_handoff(principal_id, purpose, claimant, context)
    else
      false -> {:error, :authority_handoff_transfer_unavailable}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :authority_handoff_transfer_unavailable}
  catch
    _, _ -> {:error, :authority_handoff_transfer_unavailable}
  end

  def transfer(_principal_id, _purpose, _claimant, _context),
    do: {:error, :invalid_authority_handoff_transfer}

  @spec close(module(), term(), term()) :: :ok | {:error, term()}
  def close(security, authority, bootstrap) when is_atom(security) do
    authority_result = safe_close(fn -> security.close_signing_authority(authority) end)
    bootstrap_result = safe_close(fn -> security.close_signing_authority_bootstrap(bootstrap) end)

    case {authority_result, bootstrap_result} do
      {:ok, :ok} ->
        :ok

      {{:error, reason}, :ok} ->
        {:error, reason}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {{:error, authority_reason}, {:error, bootstrap_reason}} ->
        {:error, {:authority_and_bootstrap_close_failed, authority_reason, bootstrap_reason}}
    end
  end

  def close(_security, _authority, _bootstrap), do: {:error, :security_unavailable}

  defp claim(security, principal_id, purpose, bootstrap) do
    case security.claim_signing_authority(bootstrap) do
      {:ok, opened} ->
        case SigningAuthority.canonicalize(opened) do
          {:ok, %SigningAuthority{principal_id: ^principal_id, purpose: ^purpose} = authority} ->
            {:ok, authority, bootstrap}

          {:ok, %SigningAuthority{}} ->
            _ = close(security, opened, bootstrap)
            {:error, :authority_binding_mismatch}

          {:error, reason} ->
            _ = close(security, opened, bootstrap)
            {:error, reason}
        end

      {:error, reason} ->
        _ = close_bootstrap(security, bootstrap)
        {:error, reason}

      other ->
        _ = close_bootstrap(security, bootstrap)
        {:error, {:unexpected_authority_claim_result, other}}
    end
  end

  defp authority_provider do
    provider = Config.coding_authority_provider()

    if is_atom(provider) and Code.ensure_loaded?(provider) and
         function_exported?(provider, :issue_signing_authority_bootstrap, 2) do
      {:ok, provider}
    else
      {:error, :authority_provider_unavailable}
    end
  end

  defp close_bootstrap(security, bootstrap) do
    safe_close(fn -> security.close_signing_authority_bootstrap(bootstrap) end)
  end

  defp safe_close(fun) do
    normalize_close(fun.())
  rescue
    exception -> {:error, {:close_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:close_exit, {kind, reason}}}
  end

  defp normalize_close(:ok), do: :ok
  defp normalize_close({:error, reason}), do: {:error, reason}
  defp normalize_close(other), do: {:error, {:unexpected_close_result, other}}
end
