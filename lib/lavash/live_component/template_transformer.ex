defmodule Lavash.LiveComponent.TemplateTransformer do
  @moduledoc """
  Transforms LiveComponent templates by injecting data-synced-* attributes.

  This module takes a template with natural syntax like:
    <button l-action="toggle" class={@button_class}>

  And transforms it to:
    <button data-synced-action="toggle" data-synced-field="value" data-synced-class="button_class" class={@button_class}>

  Transformation rules:
  - `l-action="action_name"` → `data-synced-action="action_name" data-synced-field="<field>"`
  - `class={@calc_name}` where calc_name is a calculate → add `data-synced-class="calc_name"`
  - `{@calc_name}` in text content where calc_name is a calculate → add `data-synced-text="calc_name"` to parent
  """

  @doc """
  Transforms a template source, injecting data-synced-* attributes.

  ## Parameters
  - `template_source` - The raw HEEx template string
  - `calculations` - List of calculation tuples: `{name, source, ast, deps}`
  - `actions` - List of action maps: `%{name: atom, field: atom, ...}`
  - `synced_fields` - List of synced field structs

  ## Returns
  The transformed template source string.
  """
  def transform(template_source, calculations, actions, _synced_fields) do
    # Build lookup sets for quick detection
    calc_names = MapSet.new(calculations, fn {name, _, _, _} -> name end)
    action_map = Map.new(actions, fn %{name: name, field: field} -> {name, field} end)

    template_source
    |> Lavash.Template.tokenize()
    |> Lavash.Template.parse()
    |> transform_tree(calc_names, action_map)
    |> tree_to_heex()
  end

  # Transform tree recursively
  defp transform_tree(nodes, calc_names, action_map) when is_list(nodes) do
    Enum.map(nodes, &transform_node(&1, calc_names, action_map))
  end

  defp transform_node({:element, tag, attrs, children, meta}, calc_names, action_map) do
    # Transform attributes
    {transformed_attrs, new_attrs} = transform_attrs(attrs, calc_names, action_map)

    # Check for text expressions in children that reference calculations
    {transformed_children, child_new_attrs} = transform_children_for_text(children, calc_names, action_map)

    # Merge any data-synced-text attributes from children
    all_new_attrs = new_attrs ++ child_new_attrs

    # Recurse into children
    transformed_children = transform_tree(transformed_children, calc_names, action_map)

    {:element, tag, transformed_attrs ++ all_new_attrs, transformed_children, meta}
  end

  defp transform_node({:text, content}, _calc_names, _action_map) do
    {:text, content}
  end

  defp transform_node({:expr, code, meta}, _calc_names, _action_map) do
    {:expr, code, meta}
  end

  defp transform_node(other, _calc_names, _action_map), do: other

  # Transform attributes, returning {transformed_attrs, new_attrs_to_add}
  defp transform_attrs(attrs, calc_names, action_map) do
    {transformed, new_attrs} =
      Enum.reduce(attrs, {[], []}, fn attr, {acc_attrs, acc_new} ->
        case attr do
          # l-action="action_name" → data-synced-action + data-synced-field
          {"l-action", {:string, action_name}} ->
            action_atom = String.to_existing_atom(action_name)
            case Map.get(action_map, action_atom) do
              nil ->
                # Action not found, keep original
                {[attr | acc_attrs], acc_new}
              field ->
                # Replace with data-synced-action and add data-synced-field
                new = [
                  {"data-synced-action", {:string, action_name}},
                  {"data-synced-field", {:string, to_string(field)}}
                ]
                {acc_attrs, new ++ acc_new}
            end

          {"l-action", {:expr, action_expr, expr_meta}} ->
            # Dynamic action - try to extract the action name
            case extract_simple_var(action_expr) do
              nil ->
                {[attr | acc_attrs], acc_new}
              _var_name ->
                # For dynamic actions, we keep the expression
                new = [
                  {"data-synced-action", {:expr, action_expr, expr_meta}}
                ]
                {acc_attrs, new ++ acc_new}
            end

          # class={@calc_name} → add data-synced-class="calc_name"
          {"class", {:expr, code, _expr_meta}} = class_attr ->
            case extract_calc_reference(code, calc_names) do
              nil ->
                {[class_attr | acc_attrs], acc_new}
              calc_name ->
                new = [{"data-synced-class", {:string, to_string(calc_name)}}]
                {[class_attr | acc_attrs], new ++ acc_new}
            end

          # Pass through other attributes
          other ->
            {[other | acc_attrs], acc_new}
        end
      end)

    {Enum.reverse(transformed), new_attrs}
  end

  # Check if children have expression nodes that reference calculations
  # If so, we need to add data-synced-text to the parent element
  defp transform_children_for_text(children, calc_names, _action_map) do
    # Look for expressions that are direct calculation references
    text_attrs =
      children
      |> Enum.filter(fn
        {:expr, code, _meta} ->
          case extract_calc_reference(code, calc_names) do
            nil -> false
            _ -> true
          end
        _ -> false
      end)
      |> Enum.map(fn {:expr, code, _meta} ->
        calc_name = extract_calc_reference(code, calc_names)
        {"data-synced-text", {:string, to_string(calc_name)}}
      end)
      |> Enum.take(1)  # Only take first one for now

    {children, text_attrs}
  end

  # Extract a simple @var reference from an expression
  defp extract_calc_reference(code, calc_names) do
    case Code.string_to_quoted(code) do
      {:ok, {:@, _, [{var_name, _, _}]}} when is_atom(var_name) ->
        if MapSet.member?(calc_names, var_name), do: var_name, else: nil
      _ ->
        nil
    end
  end

  # Extract a simple variable name from expression
  defp extract_simple_var(code) do
    case Code.string_to_quoted(code) do
      {:ok, {var_name, _, _}} when is_atom(var_name) -> var_name
      _ -> nil
    end
  end

  # Convert transformed tree back to HEEx source
  defp tree_to_heex(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&node_to_heex/1)
    |> Enum.join("")
  end

  defp node_to_heex({:element, tag, attrs, children, meta}) do
    attrs_str = attrs_to_heex(attrs)

    if children == [] and meta[:closing] == :self do
      "<#{tag}#{attrs_str} />"
    else
      children_str = tree_to_heex(children)
      "<#{tag}#{attrs_str}>#{children_str}</#{tag}>"
    end
  end

  defp node_to_heex({:text, content}), do: content

  defp node_to_heex({:expr, code, _meta}), do: "{#{code}}"

  defp node_to_heex(_), do: ""

  # Convert attributes list to HEEx string
  defp attrs_to_heex(attrs) do
    attrs
    |> Enum.map(&attr_to_heex/1)
    |> Enum.join("")
  end

  defp attr_to_heex({name, {:string, value}}) do
    # Escape quotes in value
    escaped = String.replace(value, "\"", "&quot;")
    " #{name}=\"#{escaped}\""
  end

  defp attr_to_heex({name, {:expr, code, _meta}}) do
    " #{name}={#{code}}"
  end

  defp attr_to_heex({name, {:boolean, true}}) do
    " #{name}"
  end

  defp attr_to_heex({_name, {:boolean, false}}) do
    ""
  end

  defp attr_to_heex(_), do: ""
end
