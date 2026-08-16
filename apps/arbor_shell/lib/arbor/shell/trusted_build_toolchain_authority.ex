defmodule Arbor.Shell.TrustedBuildToolchainAuthority do
  @moduledoc false

  use GenServer

  alias Arbor.Shell.Config
  alias Arbor.Shell.StartupEpoch
  alias Arbor.Shell.TrustedBuild.Identity

  @epoch_namespace __MODULE__
  @allowed_start_keys MapSet.new([:name, :boot_epoch, :hex_cache])

  @type binding :: %{
          erlang_root: map(),
          elixir_root: map(),
          erl: map(),
          elixir: map(),
          elixir_mix: map(),
          hex_archive: {:tree, String.t(), map(), String.t()} | :empty,
          hex_cache: {:tree, String.t(), map(), String.t()} | :empty
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    with {:ok, name} <- start_name(opts) do
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

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

  @spec checkout(GenServer.server()) ::
          {:ok, binding(), pid(), reference()} | {:error, term()}
  def checkout(server \\ __MODULE__) do
    call(server, :checkout)
  end

  @spec checkout_generation(GenServer.server(), reference()) ::
          {:ok, binding(), pid(), reference()} | {:error, term()}
  def checkout_generation(server \\ __MODULE__, generation)

  def checkout_generation(server, generation) when is_reference(generation) do
    call(server, {:checkout_generation, generation})
  end

  def checkout_generation(_server, _generation),
    do: {:error, :trusted_build_toolchain_unavailable}

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
        generation = make_ref()
        boot_epoch = Map.fetch!(start_opts, :boot_epoch)
        hex_cache = Map.get(start_opts, :hex_cache, :config)

        {:ok,
         bootstrap(%{
           status: :unavailable,
           reason: nil,
           boot_epoch: boot_epoch,
           generation: generation,
           binding: nil,
           hex_cache: hex_cache
         })}

      {:error, reason} ->
        {:ok,
         %{
           status: :unavailable,
           reason: reason,
           boot_epoch: nil,
           generation: make_ref(),
           binding: nil,
           hex_cache: :config
         }}
    end
  end

  @impl true
  def handle_call(:checkout, _from, %{status: :unavailable} = state) do
    {:reply, {:error, :trusted_build_toolchain_unavailable}, state}
  end

  def handle_call(:checkout, _from, %{status: :pinned, binding: binding} = state)
      when is_map(binding) do
    case reverify(binding) do
      :ok ->
        {:reply, {:ok, binding, self(), state.generation}, state}

      {:error, reason} ->
        poison(state.boot_epoch)

        {:stop, {:trusted_build_toolchain_drift, reason},
         {:error, {:trusted_build_toolchain_drift, reason}}, state}
    end
  end

  def handle_call({:checkout_generation, generation}, _from, state) do
    cond do
      state.status != :pinned ->
        {:reply, {:error, :trusted_build_toolchain_unavailable}, state}

      state.generation != generation ->
        {:reply, {:error, :trusted_build_toolchain_generation_mismatch}, state}

      true ->
        handle_call(:checkout, nil, state)
    end
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_trusted_build_toolchain_request}, state}
  end

  defp bootstrap(state) do
    case pin_binding(state.hex_cache) do
      {:ok, binding} ->
        persist_epoch(%{state | status: :pinned, binding: binding, reason: nil})

      {:error, reason} ->
        %{state | status: :unavailable, reason: reason, binding: nil}
    end
  end

  defp persist_epoch(%{boot_epoch: nil} = state), do: state

  defp persist_epoch(%{status: :pinned, binding: binding} = state) do
    case StartupEpoch.bind(@epoch_namespace, state.boot_epoch, fingerprint(binding)) do
      result when result in [:bound, :matched] ->
        state

      _other ->
        %{state | status: :unavailable, reason: :boot_epoch_poisoned, binding: nil}
    end
  end

  defp persist_epoch(state), do: state

  defp pin_binding(hex_cache_opt) do
    with {:ok, erlang_root_path} <- erlang_root(),
         {:ok, elixir_root_path} <- elixir_root(),
         {:ok, erlang_root} <- Identity.pin_directory(erlang_root_path),
         {:ok, elixir_root} <- Identity.pin_directory(elixir_root_path),
         {:ok, erl} <- Identity.pin_regular_file(Path.join(erlang_root_path, "bin/erl")),
         {:ok, elixir} <- Identity.pin_regular_file(Path.join(elixir_root_path, "bin/elixir")),
         {:ok, elixir_mix} <- Identity.pin_regular_file(Path.join(elixir_root_path, "bin/mix")),
         {:ok, hex_archive} <- pin_hex_archive(elixir_root_path),
         {:ok, hex_cache} <- pin_hex_cache(hex_cache_opt) do
      {:ok,
       %{
         erlang_root: erlang_root,
         elixir_root: elixir_root,
         erl: erl,
         elixir: elixir,
         elixir_mix: elixir_mix,
         hex_archive: hex_archive,
         hex_cache: hex_cache
       }}
    end
  end

  defp erlang_root do
    root = :code.root_dir() |> List.to_string() |> Path.expand()
    {:ok, root}
  end

  defp elixir_root do
    root = Application.app_dir(:elixir) |> Path.join("../..") |> Path.expand()
    {:ok, root}
  end

  defp pin_hex_archive(elixir_root) do
    archives = Path.join(elixir_root, ".mix/archives")

    case File.ls(archives) do
      {:ok, names} ->
        hex_names = Enum.filter(names, &String.starts_with?(&1, "hex-"))

        case hex_names do
          [name] ->
            path = Path.join(archives, name)

            with {:ok, dir} <- Identity.pin_directory(path),
                 {:ok, digest} <- Identity.tree_digest(path) do
              {:ok, {:tree, path, dir, digest}}
            end

          [] ->
            {:error, :trusted_build_hex_archive_absent}

          _many ->
            {:error, :trusted_build_hex_archive_ambiguous}
        end

      {:error, :enoent} ->
        {:ok, :empty}

      {:error, _reason} ->
        {:error, :trusted_build_hex_archive_unavailable}
    end
  end

  defp pin_hex_cache(:empty), do: {:ok, :empty}

  defp pin_hex_cache(path) when is_binary(path) do
    with {:ok, dir} <- Identity.pin_directory(path),
         {:ok, digest} <- Identity.tree_digest(path) do
      {:ok, {:tree, path, dir, digest}}
    end
  end

  defp pin_hex_cache(:config) do
    case Config.trusted_build_hex_cache() do
      {:ok, path} -> pin_hex_cache(path)
      {:error, :trusted_build_hex_cache_absent} -> {:ok, :empty}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pin_hex_cache(_other), do: {:error, :invalid_trusted_build_hex_cache}

  defp reverify(binding) do
    with :ok <- Identity.verify_directory(binding.erlang_root),
         :ok <- Identity.verify_directory(binding.elixir_root),
         :ok <- Identity.verify_file(binding.erl),
         :ok <- Identity.verify_file(binding.elixir),
         :ok <- Identity.verify_file(binding.elixir_mix),
         :ok <- reverify_tree(binding.hex_archive),
         :ok <- reverify_tree(binding.hex_cache) do
      :ok
    end
  end

  defp reverify_tree(:empty), do: :ok

  defp reverify_tree({:tree, path, dir, digest}) do
    with :ok <- Identity.verify_directory(dir),
         {:ok, ^digest} <- Identity.tree_digest(path) do
      :ok
    else
      {:ok, _other} -> {:error, :identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fingerprint(binding) do
    %{
      erlang: binding.erlang_root.path,
      elixir: binding.elixir_root.path,
      erl: binding.erl.sha256,
      elixir_bin: binding.elixir.sha256,
      mix: binding.elixir_mix.sha256,
      hex: tree_fingerprint(binding.hex_archive),
      cache: tree_fingerprint(binding.hex_cache)
    }
  end

  defp tree_fingerprint(:empty), do: :empty
  defp tree_fingerprint({:tree, path, _dir, digest}), do: {path, digest}

  defp poison(boot_epoch), do: StartupEpoch.poison(@epoch_namespace, boot_epoch)

  defp start_name(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      name when is_atom(name) -> {:ok, name}
      _other -> {:error, :invalid_trusted_build_toolchain_name}
    end
  end

  defp normalize_start_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Enum.reduce_while(opts, {:ok, %{boot_epoch: nil}}, fn
        {key, value}, {:ok, acc} ->
          if MapSet.member?(@allowed_start_keys, key) do
            if Map.has_key?(acc, key) and key != :boot_epoch do
              {:halt, {:error, :duplicate_trusted_build_toolchain_option}}
            else
              {:cont, {:ok, Map.put(acc, key, value)}}
            end
          else
            {:halt, {:error, :unknown_trusted_build_toolchain_option}}
          end

        _other, _acc ->
          {:halt, {:error, :invalid_trusted_build_toolchain_options}}
      end)
    else
      {:error, :invalid_trusted_build_toolchain_options}
    end
  end

  defp normalize_start_opts(_opts), do: {:error, :invalid_trusted_build_toolchain_options}

  defp call(server, request) do
    GenServer.call(server, request)
  catch
    :exit, _ -> {:error, :trusted_build_toolchain_unavailable}
  end
end
