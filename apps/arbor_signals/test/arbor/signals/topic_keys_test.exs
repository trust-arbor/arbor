defmodule Arbor.Signals.TopicKeysTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.TopicKeys

  describe "get_or_create/1" do
    test "creates a new key for a topic" do
      {:ok, key_info} = TopicKeys.get_or_create(:test_topic_a)

      assert is_binary(key_info.key)
      assert byte_size(key_info.key) == 32
      assert key_info.version == 1
      assert %DateTime{} = key_info.created_at
      assert is_nil(key_info.rotated_at)
    end

    test "returns existing key on subsequent calls" do
      {:ok, key_info1} = TopicKeys.get_or_create(:test_topic_b)
      {:ok, key_info2} = TopicKeys.get_or_create(:test_topic_b)

      assert key_info1.key == key_info2.key
      assert key_info1.version == key_info2.version
    end

    test "creates different keys for different topics" do
      {:ok, key_info1} = TopicKeys.get_or_create(:test_topic_c)
      {:ok, key_info2} = TopicKeys.get_or_create(:test_topic_d)

      refute key_info1.key == key_info2.key
    end
  end

  describe "get/1" do
    test "returns error for non-existent topic" do
      assert {:error, :no_key} = TopicKeys.get(:nonexistent_topic)
    end

    test "returns key info for existing topic" do
      {:ok, created} = TopicKeys.get_or_create(:test_topic_e)
      {:ok, fetched} = TopicKeys.get(:test_topic_e)

      assert created.key == fetched.key
    end
  end

  describe "rotate/1" do
    test "generates a new key and increments version" do
      {:ok, original} = TopicKeys.get_or_create(:test_topic_f)
      {:ok, rotated} = TopicKeys.rotate(:test_topic_f)

      refute original.key == rotated.key
      assert rotated.version == 2
      assert %DateTime{} = rotated.rotated_at
    end

    test "can rotate multiple times" do
      {:ok, _} = TopicKeys.get_or_create(:test_topic_g)
      {:ok, _} = TopicKeys.rotate(:test_topic_g)
      {:ok, rotated} = TopicKeys.rotate(:test_topic_g)

      assert rotated.version == 3
    end

    test "creates key if none exists" do
      {:ok, key_info} = TopicKeys.rotate(:new_rotate_topic)

      assert key_info.version == 1
    end
  end

  describe "encrypt/2 and decrypt/2" do
    test "encrypts and decrypts data successfully" do
      plaintext = "secret data to encrypt"

      {:ok, encrypted} = TopicKeys.encrypt(:test_topic_h, plaintext)

      assert is_binary(encrypted.ciphertext)
      assert is_binary(encrypted.iv)
      assert is_binary(encrypted.tag)
      assert encrypted.key_version == 1

      {:ok, decrypted} = TopicKeys.decrypt(:test_topic_h, encrypted)

      assert decrypted == plaintext
    end

    test "decryption fails with key version mismatch" do
      {:ok, encrypted} = TopicKeys.encrypt(:test_topic_i, "data")
      {:ok, _} = TopicKeys.rotate(:test_topic_i)

      assert {:error, :key_version_mismatch} = TopicKeys.decrypt(:test_topic_i, encrypted)
    end

    test "decryption fails for unknown topic" do
      {:ok, encrypted} = TopicKeys.encrypt(:test_topic_j, "data")

      # Create a fake payload with a different topic's key version
      fake_payload = %{encrypted | key_version: 99}

      assert {:error, :key_version_mismatch} = TopicKeys.decrypt(:test_topic_j, fake_payload)
    end

    test "handles empty string" do
      {:ok, encrypted} = TopicKeys.encrypt(:test_topic_k, "")
      {:ok, decrypted} = TopicKeys.decrypt(:test_topic_k, encrypted)

      assert decrypted == ""
    end

    test "handles binary data" do
      binary_data = <<1, 2, 3, 4, 5, 255, 0, 127>>

      {:ok, encrypted} = TopicKeys.encrypt(:test_topic_l, binary_data)
      {:ok, decrypted} = TopicKeys.decrypt(:test_topic_l, encrypted)

      assert decrypted == binary_data
    end
  end

  describe "stats/0" do
    test "returns statistics" do
      # Ensure at least one key exists
      TopicKeys.get_or_create(:stats_test_topic)

      stats = TopicKeys.stats()

      assert is_integer(stats.keys_created)
      assert is_integer(stats.keys_rotated)
      assert is_integer(stats.encryptions)
      assert is_integer(stats.decryptions)
      assert is_integer(stats.active_topic_keys)
      assert is_list(stats.topics)
    end
  end
end
