defmodule Managoat.Runtimes.OpenCodePinTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.ACP
  alias Managoat.Sandbox

  setup :verify_on_exit!

  for {installed, install?} <- [
        {nil, true},
        {"1.18.29", true},
        {"1.18.30", false},
        {"1.18.31", true}
      ] do
    @tag :tmp_dir
    test "installation converges from #{inspect(installed)} to the exact pin", %{tmp_dir: dir} do
      on_exit(fn -> File.rm_rf!(dir) end)
      installed = unquote(installed)
      local = Path.join(dir, "local")
      File.mkdir_p!(local)
      bin = Path.join(local, "opencode")

      if installed do
        File.write!(bin, "#!/bin/sh\necho '#{installed}'\n")
        File.chmod!(bin, 0o755)
      end

      expect(Sandbox, :exec, fn :handle, "bash", ["-lc", script], _opts ->
        # Run the production installer with a fake npm, never a real package
        # manager. Both filesystem locations are confined to this fixture.
        npm = ~S"""
        npm() {
          if [ "$*" = 'prefix -g' ]; then
            printf '%s\n' "$PIN_TEST_ROOT/global"
            return
          fi
          [ "$*" = 'install -g --no-progress --silent opencode-ai@1.18.30' ] || return 92
          printf 'installed\n' >> "$PIN_TEST_ROOT/calls"
          mkdir -p "$PIN_TEST_ROOT/global/bin"
          printf '#!/bin/sh\necho 1.18.30\n' > "$PIN_TEST_ROOT/global/bin/opencode"
          chmod +x "$PIN_TEST_ROOT/global/bin/opencode"
        }
        """

        script = String.replace(script, "/home/sprite/.local/bin", local)

        {output, code} =
          System.cmd("bash", ["-c", npm <> script],
            env: [{"PIN_TEST_ROOT", dir}],
            stderr_to_stdout: true
          )

        assert code == 0, output
        {:ok, output, code}
      end)

      assert :ok = ACP.install(:handle, "opencode", [])
      assert {"1.18.30\n", 0} = System.cmd(bin, ["--version"])
      assert File.exists?(Path.join(dir, "calls")) == unquote(install?)
    end
  end
end
