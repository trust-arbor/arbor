defmodule Arbor.Voice do
  @moduledoc """
  Public facade for the voice-first interface (VP-04D2B lifecycle + VP-04E1
  durable text turns + VP-04E2 speakable-only output).

  Exposes a tuple-keyed session lifecycle and message-driven text turns —
  `start_session/3`, `session_status/1`, `stop_session/1`, and `text_turn/3`.
  No public operation accepts or returns a pid. Optional speech output is an
  arity-1 callback seam only; no device transport or public output API.
  """

  alias Arbor.Voice.Config
  alias Arbor.Voice.Session
  alias Arbor.Voice.SessionSupervisor

  @id_max_bytes 256
  @user_text_max_bytes 8192

  @allowed_opts [
    :comms,
    :engagement_store,
    :ledger,
    :ledger_opts,
    :resource_owner,
    :resource_owner_opts,
    :backend,
    :backend_opts,
    :signals,
    :wall_clock,
    :monotonic_clock,
    :session_budget_ms,
    :daily_budget_ms,
    :transcript_recorder,
    :transcript_opts,
    :speakable,
    :speech_output
  ]

  @transcript_opts_allowlist [:persistence]
  @speakable_exports [render: 2, tts_guard!: 1]

  @type session_key :: {String.t(), String.t()}

  @type status_map :: %{
          state: :ready,
          user_id: String.t(),
          agent_id: String.t(),
          backend: atom(),
          mode: :cloud | :local,
          reserved_ms: pos_integer()
        }

  @doc """
  Start a supervised voice session for `{user_id, agent_id}`.

  Returns `{:ok, {user_id, agent_id}}` on success. Duplicate starts return
  `{:error, :already_started}`. Never returns a pid.
  """
  @spec start_session(String.t(), String.t(), keyword()) ::
          {:ok, session_key()} | {:error, atom()}
  def start_session(user_id, agent_id, opts \\ []) do
    with :ok <- validate_id(user_id, :user_id),
         :ok <- validate_id(agent_id, :agent_id),
         {:ok, config} <- build_config(user_id, agent_id, opts) do
      case SessionSupervisor.start_session(config) do
        {:ok, _pid} ->
          {:ok, {user_id, agent_id}}

        {:error, :already_started} ->
          {:error, :already_started}

        {:error, reason} ->
          {:error, public_error(reason)}
      end
    end
  end

  @doc """
  Return a redacted, bounded status map for a live session.

  Contains only lifecycle state, tuple identity, backend, mode, and reserved
  duration. Never exposes pids, engagement/reservation ids, handles, credentials,
  or raw errors.
  """
  @spec session_status(session_key()) :: {:ok, status_map()} | {:error, atom()}
  def session_status({user_id, agent_id} = key)
      when is_binary(user_id) and is_binary(agent_id) do
    with :ok <- validate_id(user_id, :user_id),
         :ok <- validate_id(agent_id, :agent_id),
         {:ok, pid} <- lookup(key) do
      Session.status(pid)
    else
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def session_status(_), do: {:error, :invalid_session_key}

  @doc """
  Stop a live voice session by tuple key.

  Settles the retained budget reservation, closes the backend via ResourceOwner,
  emits a bounded `:voice/:stop` signal, and terminates the temporary Session
  child. Never accepts or returns a pid.
  """
  @spec stop_session(session_key()) :: :ok | {:error, atom()}
  def stop_session({user_id, agent_id} = key)
      when is_binary(user_id) and is_binary(agent_id) do
    with :ok <- validate_id(user_id, :user_id),
         :ok <- validate_id(agent_id, :agent_id),
         {:ok, pid} <- lookup(key) do
      Session.stop(pid)
    else
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def stop_session(_), do: {:error, :invalid_session_key}

  @doc """
  Run one durable text turn against a live session keyed by `{user_id, agent_id}`.

  Returns `{:ok, raw_assistant_text}` only after the complete raw user/assistant
  pair is durably recorded. Never accepts or returns a Session pid.

  ## Errors

  * `:not_found` — no live session for the tuple
  * `:busy` — another turn is already in flight
  * `:invalid_user_text` — blank, non-UTF-8, oversized, or non-binary text
  * `:turn_failed` — backend/protocol failure (normalized)
  * `:transcript_record_failed` — durable write failed before public success
  * `:session_stopped` — normal stop while a turn was in flight
  * `:budget_exhausted` — hard session timer fired during the turn
  """
  @spec text_turn(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def text_turn(user_id, agent_id, user_text) do
    with :ok <- validate_id(user_id, :user_id),
         :ok <- validate_id(agent_id, :agent_id),
         :ok <- validate_user_text(user_text),
         {:ok, pid} <- lookup({user_id, agent_id}) do
      case Session.text_turn(pid, user_text) do
        {:ok, raw} when is_binary(raw) -> {:ok, raw}
        {:error, reason} -> {:error, public_turn_error(reason)}
        _other -> {:error, :turn_failed}
      end
    else
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Config construction — closed, duplicate-free option list
  # ---------------------------------------------------------------------------

  defp build_config(user_id, agent_id, opts) do
    with :ok <- validate_opts(opts),
         {:ok, daily_ms} <- resolve_daily_budget_ms(opts),
         {:ok, session_ms} <- resolve_session_budget_ms(opts, daily_ms),
         {:ok, backend} <- resolve_backend(opts),
         {:ok, backend_opts} <- resolve_backend_opts(opts),
         {:ok, ledger_opts} <- resolve_ledger_opts(opts),
         {:ok, resource_owner_opts} <- resolve_resource_owner_opts(opts),
         {:ok, transcript_opts} <- resolve_transcript_opts(opts),
         {:ok, wall_clock} <- resolve_clock(opts, :wall_clock, &default_wall_clock/0),
         {:ok, mono_clock} <- resolve_clock(opts, :monotonic_clock, &default_monotonic_clock/0),
         {:ok, comms} <- resolve_module(opts, :comms, Arbor.Comms),
         {:ok, ledger} <- resolve_module(opts, :ledger, Arbor.Voice.BudgetLedger),
         {:ok, resource_owner} <-
           resolve_module(opts, :resource_owner, Arbor.Voice.ResourceOwner),
         {:ok, signals} <- resolve_module(opts, :signals, Arbor.Signals),
         {:ok, transcript_recorder} <-
           resolve_module(opts, :transcript_recorder, Arbor.Voice.TranscriptRecorder),
         {:ok, speakable} <- resolve_speakable(opts),
         {:ok, speech_output} <- resolve_speech_output(opts),
         :ok <- validate_optional_module(opts, :engagement_store) do
      {:ok,
       %{
         session_key: {user_id, agent_id},
         user_id: user_id,
         agent_id: agent_id,
         comms: comms,
         engagement_store: Keyword.get(opts, :engagement_store),
         ledger: ledger,
         ledger_opts: ledger_opts,
         resource_owner: resource_owner,
         resource_owner_opts: resource_owner_opts,
         backend: backend,
         backend_opts: backend_opts,
         signals: signals,
         wall_clock: wall_clock,
         monotonic_clock: mono_clock,
         session_budget_ms: session_ms,
         daily_budget_ms: daily_ms,
         transcript_recorder: transcript_recorder,
         transcript_opts: transcript_opts,
         speakable: speakable,
         speech_output: speech_output
       }}
    end
  end

  defp resolve_module(opts, key, default) do
    case Keyword.fetch(opts, key) do
      :error ->
        {:ok, default}

      {:ok, mod} when is_atom(mod) and not is_nil(mod) ->
        {:ok, mod}

      {:ok, _} ->
        {:error, :invalid_opts}
    end
  end

  # Closed Speakable seam: default Arbor.Voice.Speakable; module must export
  # render/2 and tts_guard!/1. Use catch-safe module_info(:exports) so
  # compiled-but-not-yet-loaded modules are accepted (ResourceOwner pattern).
  defp resolve_speakable(opts) do
    case Keyword.fetch(opts, :speakable) do
      :error ->
        validate_speakable_module(Arbor.Voice.Speakable)

      {:ok, mod} when is_atom(mod) and not is_nil(mod) ->
        validate_speakable_module(mod)

      {:ok, _} ->
        {:error, :invalid_opts}
    end
  end

  defp validate_speakable_module(module) do
    try do
      exports = module.module_info(:exports)

      if Enum.all?(@speakable_exports, &(&1 in exports)) do
        {:ok, module}
      else
        {:error, :invalid_opts}
      end
    rescue
      _ ->
        {:error, :invalid_opts}
    catch
      _kind, _reason ->
        {:error, :invalid_opts}
    end
  end

  # nil (default) disables speech output; only an arity-1 fun is accepted.
  # The callback owns any external-I/O timeout; Session never wraps it in Task.
  defp resolve_speech_output(opts) do
    case Keyword.fetch(opts, :speech_output) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, fun} when is_function(fun, 1) ->
        {:ok, fun}

      {:ok, _} ->
        {:error, :invalid_opts}
    end
  end

  defp validate_optional_module(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, mod} when is_atom(mod) -> :ok
      {:ok, _} -> {:error, :invalid_opts}
    end
  end

  defp validate_opts(opts) do
    cond do
      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:error, :invalid_opts}

      has_duplicate_keys?(opts) ->
        {:error, :invalid_opts}

      true ->
        case Enum.reject(Keyword.keys(opts), &(&1 in @allowed_opts)) do
          [] -> :ok
          _unknown -> {:error, :invalid_opts}
        end
    end
  end

  defp has_duplicate_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) != length(Enum.uniq(keys))
  end

  defp validate_id(v, field) when is_binary(v) do
    cond do
      byte_size(v) > @id_max_bytes -> {:error, invalid_id_atom(field)}
      not String.valid?(v) -> {:error, invalid_id_atom(field)}
      String.trim(v) == "" -> {:error, invalid_id_atom(field)}
      true -> :ok
    end
  end

  defp validate_id(_v, field), do: {:error, invalid_id_atom(field)}

  defp invalid_id_atom(:user_id), do: :invalid_user_id
  defp invalid_id_atom(:agent_id), do: :invalid_agent_id

  defp resolve_daily_budget_ms(opts) do
    case Keyword.fetch(opts, :daily_budget_ms) do
      :error ->
        case Config.daily_budget_ms() do
          {:ok, ms} -> {:ok, ms}
          {:error, _} -> {:error, :invalid_config}
        end

      {:ok, v} ->
        Config.validate_daily_budget_ms(v)
        |> map_config_error()
    end
  end

  defp resolve_session_budget_ms(opts, daily_ms) do
    case Keyword.fetch(opts, :session_budget_ms) do
      :error ->
        case Keyword.fetch(opts, :daily_budget_ms) do
          {:ok, _} ->
            # Explicit daily only — session defaults to daily.
            Config.validate_session_budget_ms(daily_ms, daily_ms) |> map_config_error()

          :error ->
            case Config.session_budget_ms() do
              {:ok, ms} -> {:ok, ms}
              {:error, _} -> {:error, :invalid_config}
            end
        end

      {:ok, v} ->
        Config.validate_session_budget_ms(v, daily_ms) |> map_config_error()
    end
  end

  defp map_config_error({:ok, v}), do: {:ok, v}
  defp map_config_error({:error, _}), do: {:error, :invalid_config}

  defp resolve_backend(opts) do
    case Keyword.fetch(opts, :backend) do
      :error ->
        backend = Config.backend_module()

        if is_atom(backend) and not is_nil(backend) do
          {:ok, backend}
        else
          {:error, :invalid_config}
        end

      {:ok, backend} when is_atom(backend) and not is_nil(backend) ->
        {:ok, backend}

      {:ok, _} ->
        {:error, :invalid_opts}
    end
  end

  defp resolve_backend_opts(opts) do
    case Keyword.fetch(opts, :backend_opts) do
      :error ->
        {:ok, []}

      {:ok, backend_opts} when is_list(backend_opts) ->
        if Keyword.keyword?(backend_opts) and not has_duplicate_keys?(backend_opts) do
          {:ok, backend_opts}
        else
          {:error, :invalid_opts}
        end

      {:ok, _} ->
        {:error, :invalid_opts}
    end
  end

  defp resolve_ledger_opts(opts) do
    case Keyword.fetch(opts, :ledger_opts) do
      :error ->
        {:ok, []}

      {:ok, ledger_opts} when is_list(ledger_opts) ->
        if Keyword.keyword?(ledger_opts) and not has_duplicate_keys?(ledger_opts) do
          {:ok, ledger_opts}
        else
          {:error, :invalid_opts}
        end

      {:ok, _} ->
        {:error, :invalid_opts}
    end
  end

  defp resolve_resource_owner_opts(opts) do
    case Keyword.fetch(opts, :resource_owner_opts) do
      :error ->
        {:ok, []}

      {:ok, owner_opts} when is_list(owner_opts) ->
        if Keyword.keyword?(owner_opts) and not has_duplicate_keys?(owner_opts) do
          {:ok, owner_opts}
        else
          {:error, :invalid_opts}
        end

      {:ok, _} ->
        {:error, :invalid_opts}
    end
  end

  # Closed, duplicate-free, limited to :persistence. Session source-owns
  # recorder options comms:, backend:, and mode: — callers cannot override them.
  defp resolve_transcript_opts(opts) do
    case Keyword.fetch(opts, :transcript_opts) do
      :error ->
        {:ok, []}

      {:ok, t_opts} when is_list(t_opts) ->
        if Keyword.keyword?(t_opts) and not has_duplicate_keys?(t_opts) do
          case Enum.reject(Keyword.keys(t_opts), &(&1 in @transcript_opts_allowlist)) do
            [] -> {:ok, t_opts}
            _unknown -> {:error, :invalid_opts}
          end
        else
          {:error, :invalid_opts}
        end

      {:ok, _} ->
        {:error, :invalid_opts}
    end
  end

  defp resolve_clock(opts, key, default_fun) do
    case Keyword.fetch(opts, key) do
      :error ->
        {:ok, default_fun}

      {:ok, fun} when is_function(fun, 0) ->
        {:ok, fun}

      {:ok, _} ->
        {:error, :invalid_opts}
    end
  end

  defp default_wall_clock, do: DateTime.utc_now()
  defp default_monotonic_clock, do: System.monotonic_time(:millisecond)

  # Byte size before UTF-8 or trim scans (DoS-safe admission).
  defp validate_user_text(text) when is_binary(text) do
    cond do
      byte_size(text) > @user_text_max_bytes -> {:error, :invalid_user_text}
      not String.valid?(text) -> {:error, :invalid_user_text}
      String.trim(text) == "" -> {:error, :invalid_user_text}
      true -> :ok
    end
  end

  defp validate_user_text(_), do: {:error, :invalid_user_text}

  defp lookup(key) do
    case Registry.lookup(Arbor.Voice.Registry, key) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      [] -> :error
    end
  end

  # Collapse collaborator failures into stable public atoms — never raw terms.
  defp public_error(:already_started), do: :already_started
  defp public_error(:budget_exhausted), do: :budget_exhausted
  defp public_error(:engagement_unavailable), do: :engagement_unavailable
  defp public_error(:invalid_config), do: :invalid_config
  defp public_error(:invalid_opts), do: :invalid_opts
  defp public_error(:invalid_user_id), do: :invalid_user_id
  defp public_error(:invalid_agent_id), do: :invalid_agent_id
  defp public_error(:start_failed), do: :start_failed
  defp public_error(:not_found), do: :not_found
  defp public_error({:shutdown, reason}), do: public_error(reason)
  defp public_error({:error, reason}), do: public_error(reason)
  defp public_error(_), do: :start_failed

  defp public_turn_error(:not_found), do: :not_found
  defp public_turn_error(:busy), do: :busy
  defp public_turn_error(:invalid_user_text), do: :invalid_user_text
  defp public_turn_error(:turn_failed), do: :turn_failed
  defp public_turn_error(:transcript_record_failed), do: :transcript_record_failed
  defp public_turn_error(:session_stopped), do: :session_stopped
  defp public_turn_error(:budget_exhausted), do: :budget_exhausted
  defp public_turn_error({:error, reason}), do: public_turn_error(reason)
  defp public_turn_error(_), do: :turn_failed
end
