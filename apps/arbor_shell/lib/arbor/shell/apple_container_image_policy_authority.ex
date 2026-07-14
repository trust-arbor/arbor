defmodule Arbor.Shell.AppleContainerImagePolicyAuthority do
  @moduledoc """
  Imperative owner of startup-pinned Apple Container image admission policy.

  Binds the operator-configured full image policy to the exact startup-pinned
  compact Linux dependency-baseline receipt at process start, holds both
  privately, and re-checks the baseline receipt on each checkout. This module is
  evidence/policy authority only: it never provisions, tags, or pulls images,
  never materializes dependencies, and never grants spawn execution.

  Production Application startup starts this owner with only the shared
  application-generated `:boot_epoch` token. Narrow direct-start injection
  (`:name`, `:config`, `:baseline_authority`) is reserved for same-library tests.
  """

  use GenServer

  alias Arbor.Shell.AppleContainerAdmissionCore
  alias Arbor.Shell.Config
  alias Arbor.Shell.LinuxDependencyBaselineAuthority
  alias Arbor.Shell.LinuxDependencyBaselineCore
  alias Arbor.Shell.StartupEpoch

  @epoch_namespace __MODULE__

  @plan_keys MapSet.new([
               "kind",
               "source_root",
               "manifest_path",
               "receipt",
               "materialization_entries",
               "evidence_only"
             ])

  @forbidden_plan_keys MapSet.new([
                         "ready",
                         "readiness",
                         "provisioned",
                         "provisioning",
                         "status",
                         "destination",
                         "destinations",
                         "candidate_path",
                         "base_path",
                         "writable"
                       ])

  @type status :: :unavailable | :pinned

  @type state :: %{
          status: status(),
          reason: atom() | tuple() | nil,
          config: module(),
          baseline_authority: module(),
          boot_epoch: reference() | nil,
          policy: map() | nil,
          receipt: map() | nil
        }

  @type public_status :: %{
          required(String.t()) => String.t() | nil
        }

  @allowed_start_keys MapSet.new([:name, :config, :baseline_authority, :boot_epoch])

  @doc """
  Start the image-policy authority owner.

  Production callers pass only the application-generated `:boot_epoch` token.
  Direct-start tests may additionally inject `:name`, `:config`, and/or
  `:baseline_authority`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    with {:ok, name} <- start_name(opts) do
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Child specification for the application supervisor.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = List.wrap(opts)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Internal checkout of the owner-held canonical image policy.

  Accepts only an optional GenServer server name — never caller policy, paths,
  or receipts. When pinned, re-checkouts the baseline authority, normalizes the
  plan receipt, and requires exact equality with the privately held receipt
  before returning a shallow copy of the canonical policy. Drift or corruption
  poisons the boot epoch and terminates this owner abnormally so `rest_for_one`
  tears down later execution owners.
  """
  @spec checkout_policy(GenServer.server()) ::
          {:ok, map()} | {:error, :apple_container_image_policy_unavailable | term()}
  def checkout_policy(server \\ __MODULE__) do
    call(server, :checkout_policy)
  end

  @doc """
  Redacted public status map. Never includes policy, digests, env, labels,
  toolchain, receipt, fingerprint, or config.
  """
  @spec public_status(GenServer.server()) :: public_status()
  def public_status(server \\ __MODULE__) do
    case call(server, :public_status) do
      {:ok, status} when is_map(status) -> status
      _other -> unavailable_public_status(:authority_unavailable)
    end
  end

  @doc false
  @spec clear_boot_epoch(reference() | term()) :: :ok
  def clear_boot_epoch(boot_epoch) when is_reference(boot_epoch) do
    StartupEpoch.clear(@epoch_namespace, boot_epoch)
  end

  def clear_boot_epoch(_boot_epoch), do: :ok

  @impl true
  def init(opts) do
    case normalize_start_opts(opts) do
      {:ok, start_opts} ->
        config = Map.fetch!(start_opts, :config)
        baseline_authority = Map.fetch!(start_opts, :baseline_authority)
        boot_epoch = Map.fetch!(start_opts, :boot_epoch)
        {:ok, bootstrap(config, baseline_authority, boot_epoch)}

      {:error, reason} ->
        # Reject authority-bearing start injection without crashing the app:
        # surface as a live unavailable owner rather than a boot loop.
        {:ok,
         %{
           status: :unavailable,
           reason: reason,
           config: Config,
           baseline_authority: LinuxDependencyBaselineAuthority,
           boot_epoch: nil,
           policy: nil,
           receipt: nil
         }}
    end
  end

  @impl true
  def handle_call(:public_status, _from, state) do
    {:reply, {:ok, render_public_status(state)}, state}
  end

  def handle_call(:checkout_policy, _from, %{status: :unavailable} = state) do
    {:reply, {:error, :apple_container_image_policy_unavailable}, state}
  end

  def handle_call(
        :checkout_policy,
        _from,
        %{
          status: :pinned,
          policy: policy,
          receipt: receipt,
          baseline_authority: baseline_authority,
          boot_epoch: boot_epoch
        } = state
      )
      when is_map(policy) and is_map(receipt) and is_atom(baseline_authority) do
    case safe_recheckout(baseline_authority, receipt) do
      :ok ->
        {:reply, {:ok, shallow_policy_copy(policy)}, state}

      {:error, reason} ->
        poison_epoch(boot_epoch)
        bounded = bound_checkout_reason(reason)

        {:stop, {:apple_container_image_policy_drift, bounded},
         {:error, {:apple_container_image_policy_drift, bounded}}, state}
    end
  end

  def handle_call(:checkout_policy, _from, %{status: :pinned} = state) do
    poison_epoch(state.boot_epoch)
    bounded = :malformed_pinned_state

    {:stop, {:apple_container_image_policy_drift, bounded},
     {:error, {:apple_container_image_policy_drift, bounded}}, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_apple_container_image_policy_authority_request}, state}
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state, %{})

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redact_state(state))
    |> redact_status_field(:reason)
    |> redact_status_field(:log)
  end

  def format_status(status), do: status

  # --- Bootstrap -------------------------------------------------------------

  defp bootstrap(config, baseline_authority, boot_epoch) do
    base = %{
      status: :unavailable,
      reason: nil,
      config: config,
      baseline_authority: baseline_authority,
      boot_epoch: boot_epoch,
      policy: nil,
      receipt: nil
    }

    case StartupEpoch.status(@epoch_namespace, boot_epoch) do
      :unbound ->
        base
        |> bootstrap_fresh(config, baseline_authority)
        |> persist_initial_epoch()

      :bound ->
        repin_boot_epoch(base, config, baseline_authority)

      {:sealed, :unavailable} ->
        %{base | status: :unavailable, reason: :boot_epoch_unavailable}

      {:sealed, :unsupported} ->
        poison_epoch(boot_epoch)
        %{base | status: :unavailable, reason: :boot_epoch_poisoned}

      :poisoned ->
        %{base | status: :unavailable, reason: :boot_epoch_poisoned}
    end
  end

  defp bootstrap_fresh(base, config, baseline_authority) do
    pin_from_config(base, config, baseline_authority)
  end

  defp persist_initial_epoch(%{boot_epoch: nil} = state), do: state

  defp persist_initial_epoch(%{status: :pinned, policy: policy, receipt: receipt} = state)
       when is_map(policy) and is_map(receipt) do
    case StartupEpoch.bind(
           @epoch_namespace,
           state.boot_epoch,
           epoch_bind_term(policy, receipt)
         ) do
      result when result in [:bound, :matched] ->
        state

      :poisoned ->
        %{state | status: :unavailable, reason: :boot_epoch_poisoned, policy: nil, receipt: nil}

      :sealed ->
        poison_epoch(state.boot_epoch)
        %{state | status: :unavailable, reason: :boot_epoch_poisoned, policy: nil, receipt: nil}
    end
  end

  defp persist_initial_epoch(%{status: :unavailable} = state) do
    case StartupEpoch.seal(@epoch_namespace, state.boot_epoch, :unavailable) do
      :sealed ->
        state

      _other ->
        poison_epoch(state.boot_epoch)

        %{state | status: :unavailable, reason: :boot_epoch_poisoned, policy: nil, receipt: nil}
    end
  end

  defp repin_boot_epoch(base, config, baseline_authority) do
    case pin_from_config(base, config, baseline_authority) do
      %{status: :pinned, policy: policy, receipt: receipt} = state
      when is_map(policy) and is_map(receipt) ->
        case StartupEpoch.bind(
               @epoch_namespace,
               base.boot_epoch,
               epoch_bind_term(policy, receipt)
             ) do
          :matched ->
            state

          :bound ->
            poison_epoch(base.boot_epoch)
            %{base | status: :unavailable, reason: :boot_epoch_poisoned}

          :poisoned ->
            %{base | status: :unavailable, reason: :boot_epoch_poisoned}

          :sealed ->
            poison_epoch(base.boot_epoch)
            %{base | status: :unavailable, reason: :boot_epoch_poisoned}
        end

      _unavailable ->
        poison_epoch(base.boot_epoch)
        %{base | status: :unavailable, reason: :boot_epoch_poisoned}
    end
  end

  defp pin_from_config(base, config, baseline_authority) do
    case safe_pin(config, baseline_authority) do
      {:ok, policy, receipt} ->
        %{base | status: :pinned, reason: nil, policy: policy, receipt: receipt}

      {:error, :apple_container_image_policy_config_absent} ->
        %{base | status: :unavailable, reason: :missing_config, policy: nil, receipt: nil}

      {:error, reason} ->
        %{
          base
          | status: :unavailable,
            reason: bound_checkout_reason(reason),
            policy: nil,
            receipt: nil
        }
    end
  end

  defp safe_pin(config, baseline_authority) do
    try do
      pin(config, baseline_authority)
    rescue
      _exception ->
        {:error, :image_policy_pin_failed}
    catch
      :throw, _value ->
        {:error, :image_policy_pin_failed}

      :exit, _reason ->
        {:error, :image_policy_pin_failed}
    end
  end

  defp pin(config, baseline_authority) do
    with {:ok, policy} <- fetch_config_policy(config),
         {:ok, plan} <- checkout_baseline(baseline_authority),
         :ok <- validate_plan_shape(plan),
         {:ok, receipt} <-
           LinuxDependencyBaselineCore.normalize_compact_receipt(plan["receipt"]),
         {:ok, refs} <- AppleContainerAdmissionCore.execution_references(policy),
         :ok <- bind_policy_to_receipt(policy, refs, receipt) do
      {:ok, shallow_policy_copy(policy), receipt}
    end
  end

  defp fetch_config_policy(config) when is_atom(config) do
    case config.apple_container_image_policy() do
      {:ok, policy} when is_map(policy) -> {:ok, policy}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_image_policy_config}
    end
  end

  defp fetch_config_policy(_config), do: {:error, :invalid_image_policy_config}

  defp checkout_baseline(baseline_authority) when is_atom(baseline_authority) do
    case baseline_authority.checkout_plan() do
      {:ok, plan} when is_map(plan) -> {:ok, plan}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_baseline_plan}
    end
  end

  defp checkout_baseline(_baseline_authority), do: {:error, :invalid_baseline_authority}

  defp validate_plan_shape(plan) when is_map(plan) do
    keys = plan |> Map.keys() |> Enum.filter(&is_binary/1) |> MapSet.new()

    cond do
      map_size(plan) > 16 ->
        {:error, :plan_too_large}

      not Enum.all?(Map.keys(plan), &is_binary/1) ->
        {:error, :invalid_plan}

      MapSet.difference(keys, @plan_keys) != MapSet.new() ->
        {:error, :unsupported_plan_keys}

      MapSet.difference(@plan_keys, keys) != MapSet.new() ->
        {:error, :incomplete_plan}

      MapSet.intersection(keys, @forbidden_plan_keys) != MapSet.new() ->
        {:error, :provisioning_claim_rejected}

      plan["kind"] != "linux_dependency_baseline_source" ->
        {:error, :invalid_plan_kind}

      plan["evidence_only"] != true ->
        {:error, :plan_not_evidence_only}

      true ->
        :ok
    end
  end

  defp validate_plan_shape(_plan), do: {:error, :invalid_plan}

  defp bind_policy_to_receipt(policy, refs, receipt)
       when is_map(policy) and is_map(refs) and is_map(receipt) do
    image = Map.get(refs, :image) || %{}
    toolchain = Map.get(policy, :toolchain) || %{}
    receipt_toolchain = Map.get(receipt, "toolchain") || %{}

    cond do
      Map.get(image, :index_digest) != Map.get(receipt, "image_index_digest") ->
        {:error, :image_policy_baseline_index_mismatch}

      Map.get(policy, :manifest_digest) != Map.get(receipt, "image_manifest_digest") ->
        {:error, :image_policy_baseline_manifest_mismatch}

      Map.get(policy, :mix_lock_digest) != Map.get(receipt, "mix_lock_digest") ->
        {:error, :image_policy_baseline_mix_lock_mismatch}

      Map.get(policy, :baseline_tree_digest) != Map.get(receipt, "baseline_tree_digest") ->
        {:error, :image_policy_baseline_tree_mismatch}

      Map.get(toolchain, :erlang) != Map.get(receipt_toolchain, "erlang") ->
        {:error, :image_policy_baseline_toolchain_mismatch}

      Map.get(toolchain, :elixir) != Map.get(receipt_toolchain, "elixir") ->
        {:error, :image_policy_baseline_toolchain_mismatch}

      true ->
        :ok
    end
  end

  defp bind_policy_to_receipt(_policy, _refs, _receipt),
    do: {:error, :image_policy_baseline_binding_failed}

  defp safe_recheckout(baseline_authority, expected_receipt) do
    try do
      recheckout(baseline_authority, expected_receipt)
    rescue
      _exception ->
        {:error, :baseline_recheckout_failed}
    catch
      :throw, _value ->
        {:error, :baseline_recheckout_failed}

      :exit, _reason ->
        {:error, :baseline_recheckout_failed}
    end
  end

  defp recheckout(baseline_authority, expected_receipt) do
    with {:ok, plan} <- checkout_baseline(baseline_authority),
         :ok <- validate_plan_shape(plan),
         {:ok, receipt} <-
           LinuxDependencyBaselineCore.normalize_compact_receipt(plan["receipt"]) do
      if receipt === expected_receipt do
        :ok
      else
        {:error, :baseline_receipt_drift}
      end
    end
  end

  defp shallow_policy_copy(policy) when is_map(policy) do
    %{
      image: policy.image,
      manifest_digest: policy.manifest_digest,
      vminit_image: policy.vminit_image,
      vminit_manifest_digest: policy.vminit_manifest_digest,
      env: List.wrap(policy.env),
      labels: Map.new(policy.labels || %{}),
      mix_lock_digest: policy.mix_lock_digest,
      baseline_tree_digest: policy.baseline_tree_digest,
      toolchain: %{
        erlang: policy.toolchain.erlang,
        elixir: policy.toolchain.elixir
      }
    }
  end

  defp bound_checkout_reason(reason) when is_atom(reason), do: reason

  defp bound_checkout_reason(reason) when is_tuple(reason) do
    components = Tuple.to_list(reason)

    if components != [] and Enum.all?(components, &is_atom/1) do
      reason
    else
      :image_policy_pin_failed
    end
  end

  defp bound_checkout_reason(_reason), do: :image_policy_pin_failed

  # --- Start-option normalization --------------------------------------------

  defp normalize_start_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Enum.reduce_while(opts, {:ok, default_start_opts(), MapSet.new()}, fn
        {key, value}, {:ok, acc, seen} ->
          if MapSet.member?(@allowed_start_keys, key) do
            if MapSet.member?(seen, key) do
              {:halt, {:error, duplicate_start_option_error(key)}}
            else
              case normalize_start_value(key, value) do
                {:ok, normalized} ->
                  {:cont, {:ok, Map.put(acc, key, normalized), MapSet.put(seen, key)}}

                {:error, reason} ->
                  {:halt, {:error, reason}}
              end
            end
          else
            {:halt, {:error, :unknown_apple_container_image_policy_authority_option}}
          end

        _other, _acc ->
          {:halt, {:error, :malformed_apple_container_image_policy_authority_options}}
      end)
      |> case do
        {:ok, start_opts, _seen} -> {:ok, Map.delete(start_opts, :name)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :malformed_apple_container_image_policy_authority_options}
    end
  end

  defp normalize_start_opts(_opts),
    do: {:error, :malformed_apple_container_image_policy_authority_options}

  defp default_start_opts do
    %{
      config: Config,
      baseline_authority: LinuxDependencyBaselineAuthority,
      boot_epoch: nil
    }
  end

  defp normalize_start_value(:name, name), do: validate_start_name(name)

  defp normalize_start_value(:boot_epoch, boot_epoch) when is_reference(boot_epoch),
    do: {:ok, boot_epoch}

  defp normalize_start_value(:boot_epoch, _boot_epoch),
    do: {:error, :invalid_apple_container_image_policy_boot_epoch}

  defp normalize_start_value(:config, module) when is_atom(module), do: {:ok, module}

  defp normalize_start_value(:config, _module),
    do: {:error, :invalid_apple_container_image_policy_config}

  defp normalize_start_value(:baseline_authority, module) when is_atom(module), do: {:ok, module}

  defp normalize_start_value(:baseline_authority, _module),
    do: {:error, :invalid_apple_container_image_policy_baseline_authority}

  defp duplicate_start_option_error(:name),
    do: :duplicate_apple_container_image_policy_authority_name

  defp duplicate_start_option_error(:config),
    do: :duplicate_apple_container_image_policy_authority_config

  defp duplicate_start_option_error(:baseline_authority),
    do: :duplicate_apple_container_image_policy_authority_baseline_authority

  defp duplicate_start_option_error(:boot_epoch),
    do: :duplicate_apple_container_image_policy_authority_boot_epoch

  defp start_name(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get_values(opts, :name) do
        [] -> {:ok, __MODULE__}
        [name] -> validate_start_name(name)
        _duplicates -> {:error, :duplicate_apple_container_image_policy_authority_name}
      end
    else
      {:error, :malformed_apple_container_image_policy_authority_options}
    end
  end

  defp start_name(_opts),
    do: {:error, :malformed_apple_container_image_policy_authority_options}

  defp validate_start_name(name) when is_atom(name), do: {:ok, name}
  defp validate_start_name({:global, _term} = name), do: {:ok, name}

  defp validate_start_name({:via, module, _term} = name) when is_atom(module),
    do: {:ok, name}

  defp validate_start_name(_name),
    do: {:error, :invalid_apple_container_image_policy_authority_name}

  # --- Presentation / redaction ----------------------------------------------

  defp render_public_status(state) do
    %{
      "state" => Atom.to_string(state.status),
      "reason" => reason_label(state.reason)
    }
  end

  defp unavailable_public_status(reason) do
    %{
      "state" => "unavailable",
      "reason" => reason_label(reason)
    }
  end

  defp reason_label(nil), do: nil
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_label(reason) when is_tuple(reason) do
    components = Tuple.to_list(reason)

    if components != [] and Enum.all?(components, &is_atom/1) do
      Enum.map_join(components, ".", &Atom.to_string/1)
    else
      "error_detail"
    end
  end

  defp reason_label(_reason), do: "unavailable"

  defp redact_state(state) when is_map(state) do
    %{
      status: Map.get(state, :status),
      reason: if(is_nil(Map.get(state, :reason)), do: nil, else: :redacted),
      config: Map.get(state, :config),
      baseline_authority: Map.get(state, :baseline_authority),
      boot_epoch: if(is_reference(Map.get(state, :boot_epoch)), do: :redacted, else: nil),
      policy: if(is_nil(Map.get(state, :policy)), do: nil, else: :redacted),
      receipt: if(is_nil(Map.get(state, :receipt)), do: nil, else: :redacted)
    }
  end

  defp redact_state(_state), do: :redacted

  defp redact_status_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end

  defp epoch_bind_term(policy, receipt), do: {policy, receipt}

  defp poison_epoch(boot_epoch) do
    StartupEpoch.poison(@epoch_namespace, boot_epoch)
  end

  defp call(server, request) do
    case resolve_server(server) do
      {:ok, pid} -> GenServer.call(pid, request)
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :apple_container_image_policy_authority_unavailable}
  end

  defp resolve_server(server) when is_pid(server), do: {:ok, server}

  defp resolve_server(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> {:error, :apple_container_image_policy_authority_unavailable}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server({:via, _module, _name} = server) do
    case GenServer.whereis(server) do
      nil -> {:error, :apple_container_image_policy_authority_unavailable}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server(_server),
    do: {:error, :apple_container_image_policy_authority_unavailable}
end
