defmodule Lavash.ClientStateTest do
  use Lavash.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Lavash.Test.Magic.ClientCart.Item
  alias Lavash.Test.Magic.ClientCartLive

  defp create_item!(cart_id, name, quantity, price) do
    Item
    |> Ash.Changeset.for_create(:create, %{
      cart_id: cart_id,
      name: name,
      quantity: quantity,
      unit_price: Decimal.new(price)
    })
    |> Ash.create!()
  end

  defp unique_cart, do: "cart-#{System.unique_integer([:positive])}"

  describe "Lavash.ClientState.project/2" do
    test "projects allowlisted fields with wire-safe encoding" do
      records = [
        %{
          id: "a",
          quantity: 2,
          unit_price: Decimal.new("9.50"),
          roast: :dark,
          secret: "not-projected"
        }
      ]

      assert [projected] =
               Lavash.ClientState.project(records, [:id, :quantity, :unit_price, :roast])

      assert projected == %{id: "a", quantity: 2, unit_price: "9.50", roast: "dark"}
    end

    test "projects one level of nested association fields" do
      records = [%{id: "a", product: %{id: "p1", name: "Beans", origin: "Peru"}}]

      assert [%{product: %{id: "p1", name: "Beans"}}] =
               Lavash.ClientState.project(records, [:id, product: [:id, :name]])
    end

    test "nil list and unloaded associations are safe" do
      assert Lavash.ClientState.project(nil, [:id]) == []

      records = [%{id: "a", product: %Ash.NotLoaded{}}]
      assert [%{product: nil}] = Lavash.ClientState.project(records, [:id, product: [:id]])
    end
  end

  describe "compiled module metadata" do
    test "projection appears in optimistic_fields as a client_projection" do
      fields = ClientCartLive.__lavash__(:optimistic_fields)
      items = Enum.find(fields, &(&1.name == :items))

      assert items
      assert items.from == :client_projection
      assert items.optimistic == true
    end

    test "no setter action is generated for the projection" do
      actions = ClientCartLive.__lavash__(:actions)
      refute Enum.any?(actions, &(&1.name == :set_items))
    end

    test "reads carry their client_states" do
      [read] = ClientCartLive.__lavash__(:reads)
      assert [%Lavash.Read.ClientState{name: :items, key: :id}] = read.client_states
    end
  end

  describe "server rendering" do
    test "projected list renders and ships in data-lavash-state", %{conn: conn} do
      cart = unique_cart()
      create_item!(cart, "Beans", 2, "9.50")

      {:ok, _view, html} = live(conn, "/magic/client-cart?cart_id=#{cart}")

      assert html =~ ~s(<span class="qty")
      assert html =~ ">2<"
      # data-lavash-state carries the projection (quantity + stringified decimal)
      assert html =~ "data-lavash-state"
      assert html =~ "&quot;quantity&quot;:2"
      assert html =~ "&quot;unit_price&quot;:&quot;9.50&quot;"
      # calc over the projection settles server-side (auto-wrapped in a
      # display span by the template transformer)
      assert html =~ ~s(data-lavash-display="item_count">2</span>)
    end
  end

  describe "action flow: pre_run write + same-event re-read" do
    test "increment's response carries the post-write list", %{conn: conn} do
      cart = unique_cart()
      item = create_item!(cart, "Beans", 2, "9.50")

      {:ok, view, _html} = live(conn, "/magic/client-cart?cart_id=#{cart}")

      html = view |> element("#item-#{item.id} button", "+") |> render_click()

      # The same event's diff reflects the persisted write — no stale list
      assert html =~ ~s(<span class="qty">3</span>)
      assert html =~ ~s(data-lavash-display="item_count">3</span>)
      assert html =~ "&quot;quantity&quot;:3"

      # And it actually persisted
      assert Ash.get!(Item, item.id).quantity == 3
    end

    test "mutate's :remove branch destroys at the boundary", %{conn: conn} do
      cart = unique_cart()
      item = create_item!(cart, "Beans", 1, "4.00")

      {:ok, view, _html} = live(conn, "/magic/client-cart?cart_id=#{cart}")

      html = view |> element("#item-#{item.id} button", "-") |> render_click()

      refute html =~ "item-#{item.id}"
      assert {:error, _} = Ash.get(Item, item.id)
    end

    test "append creates the record and the response carries the real row", %{conn: conn} do
      cart = unique_cart()

      {:ok, view, _html} = live(conn, "/magic/client-cart?cart_id=#{cart}")

      html = view |> element("#add-widget") |> render_click()

      assert html =~ "Widget"
      refute html =~ "__lavash_tmp_"

      [item] = Item |> Ash.Query.for_read(:for_cart, %{cart_id: cart}) |> Ash.read!()
      assert item.name == "Widget"
      assert item.quantity == 1
      assert html =~ item.id
    end

    test "append creates the record under the client-generated id", %{conn: conn} do
      cart = unique_cart()
      client_id = Ash.UUID.generate()

      {:ok, view, _html} = live(conn, "/magic/client-cart?cart_id=#{cart}")

      ids = Jason.encode!(%{"Lavash.Test.Magic.ClientCartLive:add_item:items" => client_id})
      html = view |> element("#add-widget") |> render_click(%{"_lavash_ids" => ids})

      # The persisted record carries the id the client predicted with —
      # the same-event re-read confirms the provisional row in place.
      assert Ash.get!(Item, client_id).name == "Widget"
      assert html =~ "item-#{client_id}"
    end

    test "malformed client id is ignored and the append still lands", %{conn: conn} do
      cart = unique_cart()
      {:ok, view, _html} = live(conn, "/magic/client-cart?cart_id=#{cart}")

      ids = Jason.encode!(%{"Lavash.Test.Magic.ClientCartLive:add_item:items" => "not-a-uuid"})
      view |> element("#add-widget") |> render_click(%{"_lavash_ids" => ids})

      [item] = Item |> Ash.Query.for_read(:for_cart, %{cart_id: cart}) |> Ash.read!()
      assert item.name == "Widget"
      refute item.id == "not-a-uuid"
    end

    test "garbage _lavash_ids payload is tolerated", %{conn: conn} do
      cart = unique_cart()
      {:ok, view, _html} = live(conn, "/magic/client-cart?cart_id=#{cart}")

      view |> element("#add-widget") |> render_click(%{"_lavash_ids" => "not json"})

      [item] = Item |> Ash.Query.for_read(:for_cart, %{cart_id: cart}) |> Ash.read!()
      assert item.name == "Widget"
    end

    test "upsert's conflict branch updates the matched record (no new row)", %{conn: conn} do
      cart = unique_cart()
      item = create_item!(cart, "Widget", 2, "2.50")

      {:ok, view, _html} = live(conn, "/magic/client-cart?cart_id=#{cart}")

      html = view |> element("#upsert-widget") |> render_click()

      assert html =~ ~s(<span class="qty">3</span>)
      assert Ash.get!(Item, item.id).quantity == 3

      # Still one row — matched, not duplicated.
      assert [_] = Item |> Ash.Query.for_read(:for_cart, %{cart_id: cart}) |> Ash.read!()
    end

    test "upsert's insert branch creates under the client-generated id", %{conn: conn} do
      cart = unique_cart()
      client_id = Ash.UUID.generate()

      {:ok, view, _html} = live(conn, "/magic/client-cart?cart_id=#{cart}")

      ids = Jason.encode!(%{"Lavash.Test.Magic.ClientCartLive:upsert_item:items" => client_id})
      html = view |> element("#upsert-widget") |> render_click(%{"_lavash_ids" => ids})

      assert Ash.get!(Item, client_id).name == "Widget"
      assert html =~ "item-#{client_id}"
    end

    test "remove's response drops the row and destroys the record", %{conn: conn} do
      cart = unique_cart()
      item = create_item!(cart, "Beans", 1, "4.00")
      keeper = create_item!(cart, "Filter", 1, "3.00")

      {:ok, view, _html} = live(conn, "/magic/client-cart?cart_id=#{cart}")

      html = view |> element("#item-#{item.id} button", "x") |> render_click()

      refute html =~ "item-#{item.id}"
      assert html =~ "item-#{keeper.id}"
      assert {:error, _} = Ash.get(Item, item.id)
    end
  end

  describe "compile-time validation" do
    test "client_state on an async read is rejected" do
      assert_raise Spark.Error.DslError, ~r/requires `async false`/, fn ->
        defmodule AsyncProjection do
          use Lavash.LiveView

          read :cart_items, Lavash.Test.Magic.ClientCart.Item, :for_cart do
            argument :cart_id, state(:cart_id)

            client_state :items do
              fields [:id]
            end
          end

          state :cart_id, :string, from: :url

          template do
            ~H"<div>{inspect(@items)}</div>"
          end
        end
      end
    end

    test "set targeting a projection is rejected" do
      assert_raise Spark.Error.DslError, ~r/targets a client_state projection/, fn ->
        defmodule SetProjection do
          use Lavash.LiveView

          state :cart_id, :string, from: :url

          read :cart_items, Lavash.Test.Magic.ClientCart.Item, :for_cart do
            argument :cart_id, state(:cart_id)
            async false

            client_state :items do
              fields [:id]
            end
          end

          actions do
            action :clear do
              set :items, []
            end
          end

          template do
            ~H"<div>{inspect(@items)}</div>"
          end
        end
      end
    end

    test "mutate targeting a non-projection field is rejected" do
      assert_raise Spark.Error.DslError, ~r/does not target a client_state projection/, fn ->
        defmodule MutateNonProjection do
          use Lavash.LiveView

          state :cart_id, :string, from: :url
          state :things, {:array, :map}, from: :ephemeral, default: []

          actions do
            action :bump, [:id] do
              mutate :things, :update, rx(%{quantity: @item.quantity + 1})
            end
          end

          template do
            ~H"<div>{inspect(@things)}</div>"
          end
        end
      end
    end

    test "mutate without the projection key as an action param is rejected" do
      assert_raise Spark.Error.DslError, ~r/needs the projection key/, fn ->
        defmodule MutateMissingKey do
          use Lavash.LiveView

          state :cart_id, :string, from: :url

          read :cart_items, Lavash.Test.Magic.ClientCart.Item, :for_cart do
            argument :cart_id, state(:cart_id)
            async false

            client_state :items do
              fields [:id, :quantity]
            end
          end

          actions do
            action :bump do
              mutate :items, :update_quantity, rx(%{quantity: @item.quantity + 1})
            end
          end

          template do
            ~H"<div>{inspect(@items)}</div>"
          end
        end
      end
    end

    test "upsert matching on a non-projected field is rejected" do
      assert_raise Spark.Error.DslError, ~r/not projected own fields/, fn ->
        defmodule UpsertUnprojectedMatch do
          use Lavash.LiveView

          state :cart_id, :string, from: :url

          read :cart_items, Lavash.Test.Magic.ClientCart.Item, :for_cart do
            argument :cart_id, state(:cart_id)
            async false

            client_state :items do
              fields [:id, :quantity]
            end
          end

          actions do
            action :add, [:name] do
              upsert :items,
                match: [:name],
                on_conflict: {:update_quantity, rx(%{quantity: @item.quantity + 1})},
                on_insert: {:create, rx(%{cart_id: @cart_id, name: @name, quantity: 1})}
            end
          end

          template do
            ~H"<div>{inspect(@items)}</div>"
          end
        end
      end
    end

    test "projection name colliding with declared state is rejected" do
      assert_raise Spark.Error.DslError, ~r/collides with a declared state/, fn ->
        defmodule CollidingProjection do
          use Lavash.LiveView

          state :cart_id, :string, from: :url
          state :items, {:array, :map}, from: :ephemeral, default: []

          read :cart_items, Lavash.Test.Magic.ClientCart.Item, :for_cart do
            argument :cart_id, state(:cart_id)
            async false

            client_state :items do
              fields [:id]
            end
          end

          template do
            ~H"<div>{inspect(@items)}</div>"
          end
        end
      end
    end
  end
end
