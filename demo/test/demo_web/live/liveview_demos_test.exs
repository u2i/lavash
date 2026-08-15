defmodule DemoWeb.LiveViewDemosTest do
  @moduledoc """
  Tests for the /reactive (reactive DSL) and /builder (core API, no
  macros) demo structures, the landing page pills, and the legacy
  /demos + /lv redirects.
  """
  use DemoWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "landing page" do
    test "links all three structures with pills", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "/dsl/counter"
      assert html =~ "/reactive/counter"
      assert html =~ "/reactive/explicit-counter"
      assert html =~ "/builder/counter"
      assert html =~ "/js-counter"
      assert html =~ "/dsl/todos"
      assert html =~ "/reactive/todos"
      assert html =~ "/builder/todos"
      assert html =~ "/reactive/form-validation"
      assert html =~ "/builder/products"
    end
  end

  describe "legacy redirects" do
    test "/demos/* moved to /dsl/*", %{conn: conn} do
      assert redirected_to(get(conn, "/demos/counter"), 301) == "/dsl/counter"
      assert redirected_to(get(conn, "/demos"), 301) == "/"
    end

    test "/lv/* moved to /reactive/* and /builder/*", %{conn: conn} do
      assert redirected_to(get(conn, "/lv/counter"), 301) == "/reactive/counter"
      assert redirected_to(get(conn, "/lv/todos"), 301) == "/builder/todos"
      assert redirected_to(get(conn, "/lv/products"), 301) == "/builder/products"
      assert redirected_to(get(conn, "/lv/plain-counter"), 301) == "/js-counter"
      assert redirected_to(get(conn, "/lv"), 301) == "/"
    end
  end

  describe "builder counter" do
    test "increments through the no-macro graph", %{conn: conn} do
      {:ok, view, html} = live(conn, "/builder/counter")
      assert html =~ "Builder Counter"

      html = view |> element("button[phx-click=increment]") |> render_click()
      assert html =~ ">1</div>"
      assert html =~ "odd"
    end
  end

  describe "explicit counter" do
    test "increments and recomputes derives", %{conn: conn} do
      {:ok, view, html} = live(conn, "/reactive/explicit-counter")
      assert html =~ "Explicit Counter"

      html = view |> element("button[phx-click=increment]") |> render_click()
      assert html =~ ">1</div>"
      assert html =~ "odd"
    end

    test "step changes recompute the product derive", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/reactive/explicit-counter")

      view |> element("button[phx-click=increment]") |> render_click()
      html = view |> element("form[phx-change=set_step]") |> render_change(%{"step" => "5"})

      # count(1) x step(5)
      assert html =~ ">5</span>"
    end
  end

  describe "form validation" do
    test "shows errors for touched invalid fields and blocks submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/reactive/form-validation")

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
      {:ok, view, _html} = live(conn, "/reactive/form-validation")

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
      {:ok, view, _html} = live(conn, "/builder/products")

      # Async derive: wait for the task result to land
      html = render_async_products(view)
      assert html =~ "Bali Blue Moon"
      assert html =~ "Kenya AA"

      # Filters arrive via handle_params (URL is source of truth)
      {:ok, view, _html} = live(conn, "/builder/products?search=Bali")
      html = render_async_products(view)
      assert html =~ "Bali Blue Moon"
      refute html =~ "Kenya AA"
    end

    test "filter events patch the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/builder/products")
      render_async_products(view)

      view
      |> element("form[phx-change=set_search]")
      |> render_change(%{"value" => "Kenya"})

      assert_patch(view, "/builder/products?search=Kenya")

      html = render_async_products(view)
      assert html =~ "Kenya AA"
      refute html =~ "Bali Blue Moon"
    end

    test "pubsub invalidation refreshes the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/builder/products")
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

  # The same todos feature set exists at both non-optimistic layers;
  # run the identical flow against each.
  for path <- ["/builder/todos", "/reactive/todos"] do
    describe "todos at #{path}" do
      @todos_path path

      test "adds, toggles, filters, and clears todos", %{conn: conn} do
        conn = get(conn, @todos_path)
        {:ok, view, html} = live(conn, @todos_path)
        assert html =~ "Nothing here."

        view |> form("#todo-form", %{"title" => "Write docs"}) |> render_submit()
        html = view |> form("#todo-form", %{"title" => "Ship it"}) |> render_submit()
        assert html =~ "Write docs"
        assert html =~ "Ship it"
        assert html =~ "2 remaining"

        # Toggle the first todo done
        html =
          view
          |> element("li:first-child input[type=checkbox]")
          |> render_click()

        assert html =~ "1 remaining"
        assert html =~ "Clear 1 done"

        # The "done" filter shows only the completed one
        html = view |> element("button[phx-value-filter=done]") |> render_click()
        assert html =~ "line-through"
        refute html =~ "2 remaining"

        # Clear done removes it
        html = view |> element("button[phx-click=clear_done]") |> render_click()
        assert html =~ "Nothing here."
      end

      test "another view of the same user updates via pubsub", %{conn: conn} do
        conn = get(conn, @todos_path)
        {:ok, view_a, _} = live(conn, @todos_path)
        {:ok, view_b, _} = live(conn, @todos_path)

        view_a |> form("#todo-form", %{"title" => "Cross-tab hello"}) |> render_submit()

        # view_b hears the user_id-topic broadcast and re-fetches
        assert render(view_b) =~ "Cross-tab hello"
      end
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
