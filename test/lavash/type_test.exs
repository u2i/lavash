defmodule Lavash.TypeTest do
  use ExUnit.Case, async: true

  alias Lavash.Type

  describe "parse/2 with :string" do
    test "returns string as-is" do
      assert {:ok, "hello"} = Type.parse(:string, "hello")
    end

    test "handles empty string" do
      assert {:ok, ""} = Type.parse(:string, "")
    end

    test "handles nil" do
      assert {:ok, nil} = Type.parse(:string, nil)
    end
  end

  describe "parse/2 with :integer" do
    test "parses positive integer" do
      assert {:ok, 42} = Type.parse(:integer, "42")
    end

    test "parses negative integer" do
      assert {:ok, -10} = Type.parse(:integer, "-10")
    end

    test "parses zero" do
      assert {:ok, 0} = Type.parse(:integer, "0")
    end

    test "handles nil" do
      assert {:ok, nil} = Type.parse(:integer, nil)
    end

    test "returns error for non-numeric string" do
      assert {:error, _} = Type.parse(:integer, "abc")
    end

    test "parses integer with trailing characters" do
      assert {:ok, 42} = Type.parse(:integer, "42px")
    end
  end

  describe "parse/2 with :float" do
    test "parses float" do
      assert {:ok, 3.14} = Type.parse(:float, "3.14")
    end

    test "parses negative float" do
      assert {:ok, -2.5} = Type.parse(:float, "-2.5")
    end

    test "parses integer as float" do
      assert {:ok, 42.0} = Type.parse(:float, "42")
    end

    test "handles nil" do
      assert {:ok, nil} = Type.parse(:float, nil)
    end

    test "returns error for non-numeric string" do
      assert {:error, _} = Type.parse(:float, "abc")
    end
  end

  describe "parse/2 with :boolean" do
    test "parses 'true'" do
      assert {:ok, true} = Type.parse(:boolean, "true")
    end

    test "parses 'false'" do
      assert {:ok, false} = Type.parse(:boolean, "false")
    end

    test "parses '1' as true" do
      assert {:ok, true} = Type.parse(:boolean, "1")
    end

    test "parses '0' as false" do
      assert {:ok, false} = Type.parse(:boolean, "0")
    end

    test "handles nil" do
      assert {:ok, nil} = Type.parse(:boolean, nil)
    end

    test "returns error for invalid boolean" do
      assert {:error, _} = Type.parse(:boolean, "maybe")
    end
  end

  describe "parse/2 with :atom" do
    test "parses existing atom" do
      # Ensure atom exists
      _ = :test_atom
      assert {:ok, :test_atom} = Type.parse(:atom, "test_atom")
    end

    test "handles nil" do
      assert {:ok, nil} = Type.parse(:atom, nil)
    end

    test "returns error for non-existing atom" do
      assert {:error, _} = Type.parse(:atom, "this_atom_definitely_does_not_exist_xyz")
    end
  end

  describe "parse/2 with {:array, type}" do
    test "parses comma-separated integers" do
      assert {:ok, [1, 2, 3]} = Type.parse({:array, :integer}, "1,2,3")
    end

    test "parses comma-separated strings" do
      assert {:ok, ["a", "b", "c"]} = Type.parse({:array, :string}, "a,b,c")
    end

    test "handles empty string as empty array" do
      assert {:ok, []} = Type.parse({:array, :integer}, "")
    end

    test "handles nil" do
      assert {:ok, nil} = Type.parse({:array, :integer}, nil)
    end

    test "trims whitespace around elements" do
      assert {:ok, [1, 2, 3]} = Type.parse({:array, :integer}, "1, 2, 3")
    end

    test "handles pre-parsed list (Phoenix params style)" do
      assert {:ok, [1, 2, 3]} = Type.parse({:array, :integer}, ["1", "2", "3"])
    end

    test "returns error if any element fails to parse" do
      assert {:error, _} = Type.parse({:array, :integer}, "1,abc,3")
    end

    test "filters out empty strings from comma-separated input" do
      assert {:ok, ["a", "b"]} = Type.parse({:array, :string}, "a,,b")
      assert {:ok, ["a"]} = Type.parse({:array, :string}, "a,")
      assert {:ok, ["b"]} = Type.parse({:array, :string}, ",b")
    end

    test "filters out empty strings and nils from list input" do
      assert {:ok, ["a", "b"]} = Type.parse({:array, :string}, ["a", "", "b"])
      assert {:ok, ["a", "b"]} = Type.parse({:array, :string}, ["a", nil, "b"])
    end
  end

  describe "dump/2 with :string" do
    test "returns string as-is" do
      assert "hello" = Type.dump(:string, "hello")
    end

    test "handles nil" do
      assert nil == Type.dump(:string, nil)
    end
  end

  describe "dump/2 with :integer" do
    test "converts integer to string" do
      assert "42" = Type.dump(:integer, 42)
    end

    test "converts negative integer" do
      assert "-10" = Type.dump(:integer, -10)
    end

    test "handles nil" do
      assert nil == Type.dump(:integer, nil)
    end
  end

  describe "dump/2 with :float" do
    test "converts float to string" do
      assert "3.14" = Type.dump(:float, 3.14)
    end

    test "handles nil" do
      assert nil == Type.dump(:float, nil)
    end
  end

  describe "dump/2 with :boolean" do
    test "converts true to 'true'" do
      assert "true" = Type.dump(:boolean, true)
    end

    test "converts false to 'false'" do
      assert "false" = Type.dump(:boolean, false)
    end

    test "handles nil" do
      assert nil == Type.dump(:boolean, nil)
    end
  end

  describe "dump/2 with :atom" do
    test "converts atom to string" do
      assert "foo" = Type.dump(:atom, :foo)
    end

    test "handles nil" do
      assert nil == Type.dump(:atom, nil)
    end
  end

  describe "dump/2 with {:array, type}" do
    test "converts integer array to comma-separated string" do
      assert "1,2,3" = Type.dump({:array, :integer}, [1, 2, 3])
    end

    test "converts string array to comma-separated string" do
      assert "a,b,c" = Type.dump({:array, :string}, ["a", "b", "c"])
    end

    test "handles empty array" do
      assert "" = Type.dump({:array, :integer}, [])
    end

    test "handles nil" do
      assert nil == Type.dump({:array, :integer}, nil)
    end
  end

  describe "roundtrip" do
    test "integer roundtrip" do
      original = 42
      dumped = Type.dump(:integer, original)
      {:ok, result} = Type.parse(:integer, dumped)
      assert result == original
    end

    test "float roundtrip" do
      original = 3.14
      dumped = Type.dump(:float, original)
      {:ok, result} = Type.parse(:float, dumped)
      assert result == original
    end

    test "boolean roundtrip" do
      for original <- [true, false] do
        dumped = Type.dump(:boolean, original)
        {:ok, result} = Type.parse(:boolean, dumped)
        assert result == original
      end
    end

    test "array roundtrip" do
      original = [1, 2, 3]
      dumped = Type.dump({:array, :integer}, original)
      {:ok, result} = Type.parse({:array, :integer}, dumped)
      assert result == original
    end
  end

  describe "parse!/2" do
    test "returns value on success" do
      assert 42 = Type.parse!(:integer, "42")
    end

    test "raises on error" do
      assert_raise ArgumentError, fn ->
        Type.parse!(:integer, "abc")
      end
    end
  end

  describe "parse/2 with :uuid" do
    test "parses full UUID with dashes" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      assert {:ok, ^uuid} = Type.parse(:uuid, uuid)
    end

    test "parses UUID with uppercase" do
      uuid = "550E8400-E29B-41D4-A716-446655440000"
      assert {:ok, "550e8400-e29b-41d4-a716-446655440000"} = Type.parse(:uuid, uuid)
    end

    test "parses hex without dashes" do
      hex = "550e8400e29b41d4a716446655440000"
      assert {:ok, "550e8400-e29b-41d4-a716-446655440000"} = Type.parse(:uuid, hex)
    end

    test "handles nil" do
      assert {:ok, nil} = Type.parse(:uuid, nil)
    end
  end

  describe "parse/2 with {:uuid, prefix}" do
    test "parses prefixed TypeID" do
      # Create a TypeID with known UUID
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, tid} = TypeID.from_uuid("cat", uuid)
      typeid_str = TypeID.to_string(tid)

      assert {:ok, ^uuid} = Type.parse({:uuid, "cat"}, typeid_str)
    end

    test "returns error for wrong prefix" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, tid} = TypeID.from_uuid("dog", uuid)
      typeid_str = TypeID.to_string(tid)

      assert {:error, _} = Type.parse({:uuid, "cat"}, typeid_str)
    end
  end

  describe "dump/2 with :uuid" do
    test "encodes UUID to TypeID suffix" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      result = Type.dump(:uuid, uuid)
      # Should be 26-char base32 suffix
      assert String.length(result) == 26
    end

    test "handles nil" do
      assert nil == Type.dump(:uuid, nil)
    end
  end

  describe "dump/2 with {:uuid, prefix}" do
    test "encodes UUID to full TypeID with prefix" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      result = Type.dump({:uuid, "cat"}, uuid)
      assert String.starts_with?(result, "cat_")
    end
  end

  describe "UUID roundtrip" do
    test "plain UUID roundtrip" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      dumped = Type.dump(:uuid, uuid)
      {:ok, result} = Type.parse(:uuid, dumped)
      assert result == uuid
    end

    test "prefixed UUID roundtrip" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      dumped = Type.dump({:uuid, "cat"}, uuid)
      {:ok, result} = Type.parse({:uuid, "cat"}, dumped)
      assert result == uuid
    end
  end

  describe "dump/2 with unknown type" do
    test "uses to_string fallback" do
      # Unknown type should fall back to to_string
      assert "42" = Type.dump(:unknown_type, 42)
    end
  end

  describe "parse/2 with unknown type" do
    test "returns error for unknown type" do
      assert {:error, _} = Type.parse(:unknown_type, "value")
    end
  end

  describe "custom type module" do
    defmodule CustomDate do
      use Lavash.Type

      @impl true
      def parse(value) when is_binary(value) do
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, "invalid date format"}
        end
      end

      @impl true
      def dump(%Date{} = date), do: Date.to_iso8601(date)
    end

    test "parses with custom type" do
      assert {:ok, ~D[2024-01-15]} = Type.parse(CustomDate, "2024-01-15")
    end

    test "dumps with custom type" do
      assert "2024-01-15" = Type.dump(CustomDate, ~D[2024-01-15])
    end

    test "returns error for invalid custom type value" do
      assert {:error, "invalid date format"} = Type.parse(CustomDate, "not-a-date")
    end

    test "roundtrip with custom type" do
      original = ~D[2024-01-15]
      dumped = Type.dump(CustomDate, original)
      {:ok, result} = Type.parse(CustomDate, dumped)
      assert result == original
    end
  end
end
