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

  # Build a `:block` node (HTML element with children). Pass `children: [...]`
  # in opts to populate inner nodes; otherwise the block is empty. Pass
  # `closing: :void` or `closing: :self` to produce a `:self_close` node
  # instead (the old "void/self-closing tag" shape).
  defp tag(name, attrs \\ [], opts \\ []) do
    {children, opts} = Keyword.pop(opts, :children, [])
    {closing, opts} = Keyword.pop(opts, :closing, nil)
    m = meta(Keyword.merge([tag_name: name], opts))

    case closing do
      c when c in [:void, :self] ->
        {:self_close, :tag, name, attrs, m}

      _ ->
        {:block, :tag, name, attrs, children, m, m}
    end
  end

  # In the tree shape there's no separate close token — the block carries its
  # close meta itself. Some tests still emit `close_tag/1` between siblings;
  # those tests use `tag/3` + `close_tag/1` to bracket children, so we treat
  # `close_tag/1` as a marker that means "use the preceding tag as a parent
  # with the intervening nodes as children". The shape-builder below handles
  # that. For the simple uses (between manual display wrappers), tests are
  # updated to use `tag(.., children: [...])` instead.
  defp close_tag(name) do
    {:__close_marker__, name}
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
    forms = Keyword.get(opts, :forms, %{})
    actions = Keyword.get(opts, :actions, %{})
    attr_derives = Keyword.get(opts, :attr_derives, [])

    %{
      context: context,
      optimistic_fields: field_map,
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

  # Check if a node tree contains a span with data-lavash-display for a given
  # field (anywhere in the tree, not just at the top level).
  defp has_display_span?(nodes, field_name) do
    count_display_spans(nodes, field_name) > 0
  end

  defp count_display_spans(nodes, field_name) when is_list(nodes) do
    Enum.reduce(nodes, 0, fn node, acc -> acc + count_display_spans(node, field_name) end)
  end

  defp count_display_spans({:block, :tag, "span", attrs, children, _, _}, field_name) do
    self =
      if Enum.any?(attrs, fn
           {"data-lavash-display", {:string, ^field_name, _}, _} -> true
           _ -> false
         end),
         do: 1,
         else: 0

    self + count_display_spans(children, field_name)
  end

  defp count_display_spans({:block, _type, _name, _attrs, children, _, _}, field_name) do
    count_display_spans(children, field_name)
  end

  defp count_display_spans(_node, _field_name), do: 0

  # ============================================
  # Display injection — basic wrapping
  # ============================================

  describe "display injection - basic wrapping" do
    test "wraps bare @field in <span data-lavash-display>" do
      tokens = [body_expr("@count")]
      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      assert has_display_span?(result, "count")
      # The body_expr is now a child of the span block
      assert [
               {:block, :tag, "span", _attrs, [{:body_expr, "@count", _}], _open_meta,
                _close_meta}
             ] = result
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

      assert [
               {:block, :tag, "span", _attrs, [{:body_expr, "@count", _}], _open_meta,
                _close_meta}
             ] = result
    end

    test "works with field inside an existing tag (mixed content)" do
      tokens = [
        tag("p", [],
          children: [
            text("Total: "),
            body_expr("@count")
          ]
        )
      ]

      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      assert has_display_span?(result, "count")
      # p tag should still be there
      assert Enum.any?(result, &match?({:block, :tag, "p", _, _, _, _}, &1))
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
        tag("span", [string_attr("data-lavash-display", "count")],
          children: [body_expr("@count")]
        )
      ]

      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      # Should have exactly 1 display span (the manually-added one), not 2
      assert count_display_spans(result, "count") == 1
    end

    test "skips when inside parent tag with data-lavash-manual" do
      tokens = [
        tag("span", [bool_attr("data-lavash-manual")], children: [body_expr("@count")])
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

    test "void elements (e.g. <input>) inside a display-wrapped parent don't break detection" do
      # <div data-lavash-display="count"><input/>{@count}</div>
      tokens = [
        tag("div", [string_attr("data-lavash-display", "count")],
          children: [
            tag("input", [], closing: :void),
            body_expr("@count")
          ]
        )
      ]

      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      # The div is already a display wrapper; no additional <span> should be injected.
      assert count_display_spans(result, "count") == 0
    end

    test "self-closing tags also pass-through without consuming the depth slot" do
      tokens = [
        tag("div", [string_attr("data-lavash-display", "count")],
          children: [
            tag("br", [], closing: :self),
            body_expr("@count")
          ]
        )
      ]

      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      assert count_display_spans(result, "count") == 0
    end

    test "passes through with empty metadata" do
      tokens = [body_expr("@count")]
      result = transform(tokens, %{})

      assert [{:body_expr, "@count", _}] = result
    end

    # u2i/lavash#16 — wrapping `{@field}` in a span inside `<textarea>` /
    # `<option>` corrupts the form value because the browser treats the
    # body content as the submitted value (not as rendered DOM).
    test "skips when inside <textarea> (body content is the form value)" do
      tokens = [
        tag("textarea", [string_attr("name", "notes")], children: [body_expr("@notes")])
      ]

      metadata = optimistic_metadata([:notes])
      result = transform(tokens, metadata)

      refute has_display_span?(result, "notes"),
             "should not wrap {@notes} inside <textarea> — submitted value would be literal HTML"

      # body_expr should still be present unwrapped
      assert [
               {:block, :tag, "textarea", _attrs, [{:body_expr, "@notes", _}], _, _}
             ] = result
    end

    test "skips when inside <option> (body content is the displayed label)" do
      tokens = [
        tag("option", [string_attr("value", "a")], children: [body_expr("@label")])
      ]

      metadata = optimistic_metadata([:label])
      result = transform(tokens, metadata)

      refute has_display_span?(result, "label")
    end
  end

  # ============================================
  # Display injection — edge cases
  # ============================================

  describe "display injection - edge cases" do
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
        tag("span", [string_attr("data-lavash-display", "total")],
          children: [body_expr("@total")]
        ),
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

      [{:block, :tag, "input", attrs, _children, _, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-bind" end)
    end

    test "skips when field is not optimistic" do
      tokens = [tag("input", [expr_attr("value", "@count")])]
      metadata = optimistic_metadata([])
      result = transform(tokens, metadata)

      [{:block, :tag, "input", attrs, _children, _, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-bind" end)
    end

    test "skips on non-input elements" do
      tokens = [tag("div", [expr_attr("value", "@count")])]
      metadata = optimistic_metadata([{:count, :integer}])
      result = transform(tokens, metadata)

      [{:block, :tag, "div", attrs, _children, _, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-bind" end)
    end

    test "skips when data-lavash-bind already present" do
      tokens = [
        tag("input", [expr_attr("value", "@count"), string_attr("data-lavash-bind", "count")])
      ]

      metadata = optimistic_metadata([{:count, :integer}])
      result = transform(tokens, metadata)

      [{:block, :tag, "input", attrs, _children, _, _}] = result
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

      [{:block, :tag, "span", attrs, _children, _, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-visible" end)
    end

    test "skips when field is not boolean" do
      tokens = [tag("span", [expr_attr(":if", "@count")])]
      metadata = optimistic_metadata([{:count, :integer}])
      result = transform(tokens, metadata)

      [{:block, :tag, "span", attrs, _children, _, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-visible" end)
    end

    test "recognizes optimistic calculations as boolean-capable" do
      tokens = [tag("span", [expr_attr(":if", "@form_valid")])]
      metadata = optimistic_metadata([], calculations: %{form_valid: %{optimistic: true}})
      result = transform(tokens, metadata)

      [{:block, :tag, "span", attrs, _children, _, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-visible" end)
    end

    test "skips when data-lavash-visible already present" do
      tokens = [
        tag("span", [expr_attr(":if", "@visible"), string_attr("data-lavash-visible", "visible")])
      ]

      metadata = optimistic_metadata([{:visible, :boolean}])
      result = transform(tokens, metadata)

      [{:block, :tag, "span", attrs, _children, _, _}] = result
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
      metadata = optimistic_metadata([], calculations: %{form_valid: %{optimistic: true}})
      result = transform(tokens, metadata)

      [{:block, :tag, "button", attrs, _children, _, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "data-lavash-enabled" end)
    end

    test "skips when expression is not 'not @field' pattern" do
      tokens = [tag("button", [expr_attr("disabled", "@loading")])]
      metadata = optimistic_metadata([{:loading, :boolean}])
      result = transform(tokens, metadata)

      [{:block, :tag, "button", attrs, _children, _, _}] = result
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

      [{:block, :tag, "button", attrs, _children, _, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "phx-target" end)
    end

    test "skips in live_view context" do
      tokens = [tag("button", [string_attr("phx-click", "increment")])]
      metadata = optimistic_metadata([], context: :live_view)
      result = transform(tokens, metadata)

      [{:block, :tag, "button", attrs, _children, _, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "phx-target" end)
    end

    test "skips when phx-target already present" do
      tokens = [
        tag("button", [string_attr("phx-click", "increment"), expr_attr("phx-target", "@myself")])
      ]

      metadata = optimistic_metadata([], context: :component)
      result = transform(tokens, metadata)

      [{:block, :tag, "button", attrs, _children, _, _}] = result
      target_count = Enum.count(attrs, fn {name, _, _} -> name == "phx-target" end)
      assert target_count == 1
    end

    test "skips when no phx-event attributes present" do
      tokens = [tag("button", [string_attr("class", "btn")])]
      metadata = optimistic_metadata([], context: :component)
      result = transform(tokens, metadata)

      [{:block, :tag, "button", attrs, _children, _, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "phx-target" end)
    end
  end

  # ============================================
  # Component binding injection
  # ============================================

  describe "component binding injection" do
    test "injects __lavash_client_bindings__ on lavash_component in component context" do
      tokens = [local_component("lavash_component", [string_attr("id", "test")])]
      metadata = optimistic_metadata([], context: :component)
      result = transform(tokens, metadata)

      [{:self_close, :local_component, "lavash_component", attrs, _}] = result
      assert Enum.any?(attrs, fn {name, _, _} -> name == "__lavash_client_bindings__" end)
    end

    test "skips in live_view context" do
      tokens = [local_component("lavash_component", [string_attr("id", "test")])]
      metadata = optimistic_metadata([], context: :live_view)
      result = transform(tokens, metadata)

      [{:self_close, :local_component, "lavash_component", attrs, _}] = result
      refute Enum.any?(attrs, fn {name, _, _} -> name == "__lavash_client_bindings__" end)
    end

    test "skips on non-lavash components" do
      tokens = [local_component("link", [string_attr("href", "/")])]
      metadata = optimistic_metadata([], context: :component)
      result = transform(tokens, metadata)

      [{:self_close, :local_component, "link", attrs, _}] = result
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

      [{:block, :tag, "input", attrs, _children, _, _}] = result
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
      %Phoenix.LiveView.TagEngine.Parser{nodes: tokens} =
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
      %Phoenix.LiveView.TagEngine.Parser{nodes: tokens} =
        Lavash.TagEngine.tokenize("<p>Total: {@count}</p>",
          file: "test.heex",
          line: 1,
          caller: __ENV__,
          tag_handler: Phoenix.LiveView.HTMLEngine
        )

      metadata = optimistic_metadata([:count])
      result = transform(tokens, metadata)

      assert has_display_span?(result, "count")
      # p block preserved
      assert [{:block, :tag, "p", _attrs, children, _, _}] = result
      # text preserved inside the p
      assert Enum.any?(children, &match?({:text, "Total: ", _}, &1))
    end

    test "function-wrapped expression is not auto-injected" do
      %Phoenix.LiveView.TagEngine.Parser{nodes: tokens} =
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

  # ============================================
  # Compile-time diagnostics
  # ============================================

  defp metadata_with_state(opts) do
    fields = Keyword.get(opts, :fields, [])
    optimistic = Keyword.get(opts, :optimistic, [])

    all_state =
      Enum.map(fields, fn name ->
        {name, %{name: name, type: :any, optimistic: name in optimistic, from: :ephemeral}}
      end)
      |> Map.new()

    optimistic_metadata(optimistic)
    |> Map.put(:all_state_fields, all_state)
    |> Map.put(:caller_module, __MODULE__)
    |> Map.put(:caller_file, "test.exs")
  end

  describe "diagnostics: non-optimistic bare-ref" do
    test "warns when bare {@field} references a declared-but-not-optimistic state" do
      tokens = [body_expr("@count")]
      metadata = metadata_with_state(fields: [:count], optimistic: [])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          transform(tokens, metadata)
        end)

      assert log =~ "renders as plain text"
      assert log =~ ":count is"
    end

    test "stays silent when bare {@field} is optimistic" do
      tokens = [body_expr("@count")]
      metadata = metadata_with_state(fields: [:count], optimistic: [:count])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          transform(tokens, metadata)
        end)

      refute log =~ "plain text"
    end

    test "stays silent when @ref isn't a declared state field" do
      # {@some_helper_value} is fine — could be a calculated value, an
      # imported helper, etc. Not worth warning about.
      tokens = [body_expr("@some_helper_value")]
      metadata = metadata_with_state(fields: [:count], optimistic: [:count])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          transform(tokens, metadata)
        end)

      refute log =~ "plain text"
    end

    test "stays silent for non-bare expressions" do
      tokens = [body_expr("inspect(@count)")]
      metadata = metadata_with_state(fields: [:count], optimistic: [])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          transform(tokens, metadata)
        end)

      refute log =~ "plain text"
    end
  end

  defp local_component(name, attrs) do
    m = meta(tag_name: name)
    {:self_close, :local_component, name, attrs, m}
  end

  describe "class toggle auto-injection" do
    test "class={if @bool, do: A, else: B} on optimistic boolean → data-lavash-toggle" do
      tokens = [
        tag("div", [
          expr_attr("class", ~s|if @flag, do: "on-class", else: "off-class"|)
        ])
      ]

      metadata =
        optimistic_metadata([{:flag, :boolean}])
        |> Map.put(:all_state_fields, %{
          flag: %{name: :flag, type: :boolean, optimistic: true, from: :ephemeral}
        })

      result = transform(tokens, metadata)
      [{:block, :tag, "div", attrs, _children, _, _}] = result

      assert {"data-lavash-toggle", {:string, "flag|on-class|off-class", _}, _} =
               Enum.find(attrs, &match?({"data-lavash-toggle", _, _}, &1))
    end

    test "skipped when class is a plain string" do
      tokens = [tag("div", [string_attr("class", "static")])]
      metadata = optimistic_metadata([{:flag, :boolean}])
      result = transform(tokens, metadata)
      [{:block, :tag, "div", attrs, _children, _, _}] = result
      refute Enum.any?(attrs, &match?({"data-lavash-toggle", _, _}, &1))
    end

    test "skipped when field isn't optimistic" do
      tokens = [
        tag("div", [
          expr_attr("class", ~s|if @flag, do: "a", else: "b"|)
        ])
      ]

      # No optimistic_fields — flag is declared but not optimistic
      metadata = optimistic_metadata([])
      result = transform(tokens, metadata)
      [{:block, :tag, "div", attrs, _children, _, _}] = result
      refute Enum.any?(attrs, &match?({"data-lavash-toggle", _, _}, &1))
    end

    test "skipped when class expression is more complex than a literal if-else" do
      # function call branch — leave alone
      tokens = [
        tag("div", [
          expr_attr("class", ~s|if @flag, do: my_class(@flag), else: "off"|)
        ])
      ]

      metadata = optimistic_metadata([{:flag, :boolean}])
      result = transform(tokens, metadata)
      [{:block, :tag, "div", attrs, _children, _, _}] = result
      refute Enum.any?(attrs, &match?({"data-lavash-toggle", _, _}, &1))
    end
  end

  describe "class member auto-injection" do
    test "class={if val in @list, do: A, else: B} → data-lavash-member" do
      tokens = [
        tag("div", [
          expr_attr("class", ~s|if "x" in @items, do: "selected", else: "unselected"|)
        ])
      ]

      metadata =
        optimistic_metadata([:items])
        |> Map.put(:all_state_fields, %{
          items: %{name: :items, type: {:array, :string}, optimistic: true, from: :ephemeral}
        })

      result = transform(tokens, metadata)
      [{:block, :tag, "div", attrs, _children, _, _}] = result

      assert {"data-lavash-member", {:string, "items|selected|unselected", _}, _} =
               Enum.find(attrs, &match?({"data-lavash-member", _, _}, &1))

      assert {"data-lavash-member-value", {:string, "x", _}, _} =
               Enum.find(attrs, &match?({"data-lavash-member-value", _, _}, &1))
    end

    test "skipped when field isn't optimistic" do
      tokens = [
        tag("div", [
          expr_attr("class", ~s|if "x" in @items, do: "a", else: "b"|)
        ])
      ]

      metadata = optimistic_metadata([])
      result = transform(tokens, metadata)
      [{:block, :tag, "div", attrs, _children, _, _}] = result
      refute Enum.any?(attrs, &match?({"data-lavash-member", _, _}, &1))
    end
  end

  describe "diagnostics: bind to undeclared parent" do
    test "warns when bind targets a parent field that isn't declared" do
      tokens = [
        local_component("lavash_component", [
          string_attr("module", "Child"),
          string_attr("id", "x"),
          expr_attr("bind", "[n: :missing]")
        ])
      ]

      metadata =
        metadata_with_state(fields: [:count, :other])
        |> Map.put(:context, :live_view)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          transform(tokens, metadata)
        end)

      assert log =~ ":missing is not a declared state field"
    end

    test "stays silent when bind targets a real state field" do
      tokens = [
        local_component("lavash_component", [
          string_attr("module", "Child"),
          string_attr("id", "x"),
          expr_attr("bind", "[n: :count]")
        ])
      ]

      metadata =
        metadata_with_state(fields: [:count])
        |> Map.put(:context, :live_view)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          transform(tokens, metadata)
        end)

      refute log =~ "not a declared state field"
    end
  end
end
