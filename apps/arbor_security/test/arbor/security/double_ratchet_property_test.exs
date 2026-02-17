defmodule Arbor.Security.DoubleRatchetPropertyTest do
  @moduledoc """
  Property-based and randomized tests for the Double Ratchet protocol.

  Validates cryptographic invariants:
  - Ratchet forward never produces duplicate keys
  - Encrypt/decrypt round-trip holds for arbitrary plaintexts
  - Serialization round-trip preserves session state
  - Per-message forward secrecy (each message key is unique)
  - Out-of-order delivery with arbitrary skip patterns
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Security.Crypto
  alias Arbor.Security.DoubleRatchet

  # Keep iteration counts low for speed
  @property_runs 50

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_session_pair do
    alice_keypair = Crypto.generate_encryption_keypair()
    bob_keypair = Crypto.generate_encryption_keypair()
    {_alice_pub, alice_priv} = alice_keypair
    {bob_pub, bob_priv} = bob_keypair

    shared_secret = Crypto.derive_shared_secret(alice_priv, bob_pub)
    ^shared_secret = Crypto.derive_shared_secret(bob_priv, elem(alice_keypair, 0))

    alice = DoubleRatchet.init_sender(shared_secret, bob_pub)
    bob = DoubleRatchet.init_receiver(shared_secret, bob_keypair)

    {alice, bob}
  end

  defp random_plaintext do
    length = :rand.uniform(256)
    :crypto.strong_rand_bytes(length)
  end

  defp random_ascii_plaintext do
    length = :rand.uniform(128) + 1
    for(_ <- 1..length, do: :rand.uniform(94) + 31)
    |> List.to_string()
  end

  # ---------------------------------------------------------------------------
  # Property: Round-trip holds for arbitrary plaintexts
  # ---------------------------------------------------------------------------

  describe "property: encrypt/decrypt round-trip" do
    test "holds for random binary plaintexts" do
      Enum.each(1..@property_runs, fn _i ->
        {alice, bob} = setup_session_pair()
        plaintext = random_plaintext()

        {_alice2, header, ciphertext} = DoubleRatchet.encrypt(alice, plaintext)
        {:ok, _bob2, decrypted} = DoubleRatchet.decrypt(bob, header, ciphertext)

        assert decrypted == plaintext,
               "Round-trip failed for plaintext of size #{byte_size(plaintext)}"
      end)
    end

    test "holds for empty plaintext" do
      {alice, bob} = setup_session_pair()
      {_alice2, header, ciphertext} = DoubleRatchet.encrypt(alice, "")
      {:ok, _bob2, decrypted} = DoubleRatchet.decrypt(bob, header, ciphertext)
      assert decrypted == ""
    end

    test "holds for large plaintext (64KB)" do
      {alice, bob} = setup_session_pair()
      plaintext = :crypto.strong_rand_bytes(65_536)
      {_alice2, header, ciphertext} = DoubleRatchet.encrypt(alice, plaintext)
      {:ok, _bob2, decrypted} = DoubleRatchet.decrypt(bob, header, ciphertext)
      assert decrypted == plaintext
    end
  end

  # ---------------------------------------------------------------------------
  # Property: Chain ratchet never produces duplicate message keys
  # ---------------------------------------------------------------------------

  describe "property: no duplicate message keys" do
    test "sequential sends produce unique ciphertexts for identical plaintext" do
      Enum.each(1..div(@property_runs, 5), fn _i ->
        {alice, _bob} = setup_session_pair()
        plaintext = "identical"
        count = :rand.uniform(20) + 5

        {_final_alice, ciphertexts} =
          Enum.reduce(1..count, {alice, []}, fn _n, {session, acc} ->
            {session2, _header, ct} = DoubleRatchet.encrypt(session, plaintext)
            {session2, [ct | acc]}
          end)

        unique_count = ciphertexts |> Enum.uniq() |> length()

        assert unique_count == count,
               "Expected #{count} unique ciphertexts, got #{unique_count}"
      end)
    end

    test "chain keys never repeat within a session" do
      {alice, _bob} = setup_session_pair()
      count = 50

      {_final, chain_keys} =
        Enum.reduce(1..count, {alice, [alice.send_chain.key]}, fn _n, {session, keys} ->
          {session2, _header, _ct} = DoubleRatchet.encrypt(session, "x")
          {session2, [session2.send_chain.key | keys]}
        end)

      unique_keys = Enum.uniq(chain_keys)
      assert length(unique_keys) == count + 1, "Chain keys repeated within #{count} advances"
    end
  end

  # ---------------------------------------------------------------------------
  # Property: Multi-message sequential delivery always succeeds
  # ---------------------------------------------------------------------------

  describe "property: sequential multi-message delivery" do
    test "random number of messages all decrypt correctly" do
      Enum.each(1..div(@property_runs, 5), fn _i ->
        {alice, bob} = setup_session_pair()
        count = :rand.uniform(15) + 1

        messages =
          for _ <- 1..count do
            random_ascii_plaintext()
          end

        {_final_alice, _final_bob, decrypted} =
          Enum.reduce(messages, {alice, bob, []}, fn msg, {a, b, acc} ->
            {a2, header, ct} = DoubleRatchet.encrypt(a, msg)
            {:ok, b2, pt} = DoubleRatchet.decrypt(b, header, ct)
            {a2, b2, acc ++ [pt]}
          end)

        assert decrypted == messages
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Property: Bidirectional conversation maintains correctness
  # ---------------------------------------------------------------------------

  describe "property: bidirectional conversation" do
    test "random ping-pong exchanges all decrypt" do
      Enum.each(1..div(@property_runs, 5), fn _i ->
        {alice, bob} = setup_session_pair()
        exchanges = :rand.uniform(8) + 2

        # Alternate sender: alice sends odd rounds, bob sends even rounds
        # First message must be from alice (sender)
        {_a, _b, results} =
          Enum.reduce(1..exchanges, {alice, bob, []}, fn round, {a, b, acc} ->
            if rem(round, 2) == 1 do
              msg = "alice-#{round}"
              {a2, header, ct} = DoubleRatchet.encrypt(a, msg)
              {:ok, b2, pt} = DoubleRatchet.decrypt(b, header, ct)
              {a2, b2, [{:alice, msg, pt} | acc]}
            else
              msg = "bob-#{round}"
              {b2, header, ct} = DoubleRatchet.encrypt(b, msg)
              {:ok, a2, pt} = DoubleRatchet.decrypt(a, header, ct)
              {a2, b2, [{:bob, msg, pt} | acc]}
            end
          end)

        Enum.each(results, fn {sender, original, decrypted} ->
          assert original == decrypted,
                 "Bidirectional mismatch from #{sender}: expected #{inspect(original)}, got #{inspect(decrypted)}"
        end)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Property: Out-of-order delivery works for various skip patterns
  # ---------------------------------------------------------------------------

  describe "property: out-of-order delivery" do
    test "shuffled delivery order still decrypts all messages" do
      Enum.each(1..div(@property_runs, 5), fn _i ->
        {alice, bob} = setup_session_pair()
        count = :rand.uniform(8) + 3

        messages = for n <- 1..count, do: "msg-#{n}"

        # Alice encrypts all messages in order
        {_final_alice, encrypted} =
          Enum.reduce(messages, {alice, []}, fn msg, {a, acc} ->
            {a2, header, ct} = DoubleRatchet.encrypt(a, msg)
            {a2, [{msg, header, ct} | acc]}
          end)

        # Shuffle the encrypted messages
        shuffled = Enum.shuffle(encrypted)

        # Bob decrypts in shuffled order
        {_final_bob, decrypted_set} =
          Enum.reduce(shuffled, {bob, MapSet.new()}, fn {_orig, header, ct}, {b, set} ->
            {:ok, b2, pt} = DoubleRatchet.decrypt(b, header, ct)
            {b2, MapSet.put(set, pt)}
          end)

        # All messages should be recovered
        original_set = MapSet.new(messages)
        assert decrypted_set == original_set
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Property: Serialization round-trip preserves behavior
  # ---------------------------------------------------------------------------

  describe "property: serialization preserves session" do
    test "serialize/deserialize then continue encrypting" do
      Enum.each(1..div(@property_runs, 5), fn _i ->
        {alice, bob} = setup_session_pair()

        # Send some messages to advance state
        advance_count = :rand.uniform(5)

        {alice2, bob2} =
          Enum.reduce(1..advance_count, {alice, bob}, fn n, {a, b} ->
            {a2, h, ct} = DoubleRatchet.encrypt(a, "advance-#{n}")
            {:ok, b2, _pt} = DoubleRatchet.decrypt(b, h, ct)
            {a2, b2}
          end)

        # Serialize and restore alice
        alice_map = DoubleRatchet.to_map(alice2)
        {:ok, alice_restored} = DoubleRatchet.from_map(alice_map)

        # Verify restored session can still communicate
        plaintext = random_ascii_plaintext()
        {_a3, header, ct} = DoubleRatchet.encrypt(alice_restored, plaintext)
        {:ok, _b3, decrypted} = DoubleRatchet.decrypt(bob2, header, ct)
        assert decrypted == plaintext
      end)
    end

    test "to_map and from_map are inverse operations" do
      Enum.each(1..@property_runs, fn _i ->
        {alice, _bob} = setup_session_pair()

        # Advance state randomly
        advance = :rand.uniform(3)

        alice2 =
          Enum.reduce(1..advance, alice, fn _n, a ->
            {a2, _h, _ct} = DoubleRatchet.encrypt(a, "x")
            a2
          end)

        map = DoubleRatchet.to_map(alice2)
        {:ok, restored} = DoubleRatchet.from_map(map)

        # Structural equality
        assert restored.dh_keypair == alice2.dh_keypair
        assert restored.dh_remote == alice2.dh_remote
        assert restored.root_key == alice2.root_key
        assert restored.send_chain.key == alice2.send_chain.key
        assert restored.send_chain.n == alice2.send_chain.n
        assert restored.recv_chain.key == alice2.recv_chain.key
        assert restored.recv_chain.n == alice2.recv_chain.n
        assert restored.max_skip == alice2.max_skip
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Property: AAD binding is enforced
  # ---------------------------------------------------------------------------

  describe "property: AAD binding" do
    test "mismatched AAD always causes decryption failure" do
      Enum.each(1..@property_runs, fn _i ->
        {alice, bob} = setup_session_pair()
        plaintext = random_ascii_plaintext()
        aad = :crypto.strong_rand_bytes(:rand.uniform(32))

        {_a2, header, ct} = DoubleRatchet.encrypt(alice, plaintext, aad)

        # Use different AAD for decryption
        wrong_aad = :crypto.strong_rand_bytes(:rand.uniform(32) + 1)

        # We need a fresh bob for each attempt since failed decrypt may leave
        # the session in an intermediate state
        result = DoubleRatchet.decrypt(bob, header, ct, wrong_aad)
        assert {:error, :decryption_failed} = result
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Property: Root key evolves on DH ratchet step
  # ---------------------------------------------------------------------------

  describe "property: DH ratchet advancement" do
    test "root key changes after each direction switch" do
      Enum.each(1..div(@property_runs, 5), fn _i ->
        {alice, bob} = setup_session_pair()

        # Alice -> Bob (initial)
        {alice2, h1, c1} = DoubleRatchet.encrypt(alice, "hello")
        {:ok, bob2, _m1} = DoubleRatchet.decrypt(bob, h1, c1)
        bob_root_1 = bob2.root_key

        # Bob -> Alice (DH ratchet on Alice)
        {bob3, h2, c2} = DoubleRatchet.encrypt(bob2, "reply")
        {:ok, alice3, _m2} = DoubleRatchet.decrypt(alice2, h2, c2)
        alice_root_after_ratchet = alice3.root_key

        # Root key must have changed on Alice's side
        assert alice_root_after_ratchet != alice2.root_key

        # Alice -> Bob again (DH ratchet on Bob)
        {_alice4, h3, c3} = DoubleRatchet.encrypt(alice3, "again")
        {:ok, bob4, _m3} = DoubleRatchet.decrypt(bob3, h3, c3)

        # Bob's root key must have changed
        assert bob4.root_key != bob_root_1
      end)
    end
  end
end
