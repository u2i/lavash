defmodule Lavash.Template.TokenTransformer do
  @moduledoc """
  Unified token transformer for Lavash templates.

  This module implements `Lavash.TokenTransformer` to handle all compile-time
  template transformations at the token level:

  1. **`data-lavash-*` attributes** on HTML elements (for JS hooks/optimistic updates)
  2. **`__lavash_client_bindings__`** on component calls (for binding chain propagation)

  ## Token Structure

  Tokens from Phoenix.LiveView.Tokenizer:

  - `{:tag, name, attrs, meta}` - HTML elements
  - `{:remote_component, name, attrs, meta}` - `<Foo.bar>` components
  - `{:local_component, name, attrs, meta}` - `<.foo>` components
  - `{:slot, name, attrs, meta}` - `<:header>` slots
  - `{:close, type, name, meta}` - Closing tags
  - `{:text, content, meta}` - Text content
  - `{:expr, marker, content}` - `{...}` expressions

  Attributes are `{name, value, attr_meta}` where value is:
  - `{:string, content, str_meta}` - `"literal"`
  - `{:expr, content, expr_meta}` - `{@foo}`
  - `nil` - Boolean attribute

  ## Usage

  Pass this module as `:token_transformer` to `Lavash.TagEngine`:

      EEx.compile_string(source,
        engine: Lavash.TagEngine,
        tag_handler: Phoenix.LiveView.HTMLEngine,
        token_transformer: Lavash.Template.TokenTransformer,
        lavash_metadata: %{...}
      )
  """

  @behaviour Lavash.TokenTransformer

  @impl true
  def transform(tokens, state) do
    metadata = state[:lavash_metadata] || %{}

    # Note: subtree derive injection (data-lavash-html) is handled upstream
    # by AnalyzeTemplate, which injects directly onto pre-tokenized tokens.
    # The token transformer handles all other injections.
    tokens
    |> Enum.map(&transform_token(&1, metadata, state))
    |> maybe_inject_display_attrs(metadata)
  end

  # Transform individual tokens
  defp transform_token({:tag, name, attrs, meta}, metadata, _state) do
    if has_attr?(attrs, "data-lavash-manual") do
      {:tag, name, attrs, meta}
    else
      new_attrs = maybe_inject_tag_attrs(name, attrs, meta, metadata)
      {:tag, name, new_attrs, meta}
    end
  end

  defp transform_token({:remote_component, name, attrs, meta}, metadata, state) do
    new_attrs = maybe_inject_component_attrs(name, attrs, meta, metadata, state)
    {:remote_component, name, new_attrs, meta}
  end

  defp transform_token({:local_component, name, attrs, meta}, metadata, state) do
    new_attrs = maybe_inject_component_attrs(name, attrs, meta, metadata, state)
    {:local_component, name, new_attrs, meta}
  end

  defp transform_token(token, _metadata, _state), do: token

  # ===========================================================================
  # Display injection — auto-wrap {@field} in <span data-lavash-display>
  # ===========================================================================

  # Scans for {:body_expr, "@field", meta} tokens referencing optimistic fields.
  # Wraps each in <span data-lavash-display="field">...</span> so the JS hook
  # can update the value optimistically without a server round-trip.
  #
  # This fires for bare field references ({@count}) anywhere in the template —
  # the field doesn't need to be the sole child of a tag. Mixed content like
  # "Total: {@count}" produces "Total: <span data-lavash-display="count">5</span>".
  #
  # Does NOT fire for:
  # - Function calls: {inspect(@count)} — not a bare @field
  # - Already-wrapped: elements with data-lavash-display or data-lavash-manual
  # - Attribute values: value={@count} — handled by other patterns
  defp maybe_inject_display_attrs(tokens, metadata) do
    optimistic_fields = metadata[:optimistic_fields] || %{}
    calculations = metadata[:calculations] || %{}
    all_optimistic = Map.merge(optimistic_fields, calculations)

    # Always walk for diagnostics, even when there's nothing to wrap — a
    # declared-but-non-optimistic bare-ref is still worth warning about.
    wrap_display_exprs(tokens, all_optimistic, metadata, [])
  end

  defp wrap_display_exprs([], _fields, _metadata, acc), do: Enum.reverse(acc)

  # `inside_display_element?/1` walks the accumulator to decide whether a
  # body_expr is already inside a wrapper, so tags themselves just pass through.
  defp wrap_display_exprs(
         [{:tag, _name, _attrs, _meta} = tag | rest],
         fields,
         metadata,
         acc
       ) do
    wrap_display_exprs(rest, fields, metadata, [tag | acc])
  end

  defp wrap_display_exprs(
         [{:body_expr, expr, expr_meta} | rest],
         fields,
         metadata,
         acc
       ) do
    case extract_optimistic_field_ref(expr, fields) do
      nil ->
        warn_if_non_optimistic_bare_ref(expr, expr_meta, metadata)
        wrap_display_exprs(rest, fields, metadata, [{:body_expr, expr, expr_meta} | acc])

      field_name ->
        # Check if we're already inside an element with data-lavash-display
        if inside_display_element?(acc) do
          wrap_display_exprs(rest, fields, metadata, [{:body_expr, expr, expr_meta} | acc])
        else
          # Wrap: <span data-lavash-display="field">{@field}</span>
          span_meta = %{
            line: expr_meta[:line] || 1,
            column: expr_meta[:column] || 1,
            tag_name: "span",
            inner_location: {expr_meta[:line] || 1, (expr_meta[:column] || 1) + 6}
          }

          display_attr =
            {"data-lavash-display", {:string, field_name, %{delimiter: ?", line: 1, column: 1}},
             %{line: 1, column: 1}}

          close_meta = %{
            line: expr_meta[:line] || 1,
            column: expr_meta[:column] || 1,
            tag_name: "span",
            inner_location: {expr_meta[:line] || 1, expr_meta[:column] || 1}
          }

          tokens = [
            {:close, :tag, "span", close_meta},
            {:body_expr, expr, expr_meta},
            {:tag, "span", [display_attr], span_meta}
          ]

          wrap_display_exprs(rest, fields, metadata, tokens ++ acc)
        end
    end
  end

  defp wrap_display_exprs([token | rest], fields, metadata, acc) do
    wrap_display_exprs(rest, fields, metadata, [token | acc])
  end

  # Diagnostic: if the user wrote a bare {@field} where :field is a declared
  # state field but isn't optimistic, the template renders as plain text — the
  # JS hook won't pick it up. Most likely a missing `optimistic: true`.
  # Silent for non-bare expressions and for fields we don't know about.
  defp warn_if_non_optimistic_bare_ref(expr, expr_meta, metadata) do
    all_state = metadata[:all_state_fields] || %{}
    optimistic = metadata[:optimistic_fields] || %{}

    with [_, field_str] <- Regex.run(~r/^@(\w+)$/, String.trim(expr)),
         field_atom = safe_existing_atom(field_str),
         true <- not is_nil(field_atom),
         true <- is_map_key(all_state, field_atom),
         false <- is_map_key(optimistic, field_atom) do
      require Logger

      Logger.warning(
        "[lavash] {@#{field_str}} in #{metadata[:caller_file] || "template"}:" <>
          "#{expr_meta[:line] || "?"} renders as plain text — :#{field_str} is " <>
          "declared but not optimistic. Add `optimistic: true` to enable " <>
          "client-side updates."
      )
    end

    :ok
  end

  defp safe_existing_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  # Check if the accumulator's most recent unclosed tag has data-lavash-display.
  # This prevents double-wrapping when someone manually adds the attribute.
  #
  # The accumulator is in reverse order — head is the most recent token. We
  # walk it counting close/open pairs. Tokens with `closing: :void` or
  # `closing: :self` in meta (e.g. `<input>`, `<br/>`) never have a matching
  # `:close` token, so they must not consume an open-slot when we're at
  # depth 0 — skip them.
  defp inside_display_element?(acc) do
    Enum.reduce_while(acc, 0, fn
      {:close, :tag, _name, _meta}, depth ->
        {:cont, depth + 1}

      {:tag, _name, _attrs, %{closing: closing}}, depth when closing in [:void, :self] ->
        {:cont, depth}

      {:tag, _name, attrs, _meta}, 0 ->
        if has_attr?(attrs, "data-lavash-display") || has_attr?(attrs, "data-lavash-manual") do
          {:halt, true}
        else
          {:halt, false}
        end

      {:tag, _name, _attrs, _meta}, depth ->
        {:cont, depth - 1}

      _, depth ->
        {:cont, depth}
    end)
    |> case do
      true -> true
      _ -> false
    end
  end

  # Extract field name from expression like "@count" (bare field reference only)
  defp extract_optimistic_field_ref(expr, fields) do
    trimmed = String.trim(expr)

    case Regex.run(~r/^@(\w+)$/, trimmed) do
      [_, field_str] ->
        field_atom = String.to_existing_atom(field_str)
        if is_map_key(fields, field_atom), do: field_str, else: nil

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  # ===========================================================================
  # Component Transformations (__lavash_client_bindings__)
  # ===========================================================================

  # Lavash component names that should receive __lavash_client_bindings__
  @lavash_components ~w(lavash_component)

  # Two compile-time injections on <.lavash_component> calls inside Lavash
  # templates:
  #
  # 1. `__lavash_client_bindings__={@__lavash_client_bindings__}` — only in
  #    component context, propagates the resolved client-binding chain so a
  #    grandchild can resolve its binding back to the root LiveView field.
  #
  # 2. For each `{child_field, parent_field}` pair in the `bind=[...]`
  #    attribute, inject `child_field={@parent_field}` so the child's
  #    `update/2` sees the parent's current value under the local name. Fires
  #    in both :live_view and :component contexts because either kind of
  #    template can host a <.lavash_component>. Without this injection, bind
  #    is effectively write-only — see u2i/lavash#10.
  defp maybe_inject_component_attrs(name, attrs, meta, metadata, _state) do
    if name in @lavash_components do
      attrs
      |> maybe_inject_client_bindings(meta, metadata[:context])
      |> maybe_inject_bound_field_values(meta, metadata)
    else
      attrs
    end
  end

  defp maybe_inject_client_bindings(attrs, meta, :component) do
    if has_attr?(attrs, "__lavash_client_bindings__") do
      attrs
    else
      attrs ++
        [
          {"__lavash_client_bindings__", {:expr, "@__lavash_client_bindings__", meta}, meta}
        ]
    end
  end

  defp maybe_inject_client_bindings(attrs, _meta, _context), do: attrs

  defp maybe_inject_bound_field_values(attrs, meta, metadata) do
    case get_attr_value(attrs, "bind") do
      {:expr, source, expr_meta} ->
        case parse_bind_pairs(source) do
          {:ok, pairs} ->
            warn_if_bind_targets_unknown(pairs, expr_meta, metadata)

            Enum.reduce(pairs, attrs, fn {child_field, parent_field}, acc ->
              child_attr_name = Atom.to_string(child_field)

              if has_attr?(acc, child_attr_name) do
                acc
              else
                acc ++
                  [
                    {child_attr_name, {:expr, "@#{parent_field}", meta}, meta}
                  ]
              end
            end)

          :error ->
            attrs
        end

      _ ->
        attrs
    end
  end

  # Diagnostic: `bind={[child: :parent]}` where :parent isn't declared on the
  # host module would silently produce a write-only binding (parent's value
  # never flows down into the child because there is no such field).
  defp warn_if_bind_targets_unknown(pairs, expr_meta, metadata) do
    all_state = metadata[:all_state_fields] || %{}

    # Empty all_state means we're being called from a context that didn't
    # provide it (older callers / tests). Skip to avoid false positives.
    if map_size(all_state) > 0 do
      for {child, parent} <- pairs, not is_map_key(all_state, parent) do
        require Logger

        Logger.warning(
          "[lavash] bind=#{inspect([{child, parent}])} in " <>
            "#{metadata[:caller_file] || "template"}:#{expr_meta[:line] || "?"} " <>
            "— :#{parent} is not a declared state field on " <>
            "#{inspect(metadata[:caller_module])}. The child won't receive " <>
            "parent updates."
        )
      end
    end

    :ok
  end

  # Best-effort parser for `bind={[child: :parent, ...]}` source strings.
  # We only handle the keyword-list literal shape because that's the shape
  # the helper documents — anything more dynamic is up to the user to wire
  # the values manually.
  defp parse_bind_pairs(source) do
    case Code.string_to_quoted(source) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, fn
             {child, parent} when is_atom(child) and is_atom(parent) -> true
             _ -> false
           end) do
          {:ok, list}
        else
          :error
        end

      _ ->
        :error
    end
  end

  # ===========================================================================
  # Tag Transformations (data-lavash-*)
  # ===========================================================================

  defp maybe_inject_tag_attrs(name, attrs, _meta, metadata) do
    attrs
    |> maybe_inject_form_input(name, metadata)
    |> maybe_inject_state_binding(name, metadata)
    |> maybe_inject_visibility(metadata)
    |> maybe_inject_enabled(metadata)
    |> maybe_inject_class_toggle(metadata)
    |> maybe_inject_class_member(metadata)
    |> maybe_inject_reactive_attrs(metadata)
    |> maybe_inject_phx_target(metadata)
  end

  # Pattern 1: Form inputs
  # Supports two patterns:
  # a) Explicit: name={@form[:field].name} - injects data-lavash-* attributes
  # b) Shorthand: field={@form[:field]} - injects name, value, and all data-lavash-*
  defp maybe_inject_form_input(attrs, name, metadata)
       when name in ["input", "textarea", "select"] do
    forms = metadata[:forms] || %{}

    case get_attr_value(attrs, "field") do
      {:expr, expr, _meta} ->
        case parse_form_field_access_expr(expr) do
          {:ok, form, field} ->
            if is_map_key(forms, form) do
              inject_full_form_attrs(attrs, form, field)
            else
              maybe_inject_form_input_explicit(attrs, metadata)
            end

          _ ->
            maybe_inject_form_input_explicit(attrs, metadata)
        end

      _ ->
        maybe_inject_form_input_explicit(attrs, metadata)
    end
  end

  defp maybe_inject_form_input(attrs, _name, _metadata), do: attrs

  defp maybe_inject_form_input_explicit(attrs, metadata) do
    forms = metadata[:forms] || %{}

    if has_attr?(attrs, "data-lavash-bind") do
      attrs
    else
      case get_attr_value(attrs, "name") do
        {:expr, expr, _meta} ->
          case parse_form_field_expr(expr) do
            {:ok, form, field} ->
              if is_map_key(forms, form) do
                inject_form_attrs(attrs, form, field)
              else
                attrs
              end

            _ ->
              attrs
          end

        {:string, name_value, _meta} ->
          case parse_form_field_string(name_value) do
            {:ok, form_str, field_str} ->
              form = String.to_atom(form_str)

              if is_map_key(forms, form) do
                inject_form_attrs(attrs, form, String.to_atom(field_str))
              else
                attrs
              end

            _ ->
              attrs
          end

        _ ->
          attrs
      end
    end
  end

  defp inject_full_form_attrs(attrs, form, field) do
    form_str = to_string(form)
    field_str = to_string(field)

    attrs
    |> reject_attr("field")
    |> add_attr_if_missing("name", {:expr, "@#{form_str}[:#{field_str}].name"})
    |> add_attr_if_missing("value", {:expr, "@#{form_str}[:#{field_str}].value || \"\""})
    |> add_attr_if_missing("data-lavash-bind", {:string, "#{form_str}_params.#{field_str}"})
    |> add_attr_if_missing("data-lavash-form", {:string, form_str})
    |> add_attr_if_missing("data-lavash-field", {:string, field_str})
    |> add_attr_if_missing("data-lavash-valid", {:string, "#{form_str}_#{field_str}_valid"})
  end

  defp inject_form_attrs(attrs, form, field) do
    form_str = to_string(form)
    field_str = to_string(field)

    attrs
    |> add_attr_if_missing("data-lavash-bind", {:string, "#{form_str}_params.#{field_str}"})
    |> add_attr_if_missing("data-lavash-form", {:string, form_str})
    |> add_attr_if_missing("data-lavash-field", {:string, field_str})
    |> add_attr_if_missing("data-lavash-valid", {:string, "#{form_str}_#{field_str}_valid"})
  end

  # Pattern 2: State bindings (value={@field} on inputs)
  defp maybe_inject_state_binding(attrs, name, metadata)
       when name in ["input", "textarea", "select"] do
    if has_attr?(attrs, "data-lavash-bind") do
      attrs
    else
      case get_attr_value(attrs, "value") do
        {:expr, "@" <> field_name, _meta} ->
          field_atom = String.to_atom(field_name)

          if is_map_key(metadata[:optimistic_fields] || %{}, field_atom) do
            add_attr_if_missing(attrs, "data-lavash-bind", {:string, field_name})
          else
            attrs
          end

        _ ->
          attrs
      end
    end
  end

  defp maybe_inject_state_binding(attrs, _name, _metadata), do: attrs

  # Pattern 3: Conditional visibility (:if={@bool_field})
  defp maybe_inject_visibility(attrs, metadata) do
    if has_attr?(attrs, "data-lavash-visible") do
      attrs
    else
      case get_attr_value(attrs, ":if") do
        {:expr, "@" <> field_name, _meta} ->
          field_atom = String.to_atom(field_name)

          if optimistic_boolean?(field_atom, metadata) do
            add_attr_if_missing(attrs, "data-lavash-visible", {:string, field_name})
          else
            attrs
          end

        _ ->
          attrs
      end
    end
  end

  # Pattern 5: Enabled/disabled state (disabled={not @field})
  defp maybe_inject_enabled(attrs, metadata) do
    if has_attr?(attrs, "data-lavash-enabled") do
      attrs
    else
      case get_attr_value(attrs, "disabled") do
        {:expr, expr, _meta} ->
          case parse_negated_field(expr) do
            {:ok, field_name} ->
              field_atom = String.to_atom(field_name)

              if optimistic_boolean?(field_atom, metadata) do
                add_attr_if_missing(attrs, "data-lavash-enabled", {:string, field_name})
              else
                attrs
              end

            :error ->
              attrs
          end

        _ ->
          attrs
      end
    end
  end

  # Pattern 6a: class={if @bool, do: A, else: B} on an optimistic boolean
  # → inject data-lavash-toggle so the JS hook keeps the class set in sync
  # with the field without the user typing the directive by hand.
  defp maybe_inject_class_toggle(attrs, metadata) do
    if has_attr?(attrs, "data-lavash-toggle") do
      attrs
    else
      with {:expr, expr, _meta} <- get_attr_value(attrs, "class"),
           {:ok, field_name, true_str, false_str} <- parse_boolean_class_if(expr),
           field_atom = safe_existing_atom(field_name),
           true <- not is_nil(field_atom),
           true <- optimistic_boolean?(field_atom, metadata) do
        value = "#{field_name}|#{true_str}|#{false_str}"
        add_attr_if_missing(attrs, "data-lavash-toggle", {:string, value})
      else
        _ -> attrs
      end
    end
  end

  # Pattern 6b: class={if val in @list, do: A, else: B} on an optimistic
  # array → inject data-lavash-member + data-lavash-member-value so the JS
  # hook keeps the chip-selection class set in sync.
  defp maybe_inject_class_member(attrs, metadata) do
    if has_attr?(attrs, "data-lavash-member") do
      attrs
    else
      with {:expr, expr, _meta} <- get_attr_value(attrs, "class"),
           {:ok, value_str, field_name, true_str, false_str} <-
             parse_membership_class_if(expr),
           field_atom = safe_existing_atom(field_name),
           true <- not is_nil(field_atom),
           true <- is_map_key(metadata[:optimistic_fields] || %{}, field_atom) do
        directive = "#{field_name}|#{true_str}|#{false_str}"

        attrs
        |> add_attr_if_missing("data-lavash-member", {:string, directive})
        |> add_attr_if_missing("data-lavash-member-value", {:string, value_str})
      else
        _ -> attrs
      end
    end
  end

  # Parse `if @field, do: "...", else: "..."` (only literal-string branches).
  defp parse_boolean_class_if(source) do
    case Code.string_to_quoted(source) do
      {:ok,
       {:if, _,
        [
          {:@, _, [{field, _, ctx}]},
          [do: true_branch, else: false_branch]
        ]}}
      when is_atom(field) and is_atom(ctx) ->
        with {:ok, t} <- as_class_string(true_branch),
             {:ok, f} <- as_class_string(false_branch) do
          {:ok, Atom.to_string(field), t, f}
        end

      _ ->
        :error
    end
  end

  # Parse `if value in @field, do: "...", else: "..."` (literal value, literal classes).
  defp parse_membership_class_if(source) do
    case Code.string_to_quoted(source) do
      {:ok,
       {:if, _,
        [
          {:in, _, [value_ast, {:@, _, [{field, _, ctx}]}]},
          [do: true_branch, else: false_branch]
        ]}}
      when is_atom(field) and is_atom(ctx) ->
        with {:ok, val} <- as_member_value(value_ast),
             {:ok, t} <- as_class_string(true_branch),
             {:ok, f} <- as_class_string(false_branch) do
          {:ok, val, Atom.to_string(field), t, f}
        end

      _ ->
        :error
    end
  end

  # The branch of the if needs to be a literal string (or nil, which we
  # encode as empty string). Other shapes (function calls, list joins)
  # mean the user is doing something more complex than a class flip; we
  # leave it alone.
  defp as_class_string(s) when is_binary(s), do: {:ok, s}
  defp as_class_string(nil), do: {:ok, ""}
  defp as_class_string(_), do: :error

  # The membership-value can be a literal string or a bare atom (then
  # converted to string). We don't support runtime exprs — those would
  # need to be passed dynamically and break the static directive shape.
  defp as_member_value(s) when is_binary(s), do: {:ok, s}
  defp as_member_value(a) when is_atom(a), do: {:ok, Atom.to_string(a)}
  defp as_member_value(_), do: :error

  # Pattern 7: General reactive attribute binding
  # Looks up pre-computed attr derives (from AnalyzeTemplate transformer,
  # persisted in DSL state and passed via sigil metadata) and injects
  # data-lavash-attr-* annotations on matching elements.
  # Only injects on elements whose attribute is an EXPRESSION referencing the derive's deps.
  defp maybe_inject_reactive_attrs(attrs, metadata) do
    attr_derives = metadata[:attr_derives] || []

    Enum.reduce(attr_derives, attrs, fn derive, acc ->
      lavash_attr = "data-lavash-attr-#{derive.attr}"

      if has_attr?(acc, lavash_attr) do
        acc
      else
        # Only inject if this element has an expression attribute matching the derive's deps
        case get_attr_value(acc, derive.attr) do
          {:expr, expr, _meta} ->
            # Check if the expression references any of the derive's deps
            deps = derive.deps
            has_dep = Enum.any?(deps, fn dep -> String.contains?(expr, "@#{dep}") end)

            if has_dep do
              add_attr_if_missing(acc, lavash_attr, {:string, derive.name})
            else
              acc
            end

          _ ->
            acc
        end
      end
    end)
  end

  # Pattern 6: Auto-inject phx-target={@myself} in component context
  # In LiveComponents, phx-click events need phx-target to route to the
  # component's handle_event instead of the parent LiveView.
  defp maybe_inject_phx_target(attrs, metadata) do
    if metadata[:context] == :component and has_phx_event?(attrs) do
      add_attr_if_missing(attrs, "phx-target", {:expr, "@myself"})
    else
      attrs
    end
  end

  @phx_events ~w(phx-click phx-change phx-submit phx-blur phx-focus phx-keydown phx-keyup phx-window-keydown phx-window-keyup)
  defp has_phx_event?(attrs), do: Enum.any?(attrs, fn {name, _, _} -> name in @phx_events end)

  # ===========================================================================
  # Attribute Helpers
  # ===========================================================================

  defp has_attr?(attrs, name) do
    Enum.any?(attrs, fn {attr_name, _value, _meta} -> attr_name == name end)
  end

  defp get_attr_value(attrs, name) do
    case Enum.find(attrs, fn {attr_name, _value, _meta} -> attr_name == name end) do
      {_name, value, _meta} -> value
      nil -> nil
    end
  end

  defp reject_attr(attrs, name) do
    Enum.reject(attrs, fn {attr_name, _value, _meta} -> attr_name == name end)
  end

  defp add_attr_if_missing(attrs, name, value) do
    if has_attr?(attrs, name) do
      attrs
    else
      # Use meta with required fields for injected attributes
      attr_meta = %{line: 1, column: 1}
      value_with_meta = wrap_value_with_meta(value, attr_meta)
      attrs ++ [{name, value_with_meta, attr_meta}]
    end
  end

  # String values need delimiter in meta for TagEngine's handle_tag_attrs
  defp wrap_value_with_meta({:string, value}, _meta) do
    {:string, value, %{delimiter: ?", line: 1, column: 1}}
  end

  defp wrap_value_with_meta({:expr, value}, meta), do: {:expr, value, meta}
  defp wrap_value_with_meta(value, _meta), do: value

  # ===========================================================================
  # Parsing Helpers
  # ===========================================================================

  # Parse @form[:field].name pattern
  defp parse_form_field_expr(expr) do
    case Regex.run(~r/@(\w+)\[:(\w+)\]\.name/, expr) do
      [_, form, field] -> {:ok, String.to_atom(form), String.to_atom(field)}
      nil -> :error
    end
  end

  # Parse form[field] string pattern
  defp parse_form_field_string(name) do
    case Regex.run(~r/^(\w+)\[(\w+)\]$/, name) do
      [_, form, field] -> {:ok, form, field}
      nil -> :error
    end
  end

  # Parse @form[:field] pattern (shorthand)
  defp parse_form_field_access_expr(expr) do
    case Regex.run(~r/@(\w+)\[:(\w+)\]$/, String.trim(expr)) do
      [_, form, field] -> {:ok, String.to_atom(form), String.to_atom(field)}
      nil -> :error
    end
  end

  # Parse "not @field" pattern
  defp parse_negated_field(expr) do
    case Regex.run(~r/^not\s+@(\w+)$/, String.trim(expr)) do
      [_, field] -> {:ok, field}
      nil -> :error
    end
  end

  # Check if field is an optimistic boolean
  defp optimistic_boolean?(field_atom, metadata) do
    cond do
      is_map_key(metadata[:optimistic_fields] || %{}, field_atom) ->
        field = metadata[:optimistic_fields][field_atom]
        field.type == :boolean

      is_map_key(metadata[:calculations] || %{}, field_atom) ->
        true

      true ->
        false
    end
  end

  # ===========================================================================
  # Metadata Builder
  # ===========================================================================
end
