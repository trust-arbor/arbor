defmodule Arbor.Actions.Security.FindingStoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.FindingStore
  alias Arbor.Contracts.Security.Finding

  setup do
    dir = Path.join(System.tmp_dir!(), "sentinel_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    finding =
      Finding.new(
        category: :fail_open_authz,
        title: "authorize/3 rescues to :ok",
        location: %{file: "apps/x/lib/a.ex", function: "authorize", line: 10}
      )

    {:ok, dir: dir, finding: finding}
  end

  describe "record/2 status lifecycle" do
    test "first sighting is recorded as open", %{dir: dir, finding: f} do
      assert {:recorded, recorded} = FindingStore.record(f, dir)
      assert recorded.status == :open
      assert FindingStore.current_status(f.id, dir) == :open
    end

    test "re-detection of an open finding refreshes, keeps status", %{dir: dir, finding: f} do
      FindingStore.record(f, dir)
      assert {:updated, updated} = FindingStore.record(f, dir)
      assert updated.status == :open
    end

    test "a finding triaged wontfix is SUPPRESSED on re-detection", %{dir: dir, finding: f} do
      FindingStore.record(f, dir)
      :ok = FindingStore.set_status(f.id, :wontfix, dir: dir)

      assert {:suppressed, :wontfix} = FindingStore.record(f, dir)
      # status unchanged — the human decision sticks
      assert FindingStore.current_status(f.id, dir) == :wontfix
    end

    test "a false_positive is suppressed too (feedback channel)", %{dir: dir, finding: f} do
      FindingStore.record(f, dir)
      :ok = FindingStore.set_status(f.id, :false_positive, dir: dir, note: "test fixture")
      assert {:suppressed, :false_positive} = FindingStore.record(f, dir)
    end

    test "a FIXED finding that reappears reopens as a regression", %{dir: dir, finding: f} do
      FindingStore.record(f, dir)
      :ok = FindingStore.set_status(f.id, :fixed, dir: dir)

      assert {:reopened, reopened} = FindingStore.record(f, dir)
      assert reopened.status == :regressed
      assert FindingStore.current_status(f.id, dir) == :regressed
    end
  end

  describe "set_status/3" do
    test "errors for an unknown finding", %{dir: dir} do
      assert {:error, :not_found} =
               FindingStore.set_status("sec-finding_nope", :wontfix, dir: dir)
    end

    test "appends a note", %{dir: dir, finding: f} do
      FindingStore.record(f, dir)
      :ok = FindingStore.set_status(f.id, :false_positive, dir: dir, note: "matches fixture")
      content = File.read!(Path.join(dir, f.id <> ".md"))
      assert content =~ "status: false_positive"
      assert content =~ "matches fixture"
    end
  end

  describe "list/1" do
    test "lists all and filters by status", %{dir: dir, finding: f} do
      other =
        Finding.new(
          category: :crypto_weakness,
          title: "weak",
          location: %{file: "apps/y/lib/b.ex", function: "verify"}
        )

      FindingStore.record(f, dir)
      FindingStore.record(other, dir)
      :ok = FindingStore.set_status(other.id, :wontfix, dir: dir)

      assert length(FindingStore.list(dir: dir)) == 2
      assert [{id, :wontfix}] = FindingStore.list(dir: dir, status: :wontfix)
      assert id == other.id
      assert [{open_id, :open}] = FindingStore.list(dir: dir, status: :open)
      assert open_id == f.id
    end

    test "empty store lists nothing", %{dir: dir} do
      assert FindingStore.list(dir: dir) == []
    end
  end

  describe "Finding markdown round-trip" do
    test "status_from_markdown reads what to_markdown wrote", %{finding: f} do
      assert Finding.status_from_markdown(Finding.to_markdown(f)) == :open
    end

    test "replace_status_in_markdown swaps the frontmatter status", %{finding: f} do
      md = Finding.to_markdown(f)
      assert {:ok, updated} = Finding.replace_status_in_markdown(md, :triaged)
      assert Finding.status_from_markdown(updated) == :triaged
      # only the frontmatter line changed; the title is intact
      assert updated =~ "authorize/3 rescues to :ok"
    end

    test "status_from_markdown returns nil for content with no frontmatter" do
      assert Finding.status_from_markdown("# just a heading\n") == nil
    end
  end
end
