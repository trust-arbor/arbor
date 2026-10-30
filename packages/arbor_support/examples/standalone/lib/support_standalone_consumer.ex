defmodule SupportStandaloneConsumer do
  @moduledoc "Public safety-helper qualification without an Arbor product runtime."

  alias Arbor.Common.Pagination.Cursor
  alias Arbor.Common.{SafeAtom, SafePath, SensitiveData}
  alias Arbor.Common.SafePath.NativeReaderArtifact

  @modules [
    Cursor,
    SafeAtom,
    SafePath,
    SafePath.RootBinding,
    SafePath.TraversalError,
    SensitiveData,
    NativeReaderArtifact
  ]
  @forbidden [
    Arbor.Common,
    Arbor.Common.Pagination,
    Arbor.KernelRuntime,
    Arbor.Security,
    Arbor.Contracts,
    Arbor.Custody,
    Arbor.Signals,
    Arbor.Capabilities
  ]

  def verify!(opts \\ []) do
    if Keyword.get(opts, :require_no_mix, false) do
      ensure(not Code.ensure_loaded?(Mix), "Mix code was present")
      ensure(:code.lib_dir(:mix) == {:error, :bad_name}, "Mix metadata was present")
    end

    {:ok, _started} = Application.ensure_all_started(:arbor_support)

    ensure(
      Application.spec(:arbor_support, :mod) in [nil, []],
      "support has an application callback"
    )

    ensure(
      Application.spec(:arbor_support, :registered) in [nil, []],
      "support declares registered roles"
    )

    assert_closure!()

    paths =
      Map.new(@modules, fn module ->
        ensure(Code.ensure_loaded?(module), "a public helper module was unavailable")

        ensure(
          :application.get_application(module) == {:ok, :arbor_support},
          "wrong module owner"
        )

        {Atom.to_string(module), List.to_string(:code.which(module))}
      end)

    ensure(
      not function_exported?(SafePath, :read_within_fixture, 3),
      "test-only race hook was published"
    )

    ensure(
      not function_exported?(SafePath, :read_within_materialization_fixture, 4),
      "test-only materialization hook was published"
    )

    embedded = NativeReaderArtifact.binary()
    embedded_hash = :crypto.hash(:sha256, embedded) |> Base.encode16(case: :lower)
    ensure(embedded_hash == NativeReaderArtifact.binary_sha256(), "embedded reader hash mismatch")

    ensure(
      NativeReaderArtifact.source_sha256() == System.fetch_env!("SUPPORT_COLD_C_SHA256"),
      "embedded reader does not match the archived C source"
    )

    ensure(byte_size(embedded) in 1..1_048_576, "embedded reader size is invalid")
    ebin = Path.dirname(List.to_string(:code.which(SafePath)))

    ensure(
      not File.exists?(Path.join(ebin, "arbor_safe_path_reader")),
      "runtime ebin deputy exists"
    )

    ensure(
      Enum.all?(Path.wildcard(Path.join(ebin, "*")), fn path ->
        case File.lstat(path) do
          {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) == 0
          _ -> false
        end
      end),
      "executable or nonregular ebin input exists"
    )

    fixture = System.fetch_env!("SUPPORT_COLD_FIXTURE_ROOT")
    ensure(Path.type(fixture) == :absolute, "fixture root is not absolute")
    File.mkdir!(fixture)
    File.chmod!(fixture, 0o700)
    {:ok, canonical_fixture} = SafePath.resolve_real(fixture)
    ensure(canonical_fixture == fixture, "fixture root has a symlink ancestor")
    readers_before = reader_directories()
    paths!(fixture)
    atoms!()
    cursor_check_groups = cursors!()
    sensitive_data!()
    ensure(reader_directories() == readers_before, "native reader materialization was stranded")
    :ok = Application.stop(:arbor_support)
    {:ok, _restarted} = Application.ensure_all_started(:arbor_support)
    assert_closure!()

    %{
      "package" => "arbor_support",
      "version" => Application.spec(:arbor_support, :vsn) |> List.to_string(),
      "checks" => [
        "passive exact support-only first-party closure and module ownership",
        "fresh C-source-bound embedded artifact without a runtime ebin deputy",
        "public descriptor read, validator ordering, denial and native self-unlink cleanup",
        "escape symlink, exact leaf and replaced bound-root refusals",
        "opened file descriptors retain original bytes across root and ancestor replacement",
        "existing and allowed atoms only; unknown bounded keys remain strings",
        "Cursor wire format, timestamp precision, strict tie ordering and invalid-cursor refusal",
        "PII and secret scan/redaction, entropy and Luhn signatures",
        "passive application stop and restart"
      ],
      "cursor_check_groups" => cursor_check_groups,
      "code_paths" => paths,
      "compiled_applications" => compiled_applications(),
      "loaded_applications" => app_names(Application.loaded_applications()),
      "started_applications" => app_names(Application.started_applications()),
      "native_source_sha256" => NativeReaderArtifact.source_sha256(),
      "native_binary_sha256" => embedded_hash,
      "native_binary_bytes" => byte_size(embedded),
      "mix_available" => Code.ensure_loaded?(Mix)
    }
  end

  defp paths!(fixture) do
    root = directory(fixture, "checked")
    candidate = Path.join(root, "candidate.txt")
    File.write!(candidate, "before-validation")
    {:ok, binding} = SafePath.bind_root(root)
    ensure(SafePath.binding_root(binding) == root, "bound root changed canonical identity")
    baseline = MapSet.new(Port.list())
    ref = make_ref()

    validator = fn opened_path ->
      ensure(opened_path == candidate, "validator saw the wrong opened path")
      observe_reader!(baseline, ref)
      File.write!(candidate, "after-validation")
      :ok
    end

    ensure(
      SafePath.read_within_bound_checked("candidate.txt", binding, validator) ==
        {:ok, "after-validation", candidate},
      "descriptor validation did not precede file DATA"
    )

    assert_reader_closed!(ref)
    ref = make_ref()

    ensure(
      SafePath.read_exact_bound_checked(candidate, binding, fn _path ->
        observe_reader!(baseline, ref)
        {:error, :fixture_constraint_denied}
      end) == {:error, :fixture_constraint_denied},
      "validator denial did not close the descriptor"
    )

    assert_reader_closed!(ref)

    outside = directory(fixture, "outside")
    outside_file = Path.join(outside, "outside.txt")
    File.write!(outside_file, "replacement-secret")
    File.ln_s!(outside_file, Path.join(root, "escape"))

    ensure(
      SafePath.read_within("escape", root) == {:error, :path_traversal},
      "escape symlink was read"
    )

    File.ln_s!(candidate, Path.join(root, "exact-link"))

    ensure(
      denied_path?(SafePath.read_exact("exact-link", root)),
      "exact leaf symlink was followed"
    )

    ensure(
      SafePath.resolve_within("../outside/outside.txt", root) == {:error, :path_traversal},
      "relative escape was admitted"
    )

    ensure(
      SafePath.safe_join(root, "%2e%2e/outside") == {:error, :traversal_sequence},
      "encoded traversal was admitted"
    )

    replaced = directory(fixture, "bound-root")
    File.write!(Path.join(replaced, "candidate.txt"), "bound-original")
    {:ok, old_binding} = SafePath.bind_root(replaced)
    File.rename!(replaced, replaced <> "-original")
    File.mkdir!(replaced)
    File.write!(Path.join(replaced, "candidate.txt"), "replacement-secret")

    ensure(
      SafePath.read_within_bound_checked("candidate.txt", old_binding, fn _ -> :ok end) ==
        {:error, :path_changed},
      "replaced bound root was admitted"
    )

    ensure(
      SafePath.read_exact_bound_checked("candidate.txt", old_binding, fn _ -> :ok end) ==
        {:error, :path_changed},
      "exact read admitted a replaced bound root"
    )

    ancestor_root = directory(fixture, "ancestor-before-open")
    ancestor = directory(ancestor_root, "ancestor")
    File.write!(Path.join(ancestor, "candidate.txt"), "ancestor-original")
    {:ok, ancestor_binding} = SafePath.bind_root(ancestor_root)
    File.rename!(ancestor, ancestor <> "-original")
    File.ln_s!(outside, ancestor)

    ensure(
      denied_path?(
        SafePath.read_within_bound_checked("ancestor/outside.txt", ancestor_binding, fn _ ->
          {:error, :unexpected_validator}
        end)
      ),
      "replaced ancestor escaped the bound root"
    )

    pinned_root = directory(fixture, "pinned-root")
    pinned_candidate = Path.join(pinned_root, "candidate.txt")
    File.write!(pinned_candidate, "pinned-root-original")

    ensure(
      SafePath.read_within_checked("candidate.txt", pinned_root, fn opened ->
        ensure(opened == pinned_candidate, "pinned root validator path changed")
        File.rename!(pinned_root, pinned_root <> "-original")
        File.ln_s!(outside, pinned_root)
        :ok
      end) == {:ok, "pinned-root-original", pinned_candidate},
      "opened root descriptor was redirected"
    )

    pinned_root = directory(fixture, "pinned-ancestor")
    ancestor = directory(pinned_root, "ancestor")
    pinned_candidate = Path.join(ancestor, "candidate.txt")
    File.write!(pinned_candidate, "pinned-ancestor-original")

    ensure(
      SafePath.read_within_checked("ancestor/candidate.txt", pinned_root, fn opened ->
        ensure(opened == pinned_candidate, "pinned ancestor validator path changed")
        File.rename!(ancestor, ancestor <> "-original")
        File.ln_s!(outside, ancestor)
        :ok
      end) == {:ok, "pinned-ancestor-original", pinned_candidate},
      "opened ancestor descriptor was redirected"
    )
  end

  defp observe_reader!(baseline, ref) do
    readers =
      for port <- Port.list(),
          not MapSet.member?(baseline, port),
          Port.info(port, :connected) == {:connected, self()},
          {:name, name} <- [Port.info(port, :name)],
          path = List.to_string(name),
          Path.basename(path) == "reader",
          String.starts_with?(Path.basename(Path.dirname(path)), "arbor-safe-path-reader-"),
          do: {port, path}

    ensure(length(readers) == 1, "read was not backed by one exact caller-owned native Port")
    [{port, executable}] = readers
    ensure(File.lstat(executable) == {:error, :enoent}, "executing reader image was not unlinked")

    ensure(
      File.lstat(Path.dirname(executable)) == {:error, :enoent},
      "reader directory survived READY"
    )

    send(self(), {ref, port})
    :ok
  end

  defp assert_reader_closed!(ref) do
    receive do
      {^ref, port} -> await_port_closed!(port, 100)
    after
      0 -> ensure(false, "native reader observation was missing")
    end
  end

  defp await_port_closed!(port, attempts) do
    if Port.info(port) == nil do
      :ok
    else
      ensure(attempts > 0, "owned native Port survived read completion")

      receive do
      after
        10 -> await_port_closed!(port, attempts - 1)
      end
    end
  end

  defp atoms! do
    ensure(SafeAtom.to_existing("ok") == {:ok, :ok}, "existing atom conversion changed")

    ensure(
      SafeAtom.to_allowed("read", [:read, :write]) == {:ok, :read},
      "allowed atom conversion changed"
    )

    ensure(
      SafeAtom.to_allowed(:error, [:read, :write]) == {:error, {:not_allowed, :error}},
      "existing disallowed atom was admitted"
    )

    for _ <- 1..16 do
      unknown = "support_unknown_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      ensure(unknown_atom?(unknown), "atom probe was not initially unknown")

      ensure(
        SafeAtom.to_existing(unknown) == {:error, {:unknown_atom, unknown}},
        "unknown atom was admitted"
      )

      ensure(
        SafeAtom.to_allowed(unknown, [:read]) == {:error, {:not_allowed, unknown}},
        "unknown allowed atom was admitted"
      )

      ensure(
        SafeAtom.atomize_keys(%{"name" => "safe", unknown => 1}, [:name]) ==
          %{unknown => 1, name: "safe"},
        "unknown map key was atomized"
      )

      ensure(
        SafeAtom.atomize_keys_deep(%{"name" => %{"name" => "safe", unknown => 1}},
          known_keys: [:name],
          nested: %{name: [known_keys: [:name]]}
        ) ==
          %{name: %{unknown => 1, name: "safe"}},
        "unknown nested key was atomized"
      )

      ensure(unknown_atom?(unknown), "public conversion allocated an attacker-selected atom")
    end
  end

  defp unknown_atom?(value) do
    _existing_atom = String.to_existing_atom(value)
    false
  rescue
    ArgumentError -> true
  end

  defp cursors! do
    timestamp = ~U[2024-01-13 12:00:00.123456Z]
    milliseconds = 1_705_147_200_123
    identifier = "record:with:colons"
    encoded = "1705147200123:record:with:colons"

    ensure(
      Cursor.generate(timestamp, identifier) == encoded,
      "DateTime cursor wire format changed"
    )

    ensure(
      Cursor.generate(milliseconds, identifier) == encoded,
      "integer cursor wire format changed"
    )

    ensure(
      Cursor.parse(encoded) == {:ok, {milliseconds, identifier}},
      "cursor parse round trip changed"
    )

    ensure(Cursor.parse("-1:before") == {:ok, {-1, "before"}}, "signed timestamp parsing changed")

    millisecond_time = DateTime.truncate(timestamp, :millisecond)

    ensure(
      Cursor.parse_datetime(encoded) == {:ok, {millisecond_time, identifier}},
      "millisecond DateTime cursor round trip changed"
    )

    micro_cursor = Integer.to_string(DateTime.to_unix(timestamp, :microsecond)) <> ":b"

    ensure(
      Cursor.parse_datetime(micro_cursor, precision: :microsecond) == {:ok, {timestamp, "b"}},
      "microsecond DateTime cursor round trip changed"
    )

    for {order, passing, refused} <- [{:asc, "c", "a"}, {:desc, "a", "c"}] do
      ensure(
        Cursor.passes_filter?(milliseconds, passing, milliseconds, "b", order),
        "equal-time cursor ID ordering changed"
      )

      ensure(
        not Cursor.passes_filter?(milliseconds, refused, milliseconds, "b", order),
        "reverse equal-time cursor ID was included"
      )

      ensure(
        not Cursor.passes_filter?(milliseconds, "b", milliseconds, "b", order),
        "cursor boundary record was repeated"
      )
    end

    records = [
      %{timestamp: DateTime.add(millisecond_time, -1, :millisecond), id: "older"},
      %{timestamp: millisecond_time, id: "a"},
      %{timestamp: millisecond_time, id: "b"},
      %{timestamp: millisecond_time, id: "c"},
      %{timestamp: DateTime.add(millisecond_time, 1, :millisecond), id: "newer"}
    ]

    opts = [timestamp_fn: & &1.timestamp, id_fn: & &1.id]
    boundary = Cursor.generate(millisecond_time, "b")
    invalid_cursors = ["invalid", "abc:record", "123junk:record", "123:", ""]

    for invalid <- invalid_cursors do
      ensure(Cursor.parse(invalid) == :error, "malformed encoded cursor parsed")
      ensure(Cursor.parse_datetime(invalid) == :error, "malformed DateTime cursor parsed")
    end

    for invalid <- [nil, 123, %{}] do
      ensure(Cursor.parse(invalid) == :error, "nonbinary cursor parsed")
    end

    for {order, expected} <- [asc: ["c", "newer"], desc: ["older", "a"]] do
      ensure(
        Enum.map(Cursor.filter_records(records, boundary, order, opts), & &1.id) == expected,
        "millisecond cursor selection or stable input ordering changed"
      )

      ensure(
        Enum.map(Cursor.filter_records_datetime(records, boundary, order, opts), & &1.id) ==
          expected,
        "DateTime cursor selection or stable input ordering changed"
      )

      ensure(
        Cursor.filter_records(records, nil, order, []) == records,
        "nil cursor did not preserve the input records"
      )

      ensure(
        Cursor.filter_records_datetime(records, nil, order, []) == records,
        "nil DateTime cursor did not preserve the input records"
      )

      for invalid <- invalid_cursors do
        ensure(
          Cursor.filter_records(records, invalid, order, opts) == [],
          "malformed cursor did not fail closed"
        )

        ensure(
          Cursor.filter_records_datetime(records, invalid, order, opts) == [],
          "malformed DateTime cursor did not fail closed"
        )
      end
    end

    micro_records = [
      %{timestamp: DateTime.add(timestamp, -1, :microsecond), id: "z_before"},
      %{timestamp: timestamp, id: "a"},
      %{timestamp: timestamp, id: "b"},
      %{timestamp: timestamp, id: "c"},
      %{timestamp: DateTime.add(timestamp, 1, :microsecond), id: "a_after"}
    ]

    for {order, expected} <- [asc: ["c", "a_after"], desc: ["z_before", "a"]] do
      selected =
        Cursor.filter_records_datetime(
          micro_records,
          micro_cursor,
          order,
          Keyword.put(opts, :precision, :microsecond)
        )

      ensure(
        Enum.map(selected, & &1.id) == expected,
        "microsecond cursor precision or equal-time ID ordering changed"
      )
    end

    7
  end

  defp sensitive_data! do
    findings = SensitiveData.scan_pii("Contact john.doe@company.com for help")

    ensure(
      Enum.any?(findings, fn {label, _} -> label == "Email Address" end),
      "PII scan signature changed"
    )

    ensure(
      not Enum.any?(SensitiveData.scan_pii("test@example.com"), fn {label, _} ->
        label == "Email Address"
      end),
      "PII fixture filtering changed"
    )

    text =
      ~s({"access_token":"tiny","credentials":"smallcred","authorization":"Bearer short-token","public":"keep"})

    redacted = SensitiveData.redact_secrets(text)

    ensure(
      Enum.all?(["tiny", "smallcred", "short-token"], &(not String.contains?(redacted, &1))),
      "labeled secret values survived redaction"
    )

    ensure(String.contains?(redacted, ~s("public":"keep")), "public material was redacted")
    blob = "mF9aQ2rX8vL4nP6sT1uW3yZ5bC7dE9gH0jK2lM4oP6qR8sT0"

    ensure(
      not String.contains?(SensitiveData.redact_secrets("payload=" <> blob), blob),
      "entropy secret survived redaction"
    )

    key_block =
      "-----BEGIN " <>
        "ENCRYPTED PRIVATE KEY-----\nprivate-body\n-----END ENCRYPTED PRIVATE KEY-----"

    ensure(
      SensitiveData.redact_secrets("before\n" <> key_block <> "\nafter") ==
        "before\n[REDACTED]\nafter",
      "private-key block redaction changed"
    )

    ensure(
      SensitiveData.scan_secrets("CANARY_marker",
        additional_patterns: [{~r/CANARY_[a-z]+/, "Standalone"}]
      ) ==
        [{"Standalone", "CANARY_marker"}],
      "additional secret scan signature changed"
    )

    ensure(
      Enum.any?(SensitiveData.scan_all("john.doe@company.com"), fn {label, _} ->
        label == "Email Address"
      end),
      "combined sensitive-data scan changed"
    )

    ensure(
      not String.contains?(
        SensitiveData.redact_pii("john.doe@company.com"),
        "john.doe@company.com"
      ),
      "PII redaction signature changed"
    )

    ensure(abs(SensitiveData.shannon_entropy("ab") - 1.0) < 0.01, "entropy signature changed")

    ensure(
      SensitiveData.valid_luhn?("4532015112830366") and
        not SensitiveData.valid_luhn?("4532015112830367"),
      "Luhn signature changed"
    )
  end

  defp directory(parent, name) do
    path = Path.join(parent, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp denied_path?({:error, reason}),
    do: reason in [:path_changed, :path_traversal, :not_regular]

  defp denied_path?(_other), do: false

  defp reader_directories,
    do:
      File.ls!("/tmp")
      |> Enum.filter(&String.starts_with?(&1, "arbor-safe-path-reader-"))
      |> Enum.sort()

  defp assert_closure! do
    for apps <- [Application.loaded_applications(), Application.started_applications()] do
      first_party = apps |> app_names() |> Enum.filter(&String.starts_with?(&1, "arbor_"))
      ensure(first_party == ["arbor_support"], "unexpected first-party application closure")
    end

    ensure(
      compiled_applications() == ["arbor_support"],
      "unexpected first-party compiled closure"
    )

    ensure(Enum.all?(@forbidden, &(not Code.ensure_loaded?(&1))), "product code was available")
  end

  defp app_names(apps),
    do: apps |> Enum.map(fn {app, _, _} -> Atom.to_string(app) end) |> Enum.sort()

  defp compiled_applications do
    :code.get_path()
    |> Enum.map(&Path.basename(Path.dirname(List.to_string(&1))))
    |> Enum.filter(&String.starts_with?(&1, "arbor_"))
    |> Enum.map(&String.replace(&1, ~r/-\d.*$/, ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("Support qualification failed: " <> label)
end
