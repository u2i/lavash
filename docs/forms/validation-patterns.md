# Form Validation Patterns

Lavash provides a comprehensive form validation system that combines client-side and server-side validation with automatic state management and visual feedback.

## Quick Start

```elixir
defmodule MyApp.UserFormLive do
  use Lavash.LiveView

  alias MyApp.Accounts.User

  # Define form - auto-generates validation state
  form :user_form, User do
    create :create_user
  end

  actions do
    action :save do
      submit :user_form, on_success: :on_saved
    end

    action :on_saved do
      # Handle success - e.g., navigate or show message
    end
  end

  render fn assigns ->
    ~L"""
    <.form for={@user_form} phx-submit="save">
      <.input
        field={@user_form[:name]}
        label="Name"
        errors={@user_form_name_errors}
      />

      <!-- Submit button automatically disabled when form invalid -->
      <button
        type="submit"
        data-lavash-enabled="user_form_valid"
        phx-disable-with="Saving..."
        class="btn btn-primary"
      >
        Save
      </button>
    </.form>
    """
  end
end
```

## How Validation Works

Lavash uses a **blur-then-change** pattern for optimal UX:

1. **Before blur** - Field shows no errors, validation doesn't run
2. **On blur** - Field is validated and marked as "touched"
3. **After blur** - Field validates on every keystroke
4. **On submit** - All fields marked touched and validated

This pattern provides instant feedback once the user has left a field, without being annoying while they're still typing.

## Auto-Generated Validation State

For each form, Lavash automatically generates:

### Overall Form State
- `@{form}_valid` - Boolean, true when ALL fields are valid
- `@{form}_errors` - Array of all errors across all fields

### Per-Field State
- `@{form}_{field}_valid` - Boolean validity for specific field
- `@{form}_{field}_errors` - Array of error messages for specific field

### Example

```elixir
form :address_form, Address do
  create :save
end
```

Auto-generates:
- `@address_form_valid`
- `@address_form_first_name_valid`
- `@address_form_first_name_errors`
- `@address_form_last_name_valid`
- `@address_form_last_name_errors`
- ... (one pair for each field)

## Submit Button Patterns

### Pattern 1: Using data-lavash-enabled (Recommended)

```elixir
<button
  type="submit"
  data-lavash-enabled="my_form_valid"
  phx-disable-with="Saving..."
  class="btn btn-primary"
>
  Submit
</button>
```

**Benefits:**
- Declarative - no conditional logic needed
- Automatic visual feedback (opacity + cursor)
- Consistent across all forms

### Pattern 2: Manual disabled attribute

```elixir
<button
  type="submit"
  disabled={not @my_form_valid}
  phx-disable-with="Saving..."
  class={"btn " <> if @my_form_valid, do: "btn-primary", else: "btn-disabled opacity-60"}
>
  Submit
</button>
```

**Use when:** You need custom styling logic

## Validation Error Sources

### Client Errors (Instant)

Transpiled from Ash resource constraints:
- `allow_nil?` → Required validation
- `min_length`, `max_length` → Length validation
- `min`, `max` → Number range validation

Example:
```elixir
attribute :name, :string do
  allow_nil? false     # → "is required"
  constraints [
    min_length: 3,     # → "must be at least 3 characters"
    max_length: 50     # → "must be at most 50 characters"
  ]
end
```

### Server Errors (Delayed)

From custom Ash validations that can't be transpiled:
- Uniqueness checks
- Complex regex patterns
- Database lookups
- Custom validation functions

Example:
```elixir
validations do
  validate present(:email), message: "Enter an email"
  validate present(:username), message: "Enter a username"

  # Custom validation - runs on server
  validate fn changeset, _context ->
    # Complex logic here...
  end
end
```

Server errors are automatically:
1. Stored in `{form}_server_errors` state
2. Merged into `{form}_{field}_errors` for display
3. Shown in the same UI as client errors

## Error Display

### Per-Field Errors

Use the `.field_errors` component:

```elixir
<.input
  field={@user_form[:email]}
  label="Email"
  errors={@user_form_email_errors}
/>
```

The `.input` component automatically shows errors below the field when:
- Field has been touched (blurred), OR
- Form has been submitted

### Visual Feedback

Inputs automatically receive visual styling based on validation state:

- **Untouched** - Neutral border (default)
- **Touched + Invalid** - Red border (`input-error` class)
- **Touched + Valid** - No special styling (green borders are distracting)

This happens automatically via JavaScript - no template changes needed.

## Submit Validation

When a form is submitted:

1. **All fields marked touched** - Errors now visible on all fields
2. **Form validated** - Check if `{form}_valid` is true
3. **First invalid field focused** - User's attention directed to the error
4. **Field scrolled into view** - Smooth scroll to error location
5. **Submit prevented** - If any validation fails

If validation passes:
- Form submits to server
- `phx-disable-with` shows loading state
- On success → `on_success` action triggered
- On error → Server errors merged into field errors

## Advanced Patterns

### Custom Valid Field Names

If you have custom validation logic:

```elixir
<input
  field={@form[:email]}
  data-lavash-valid="email_format_valid"
  errors={@form_email_errors}
/>
```

### Conditional Submit Button Color

Use `data-lavash-toggle` for dynamic classes:

```elixir
<button
  type="submit"
  data-lavash-enabled="form_valid"
  data-lavash-toggle="form_valid|btn-primary|btn-disabled"
>
  Submit
</button>
```

Format: `field_name|classes_when_true|classes_when_false`

### Form-Level Error Summary

For long forms, show a summary at the top:

```elixir
<div :if={length(@my_form_errors) > 0} class="alert alert-warning mb-4">
  <p>Please fix validation errors before submitting</p>
</div>
```

## Complete Example

```elixir
defmodule MyApp.CheckoutLive do
  use Lavash.LiveView

  alias MyApp.Orders.Payment

  form :payment_form, Payment do
    create :process_payment
  end

  actions do
    action :save do
      submit :payment_form,
        on_success: :on_payment_success,
        on_error: :on_payment_error
    end

    action :on_payment_success do
      # Navigate to confirmation page
    end

    action :on_payment_error do
      # Show error toast or message
    end
  end

  render fn assigns ->
    ~L"""
    <.form for={@payment_form} phx-submit="save" class="space-y-4">
      <.input
        field={@payment_form[:card_number]}
        label="Card Number"
        errors={@payment_form_card_number_errors}
        format="credit-card"
      />

      <div class="grid grid-cols-2 gap-4">
        <.input
          field={@payment_form[:expiry]}
          label="Expiry (MM/YY)"
          errors={@payment_form_expiry_errors}
        />

        <.input
          field={@payment_form[:cvv]}
          label="CVV"
          errors={@payment_form_cvv_errors}
        />
      </div>

      <button
        type="submit"
        data-lavash-enabled="payment_form_valid"
        phx-disable-with="Processing..."
        class="btn btn-primary w-full"
      >
        Pay Now
      </button>
    </.form>
    """
  end
end
```

## Troubleshooting

### Submit button not disabling

1. Check that form name matches: `form :user_form` → `data-lavash-enabled="user_form_valid"`
2. Verify form has validation constraints in Ash resource
3. Check browser console for JavaScript errors

### Errors not showing

1. Ensure you're passing `errors={@form_field_errors}` to input component
2. Check that field is marked as `allow_nil? false` or has constraints
3. Verify field has been touched (blurred) or form submitted

### Validation too strict

If you want to allow submit even when invalid (not recommended):
- Remove `data-lavash-enabled` attribute
- Handle server-side validation errors in `on_error` action

## Best Practices

1. **Always use `data-lavash-enabled`** for submit buttons on validated forms
2. **Keep validations in Ash resources** - single source of truth
3. **Use server validation** for uniqueness, database checks
4. **Show per-field errors** - more helpful than form-level only
5. **Test with keyboard navigation** - ensure Tab, Enter, Escape work
6. **Consider accessibility** - error messages should be screen-reader friendly

## See Also

- [Form DSL Reference](../dsl/forms.md)
- [Input Components](../components/inputs.md)
- [Ash Resource Validations](https://hexdocs.pm/ash/validations.html)
