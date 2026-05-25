defmodule Lavash.Rx.ShortCircuitTest do
  @moduledoc """
  Regression for the `rx(@a && @b)` family. `Kernel.&&/2`, `Kernel.||/2`,
  `Kernel.and/2`, `Kernel.or/2` are macros that, on some Elixir versions,
  expand eagerly before `rx`'s own walker runs — at which point nested
  `@field` refs flow through `Kernel.@/1` against an already-compiled
  module and raise. `Lavash.Rx.pre_expand_short_circuits/2` canonicalises
  those four forms before the walker runs so the @-refs stay visible.
  """
  use ExUnit.Case, async: true

  import Lavash.Rx, only: [rx: 1]

  defp compile(%Lavash.Rx{ast: ast}) do
    fn_ast = {:fn, [], [{:->, [], [[{:state, [], nil}], ast]}]}
    {fun, _} = Code.eval_quoted(fn_ast, [])
    fun
  end

  describe "rx with short-circuit operators" do
    test "&& between two @field references compiles and evaluates" do
      r = rx(@a && @b)
      fun = compile(r)

      assert fun.(%{a: nil, b: "x"}) == nil
      assert fun.(%{a: false, b: "x"}) == false
      assert fun.(%{a: "left", b: "right"}) == "right"
    end

    test "|| between two @field references compiles and evaluates" do
      r = rx(@a || @b)
      fun = compile(r)

      assert fun.(%{a: nil, b: "x"}) == "x"
      assert fun.(%{a: "first", b: "second"}) == "first"
      assert fun.(%{a: nil, b: nil}) == nil
    end

    test "and / or word forms between @field references" do
      and_r = rx(@a and @b)
      or_r = rx(@a or @b)

      assert compile(and_r).(%{a: true, b: false}) == false
      assert compile(and_r).(%{a: true, b: true}) == true
      assert compile(or_r).(%{a: false, b: true}) == true
      assert compile(or_r).(%{a: false, b: false}) == false
    end

    test "deps are still extracted from inside && / ||" do
      r = rx(@a && @b)
      assert Enum.sort(r.deps) == [:a, :b]

      r2 = rx(@x || @y)
      assert Enum.sort(r2.deps) == [:x, :y]
    end
  end

  # The exact user-reported shape from u2i-compliance-portal: short-circuit
  # operator wrapping a nested `@field[...]` path access.
  describe "rx with @field && @field[path] (the original user report)" do
    test "nested @doc[path][@handle] under && / || compiles" do
      r = rx((@doc && @doc["by_person"][@handle]) || nil)
      fun = compile(r)

      assert fun.(%{doc: nil, handle: "alice"}) == nil

      doc = %{"by_person" => %{"alice" => %{"status" => "ok"}}}
      assert fun.(%{doc: doc, handle: "alice"}) == %{"status" => "ok"}
      assert fun.(%{doc: doc, handle: "bob"}) == nil
    end

    test "deps capture both refs even inside short-circuited path access" do
      r = rx((@doc && @doc["by_person"][@handle]) || nil)
      assert :doc in r.deps
      assert :handle in r.deps
    end
  end

  # Originally hit in rc.3 / rc.4 — reported by a u2i-compliance-portal
  # adopter. The bracket-access root is itself a parenthesised expression
  # (`(@doc["by_person"] || %{})[@handle]`), so `extract_path` returns
  # `:not_a_path`. The walker recursed into the LHS but lost the RHS key,
  # which meant `:handle` was missing from deps even though it was clearly
  # referenced. The calc never re-fired when `:handle` changed and the
  # reactive engine returned a stale value (often nil).
  describe "rx deps inside bracket-access not rooted at @" do
    test "@-ref inside the KEY of a non-@-rooted bracket access is captured" do
      r = rx(@a && (@b || @c)[@d])
      assert Enum.sort(r.deps) == [:a, :b, :c, :d]
    end

    test "the original user shape" do
      r = rx(@tasks_doc && (@tasks_doc["by_person"] || %{})[@handle])
      assert :handle in r.deps
      assert :tasks_doc in r.deps
    end

    test "user shape returns the looked-up value, not nil" do
      r = rx(@tasks_doc && (@tasks_doc["by_person"] || %{})[@handle])
      fun = compile(r)

      doc = %{"by_person" => %{"tom.clarke" => %{"id" => 1}}}
      assert fun.(%{tasks_doc: doc, handle: "tom.clarke"}) == %{"id" => 1}
      assert fun.(%{tasks_doc: doc, handle: "missing"}) == nil
      assert fun.(%{tasks_doc: nil, handle: "tom.clarke"}) == nil
    end
  end
end
