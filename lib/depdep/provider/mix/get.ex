defmodule Depdep.Provider.Mix.Get do
  @moduledoc """
  Runs `mix deps.get` for each member, on depdep's behalf.

  Every consumer's `before_script` was the same three lines in the same order —
  pull, `mix deps.get`, and a second pull for projects with git dependencies —
  and the order was the whole contract. Owning the middle line lets depdep do
  the third itself: a git dependency's children are unknown until its source
  is on disk, and only whoever ran `deps.get` knows when that is (#60).

  The output is forwarded unchanged, line by line as it arrives, so the job log
  reads exactly as it did when the consumer ran the command. Nothing here is
  parsed; `Depdep.CLI` already knows what the pull left unresolved.

  **The exit status is the contract.** A `deps.get` that fails inside depdep
  has to fail the job exactly as the bare line it replaced would have — it is
  the consumer's fetch, not the store's — so the status comes back to the
  caller rather than being absorbed into a warning. Store trouble stays what
  it always was.
  """

  @doc """
  `:ok`, or `{:error, {project, status}}` for the first member whose `deps.get`
  exited non-zero — the rest are not attempted, as they would not have been.

  Each member is run with the pull's `MIX_ENV`: `deps.get` fetches every
  dependency regardless, but a `mix.exs` that computes its list from the
  environment should see the same one the pull did.
  """
  def run(root, projects, env) do
    Enum.reduce_while(projects, :ok, fn project, :ok ->
      dir = Path.join(root, project)

      # `into: IO.stream()` forwards each line as it arrives rather than after
      # the command ends — a `deps.get` over a slow mirror must not look hung.
      {_, status} =
        System.cmd("mix", ["deps.get"],
          cd: dir,
          env: [{"MIX_ENV", to_string(env)}],
          stderr_to_stdout: true,
          into: IO.stream()
        )

      case status do
        0 -> {:cont, :ok}
        status -> {:halt, {:error, {project, status}}}
      end
    end)
  end
end
