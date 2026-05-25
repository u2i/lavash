defmodule Lavash.Template.TokenTransformer do
  @moduledoc """
  Unified token-tree transformer for Lavash templates.

  This module implements `Lavash.TokenTransformer` to handle all compile-time
  template transformations at the tree level:

  1. **`data-lavash-*` attributes** on HTML elements (for JS hooks/optimistic updates)
  2. **`__lavash_client_bindings__`** on component calls (for binding chain propagation)
  3. **`<span data-lavash-display>` wrapping** of bare `{@field}` expressions

  ## Tree shape (LV 1.2)

  Nodes:

  - `{:block, type, name, attrs, children, open_meta, close_meta}` —
    `type` is `:tag` | `:local_component` | `:remote_component` | `:slot`
  - `{:self_close, type, name, attrs, meta}` — void/self-closing tags
  - `{:text, content, meta}`
  - `{:body_expr, code, meta}` — `{...}` inline expression
  - `{:eex, code, meta}` — `<%= ... %>` expression
  - `{:eex_block, code, clauses, meta}` — `<%= if x do %>...<% end %>`
    where each clause is `{children, end_code, meta}`
  - `{:eex_comment, content, meta}`

  Attributes (per node):

  - `{name, attr_value, meta}` where `attr_value` is
    `{:expr, code, meta}` | `{:string, content, meta}` | `nil`
  - or `{:root, {:expr, code, meta}, meta}` for `<div {@spread}>`

  ## Usage

      Lavash.TagEngine.compile_from_tokens(parsed,
        token_transformer: Lavash.Template.TokenTransformer,
        lavash_metadata: %{...}
      )
  """

  @behaviour Lavash.TokenTransformer

  @impl true
  def transform(nodes, state) when is_list(nodes) do
    metadata = state[:lavash_metadata] || %{}
    walk_nodes(nodes, metadata, state, _parent = nil)
  end

  # ---------------------------------------------------------------------------
  # Tree walker
  # ---------------------------------------------------------------------------

  # parent is either nil (top-level) or {:tag, name, attrs} describing the
  # immediately-enclosing block node. Used so display-wrapping can skip
  # children that are already inside a `<span data-lavash-display>`.

  defp walk_nodes(nodes, metadata, state, parent) do
    nodes
    |> Enum.flat_map(&walk_node(&1, metadata, state, parent))
  end

  # Returns a list of replacement nodes (usually one, sometimes more when a
  # body_expr expands to [span_open?, ...] — though with the tree shape we
  # collapse the open/close pair into a single synthesized block).

  defp walk_node({:block, :tag, name, attrs, children, open_meta, close_meta}, metadata, state, _parent) do
    {new_attrs, manual?} = transform_tag_attrs(name, attrs, open_meta, metadata)

    new_children =
      if manual? do
        # data-lavash-manual means: do not transform children either.
        children
      else
        walk_nodes(children, metadata, state, {:tag, name, new_attrs})
      end

    [{:block, :tag, name, new_attrs, new_children, open_meta, close_meta}]
  end

  defp walk_node({:block, comp_type, name, attrs, children, open_meta, close_meta}, metadata, state, _parent)
       when comp_type in [:local_component, :remote_component] do
    new_attrs = maybe_inject_component_attrs(name, attrs, open_meta, metadata, state)
    new_children = walk_nodes(children, metadata, state, nil)
    [{:block, comp_type, name, new_attrs, new_children, open_meta, close_meta}]
  end

  defp walk_node({:block, :slot, name, attrs, children, open_meta, close_meta}, metadata, state, _parent) do
    new_children = walk_nodes(children, metadata, state, nil)
    [{:block, :slot, name, attrs, new_children, open_meta, close_meta}]
  end

  defp walk_node({:self_close, :tag, name, attrs, meta}, metadata, _state, _parent) do
    {new_attrs, _manual?} = transform_tag_attrs(name, attrs, meta, metadata)
    [{:self_close, :tag, name, new_attrs, meta}]
  end

  defp walk_node({:self_close, comp_type, name, attrs, meta}, metadata, state, _parent)
       when comp_type in [:local_component, :remote_component] do
    new_attrs = maybe_inject_component_attrs(name, attrs, meta, metadata, state)
    [{:self_close, comp_type, name, new_attrs, meta}]
  end

  defp walk_node({:self_close, :slot, _name, _attrs, _meta} = node, _metadata, _state, _parent) do
    [node]
  end

  defp walk_node({:body_expr, expr, expr_meta} = node, metadata, _state, parent) do
    optimistic_fields = metadata[:optimistic_fields] || %{}
    calculations = metadata[:calculations] || %{}
    all_optimistic = Map.merge(optimistic_fields, calculations)

    case extract_optimistic_field_ref(expr, all_optimistic) do
      nil ->
        warn_if_non_optimistic_bare_ref(expr, expr_meta, metadata)
        [node]

      field_name ->
        cond do
          parent_is_display_wrapper?(parent) ->
            [node]

          # u2i/lavash#16 — Inside elements whose body text becomes their
          # form value (`<textarea>`, `<option>`, etc.) the browser sees
          # the literal `<span data-lavash-display="...">N</span>` as the
          # submitted value. The `data-lavash-bind` attribute auto-injected
          # on `<textarea>` already keeps the field in sync on the client,
          # so the span is also redundant. Leave the body_expr alone.
          parent_consumes_body_as_value?(parent) ->
            [node]

          true ->
            [wrap_body_expr_in_display_span(field_name, expr, expr_meta)]
        end
    end
  end

  defp walk_node({:eex_block, code, clauses, meta}, metadata, state, _parent) do
    new_clauses =
      Enum.map(clauses, fn {clause_nodes, end_code, clause_meta} ->
        {walk_nodes(clause_nodes, metadata, state, nil), end_code, clause_meta}
      end)

    [{:eex_block, code, new_clauses, meta}]
  end

  # Pass-through for everything else (`:text`, `:eex`, `:eex_comment`, unknown).
  defp walk_node(node, _metadata, _state, _parent), do: [node]

  # ---------------------------------------------------------------------------
  # Tag attribute transformation
  # ---------------------------------------------------------------------------

  # Returns {new_attrs, manual?} — manual? short-circuits descent into children
  # so user-managed subtrees are left untouched.
  defp transform_tag_attrs(name, attrs, meta, metadata) do
    manual? = has_attr?(attrs, "data-lavash-manual")

    if manual? do
      {attrs, true}
    else
      {maybe_inject_tag_attrs(name, attrs, meta, metadata), false}
    end
  end

  # ---------------------------------------------------------------------------
  # Display wrapping helpers
  # ---------------------------------------------------------------------------

  defp parent_is_display_wrapper?({:tag, _name, attrs}) do
    has_attr?(attrs, "data-lavash-display") or has_attr?(attrs, "data-lavash-manual")
  end

  defp parent_is_display_wrapper?(_), do: false

  # Tags whose body content is submitted as their value rather than rendered
  # as inner HTML. Wrapping `{@field}` in a span here would inject literal
  # HTML into the form payload. `<title>` is mostly defensive — bare
  # `{@field}` there is rare but the span would still corrupt the page
  # title text.
  @body_as_value_tags ~w(textarea option title)

  defp parent_consumes_body_as_value?({:tag, name, _attrs}) when name in @body_as_value_tags,
    do: true

  defp parent_consumes_body_as_value?(_), do: false

  defp wrap_body_expr_in_display_span(field_name, expr, expr_meta) do
    line = expr_meta[:line] || 1
    column = expr_meta[:column] || 1

    open_meta = %{
      line: line,
      column: column,
      tag_name: "span",
      inner_location: {line, column + 6}
    }

    close_meta = %{
      line: line,
      column: column,
      tag_name: "span",
      inner_location: {line, column}
    }

    display_attr =
      {"data-lavash-display",
       {:string, field_name, %{delimiter: ?", line: line, column: column}},
       %{line: line, column: column}}

    {:block, :tag, "span", [display_attr], [{:body_expr, expr, expr_meta}], open_meta,
     close_meta}
  end

  # Diagnostic: bare {@field} for a declared-but-non-optimistic field
  # renders as plain text — the user probably meant `optimistic: true`.
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

  @lavash_components ~w(lavash_component)

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

  defp warn_if_bind_targets_unknown(pairs, expr_meta, metadata) do
    all_state = metadata[:all_state_fields] || %{}

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

  # Pattern 6a: class={if @bool, do: A, else: B}
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

  # Pattern 6b: class={if val in @list, do: A, else: B}
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

  defp as_class_string(s) when is_binary(s), do: {:ok, s}
  defp as_class_string(nil), do: {:ok, ""}
  defp as_class_string(_), do: :error

  defp as_member_value(s) when is_binary(s), do: {:ok, s}
  defp as_member_value(a) when is_atom(a), do: {:ok, Atom.to_string(a)}
  defp as_member_value(_), do: :error

  # Pattern 7: General reactive attribute binding
  defp maybe_inject_reactive_attrs(attrs, metadata) do
    attr_derives = metadata[:attr_derives] || []

    Enum.reduce(attr_derives, attrs, fn derive, acc ->
      lavash_attr = "data-lavash-attr-#{derive.attr}"

      if has_attr?(acc, lavash_attr) do
        acc
      else
        case get_attr_value(acc, derive.attr) do
          {:expr, expr, _meta} ->
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
  defp maybe_inject_phx_target(attrs, metadata) do
    if metadata[:context] == :component and has_phx_event?(attrs) do
      add_attr_if_missing(attrs, "phx-target", {:expr, "@myself"})
    else
      attrs
    end
  end

  @phx_events ~w(phx-click phx-change phx-submit phx-blur phx-focus phx-keydown phx-keyup phx-window-keydown phx-window-keyup)
  defp has_phx_event?(attrs) do
    Enum.any?(attrs, fn
      {name, _, _} -> name in @phx_events
      _ -> false
    end)
  end

  # ===========================================================================
  # Attribute Helpers
  # ===========================================================================

  # Attrs may include `{:root, value, meta}` for `<div {@spread}>` — those
  # spread attrs have no string name and are pass-through for all our checks.
  defp has_attr?(attrs, name) do
    Enum.any?(attrs, fn
      {^name, _value, _meta} -> true
      _ -> false
    end)
  end

  defp get_attr_value(attrs, name) do
    case Enum.find(attrs, fn
           {^name, _value, _meta} -> true
           _ -> false
         end) do
      {_name, value, _meta} -> value
      nil -> nil
    end
  end

  defp reject_attr(attrs, name) do
    Enum.reject(attrs, fn
      {^name, _value, _meta} -> true
      _ -> false
    end)
  end

  defp add_attr_if_missing(attrs, name, value) do
    if has_attr?(attrs, name) do
      attrs
    else
      attr_meta = %{line: 1, column: 1}
      value_with_meta = wrap_value_with_meta(value, attr_meta)
      attrs ++ [{name, value_with_meta, attr_meta}]
    end
  end

  defp wrap_value_with_meta({:string, value}, _meta) do
    {:string, value, %{delimiter: ?", line: 1, column: 1}}
  end

  defp wrap_value_with_meta({:expr, value}, meta), do: {:expr, value, meta}
  defp wrap_value_with_meta(value, _meta), do: value

  # ===========================================================================
  # Parsing Helpers
  # ===========================================================================

  defp parse_form_field_expr(expr) do
    case Regex.run(~r/@(\w+)\[:(\w+)\]\.name/, expr) do
      [_, form, field] -> {:ok, String.to_atom(form), String.to_atom(field)}
      nil -> :error
    end
  end

  defp parse_form_field_string(name) do
    case Regex.run(~r/^(\w+)\[(\w+)\]$/, name) do
      [_, form, field] -> {:ok, form, field}
      nil -> :error
    end
  end

  defp parse_form_field_access_expr(expr) do
    case Regex.run(~r/@(\w+)\[:(\w+)\]$/, String.trim(expr)) do
      [_, form, field] -> {:ok, String.to_atom(form), String.to_atom(field)}
      nil -> :error
    end
  end

  defp parse_negated_field(expr) do
    case Regex.run(~r/^not\s+@(\w+)$/, String.trim(expr)) do
      [_, field] -> {:ok, field}
      nil -> :error
    end
  end

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
end
