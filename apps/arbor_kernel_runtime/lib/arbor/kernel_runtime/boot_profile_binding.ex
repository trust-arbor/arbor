defmodule Arbor.KernelRuntime.BootProfileBinding do
  @moduledoc """
  VM-lifetime boot-profile binding owner.

  After Envelope.verify_boot_profile/3 and Core projection, this process
  creates one protected named ETS set and insert_new's a single row.
  The live VM `:init` process is the heir. There is no production reset.

  An init-owned table is durable storage, not authenticity evidence.
  ETS does not retain origin history. Every owner or application restore
  independently verifies the configured signed stage-zero envelope at the
  sampled clock, projects it, and publishes the inherited row only when
  the identity token matches and the projected snapshot is exactly equal.
  Same-identity restore can fail closed when the signed envelope is no
  longer valid at the sampled time (`:expired`, `:not_yet_valid`,
  revocation, or mismatch). Changed identity is rejected without
  verification or row replacement.

  Public `boot_profile/0` does not invoke Envelope. Each fetch validates
  the bounded table and snapshot. Publication requires a live binding
  owner, proving restore or first-bind succeeded.

  Application-level: `:protected` ETS allows any process to read and only
  the owner to mutate. Non-owner insert, delete, take, or give_away raise
  ArgumentError.

  In-VM first-party code in this VM is reviewed TCB. Protected ETS does
  not isolate hostile same-VM TCB. A preclaimed table whose snapshot
  equals the independently verified projection is authentic; origin
  history is unavailable and is not the admission property.

  Stage-zero bytes are installer/OS TCB. Envelope is the sole verifier.
  OS/root/installer compromise and arbitrary hostile code already admitted
  into this VM remain outside the plugin threat boundary.
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.KernelRuntime.BootProfileBinding.Core
  alias Arbor.KernelRuntime.Config

  @table :arbor_kernel_runtime_boot_profile_binding
  @key :vm_lifetime_identity
  @heir_data :arbor_kernel_runtime_boot_profile_binding

  @clock_mfa Application.compile_env(
               :arbor_kernel_runtime,
               :boot_profile_clock_mfa,
               {__MODULE__, :sample_utc_second, []}
             )

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec snapshot() :: {:ok, map()} | {:error, :not_bound}
  def snapshot do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        case fetch_slot() do
          {:ok, snapshot, _token} -> {:ok, snapshot}
          _ -> {:error, :not_bound}
        end

      _ ->
        {:error, :not_bound}
    end
  end

  @spec sample_utc_second() :: String.t()
  def sample_utc_second do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  @impl true
  def init(_opts) do
    case bind_or_restore() do
      {:ok, snapshot} ->
        Logger.info(
          "kernel runtime boot profile bound profile_id=#{snapshot["profile_id"]} " <>
            "manifest_sha256=#{snapshot["manifest_sha256"]}"
        )

        {:ok, %{}}

      {:error, reason} ->
        Logger.warning("kernel runtime boot profile bind failed: #{reason_tag(reason)}")
        {:stop, reason}
    end
  end

  defp bind_or_restore do
    case fetch_slot() do
      :corrupt ->
        {:error, {:boot_profile_binding_failed, :corrupt_slot}}

      {:ok, snapshot, token} ->
        restore(snapshot, token)

      :absent ->
        first_bind()
    end
  end

  defp restore(snapshot, frozen_token) do
    with {:ok, stage_zero} <- stage_zero(),
         {:ok, token} <- Core.identity_token(stage_zero) do
      if Core.same_identity?(token, frozen_token) do
        reverify_inherited(stage_zero, snapshot)
      else
        {:error, {:boot_profile_rebind_rejected, snapshot["manifest_sha256"], token}}
      end
    else
      {:error, reason} -> {:error, {:boot_profile_binding_failed, reason}}
    end
  end

  defp first_bind do
    with {:ok, stage_zero} <- stage_zero(),
         {:ok, snapshot} <- authenticate_stage_zero(stage_zero),
         {:ok, token} <- Core.identity_token(stage_zero) do
      commit_first(snapshot, token)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, {:boot_profile_binding_failed, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp reverify_inherited(stage_zero, snapshot) do
    case authenticate_stage_zero(stage_zero) do
      {:ok, projected} ->
        if projected == snapshot do
          {:ok, snapshot}
        else
          {:error, {:boot_profile_binding_failed, :corrupt_slot}}
        end

      {:error, reason} when is_atom(reason) ->
        {:error, {:boot_profile_binding_failed, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp authenticate_stage_zero(stage_zero) do
    with {:ok, now} <- resolve_now(),
         verifier <- Core.verifier_input(stage_zero, now),
         {:ok, result} <-
           Envelope.verify_boot_profile(
             stage_zero["manifest_bytes"],
             stage_zero["signature_bytes"],
             verifier
           ) do
      Core.project(result)
    end
  end

  # Sole writer of the VM-lifetime identity table. Fetch-before-create;
  # never overwrite a claimed or malformed table.
  defp commit_first(snapshot, token) do
    case fetch_slot() do
      {:ok, ^snapshot, ^token} ->
        {:ok, snapshot}

      {:ok, _other, _token} ->
        {:error, {:boot_profile_binding_failed, :corrupt_slot}}

      :corrupt ->
        {:error, {:boot_profile_binding_failed, :corrupt_slot}}

      :absent ->
        case init_pid() do
          {:ok, init_pid} -> create_and_insert(snapshot, token, init_pid)
          :error -> {:error, {:boot_profile_binding_failed, :corrupt_slot}}
        end
    end
  end

  defp create_and_insert(snapshot, token, init_pid) do
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :protected,
        {:heir, init_pid, @heir_data},
        read_concurrency: true
      ])

    case :ets.insert_new(table, {@key, snapshot, token}) do
      true ->
        case fetch_slot() do
          {:ok, ^snapshot, ^token} -> {:ok, snapshot}
          _ -> {:error, {:boot_profile_binding_failed, :corrupt_slot}}
        end

      false ->
        {:error, {:boot_profile_binding_failed, :corrupt_slot}}
    end
  rescue
    ArgumentError -> {:error, {:boot_profile_binding_failed, :corrupt_slot}}
  end

  defp fetch_slot do
    case :ets.whereis(@table) do
      :undefined ->
        :absent

      table ->
        read_validated(table)
    end
  rescue
    ArgumentError -> :corrupt
  end

  defp read_validated(table) do
    with {:ok, init_pid} <- init_pid(),
         :ok <- validate_table(table, init_pid),
         [{@key, snapshot, token}] <- :ets.lookup(table, @key),
         true <- is_binary(token) and byte_size(token) == 32,
         {:ok, admitted} <- Core.admit_snapshot(snapshot) do
      {:ok, admitted, token}
    else
      _ -> :corrupt
    end
  rescue
    ArgumentError -> :corrupt
  end

  defp validate_table(table, init_pid) do
    owner = :ets.info(table, :owner)
    heir = :ets.info(table, :heir)

    if :ets.info(table, :name) == @table and
         :ets.info(table, :type) == :set and
         :ets.info(table, :protection) == :protected and
         :ets.info(table, :size) == 1 and
         valid_ownership?(owner, heir, init_pid) do
      :ok
    else
      :error
    end
  end

  defp valid_ownership?(owner, heir, init_pid) do
    binding = Process.whereis(__MODULE__)
    (is_pid(binding) and owner == binding and heir == init_pid) or owner == init_pid
  end

  defp init_pid do
    case Process.whereis(:init) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  defp stage_zero do
    case Config.boot_profile_stage_zero() do
      {:ok, stage_zero} -> {:ok, stage_zero}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_now do
    {module, function, args} = @clock_mfa

    case apply(module, function, args) do
      now when is_binary(now) and byte_size(now) >= 1 and byte_size(now) <= 32 ->
        {:ok, now}

      _ ->
        {:error, :malformed_stage_zero}
    end
  rescue
    _ -> {:error, :malformed_stage_zero}
  catch
    _, _ -> {:error, :malformed_stage_zero}
  end

  defp reason_tag({:boot_profile_binding_failed, reason}) when is_atom(reason), do: reason

  defp reason_tag({:boot_profile_rebind_rejected, _digest, _token}) do
    :boot_profile_rebind_rejected
  end

  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag(_reason), do: :boot_profile_binding_failed
end
