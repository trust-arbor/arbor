defmodule Mix.Tasks.Arbor.LifecycleIdentity do
  @moduledoc """
  Pure decision core for the Arbor lifecycle mix tasks (start/stop/restart).

  Resolves the persisted managed-daemon identity instead of trusting a
  freshly re-detected host, verifies OS PIDs before signaling them, and
  serializes admission through an exclusive lifecycle lock. Every function
  here is pure — no `File`/`System`/`:rpc`/`Mix.shell()` calls — so tests
  exercise the full decision matrix without starting distribution, spawning
  a daemon, or signaling a real process. `Mix.Tasks.Arbor.Helpers` fetches
  the OS-facing facts (file reads, `kill -0`, `ps` argv) and hands them to
  these functions as plain data.
  """

  @max_metadata_bytes 4096
  @max_lock_bytes 512
  @node_re ~r/^arbor_dev_([0-9a-f]{4})@(.+)$/

  @type pid_check ::
          :no_such_process
          | {:verified_arbor, String.t()}
          | :present_not_arbor
          | :unverified

  @type metadata :: %{
          node: String.t(),
          host: String.t(),
          pid: pos_integer(),
          state: :starting | :ready
        }

  @type host_intent ::
          {:operator_relocation, String.t()}
          | {:internal_continuity, String.t()}
          | {:auto, String.t()}

  # --- Metadata (bounded, versioned) -----------------------------------

  @doc """
  Parses the runtime metadata JSON payload. Oversized, malformed JSON, or a
  payload with the wrong shape/types all collapse to `{:error, :malformed}` —
  a distinct, terminal state from `:absent` everywhere downstream.
  """
  @spec parse_metadata(binary()) :: {:ok, metadata()} | {:error, :malformed}
  def parse_metadata(raw) when is_binary(raw) and byte_size(raw) > @max_metadata_bytes do
    {:error, :malformed}
  end

  def parse_metadata(raw) when is_binary(raw) do
    with {:ok, decoded} <- Jason.decode(raw),
         %{"version" => 1, "node" => node, "host" => host, "pid" => pid, "state" => state} <-
           decoded,
         true <- is_binary(node) and node =~ @node_re,
         true <- is_binary(host) and host != "",
         true <- is_integer(pid) and pid > 0 and pid <= 4_194_304,
         true <- state in ["starting", "ready"] do
      {:ok, %{node: node, host: host, pid: pid, state: state_atom(state)}}
    else
      _ -> {:error, :malformed}
    end
  end

  def parse_metadata(_), do: {:error, :malformed}

  defp state_atom("starting"), do: :starting
  defp state_atom("ready"), do: :ready

  @doc "Encodes a metadata map back to its JSON wire form."
  @spec encode_metadata(metadata()) :: binary()
  def encode_metadata(%{node: node, host: host, pid: pid, state: state}) do
    Jason.encode!(%{version: 1, node: node, host: host, pid: pid, state: to_string(state)})
  end

  @doc """
  Cross-checks a syntactically-valid metadata record against this machine's
  own persisted `node_id`: the node field's hex prefix must equal
  `local_node_id`, and its `@host` suffix must equal the record's own `host`
  field exactly. A record that fails this — copied from another machine,
  hand-edited, or otherwise corrupted — is exactly as untrustworthy as a
  syntax error and is folded into the same `{:error, :malformed}` state.
  """
  @spec validate_metadata_identity(metadata(), String.t()) :: :ok | {:error, :malformed}
  def validate_metadata_identity(%{node: node, host: host}, local_node_id) do
    case Regex.run(@node_re, node) do
      [_, ^local_node_id, ^host] -> :ok
      _ -> {:error, :malformed}
    end
  end

  # --- Lifecycle lock ownership record ----------------------------------

  @spec parse_lock_owner(binary()) ::
          {:ok, %{pid: pos_integer(), token: String.t()}} | {:error, :malformed}
  def parse_lock_owner(raw) when is_binary(raw) and byte_size(raw) > @max_lock_bytes do
    {:error, :malformed}
  end

  def parse_lock_owner(raw) when is_binary(raw) do
    with {:ok, %{"pid" => pid, "token" => token}} <- Jason.decode(raw),
         true <- is_integer(pid) and pid > 0 and pid <= 4_194_304,
         true <- is_binary(token) and token != "" do
      {:ok, %{pid: pid, token: token}}
    else
      _ -> {:error, :malformed}
    end
  end

  def parse_lock_owner(_), do: {:error, :malformed}

  @spec encode_lock_owner(pos_integer(), String.t()) :: binary()
  def encode_lock_owner(pid, token), do: Jason.encode!(%{pid: pid, token: token})

  @doc """
  Decides the next step for an exclusive-lock acquisition attempt that lost
  the OS-atomic `mkdir` race (i.e. the lock directory already existed).
  `owner_pid_alive?` is `:unverified` when the owner record itself couldn't
  be read/parsed — that case always refuses rather than guessing. A verified
  dead owner is also refused: automatically removing a stale path cannot be
  made generation-safe with `mkdir`/`rename` alone because a delayed reclaimer
  could act on a newly acquired lock at the same path.
  """
  @spec decide_lock_step(%{
          owner: {:ok, map()} | {:error, :malformed} | :absent,
          owner_pid_alive?: boolean() | :unverified
        }) ::
          {:refuse, :held_by, pos_integer()}
          | {:refuse, :stale_lock, %{pid: pos_integer()}}
          | {:refuse, :ambiguous_lock, map()}
  def decide_lock_step(%{owner: {:ok, %{pid: pid}}, owner_pid_alive?: true}) do
    {:refuse, :held_by, pid}
  end

  def decide_lock_step(%{owner: {:ok, %{pid: pid}}, owner_pid_alive?: false}) do
    {:refuse, :stale_lock, %{pid: pid}}
  end

  def decide_lock_step(%{owner: {:ok, _}, owner_pid_alive?: :unverified}) do
    {:refuse, :ambiguous_lock, %{}}
  end

  def decide_lock_step(%{owner: {:error, :malformed}}), do: {:refuse, :ambiguous_lock, %{}}
  def decide_lock_step(%{owner: :absent}), do: {:refuse, :ambiguous_lock, %{}}

  # --- Exact argv identity check ----------------------------------------

  @doc """
  Parses a process's argv line for a bounded, exact `-name`/`--name` or
  `-sname`/`--sname` value (the Elixir launcher re-execs into `erl`, which
  reports the single-dash form in `ps` output — both forms are recognized).
  The value must match `arbor_dev_<hex>@<host>` with `<hex>` equal to this
  machine's own `local_node_id`. Never inspects or retains any
  `-cookie`/`--cookie` token or value.
  """
  @spec parse_arbor_node_from_argv(String.t(), String.t()) ::
          {:verified_arbor, String.t()} | :present_not_arbor
  def parse_arbor_node_from_argv(argv, local_node_id)
      when is_binary(argv) and is_binary(local_node_id) do
    tokens = String.split(argv)

    with value when is_binary(value) <- find_name_value(tokens),
         [_, ^local_node_id, _host] <- Regex.run(@node_re, value) do
      {:verified_arbor, value}
    else
      _ -> :present_not_arbor
    end
  end

  defp find_name_value(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [flag, value] when flag in ["-name", "--name", "-sname", "--sname"] -> value
      _ -> nil
    end)
  end

  # --- decide_start -------------------------------------------------------

  @doc """
  Admission decision for `mix arbor.start`. Assumes the lifecycle lock is
  already held by the caller (lock acquisition is a separate, outer
  concern — see `Mix.Tasks.Arbor.Helpers.with_lock/2`).
  """
  @spec decide_start(map()) :: {:proceed, String.t()} | {:refuse, atom(), map()}
  def decide_start(%{metadata: {:error, :malformed}}) do
    {:refuse, :malformed_metadata, %{}}
  end

  def decide_start(%{metadata: {:ok, meta}, metadata_pid_check: check, host_intent: intent}) do
    case check do
      {:verified_arbor, node} when node == meta.node ->
        {:refuse, :already_running, %{node: meta.node, pid: meta.pid}}

      {:verified_arbor, node} ->
        {:refuse, :node_identity_mismatch, %{expected: meta.node, observed: node}}

      :unverified ->
        {:refuse, :ambiguous_metadata_pid, %{}}

      _ ->
        {:proceed, host_from_intent(intent)}
    end
  end

  def decide_start(%{metadata: :absent, legacy_pid_present?: false, host_intent: intent}) do
    {:proceed, host_from_intent(intent)}
  end

  def decide_start(%{
        metadata: :absent,
        legacy_pid_present?: true,
        legacy_pid_check: check,
        host_intent: intent
      }) do
    case check do
      {:verified_arbor, node} -> {:refuse, :legacy_daemon_alive, %{node: node}}
      :unverified -> {:refuse, :ambiguous_legacy_state, %{}}
      _ -> {:proceed, host_from_intent(intent)}
    end
  end

  defp host_from_intent({_tag, host}), do: host

  # --- decide_stop ---------------------------------------------------------

  @doc """
  Stop decision. `node_ping` (optional, defaults to not attempted) only
  chooses between an RPC-graceful shutdown and a direct signal — it never
  factors into whether a PID is safe to signal, which is decided solely by
  the verified argv identity check.
  """
  @spec decide_stop(map()) ::
          {:stop_via_verified, String.t(), pos_integer(), boolean()}
          | {:already_stopped, [atom()]}
          | {:ambiguous, map()}
  def decide_stop(%{metadata: {:ok, meta}, metadata_pid_check: check} = facts) do
    case check do
      {:verified_arbor, node} when node == meta.node ->
        {:stop_via_verified, meta.node, meta.pid, Map.get(facts, :node_ping) == :pong}

      {:verified_arbor, _other} ->
        {:ambiguous, %{reason: :node_identity_mismatch}}

      :unverified ->
        {:ambiguous, %{reason: :ambiguous_metadata_pid}}

      _ ->
        {:already_stopped, [:pid_file, :metadata_file]}
    end
  end

  # Canonical metadata exists but is corrupted (unreadable, unparseable, or
  # fails local identity cross-validation) — distinct from :absent. This is
  # NOT the same as "nothing tracked": something IS canonically tracked,
  # its content just can't be trusted, so neither falling back to the
  # legacy PID file (which could signal an unrelated process, or miss a
  # still-live canonically-tracked daemon entirely) nor reporting
  # already_stopped (which would wrongly let Restart launch a replacement)
  # is safe. Ambiguity always preserves evidence: the metadata file is
  # never included in any cleanup list from this clause.
  def decide_stop(%{metadata: {:error, :malformed}}) do
    {:ambiguous, %{reason: :malformed_canonical_metadata}}
  end

  def decide_stop(%{metadata: :absent} = facts) do
    decide_stop_legacy(facts)
  end

  @doc """
  Decides whether a PID may be signaled, given a *freshly re-verified*
  `pid_check` (from `Helpers.verify_pid_as_arbor_node/1`, taken immediately
  before signaling) and the exact node identity expected at that PID. This
  is the sole admission gate behind `Helpers.signal_if_verified/3` — the
  single boundary in this codebase allowed to deliver `kill <pid>` — used
  both when Stop is about to terminate a daemon and when Start is cleaning
  up a just-spawned process whose launch tracking failed to publish. A PID
  obtained moments ago from our own spawn call is not exempt: the process
  could already have exited and had its PID reused by something else in
  that window. Only an exact argv match against `expected_node` is safe to
  signal; anything else must be preserved as evidence, never signaled.
  """
  @spec decide_signal_authorization(pid_check(), String.t()) ::
          :safe_to_signal | :preserve_evidence
  def decide_signal_authorization({:verified_arbor, node}, expected_node)
      when node == expected_node do
    :safe_to_signal
  end

  def decide_signal_authorization(_pid_check, _expected_node), do: :preserve_evidence

  @doc """
  Decides whether a graceful (RPC `:init.stop`) stop attempt may be treated
  as confirmed, from two independently-observed facts: whether the node
  stopped answering `net_adm:ping` (`node_unreachable?`) and whether the OS
  PID itself was confirmed to have exited (`os_exited?`). Distributed-Erlang
  unreachability alone (net_ticktime expiry, a partition, an EPMD hiccup) is
  NOT proof the OS process exited — only the conjunction of both confirms a
  clean stop; anything less must escalate to a re-verified SIGTERM rather
  than being cleaned up as if the daemon had already exited.
  """
  @spec decide_stop_confirmation(%{node_unreachable?: boolean(), os_exited?: boolean()}) ::
          :confirmed_stopped | :escalate_to_signal
  def decide_stop_confirmation(%{node_unreachable?: true, os_exited?: true}),
    do: :confirmed_stopped

  def decide_stop_confirmation(_facts), do: :escalate_to_signal

  defp decide_stop_legacy(%{legacy_pid_present?: false}), do: {:already_stopped, []}

  defp decide_stop_legacy(%{legacy_pid_present?: true, legacy_pid_check: check} = facts) do
    case check do
      {:verified_arbor, node} ->
        {:stop_via_verified, node, facts.legacy_pid, Map.get(facts, :node_ping) == :pong}

      :unverified ->
        {:ambiguous, %{reason: :ambiguous_legacy_state}}

      _ ->
        {:already_stopped, [:pid_file]}
    end
  end

  # --- decide_status -------------------------------------------------------

  @doc """
  Resolves the identity Status may display. Canonical metadata is
  authoritative whenever present: a dead/reused canonical PID means no
  managed process is currently verified, while a mismatched or unreadable
  identity is ambiguous. Legacy state is consulted only when canonical
  metadata is genuinely absent.
  """
  @spec decide_status(map()) ::
          {:managed, String.t(), pos_integer()} | :ambiguous | :none
  def decide_status(%{metadata: {:error, :malformed}}), do: :ambiguous

  def decide_status(%{metadata: {:ok, meta}, metadata_pid_check: check}) do
    case check do
      {:verified_arbor, node} when node == meta.node -> {:managed, node, meta.pid}
      {:verified_arbor, _other} -> :ambiguous
      :unverified -> :ambiguous
      _not_running -> :none
    end
  end

  def decide_status(%{metadata: :absent, legacy_pid_present?: false}), do: :none

  def decide_status(%{
        metadata: :absent,
        legacy_pid_present?: true,
        legacy_pid: pid,
        legacy_pid_check: check
      }) do
    case check do
      {:verified_arbor, node} -> {:managed, node, pid}
      :unverified -> :ambiguous
      _not_running -> :none
    end
  end
end
