defmodule Lavash.SparkHeex.Dsl do
  @moduledoc false
  # The Spark extension itself: declares a `state` section (a stripped-down
  # version of lavash's state DSL) so we have something for the template to
  # validate references against.
  #
  # No `template` section here — `template do ... end` is a regular macro
  # that stuffs the template source onto a module attribute, which a
  # transformer copies into the persistent DSL state.

  @state_entity %Spark.Dsl.Entity{
    name: :state,
    target: Lavash.SparkHeex.State,
    args: [:name, :type],
    schema: [
      name: [type: :atom, required: true],
      type: [type: :atom, required: true],
      default: [type: :any, default: nil]
    ]
  }

  @states_section %Spark.Dsl.Section{
    name: :states,
    top_level?: true,
    entities: [@state_entity]
  }

  @action_entity %Spark.Dsl.Entity{
    name: :action,
    target: Lavash.SparkHeex.Action,
    args: [:name],
    schema: [
      name: [type: :atom, required: true],
      args: [type: {:list, :atom}, default: []]
    ]
  }

  @actions_section %Spark.Dsl.Section{
    name: :actions,
    top_level?: true,
    entities: [@action_entity]
  }

  use Spark.Dsl.Extension,
    sections: [@states_section, @actions_section],
    transformers: [
      Lavash.SparkHeex.Transformers.IngestTemplate,
      Lavash.SparkHeex.Transformers.ValidateTemplate,
      Lavash.SparkHeex.Transformers.ValidateEvents,
      Lavash.SparkHeex.Transformers.CompileTemplate
    ],
    imports: [Lavash.SparkHeex.TemplateMacro]
end

defmodule Lavash.SparkHeex.State do
  @moduledoc false
  defstruct [:name, :type, :default, __spark_metadata__: nil]
end

defmodule Lavash.SparkHeex.Action do
  @moduledoc false
  defstruct [:name, :args, __spark_metadata__: nil]
end
