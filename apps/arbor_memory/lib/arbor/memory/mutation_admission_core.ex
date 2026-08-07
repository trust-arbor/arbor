defmodule Arbor.Memory.MutationAdmissionCore do
  @moduledoc """
  Pure open→draining→destroyed gate decisions for Memory mutation admission
  (VP-05D2C3I1A). No process, clock, random, Persistence, or IO.
  """

  @hash_re ~r/^[0-9a-f]{64}$/
  @gates ~w(open draining destroyed)
  @max_gate_gen 1_000_000_000
  @max_fence_gen 1_000_000_000
  @default_max_active_roots 64
  @default_max_record_encoded_bytes 65_536
  @absolute_max_roots 256

  @type root :: %{
          lineage_hash: String.t(),
          node_fp: String.t(),
          runtime_fp: String.t()
        }

  @type state :: %{
          gate: :open | :draining | :destroyed,
          gate_gen: pos_integer(),
          roots: %{optional(String.t()) => root()},
          fence_gen: non_neg_integer(),
          fence_hash: String.t() | nil
        }

  @type bounds :: %{
          optional(:max_active_roots) => pos_integer(),
          optional(:max_record_encoded_bytes) => pos_integer()
        }

  @doc "Default validated bounds used when callers omit them."
  @spec default_bounds() :: %{
          max_active_roots: pos_integer(),
          max_record_encoded_bytes: pos_integer()
        }
  def default_bounds do
    %{
      max_active_roots: @default_max_active_roots,
      max_record_encoded_bytes: @default_max_record_encoded_bytes
    }
  end

  @doc """
  Construct: decode durable data or bootstrap open/empty.

  Validates semantic cross-field invariants and configured bounds:
  - destroyed requires zero roots and a current fence
  - open cannot carry a fence
  - draining with a fence implies zero roots
  - each root's lineage_hash equals its lease-hash key
  - active roots and encoded bytes respect bounds
  """
  @spec new(map() | nil, bounds()) :: {:ok, state()} | {:error, :invalid_request}
  def new(data, bounds \\ %{})

  # Bootstrap empty open state — still normalize/reject invalid bounds.
  def new(nil, bounds) do
    case normalize_bounds(bounds) do
      {:ok, _b} ->
        {:ok,
         %{
           gate: :open,
           gate_gen: 1,
           roots: %{},
           fence_gen: 0,
           fence_hash: nil
         }}

      :error ->
        {:error, :invalid_request}
    end
  end

  def new(data, bounds) when is_map(data) and is_map(bounds) do
    with {:ok, b} <- normalize_bounds(bounds),
         :ok <- ensure_encoded_size(data, b.max_record_encoded_bytes),
         {:ok, state} <- decode(data, b),
         :ok <- validate_invariants(state, b) do
      {:ok, state}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def new(_, _), do: {:error, :invalid_request}

  @doc "Convert state to JSON-clean string-keyed map for Record.data."
  @spec to_data(state()) :: map()
  def to_data(%{} = state) do
    roots =
      Map.new(state.roots, fn {hash, root} ->
        {hash,
         %{
           "lineage_hash" => root.lineage_hash,
           "node_fp" => root.node_fp,
           "runtime_fp" => root.runtime_fp
         }}
      end)

    %{
      "v" => 1,
      "gate" => Atom.to_string(state.gate),
      "gate_gen" => state.gate_gen,
      "roots" => roots,
      "fence_gen" => state.fence_gen,
      "fence_hash" => state.fence_hash
    }
  end

  @doc "Admit a new root lineage while open. Lineage hash must equal lease hash."
  @spec acquire_new(state(), String.t(), String.t(), String.t(), String.t(), bounds()) ::
          {:ok, state()} | {:error, atom()}
  def acquire_new(state, lease_hash, lineage_hash, node_fp, runtime_fp, bounds \\ %{})

  def acquire_new(%{gate: :destroyed}, _, _, _, _, _), do: {:error, :destroyed}
  def acquire_new(%{gate: :draining}, _, _, _, _, _), do: {:error, :draining}

  def acquire_new(%{gate: :open} = state, lease_hash, lineage_hash, node_fp, runtime_fp, bounds) do
    with {:ok, b} <- normalize_bounds(bounds) do
      cond do
        not valid_hash?(lease_hash) ->
          {:error, :invalid_request}

        not valid_hash?(lineage_hash) ->
          {:error, :invalid_request}

        lineage_hash != lease_hash ->
          {:error, :invalid_request}

        not valid_fp?(node_fp) ->
          {:error, :invalid_request}

        not valid_hash?(runtime_fp) ->
          {:error, :invalid_request}

        Map.has_key?(state.roots, lease_hash) ->
          {:error, :invalid_request}

        map_size(state.roots) >= b.max_active_roots ->
          {:error, :capacity_exceeded}

        true ->
          root = %{
            lineage_hash: lineage_hash,
            node_fp: node_fp,
            runtime_fp: runtime_fp
          }

          new_state = %{state | roots: Map.put(state.roots, lease_hash, root)}

          case ensure_encoded_size(to_data(new_state), b.max_record_encoded_bytes) do
            :ok -> {:ok, new_state}
            :error -> {:error, :capacity_exceeded}
          end
      end
    end
  end

  def acquire_new(_, _, _, _, _, _), do: {:error, :invalid_request}

  @doc "Exact reentry: root present and gate not destroyed."
  @spec assert_reenterable(state(), String.t()) :: :ok | {:error, atom()}
  def assert_reenterable(%{gate: :destroyed}, _lease_hash), do: {:error, :destroyed}

  def assert_reenterable(%{gate: gate} = state, lease_hash)
      when gate in [:open, :draining] do
    cond do
      not valid_hash?(lease_hash) -> {:error, :invalid_lease}
      Map.has_key?(state.roots, lease_hash) -> :ok
      true -> {:error, :invalid_lease}
    end
  end

  def assert_reenterable(_, _), do: {:error, :invalid_request}

  @doc "open→draining (bumps gate_gen). Already draining is a no-op. Does not touch roots."
  @spec begin_drain(state()) :: {:ok, state()} | {:error, atom()}
  def begin_drain(%{gate: :destroyed}), do: {:error, :destroyed}
  def begin_drain(%{gate: :draining} = state), do: {:ok, state}

  def begin_drain(%{gate: :open, gate_gen: gen} = state) when is_integer(gen) and gen > 0 do
    next = gen + 1

    if next <= @max_gate_gen do
      {:ok, %{state | gate: :draining, gate_gen: next}}
    else
      {:error, :invalid_request}
    end
  end

  def begin_drain(_), do: {:error, :invalid_request}

  @doc "Issue or rotate fence while draining with zero roots."
  @spec issue_fence(state(), String.t()) ::
          {:ok, state(), %{fence_gen: pos_integer()}} | {:error, atom()}
  def issue_fence(%{gate: :destroyed}, _), do: {:error, :destroyed}
  def issue_fence(%{gate: :open}, _), do: {:error, :not_drained}

  def issue_fence(%{gate: :draining, roots: roots} = state, fence_hash) do
    cond do
      map_size(roots) != 0 ->
        {:error, :not_drained}

      not valid_hash?(fence_hash) ->
        {:error, :invalid_request}

      true ->
        next_gen = state.fence_gen + 1

        if next_gen <= @max_fence_gen do
          new_state = %{state | fence_gen: next_gen, fence_hash: fence_hash}
          {:ok, new_state, %{fence_gen: next_gen}}
        else
          {:error, :invalid_request}
        end
    end
  end

  def issue_fence(_, _), do: {:error, :invalid_request}

  @doc """
  Terminal destroy on exact current fence + empty roots.
  Exact same fence when already destroyed is idempotent only if roots remain zero.
  """
  @spec mark_destroyed(state(), String.t(), pos_integer()) ::
          {:ok, state(), :committed | :idempotent} | {:error, atom()}
  def mark_destroyed(
        %{gate: :destroyed, fence_hash: hash, fence_gen: gen, roots: roots} = state,
        fence_hash,
        fence_gen
      )
      when is_binary(fence_hash) and is_integer(fence_gen) do
    cond do
      map_size(roots) != 0 ->
        {:error, :invalid_request}

      hash == fence_hash and gen == fence_gen ->
        {:ok, state, :idempotent}

      true ->
        {:error, :stale_fence}
    end
  end

  def mark_destroyed(%{gate: :open}, _hash, _gen), do: {:error, :not_drained}

  def mark_destroyed(%{gate: :draining, roots: roots} = state, fence_hash, fence_gen) do
    cond do
      map_size(roots) != 0 ->
        {:error, :not_drained}

      state.fence_gen == 0 or is_nil(state.fence_hash) ->
        {:error, :invalid_fence}

      not valid_hash?(fence_hash) or not is_integer(fence_gen) or fence_gen < 1 ->
        {:error, :invalid_fence}

      state.fence_hash != fence_hash or state.fence_gen != fence_gen ->
        {:error, :stale_fence}

      true ->
        next_gen = state.gate_gen + 1

        if next_gen <= @max_gate_gen do
          {:ok, %{state | gate: :destroyed, gate_gen: next_gen}, :committed}
        else
          {:error, :invalid_request}
        end
    end
  end

  def mark_destroyed(_, _, _), do: {:error, :invalid_request}

  @doc "Remove one durable root by lease hash."
  @spec release_root(state(), String.t()) :: {:ok, state()} | {:error, atom()}
  def release_root(%{gate: :destroyed}, _), do: {:error, :destroyed}

  def release_root(%{gate: gate} = state, lease_hash) when gate in [:open, :draining] do
    cond do
      not valid_hash?(lease_hash) ->
        {:error, :invalid_lease}

      not Map.has_key?(state.roots, lease_hash) ->
        {:error, :stale_lease}

      true ->
        {:ok, %{state | roots: Map.delete(state.roots, lease_hash)}}
    end
  end

  def release_root(_, _), do: {:error, :invalid_request}

  @doc "Move-only handoff: same root key, refresh fingerprints."
  @spec handoff_root(state(), String.t(), String.t(), String.t()) ::
          {:ok, state()} | {:error, atom()}
  def handoff_root(%{gate: :destroyed}, _, _, _), do: {:error, :destroyed}

  def handoff_root(%{gate: gate} = state, lease_hash, node_fp, runtime_fp)
      when gate in [:open, :draining] do
    cond do
      not valid_hash?(lease_hash) ->
        {:error, :invalid_lease}

      not valid_fp?(node_fp) ->
        {:error, :invalid_request}

      not valid_hash?(runtime_fp) ->
        {:error, :invalid_request}

      not Map.has_key?(state.roots, lease_hash) ->
        {:error, :stale_lease}

      true ->
        root = state.roots[lease_hash]

        updated = %{
          root
          | node_fp: node_fp,
            runtime_fp: runtime_fp
        }

        {:ok, %{state | roots: Map.put(state.roots, lease_hash, updated)}}
    end
  end

  def handoff_root(_, _, _, _), do: {:error, :invalid_request}

  @doc """
  Conservatively drop roots proven prior-local to this node under a prior runtime.
  Ambiguous/foreign/current-runtime roots remain.
  """
  @spec reconcile(state(), String.t(), String.t()) :: {:ok, state()}
  def reconcile(%{} = state, current_node_fp, current_runtime_fp)
      when is_binary(current_node_fp) and is_binary(current_runtime_fp) do
    if current_node_fp == "ambiguous" or not valid_hash?(current_runtime_fp) do
      {:ok, state}
    else
      kept =
        state.roots
        |> Enum.reject(fn {_hash, root} ->
          root.node_fp == current_node_fp and root.runtime_fp != current_runtime_fp and
            valid_hash?(root.node_fp) and valid_hash?(root.runtime_fp)
        end)
        |> Map.new()

      {:ok, %{state | roots: kept}}
    end
  end

  def reconcile(state, _, _), do: {:ok, state}

  @doc "Redacted status view — no hashes/tokens/fps."
  @spec status_view(state()) :: map()
  def status_view(%{} = state) do
    %{
      gate: state.gate,
      gate_generation: state.gate_gen,
      active_roots: map_size(state.roots)
    }
  end

  @doc false
  @spec valid_hash?(term()) :: boolean()
  def valid_hash?(v) when is_binary(v),
    do: byte_size(v) == 64 and Regex.match?(@hash_re, v)

  def valid_hash?(_), do: false

  @doc false
  @spec valid_fp?(term()) :: boolean()
  def valid_fp?("ambiguous"), do: true
  def valid_fp?(v), do: valid_hash?(v)

  defp normalize_bounds(bounds) when is_map(bounds) do
    max_roots = Map.get(bounds, :max_active_roots, @default_max_active_roots)
    max_bytes = Map.get(bounds, :max_record_encoded_bytes, @default_max_record_encoded_bytes)

    if is_integer(max_roots) and max_roots > 0 and max_roots <= @absolute_max_roots and
         is_integer(max_bytes) and max_bytes > 0 and
         max_bytes <= @default_max_record_encoded_bytes do
      {:ok, %{max_active_roots: max_roots, max_record_encoded_bytes: max_bytes}}
    else
      :error
    end
  end

  defp normalize_bounds(_), do: :error

  defp validate_invariants(state, bounds) do
    cond do
      map_size(state.roots) > bounds.max_active_roots ->
        :error

      state.gate == :open and (state.fence_gen != 0 or not is_nil(state.fence_hash)) ->
        :error

      state.gate == :destroyed and
          (map_size(state.roots) != 0 or state.fence_gen < 1 or is_nil(state.fence_hash)) ->
        :error

      state.gate == :draining and state.fence_gen > 0 and map_size(state.roots) != 0 ->
        :error

      state.fence_gen > 0 and is_nil(state.fence_hash) ->
        :error

      state.fence_gen == 0 and not is_nil(state.fence_hash) ->
        :error

      not roots_lineage_ok?(state.roots) ->
        :error

      true ->
        :ok
    end
  end

  defp roots_lineage_ok?(roots) do
    Enum.all?(roots, fn {lease_hash, root} ->
      root.lineage_hash == lease_hash
    end)
  end

  defp decode(data, bounds) when is_map(data) do
    with :ok <- ensure_closed_keys(data),
         {:ok, 1} <- fetch_v(data),
         {:ok, gate} <- fetch_gate(data),
         {:ok, gate_gen} <- fetch_pos_int(data, "gate_gen", @max_gate_gen),
         {:ok, roots} <- fetch_roots(data, bounds.max_active_roots),
         {:ok, fence_gen} <- fetch_non_neg_int(data, "fence_gen", @max_fence_gen),
         {:ok, fence_hash} <- fetch_fence_hash(data, fence_gen) do
      {:ok,
       %{
         gate: gate,
         gate_gen: gate_gen,
         roots: roots,
         fence_gen: fence_gen,
         fence_hash: fence_hash
       }}
    else
      _ -> :error
    end
  end

  defp decode(_, _), do: :error

  defp ensure_closed_keys(data) do
    allowed = MapSet.new(["v", "gate", "gate_gen", "roots", "fence_gen", "fence_hash"])

    if Enum.all?(Map.keys(data), &is_binary/1) and
         Enum.all?(Map.keys(data), &MapSet.member?(allowed, &1)) do
      :ok
    else
      :error
    end
  end

  defp fetch_v(%{"v" => 1}), do: {:ok, 1}
  defp fetch_v(_), do: :error

  defp fetch_gate(%{"gate" => gate}) when gate in @gates,
    do: {:ok, String.to_existing_atom(gate)}

  defp fetch_gate(_), do: :error

  defp fetch_pos_int(data, key, max) do
    case Map.fetch(data, key) do
      {:ok, n} when is_integer(n) and n > 0 and n <= max -> {:ok, n}
      _ -> :error
    end
  end

  defp fetch_non_neg_int(data, key, max) do
    case Map.fetch(data, key) do
      {:ok, n} when is_integer(n) and n >= 0 and n <= max -> {:ok, n}
      _ -> :error
    end
  end

  defp fetch_roots(%{"roots" => roots}, max_roots) when is_map(roots) do
    if map_size(roots) > max_roots do
      :error
    else
      Enum.reduce_while(roots, {:ok, %{}}, fn
        {hash, root}, {:ok, acc} when is_binary(hash) and is_map(root) ->
          case decode_root(hash, root) do
            {:ok, decoded} -> {:cont, {:ok, Map.put(acc, hash, decoded)}}
            :error -> {:halt, :error}
          end

        _, _ ->
          {:halt, :error}
      end)
    end
  end

  defp fetch_roots(_, _), do: :error

  defp decode_root(hash, root) do
    with true <- valid_hash?(hash),
         :ok <- ensure_root_keys(root),
         {:ok, lineage} <- Map.fetch(root, "lineage_hash"),
         {:ok, node_fp} <- Map.fetch(root, "node_fp"),
         {:ok, runtime_fp} <- Map.fetch(root, "runtime_fp"),
         true <- valid_hash?(lineage),
         true <- lineage == hash,
         true <- valid_fp?(node_fp),
         true <- valid_hash?(runtime_fp) do
      {:ok,
       %{
         lineage_hash: lineage,
         node_fp: node_fp,
         runtime_fp: runtime_fp
       }}
    else
      _ -> :error
    end
  end

  defp ensure_root_keys(root) do
    allowed = MapSet.new(["lineage_hash", "node_fp", "runtime_fp"])

    if Enum.all?(Map.keys(root), &is_binary/1) and
         Enum.all?(Map.keys(root), &MapSet.member?(allowed, &1)) and
         MapSet.size(MapSet.new(Map.keys(root))) == 3 do
      :ok
    else
      :error
    end
  end

  defp fetch_fence_hash(%{"fence_hash" => nil}, 0), do: {:ok, nil}

  defp fetch_fence_hash(%{"fence_hash" => hash}, gen) when gen > 0 and is_binary(hash) do
    if valid_hash?(hash), do: {:ok, hash}, else: :error
  end

  defp fetch_fence_hash(data, 0) do
    case Map.fetch(data, "fence_hash") do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      _ -> :error
    end
  end

  defp fetch_fence_hash(_, _), do: :error

  defp ensure_encoded_size(data, max_bytes) do
    case Jason.encode(data) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes -> :ok
      _ -> :error
    end
  end
end
