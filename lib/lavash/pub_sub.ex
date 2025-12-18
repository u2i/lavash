defmodule Lavash.PubSub do
  @moduledoc """
  PubSub integration for cross-process resource invalidation.

  When a Lavash form submits successfully, it broadcasts to all subscribers
  watching that resource. Supports both coarse-grained (resource-level) and
  fine-grained (combination-based) invalidation.

  ## Configuration

  Configure your app's PubSub in config:

      config :lavash, pubsub: MyApp.PubSub

  ## Topic Types

  ### Resource-level topics
  Format: `lavash:<Resource>`
  Example: `lavash:MyApp.Product`
  Used when no specific attributes are being watched.

  ### Combination topics
  Format: `lavash:<Resource>:<attr1>=<val1>&<attr2>=<val2>`
  Example: `lavash:MyApp.Product:category_id=abc-123&in_stock=true`
  Used for fine-grained invalidation based on filter combinations.
  Attributes are sorted alphabetically for consistent topic names.

  ## How it works

  1. On mount, Lavash subscribes to a combination topic based on current filter values
  2. On mutation, broadcasts to all subset combinations of the record's attribute values
  3. This ensures any consumer filtering on any subset of those attributes gets notified
  4. Both old and new values are broadcast to handle additions and removals

  ## Example

  A product with `category_id=cat-a`, `in_stock=true` will broadcast to:
  - `lavash:Product:category_id=cat-a&in_stock=true` (both specified)
  - `lavash:Product:category_id=cat-a` (only category)
  - `lavash:Product:in_stock=true` (only in_stock)
  - `lavash:Product` (resource-level, neither specified)

  A consumer filtering `category_id=cat-a, in_stock=nil` subscribes to:
  - `lavash:Product:category_id=cat-a` (only category specified)
  """

  @doc """
  Returns the configured PubSub module, or nil if not configured.
  """
  def pubsub do
    Application.get_env(:lavash, :pubsub)
  end

  # ============================================================================
  # Resource-level subscriptions (coarse-grained)
  # ============================================================================

  @doc """
  Subscribe the current process to all invalidation events for a resource.
  """
  def subscribe(resource) when is_atom(resource) do
    case pubsub() do
      nil -> :ok
      pubsub_mod -> Phoenix.PubSub.subscribe(pubsub_mod, resource_topic(resource))
    end
  end

  @doc """
  Broadcast a resource mutation to all resource-level subscribers.
  """
  def broadcast(resource) when is_atom(resource) do
    case pubsub() do
      nil ->
        :ok

      pubsub_mod ->
        Phoenix.PubSub.broadcast(
          pubsub_mod,
          resource_topic(resource),
          {:lavash_invalidate, resource}
        )
    end
  end

  @doc """
  Returns the resource-level topic name.
  """
  def resource_topic(resource) when is_atom(resource) do
    "lavash:#{resource}"
  end

  # ============================================================================
  # Combination-based subscriptions (fine-grained)
  # ============================================================================

  @doc """
  Subscribe to invalidation events for a specific combination of attribute values.

  The filter_values map contains the current filter state. Attributes with nil
  values are considered "not filtered" and are excluded from the topic.

  ## Examples

      # Filtering by category only
      subscribe_combination(Product, [:category_id, :in_stock], %{category_id: "cat-a", in_stock: nil})
      # Subscribes to: lavash:Product:category_id=cat-a

      # Filtering by both
      subscribe_combination(Product, [:category_id, :in_stock], %{category_id: "cat-a", in_stock: true})
      # Subscribes to: lavash:Product:category_id=cat-a&in_stock=true

      # No filters active
      subscribe_combination(Product, [:category_id, :in_stock], %{category_id: nil, in_stock: nil})
      # Subscribes to: lavash:Product (resource-level)
  """
  def subscribe_combination(resource, watched_attrs, filter_values)
      when is_atom(resource) and is_list(watched_attrs) and is_map(filter_values) do
    case pubsub() do
      nil ->
        :ok

      pubsub_mod ->
        topic = combination_topic(resource, watched_attrs, filter_values)
        Phoenix.PubSub.subscribe(pubsub_mod, topic)
    end
  end

  @doc """
  Unsubscribe from a specific combination topic.
  """
  def unsubscribe_combination(resource, watched_attrs, filter_values)
      when is_atom(resource) and is_list(watched_attrs) and is_map(filter_values) do
    case pubsub() do
      nil ->
        :ok

      pubsub_mod ->
        topic = combination_topic(resource, watched_attrs, filter_values)
        Phoenix.PubSub.unsubscribe(pubsub_mod, topic)
    end
  end

  @doc """
  Broadcast a mutation to all relevant combination topics.

  Takes attribute changes (old and new values) and broadcasts to all subset
  combinations. This ensures any consumer filtering on any subset of these
  attributes will be notified.

  ## Parameters

  - `resource`: The Ash resource module
  - `watched_attrs`: List of attributes that consumers might filter on
  - `changes`: Map of %{attr => {old_value, new_value}} for changed attributes
  - `unchanged`: Map of %{attr => value} for unchanged attributes

  ## Example

      # Product's category changed from cat-a to cat-b, in_stock stayed true
      broadcast_mutation(Product, [:category_id, :in_stock],
        %{category_id: {"cat-a", "cat-b"}},
        %{in_stock: true}
      )

      # This broadcasts to topics for both old and new values:
      # Old value combinations (for removals from queries):
      #   - lavash:Product:category_id=cat-a&in_stock=true
      #   - lavash:Product:category_id=cat-a
      #   - lavash:Product:in_stock=true
      # New value combinations (for additions to queries):
      #   - lavash:Product:category_id=cat-b&in_stock=true
      #   - lavash:Product:category_id=cat-b
      #   - lavash:Product:in_stock=true (same as old, deduped)
  """
  def broadcast_mutation(resource, watched_attrs, changes, unchanged \\ %{})
      when is_atom(resource) and is_list(watched_attrs) and is_map(changes) and is_map(unchanged) do
    case pubsub() do
      nil ->
        :ok

      pubsub_mod ->
        message = {:lavash_invalidate, resource}

        # Build old and new value maps
        old_values = build_values_map(changes, unchanged, :old)
        new_values = build_values_map(changes, unchanged, :new)

        # Generate all subset combinations for both old and new values
        old_topics = all_combination_topics(resource, watched_attrs, old_values)
        new_topics = all_combination_topics(resource, watched_attrs, new_values)

        # Dedupe and broadcast
        all_topics = Enum.uniq(old_topics ++ new_topics)

        Enum.each(all_topics, fn topic ->
          Phoenix.PubSub.broadcast(pubsub_mod, topic, message)
        end)

        :ok
    end
  end

  @doc """
  Returns the combination topic for a specific set of filter values.
  Only includes attributes with non-nil values. Attributes are sorted alphabetically.
  """
  def combination_topic(resource, watched_attrs, filter_values)
      when is_atom(resource) and is_list(watched_attrs) and is_map(filter_values) do
    # Filter to only watched attrs with non-nil values, sort alphabetically
    active_filters =
      watched_attrs
      |> Enum.filter(fn attr -> Map.get(filter_values, attr) != nil end)
      |> Enum.sort()
      |> Enum.map(fn attr -> {attr, Map.get(filter_values, attr)} end)

    if active_filters == [] do
      # No active filters - use resource-level topic
      resource_topic(resource)
    else
      # Build combination topic
      filter_str =
        active_filters
        |> Enum.map(fn {attr, value} -> "#{attr}=#{encode_value(value)}" end)
        |> Enum.join("&")

      "lavash:#{resource}:#{filter_str}"
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  # Build a values map for either old or new values
  defp build_values_map(changes, unchanged, which) do
    changed_values =
      Enum.map(changes, fn {attr, {old_val, new_val}} ->
        {attr, if(which == :old, do: old_val, else: new_val)}
      end)
      |> Map.new()

    Map.merge(unchanged, changed_values)
  end

  # Generate all subset combination topics for a set of values
  defp all_combination_topics(resource, watched_attrs, values) do
    # Generate power set of watched_attrs (all subsets)
    subsets = power_set(watched_attrs)

    Enum.map(subsets, fn subset_attrs ->
      # Build filter values for this subset
      filter_values = Map.take(values, subset_attrs)
      combination_topic(resource, subset_attrs, filter_values)
    end)
  end

  # Generate power set (all subsets) of a list
  defp power_set([]), do: [[]]

  defp power_set([h | t]) do
    rest = power_set(t)
    rest ++ Enum.map(rest, &[h | &1])
  end

  # Encode values for topic names
  defp encode_value(nil), do: ""
  defp encode_value(value) when is_binary(value), do: value
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_float(value), do: Float.to_string(value)
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(%Decimal{} = value), do: Decimal.to_string(value)
  defp encode_value(value), do: to_string(value)

  # ============================================================================
  # Backward compatibility
  # ============================================================================

  @doc deprecated: "Use resource_topic/1 instead"
  def topic(resource), do: resource_topic(resource)
end
