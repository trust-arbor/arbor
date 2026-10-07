defmodule Arbor.Security.SessionRegistry do
  @moduledoc false

  use GenServer

  alias Arbor.Security.SupervisedOwner

  @max_sessions 16_384
  @owner_table :arbor_security_session_registry_owner
  @mutation_denied {:error, :session_mutation_unauthorized}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # Session mutation is intentionally not an ambient registry API. Keeping the
  # retired shape fail-closed prevents a bearer holder from decoding a revoked
  # token and re-inserting its session id.
  @doc false
  @spec issue(String.t(), String.t(), integer()) ::
          {:error, :session_mutation_unauthorized | :invalid_session}
  def issue(session_id, principal_id, expires_at)
      when is_binary(session_id) and is_binary(principal_id) and is_integer(expires_at),
      do: @mutation_denied

  def issue(_, _, _), do: {:error, :invalid_session}

  @doc false
  def issue_human(session_id, principal_id, expires_at, authority)
      when is_binary(session_id) and is_binary(principal_id) and is_integer(expires_at) do
    authenticated_call({:issue_human, session_id, principal_id, expires_at, authority})
  end

  def issue_human(_, _, _, _), do: {:error, :invalid_session}

  @doc false
  def issue_conversation(session_id, principal_id, target, expires_at, receipt)
      when is_binary(session_id) and is_binary(principal_id) and is_binary(target) and
             is_integer(expires_at) do
    authenticated_call(
      {:issue_conversation, session_id, principal_id, target, expires_at, receipt}
    )
  end

  def issue_conversation(_, _, _, _, _), do: {:error, :invalid_session}

  @doc false
  def issue_terminal_conversation(session_id, principal_id, target, expires_at)
      when is_binary(session_id) and is_binary(principal_id) and is_binary(target) and
             is_integer(expires_at) do
    authenticated_call(
      {:issue_terminal_conversation, session_id, principal_id, target, expires_at}
    )
  end

  def issue_terminal_conversation(_, _, _, _), do: {:error, :invalid_session}

  if Mix.env() == :test do
    @doc false
    def issue_fixture(session_id, principal_id, expires_at)
        when is_binary(session_id) and is_binary(principal_id) and is_integer(expires_at) do
      authenticated_call({:issue_fixture, session_id, principal_id, expires_at})
    end

    def issue_fixture(_, _, _), do: {:error, :invalid_session}
  end

  @spec active?(String.t(), String.t()) :: boolean()
  def active?(session_id, principal_id)
      when is_binary(session_id) and is_binary(principal_id) do
    safe_call({:active?, session_id, principal_id}) == true
  end

  def active?(_, _), do: false

  @doc false
  @spec revoke(String.t()) :: {:error, :session_mutation_unauthorized | :invalid_session}
  def revoke(session_id) when is_binary(session_id), do: @mutation_denied
  def revoke(_), do: {:error, :invalid_session}

  @doc false
  def revoke_token(token) when is_binary(token), do: authenticated_call({:revoke_token, token})
  def revoke_token(_), do: {:error, :invalid_token}

  if Mix.env() == :test do
    @doc false
    def revoke_fixture(session_id) when is_binary(session_id),
      do: authenticated_call({:revoke_fixture, session_id})

    def revoke_fixture(_), do: {:error, :invalid_session}
  end

  @doc false
  def owner_process?, do: owner_pid() == self()

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)

    table = :ets.new(@owner_table, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(table, {:owner_pid, self()})

    {:ok,
     %{
       sessions: %{},
       authenticated_calls: Arbor.Common.new_authenticated_call_custody(),
       owner_table: table
     }}
  end

  @impl true
  def handle_call({:active?, session_id, principal_id}, _from, state) do
    now = System.system_time(:second)
    sessions = prune(state.sessions, now)

    active? =
      match?(
        %{principal_id: ^principal_id, expires_at: expires_at} when expires_at > now,
        Map.get(sessions, session_id)
      )

    {:reply, active?, %{state | sessions: sessions}}
  end

  # A raw GenServer call cannot prove who sent it: its `from` PID is ordinary
  # message data. Every mutation shape therefore fails before touching state.
  def handle_call(request, _from, state) do
    reply =
      if mutation_request?(request), do: @mutation_denied, else: {:error, :unsupported_request}

    {:reply, reply, state}
  end

  @impl true
  def handle_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        {reply, state} = handle_authenticated_call(request, caller, state)
        :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
        {:noreply, state}

      result when result in [:pending, :expired, :rejected, :unrecognized] ->
        {:noreply, state}
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    count =
      case get_in(status, [:state, :sessions]) do
        sessions when is_map(sessions) -> map_size(sessions)
        _ -> 0
      end

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, %{active_session_count: count})
    |> redact(:reason)
    |> redact(:log)
  end

  defp handle_authenticated_call(
         {:issue_human, session_id, principal_id, expires_at, authority},
         caller,
         state
       ) do
    with :ok <- Arbor.Security.validate_signing_authority_owner(authority, caller, principal_id) do
      put_session(state, session_id, principal_id, expires_at)
    else
      _ -> {@mutation_denied, state}
    end
  end

  defp handle_authenticated_call(
         {:issue_conversation, session_id, principal_id, target, expires_at, receipt},
         _caller,
         state
       ) do
    resource = "arbor://chat/agent/" <> target

    with true <- conversation_id?(principal_id, "human_"),
         true <- conversation_target?(target),
         {:ok, ^principal_id} <-
           Arbor.Security.consume_delivery_receipt(receipt, resource, :chat) do
      put_session(state, session_id, principal_id, expires_at)
    else
      _ -> {@mutation_denied, state}
    end
  end

  defp handle_authenticated_call(
         {:issue_terminal_conversation, session_id, principal_id, target, expires_at},
         caller,
         state
       ) do
    if exact_terminal_login?(caller) and conversation_id?(principal_id, "human_") and
         conversation_target?(target) do
      put_session(state, session_id, principal_id, expires_at)
    else
      {@mutation_denied, state}
    end
  end

  defp handle_authenticated_call({:revoke_token, token}, _caller, state) do
    case Arbor.Security.SessionToken.registry_revoke_claim(token) do
      {:ok, session_id} -> {:ok, %{state | sessions: Map.delete(state.sessions, session_id)}}
      _ -> {{:error, :invalid_token}, state}
    end
  end

  if Mix.env() == :test do
    defp handle_authenticated_call(
           {:issue_fixture, session_id, principal_id, expires_at},
           _caller,
           state
         ),
         do: put_session(state, session_id, principal_id, expires_at)

    defp handle_authenticated_call({:revoke_fixture, session_id}, _caller, state),
      do: {:ok, %{state | sessions: Map.delete(state.sessions, session_id)}}
  end

  defp handle_authenticated_call(_request, _caller, state), do: {@mutation_denied, state}

  defp put_session(state, session_id, principal_id, expires_at) do
    now = System.system_time(:second)
    sessions = prune(state.sessions, now)

    cond do
      not valid_session_id?(session_id) or not valid_principal?(principal_id) ->
        {{:error, :invalid_session}, %{state | sessions: sessions}}

      Map.has_key?(sessions, session_id) ->
        {{:error, :session_id_collision}, %{state | sessions: sessions}}

      map_size(sessions) >= @max_sessions ->
        {{:error, :session_registry_full}, %{state | sessions: sessions}}

      true ->
        entry = %{principal_id: principal_id, expires_at: expires_at}
        {:ok, %{state | sessions: Map.put(sessions, session_id, entry)}}
    end
  end

  defp mutation_request?({operation, _, _, _}) when operation in [:issue, :issue_fixture],
    do: true

  defp mutation_request?({:issue_human, _, _, _, _}), do: true
  defp mutation_request?({:issue_conversation, _, _, _, _, _}), do: true
  defp mutation_request?({:issue_terminal_conversation, _, _, _, _}), do: true

  defp mutation_request?({operation, _})
       when operation in [:revoke, :revoke_token, :revoke_fixture], do: true

  defp mutation_request?(_request), do: false

  defp exact_terminal_login?(caller) do
    Process.whereis(Arbor.Security.TerminalLogin) == caller and
      SupervisedOwner.authorized?(caller, :arbor_security, [Arbor.Security.TerminalLogin])
  end

  defp authenticated_call(message) do
    case owner_pid() do
      pid when is_pid(pid) -> Arbor.Common.authenticated_call(pid, message)
      _ -> {:error, :session_registry_unavailable}
    end
  catch
    :exit, _ -> {:error, :session_registry_unavailable}
  end

  defp safe_call(message) do
    case owner_pid() do
      pid when is_pid(pid) -> GenServer.call(pid, message)
      _ -> {:error, :session_registry_unavailable}
    end
  catch
    :exit, _ -> {:error, :session_registry_unavailable}
  end

  defp owner_pid do
    SupervisedOwner.protected_directory_owner(
      @owner_table,
      :owner_pid,
      :arbor_security,
      [__MODULE__]
    )
  end

  defp prune(sessions, now) do
    Map.reject(sessions, fn {_id, %{expires_at: expiry}} -> expiry <= now end)
  end

  defp valid_session_id?(id) do
    byte_size(id) == 32 and String.valid?(id) and Regex.match?(~r/\A[0-9a-f]{32}\z/, id)
  end

  defp valid_principal?(principal),
    do: is_binary(principal) and byte_size(principal) in 1..256 and String.valid?(principal)

  defp conversation_target?(target),
    do: conversation_id?(target, "agent_") or conversation_id?(target, "human_")

  defp conversation_id?(id, prefix) when is_binary(id) and byte_size(id) in 1..256,
    do:
      String.valid?(id) and String.starts_with?(id, prefix) and
        Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id) and byte_size(id) > byte_size(prefix)

  defp conversation_id?(_, _), do: false

  defp redact(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end
end
