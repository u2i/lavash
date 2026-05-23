defmodule Lavash.Template.TokenTransformerTest do
  use ExUnit.Case, async: true

  alias Lavash.Template.TokenTransformer

  # ============================================
  # Helpers
  # ============================================

  defp meta(opts \\ []) do
    Map.merge(%{line: 1, column: 1, tag_name: "span", inner_location: {1, 7}}, Map.new(opts))
  end

  defp attr_meta, do: %{line: 1, column: 1}

  defp string_attr(name, value) do
    {name, {:string, value, %{delimiter: ?", line: 1, column: 1}}, attr_meta()}
  end

  defp expr_attr(name, expr) do
    {name, {:expr, expr, attr_meta()}, attr_meta()}
  end

  defp bool_attr(name) do
    {name, nil, attr_meta()}
  end

  defp body_expr(expr, opts \\ []) do
    {:body_expr, expr, Map.merge(%{line: 1, column: 1}, Map.new(opts))}
  end

  defp tag(name, attrs \\ [], opts \\ []) do
    {:tag, name, attrs, meta(Keyword.merge([tag_name: name], opts))}
  end

  defp close_tag(name) do
    {:close, :tag, name, %{line: 1, column: 1, tag_name: name, inner_location: {1, 1}}}
  end

  defp text(content) do
    {:text, content, %{line_end: 1, column_end: 1}}
  end

  defp optimistic_metadata(fields, opts \\ []) do
    field_map =
      fields
      |> Enum.map(fn
        {name, type} -> {name, %{name: name, type: type, optimistic: true, from: :ephemeral}}
        name -> {name, %{name: name, type: :any, optimistic: true, from: :ephemeral}}
      end)
      |> Map.new()

    context = Keyword.get(opts, :context, :live_view)
    calculations = Keyword.get(opts, :calculations, %{})
    derives = Keyword.get(opts, :derives, %{})
    forms = Keyword.get(opts, :forms, %{})
    actions = Keyword.get(opts, :actions, %{})
    attr_derives = Keyword.get(opts, :attr_derives, [])

    %{
      context: context,
      optimistic_fields: field_map,
      optimistic_derives: derives,
      calculations: calculations,
      forms: forms,
      actions: actions,
      optimistic_actions: %{},
      attr_derives: attr_derives,
      caller_module: __MODULE__
    }
  end

  defp state(metadata), do: %{lavash_metadata: metadata}

  defp transform(tokens, metadata) do
    TokenTransformer.transform(tokens, state(metadata))
  end

  # Check if a token list contains a span with data-lavash-display for a given field
  defp has_display_span?(tokens, field_name) do
    Enum.any?(tokens, fn
      {:tag, "span", attrs, _meta} ->
        Enum.any?(attrs, fn
          {"data-lavash-display", {:string, ^field_name, _}, _} -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  # Count display spans for a field
  defp count_display_spans(tokens, field_name) do
    Enum.count(tokens, fn
      {:tag, "span", attrs, _meta} ->
        Enum.any?(attrs, fn
          {"data-lavash-display", {:string, ^field_name, _}, _} -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  # ============================================
  # Display injection — basic wrapping
  # ============================================

  describe "display injection - basic wrapping" do
    test "wraps bare @field in <span data-lavash-display>" do
      tokens = [body_expr("@count")]
      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      assert has_display_span?(result, "count")
      assert Enum.any?(result, &match?({:body_expr, "@count", _}, &1))
      assert Enum.any?(result, &match?({:close, :tag, "span", _}, &1))
    end

    test "wraps multiple @field references" do
      tokens = [body_expr("@count"), text(" and "), body_expr("@total")]
      metadata = optimistic_metadata([:count, :total])
      result = transform(tokens, metadata)

      assert count_display_spans(result, "count") == 1
      assert count_display_spans(result, "total") == 1
    end

    test "preserves original body_expr inside the span" do
      tokens = [body_expr("@count")]
      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      # Should be: span open, body_expr, span close
      assert [{:tag, "span", _, _}, {:body_expr, "@count", _}, {:close, :tag, "span", _}] = result
    end

    test "works with field inside an existing tag (mixed content)" do
      tokens = [
        tag("p"),
        text("Total: "),
        body_expr("@count"),
        close_tag("p")
      ]

      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      assert has_display_span?(result, "count")
      # p tag should still be there
      assert Enum.any?(result, &match?({:tag, "p", _, _}, &1))
    end
  end

  # ============================================
  # Display injection — skip conditions
  # ============================================

  describe "display injection - skip conditions" do
    test "skips non-bare expression (function call)" do
      tokens = [body_expr("inspect(@count)")]
      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      refute has_display_span?(result, "count")
      assert [{:body_expr, "inspect(@count)", _}] = result
    end

    test "skips arithmetic expression" do
      tokens = [body_expr("@a + @b")]
      metadata = optimistic_metadata([:a, :b])
      result = transform(tokens, metadata)

      refute has_display_span?(result, "a")
      refute has_display_span?(result, "b")
    end

    test "skips non-optimistic field" do
      tokens = [body_expr("@count")]
      metadata = optimistic_metadata([])
      result = transform(tokens, metadata)

      refute has_display_span?(result, "count")
      assert [{:body_expr, "@count", _}] = result
    end

    test "skips when inside parent tag with data-lavash-display" do
      tokens = [
        tag("span", [string_attr("data-lavash-display", "count")]),
        body_expr("@count"),
        close_tag("span")
      ]

      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      # Should have exactly 1 display span (the manually-added one), not 2
      assert count_display_spans(result, "count") == 1
    end

    test "skips when inside parent tag with data-lavash-manual" do
      tokens = [
        tag("span", [bool_attr("data-lavash-manual")]),
        body_expr("@count"),
        close_tag("span")
      ]

      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      refute has_display_span?(result, "count")
    end

    test "skips when no optimistic fields at all" do
      tokens = [body_expr("@count")]
      metadata = optimistic_metadata([])
      result = transform(tokens, metadata)

      refute has_display_span?(result, "count")
    end

    test "passes through with empty metadata" do
      tokens = [body_expr("@count")]
      result = transform(tokens, %{})

      assert [{:body_expr, "@count", _}] = result
    end
  end

  # ============================================
  # Display injection — edge cases
  # ============================================

  describe "display injection - edge cases" do
    test "recognizes optimistic_derives" do
      tokens = [body_expr("@form_valid")]
      metadata = optimistic_metadata([], derives: %{form_valid: %{optimistic: true}})
      result = transform(tokens, metadata)

      assert has_display_span?(result, "form_valid")
    end

    test "recognizes calculations" do
      tokens = [body_expr("@doubled")]
      metadata = optimistic_metadata([], calculations: %{doubled: %{optimistic: true}})
      result = transform(tokens, metadata)

      assert has_display_span?(result, "doubled")
    end

    test "handles nonexistent atom gracefully" do
      tokens = [body_expr("@this_atom_does_not_exist_xyz_123")]
      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      # Should not crash, should pass through
      assert [{:body_expr, "@this_atom_does_not_exist_xyz_123", _}] = result
    end

    test "resumes wrapping after display parent closes" do
      tokens = [
        # Inside display parent — skip
        tag("span", [string_attr("data-lavash-display", "total")]),
        body_expr("@total"),
        close_tag("span"),
        # After display parent closes — should wrap
        body_expr("@count")
      ]

      metadata = optimistic_metadata([:count, :total])
      result = transform(tokens, metadata)

      # total: manually-displayed, count: auto-wrapped
      assert count_display_spans(result, "total") == 1
      assert count_display_spans(result, "count") == 1
    end
  end

  # ============================================
  # State binding injection
  # ============================================

  describe "state binding injection" do
    test "injects data-lavash-bind for <input value={@field}> on optimistic field" do
      tokens = [tag("input", [expr_attr("value", "@count")])]
      metadata = optimistic_metadata([{:count, :integer}])
      result = transform(tokens, metadata)

      [{:tag, "input", attrs, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-bind" end)
    end

    test "skips when field is not optimistic" do
      tokens = [tag("input", [expr_attr("value", "@count")])]
      metadata = optimistic_metadata([])
      result = transform(tokens, metadata)

      [{:tag, "input", attrs, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-bind" end)
    end

    test "skips on non-input elements" do
      tokens = [tag("div", [expr_attr("value", "@count")])]
      metadata = optimistic_metadata([{:count, :integer}])
      result = transform(tokens, metadata)

      [{:tag, "div", attrs, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-bind" end)
    end

    test "skips when data-lavash-bind already present" do
      tokens = [
        tag("input", [expr_attr("value", "@count"), string_attr("data-lavash-bind", "count")])
      ]

      metadata = optimistic_metadata([{:count, :integer}])
      result = transform(tokens, metadata)

      [{:tag, "input", attrs, _}] = result
      bind_count = Enum.count(attrs, fn {name, _, _} -> name == "data-lavash-bind" end)
      assert bind_count == 1
    end
  end

  # ============================================
  # Visibility injection
  # ============================================

  describe "visibility injection" do
    test "injects data-lavash-visible for :if={@bool_field} on optimistic boolean" do
      tokens = [tag("span", [expr_attr(":if", "@visible")])]
      metadata = optimistic_metadata([{:visible, :boolean}])
      result = transform(tokens, metadata)

      [{:tag, "span", attrs, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-visible" end)
    end

    test "skips when field is not boolean" do
      tokens = [tag("span", [expr_attr(":if", "@count")])]
      metadata = optimistic_metadata([{:count, :integer}])
      result = transform(tokens, metadata)

      [{:tag, "span", attrs, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-visible" end)
    end

    test "recognizes optimistic derives as boolean-capable" do
      tokens = [tag("span", [expr_attr(":if", "@form_valid")])]
      metadata = optimistic_metadata([], derives: %{form_valid: %{optimistic: true}})
      result = transform(tokens, metadata)

      [{:tag, "span", attrs, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-visible" end)
    end

    test "skips when data-lavash-visible already present" do
      tokens = [
        tag("span", [expr_attr(":if", "@visible"), string_attr("data-lavash-visible", "visible")])
      ]

      metadata = optimistic_metadata([{:visible, :boolean}])
      result = transform(tokens, metadata)

      [{:tag, "span", attrs, _}] = result
      vis_count = Enum.count(attrs, fn {name, _, _} -> name == "data-lavash-visible" end)
      assert vis_count == 1
    end
  end

  # ============================================
  # Enabled injection
  # ============================================

  describe "enabled injection" do
    test "injects data-lavash-enabled for disabled={not @field}" do
      tokens = [tag("button", [expr_attr("disabled", "not @form_valid")])]
      metadata = optimistic_metadata([], derives: %{form_valid: %{optimistic: true}})
      result = transform(tokens, metadata)

      [{:tag, "button", attrs, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-enabled" end)
    end

    test "skips when expression is not 'not @field' pattern" do
      tokens = [tag("button", [expr_attr("disabled", "@loading")])]
      metadata = optimistic_metadata([{:loading, :boolean}])
      result = transform(tokens, metadata)

      [{:tag, "button", attrs, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-enabled" end)
    end
  end

  # ============================================
  # phx-target injection
  # ============================================

  describe "phx-target injection" do
    test "injects phx-target={@myself} in component context with phx-click" do
      tokens = [tag("button", [string_attr("phx-click", "increment")])]
      metadata = optimistic_metadata([], context: :component)
      result = transform(tokens, metadata)

      [{:tag, "button", attrs, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "phx-target" end)
    end

    test "skips in live_view context" do
      tokens = [tag("button", [string_attr("phx-click", "increment")])]
      metadata = optimistic_metadata([], context: :live_view)
      result = transform(tokens, metadata)

      [{:tag, "button", attrs, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "phx-target" end)
    end

    test "skips when phx-target already present" do
      tokens = [
        tag("button", [string_attr("phx-click", "increment"), expr_attr("phx-target", "@myself")])
      ]

      metadata = optimistic_metadata([], context: :component)
      result = transform(tokens, metadata)

      [{:tag, "button", attrs, _}] = result
      target_count = Enum.count(attrs, fn {name, _, _} -> name == "phx-target" end)
      assert target_count == 1
    end

    test "skips when no phx-event attributes present" do
      tokens = [tag("button", [string_attr("class", "btn")])]
      metadata = optimistic_metadata([], context: :component)
      result = transform(tokens, metadata)

      [{:tag, "button", attrs, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "phx-target" end)
    end
  end

  # ============================================
  # Component binding injection
  # ============================================

  describe "component binding injection" do
    test "injects __lavash_client_bindings__ on lavash_component in component context" do
      tokens = [{:local_component, "lavash_component", [string_attr("id", "test")], meta()}]
      metadata = optimistic_metadata([], context: :component)
      result = transform(tokens, metadata)

      [{:local_component, "lavash_component", attrs, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "__lavash_client_bindings__" end)
    end

    test "skips in live_view context" do
      tokens = [{:local_component, "lavash_component", [string_attr("id", "test")], meta()}]
      metadata = optimistic_metadata([], context: :live_view)
      result = transform(tokens, metadata)

      [{:local_component, "lavash_component", attrs, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "__lavash_client_bindings__" end)
    end

    test "skips on non-lavash components" do
      tokens = [{:local_component, "link", [string_attr("href", "/")], meta()}]
      metadata = optimistic_metadata([], context: :component)
      result = transform(tokens, metadata)

      [{:local_component, "link", attrs, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "__lavash_client_bindings__" end)
    end
  end

  # ============================================
  # data-lavash-manual opt-out
  # ============================================

  describe "data-lavash-manual opt-out" do
    test "skips all tag injections on element with data-lavash-manual" do
      tokens = [
        tag("input", [
          bool_attr("data-lavash-manual"),
          expr_attr("value", "@count"),
          string_attr("phx-click", "inc")
        ])
      ]

      metadata = optimistic_metadata([{:count, :integer}], context: :component)
      result = transform(tokens, metadata)

      [{:tag, "input", attrs, _}] = result
      # Should NOT inject data-lavash-bind or phx-target
      refute Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-bind" end)
      refute Enum.any?(attrs, fn {name, _, _} -> name == "phx-target" end)
    end
  end

  # ============================================
  # Smoke test — real tokenizer round-trip
  # ============================================

  describe "smoke test with real tokenizer" do
    test "auto-injects display span via full tokenize + transform pipeline" do
      tokens =
        Lavash.TagEngine.tokenize("<div>{@count}</div>",
          file: "test.heex",
          line: 1,
          caller: __ENV__,
          tag_handler: Phoenix.LiveView.HTMLEngine
        )

      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      assert has_display_span?(result, "count")
    end

    test "mixed content produces inline span" do
      tokens =
        Lavash.TagEngine.tokenize("<p>Total: {@count}</p>",
          file: "test.heex",
          line: 1,
          caller: __ENV__,
          tag_handler: Phoenix.LiveView.HTMLEngine
        )

      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      assert has_display_span?(result, "count")
      # p tag preserved
      assert Enum.any?(result, &match?({:tag, "p", _, _}, &1))
      # text preserved
      assert Enum.any?(result, &match?({:text, "Total: ", _}, &1))
    end

    test "function-wrapped expression is not auto-injected" do
      tokens =
        Lavash.TagEngine.tokenize("<span>{inspect(@roast)}</span>",
          file: "test.heex",
          line: 1,
          caller: __ENV__,
          tag_handler: Phoenix.LiveView.HTMLEngine
        )

      metadata = optimistic_metadata([:roast])
      result = transform(tokens, metadata)

      refute has_display_span?(result, "roast")
    end
  end
end
