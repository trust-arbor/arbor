defmodule Arbor.Agent.SystemLifecycleAuthority do
  @moduledoc """
  The system lifecycle principal (decision D4,
  `.arbor/decisions/2026-10-08-lifecycle-authority-sources-and-genesis.md`).

  `Lifecycle.start/2` needs an owner-process-bound `:actor_authority`.
  `Arbor.Agent.Bootstrap` and `Arbor.Agent.Reconciler` start agents with no human
  present, so they start through this supervised owner. Modeled on
  `Arbor.Scheduler.Identity`:

    * A stable named identity (`"system_lifecycle"`), loaded from or created in
      the signing-key store and registered through its own narrow path
      (`Arbor.Security.register_system_lifecycle_identity/2`), admitted only
      for this exact supervised process. It needs no
      `arbor://security/identity/register` right.
    * A long-lived signing authority in private custody: a private ETS table in
      a sensitive process, redacted status. It is never exported.
    * Mutations admitted only through `Arbor.Common` authenticated calls from the
      exact supervised `Arbor.Agent.Bootstrap` and `Arbor.Agent.Reconciler`
      processes, carrying the startup token `Arbor.Agent.Application` gives all
      three.

  ## Authority

  It never creates agents, never mints or removes capabilities, and holds no
  global or wildcard rights. Its rights are per agent (suspend and resume only),
  granted by a human: enabling auto_start with
  `Arbor.Agent.Manager.set_auto_start/3` grants it `delegated_resources/1` for
  that agent with the human's authority, and disabling revokes them. Before a
  start it requires the profile's `auto_start` flag *and* all of those
  capabilities. The capabilities are the authority; the flag is only the
  desired state. Start-time activation skips re-registering an identity that is
  already registered with the same key, so it never needs the register right.

  ## Starts are serialized

  The broker binds an authority to the process that opened it, so a start must
  run `Lifecycle.start/2` (via `Manager.resume_agent/2`) inside this process.
  Starts are serialized here: each one can hold the owner for the
  runtime-admission deadline (120 s, at most 180 s). Both callers already wait
  synchronously on their starts, Reconciler starts are rate-limited (3 per agent
  per 10 minutes), and Bootstrap starts its agents one at a time, so
  serialization costs a queued caller at most one start's wait. Serializing also
  keeps one principal's activations from interleaving. The principal id is
  published in a protected table, so `principal_id/0` never waits behind a
  start.
  """

  use GenServer

  require Logger

  alias Arbor.Agent.{Manager, ProfileStore}
  alias Arbor.Contracts.Security.{Identity, SigningAuthority}
  alias Arbor.Security

  @identity_name "system_lifecycle"
  @purpose :system_lifecycle
  @custody_table Arbor.Agent.SystemLifecycleAuthority.Custody
  @custody_tag :arbor_agent_system_lifecycle_custody_v1
  @directory :arbor_agent_system_lifecycle_principal_directory
  @permitted_callers [Arbor.Agent.Bootstrap, Arbor.Agent.Reconciler]
  # Above the runtime-admission maximum deadline (180 s), plus queueing.
  @start_call_timeout_ms 200_000
  @bootstrap_retry_ms 30_000

  # ── Public API ──────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The capability URIs a human delegates to this principal for one agent when
  enabling auto_start: resume (re-activate a suspended exact-policy identity)
  and suspend (fail an activation closed).

  Deliberately no `arbor://security/{grant,revoke}/<agent_id>`: the principal
  never mints or removes an agent's capabilities. An agent whose capabilities
  already match its profile auto-starts. One whose exact-policy capabilities
  drifted fails closed (and is suspended) until a human re-syncs it
  (Hysun, 2026-10-08).
  """
  @spec delegated_resources(String.t()) :: [String.t()]
  def delegated_resources(agent_id) when is_binary(agent_id) do
    [
      "arbor://security/identity/suspend/#{agent_id}",
      "arbor://security/identity/resume/#{agent_id}"
    ]
  end

  @doc """
  The principal id, read from the owner's protected directory. Never waits
  behind a running start.
  """
  @spec principal_id() :: {:ok, String.t()} | {:error, :system_lifecycle_unavailable}
  def principal_id do
    with {:ok, owner} <- owner_pid(),
         true <- :ets.info(@directory, :owner) == owner,
         [{:principal, principal_id}] when is_binary(principal_id) <-
           :ets.lookup(@directory, :principal) do
      {:ok, principal_id}
    else
      _ -> {:error, :system_lifecycle_unavailable}
    end
  rescue
    ArgumentError -> {:error, :system_lifecycle_unavailable}
  end

  @doc false
  @spec await_ready(timeout()) :: :ok | {:error, term()}
  def await_ready(timeout \\ 30_000) do
    case owner_pid() do
      {:ok, owner} -> GenServer.call(owner, :await_ready, timeout)
      {:error, _} = error -> error
    end
  catch
    :exit, _reason -> {:error, :system_lifecycle_unavailable}
  end

  @doc """
  Start an existing, opted-in auto_start agent as this principal.

  Admitted only from the supervised `Arbor.Agent.Bootstrap` or
  `Arbor.Agent.Reconciler` presenting the startup token. Fails closed unless the
  profile has `auto_start: true` and this principal holds every
  `delegated_resources/1` capability for the agent. `opts` are ordinary
  `Manager.resume_agent/2` options and must not carry an `:actor_authority`.
  """
  @spec start_agent(String.t(), keyword(), reference()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start_agent(agent_id, opts, token),
    do: protected_call({:start_agent, agent_id, opts, token}, @start_call_timeout_ms)

  # ── GenServer ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)

    with {:ok, token} <- startup_token(opts),
         :ok <- claim_directory() do
      @custody_table = :ets.new(@custody_table, [:named_table, :set, :private])
      true = :ets.insert(@custody_table, {@custody_tag, :bootstrap, token})

      {:ok,
       %{
         phase: :pending,
         dormant_reason: nil,
         authenticated_calls: Arbor.Common.new_authenticated_call_custody()
       }, {:continue, :bootstrap}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    # SigningKeyStore and the identity Registry admit this process by its exact
    # supervised path, which asks Arbor.Agent.AppSupervisor for its children.
    # Running this in init/1 would deadlock that supervisor; a continuation
    # runs after the child is recorded, and queued calls wait behind it.
    {:noreply, bootstrap(state)}
  end

  @impl true
  def handle_call(:await_ready, _from, %{phase: :ready} = state), do: {:reply, :ok, state}

  def handle_call(:await_ready, _from, state),
    do: {:reply, {:error, {:system_lifecycle_dormant, state.dormant_reason}}, state}

  # A raw `$gen_call` `from` tuple is caller-forgeable message data. Only the
  # readiness observation uses GenServer.call; starts are admitted through
  # AuthenticatedCall and exact supervision provenance.
  def handle_call(_request, _from, state),
    do: {:reply, {:error, :system_lifecycle_unauthorized}, state}

  @impl true
  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info(:retry_bootstrap, %{phase: :dormant} = state),
    do: {:noreply, bootstrap(state)}

  def handle_info(:retry_bootstrap, state), do: {:noreply, state}

  def handle_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        reply = handle_authenticated_call(request, caller)
        :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
        {:noreply, state}

      result when result in [:pending, :expired, :rejected, :unrecognized] ->
        {:noreply, state}
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, %{identity: :private_custody})
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, :redacted)
  end

  @impl true
  def terminate(_reason, _state) do
    case read_ready_custody() do
      {:ok, %{authority: authority}} -> _ = Security.close_signing_authority(authority)
      _ -> :ok
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # ── Authenticated starts ────────────────────────────────────────────

  defp handle_authenticated_call({:start_agent, agent_id, opts, token}, caller) do
    with {:ok, custody} <- authorize_caller(token, caller),
         :ok <- validate_start_request(agent_id, opts),
         :ok <- require_opted_in(agent_id, custody.principal_id) do
      run_start(agent_id, opts, custody.authority)
    end
  end

  defp handle_authenticated_call(_request, _caller),
    do: {:error, :system_lifecycle_unauthorized}

  defp authorize_caller(token, caller) when is_reference(token) and is_pid(caller) do
    with {:ok, %{token: ^token} = custody} <- read_ready_custody(),
         true <- permitted_caller?(caller) do
      {:ok, custody}
    else
      _ -> {:error, :system_lifecycle_unauthorized}
    end
  end

  defp authorize_caller(_token, _caller), do: {:error, :system_lifecycle_unauthorized}

  defp permitted_caller?(caller) do
    Enum.any?(@permitted_callers, fn name ->
      Arbor.Common.supervised_registered_child_pid(:arbor_agent, [name], name) == {:ok, caller}
    end)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp validate_start_request(agent_id, opts) do
    if is_binary(agent_id) and agent_id != "" and is_list(opts) and Keyword.keyword?(opts) and
         not Keyword.has_key?(opts, :actor_authority),
       do: :ok,
       else: {:error, :invalid_start_request}
  end

  # The flag is the desired state; the human-granted capabilities are the
  # authority. Both must be present.
  defp require_opted_in(agent_id, principal_id) do
    with {:ok, %{auto_start: true}} <- ProfileStore.load_profile(agent_id),
         :ok <- require_delegation(agent_id, principal_id) do
      :ok
    else
      {:ok, _profile} -> {:error, :auto_start_not_enabled}
      {:error, :auto_start_not_delegated} = error -> error
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :auto_start_not_delegated}
    end
  end

  defp require_delegation(agent_id, principal_id) do
    case Security.list_capabilities(principal_id) do
      {:ok, capabilities} ->
        if Enum.all?(delegated_resources(agent_id), &holds?(capabilities, &1)),
          do: :ok,
          else: {:error, :auto_start_not_delegated}

      _ ->
        {:error, :auto_start_not_delegated}
    end
  end

  defp holds?(capabilities, resource) do
    Enum.any?(capabilities, fn capability ->
      capability.resource_uri == resource and
        Security.capability_authorizes?(capability, resource)
    end)
  end

  defp run_start(agent_id, opts, authority) do
    Manager.resume_agent(agent_id, Keyword.put(opts, :actor_authority, authority))
  rescue
    exception ->
      Logger.warning(
        "[SystemLifecycleAuthority] start raised for #{agent_id}: #{Exception.message(exception)}"
      )

      {:error, :system_lifecycle_start_failed}
  catch
    :exit, reason ->
      Logger.warning(
        "[SystemLifecycleAuthority] start exited for #{agent_id}: #{inspect(reason)}"
      )

      {:error, :system_lifecycle_start_failed}
  end

  # ── Identity bootstrap ──────────────────────────────────────────────

  defp bootstrap(state) do
    with {:ok, token} <- read_bootstrap_token(),
         {:ok, identity} <- load_or_create_identity(),
         {:ok, authority} <- open_authority(identity.agent_id),
         :ok <- put_ready_custody(authority, identity.agent_id, token) do
      true = :ets.insert(@directory, {:principal, identity.agent_id})
      Logger.info("[SystemLifecycleAuthority] ready as #{identity.agent_id}")
      %{state | phase: :ready, dormant_reason: nil}
    else
      {:error, reason} ->
        Logger.warning("[SystemLifecycleAuthority] dormant: #{inspect(reason)}")
        Process.send_after(self(), :retry_bootstrap, @bootstrap_retry_ms)
        %{state | phase: :dormant, dormant_reason: reason}
    end
  rescue
    exception ->
      reason = {:bootstrap_exception, Exception.message(exception)}
      Logger.warning("[SystemLifecycleAuthority] dormant: #{inspect(reason)}")
      Process.send_after(self(), :retry_bootstrap, @bootstrap_retry_ms)
      %{state | phase: :dormant, dormant_reason: reason}
  catch
    :exit, reason ->
      Logger.warning("[SystemLifecycleAuthority] dormant: #{inspect({:bootstrap_exit, reason})}")
      Process.send_after(self(), :retry_bootstrap, @bootstrap_retry_ms)
      %{state | phase: :dormant, dormant_reason: {:bootstrap_exit, reason}}
  end

  defp load_or_create_identity do
    case Security.lookup_identity_ids_by_display_name(@identity_name) do
      {:ok, agent_ids} when is_list(agent_ids) ->
        case find_named_identity(agent_ids) do
          {:ok, identity} -> {:ok, identity}
          # Another identity can carry the display name (an agent created with
          # it); without a usable stored key it is not ours. Start fresh rather
          # than stay dormant: a fresh principal holds nothing.
          :not_found -> create_identity()
        end

      {:error, :not_found} ->
        create_identity()

      {:error, reason} ->
        {:error, {:identity_lookup_failed, reason}}

      _other ->
        {:error, :identity_lookup_failed}
    end
  end

  # Public-key reads only: the key store does not bind this owner's principal
  # until a key-material operation, so scanning candidates is safe.
  defp find_named_identity(agent_ids) do
    Enum.find_value(agent_ids, :not_found, fn agent_id ->
      with {:ok, %Identity{agent_id: ^agent_id} = identity} <-
             Security.signing_key_public_identity(agent_id, name: @identity_name),
           {:ok, public_key} <- Security.lookup_public_key(agent_id),
           true <- public_key == identity.public_key do
        {:ok, Identity.public_only(identity)}
      else
        _ -> nil
      end
    end)
  end

  defp create_identity do
    with {:ok, %Identity{} = identity} <- Security.generate_identity(name: @identity_name),
         :ok <- ensure_fresh_principal(identity),
         :ok <- Security.store_signing_key(identity.agent_id, identity.private_key) do
      case register_identity(identity) do
        :ok ->
          {:ok, Identity.public_only(identity)}

        {:error, reason} ->
          _ = Security.delete_signing_key(identity.agent_id)
          {:error, {:identity_registration_failed, reason}}
      end
    else
      {:error, reason} -> {:error, {:identity_creation_failed, reason}}
      _other -> {:error, :identity_creation_failed}
    end
  end

  defp ensure_fresh_principal(identity) do
    with {:error, :no_signing_key} <- Security.signing_key_status(identity.agent_id),
         {:error, :not_found} <- Security.lookup_public_key(identity.agent_id) do
      :ok
    else
      {:ok, _} -> {:error, :fresh_principal_collision}
      {:error, reason} -> {:error, {:fresh_principal_preflight_failed, reason}}
    end
  end

  defp register_identity(identity) do
    with {:ok, proof} <- Security.build_stored_identity_registration_proof(identity) do
      Security.register_system_lifecycle_identity(identity, proof)
    end
  end

  defp open_authority(principal_id) do
    with {:ok, proof} <-
           Security.build_stored_signing_authority_acquisition_proof(
             principal_id,
             @purpose,
             self(),
             __MODULE__
           ),
         {:ok, %SigningAuthority{} = authority} <- Security.open_signing_authority(proof) do
      {:ok, authority}
    else
      {:error, reason} -> {:error, {:signing_authority_open_failed, reason}}
      _other -> {:error, :signing_authority_open_failed}
    end
  end

  # ── Private custody ─────────────────────────────────────────────────

  defp startup_token(opts) when is_list(opts) do
    case Keyword.get(opts, :system_lifecycle_token) do
      token when is_reference(token) -> {:ok, token}
      _ -> {:error, :system_lifecycle_token_required}
    end
  end

  defp startup_token(_opts), do: {:error, :system_lifecycle_token_required}

  defp claim_directory do
    _ = :ets.new(@directory, [:named_table, :protected, :set, read_concurrency: true])
    :ok
  rescue
    ArgumentError -> {:error, :system_lifecycle_directory_unavailable}
  end

  defp put_ready_custody(%SigningAuthority{} = authority, principal_id, token)
       when is_binary(principal_id) and is_reference(token) do
    if valid_custody_owner?() do
      true =
        :ets.insert(@custody_table, {@custody_tag, :ready, authority, principal_id, token})

      :ok
    else
      {:error, :system_lifecycle_custody_invalid}
    end
  rescue
    ArgumentError -> {:error, :system_lifecycle_custody_invalid}
  end

  defp put_ready_custody(_authority, _principal_id, _token),
    do: {:error, :system_lifecycle_custody_invalid}

  defp read_bootstrap_token do
    case read_custody() do
      {:ok, {@custody_tag, :bootstrap, token}} when is_reference(token) -> {:ok, token}
      _ -> {:error, :system_lifecycle_custody_invalid}
    end
  end

  defp read_ready_custody do
    case read_custody() do
      {:ok, {@custody_tag, :ready, %SigningAuthority{} = authority, principal_id, token}}
      when is_binary(principal_id) and is_reference(token) ->
        {:ok, %{authority: authority, principal_id: principal_id, token: token}}

      _ ->
        {:error, :system_lifecycle_custody_invalid}
    end
  end

  defp read_custody do
    if valid_custody_owner?() and :ets.info(@custody_table, :size) == 1 do
      case :ets.lookup(@custody_table, @custody_tag) do
        [entry] -> {:ok, entry}
        _ -> {:error, :system_lifecycle_custody_invalid}
      end
    else
      {:error, :system_lifecycle_custody_invalid}
    end
  rescue
    ArgumentError -> {:error, :system_lifecycle_custody_invalid}
  end

  defp valid_custody_owner? do
    :ets.info(@custody_table, :owner) == self() and
      :ets.info(@custody_table, :protection) == :private and
      :ets.info(@custody_table, :type) == :set and
      :ets.info(@custody_table, :named_table) == true
  rescue
    ArgumentError -> false
  end

  # ── Owner resolution ────────────────────────────────────────────────

  defp owner_pid do
    case Arbor.Common.supervised_registered_child_pid(:arbor_agent, [__MODULE__], __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      _ -> {:error, :system_lifecycle_unavailable}
    end
  rescue
    _ -> {:error, :system_lifecycle_unavailable}
  catch
    :exit, _ -> {:error, :system_lifecycle_unavailable}
  end

  defp protected_call(request, timeout) do
    with {:ok, owner} <- owner_pid() do
      Arbor.Common.authenticated_call(owner, request, timeout)
    end
  rescue
    _ -> {:error, :system_lifecycle_unavailable}
  catch
    :exit, _ -> {:error, :system_lifecycle_unavailable}
  end
end
