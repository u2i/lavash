defmodule Lavash.PubSubTest do
  use ExUnit.Case, async: true

  alias Lavash.PubSub

  defmodule TestResource do
  end

  describe "resource_topic/1" do
    test "returns topic string for resource" do
      assert PubSub.resource_topic(TestResource) == "lavash:Elixir.Lavash.PubSubTest.TestResource"
    end
  end

  describe "topic/1 (deprecated)" do
    test "delegates to resource_topic" do
      assert PubSub.topic(TestResource) == PubSub.resource_topic(TestResource)
    end
  end

  describe "combination_topic/3" do
    test "returns resource topic when no filters active" do
      topic = PubSub.combination_topic(TestResource, [:category_id, :in_stock], %{})
      assert topic == PubSub.resource_topic(TestResource)
    end

    test "returns resource topic when all filters are nil" do
      topic =
        PubSub.combination_topic(TestResource, [:category_id, :in_stock], %{
          category_id: nil,
          in_stock: nil
        })

      assert topic == PubSub.resource_topic(TestResource)
    end

    test "builds topic with single filter" do
      topic =
        PubSub.combination_topic(TestResource, [:category_id, :in_stock], %{
          category_id: "cat-123",
          in_stock: nil
        })

      assert topic == "lavash:Elixir.Lavash.PubSubTest.TestResource:category_id=cat-123"
    end

    test "builds topic with multiple filters sorted alphabetically" do
      topic =
        PubSub.combination_topic(TestResource, [:in_stock, :category_id], %{
          category_id: "cat-123",
          in_stock: true
        })

      # category_id comes before in_stock alphabetically
      assert topic ==
               "lavash:Elixir.Lavash.PubSubTest.TestResource:category_id=cat-123&in_stock=true"
    end

    test "encodes integer values" do
      topic =
        PubSub.combination_topic(TestResource, [:count], %{
          count: 42
        })

      assert topic == "lavash:Elixir.Lavash.PubSubTest.TestResource:count=42"
    end

    test "encodes atom values" do
      topic =
        PubSub.combination_topic(TestResource, [:status], %{
          status: :active
        })

      assert topic == "lavash:Elixir.Lavash.PubSubTest.TestResource:status=active"
    end

    test "encodes boolean values" do
      topic =
        PubSub.combination_topic(TestResource, [:enabled], %{
          enabled: false
        })

      assert topic == "lavash:Elixir.Lavash.PubSubTest.TestResource:enabled=false"
    end

    test "encodes float values" do
      topic =
        PubSub.combination_topic(TestResource, [:price], %{
          price: 19.99
        })

      assert String.starts_with?(topic, "lavash:Elixir.Lavash.PubSubTest.TestResource:price=19.99")
    end

    test "encodes Decimal values" do
      topic =
        PubSub.combination_topic(TestResource, [:amount], %{
          amount: Decimal.new("100.50")
        })

      assert topic == "lavash:Elixir.Lavash.PubSubTest.TestResource:amount=100.50"
    end
  end

  describe "pubsub/0" do
    test "returns nil when not configured" do
      # Clear any existing config
      original = Application.get_env(:lavash, :pubsub)
      Application.delete_env(:lavash, :pubsub)

      assert PubSub.pubsub() == nil

      # Restore
      if original, do: Application.put_env(:lavash, :pubsub, original)
    end
  end

  describe "subscribe/1 without pubsub configured" do
    test "returns :ok when pubsub not configured" do
      original = Application.get_env(:lavash, :pubsub)
      Application.delete_env(:lavash, :pubsub)

      assert PubSub.subscribe(TestResource) == :ok

      if original, do: Application.put_env(:lavash, :pubsub, original)
    end
  end

  describe "broadcast/1 without pubsub configured" do
    test "returns :ok when pubsub not configured" do
      original = Application.get_env(:lavash, :pubsub)
      Application.delete_env(:lavash, :pubsub)

      assert PubSub.broadcast(TestResource) == :ok

      if original, do: Application.put_env(:lavash, :pubsub, original)
    end
  end

  describe "subscribe_combination/3 without pubsub configured" do
    test "returns :ok when pubsub not configured" do
      original = Application.get_env(:lavash, :pubsub)
      Application.delete_env(:lavash, :pubsub)

      assert PubSub.subscribe_combination(TestResource, [:category_id], %{category_id: "cat-1"}) ==
               :ok

      if original, do: Application.put_env(:lavash, :pubsub, original)
    end
  end

  describe "unsubscribe_combination/3 without pubsub configured" do
    test "returns :ok when pubsub not configured" do
      original = Application.get_env(:lavash, :pubsub)
      Application.delete_env(:lavash, :pubsub)

      assert PubSub.unsubscribe_combination(TestResource, [:category_id], %{category_id: "cat-1"}) ==
               :ok

      if original, do: Application.put_env(:lavash, :pubsub, original)
    end
  end

  describe "broadcast_mutation/4 without pubsub configured" do
    test "returns :ok when pubsub not configured" do
      original = Application.get_env(:lavash, :pubsub)
      Application.delete_env(:lavash, :pubsub)

      assert PubSub.broadcast_mutation(
               TestResource,
               [:category_id],
               %{category_id: {"old", "new"}},
               %{}
             ) == :ok

      if original, do: Application.put_env(:lavash, :pubsub, original)
    end
  end
end
