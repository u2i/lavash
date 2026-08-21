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

    test "validation demo submit's conditional class rides an attr derive", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dsl/validation")

      # pattern 7: the mixed class list gets a reactive attribute derive
      assert Regex.match?(~r/<button[^>]*data-lavash-attr-class="__attr_\d+_class"/, html)
      # dead render carries the invalid-state classes
      assert html =~ "bg-base-300 text-base-content"
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

  describe "hidden-class visibility via toggle injection (#110)" do
    test "checkout hidden-class idioms get field||hidden toggles", %{conn: conn} do
      # First request creates the anonymous user + cart via mount
      conn = get(conn, "/storefront/checkout")
      user = conn.assigns.current_user

      product =
        Demo.Catalog.Product
        |> Ash.Changeset.for_create(:create, %{name: "Toggle Beans", price: Decimal.new("20.00")})
        |> Ash.create!()

      cart =
        Demo.Cart.Cart
        |> Ash.Query.for_read(:for_user, %{user_id: user.id})
        |> Ash.read_one!()

      Demo.Cart.CartItem
      |> Ash.Changeset.for_create(:create_row, %{
        cart_id: cart.id,
        product_id: product.id,
        quantity: 1
      })
      |> Ash.create!()

      {:ok, _view, html} = live(conn, "/storefront/checkout")

      # Every hidden-class idiom (badges, ship-to arrows, address list)
      # rides a reactive attribute derive now — several distinct ones
      attr_class_derives =
        Regex.scan(~r/data-lavash-attr-class="(__attr_\d+_class)"/, html)
        |> Enum.map(fn [_, name] -> name end)
        |> Enum.uniq()

      assert length(attr_class_derives) >= 5

      # payment form: <.form> is passthrough-registered by default, so
      # its class conditional gets an attribute derive forwarded via
      # :global to the rendered <form> tag (#123)
      assert Regex.match?(~r/<form[^>]*data-lavash-attr-class="__attr_\d+_class"/, html)
      refute html =~ "data-lavash-toggle"

      # the hand-written attrs are gone — derives own visibility here
      refute html =~ "data-lavash-visible"
    end
  end

  defp button_disabled?(html, label) do
    Regex.match?(~r/<button[^>]*disabled[^>]*>[^<]*#{Regex.escape(label)}/s, html)
  end
end
