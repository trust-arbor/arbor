defmodule Arbor.LLM.OAuth.Login.PendingStore do
  @moduledoc false

  # In-process, supervised, one-shot correlation-handle store for the OAuth
  # login coordinator (Arbor.LLM.OAuth.Login).
  #
  # Owns no ETS table -- state is a plain in-process map held by this
  # GenServer, so every read and write, from any process (including a future
  # caller distinct from whichever process started the flow), goes through a
  # single serialized GenServer.call to this one stable, supervised process.
  # This is what makes a cross-process handoff (start now, complete later,
  # possibly from a different process) correct, and what makes the
  # 256-entry cap and one-shot handle semantics race-free -- everything
  # happens inside one process's message queue, not across concurrently
  # racing callers.
  #
  # Handles are minted here (32 random bytes, url-safe base64, no padding --
  # always exactly 43 characters) and returned to callers opaquely; issue_* never
  # accepts a caller-supplied handle. take_*/1 is an atomic
  # remove-and-return: a forged (never-issued) handle and a replayed
  # (already-consumed) handle both resolve to {:error, :not_found}, and an
  # expired-but-unconsumed handle resolves to {:error, :expired} while still
  # being removed -- so a pending flow can only ever be completed once.
  #
  # Restart semantics: started :permanent under Arbor.LLM.Application's
  # :one_for_one supervisor. On crash it restarts with EMPTY state: every
  # in-flight (not-yet-completed) login handle is invalidated. This is
  # deliberate and safe -- it is a fail-closed loss of ephemeral,
  # short-lived, human-paced correlation state, never a fail-open condition,
  # and a caller simply restarts the login flow. No external dependency can
  # crash-loop this process (it performs only in-memory map operations); if
  # it did, the supervisor's default restart intensity escalates to the
  # application rather than being masked with a wider restart budget.

  use GenServer
  alias Arbor.Common.OAuth.AuthCode

  @max_entries 256
  @handle_bytes 32
  @sweep_interval_ms 60_000
  @handle_pattern ~r/\A[A-Za-z0-9_-]{43}\z/
  @openai_handle_ttl_max_s 86_400
  @xai_handle_ttl_max_s 86_400
  @openai_redirect_selectors [:port_1455, :port_1457]
  @xai_device_code_max_bytes 2_048
  @xai_interval_max_s 3_600
  @control_character_pattern ~r/[\x00-\x1F\x7F]/

  @type flow :: :openai | :xai
  @type openai_record :: %{
          deadline_ms: integer(),
          redirect_uri_selector: atom(),
          state: String.t(),
          code_verifier: String.t(),
          code_challenge: String.t()
        }
  @type xai_record :: %{
          deadline_ms: integer(),
          device_code: String.t(),
          interval: non_neg_integer()
        }
  @type openai_issuance :: %{handle: String.t(), state: String.t(), code_challenge: String.t()}
  @type xai_issuance :: %{handle: String.t()}
  @type record :: openai_record() | xai_record()

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{openai: %{}, xai: %{}}, name: name)
  end

  @doc "Issue an OpenAI pending-authorization record and return opaque one-shot metadata."
  @spec issue_openai(term(), term()) ::
          {:ok, openai_issuance()}
          | {:error,
             :too_many_pending_logins | :invalid_pending_deadline | :invalid_pending_value}
  def issue_openai(selector, deadline_ms) do
    with :ok <- validate_openai_selector(selector),
         :ok <- validate_openai_deadline(deadline_ms) do
      GenServer.call(__MODULE__, {:issue, :openai, {selector, deadline_ms}})
    end
  end

  @doc "One-shot consume the OpenAI pending record for `handle`."
  @spec take_openai(term()) :: {:ok, record()} | {:error, :not_found | :expired}
  def take_openai(handle), do: take(:openai, handle)

  @doc "Issue an xAI pending-device-authorization record and return an opaque one-shot handle."
  @spec issue_xai(term(), term(), term()) ::
          {:ok, xai_issuance()}
          | {:error,
             :too_many_pending_logins | :invalid_pending_deadline | :invalid_pending_value}
  def issue_xai(device_code, interval, deadline_ms) do
    with :ok <- validate_xai_deadline(deadline_ms),
         :ok <- validate_xai_device_code(device_code),
         :ok <- validate_xai_interval(interval) do
      GenServer.call(__MODULE__, {:issue, :xai, {device_code, interval, deadline_ms}})
    end
  end

  @doc "One-shot consume the xAI pending record for `handle`."
  @spec take_xai(term()) :: {:ok, record()} | {:error, :not_found | :expired}
  def take_xai(handle), do: take(:xai, handle)

  defp take(flow, handle) when is_binary(handle) do
    if valid_handle?(handle) do
      GenServer.call(__MODULE__, {:take, flow, handle})
    else
      {:error, :not_found}
    end
  end

  defp take(_flow, _handle), do: {:error, :not_found}

  @doc false
  @spec valid_handle?(term()) :: boolean()
  def valid_handle?(handle) when is_binary(handle) do
    byte_size(handle) == 43 and Regex.match?(@handle_pattern, handle)
  end

  def valid_handle?(_handle), do: false

  # -- GenServer callbacks -----------------------------------------------

  @impl true
  def init(state) do
    schedule_sweep()
    {:ok, state}
  end

  @impl true
  def handle_call({:issue, flow, params}, _from, state) when flow in [:openai, :xai] do
    now = monotonic_ms()
    swept = %{openai: sweep(state.openai, now), xai: sweep(state.xai, now)}
    total = map_size(swept.openai) + map_size(swept.xai)

    if total >= @max_entries do
      {:reply, {:error, :too_many_pending_logins}, swept}
    else
      handle = mint_handle(Map.fetch!(swept, flow))

      case flow do
        :openai ->
          {selector, deadline_ms} = params
          {verifier, challenge} = AuthCode.generate_pkce()
          state = AuthCode.generate_state()

          issued = %{
            handle: handle,
            state: state,
            code_challenge: challenge
          }

          record = %{
            redirect_uri_selector: selector,
            state: state,
            code_verifier: verifier,
            code_challenge: challenge,
            deadline_ms: deadline_ms
          }

          updated = Map.update!(swept, :openai, &Map.put(&1, handle, record))
          {:reply, {:ok, issued}, updated}

        :xai ->
          {device_code, interval, deadline_ms} = params

          record = %{
            device_code: device_code,
            interval: interval,
            deadline_ms: deadline_ms
          }

          updated = Map.update!(swept, :xai, &Map.put(&1, handle, record))
          {:reply, {:ok, %{handle: handle}}, updated}
      end
    end
  end

  def handle_call({:take, flow, handle}, _from, state) do
    {entry, remaining} = Map.pop(Map.fetch!(state, flow), handle)
    reply = take_reply(entry)
    {:reply, reply, Map.put(state, flow, remaining)}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :invalid_pending_request}, state}
  end

  @impl true
  def handle_cast(_request, state) do
    {:stop, :invalid_pending_request, state}
  end

  defp take_reply(nil), do: {:error, :not_found}

  defp take_reply(%{deadline_ms: deadline_ms} = entry) do
    if monotonic_ms() < deadline_ms, do: {:ok, entry}, else: {:error, :expired}
  end

  @impl true
  def handle_info(:sweep_expired, state) do
    now = monotonic_ms()
    next = %{openai: sweep(state.openai, now), xai: sweep(state.xai, now)}
    schedule_sweep()
    {:noreply, next}
  end

  # Redacts :state, :message, :reason, and :log -- whichever are present --
  # from ORDINARY :sys.get_status/1,2 output and from the crash report
  # logged on abnormal termination. Matches the documented
  # GenServer.format_status/1 pattern: same keys, transformed values.
  #
  # This is the currently conceded same-BEAM (T4) redaction boundary, not
  # an access-control boundary: any same-BEAM caller can still read the raw
  # state via :sys.get_state/1 (which bypasses this callback entirely),
  # attach a trace, or perform code injection. In particular,
  # :sys.log(pid, true) installs a debug ring that :sys.get_status/1 then
  # returns OUTSIDE this callback -- once enabled, it can hold prior
  # messages, replies, and states verbatim regardless of the redaction
  # below. Never enable :sys logging (or any other :sys debug handler) on
  # this process in production. See
  # .claude/skills/applied-learning-otp-ownership-cleanup.md
  # ("GenServer.format_status/1 cannot sanitize an explicitly enabled :sys
  # debug ring").
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason, :log] ->
        {key, "#Arbor.LLM.OAuth.Login.PendingStore<redacted>"}

      key_value ->
        key_value
    end)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep_expired, @sweep_interval_ms)

  defp sweep(map, now), do: Map.filter(map, fn {_handle, %{deadline_ms: dl}} -> dl >= now end)

  defp mint_handle(existing_map) do
    handle = Base.url_encode64(:crypto.strong_rand_bytes(@handle_bytes), padding: false)
    if Map.has_key?(existing_map, handle), do: mint_handle(existing_map), else: handle
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp validate_openai_selector(selector) when selector in @openai_redirect_selectors, do: :ok
  defp validate_openai_selector(_selector), do: {:error, :invalid_pending_value}

  defp validate_xai_device_code(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @xai_device_code_max_bytes and
         String.trim(value) != "" and not Regex.match?(@control_character_pattern, value) do
      :ok
    else
      {:error, :invalid_pending_value}
    end
  end

  defp validate_xai_device_code(_value), do: {:error, :invalid_pending_value}

  defp validate_xai_interval(interval)
       when is_integer(interval) and interval >= 1 and interval <= @xai_interval_max_s,
       do: :ok

  defp validate_xai_interval(_interval), do: {:error, :invalid_pending_value}

  defp validate_openai_deadline(deadline_ms) when is_integer(deadline_ms) do
    now = monotonic_ms()
    max = now + @openai_handle_ttl_max_s * 1000

    if deadline_ms > now and deadline_ms <= max do
      :ok
    else
      {:error, :invalid_pending_deadline}
    end
  end

  defp validate_openai_deadline(_deadline_ms), do: {:error, :invalid_pending_deadline}

  defp validate_xai_deadline(deadline_ms) when is_integer(deadline_ms) do
    now = monotonic_ms()
    max = now + @xai_handle_ttl_max_s * 1000

    if deadline_ms > now and deadline_ms <= max do
      :ok
    else
      {:error, :invalid_pending_deadline}
    end
  end

  defp validate_xai_deadline(_deadline_ms), do: {:error, :invalid_pending_deadline}
end
