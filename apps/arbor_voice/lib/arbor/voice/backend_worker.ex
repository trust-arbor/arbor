defmodule Arbor.Voice.BackendWorker do
  @moduledoc false

  use GenServer

  alias Arbor.Voice.Redacted

  @effect_request_tag :voice_backend_effect_request
  @effect_reply_tag :voice_backend_effect_reply
  @result_tag :voice_backend_operation_result

  @default_effect_timeout_ms 100
  @max_effect_timeout_ms 5_000
  @default_ack_timeout_ms 1_000
  @max_ack_timeout_ms 30_000
  @default_retire_timeout_ms 1_000
  @max_retire_timeout_ms 30_000
  @call_timeout_ms 1_000
  @max_result_binary_bytes 2 * 1024 * 1024
  @max_identifier_bytes 4_096

  @operations [
    :open,
    :configure,
    :send_text,
    :send_audio,
    :send_tool_result,
    :recv,
    :meta,
    :close
  ]
  @send_operations [:send_text, :send_audio, :send_tool_result]

  defmodule State do
    @moduledoc false

    @enforce_keys [
      :coordinator,
      :coordinator_ref,
      :generation,
      :worker_token,
      :backend_module,
      :backend_opts,
      :frozen_route,
      :effect_timeout_ms,
      :ack_timeout_ms,
      :retire_timeout_ms,
      :session
    ]
    defstruct @enforce_keys ++
                [
                  phase: :new,
                  operation: nil,
                  operation_args: nil,
                  operation_token: nil,
                  deadline_ms: nil,
                  terminal: false,
                  ack_timer_ref: nil
                ]

    defimpl Inspect do
      import Inspect.Algebra

      alias Arbor.Voice.Redacted

      def inspect(state, opts) do
        safe = %{
          coordinator: state.coordinator,
          generation: state.generation,
          backend_module: state.backend_module,
          phase: state.phase,
          operation: state.operation,
          terminal: state.terminal,
          has_session: not is_nil(Redacted.value(state.session))
        }

        concat(["#Arbor.Voice.BackendWorker.State<", to_doc(safe, opts), ">"])
      end
    end
  end

  @type operation ::
          :open
          | :configure
          | :send_text
          | :send_audio
          | :send_tool_result
          | :recv
          | :meta
          | :close

  @doc false
  def start_link(
        coordinator,
        generation,
        worker_token,
        backend_module,
        backend_opts,
        frozen_route,
        opts
      ) do
    GenServer.start_link(
      __MODULE__,
      {coordinator, generation, worker_token, backend_module, backend_opts, frozen_route, opts}
    )
  end

  @doc false
  @spec new_operation_token() :: reference()
  def new_operation_token, do: make_ref()

  @doc false
  @spec submit(
          GenServer.server(),
          reference(),
          binary(),
          reference(),
          integer(),
          operation(),
          list()
        ) :: :ok | {:error, atom()}
  def submit(
        worker,
        generation,
        worker_token,
        operation_token,
        deadline_ms,
        operation,
        args
      ) do
    GenServer.call(
      worker,
      {:submit, generation, worker_token, operation_token, deadline_ms, operation, args},
      @call_timeout_ms
    )
  catch
    :exit, _reason -> {:error, :worker_unavailable}
  end

  @doc false
  @spec ack(GenServer.server(), reference(), binary(), reference()) ::
          :ok | {:error, atom()}
  def ack(worker, generation, worker_token, operation_token) do
    GenServer.call(
      worker,
      {:ack, generation, worker_token, operation_token},
      @call_timeout_ms
    )
  catch
    :exit, _reason -> {:error, :worker_unavailable}
  end

  @doc false
  @spec reply_effect(tuple(), term()) :: :ok | {:error, :invalid_effect_request}
  def reply_effect(
        {@effect_request_tag, worker, generation, worker_token, effect_token, effect,
         frozen_route, reply_alias},
        decision
      )
      when is_pid(worker) and is_reference(generation) and is_binary(worker_token) and
             is_reference(effect_token) and is_atom(effect) and is_reference(reply_alias) do
    send(
      reply_alias,
      {@effect_reply_tag, worker, generation, worker_token, effect_token, effect, frozen_route,
       decision}
    )

    :ok
  rescue
    _exception -> {:error, :invalid_effect_request}
  catch
    _kind, _reason -> {:error, :invalid_effect_request}
  end

  def reply_effect(_request, _decision), do: {:error, :invalid_effect_request}

  @impl true
  def init(
        {coordinator, generation, worker_token, backend_module, backend_opts, frozen_route, opts}
      ) do
    with true <- is_pid(coordinator),
         true <- is_reference(generation),
         {:ok, token} <- unwrap_worker_token(worker_token),
         {:ok, backend_opts} <- unwrap_backend_opts(backend_opts),
         {:ok, frozen_route} <- unwrap_frozen_route(frozen_route),
         :ok <- validate_backend(backend_module),
         {:ok, config} <- validate_opts(opts),
         :ok <- bind_coordinator(coordinator) do
      {:ok,
       %State{
         coordinator: coordinator,
         coordinator_ref: Process.monitor(coordinator),
         generation: generation,
         worker_token: Redacted.new(token),
         backend_module: backend_module,
         backend_opts: Redacted.new(backend_opts),
         frozen_route: Redacted.new(frozen_route),
         effect_timeout_ms: config.effect_timeout_ms,
         ack_timeout_ms: config.ack_timeout_ms,
         retire_timeout_ms: config.retire_timeout_ms,
         session: Redacted.new(nil)
       }}
    else
      _invalid -> {:stop, :invalid_worker_config}
    end
  end

  @impl true
  def handle_call(request, {caller, _tag}, state) when caller != state.coordinator do
    _ = request
    {:reply, {:error, :foreign_coordinator}, state}
  end

  def handle_call(
        {:submit, generation, worker_token, operation_token, deadline_ms, operation, args},
        _from,
        state
      ) do
    with :ok <- validate_identity(state, generation, worker_token),
         :ok <- validate_idle(state),
         :ok <- validate_operation_token(operation_token),
         :ok <- validate_deadline(deadline_ms),
         :ok <- validate_operation(state.phase, operation, args) do
      next_state = %{
        state
        | phase: :running,
          operation: operation,
          operation_args: Redacted.new(args),
          operation_token: operation_token,
          deadline_ms: deadline_ms,
          terminal: false
      }

      {:reply, :ok, next_state, {:continue, :execute_operation}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ack, generation, worker_token, operation_token}, _from, state) do
    with :ok <- validate_identity(state, generation, worker_token),
         :ok <- validate_ack(state, operation_token) do
      cancel_timer(state.ack_timer_ref)

      if state.terminal do
        {:stop, :normal, :ok, %{state | ack_timer_ref: nil}}
      else
        {:reply, :ok, clear_operation(state)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :malformed_request}, state}

  @impl true
  def handle_continue(:execute_operation, state) do
    deadline_timer = arm_kill_timer(state.deadline_ms)
    Process.put(operation_deadline_key(), state.deadline_ms)

    execution = execute_operation(state)
    completed_at = now_ms()

    Process.delete(operation_deadline_key())
    cancel_kill_timer(deadline_timer)

    execution =
      if completed_at > state.deadline_ms do
        %{execution | outcome: {:error, :operation_timeout}, terminal: true}
      else
        execution
      end

    {session, terminal} =
      if execution.terminal do
        {retire_session(execution.session, state), true}
      else
        {execution.session, false}
      end

    worker_token = Redacted.value(state.worker_token)

    send(
      state.coordinator,
      {@result_tag, self(), state.generation, worker_token, state.operation_token,
       state.operation, completed_at, execution.outcome}
    )

    ack_timer =
      Process.send_after(
        self(),
        {:ack_timeout, state.generation, state.operation_token},
        state.ack_timeout_ms
      )

    {:noreply,
     %{
       state
       | phase: :awaiting_ack,
         session: Redacted.new(session),
         terminal: terminal,
         ack_timer_ref: ack_timer
     }}
  end

  @impl true
  def handle_info(
        {:ack_timeout, generation, operation_token},
        %{phase: :awaiting_ack, generation: generation, operation_token: operation_token} = state
      ) do
    _ = retire_session(Redacted.value(state.session), state)
    {:stop, :normal, %{state | session: Redacted.new(nil), ack_timer_ref: nil}}
  end

  def handle_info(
        {:DOWN, coordinator_ref, :process, coordinator, _reason},
        %{coordinator_ref: coordinator_ref, coordinator: coordinator} = state
      ) do
    cancel_timer(state.ack_timer_ref)
    _ = retire_session(Redacted.value(state.session), state)
    {:stop, :normal, %{state | session: Redacted.new(nil)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(%{state: %State{} = state} = status) do
    %{status | state: public_state(state), message: :redacted, log: :redacted}
  end

  def format_status(status), do: status

  defp execute_operation(%{operation: :open} = state) do
    authorizer = effect_authorizer(state)
    backend_opts = Keyword.put(Redacted.value(state.backend_opts), :effect_authorizer, authorizer)

    invoke_and_normalize(state, fn -> state.backend_module.open(backend_opts) end)
  end

  defp execute_operation(%{operation: operation} = state) do
    session = Redacted.value(state.session)
    args = operation_args(state)

    invoke_and_normalize(state, fn -> apply(state.backend_module, operation, [session | args]) end)
  end

  defp invoke_and_normalize(state, callback) do
    callback.()
    |> normalize_result(state.operation, Redacted.value(state.session))
  rescue
    _exception -> terminal_result(:backend_callback_fault, Redacted.value(state.session))
  catch
    _kind, _reason -> terminal_result(:backend_callback_fault, Redacted.value(state.session))
  end

  defp normalize_result({:ok, session}, :open, _prior),
    do: operation_result(:ok, session, false)

  defp normalize_result({:error, _reason}, :open, _prior),
    do: terminal_result(:backend_open_failed, nil)

  defp normalize_result({:ok, session}, operation, _prior)
       when operation in [:configure | @send_operations],
       do: operation_result(:ok, session, false)

  defp normalize_result({:error, _reason, latest_session}, operation, _prior)
       when operation in [:configure | @send_operations],
       do: terminal_result(:backend_partial_failure, latest_session)

  defp normalize_result({:error, _reason}, :configure, prior),
    do: operation_result({:error, :backend_callback_failed}, prior, false)

  defp normalize_result({:error, _reason}, operation, prior)
       when operation in @send_operations,
       do: terminal_result(:backend_callback_failed, prior)

  defp normalize_result({:ok, session, event}, :recv, _prior) do
    case normalize_event(event) do
      {:ok, bounded_event} -> operation_result({:ok, bounded_event}, session, false)
      :error -> terminal_result(:invalid_backend_event, session)
    end
  end

  defp normalize_result({:error, :timeout}, :recv, prior),
    do: operation_result({:error, :timeout}, prior, false)

  defp normalize_result({:error, _reason}, :recv, prior),
    do: terminal_result(:backend_callback_failed, prior)

  defp normalize_result(meta, :meta, prior) do
    if valid_meta?(meta),
      do: operation_result({:ok, meta}, prior, false),
      else: terminal_result(:invalid_backend_meta, prior)
  end

  defp normalize_result(:ok, :close, _prior), do: operation_result(:ok, nil, true)
  defp normalize_result(_result, :close, prior), do: terminal_result(:backend_close_failed, prior)

  defp normalize_result(_result, _operation, prior),
    do: terminal_result(:invalid_backend_return, prior)

  defp operation_result(outcome, session, terminal) do
    %{outcome: outcome, session: session, terminal: terminal}
  end

  defp terminal_result(reason, session),
    do: operation_result({:error, reason}, session, true)

  defp retire_session(nil, _state), do: nil

  defp retire_session(session, state) do
    timer = arm_relative_kill_timer(state.retire_timeout_ms)

    try do
      _ = state.backend_module.close(session)
      nil
    rescue
      _exception -> nil
    catch
      _kind, _reason -> nil
    after
      cancel_kill_timer(timer)
    end
  end

  defp effect_authorizer(state) do
    coordinator = state.coordinator
    generation = state.generation
    worker_token = Redacted.value(state.worker_token)
    frozen_route = Redacted.value(state.frozen_route)
    timeout_ms = state.effect_timeout_ms

    fn effect, callback_route ->
      authorize_effect(
        coordinator,
        generation,
        worker_token,
        effect,
        callback_route,
        frozen_route,
        timeout_ms
      )
    end
  end

  defp authorize_effect(
         coordinator,
         generation,
         worker_token,
         effect,
         callback_route,
         frozen_route,
         timeout_ms
       )
       when is_atom(effect) and not is_nil(effect) and callback_route === frozen_route do
    deadline_ms = Process.get(operation_deadline_key())
    remaining = if is_integer(deadline_ms), do: deadline_ms - now_ms(), else: 0
    wait_ms = min(timeout_ms, max(remaining, 0))

    if wait_ms == 0 do
      {:error, :backend_effect_denied}
    else
      effect_token = make_ref()
      reply_alias = :erlang.alias()

      request =
        {@effect_request_tag, self(), generation, worker_token, effect_token, effect,
         frozen_route, reply_alias}

      send(coordinator, request)

      decision =
        receive do
          {@effect_reply_tag, worker, ^generation, ^worker_token, ^effect_token, ^effect,
           ^frozen_route, response}
          when worker == self() ->
            response
        after
          wait_ms -> :effect_timeout
        end

      :erlang.unalias(reply_alias)

      if decision === :allow, do: :allow, else: {:error, :backend_effect_denied}
    end
  rescue
    _exception -> {:error, :backend_effect_denied}
  catch
    _kind, _reason -> {:error, :backend_effect_denied}
  end

  defp authorize_effect(
         _coordinator,
         _generation,
         _worker_token,
         _effect,
         _callback_route,
         _frozen_route,
         _timeout_ms
       ),
       do: {:error, :backend_effect_denied}

  defp operation_args(state) do
    case state.operation_args do
      %Redacted{} = args -> Redacted.value(args)
      _missing -> []
    end
  end

  defp validate_operation(:new, :open, []), do: :ok

  defp validate_operation(:new, _operation, _args), do: {:error, :open_required}
  defp validate_operation(:idle, :open, _args), do: {:error, :already_open}

  defp validate_operation(:idle, operation, args) when operation in @operations do
    if valid_operation_args?(operation, args) do
      :ok
    else
      {:error, :invalid_operation}
    end
  end

  defp validate_operation(_phase, _operation, _args), do: {:error, :invalid_operation}

  defp valid_operation_args?(:configure, [config]), do: is_map(config)
  defp valid_operation_args?(:send_text, [text]), do: is_binary(text)
  defp valid_operation_args?(:send_audio, [audio]), do: is_binary(audio)

  defp valid_operation_args?(:send_tool_result, [call_id, output]),
    do: is_binary(call_id) and is_binary(output)

  defp valid_operation_args?(:recv, [timeout]),
    do: timeout == :infinity or (is_integer(timeout) and timeout >= 0)

  defp valid_operation_args?(operation, []) when operation in [:meta, :close], do: true
  defp valid_operation_args?(_operation, _args), do: false

  defp validate_identity(state, generation, worker_token) do
    expected_token = Redacted.value(state.worker_token)

    cond do
      generation !== state.generation -> {:error, :stale_generation}
      not is_binary(worker_token) -> {:error, :invalid_worker_token}
      worker_token !== expected_token -> {:error, :invalid_worker_token}
      true -> :ok
    end
  end

  defp validate_idle(%{phase: phase}) when phase in [:running, :awaiting_ack],
    do: {:error, :operation_pending}

  defp validate_idle(%{phase: phase}) when phase in [:new, :idle], do: :ok
  defp validate_idle(_state), do: {:error, :worker_terminal}

  defp validate_operation_token(token) when is_reference(token), do: :ok
  defp validate_operation_token(_token), do: {:error, :invalid_operation_token}

  defp validate_deadline(deadline_ms) when is_integer(deadline_ms) do
    if deadline_ms > now_ms(), do: :ok, else: {:error, :deadline_expired}
  end

  defp validate_deadline(_deadline_ms), do: {:error, :invalid_deadline}

  defp validate_ack(%{phase: :awaiting_ack, operation_token: token}, token), do: :ok
  defp validate_ack(%{phase: :awaiting_ack}, _token), do: {:error, :stale_ack}
  defp validate_ack(_state, _token), do: {:error, :ack_not_expected}

  defp clear_operation(state) do
    %{
      state
      | phase: :idle,
        operation: nil,
        operation_args: nil,
        operation_token: nil,
        deadline_ms: nil,
        terminal: false,
        ack_timer_ref: nil
    }
  end

  defp normalize_event({:input_transcript, text}) when is_binary(text),
    do: bounded_binary_event({:input_transcript, text}, text)

  defp normalize_event({:output_text_delta, text}) when is_binary(text),
    do: bounded_binary_event({:output_text_delta, text}, text)

  defp normalize_event({:output_audio, audio}) when is_binary(audio),
    do: bounded_binary_event({:output_audio, audio}, audio)

  defp normalize_event({:turn_done, %{text: text} = payload}) when is_binary(text) do
    if Map.keys(payload) == [:text] and byte_size(text) <= @max_result_binary_bytes,
      do: {:ok, {:turn_done, payload}},
      else: :error
  end

  defp normalize_event({:tool_call, %{id: id, name: name, arguments: arguments} = call})
       when is_binary(id) and is_binary(name) and is_map(arguments) do
    exact_keys? =
      Map.keys(call) |> MapSet.new() |> MapSet.equal?(MapSet.new([:id, :name, :arguments]))

    if exact_keys? and byte_size(id) <= @max_identifier_bytes and
         byte_size(name) <= @max_identifier_bytes and bounded_json?(arguments) do
      {:ok, {:tool_call, call}}
    else
      :error
    end
  end

  defp normalize_event({:error, _reason}), do: {:ok, {:error, :backend_event_error}}
  defp normalize_event(_event), do: :error

  defp bounded_binary_event(event, binary) do
    if byte_size(binary) <= @max_result_binary_bytes, do: {:ok, event}, else: :error
  end

  defp bounded_json?(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded) <= @max_result_binary_bytes
      {:error, _reason} -> false
    end
  end

  defp valid_meta?(
         %{backend: backend, mode: mode, input_rate: input_rate, output_rate: output_rate} = meta
       ) do
    exact_keys? =
      meta
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.equal?(MapSet.new([:backend, :mode, :input_rate, :output_rate]))

    exact_keys? and is_atom(backend) and not is_nil(backend) and mode in [:cloud, :local] and
      valid_rate?(input_rate) and valid_rate?(output_rate)
  end

  defp valid_meta?(_meta), do: false
  defp valid_rate?(nil), do: true
  defp valid_rate?(rate), do: is_integer(rate) and rate > 0

  defp unwrap_worker_token(%Redacted{} = redacted) do
    case Redacted.value(redacted) do
      token when is_binary(token) and byte_size(token) == 32 -> {:ok, token}
      _invalid -> {:error, :invalid_worker_token}
    end
  end

  defp unwrap_worker_token(_token), do: {:error, :invalid_worker_token}

  defp unwrap_backend_opts(%Redacted{} = redacted) do
    opts = Redacted.value(redacted)

    if is_list(opts) and Keyword.keyword?(opts),
      do: {:ok, opts},
      else: {:error, :invalid_backend_opts}
  end

  defp unwrap_backend_opts(_opts), do: {:error, :invalid_backend_opts}

  defp unwrap_frozen_route(%Redacted{} = redacted) do
    route = Redacted.value(redacted)
    if valid_route?(route), do: {:ok, route}, else: {:error, :invalid_route}
  end

  defp unwrap_frozen_route(_route), do: {:error, :invalid_route}

  defp valid_route?(:none), do: true

  defp valid_route?(
         %{
           destination: destination,
           provider: provider,
           runtime: runtime,
           model: model
         } = route
       ) do
    route |> Map.keys() |> MapSet.new() ==
      MapSet.new([:destination, :provider, :runtime, :model]) and
      Enum.all?([destination, provider, runtime, model], &is_binary/1)
  end

  defp valid_route?(_route), do: false

  defp validate_backend(backend_module) when is_atom(backend_module) do
    callbacks = [
      open: 1,
      configure: 2,
      send_text: 2,
      send_audio: 2,
      send_tool_result: 3,
      recv: 2,
      meta: 1,
      close: 1
    ]

    if Code.ensure_loaded?(backend_module) and
         Enum.all?(callbacks, fn {name, arity} ->
           function_exported?(backend_module, name, arity)
         end) do
      :ok
    else
      {:error, :invalid_backend}
    end
  end

  defp validate_backend(_backend_module), do: {:error, :invalid_backend}

  defp validate_opts(opts) when is_list(opts) do
    allowed = [:effect_timeout_ms, :ack_timeout_ms, :retire_timeout_ms]

    with true <- Keyword.keyword?(opts),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in allowed)),
         {:ok, effect_timeout_ms} <-
           bounded_timeout(
             opts,
             :effect_timeout_ms,
             @default_effect_timeout_ms,
             @max_effect_timeout_ms
           ),
         {:ok, ack_timeout_ms} <-
           bounded_timeout(opts, :ack_timeout_ms, @default_ack_timeout_ms, @max_ack_timeout_ms),
         {:ok, retire_timeout_ms} <-
           bounded_timeout(
             opts,
             :retire_timeout_ms,
             @default_retire_timeout_ms,
             @max_retire_timeout_ms
           ) do
      {:ok,
       %{
         effect_timeout_ms: effect_timeout_ms,
         ack_timeout_ms: ack_timeout_ms,
         retire_timeout_ms: retire_timeout_ms
       }}
    else
      _invalid -> {:error, :invalid_worker_opts}
    end
  end

  defp validate_opts(_opts), do: {:error, :invalid_worker_opts}

  defp bounded_timeout(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      timeout when is_integer(timeout) and timeout > 0 and timeout <= maximum -> {:ok, timeout}
      _invalid -> {:error, :invalid_worker_opts}
    end
  end

  defp bind_coordinator(coordinator) do
    if Process.alive?(coordinator) do
      Process.link(coordinator)
      :ok
    else
      {:error, :coordinator_unavailable}
    end
  rescue
    _exception -> {:error, :coordinator_unavailable}
  catch
    _kind, _reason -> {:error, :coordinator_unavailable}
  end

  defp arm_kill_timer(deadline_ms) do
    arm_relative_kill_timer(max(deadline_ms - now_ms(), 0))
  end

  defp arm_relative_kill_timer(timeout_ms) do
    case :timer.kill_after(timeout_ms, self()) do
      {:ok, timer} -> timer
      {:error, _reason} -> nil
    end
  end

  defp cancel_kill_timer(nil), do: :ok

  defp cancel_kill_timer(timer) do
    _ = :timer.cancel(timer)
    :ok
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _ = Process.cancel_timer(timer)
    :ok
  end

  defp operation_deadline_key, do: {__MODULE__, :operation_deadline}
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp public_state(state) do
    %{
      coordinator: state.coordinator,
      generation: state.generation,
      backend_module: state.backend_module,
      phase: state.phase,
      operation: state.operation,
      terminal: state.terminal,
      has_session: not is_nil(Redacted.value(state.session))
    }
  end
end
