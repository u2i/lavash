defmodule Lavash.LiveView.Components do
  @moduledoc """
  Lavash form components with built-in optimistic updates.

  These components combine Phoenix form patterns with Lavash's optimistic
  validation system. Import them into your LiveView or component:

      import Lavash.LiveView.Components

  ## Input Component

  The `input/1` component renders a complete form field with:
  - Floating label (default) or traditional label-above-input
  - Optimistic validation styling (error classes when invalid)
  - Error messages with `data-lavash-errors`

  ### Basic Usage

      <.input field={@payment[:card_number]} label="Card number" />

  ### With Custom Validation Field

  When using `extend_errors` or custom validation logic:

      <.input field={@payment[:cvv]} label="CVV"
              valid={@cvv_valid} valid_field="cvv_valid"
              errors={@payment_cvv_errors} />

  ### All Options

      <.input
        field={@form[:field]}           # Required: Phoenix.HTML.FormField
        label="Field Label"             # Required: Label text
        type="text"                     # Input type (default: "text")
        floating={true}                 # Floating label (default) or label above input
        valid={@field_valid}            # Validation state boolean
        valid_field="custom_valid"      # Custom valid field name for JS
        errors={@field_errors}          # Error list
        placeholder="Enter value"       # Input placeholder
        # ... any other HTML attributes passed through
      />

  ### Non-floating Label

  For traditional label-above-input layout:

      <.input field={@form[:email]} label="Email" floating={false} />
  """

  use Phoenix.Component
  import Lavash.LiveView.Helpers, only: [field_errors: 1]

  @doc """
  Renders a form input with floating label and optimistic validation.

  ## Examples

      <.input field={@payment[:card_number]} label="Card number" />

      <.input field={@payment[:cvv]} label="CVV"
              valid={@cvv_valid} valid_field="cvv_valid"
              errors={@payment_cvv_errors}
              maxlength="4" inputmode="numeric" />
  """
  attr :field, Phoenix.HTML.FormField,
    required: true,
    doc: "The form field from `@form[:field]`"

  attr :label, :string,
    required: true,
    doc: "The label text"

  attr :type, :string,
    default: "text",
    doc: "The input type"

  attr :valid, :boolean,
    default: nil,
    doc: "Validation state. If nil, derives from form_field_valid assign"

  attr :valid_field, :string,
    default: nil,
    doc: "Custom valid field name for JS (e.g., 'cvv_valid' instead of 'payment_cvv_valid')"

  attr :errors, :list,
    default: nil,
    doc: "Error list. If nil, derives from form_field_errors assign"

  attr :show_errors, :boolean,
    default: nil,
    doc: "Whether to show errors. If nil, derives from form_field_show_errors assign"

  attr :class, :string,
    default: nil,
    doc: "Additional CSS classes for the input"

  attr :wrapper_class, :string,
    default: nil,
    doc: "Additional CSS classes for the wrapper div"

  attr :floating, :boolean,
    default: true,
    doc: "Whether to use floating label style (default) or traditional label-above-input"

  attr :format, :string,
    default: nil,
    doc: "Input formatting: 'credit-card' (XXXX XXXX XXXX XXXX), 'expiry' (MM/YY)"

  attr :rest, :global,
    include: ~w(autocomplete disabled form inputmode list maxlength minlength
                pattern placeholder readonly required size step),
    doc: "Additional HTML attributes for the input"

  def input(assigns) do
    assigns = prepare_field_assigns(assigns)

    ~H"""
    <.field_wrapper {assigns}>
      <input
        type={@type}
        name={@field.name}
        value={@field.value || ""}
        data-lavash-bind={"#{@form_str}_params.#{@field_str}"}
        data-lavash-form={@form_str}
        data-lavash-field={@field_str}
        data-lavash-valid={@lavash_valid_field}
        data-lavash-format={@format}
        class={["input input-bordered w-full", input_validation_class(assigns), @class]}
        {@rest}
      />
    </.field_wrapper>
    """
  end

  @doc """
  Renders a textarea with floating label and optimistic validation.

  Same attributes as `input/1` but renders a textarea.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :valid, :boolean, default: nil
  attr :valid_field, :string, default: nil
  attr :errors, :list, default: nil
  attr :show_errors, :boolean, default: nil
  attr :class, :string, default: nil
  attr :wrapper_class, :string, default: nil
  attr :floating, :boolean, default: true
  attr :rows, :integer, default: 3

  attr :rest, :global,
    include: ~w(autocomplete disabled form maxlength minlength placeholder readonly required),
    doc: "Additional HTML attributes"

  def textarea(assigns) do
    assigns = prepare_field_assigns(assigns)

    ~H"""
    <.field_wrapper {assigns}>
      <textarea
        name={@field.name}
        rows={@rows}
        data-lavash-bind={"#{@form_str}_params.#{@field_str}"}
        data-lavash-form={@form_str}
        data-lavash-field={@field_str}
        data-lavash-valid={@lavash_valid_field}
        class={["textarea textarea-bordered w-full", input_validation_class(assigns), @class]}
        {@rest}
      >{@field.value || ""}</textarea>
    </.field_wrapper>
    """
  end

  # Shared wrapper that handles floating vs non-floating labels
  attr :label, :string, required: true
  attr :floating, :boolean, required: true
  attr :wrapper_class, :string, default: nil
  attr :form_name, :any, required: true
  attr :field_name, :atom, required: true
  attr :errors, :list, default: nil
  attr :valid, :boolean, default: nil
  attr :lavash_valid_field, :string, required: true
  slot :inner_block, required: true

  defp field_wrapper(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%= if @floating do %>
        <label class="floating-label w-full">
          {render_slot(@inner_block)}
          <span>{@label}</span>
        </label>
      <% else %>
        <label class="label">
          <span class="label-text">{@label}</span>
        </label>
        {render_slot(@inner_block)}
      <% end %>
      <div class="min-h-5 mt-1">
        <.field_errors form={@form_name} field={@field_name} errors={@errors || []} />
      </div>
    </div>
    """
  end

  # Shared setup for field components
  defp prepare_field_assigns(assigns) do
    %Phoenix.HTML.FormField{field: field_name, form: form} = assigns.field
    form_name = form.name
    form_str = to_string(form_name)
    field_str = to_string(field_name)
    valid_field = assigns.valid_field || "#{form_str}_#{field_str}_valid"

    assigns
    |> assign(:form_name, form_name)
    |> assign(:field_name, field_name)
    |> assign(:form_str, form_str)
    |> assign(:field_str, field_str)
    |> assign(:lavash_valid_field, valid_field)
  end

  defp input_validation_class(assigns) do
    # show_errors must be explicitly passed for validation classes to apply
    # (prevents flash of error styling before user interaction)
    # Only show error styling, not success (green can be distracting)
    cond do
      not (assigns.show_errors || false) -> ""
      assigns.valid == false -> "input-error"
      true -> ""
    end
  end
end
