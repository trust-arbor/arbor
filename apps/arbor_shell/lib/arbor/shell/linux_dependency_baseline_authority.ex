defmodule Arbor.Shell.LinuxDependencyBaselineAuthority do
  @moduledoc """
  Imperative owner of a startup-pinned Linux dependency-baseline source Binding.

  Pins the operator-configured source root + manifest at process start via the
  source verifier, holds the Binding privately, and re-verifies before returning
  an evidence-only materialization plan. This module is not executable authority
  by itself: it never materializes dependencies, adds local aliases, probes
  Apple Container, or grants spawn execution.

  Production Application startup starts this owner with only the shared
  application-generated `:boot_epoch` token. Narrow direct-start injection is
  reserved for same-library tests.
  """

  use GenServer

  alias Arbor.Shell.Config
  alias Arbor.Shell.LinuxDependencyBaselineSource
  alias Arbor.Shell.StartupEpoch
  alias Arbor.Shell.TrustedPath

  @epoch_namespace __MODULE__

  @type status :: :unavailable | :pinned

  @type state :: %{
          status: status(),
          reason: atom() | tuple() | nil,
          source: module(),
          trusted_path: module(),
          boot_epoch: reference() | nil,
          binding: term() | nil
        }

  @type public_status :: %{
          required(String.t()) => String.t() | nil
        }

  @allowed_start_keys MapSet.new([:name, :source, :trusted_path, :boot_epoch])

  @doc """
  Start the Linux dependency-baseline authority owner.

  Production callers pass only the application-generated `:boot_epoch` token.
  Direct-start tests may additionally inject `:name`, `:source`, and/or
  `:trusted_path`.
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
  Internal checkout of an evidence-only materialization plan.

  Never accepts caller bindings or paths. When pinned, re-verifies the private
  Binding then projects `Source.plan/1`. Drift or plan corruption poisons the
  boot epoch and terminates this owner abnormally so `rest_for_one` tears down
  later execution owners.
  """
  @spec checkout_plan(GenServer.server()) ::
          {:ok, map()} | {:error, :linux_dependency_baseline_unavailable | term()}
  def checkout_plan(server \\ __MODULE__) do
    call(server, :checkout_plan)
  end

  @doc """
  Redacted public status map. Never includes Binding, paths, inventory, or digests.
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
        source = Map.fetch!(start_opts, :source)
        trusted_path = Map.fetch!(start_opts, :trusted_path)
        boot_epoch = Map.fetch!(start_opts, :boot_epoch)
        {:ok, bootstrap(source, trusted_path, boot_epoch)}

      {:error, reason} ->
        # Reject authority-bearing start injection without crashing the app:
        # surface as a live unavailable owner rather than a boot loop.
        {:ok,
         %{
           status: :unavailable,
           reason: reason,
           source: LinuxDependencyBaselineSource,
           trusted_path: TrustedPath,
           boot_epoch: nil,
           binding: nil
         }}
    end
  end

  @impl true
  def handle_call(:public_status, _from, state) do
    {:reply, {:ok, render_public_status(state)}, state}
  end

  def handle_call(:checkout_plan, _from, %{status: :unavailable} = state) do
    {:reply, {:error, :linux_dependency_baseline_unavailable}, state}
  end

  def handle_call(
        :checkout_plan,
        _from,
        %{
          status: :pinned,
          binding: binding,
          source: source,
          trusted_path: trusted_path,
          boot_epoch: boot_epoch
        } = state
      )
      when not is_nil(binding) and is_atom(source) and is_atom(trusted_path) do
    case safe_verify_and_plan(source, binding, trusted_path) do
      {:ok, plan} ->
        {:reply, {:ok, plan}, state}

      {:error, reason} ->
        poison_epoch(boot_epoch)
        bounded = bound_checkout_reason(reason)

        {:stop, {:linux_dependency_baseline_drift, bounded},
         {:error, {:linux_dependency_baseline_drift, bounded}}, state}
    end
  end

  def handle_call(:checkout_plan, _from, %{status: :pinned} = state) do
    # Pinned status without a well-formed private Binding / source modules is
    # internal corruption: poison the epoch and fail closed without exposing
    # arbitrary state terms.
    poison_epoch(state.boot_epoch)
    bounded = :malformed_pinned_state

    {:stop, {:linux_dependency_baseline_drift, bounded},
     {:error, {:linux_dependency_baseline_drift, bounded}}, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_linux_dependency_baseline_authority_request}, state}
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

  defp bootstrap(source, trusted_path, boot_epoch) do
    base = %{
      status: :unavailable,
      reason: nil,
      source: source,
      trusted_path: trusted_path,
      boot_epoch: boot_epoch,
      binding: nil
    }

    case StartupEpoch.status(@epoch_namespace, boot_epoch) do
      :unbound ->
        base
        |> bootstrap_fresh(source, trusted_path)
        |> persist_initial_epoch()

      :bound ->
        repin_boot_epoch(base, source, trusted_path)

      {:sealed, :unavailable} ->
        %{base | status: :unavailable, reason: :boot_epoch_unavailable}

      {:sealed, :unsupported} ->
        # Not used by this authority; treat as poisoned for fail-closed safety.
        poison_epoch(boot_epoch)
        %{base | status: :unavailable, reason: :boot_epoch_poisoned}

      :poisoned ->
        %{base | status: :unavailable, reason: :boot_epoch_poisoned}
    end
  end

  defp bootstrap_fresh(base, source, trusted_path) do
    pin_from_config(base, source, trusted_path)
  end

  defp persist_initial_epoch(%{boot_epoch: nil} = state), do: state

  defp persist_initial_epoch(%{status: :pinned, binding: binding} = state)
       when not is_nil(binding) do
    case StartupEpoch.bind(
           @epoch_namespace,
           state.boot_epoch,
           epoch_bind_term(binding)
         ) do
      result when result in [:bound, :matched] ->
        state

      :poisoned ->
        %{state | status: :unavailable, reason: :boot_epoch_poisoned, binding: nil}

      :sealed ->
        poison_epoch(state.boot_epoch)
        %{state | status: :unavailable, reason: :boot_epoch_poisoned, binding: nil}
    end
  end

  defp persist_initial_epoch(%{status: :unavailable} = state) do
    case StartupEpoch.seal(@epoch_namespace, state.boot_epoch, :unavailable) do
      :sealed ->
        state

      _other ->
        poison_epoch(state.boot_epoch)
        %{state | status: :unavailable, reason: :boot_epoch_poisoned, binding: nil}
    end
  end

  defp repin_boot_epoch(base, source, trusted_path) do
    case pin_from_config(base, source, trusted_path) do
      %{status: :pinned, binding: binding} = state when not is_nil(binding) ->
        case StartupEpoch.bind(
               @epoch_namespace,
               base.boot_epoch,
               epoch_bind_term(binding)
             ) do
          :matched ->
            state

          :bound ->
            # Unexpected unbound transition under a bound epoch — fail closed.
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

  defp pin_from_config(base, source, trusted_path) do
    case Config.linux_dependency_baseline() do
      {:ok, %{source_root: source_root, manifest_path: manifest_path}} ->
        case source.pin(source_root, manifest_path, trusted_path) do
          {:ok, binding} ->
            %{base | status: :pinned, reason: nil, binding: binding}

          {:error, reason} ->
            %{base | status: :unavailable, reason: reason, binding: nil}
        end

      {:error, :linux_dependency_baseline_config_absent} ->
        %{base | status: :unavailable, reason: :missing_config, binding: nil}

      {:error, reason} ->
        %{base | status: :unavailable, reason: reason, binding: nil}
    end
  end

  # Never retain exception text or arbitrary source/verifier terms across the
  # GenServer boundary. Raise/throw/exit from verify/plan poison via the caller.
  defp safe_verify_and_plan(source, binding, trusted_path) do
    try do
      verify_and_plan(source, binding, trusted_path)
    rescue
      _exception ->
        {:error, :source_verify_or_plan_failed}
    catch
      :throw, _value ->
        {:error, :source_verify_or_plan_failed}

      :exit, _reason ->
        {:error, :source_verify_or_plan_failed}
    end
  end

  defp verify_and_plan(source, binding, trusted_path) do
    with :ok <- source.verify(binding, trusted_path),
         plan when is_map(plan) <- source.plan(binding) do
      {:ok, plan}
    else
      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_plan}
    end
  end

  # Atom-only reasons are stable operator labels. Anything else (paths, digests,
  # exception-shaped terms) collapses to a bounded generic atom.
  defp bound_checkout_reason(reason) when is_atom(reason), do: reason

  defp bound_checkout_reason(reason) when is_tuple(reason) do
    components = Tuple.to_list(reason)

    if components != [] and Enum.all?(components, &is_atom/1) do
      reason
    else
      :source_verify_or_plan_failed
    end
  end

  defp bound_checkout_reason(_reason), do: :source_verify_or_plan_failed

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
            {:halt, {:error, :unknown_linux_dependency_baseline_authority_option}}
          end

        _other, _acc ->
          {:halt, {:error, :malformed_linux_dependency_baseline_authority_options}}
      end)
      |> case do
        {:ok, start_opts, _seen} -> {:ok, Map.delete(start_opts, :name)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :malformed_linux_dependency_baseline_authority_options}
    end
  end

  defp normalize_start_opts(_opts),
    do: {:error, :malformed_linux_dependency_baseline_authority_options}

  defp default_start_opts do
    %{
      source: LinuxDependencyBaselineSource,
      trusted_path: TrustedPath,
      boot_epoch: nil
    }
  end

  defp normalize_start_value(:name, name), do: validate_start_name(name)

  defp normalize_start_value(:boot_epoch, boot_epoch) when is_reference(boot_epoch),
    do: {:ok, boot_epoch}

  defp normalize_start_value(:boot_epoch, _boot_epoch),
    do: {:error, :invalid_linux_dependency_baseline_boot_epoch}

  defp normalize_start_value(:trusted_path, module) when is_atom(module) do
    {:ok, module}
  end

  defp normalize_start_value(:trusted_path, _module),
    do: {:error, :invalid_linux_dependency_baseline_trusted_path}

  defp normalize_start_value(:source, module) when is_atom(module) do
    {:ok, module}
  end

  defp normalize_start_value(:source, _module),
    do: {:error, :invalid_linux_dependency_baseline_source}

  defp duplicate_start_option_error(:name),
    do: :duplicate_linux_dependency_baseline_authority_name

  defp duplicate_start_option_error(:source),
    do: :duplicate_linux_dependency_baseline_authority_source

  defp duplicate_start_option_error(:trusted_path),
    do: :duplicate_linux_dependency_baseline_authority_trusted_path

  defp duplicate_start_option_error(:boot_epoch),
    do: :duplicate_linux_dependency_baseline_authority_boot_epoch

  defp start_name(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get_values(opts, :name) do
        [] -> {:ok, __MODULE__}
        [name] -> validate_start_name(name)
        _duplicates -> {:error, :duplicate_linux_dependency_baseline_authority_name}
      end
    else
      {:error, :malformed_linux_dependency_baseline_authority_options}
    end
  end

  defp start_name(_opts), do: {:error, :malformed_linux_dependency_baseline_authority_options}

  defp validate_start_name(name) when is_atom(name), do: {:ok, name}
  defp validate_start_name({:global, _term} = name), do: {:ok, name}

  defp validate_start_name({:via, module, _term} = name) when is_atom(module),
    do: {:ok, name}

  defp validate_start_name(_name),
    do: {:error, :invalid_linux_dependency_baseline_authority_name}

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

  # Public labels are atom-only. Binary tuple components (paths, digests) and
  # other detail-bearing terms map to a single bounded generic label.
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
      source: Map.get(state, :source),
      trusted_path: Map.get(state, :trusted_path),
      boot_epoch: if(is_reference(Map.get(state, :boot_epoch)), do: :redacted, else: nil),
      binding: if(is_nil(Map.get(state, :binding)), do: nil, else: :redacted)
    }
  end

  defp redact_state(_state), do: :redacted

  defp redact_status_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end

  defp epoch_bind_term(binding), do: binding

  defp poison_epoch(boot_epoch) do
    StartupEpoch.poison(@epoch_namespace, boot_epoch)
  end

  defp call(server, request) do
    case resolve_server(server) do
      {:ok, pid} -> GenServer.call(pid, request)
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :linux_dependency_baseline_authority_unavailable}
  end

  defp resolve_server(server) when is_pid(server), do: {:ok, server}

  defp resolve_server(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> {:error, :linux_dependency_baseline_authority_unavailable}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server({:via, _module, _name} = server) do
    case GenServer.whereis(server) do
      nil -> {:error, :linux_dependency_baseline_authority_unavailable}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server(_server), do: {:error, :linux_dependency_baseline_authority_unavailable}
end
