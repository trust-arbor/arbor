defmodule Arbor.Persistence.BackupTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Backup

  @moduletag :fast

  describe "parse_backup_date/1" do
    test "parses valid backup filename" do
      datetime = Backup.parse_backup_date("arbor-2026-01-30-153045.sql.age")

      assert datetime.year == 2026
      assert datetime.month == 1
      assert datetime.day == 30
      assert datetime.hour == 15
      assert datetime.minute == 30
      assert datetime.second == 45
    end

    test "handles midnight timestamp" do
      datetime = Backup.parse_backup_date("arbor-2026-12-25-000000.sql.age")

      assert datetime.year == 2026
      assert datetime.month == 12
      assert datetime.day == 25
      assert datetime.hour == 0
      assert datetime.minute == 0
      assert datetime.second == 0
    end

    test "returns current time for invalid filename" do
      before = DateTime.utc_now()
      datetime = Backup.parse_backup_date("invalid-filename.txt")
      after_time = DateTime.utc_now()

      assert DateTime.compare(datetime, before) in [:gt, :eq]
      assert DateTime.compare(datetime, after_time) in [:lt, :eq]
    end
  end

  describe "calculate_retention/2" do
    test "keeps last N daily backups" do
      backups = generate_backups(10, :daily)
      retention = [daily: 3, weekly: 0, monthly: 0]

      keeps = Backup.calculate_retention(backups, retention)

      # Should keep the 3 most recent
      assert MapSet.size(keeps) == 3

      # Newest 3 should be kept
      newest_3 = backups |> Enum.sort_by(& &1.date, {:desc, DateTime}) |> Enum.take(3)

      for backup <- newest_3 do
        assert MapSet.member?(keeps, backup.path)
      end
    end

    test "keeps first backup of each week" do
      # Generate backups across 5 weeks
      backups = generate_weekly_backups(5, 2)
      retention = [daily: 0, weekly: 3, monthly: 0]

      keeps = Backup.calculate_retention(backups, retention)

      # Should keep first backup of each of the last 3 weeks
      # Since we have multiple backups per week, we keep the earliest of each week
      assert MapSet.size(keeps) == 3
    end

    test "keeps first backup of each month" do
      # Generate backups across 4 months
      backups = generate_monthly_backups(4, 3)
      retention = [daily: 0, weekly: 0, monthly: 2]

      keeps = Backup.calculate_retention(backups, retention)

      # Should keep first backup of each of the last 2 months
      assert MapSet.size(keeps) == 2
    end

    test "union of daily, weekly, and monthly keeps" do
      # Generate a mix of backups
      backups = generate_backups(14, :daily)
      retention = [daily: 3, weekly: 2, monthly: 1]

      keeps = Backup.calculate_retention(backups, retention)

      # Should be union of all retention rules
      # Daily: 3 most recent
      # Weekly: first of last 2 weeks
      # Monthly: first of last 1 month
      # Some may overlap, so size <= 6
      assert MapSet.size(keeps) >= 3
      assert MapSet.size(keeps) <= 6
    end

    test "handles empty backup list" do
      keeps = Backup.calculate_retention([], daily: 7, weekly: 4, monthly: 3)
      assert MapSet.size(keeps) == 0
    end

    test "handles fewer backups than retention count" do
      backups = generate_backups(2, :daily)
      retention = [daily: 7, weekly: 4, monthly: 3]

      keeps = Backup.calculate_retention(backups, retention)

      # Should keep all 2 backups
      assert MapSet.size(keeps) == 2
    end
  end

  describe "list_backups/1" do
    setup do
      # Create a temp directory for testing
      tmp_dir = Path.join(System.tmp_dir!(), "arbor_backup_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, backup_dir: tmp_dir}
    end

    test "returns empty list for empty directory", %{backup_dir: dir} do
      backups = Backup.list_backups(backup_dir: dir)
      assert backups == []
    end

    test "returns empty list for non-existent directory" do
      backups = Backup.list_backups(backup_dir: "/nonexistent/path/12345")
      assert backups == []
    end

    test "lists backup files with correct metadata", %{backup_dir: dir} do
      # Create some fake backup files
      file1 = Path.join(dir, "arbor-2026-01-30-100000.sql.age")
      file2 = Path.join(dir, "arbor-2026-01-29-030000.sql.age")

      File.write!(file1, "backup data 1")
      File.write!(file2, "backup data 2 longer")

      backups = Backup.list_backups(backup_dir: dir)

      assert length(backups) == 2

      # Should be sorted by date descending
      [newer, older] = backups

      assert newer.filename == "arbor-2026-01-30-100000.sql.age"
      assert newer.date.day == 30
      assert newer.size == byte_size("backup data 1")

      assert older.filename == "arbor-2026-01-29-030000.sql.age"
      assert older.date.day == 29
    end

    test "ignores non-backup files", %{backup_dir: dir} do
      # Create backup and non-backup files
      File.write!(Path.join(dir, "arbor-2026-01-30-100000.sql.age"), "backup")
      File.write!(Path.join(dir, "other-file.txt"), "not a backup")
      File.write!(Path.join(dir, "arbor-incomplete.sql"), "also not a backup")

      backups = Backup.list_backups(backup_dir: dir)

      assert length(backups) == 1
      assert hd(backups).filename == "arbor-2026-01-30-100000.sql.age"
    end
  end

  # Helper functions for generating test data

  defp generate_backups(count, :daily) do
    base_date = DateTime.utc_now()

    Enum.map(0..(count - 1), fn days_ago ->
      date = DateTime.add(base_date, -days_ago, :day)
      filename = format_backup_filename(date)

      %{
        path: "/backups/#{filename}",
        filename: filename,
        date: date,
        size: 1000
      }
    end)
  end

  defp generate_weekly_backups(weeks, backups_per_week) do
    base_date = DateTime.utc_now()

    for week <- 0..(weeks - 1), day <- 0..(backups_per_week - 1) do
      date = DateTime.add(base_date, -(week * 7 + day), :day)
      filename = format_backup_filename(date)

      %{
        path: "/backups/#{filename}",
        filename: filename,
        date: date,
        size: 1000
      }
    end
  end

  defp generate_monthly_backups(months, backups_per_month) do
    base_date = DateTime.utc_now()

    for month <- 0..(months - 1), day <- 0..(backups_per_month - 1) do
      date = DateTime.add(base_date, -(month * 30 + day), :day)
      filename = format_backup_filename(date)

      %{
        path: "/backups/#{filename}",
        filename: filename,
        date: date,
        size: 1000
      }
    end
  end

  defp format_backup_filename(datetime) do
    timestamp = Calendar.strftime(datetime, "%Y-%m-%d-%H%M%S")
    "arbor-#{timestamp}.sql.age"
  end
end
