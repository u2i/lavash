defmodule Lavash.Rx.TranspilerTest do
  use ExUnit.Case, async: true

  alias Lavash.Rx.Transpiler

  describe "to_js/1 - literals" do
    test "string literals" do
      assert Transpiler.to_js(~s|"hello"|) == ~s|"hello"|
      assert Transpiler.to_js(~s|"hello world"|) == ~s|"hello world"|
      assert Transpiler.to_js(~s|""|) == ~s|""|
    end

    test "number literals" do
      assert Transpiler.to_js("42") == "42"
      assert Transpiler.to_js("3.14") == "3.14"
      assert Transpiler.to_js("0") == "0"
      # Note: negative literals like "-5" are parsed as unary minus
      # and would need special handling. In practice, negative numbers
      # come from calculations (e.g., @count - 5) not as literals.
    end

    test "boolean literals" do
      assert Transpiler.to_js("true") == "true"
      assert Transpiler.to_js("false") == "false"
    end

    test "nil literal" do
      assert Transpiler.to_js("nil") == "null"
    end

    test "atom literals" do
      assert Transpiler.to_js(":foo") == ~s|"foo"|
      assert Transpiler.to_js(":hello_world") == ~s|"hello_world"|
    end

    test "list literals" do
      assert Transpiler.to_js("[]") == "[]"
      assert Transpiler.to_js("[1, 2, 3]") == "[1, 2, 3]"
      assert Transpiler.to_js(~s|["a", "b"]|) == ~s|["a", "b"]|
    end

    test "map literals" do
      assert Transpiler.to_js("%{}") == "{}"
      assert Transpiler.to_js("%{a: 1}") == "{:a: 1}"
      assert Transpiler.to_js("%{a: 1, b: 2}") == "{:a: 1, :b: 2}"
    end
  end

  describe "elixir_to_js/1 - state references" do
    test "@variable becomes state.variable" do
      assert Transpiler.to_js("@count") == "state.count"
      assert Transpiler.to_js("@user_name") == "state.user_name"
    end

    test "nested @variable access" do
      assert Transpiler.to_js("@user.name") == "state.user.name"
    end
  end

  describe "elixir_to_js/1 - comparison operators" do
    test "equality operators use ===" do
      assert Transpiler.to_js("@a == @b") == "(state.a === state.b)"
      assert Transpiler.to_js("@a != @b") == "(state.a !== state.b)"
    end

    test "comparison operators" do
      assert Transpiler.to_js("@a > @b") == "(state.a > state.b)"
      assert Transpiler.to_js("@a < @b") == "(state.a < state.b)"
      assert Transpiler.to_js("@a >= @b") == "(state.a >= state.b)"
      assert Transpiler.to_js("@a <= @b") == "(state.a <= state.b)"
    end
  end

  describe "elixir_to_js/1 - logical operators" do
    test "&& and || operators" do
      assert Transpiler.to_js("@a && @b") == "(state.a && state.b)"
      assert Transpiler.to_js("@a || @b") == "(state.a || state.b)"
    end

    test "and/or keywords become &&/||" do
      assert Transpiler.to_js("@a and @b") == "(state.a && state.b)"
      assert Transpiler.to_js("@a or @b") == "(state.a || state.b)"
    end

    test "not operator" do
      assert Transpiler.to_js("not @active") == "!state.active"
      assert Transpiler.to_js("!@active") == "!state.active"
    end
  end

  describe "elixir_to_js/1 - arithmetic operators" do
    test "basic arithmetic" do
      assert Transpiler.to_js("@a + @b") == "(state.a + state.b)"
      assert Transpiler.to_js("@a - @b") == "(state.a - state.b)"
      assert Transpiler.to_js("@a * @b") == "(state.a * state.b)"
      assert Transpiler.to_js("@a / @b") == "(state.a / state.b)"
    end
  end

  describe "elixir_to_js/1 - if expressions" do
    test "if-else becomes ternary" do
      assert Transpiler.to_js("if @active, do: \"on\", else: \"off\"") ==
               "(state.active ? \"on\" : \"off\")"
    end

    test "if without else returns null" do
      assert Transpiler.to_js("if @active, do: \"on\"") ==
               "(state.active ? \"on\" : null)"
    end

    test "nested if expressions" do
      code = "if @a, do: (if @b, do: 1, else: 2), else: 3"
      result = Transpiler.to_js(code)
      assert result == "(state.a ? (state.b ? 1 : 2) : 3)"
    end
  end

  describe "elixir_to_js/1 - String functions" do
    test "String.length" do
      assert Transpiler.to_js("String.length(@name)") == "(state.name.length)"
    end

    test "String.trim" do
      assert Transpiler.to_js("String.trim(@input)") == "(state.input.trim())"
    end

    test "String.to_integer" do
      assert Transpiler.to_js("String.to_integer(@num)") == "parseInt(state.num, 10)"
    end

    test "String.to_float" do
      assert Transpiler.to_js("String.to_float(@num)") == "parseFloat(state.num)"
    end

    test "String.contains?" do
      assert Transpiler.to_js(~s|String.contains?(@text, "foo")|) ==
               "(state.text.includes(\"foo\"))"
    end

    test "String.starts_with?" do
      assert Transpiler.to_js(~s|String.starts_with?(@text, "pre")|) ==
               "(state.text.startsWith(\"pre\"))"
    end

    test "String.ends_with?" do
      assert Transpiler.to_js(~s|String.ends_with?(@text, "suf")|) ==
               "(state.text.endsWith(\"suf\"))"
    end

    test "String.replace with regex" do
      assert Transpiler.to_js(~s|String.replace(@text, ~r/\\D/, "")|) ==
               "(state.text.replace(/\\D/g, \"\"))"
    end

    test "String.slice with constants" do
      assert Transpiler.to_js("String.slice(@text, 0, 2)") ==
               "(state.text.slice(0, 2))"
    end

    test "String.match?" do
      assert Transpiler.to_js(~s|String.match?(@text, ~r/^\\d+$/)|) ==
               "(/^\\d+$/.test(state.text))"
    end
  end

  describe "elixir_to_js/1 - Enum functions" do
    test "Enum.member?" do
      assert Transpiler.to_js("Enum.member?(@tags, \"foo\")") ==
               "state.tags.includes(\"foo\")"
    end

    test "Enum.count" do
      assert Transpiler.to_js("Enum.count(@items)") == "(state.items.length)"
    end

    test "Enum.join with separator" do
      assert Transpiler.to_js(~s|Enum.join(@items, ", ")|) ==
               "(state.items.join(\", \"))"
    end

    test "Enum.join without separator" do
      assert Transpiler.to_js("Enum.join(@items)") == "(state.items.join(\",\"))"
    end

    test "Enum.map with fn" do
      assert Transpiler.to_js("Enum.map(@items, fn x -> x * 2 end)") ==
               "(state.items.map(x => (x * 2)))"
    end

    test "Enum.filter with fn" do
      assert Transpiler.to_js("Enum.filter(@items, fn x -> x > 0 end)") ==
               "(state.items.filter(x => (x > 0)))"
    end

    test "Enum.reject with fn" do
      assert Transpiler.to_js("Enum.reject(@items, fn x -> x == 0 end)") ==
               "(state.items.filter(x => !((x === 0))))"
    end
  end

  describe "elixir_to_js/1 - Map functions" do
    test "Map.get with 2 args" do
      assert Transpiler.to_js(~s|Map.get(@data, "key")|) ==
               "state.data[\"key\"]"
    end

    test "Map.get with 3 args (default)" do
      assert Transpiler.to_js(~s|Map.get(@data, "key", "default")|) ==
               "(state.data[\"key\"] ?? \"default\")"
    end
  end

  describe "elixir_to_js/1 - utility functions" do
    test "length/1" do
      assert Transpiler.to_js("length(@items)") == "(state.items.length)"
    end

    test "is_nil/1" do
      assert Transpiler.to_js("is_nil(@value)") ==
               "(state.value === null || state.value === undefined)"
    end

    test "humanize/1" do
      result = Transpiler.to_js("humanize(@status)")
      assert result =~ "toString().replace(/_/g"
      assert result =~ "toUpperCase()"
    end

    test "get_in with literal keys" do
      assert Transpiler.to_js("get_in(@data, [:user, :name])") ==
               "(state.data.user.name)"
    end

    test "valid_card_number?" do
      assert Transpiler.to_js("valid_card_number?(@digits)") ==
               "Lavash.Rx.Validators.validCardNumber(state.digits)"
    end
  end

  describe "elixir_to_js/1 - string concatenation" do
    test "<> operator" do
      assert Transpiler.to_js(~s|"$" <> @amount|) == "(\"$\" + state.amount)"
    end
  end

  describe "elixir_to_js/1 - list operations" do
    test "++ operator" do
      assert Transpiler.to_js("@list1 ++ @list2") ==
               "[...state.list1, ...state.list2]"
    end

    test "in operator" do
      assert Transpiler.to_js(~s|@value in ["a", "b"]|) ==
               "[\"a\", \"b\"].includes(state.value)"
    end
  end

  describe "elixir_to_js/1 - pipe operator" do
    test "simple pipe" do
      assert Transpiler.to_js("@text |> String.trim()") ==
               "(state.text.trim())"
    end

    test "chained pipes" do
      code = "@digits |> String.replace(~r/\\D/, \"\") |> String.length()"
      result = Transpiler.to_js(code)
      assert result =~ "replace(/\\D/g"
      assert result =~ ".length"
    end
  end

  describe "elixir_to_js/1 - string interpolation" do
    test "simple interpolation" do
      # Note: we need to construct the interpolated string carefully
      # because Elixir will try to interpolate it at compile time
      code = ~S|"Hello #{@name}"|
      result = Transpiler.to_js(code)
      assert result == "`Hello ${state.name}`"
    end

    test "multiple interpolations" do
      code = ~S|"#{@first} #{@last}"|
      result = Transpiler.to_js(code)
      assert result == "`${state.first} ${state.last}`"
    end
  end

  describe "elixir_to_js/1 - dot access" do
    test "object field access" do
      assert Transpiler.to_js("item.name") == "item.name"
    end

    test "nested access" do
      assert Transpiler.to_js("@user.profile.name") == "state.user.profile.name"
    end
  end

  describe "elixir_to_js/1 - bracket access" do
    test "Access.get style" do
      assert Transpiler.to_js(~s|@data["key"]|) == "state.data[\"key\"]"
    end
  end

  describe "elixir_to_js/1 - complex expressions" do
    test "combined operators" do
      code = "@count > 0 && @enabled"
      result = Transpiler.to_js(code)
      assert result == "((state.count > 0) && state.enabled)"
    end

    test "ternary with function calls" do
      code = ~s|if String.length(@text) > 0, do: "has content", else: "empty"|
      result = Transpiler.to_js(code)
      assert result =~ "state.text.length"
      assert result =~ "?"
    end

    test "nested ternaries" do
      code = "if @a, do: (if @b, do: 1, else: 2), else: 0"
      result = Transpiler.to_js(code)
      assert result == "(state.a ? (state.b ? 1 : 2) : 0)"
    end
  end

  describe "elixir_to_js/1 - untranspilable expressions" do
    test "unknown function calls return undefined with comment" do
      result = Transpiler.to_js("Ash.read!(Product)")
      assert result =~ "undefined"
      assert result =~ "untranspilable"
    end

    test "Decimal operations are untranspilable" do
      result = Transpiler.to_js("Decimal.add(@a, @b)")
      assert result =~ "undefined"
      assert result =~ "untranspilable"
    end
  end

  describe "validate/1" do
    test "returns :ok for transpilable expressions" do
      assert Transpiler.validate("@count") == :ok
      assert Transpiler.validate("@a + @b") == :ok
      assert Transpiler.validate("length(@items)") == :ok
      assert Transpiler.validate("String.length(@text)") == :ok
      assert Transpiler.validate("if @a, do: 1, else: 2") == :ok
    end

    test "returns error for unsupported function calls" do
      assert {:error, _} = Transpiler.validate("Ash.read!(Product)")
      assert {:error, _} = Transpiler.validate("Decimal.add(@a, @b)")
    end
  end
end
