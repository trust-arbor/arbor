defmodule Arbor.Common.Extension.ProtectedRegistry do
  @moduledoc """
  Owner-only E1A registry for closed provider handles.

  This is a new seam beside `RegistryBase`. It does not register module
  atoms, expose public ETS, or offer production reset/restore. Mutation
  requires the start-bound owner token. Remote lookup fails closed.
  Production commit stays disabled until a later packet supplies a
  boot-profile Platform signing identity.
  """

  use GenServer

  alias Arbor.Common.Extension.Activation
  alias Arbor.Common.Extension.RegistryCore
  alias Arbor.Common.ExtensionEnvelopes

  @doc "Start a registry bound to one owner token."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc "Stage a transaction and handle. Invisible until commit."
  @spec stage(GenServer.server(), reference(), map(), map(), keyword()) ::
          :ok | {:error, String.t()}
  def stage(server, token, transaction, handle, opts \\ []) do
    GenServer.call(server, {:stage, token, transaction, handle, opts})
  end

  @doc "Authorize the in-flight staged transaction."
  @spec authorize(GenServer.server(), reference(), term(), keyword()) ::
          :ok | {:error, String.t()}
  def authorize(server, token, document, opts \\ []) do
    GenServer.call(server, {:authorize, token, document, opts})
  end

  @doc "Publish the authorized handle when commit is allowed."
  @spec commit(GenServer.server(), reference(), keyword()) :: :ok | {:error, String.t()}
  def commit(server, token, opts \\ []) do
    GenServer.call(server, {:commit, token, opts})
  end

  @doc "Drop the in-flight staged transaction."
  @spec rollback(GenServer.server(), reference()) :: :ok | {:error, String.t()}
  def rollback(server, token) do
    GenServer.call(server, {:rollback, token})
  end

  @doc "Resolve a published handle. Remote nodes are unauthorized."
  @spec resolve(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def resolve(server, name, opts \\ []) do
    GenServer.call(server, {:resolve, name, opts})
  end

  @doc "List live published entries."
  @spec list(GenServer.server(), keyword()) :: [map()]
  def list(server, opts \\ []) do
    GenServer.call(server, {:list, opts})
  end

  @doc "Mark a name as core before lock."
  @spec mark_core(GenServer.server(), reference(), String.t()) :: :ok | {:error, String.t()}
  def mark_core(server, token, name) do
    GenServer.call(server, {:mark_core, token, name})
  end

  @doc "Lock core names against later overwrite."
  @spec lock_core(GenServer.server(), reference()) :: :ok | {:error, String.t()}
  def lock_core(server, token) do
    GenServer.call(server, {:lock_core, token})
  end

  @impl true
  def init(opts) do
    token = Keyword.get(opts, :owner_token)
    owner = Keyword.get(opts, :owner, self())
    owner_id = Keyword.get(opts, :owner_id, "owner.local")

    cond do
      not is_reference(token) ->
        {:stop, :owner_token_required}

      not is_pid(owner) ->
        {:stop, :owner_required}

      not is_binary(owner_id) ->
        {:stop, :invalid_owner_id}

      true ->
        {:ok,
         %{
           token: token,
           owner: owner,
           owner_id: owner_id,
           owner_mon: Process.monitor(owner),
           core: RegistryCore.new(),
           activation: Activation.new(),
           allow_commit?: Keyword.get(opts, :allow_commit, false) == true,
           public_key: Keyword.get(opts, :public_key),
           boot_profile_digest: Keyword.get(opts, :boot_profile_digest, ""),
           boot_epoch: Keyword.get(opts, :boot_epoch, 1)
         }}
    end
  end

  @impl true
  def handle_call({:stage, token, transaction, handle, opts}, _from, state) do
    with :ok <- owner_token(state, token),
         {:ok, handle} <- ExtensionEnvelopes.validate(:provider_handle, handle),
         {:ok, activation} <- Activation.stage(Activation.new(), transaction, opts),
         {:ok, core} <-
           RegistryCore.stage(
             state.core,
             activation.transaction,
             handle,
             state.owner_id,
             now(opts)
           ) do
      {:reply, :ok, %{state | core: core, activation: activation}}
    else
      {:error, reason} -> {:reply, {:error, public_error(reason)}, state}
    end
  end

  def handle_call({:authorize, token, document, opts}, _from, state) do
    with :ok <- owner_token(state, token),
         {:ok, activation, effects} <-
           Activation.authorize(state.activation, document, authorize_opts(state, opts)) do
      core = apply_effects(state.core, effects)
      {:reply, :ok, %{state | core: core, activation: activation}}
    else
      {:error, reason} -> {:reply, {:error, public_error(reason)}, state}
    end
  end

  def handle_call({:commit, token, opts}, _from, state) do
    with :ok <- owner_token(state, token),
         {:ok, activation} <-
           Activation.commit(state.activation, commit_opts(state, opts)),
         {:ok, core} <- RegistryCore.publish(state.core, activation.receipt, now(opts)) do
      {:reply, :ok, %{state | core: core, activation: Activation.new()}}
    else
      {:error, reason} -> {:reply, {:error, public_error(reason)}, state}
    end
  end

  def handle_call({:rollback, token}, _from, state) do
    with :ok <- owner_token(state, token),
         {:ok, _activation} <- Activation.rollback(state.activation),
         {:ok, core} <- RegistryCore.rollback(state.core) do
      {:reply, :ok, %{state | core: core, activation: Activation.new()}}
    else
      {:error, reason} -> {:reply, {:error, public_error(reason)}, state}
    end
  end

  def handle_call({:resolve, name, opts}, _from, state) do
    if Keyword.get(opts, :node, :local) != :local do
      {:reply, {:error, "unauthorized"}, state}
    else
      {:reply, RegistryCore.resolve(state.core, name, now(opts)), state}
    end
  end

  def handle_call({:list, opts}, _from, state) do
    {:reply, RegistryCore.list_published(state.core, now(opts)), state}
  end

  def handle_call({:mark_core, token, name}, _from, state) do
    with :ok <- owner_token(state, token),
         {:ok, core} <- RegistryCore.mark_core(state.core, name) do
      {:reply, :ok, %{state | core: core}}
    else
      {:error, reason} -> {:reply, {:error, public_error(reason)}, state}
    end
  end

  def handle_call({:lock_core, token}, _from, state) do
    case owner_token(state, token) do
      :ok -> {:reply, :ok, %{state | core: RegistryCore.lock_core(state.core)}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, "malformed"}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_mon: ref} = state) do
    core = RegistryCore.cleanup(state.core, now([]), dead_owner_id: state.owner_id)
    {:noreply, %{state | core: core, activation: Activation.new()}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp owner_token(%{token: token}, token) when is_reference(token), do: :ok
  defp owner_token(_state, _token), do: {:error, "unauthorized"}

  defp authorize_opts(state, opts) do
    [
      public_key: Keyword.get(opts, :public_key, state.public_key),
      now: now(opts),
      consumed_nonces: state.core.consumed_nonces,
      boot_profile_digest: Keyword.get(opts, :boot_profile_digest, state.boot_profile_digest),
      boot_epoch: Keyword.get(opts, :boot_epoch, state.boot_epoch),
      revoked: Keyword.get(opts, :revoked, false)
    ]
  end

  defp commit_opts(state, opts) do
    [now: now(opts), allow_commit: state.allow_commit? or Keyword.get(opts, :allow_commit, false)]
  end

  defp apply_effects(core, effects) do
    Enum.reduce(effects, core, fn
      {:consume_nonce, nonce}, acc -> RegistryCore.consume_nonce(acc, nonce)
      _other, acc -> acc
    end)
  end

  defp public_error(reason) when is_binary(reason), do: reason
  defp public_error(:unauthorized), do: "unauthorized"
  defp public_error(_reason), do: "malformed"

  defp now(opts) do
    case Keyword.get(opts, :now) do
      now when is_binary(now) -> now
      _ -> "1970-01-01T00:00:00Z"
    end
  end
end
