defmodule Tyrex.Error do
  @moduledoc """
  Exception struct for Tyrex runtime errors.

  Fields:
    * `:name` - Error type atom. One of:
      * `:execution_error` — JS/TS code raised or failed to compile
      * `:promise_rejection` — Returned promise rejected; `:value` holds the
        decoded rejection value
      * `:conversion_error` — A value could not be converted between Elixir
        and JavaScript representations
      * `:dead_runtime_error` — The underlying runtime is no longer alive
        (e.g. crashed, was killed, or was stopped while a call was in flight)
      * `:timeout` — An `eval` exceeded its `:timeout` deadline. The V8 isolate
        was terminated, so the runtime is dead and must be replaced
      * `:heap_limit_error` — The guest exceeded the runtime's `:max_heap_mb`
        cap. The isolate was terminated, so the runtime is dead
      * `:unsupported_option` — The requested combination of options cannot be
        served (e.g. `blocking: true` on a runtime with the `:apply` bridge
        enabled, which would deadlock)
    * `:message` - Human-readable error message (optional)
    * `:value` - Additional error value, such as the rejected promise value (optional)
  """

  @enforce_keys [
    :name
  ]

  @typedoc """
  A `Tyrex.Error` exception with a tagged `:name`, optional human-readable
  `:message`, and an optional `:value` payload (used for promise rejections).
  """
  @type t :: %__MODULE__{
          name: atom(),
          message: String.t() | nil,
          value: term() | nil
        }

  defexception [:message, :name, :value]

  @doc """
  Build a `Tyrex.Error` exception from a keyword list.

  Required: `:name`. Optional: `:message`, `:value`. This is the callback
  used by `raise Tyrex.Error, name: :dead_runtime_error` and similar.
  """
  @spec exception(Keyword.t()) :: t()
  def exception(opts) do
    %__MODULE__{
      message: Keyword.get(opts, :message),
      name: Keyword.fetch!(opts, :name),
      value: Keyword.get(opts, :value)
    }
  end

  @doc """
  Format a `Tyrex.Error` as a human-readable string. Used by Elixir when
  the exception is raised or inspected via `Exception.message/1`.
  """
  @spec message(t()) :: String.t()
  def message(error) do
    if error.message do
      "#{error.name}: #{error.message}"
    else
      Atom.to_string(error.name)
    end
  end
end
