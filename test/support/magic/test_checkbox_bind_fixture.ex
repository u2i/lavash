defmodule Lavash.Test.Magic.CheckboxBindLive do
  @moduledoc """
  Regression fixture mirroring the shape that exposed the
  target.value-vs-target.checked bug in form_handler.

  - `:confirmed` is an optimistic boolean; the checkbox binds to it
    via `data-lavash-bind="confirmed"`.
  - `:submitted` is a non-optimistic boolean (defaults to false).
  - `:ready_to_submit` is a calculation combining both. The submit
    button is `disabled={not @ready_to_submit}` — the template
    transformer should rewrite this to add
    `data-lavash-enabled="ready_to_submit"` so the JS pipeline can
    toggle the button client-side.

  When the user ticks the checkbox, the bind handler must write
  the boolean `true` (not the string `"true"` from `target.value`).
  Otherwise the JS calc evaluates `"true" && !false` which is a
  truthy string — and the downstream `data-lavash-enabled` handler
  does a strict `=== true` check that the string fails. Result:
  button stays disabled even though the calc is logically truthy.
  """
  use Lavash.LiveView

  state :confirmed, :boolean, from: :ephemeral, default: false, optimistic: true
  state :submitted, :boolean, from: :ephemeral, default: false, optimistic: true

  calculate :ready_to_submit, rx(@confirmed and not @submitted)

  template do
    ~H"""
    <div>
      <label>
        <input
          id="confirm-box"
          type="checkbox"
          name="confirmed"
          value="true"
          data-lavash-bind="confirmed"
        /> Confirm
      </label>

      <button
        id="submit-btn"
        type="submit"
        disabled={not @ready_to_submit}
      >
        Submit
      </button>

      <!-- Mirror state to DOM for assertions -->
      <p id="confirmed-state">{inspect(@confirmed)}</p>
      <p id="ready-state">{inspect(@ready_to_submit)}</p>
    </div>
    """
  end
end
