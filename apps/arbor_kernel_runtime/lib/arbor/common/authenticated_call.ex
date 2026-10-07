defmodule Arbor.Common.AuthenticatedCall do
  @moduledoc """
  Authenticates same-node calls whose effects depend on the caller process.

  A `GenServer.call/3` request carries `{caller_pid, reply_tag}` as ordinary
  message data. A process that sends a raw `:"$gen_call"` can therefore claim
  another process's PID. This module replaces that wire shape with a
  challenge-response exchange with caller-owned private custody:

  * the client sends a fresh request reference;
  * the server stores a random challenge only in a server-owned private ETS
    table and sends it directly to the claimed caller PID;
  * the caller selectively receives the challenge, writes it into a one-shot
    private ETS table, and gives that table directly to the exact server PID;
  * the VM emits an `ETS-TRANSFER` message that names the real former owner;
    and
  * the server verifies actual table ownership plus the stored challenge and
    unguessable transfer reference before returning the authenticated caller,
    request, and reply target to its GenServer.

  Private ETS is required because a protected table prevents attacker writes
  but still permits every local process to read the challenge. Only the table's
  current owner can call `:ets.give_away/3`, so a forged `ETS-TRANSFER` tuple is
  rejected unless the exact proof table is actually owned by the server. During
  a legitimate call, `call/3` also marks the caller sensitive and restores its
  previous flag afterward so the challenge is not exposed through
  `Process.info/2`.

  A service that authorizes a long-lived exact PID outside this complete
  protocol must mark that principal process sensitive permanently from startup;
  the temporary flag in `call/3` cannot protect messages delivered while no
  legitimate call is active.

  Server state contains only the private table locator. Callers must pass an
  already-authenticated server PID to `call/3`; using a registered name would
  let a name thief intercept the challenge exchange.
  """

  @protocol :"$arbor_authenticated_call"
  @challenge_bytes 32
  @challenge_ttl_ms 5_000
  @max_pending 1_024
  @custody_seal_key {__MODULE__, :sealed_custody}

  @typedoc "Opaque reply target returned only after a challenge is consumed."
  @opaque reply_to :: {reference(), reference()}

  @type handle_result ::
          :pending
          | :expired
          | :rejected
          | :unrecognized
          | {:authenticated, pid(), term(), reply_to()}

  @doc "Creates the private pending-challenge table owned by the calling server."
  @spec new_custody() :: :ets.tid()
  def new_custody do
    case sealed_custody() do
      {:ok, custody} ->
        custody

      :error ->
        custody = :ets.new(__MODULE__, [:set, :private])
        Process.put(@custody_seal_key, custody)
        custody
    end
  end

  @doc "Performs an authenticated call to an exact, already-verified local server PID."
  @spec call(pid(), term(), timeout()) :: term()
  def call(server_pid, request, timeout \\ 5_000)

  def call(server_pid, request, timeout)
      when is_pid(server_pid) and node(server_pid) == node() and
             (timeout == :infinity or (is_integer(timeout) and timeout > 0)) do
    previous_sensitive = Process.flag(:sensitive, true)
    request_ref = make_ref()
    reply_alias = :erlang.alias()
    caller_proof = :ets.new(__MODULE__, [:set, :private])
    monitor_ref = Process.monitor(server_pid)
    deadline = deadline(timeout)

    send(
      server_pid,
      {@protocol, :begin, self(), request_ref, reply_alias, caller_proof, request,
       challenge_ttl(timeout)}
    )

    try do
      case await_challenge(server_pid, request_ref, monitor_ref, deadline) do
        {:challenge, challenge, transfer_ref} ->
          true = :ets.insert(caller_proof, {request_ref, challenge, transfer_ref})

          true =
            :ets.give_away(
              caller_proof,
              server_pid,
              {@protocol, :proof, request_ref, transfer_ref}
            )

          await_reply(server_pid, request_ref, monitor_ref, deadline)

        {:reply, result} ->
          result
      end
    after
      Process.demonitor(monitor_ref, [:flush])
      :erlang.unalias(reply_alias)
      delete_client_proof(caller_proof)
      Process.flag(:sensitive, previous_sensitive)
    end
  end

  def call(server_pid, _request, _timeout) when is_pid(server_pid) do
    exit({:badarg, {__MODULE__, :call, [server_pid]}})
  end

  def call(server, _request, _timeout) do
    exit({:noproc, {__MODULE__, :call, [server]}})
  end

  @doc "Handles one protocol message inside the server's `handle_info/2`."
  @spec handle(term(), :ets.tid()) :: handle_result()
  def handle(message, _state_custody) do
    case sealed_custody() do
      {:ok, custody} -> do_handle(message, custody)
      :error -> :rejected
    end
  end

  defp do_handle(
         {@protocol, :begin, caller_pid, request_ref, reply_alias, caller_proof, request,
          challenge_ttl_ms},
         custody
       ) do
    begin_call(
      custody,
      caller_pid,
      request_ref,
      reply_alias,
      caller_proof,
      request,
      challenge_ttl_ms
    )
  end

  defp do_handle(
         {:"ETS-TRANSFER", caller_proof, caller_pid,
          {@protocol, :proof, request_ref, transfer_ref}},
         custody
       ) do
    finish_call(custody, caller_proof, caller_pid, request_ref, transfer_ref)
  end

  defp do_handle({:"ETS-TRANSFER", _caller_proof, _caller_pid, _gift}, _custody),
    do: :rejected

  defp do_handle({@protocol, :expire, request_ref, expiry_ref}, custody) do
    expire_call(custody, request_ref, expiry_ref)
  end

  defp do_handle(_message, _custody), do: :unrecognized

  @doc "Replies to the authenticated caller returned by `handle/2`."
  @spec reply(reply_to(), term()) :: :ok
  def reply({reply_alias, request_ref}, result)
      when is_reference(reply_alias) and is_reference(request_ref) do
    safe_send(reply_alias, {@protocol, :reply, self(), request_ref, result})
    :ok
  end

  @doc "Clears outstanding challenges while retaining the private table."
  @spec clear(:ets.tid()) :: :ok
  def clear(_state_custody) do
    with {:ok, custody} <- sealed_custody() do
      custody
      |> :ets.tab2list()
      |> Enum.each(fn
        {_request_ref, _caller_pid, caller_proof, _challenge, _transfer_ref, _reply_alias,
         _request, timer_ref, _expiry_ref} ->
          Process.cancel_timer(timer_ref)
          delete_transferred_proof(caller_proof, custody)

        {_request_ref, :expired, _caller_pid, caller_proof, _challenge, _transfer_ref, timer_ref,
         _expiry_ref} ->
          Process.cancel_timer(timer_ref)
          delete_transferred_proof(caller_proof, custody)
      end)

      :ets.delete_all_objects(custody)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp sealed_custody do
    case Process.get(@custody_seal_key) do
      custody when is_reference(custody) ->
        if custody_owned?(custody), do: {:ok, custody}, else: :error

      _other ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp begin_call(
         custody,
         caller_pid,
         request_ref,
         reply_alias,
         caller_proof,
         request,
         challenge_ttl_ms
       ) do
    if valid_begin?(
         custody,
         caller_pid,
         request_ref,
         reply_alias,
         caller_proof,
         challenge_ttl_ms
       ) do
      challenge = :crypto.strong_rand_bytes(@challenge_bytes)
      transfer_ref = make_ref()
      expiry_ref = make_ref()

      timer_ref =
        Process.send_after(
          self(),
          {@protocol, :expire, request_ref, expiry_ref},
          challenge_ttl_ms
        )

      record =
        {request_ref, caller_pid, caller_proof, challenge, transfer_ref, reply_alias, request,
         timer_ref, expiry_ref}

      if :ets.insert_new(custody, record) do
        send(caller_pid, {@protocol, :challenge, self(), request_ref, challenge, transfer_ref})
        :pending
      else
        Process.cancel_timer(timer_ref)
        reject(reply_alias, request_ref)
      end
    else
      reject(reply_alias, request_ref)
    end
  rescue
    ArgumentError -> reject(reply_alias, request_ref)
  end

  defp finish_call(custody, transferred_proof, caller_pid, request_ref, transfer_ref) do
    if custody_owned?(custody) do
      case :ets.lookup(custody, request_ref) do
        [
          {^request_ref, expected_caller, caller_proof, expected_challenge, expected_transfer_ref,
           reply_alias, request, timer_ref, _expiry_ref}
        ]
        when is_pid(expected_caller) ->
          true = :ets.delete(custody, request_ref)
          Process.cancel_timer(timer_ref)

          authenticated? =
            transferred_proof == caller_proof and caller_pid == expected_caller and
              transfer_ref == expected_transfer_ref and
              caller_proof_matches?(
                caller_proof,
                request_ref,
                expected_challenge,
                expected_transfer_ref
              )

          if transferred_proof == caller_proof do
            delete_transferred_proof(caller_proof, custody)
          end

          if authenticated? do
            {:authenticated, caller_pid, request, {reply_alias, request_ref}}
          else
            reject(reply_alias, request_ref)
            :rejected
          end

        [
          {^request_ref, :expired, expected_caller, caller_proof, expected_challenge,
           expected_transfer_ref, timer_ref, _expiry_ref}
        ] ->
          if transferred_proof == caller_proof and caller_pid == expected_caller and
               transfer_ref == expected_transfer_ref and
               caller_proof_matches?(
                 caller_proof,
                 request_ref,
                 expected_challenge,
                 expected_transfer_ref
               ) do
            true = :ets.delete(custody, request_ref)
            Process.cancel_timer(timer_ref)
            delete_transferred_proof(caller_proof, custody)
            :expired
          else
            :rejected
          end

        _missing_or_wrong_owner ->
          :rejected
      end
    else
      :rejected
    end
  rescue
    ArgumentError -> :rejected
  end

  defp expire_call(custody, request_ref, expiry_ref) do
    if custody_owned?(custody) do
      case :ets.lookup(custody, request_ref) do
        [
          {^request_ref, caller_pid, caller_proof, challenge, transfer_ref, reply_alias, _request,
           _timer_ref, ^expiry_ref}
        ]
        when is_pid(caller_pid) ->
          remember_expired_proof(
            custody,
            request_ref,
            caller_pid,
            caller_proof,
            challenge,
            transfer_ref
          )

          reply({reply_alias, request_ref}, {:error, :authenticated_call_timeout})
          :expired

        [
          {^request_ref, :expired, _caller_pid, caller_proof, _challenge, _transfer_ref,
           _timer_ref, ^expiry_ref}
        ] ->
          true = :ets.delete(custody, request_ref)
          delete_transferred_proof(caller_proof, custody)
          :expired

        _missing_or_newer_request ->
          :expired
      end
    else
      :expired
    end
  rescue
    ArgumentError -> :expired
  end

  defp valid_begin?(
         custody,
         caller_pid,
         request_ref,
         reply_alias,
         caller_proof,
         challenge_ttl_ms
       ) do
    custody_owned?(custody) and is_pid(caller_pid) and caller_pid != self() and
      caller_proof != custody and node(caller_pid) == node() and
      Process.alive?(caller_pid) and is_reference(request_ref) and is_reference(reply_alias) and
      valid_caller_proof?(caller_proof, caller_pid, true) and
      is_integer(challenge_ttl_ms) and challenge_ttl_ms > 0 and
      challenge_ttl_ms <= @challenge_ttl_ms and
      :ets.info(custody, :size) < @max_pending
  end

  defp remember_expired_proof(
         custody,
         request_ref,
         caller_pid,
         caller_proof,
         challenge,
         transfer_ref
       ) do
    expiry_ref = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {@protocol, :expire, request_ref, expiry_ref},
        @challenge_ttl_ms
      )

    true =
      :ets.insert(
        custody,
        {request_ref, :expired, caller_pid, caller_proof, challenge, transfer_ref, timer_ref,
         expiry_ref}
      )

    :ok
  end

  defp caller_proof_matches?(
         caller_proof,
         request_ref,
         expected_challenge,
         expected_transfer_ref
       ) do
    valid_server_proof?(caller_proof) and
      case :ets.lookup(caller_proof, request_ref) do
        [{^request_ref, challenge, transfer_ref}] ->
          transfer_ref == expected_transfer_ref and secure_equal?(challenge, expected_challenge)

        _missing_or_malformed ->
          false
      end
  rescue
    ArgumentError -> false
  end

  defp valid_caller_proof?(caller_proof, caller_pid, require_empty?) do
    :ets.info(caller_proof, :owner) == caller_pid and
      :ets.info(caller_proof, :protection) == :private and
      :ets.info(caller_proof, :type) == :set and
      :ets.info(caller_proof, :keypos) == 1 and
      (not require_empty? or :ets.info(caller_proof, :size) == 0)
  rescue
    ArgumentError -> false
  end

  defp valid_server_proof?(caller_proof) do
    :ets.info(caller_proof, :owner) == self() and
      :ets.info(caller_proof, :protection) == :private and
      :ets.info(caller_proof, :type) == :set and
      :ets.info(caller_proof, :keypos) == 1 and
      :ets.info(caller_proof, :size) == 1
  rescue
    ArgumentError -> false
  end

  defp custody_owned?(custody) do
    :ets.info(custody, :owner) == self() and :ets.info(custody, :protection) == :private
  rescue
    ArgumentError -> false
  end

  defp reject(reply_alias, request_ref)
       when is_reference(reply_alias) and is_reference(request_ref) do
    reply({reply_alias, request_ref}, {:error, :unauthorized})
    :rejected
  end

  defp reject(_reply_alias, _request_ref), do: :rejected

  defp await_challenge(server_pid, request_ref, monitor_ref, deadline) do
    timeout = remaining(deadline)

    receive do
      {@protocol, :challenge, ^server_pid, ^request_ref, challenge, transfer_ref}
      when is_binary(challenge) and byte_size(challenge) == @challenge_bytes and
             is_reference(transfer_ref) ->
        {:challenge, challenge, transfer_ref}

      {@protocol, :reply, ^server_pid, ^request_ref, result} ->
        {:reply, result}

      {:DOWN, ^monitor_ref, :process, ^server_pid, reason} ->
        exit({reason, {__MODULE__, :call, [server_pid]}})
    after
      timeout -> exit({:timeout, {__MODULE__, :call, [server_pid]}})
    end
  end

  defp await_reply(server_pid, request_ref, monitor_ref, deadline) do
    timeout = remaining(deadline)

    receive do
      {@protocol, :reply, ^server_pid, ^request_ref, result} ->
        result

      {:DOWN, ^monitor_ref, :process, ^server_pid, reason} ->
        exit({reason, {__MODULE__, :call, [server_pid]}})
    after
      timeout -> exit({:timeout, {__MODULE__, :call, [server_pid]}})
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp challenge_ttl(:infinity), do: @challenge_ttl_ms
  defp challenge_ttl(timeout), do: min(timeout, @challenge_ttl_ms)

  defp delete_client_proof(caller_proof) do
    :ets.delete(caller_proof)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp delete_transferred_proof(caller_proof, custody) do
    if caller_proof != custody and :ets.info(caller_proof, :owner) == self() do
      :ets.delete(caller_proof)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp safe_send(destination, message) do
    send(destination, message)
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :error, :badarg -> :ok
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {a, b}, acc -> Bitwise.bor(acc, Bitwise.bxor(a, b)) end)
    |> Kernel.==(0)
  end

  defp secure_equal?(_left, _right), do: false
end
