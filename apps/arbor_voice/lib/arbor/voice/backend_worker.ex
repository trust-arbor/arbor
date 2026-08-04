defmodule Arbor.Voice.BackendWorker do
  @moduledoc false

  use GenServer

  alias Arbor.Voice.Redacted

  @result_tag :voice_backend_operation_result

  @default_effect_timeout_ms 100
  @max_effect_timeout_ms 5_000
  @default_ack_timeout_ms 1_000
  @max_ack_timeout_ms 30_000
  @default_retire_timeout_ms 1_000
  @max_retire_timeout_ms 30_000
  @max_deadline_distance_ms 120_000
  @call_timeout_ms 1_000

  @max_route_scalar_bytes 2_048
  @max_route_bytes 8_192
  @max_backend_opts_count 32
  @max_backend_opts_bytes 65_536
  @max_config_bytes 262_144
  @max_text_bytes 8_192
  @max_audio_bytes 2 * 1024 * 1024
  @max_tool_id_bytes 256
  @max_tool_output_bytes 8_192
  @max_operation_bytes @max_audio_bytes + 65_536
  @max_result_binary_bytes 2 * 1024 * 1024
  @max_event_text_bytes 8_192
  @max_event_arguments_bytes 8_192
  @max_identifier_bytes 256

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

  defmodule Credential do
    @moduledoc false
    @enforce_keys [:worker, :coordinator, :generation, :secret]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            worker: pid(),
            coordinator: pid(),
            generation: reference(),
            secret: Arbor.Voice.Redacted.t()
          }

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(credential, _opts) do
        concat([
          "#Arbor.Voice.BackendWorker.Credential<worker=",
          inspect(credential.worker),
          " generation=redacted>"
        ])
      end
    end
  end

  defmodule CompletionCredential do
    @moduledoc false
    @enforce_keys [:value]
    defstruct @enforce_keys

    @type t :: %__MODULE__{value: Arbor.Voice.Redacted.t()}

    defimpl Inspect do
      def inspect(_credential, _opts),
        do: "#Arbor.Voice.BackendWorker.CompletionCredential<redacted>"
    end
  end

  defmodule OperationRequest do
    @moduledoc false
    @enforce_keys [
      :worker,
      :coordinator,
      :generation,
      :operation_token,
      :deadline_ms,
      :operation,
      :args,
      :authenticator
    ]
    defstruct @enforce_keys

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(request, opts) do
        safe = %{
          worker: request.worker,
          coordinator: request.coordinator,
          generation: request.generation,
          operation: request.operation,
          deadline_ms: request.deadline_ms,
          payload: :redacted,
          authenticator: :redacted
        }

        concat(["#Arbor.Voice.BackendWorker.OperationRequest<", to_doc(safe, opts), ">"])
      end
    end
  end

  defmodule AckRequest do
    @moduledoc false
    @enforce_keys [
      :worker,
      :coordinator,
      :generation,
      :operation_token,
      :completion,
      :authenticator
    ]
    defstruct @enforce_keys

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(request, opts) do
        safe = %{
          worker: request.worker,
          coordinator: request.coordinator,
          generation: request.generation,
          completion: :redacted,
          authenticator: :redacted
        }

        concat(["#Arbor.Voice.BackendWorker.AckRequest<", to_doc(safe, opts), ">"])
      end
    end
  end

  defmodule EffectRequest do
    @moduledoc false
    @enforce_keys [
      :worker,
      :coordinator,
      :generation,
      :operation_token,
      :effect_token,
      :effect,
      :frozen_route,
      :reply_alias
    ]
    defstruct @enforce_keys

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(request, opts) do
        safe = %{
          worker: request.worker,
          coordinator: request.coordinator,
          generation: request.generation,
          effect: request.effect,
          operation: :redacted,
          route: :redacted,
          reply: :redacted
        }

        concat(["#Arbor.Voice.BackendWorker.EffectRequest<", to_doc(safe, opts), ">"])
      end
    end
  end

  defmodule EffectReply do
    @moduledoc false
    @enforce_keys [
      :worker,
      :coordinator,
      :generation,
      :operation_token,
      :effect_token,
      :effect,
      :frozen_route,
      :decision,
      :authenticator
    ]
    defstruct @enforce_keys

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(reply, opts) do
        safe = %{
          worker: reply.worker,
          coordinator: reply.coordinator,
          generation: reply.generation,
          effect: reply.effect,
          decision: :redacted,
          authenticator: :redacted
        }

        concat(["#Arbor.Voice.BackendWorker.EffectReply<", to_doc(safe, opts), ">"])
      end
    end
  end

  defmodule Result do
    @moduledoc false
    @enforce_keys [
      :worker,
      :coordinator,
      :generation,
      :operation_token,
      :operation,
      :completed_at,
      :outcome,
      :completion,
      :authenticator
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            worker: pid(),
            coordinator: pid(),
            generation: reference(),
            operation_token: reference(),
            operation: atom(),
            completed_at: integer(),
            outcome: term(),
            completion: CompletionCredential.t(),
            authenticator: Arbor.Voice.Redacted.t()
          }

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(result, opts) do
        safe = %{
          worker: result.worker,
          coordinator: result.coordinator,
          generation: result.generation,
          operation: result.operation,
          completed_at: result.completed_at,
          outcome: :redacted,
          completion: :redacted,
          authenticator: :redacted
        }

        concat(["#Arbor.Voice.BackendWorker.Result<", to_doc(safe, opts), ">"])
      end
    end
  end

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :coordinator,
      :coordinator_ref,
      :generation,
      :worker_secret,
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
                  completion: nil,
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
        worker_secret,
        backend_module,
        backend_opts,
        frozen_route,
        opts
      ) do
    GenServer.start_link(
      __MODULE__,
      {coordinator, generation, worker_secret, backend_module, backend_opts, frozen_route, opts}
    )
  end

  @doc false
  @spec new_operation_token() :: reference()
  def new_operation_token, do: make_ref()

  @doc false
  @spec max_deadline_distance_ms() :: pos_integer()
  def max_deadline_distance_ms, do: @max_deadline_distance_ms

  @doc false
  @spec max_config_bytes() :: pos_integer()
  def max_config_bytes, do: @max_config_bytes

  @doc false
  @spec max_audio_bytes() :: pos_integer()
  def max_audio_bytes, do: @max_audio_bytes

  @doc false
  @spec new_credential(pid(), pid(), reference(), Redacted.t()) :: Credential.t()
  def new_credential(worker, coordinator, generation, secret) do
    %Credential{
      worker: worker,
      coordinator: coordinator,
      generation: generation,
      secret: secret
    }
  end

  @doc false
  @spec submit(pid(), Credential.t(), reference(), integer(), operation(), list()) ::
          :ok | {:error, atom()}
  def submit(worker, credential, operation_token, deadline_ms, operation, args) do
    with {:ok, secret} <- boundary_secret(credential, worker),
         :ok <- validate_operation_token(operation_token),
         :ok <- validate_deadline(deadline_ms),
         :ok <- validate_operation_args(operation, args) do
      request = %OperationRequest{
        worker: worker,
        coordinator: self(),
        generation: credential.generation,
        operation_token: operation_token,
        deadline_ms: deadline_ms,
        operation: operation,
        args: Redacted.new(args),
        authenticator:
          Redacted.new(
            authenticate(
              secret,
              :operation,
              operation_auth_fields(
                worker,
                self(),
                credential.generation,
                operation_token,
                deadline_ms,
                operation,
                args
              )
            )
          )
      }

      safe_call(worker, {:submit, request})
    end
  end

  @doc false
  @spec verify_result(Result.t(), Credential.t()) :: {:ok, map()} | {:error, atom()}
  def verify_result(%Result{} = result, credential) do
    with {:ok, secret} <- boundary_secret(credential, result.worker),
         true <- result.coordinator == self(),
         true <- result.generation === credential.generation,
         {:ok, completion_value} <- completion_value(result.completion),
         true <- valid_result_shape?(result),
         true <-
           authenticated?(
             result.authenticator,
             secret,
             :result,
             result_auth_fields(result, completion_value)
           ) do
      {:ok,
       %{
         worker: result.worker,
         generation: result.generation,
         operation_token: result.operation_token,
         operation: result.operation,
         completed_at: result.completed_at,
         outcome: result.outcome,
         completion: result.completion
       }}
    else
      _invalid -> {:error, :invalid_result}
    end
  end

  def verify_result(_result, _credential), do: {:error, :invalid_result}

  @doc false
  @spec ack(pid(), Credential.t(), Result.t()) :: :ok | {:error, atom()}
  def ack(worker, credential, %Result{} = result) do
    with {:ok, verified} <- verify_result(result, credential) do
      ack(worker, credential, verified.operation_token, verified.completion)
    end
  end

  def ack(_worker, _credential, _result), do: {:error, :invalid_result}

  @doc false
  @spec ack(pid(), Credential.t(), reference(), CompletionCredential.t()) ::
          :ok | {:error, atom()}
  def ack(worker, credential, operation_token, completion) do
    with {:ok, secret} <- boundary_secret(credential, worker),
         :ok <- validate_operation_token(operation_token),
         {:ok, completion_value} <- completion_value(completion) do
      request = %AckRequest{
        worker: worker,
        coordinator: self(),
        generation: credential.generation,
        operation_token: operation_token,
        completion: completion,
        authenticator:
          Redacted.new(
            authenticate(
              secret,
              :ack,
              ack_auth_fields(
                worker,
                self(),
                credential.generation,
                operation_token,
                completion_value
              )
            )
          )
      }

      safe_call(worker, {:ack, request})
    end
  end

  @doc false
  @spec reply_effect(EffectRequest.t(), Credential.t(), term()) ::
          :ok | {:error, :invalid_effect_request}
  def reply_effect(%EffectRequest{} = request, credential, decision) do
    with {:ok, secret} <- boundary_secret(credential, request.worker),
         true <- request.coordinator == self(),
         true <- request.generation === credential.generation,
         true <- valid_effect_request_shape?(request) do
      reply = %EffectReply{
        worker: request.worker,
        coordinator: request.coordinator,
        generation: request.generation,
        operation_token: request.operation_token,
        effect_token: request.effect_token,
        effect: request.effect,
        frozen_route: request.frozen_route,
        decision: decision,
        authenticator:
          Redacted.new(
            authenticate(secret, :effect_reply, effect_reply_auth_fields(request, decision))
          )
      }

      send(request.reply_alias, reply)
      :ok
    else
      _invalid -> {:error, :invalid_effect_request}
    end
  rescue
    _exception -> {:error, :invalid_effect_request}
  catch
    _kind, _reason -> {:error, :invalid_effect_request}
  end

  def reply_effect(_request, _credential, _decision), do: {:error, :invalid_effect_request}

  @doc false
  @spec reply_effect(term(), term()) :: {:error, :invalid_effect_request}
  def reply_effect(_request, _decision), do: {:error, :invalid_effect_request}

  @impl true
  def init(
        {coordinator, generation, worker_secret, backend_module, backend_opts, frozen_route, opts}
      ) do
    with true <- is_pid(coordinator),
         true <- is_reference(generation),
         {:ok, secret} <- unwrap_secret(worker_secret),
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
         worker_secret: Redacted.new(secret),
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
  def handle_call(_request, {caller, _tag}, state) when caller != state.coordinator do
    {:reply, {:error, :foreign_coordinator}, state}
  end

  def handle_call({:submit, %OperationRequest{} = request}, _from, state) do
    with :ok <- validate_request_identity(state, request),
         :ok <- validate_idle(state),
         {:ok, args} <- unwrap_request_args(request.args),
         :ok <- validate_operation_token(request.operation_token),
         :ok <- validate_deadline(request.deadline_ms),
         :ok <- validate_operation(state.phase, request.operation, args),
         true <- valid_operation_authenticator?(state, request, args) do
      next_state = %{
        state
        | phase: :running,
          operation: request.operation,
          operation_args: Redacted.new(args),
          operation_token: request.operation_token,
          deadline_ms: request.deadline_ms,
          completion: nil,
          terminal: false
      }

      {:reply, :ok, next_state, {:continue, :execute_operation}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      false -> {:reply, {:error, :invalid_operation_authenticator}, state}
    end
  end

  def handle_call({:ack, %AckRequest{} = request}, _from, state) do
    with :ok <- validate_ack_identity(state, request),
         :ok <- validate_ack(state, request),
         true <- valid_ack_authenticator?(state, request) do
      cancel_timer(state.ack_timer_ref)

      if state.terminal do
        {:stop, :normal, :ok, %{state | ack_timer_ref: nil}}
      else
        {:reply, :ok, clear_operation(state)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      false -> {:reply, {:error, :invalid_ack}, state}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :malformed_request}, state}

  @impl true
  def handle_continue(:execute_operation, state) do
    case arm_kill_timer(state.deadline_ms) do
      {:ok, deadline_timer} ->
        execute_with_watchdog(state, deadline_timer)

      :error ->
        Process.exit(self(), :kill)
        {:noreply, state}
    end
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

  defp execute_with_watchdog(state, deadline_timer) do
    Process.put(operation_context_key(), %{
      deadline_ms: state.deadline_ms,
      operation_token: state.operation_token
    })

    execution = execute_operation(state)
    completed_at = now_ms()

    Process.delete(operation_context_key())
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

    completion_value = make_ref()
    completion = %CompletionCredential{value: Redacted.new(completion_value)}
    result = build_result(state, execution.outcome, completed_at, completion, completion_value)
    send(state.coordinator, {@result_tag, result})

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
         completion: completion,
         terminal: terminal,
         ack_timer_ref: ack_timer
     }}
  end

  defp build_result(state, outcome, completed_at, completion, completion_value) do
    result = %Result{
      worker: self(),
      coordinator: state.coordinator,
      generation: state.generation,
      operation_token: state.operation_token,
      operation: state.operation,
      completed_at: completed_at,
      outcome: outcome,
      completion: completion,
      authenticator: Redacted.new(<<>>)
    }

    secret = Redacted.value(state.worker_secret)

    %{
      result
      | authenticator:
          Redacted.new(
            authenticate(secret, :result, result_auth_fields(result, completion_value))
          )
    }
  end

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
    do: terminal_result(:backend_callback_failed, prior)

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

  defp operation_result(outcome, session, terminal),
    do: %{outcome: outcome, session: session, terminal: terminal}

  defp terminal_result(reason, session),
    do: operation_result({:error, reason}, session, true)

  defp retire_session(nil, _state), do: nil

  defp retire_session(session, state) do
    case arm_relative_kill_timer(state.retire_timeout_ms) do
      {:ok, timer} ->
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

      :error ->
        Process.exit(self(), :kill)
        nil
    end
  end

  defp effect_authorizer(state) do
    coordinator = state.coordinator
    generation = state.generation
    worker_secret = Redacted.value(state.worker_secret)
    frozen_route = Redacted.value(state.frozen_route)
    timeout_ms = state.effect_timeout_ms

    fn effect, callback_route ->
      authorize_effect(
        coordinator,
        generation,
        worker_secret,
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
         worker_secret,
         effect,
         callback_route,
         frozen_route,
         timeout_ms
       )
       when is_atom(effect) and not is_nil(effect) and callback_route === frozen_route do
    with %{deadline_ms: deadline_ms, operation_token: operation_token}
         when is_integer(deadline_ms) and is_reference(operation_token) <-
           Process.get(operation_context_key()),
         remaining when remaining > 0 <- deadline_ms - now_ms() do
      effect_token = make_ref()
      reply_alias = :erlang.alias()

      request = %EffectRequest{
        worker: self(),
        coordinator: coordinator,
        generation: generation,
        operation_token: operation_token,
        effect_token: effect_token,
        effect: effect,
        frozen_route: frozen_route,
        reply_alias: reply_alias
      }

      send(coordinator, request)
      wait_ms = min(timeout_ms, remaining)

      reply =
        receive do
          %EffectReply{} = candidate -> candidate
        after
          wait_ms -> :effect_timeout
        end

      :erlang.unalias(reply_alias)

      if valid_effect_reply?(
           reply,
           request,
           worker_secret
         ),
         do: :allow,
         else: {:error, :backend_effect_denied}
    else
      _invalid -> {:error, :backend_effect_denied}
    end
  rescue
    _exception -> {:error, :backend_effect_denied}
  catch
    _kind, _reason -> {:error, :backend_effect_denied}
  end

  defp authorize_effect(
         _coordinator,
         _generation,
         _worker_secret,
         _effect,
         _callback_route,
         _frozen_route,
         _timeout_ms
       ),
       do: {:error, :backend_effect_denied}

  defp valid_effect_reply?(%EffectReply{} = reply, request, secret) do
    reply.worker == request.worker and
      reply.coordinator == request.coordinator and
      reply.generation === request.generation and
      reply.operation_token === request.operation_token and
      reply.effect_token === request.effect_token and
      reply.effect === request.effect and
      reply.frozen_route === request.frozen_route and
      reply.decision === :allow and
      authenticated?(
        reply.authenticator,
        secret,
        :effect_reply,
        effect_reply_auth_fields(request, reply.decision)
      )
  end

  defp valid_effect_reply?(_reply, _request, _secret), do: false

  defp operation_args(%{operation_args: %Redacted{} = args}), do: Redacted.value(args)
  defp operation_args(_state), do: []

  defp validate_operation(:new, :open, []), do: :ok
  defp validate_operation(:new, _operation, _args), do: {:error, :open_required}
  defp validate_operation(:idle, :open, _args), do: {:error, :already_open}

  defp validate_operation(:idle, operation, args),
    do: validate_operation_args(operation, args)

  defp validate_operation(_phase, _operation, _args), do: {:error, :invalid_operation}

  defp validate_operation_args(operation, args) when operation in @operations do
    if valid_operation_args?(operation, args) and
         bounded_external_term?(args, @max_operation_bytes),
       do: :ok,
       else: {:error, :invalid_operation}
  end

  defp validate_operation_args(_operation, _args), do: {:error, :invalid_operation}

  defp valid_operation_args?(:open, []), do: true

  defp valid_operation_args?(:configure, [config]) when is_map(config),
    do: bounded_json?(config, @max_config_bytes)

  defp valid_operation_args?(:send_text, [text]),
    do: bounded_utf8?(text, @max_text_bytes)

  defp valid_operation_args?(:send_audio, [audio]),
    do: is_binary(audio) and byte_size(audio) <= @max_audio_bytes

  defp valid_operation_args?(:send_tool_result, [call_id, output]),
    do:
      bounded_utf8?(call_id, @max_tool_id_bytes) and
        bounded_utf8?(output, @max_tool_output_bytes)

  defp valid_operation_args?(:recv, [timeout]),
    do: timeout == :infinity or (is_integer(timeout) and timeout >= 0)

  defp valid_operation_args?(operation, []) when operation in [:meta, :close], do: true
  defp valid_operation_args?(_operation, _args), do: false

  defp validate_request_identity(state, request) do
    cond do
      request.worker != self() -> {:error, :invalid_worker}
      request.coordinator != state.coordinator -> {:error, :foreign_coordinator}
      request.generation !== state.generation -> {:error, :stale_generation}
      true -> :ok
    end
  end

  defp validate_ack_identity(state, request) do
    cond do
      request.worker != self() -> {:error, :invalid_worker}
      request.coordinator != state.coordinator -> {:error, :foreign_coordinator}
      request.generation !== state.generation -> {:error, :stale_generation}
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
    remaining = deadline_ms - now_ms()

    cond do
      remaining <= 0 -> {:error, :deadline_expired}
      remaining > @max_deadline_distance_ms -> {:error, :deadline_too_far}
      true -> :ok
    end
  end

  defp validate_deadline(_deadline_ms), do: {:error, :invalid_deadline}

  defp validate_ack(%{phase: :awaiting_ack} = state, request) do
    with true <- request.operation_token === state.operation_token,
         {:ok, requested_completion} <- completion_value(request.completion),
         {:ok, expected_completion} <- completion_value(state.completion),
         true <- requested_completion === expected_completion do
      :ok
    else
      _invalid -> {:error, :stale_ack}
    end
  end

  defp validate_ack(_state, _request), do: {:error, :ack_not_expected}

  defp clear_operation(state) do
    %{
      state
      | phase: :idle,
        operation: nil,
        operation_args: nil,
        operation_token: nil,
        deadline_ms: nil,
        completion: nil,
        terminal: false,
        ack_timer_ref: nil
    }
  end

  defp normalize_event({:input_transcript, text}) when is_binary(text),
    do: bounded_text_event({:input_transcript, text}, text)

  defp normalize_event({:output_text_delta, text}) when is_binary(text),
    do: bounded_text_event({:output_text_delta, text}, text)

  defp normalize_event({:output_audio, audio}) when is_binary(audio),
    do: bounded_binary_event({:output_audio, audio}, audio)

  defp normalize_event({:turn_done, %{text: text} = payload}) when is_binary(text) do
    if Map.keys(payload) == [:text] and bounded_utf8?(text, @max_event_text_bytes),
      do: {:ok, {:turn_done, payload}},
      else: :error
  end

  defp normalize_event({:tool_call, %{id: id, name: name, arguments: arguments} = call})
       when is_binary(id) and is_binary(name) and is_map(arguments) do
    exact_keys? =
      Map.keys(call) |> MapSet.new() |> MapSet.equal?(MapSet.new([:id, :name, :arguments]))

    if exact_keys? and bounded_utf8?(id, @max_identifier_bytes) and
         bounded_utf8?(name, @max_identifier_bytes) and
         bounded_json?(arguments, @max_event_arguments_bytes) do
      {:ok, {:tool_call, call}}
    else
      :error
    end
  end

  defp normalize_event({:error, _reason}), do: {:ok, {:error, :backend_event_error}}
  defp normalize_event(_event), do: :error

  defp bounded_text_event(event, binary) do
    if bounded_utf8?(binary, @max_event_text_bytes), do: {:ok, event}, else: :error
  end

  defp bounded_binary_event(event, binary) do
    if byte_size(binary) <= @max_result_binary_bytes, do: {:ok, event}, else: :error
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

  defp boundary_secret(%Credential{} = credential, worker) do
    cond do
      credential.worker != worker -> {:error, :invalid_worker_credential}
      credential.coordinator != self() -> {:error, :foreign_coordinator}
      not is_reference(credential.generation) -> {:error, :invalid_worker_credential}
      true -> unwrap_secret(credential.secret)
    end
  end

  defp boundary_secret(_credential, _worker), do: {:error, :invalid_worker_credential}

  defp unwrap_secret(%Redacted{} = redacted) do
    case Redacted.value(redacted) do
      secret when is_binary(secret) and byte_size(secret) == 32 -> {:ok, secret}
      _invalid -> {:error, :invalid_worker_credential}
    end
  end

  defp unwrap_secret(_secret), do: {:error, :invalid_worker_credential}

  defp completion_value(%CompletionCredential{value: %Redacted{} = value}) do
    case Redacted.value(value) do
      completion when is_reference(completion) -> {:ok, completion}
      _invalid -> {:error, :invalid_completion}
    end
  end

  defp completion_value(_completion), do: {:error, :invalid_completion}

  defp unwrap_request_args(%Redacted{} = redacted) do
    args = Redacted.value(redacted)

    if is_list(args) and bounded_external_term?(args, @max_operation_bytes),
      do: {:ok, args},
      else: {:error, :invalid_operation}
  end

  defp unwrap_request_args(_args), do: {:error, :invalid_operation}

  defp unwrap_backend_opts(%Redacted{} = redacted) do
    opts = Redacted.value(redacted)

    if valid_backend_opts?(opts),
      do: {:ok, opts},
      else: {:error, :invalid_backend_opts}
  end

  defp unwrap_backend_opts(_opts), do: {:error, :invalid_backend_opts}

  defp valid_backend_opts?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and
      length(opts) <= @max_backend_opts_count and
      length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
      bounded_external_term?(opts, @max_backend_opts_bytes)
  end

  defp valid_backend_opts?(_opts), do: false

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
    exact_keys? =
      route |> Map.keys() |> MapSet.new() ==
        MapSet.new([:destination, :provider, :runtime, :model])

    values = [destination, provider, runtime, model]

    exact_keys? and Enum.all?(values, &bounded_utf8?(&1, @max_route_scalar_bytes)) and
      Enum.reduce(values, 0, &(byte_size(&1) + &2)) <= @max_route_bytes
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

  defp valid_operation_authenticator?(state, request, args) do
    secret = Redacted.value(state.worker_secret)

    authenticated?(
      request.authenticator,
      secret,
      :operation,
      operation_auth_fields(
        request.worker,
        request.coordinator,
        request.generation,
        request.operation_token,
        request.deadline_ms,
        request.operation,
        args
      )
    )
  end

  defp valid_ack_authenticator?(state, request) do
    case completion_value(request.completion) do
      {:ok, completion} ->
        authenticated?(
          request.authenticator,
          Redacted.value(state.worker_secret),
          :ack,
          ack_auth_fields(
            request.worker,
            request.coordinator,
            request.generation,
            request.operation_token,
            completion
          )
        )

      _invalid ->
        false
    end
  end

  defp valid_result_shape?(result) do
    is_pid(result.worker) and is_pid(result.coordinator) and is_reference(result.generation) and
      is_reference(result.operation_token) and result.operation in @operations and
      is_integer(result.completed_at)
  end

  defp valid_effect_request_shape?(request) do
    is_pid(request.worker) and is_pid(request.coordinator) and is_reference(request.generation) and
      is_reference(request.operation_token) and is_reference(request.effect_token) and
      is_atom(request.effect) and not is_nil(request.effect) and
      valid_route?(request.frozen_route) and
      is_reference(request.reply_alias)
  end

  defp operation_auth_fields(
         worker,
         coordinator,
         generation,
         operation_token,
         deadline_ms,
         operation,
         args
       ) do
    {worker, coordinator, generation, operation_token, deadline_ms, operation, args}
  end

  defp ack_auth_fields(worker, coordinator, generation, operation_token, completion) do
    {worker, coordinator, generation, operation_token, completion}
  end

  defp effect_reply_auth_fields(request, decision) do
    {request.worker, request.coordinator, request.generation, request.operation_token,
     request.effect_token, request.effect, request.frozen_route, request.reply_alias, decision}
  end

  defp result_auth_fields(result, completion) do
    {result.worker, result.coordinator, result.generation, result.operation_token,
     result.operation, result.completed_at, result.outcome, completion}
  end

  defp authenticate(secret, purpose, fields) do
    payload = :erlang.term_to_binary({__MODULE__, purpose, fields}, [:deterministic])
    :crypto.mac(:hmac, :sha256, secret, payload)
  end

  defp authenticated?(%Redacted{} = wrapped, secret, purpose, fields) do
    case Redacted.value(wrapped) do
      authenticator when is_binary(authenticator) and byte_size(authenticator) == 32 ->
        expected = authenticate(secret, purpose, fields)
        :crypto.hash_equals(expected, authenticator)

      _invalid ->
        false
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp authenticated?(_wrapped, _secret, _purpose, _fields), do: false

  defp bounded_utf8?(value, maximum) when is_binary(value) and byte_size(value) <= maximum,
    do: String.valid?(value)

  defp bounded_utf8?(_value, _maximum), do: false

  defp bounded_json?(value, maximum) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded) <= maximum
      {:error, _reason} -> false
    end
  rescue
    _exception -> false
  end

  defp bounded_external_term?(value, maximum) do
    :erlang.external_size(value) <= maximum
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
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

  defp safe_call(worker, request) do
    GenServer.call(worker, request, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :worker_unavailable}
  end

  defp arm_kill_timer(deadline_ms) do
    arm_relative_kill_timer(max(deadline_ms - now_ms(), 0))
  end

  defp arm_relative_kill_timer(timeout_ms) do
    case :timer.kill_after(timeout_ms, self()) do
      {:ok, timer} -> {:ok, timer}
      {:error, _reason} -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp cancel_kill_timer(timer) do
    _ = :timer.cancel(timer)
    :ok
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _ = Process.cancel_timer(timer)
    :ok
  end

  defp operation_context_key, do: {__MODULE__, :operation_context}
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
