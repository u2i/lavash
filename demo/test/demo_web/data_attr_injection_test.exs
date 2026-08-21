defmodule DemoWeb.DataAttrInjectionTest do
  @moduledoc """
  Pins the DataAttrTransformer auto-injection at the sites where the
  demo used to hand-write `data-lavash-*` attributes (#109) and where
  buttons now use idiomatic `disabled={not @field}` instead of a
  manual `data-lavash-enabled` (#113–#117). If injection ever stops
  firing for one of these patterns, these tests catch the silent loss
  of optimistic behavior.
  """
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "state-binding injection (pattern 2)" do
    test "counter multiplier range input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dsl/counter")
      assert html =~ ~s(data-lavash-bind="multiplier")
    end

    test "storefront products search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/storefront/products")
      assert html =~ ~s(data-lavash-bind="search")
    end

    test "storefront products sort select (from option selected exprs)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/storefront/products")
      assert html =~ ~s(data-lavash-bind="sort")
    end

    test "chat message input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")
      assert html =~ ~s(data-lavash-bind="input")
    end
  end

  describe "enabled/disabled injection (pattern 4)" do
    test "chat send button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")
      assert html =~ ~s(data-lavash-enabled="input_valid?")
    end

    test "validation demo submit is dead-render disabled AND injected", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dsl/validation")
      assert html =~ ~s(data-lavash-enabled="form_valid")
      assert button_disabled?(html, "Create Account")
    end

    test "form validation demo submit is dead-render disabled AND injected", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dsl/form-validation")
      assert html =~ ~s(data-lavash-enabled="form_valid")
      assert button_disabled?(html, "Register")
    end

    test "product page quantity decrement is dead-render disabled AND injected", %{conn: conn} do
      product =
        Demo.Catalog.Product
        |> Ash.Changeset.for_create(:create, %{
          name: "Injection Test Beans",
          price: Decimal.new("20.00"),
          in_stock: true,
          rating: Decimal.new("4.5")
        })
        |> Ash.create!()

      {:ok, _view, html} = live(conn, "/storefront/products/#{product.id}")

      assert html =~ ~s(data-lavash-enabled="quantity_gt_1")
      # quantity starts at 1 — decrement must be disabled server-side
      assert html =~ ~r/<button[^>]*phx-click="dec_quantity"[^>]*disabled/
    end
  end

  defp button_disabled?(html, label) do
    Regex.match?(~r/<button[^>]*disabled[^>]*>[^<]*#{Regex.escape(label)}/s, html)
  end
end
