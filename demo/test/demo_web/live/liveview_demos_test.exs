defmodule DemoWeb.LiveViewDemosTest do
  @moduledoc """
  Tests for the non-DSL (/lv) demos: the Explicit counter, reactive
  form validation, and the reactive products catalog.
  """
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "index" do
    test "lists all non-DSL demos", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/lv")

      assert html =~ "/lv/counter"
      assert html =~ "/lv/explicit-counter"
      assert html =~ "/lv/plain-counter"
      assert html =~ "/lv/form-validation"
      assert html =~ "/lv/products"
    end
  end

  describe "explicit counter" do
    test "increments and recomputes derives", %{conn: conn} do
      {:ok, view, html} = live(conn, "/lv/explicit-counter")
      assert html =~ "Explicit Counter"

      html = view |> element("button[phx-click=increment]") |> render_click()
      assert html =~ ">1</div>"
      assert html =~ "odd"
    end

    test "step changes recompute the product derive", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/lv/explicit-counter")

      view |> element("button[phx-click=increment]") |> render_click()
      html = view |> element("form[phx-change=set_step]") |> render_change(%{"step" => "5"})

      # count(1) x step(5)
      assert html =~ ">5</span>"
    end
  end

  describe "form validation" do
    test "shows errors for touched invalid fields and blocks submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/lv/form-validation")

      html =
        view
        |> form("#registration-form", registration: %{"name" => "A"})
        |> render_change()

      assert html =~ "must be at least 2 characters"

      # Invalid submit does not complete
      html =
        view
        |> form("#registration-form", registration: %{"name" => "A"})
        |> render_submit()

      refute html =~ "Registration Complete!"
      # After an attempted submit, untouched-field errors show too
      assert html =~ "is required"
    end

    test "valid submit creates the registration", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/lv/form-validation")

      params = %{"name" => "Ada Lovelace", "email" => "ada@example.com", "age" => "36"}

      html =
        view
        |> form("#registration-form", registration: params)
        |> render_submit()

      assert html =~ "Registration Complete!"
      assert html =~ "Ada Lovelace"
    end
  end

  describe "products" do
    setup do
      # ETS-free zone: Product is SQLite-backed, sandboxed by ConnCase.
      category =
        Demo.Catalog.Category
        |> Ash.Changeset.for_create(:create, %{name: "Beans", slug: "beans"})
        |> Ash.create!()

      for {name, in_stock} <- [{"Bali Blue Moon", true}, {"Kenya AA", false}] do
        Demo.Catalog.Product
        |> Ash.Changeset.for_create(:create, %{
          name: name,
          price: Decimal.new("20.00"),
          in_stock: in_stock,
          category_id: category.id
        })
        |> Ash.create!()
      end

      :ok
    end

    test "renders products and filters via URL params", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/lv/products")

      # Async derive: wait for the task result to land
      html = render_async_products(view)
      assert html =~ "Bali Blue Moon"
      assert html =~ "Kenya AA"

      # Filters arrive via handle_params (URL is source of truth)
      {:ok, view, _html} = live(conn, "/lv/products?search=Bali")
      html = render_async_products(view)
      assert html =~ "Bali Blue Moon"
      refute html =~ "Kenya AA"
    end

    test "filter events patch the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/lv/products")
      render_async_products(view)

      view
      |> element("form[phx-change=set_search]")
      |> render_change(%{"value" => "Kenya"})

      assert_patch(view, "/lv/products?search=Kenya")

      html = render_async_products(view)
      assert html =~ "Kenya AA"
      refute html =~ "Bali Blue Moon"
    end

    test "pubsub invalidation refreshes the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/lv/products")
      html = render_async_products(view)
      assert html =~ "Bali Blue Moon"

      Demo.Catalog.Product
      |> Ash.Changeset.for_create(:create, %{name: "Yirgacheffe", price: Decimal.new("22.00")})
      |> Ash.create!()

      # Simulate what a lavash form mutation broadcasts
      Lavash.PubSub.broadcast(Demo.Catalog.Product)

      html = render_async_products(view)
      assert html =~ "Yirgacheffe"
    end
  end

  # The products list is an async derive — poll until the AsyncResult
  # lands (the task sends {:lavash_reactive, ...} back to the view).
  defp render_async_products(view, attempts \\ 50) do
    html = render(view)

    cond do
      not (html =~ "loading-spinner") ->
        html

      attempts == 0 ->
        flunk("products async derive never completed")

      true ->
        Process.sleep(20)
        render_async_products(view, attempts - 1)
    end
  end
end
