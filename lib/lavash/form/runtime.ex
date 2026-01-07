defmodule Lavash.Form.Runtime do
  @moduledoc """
  Shared form handling runtime for both LiveView and Component.

  This module contains the common logic for form operations:
  - `extract_resource/1` - Extract Ash resource from various form types
  - `extract_changeset/1` - Extract Ash changeset from various form types
  - `broadcast_mutation/1` - Broadcast mutation events for PubSub invalidation
  """

  @doc """
  Extract the Ash resource module from various form types.

  Supports:
  - `Lavash.Form` with embedded changeset
  - `Ash.Changeset`
  - `AshPhoenix.Form`
  - `Phoenix.HTML.Form` (recurses into source)
  """
  def extract_resource(%Lavash.Form{changeset: %Ash.Changeset{resource: resource}}), do: resource
  def extract_resource(%Ash.Changeset{resource: resource}), do: resource
  def extract_resource(%AshPhoenix.Form{resource: resource}), do: resource
  def extract_resource(%Phoenix.HTML.Form{source: source}), do: extract_resource(source)
  def extract_resource(_), do: nil

  @doc """
  Extract the Ash changeset from various form types.

  Supports:
  - `Lavash.Form` with embedded changeset
  - `Phoenix.HTML.Form` (recurses into source)
  - `AshPhoenix.Form` with Ash.Changeset source
  - `Ash.Changeset` directly
  """
  def extract_changeset(%Lavash.Form{changeset: changeset}), do: changeset
  def extract_changeset(%Phoenix.HTML.Form{source: source}), do: extract_changeset(source)
  def extract_changeset(%AshPhoenix.Form{source: %Ash.Changeset{} = cs}), do: cs
  def extract_changeset(%Ash.Changeset{} = cs), do: cs
  def extract_changeset(_), do: nil

  @doc """
  Broadcast mutation to all relevant PubSub topics.

  Uses the resource's notify_on configuration from Lavash.Resource extension
  to enable fine-grained invalidation based on filter combinations.
  """
  def broadcast_mutation(form) do
    changeset = extract_changeset(form)

    if changeset do
      resource = changeset.resource
      old_record = changeset.data
      changed_attrs = changeset.attributes || %{}

      # Get notify_on attributes from the resource's Lavash extension
      notify_attrs = Lavash.Resource.notify_on(resource)

      if notify_attrs != [] do
        # Build changes map: %{attr => {old_value, new_value}}
        changes =
          notify_attrs
          |> Enum.filter(&Map.has_key?(changed_attrs, &1))
          |> Enum.map(fn attr ->
            old_value = if old_record, do: Map.get(old_record, attr), else: nil
            new_value = Map.get(changed_attrs, attr)
            {attr, {old_value, new_value}}
          end)
          |> Map.new()

        # Build unchanged map: %{attr => value} for notify attrs that didn't change
        unchanged =
          notify_attrs
          |> Enum.reject(&Map.has_key?(changed_attrs, &1))
          |> Enum.map(fn attr ->
            value = if old_record, do: Map.get(old_record, attr), else: nil
            {attr, value}
          end)
          |> Map.new()

        # Broadcast to all relevant combination topics
        Lavash.PubSub.broadcast_mutation(resource, notify_attrs, changes, unchanged)
      else
        # No fine-grained invalidation configured, just broadcast resource-level
        Lavash.PubSub.broadcast(resource)
      end
    else
      # Couldn't extract changeset, broadcast resource-level
      resource = extract_resource(form)
      if resource, do: Lavash.PubSub.broadcast(resource)
    end
  end
end
