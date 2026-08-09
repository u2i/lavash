defmodule Lavash.Rx.CalcLocalHelpersTest do
  @moduledoc """
  Regression for u2i/lavash#18 — `calculate :foo, rx(local_helper(@x))` must
  resolve unqualified calls to local helpers (both `def` and `defp`) at
  runtime, and the compiler must see those references (no spurious
  "unused" warnings).

  The fix mirrors the rc.2 #15 fix for `run fn`: each `calculate` body is
  hoisted at compile time into a generated `def __lavash_calc__(:name, state)`
  on the user's module, so calls inside the body resolve in the user's
  module scope.
  """
  use ExUnit.Case, async: true

  describe "calculate rx body in a LiveView" do
    defmodule LiveViewCalcs do
      use Lavash.LiveView

      state :doc, :any, default: nil
      state :handle, :string, default: nil

      calculate :via_public, rx(lookup_pub(@doc)), optimistic: false
      calculate :via_private, rx(lookup_priv(@doc, @handle)), optimistic: false
      calculate :via_chain, rx(format(lookup_priv(@doc, @handle))), optimistic: false

      def lookup_pub(nil), do: "no-doc"
      def lookup_pub(doc), do: "pub:" <> doc["k"]

      defp lookup_priv(nil, _), do: nil
      defp lookup_priv(doc, h), do: doc["by"][h]

      defp format(nil), do: "missing"
      defp format(v), do: "fmt:" <> v

      def render(assigns), do: ~H"<div>{@via_public}</div>"
    end

    test "rx can call an unqualified public local function" do
      assert LiveViewCalcs.__lavash_calc__(:via_public, %{doc: %{"k" => "x"}}) == "pub:x"
      assert LiveViewCalcs.__lavash_calc__(:via_public, %{doc: nil}) == "no-doc"
    end

    test "rx can call an unqualified private local function" do
      doc = %{"by" => %{"alice" => "data"}}
      assert LiveViewCalcs.__lavash_calc__(:via_private, %{doc: doc, handle: "alice"}) == "data"
      assert LiveViewCalcs.__lavash_calc__(:via_private, %{doc: nil, handle: "alice"}) == nil
    end

    test "rx body can chain multiple private helpers" do
      doc = %{"by" => %{"alice" => "data"}}
      assert LiveViewCalcs.__lavash_calc__(:via_chain, %{doc: doc, handle: "alice"}) == "fmt:data"
      assert LiveViewCalcs.__lavash_calc__(:via_chain, %{doc: nil, handle: "alice"}) == "missing"
    end
  end

  describe "calculate rx body in a Lavash component" do
    defmodule ComponentCalcs do
      use Lavash.Component

      state :n, :integer, default: 0, from: :ephemeral

      calculate :doubled, rx(double(@n)), optimistic: false

      defp double(n), do: n * 2

      def render(assigns), do: ~H"<div>{@doubled}</div>"
    end

    test "rx in a component can call an unqualified private local function" do
      assert ComponentCalcs.__lavash_calc__(:doubled, %{n: 5}) == 10
    end
  end

  # The user-reported pattern that originally surfaced this — a nil-safe
  # nested-map lookup expressed as a private helper called from rx.
  describe "the original u2i-compliance-portal recipe" do
    defmodule PortalShape do
      use Lavash.LiveView

      state :tasks_doc, :any, default: nil
      state :handle, :string, default: nil

      calculate :raw_state, rx(lookup_state(@tasks_doc, @handle)), optimistic: false

      defp lookup_state(nil, _h), do: nil
      defp lookup_state(doc, h) when is_map(doc), do: (doc["by_person"] || %{})[h]

      def render(assigns), do: ~H"<div>{inspect(@raw_state)}</div>"
    end

    test "nil doc short-circuits, real doc returns the nested value, missing handle is nil" do
      assert PortalShape.__lavash_calc__(:raw_state, %{tasks_doc: nil, handle: "alice"}) == nil

      doc = %{"by_person" => %{"alice" => %{"status" => "ok"}}}

      assert PortalShape.__lavash_calc__(:raw_state, %{tasks_doc: doc, handle: "alice"}) ==
               %{"status" => "ok"}

      assert PortalShape.__lavash_calc__(:raw_state, %{tasks_doc: doc, handle: "bob"}) == nil
    end
  end
end
