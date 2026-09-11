defmodule Managoat.Runtimes.ProvisioningTest do
  @moduledoc """
  The imperative half of each runtime — `prepare_sandbox/3`, `write_config/2`
  and the adapter install — driven against a stubbed sandbox.

  In Fountain these paths were covered by the conversation server's
  provisioning tests, which drive them through the real server. A package
  cannot lean on its host's tests, so the shape of every exec and write is
  pinned here: the script each runtime runs, the file it writes, and the
  tagged error it answers with when the sandbox refuses.
  """
  use ExUnit.Case, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias Managoat.Runtimes.{ACP, Claude, Codex, Gemini, OpenCode}
  alias Managoat.Sandbox

  setup :verify_on_exit!

  @handle %Sandbox.Handle{provider: :sprites, name: "prov-test"}

  describe "Codex" do
    test "default_env/2 exports OPENAI_API_KEY, or nothing" do
      assert Codex.default_env(nil, %{openai_api_key: "sk"}) == [{"OPENAI_API_KEY", "sk"}]
      assert Codex.default_env(nil, %{openai_api_key: ""}) == []
      assert Codex.default_env(nil, %{}) == []
    end

    test "prepare_sandbox/3 logs in with the key on stdin, then waits for the exit" do
      test = self()
      command = %Sandbox.Command{provider: :sprites, ref: make_ref()}

      expect(Sandbox, :spawn, fn @handle, "codex", ["login", "--with-api-key"], opts ->
        assert opts[:stdin] == true
        assert opts[:owner] == test
        {:ok, command}
      end)

      expect(Sandbox, :write_stdin, fn ^command, "sk-1\n" ->
        # The CLI exits after it has read the key; the owner sees the exit.
        send(test, {:exit, %{ref: command.ref}, 0})
        :ok
      end)

      expect(Sandbox, :close_stdin, fn ^command -> :ok end)

      assert :ok = Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", "sk-1"}])
    end

    test "a non-zero login exit is reported with its code" do
      test = self()
      command = %Sandbox.Command{provider: :sprites, ref: make_ref()}

      expect(Sandbox, :spawn, fn _h, _c, _a, _o -> {:ok, command} end)

      expect(Sandbox, :write_stdin, fn ^command, _ ->
        send(test, {:exit, %{ref: command.ref}, 3})
        :ok
      end)

      expect(Sandbox, :close_stdin, fn ^command -> :ok end)

      assert {:error, {:codex_login_exit, 3}} =
               Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", "sk"}])
    end

    test "a transport that drops before the exit is an error, not a successful login" do
      # managoat_sandbox 0.2.0: a stream that closes with no exit frame is
      # `{:error, _, :closed_before_exit}`. Under 0.1.0 it was a synthesised
      # `{:exit, _, 0}`, so this returned :ok and provisioning carried on
      # with a sandbox that had never logged in.
      test = self()
      command = %Sandbox.Command{provider: :sprites, ref: make_ref()}

      expect(Sandbox, :spawn, fn _h, _c, _a, _o -> {:ok, command} end)

      expect(Sandbox, :write_stdin, fn ^command, _ ->
        send(test, {:error, %{ref: command.ref}, :closed_before_exit})
        :ok
      end)

      expect(Sandbox, :close_stdin, fn ^command -> :ok end)

      assert {:error, {:codex_login_transport, :closed_before_exit}} =
               Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", "sk"}])
    end

    test "a refused stdin write and a failed spawn are tagged errors, not exits" do
      command = %Sandbox.Command{provider: :sprites, ref: make_ref()}
      expect(Sandbox, :spawn, fn _h, _c, _a, _o -> {:ok, command} end)
      expect(Sandbox, :write_stdin, fn ^command, _ -> {:error, :closed} end)

      assert {:error, {:codex_login_write, :closed}} =
               Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", "sk"}])

      expect(Sandbox, :spawn, fn _h, _c, _a, _o -> {:error, :unavailable} end)

      assert {:error, {:codex_login_spawn, {:error, :unavailable}}} =
               Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", "sk"}])
    end

    test "no key in the env is named, rather than left for the first turn to 401 on" do
      reject(&Sandbox.spawn/4)
      assert {:error, :missing_openai_api_key} = Codex.prepare_sandbox(@handle, nil, [])

      assert {:error, :missing_openai_api_key} =
               Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", ""}])
    end
  end

  describe "Claude" do
    test "prepare_sandbox/3 warms the CLI's model list through the pinned adapter" do
      test = self()

      expect(Sandbox, :exec, fn @handle, "bash", ["-lc", script], opts ->
        send(test, {:exec, script, opts})
        {:ok, "warm\n", 0}
      end)

      env = [{"ANTHROPIC_API_KEY", "sk-1"}]
      assert :ok = Claude.prepare_sandbox(@handle, nil, env)

      assert_receive {:exec, script, opts}
      assert opts[:env] == env
      # The adapter the turn will use, from where ACP.install/3 put it, in
      # the directory the turn will run in.
      assert script =~ "timeout 45 /home/sprite/.local/bin/claude-agent-acp"
      assert script =~ "cd /home/sprite\n"
      assert script =~ ~s("method":"initialize")
      assert script =~ ~s("method":"session/new")
      # The cache key the CLI writes, in the file it writes it to, and the
      # short-circuit for a sandbox that is already warm.
      assert script =~ ~s(cfg="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json")
      assert script =~ "additionalModelOptionsCache"
      assert script =~ "echo warm\n  exit 0"
    end

    test "the OAuth credential is enough to warm with" do
      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "warm", 0} end)
      assert :ok = Claude.prepare_sandbox(@handle, nil, [{"CLAUDE_CODE_OAUTH_TOKEN", "t"}])
    end

    test "a cache that stays cold is logged and provisioning goes on" do
      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "cold\n", 0} end)

      log =
        capture_log(fn ->
          assert :ok = Claude.prepare_sandbox(@handle, nil, [{"ANTHROPIC_API_KEY", "sk"}])
        end)

      assert log =~ "did not warm"
    end

    test "a script that dies is logged with its exit, and provisioning goes on" do
      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "bash: timeout: not found", 127} end)

      log =
        capture_log(fn ->
          assert :ok = Claude.prepare_sandbox(@handle, nil, [{"ANTHROPIC_API_KEY", "sk"}])
        end)

      assert log =~ "exited 127"
      assert log =~ "timeout: not found"
    end

    test "a sandbox that cannot run the script is a tagged error" do
      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:error, :unavailable} end)

      assert {:error, {:claude_model_list_warmup, :unavailable}} =
               Claude.prepare_sandbox(@handle, nil, [{"ANTHROPIC_API_KEY", "sk"}])
    end

    test "no credential in the env runs nothing: there is nothing to fetch with" do
      reject(&Sandbox.exec/4)

      assert :ok = Claude.prepare_sandbox(@handle, nil, [])
      assert :ok = Claude.prepare_sandbox(@handle, nil, [{"ANTHROPIC_API_KEY", ""}])
      assert :ok = Claude.prepare_sandbox(@handle, nil, [{"HOME", "/home/sprite"}])
    end
  end

  describe "configuration no-ops" do
    test "an agent without runtime-specific config writes nothing" do
      reject(&Sandbox.write_file/3)

      assert :ok = Managoat.Runtimes.Claude.write_config(@handle, %{})
      assert :ok = Managoat.Runtimes.Instructions.write(@handle, "claude", %{})
    end
  end

  describe "Gemini" do
    test "default_env/2 exports the key and HOME=/tmp, and HOME alone without a key" do
      assert Gemini.default_env(nil, %{gemini_api_key: "g"}) ==
               [{"GEMINI_API_KEY", "g"}, {"HOME", "/tmp"}]

      assert Gemini.default_env(nil, %{gemini_api_key: ""}) == [{"HOME", "/tmp"}]
      assert Gemini.default_env(nil, %{}) == [{"HOME", "/tmp"}]
    end

    test "write_config/2 writes user-scope MCP servers under gemini's own HOME" do
      test = self()

      expect(Sandbox, :write_file, fn @handle, path, body ->
        send(test, {:wrote, path, body})
        :ok
      end)

      servers = %{"fs" => %{"command" => "mcp-fs"}}
      assert :ok = Gemini.write_config(@handle, %{mcp_servers: servers})

      assert_receive {:wrote, "/tmp/.gemini/settings.json", body}
      assert Jason.decode!(body) == %{"mcpServers" => servers}
    end

    test "write_config/2 writes nothing without servers" do
      reject(&Sandbox.write_file/3)
      assert :ok = Gemini.write_config(@handle, nil)
      assert :ok = Gemini.write_config(@handle, %{mcp_servers: %{}})
      assert :ok = Gemini.write_config(@handle, %{mcp_servers: nil})
    end

    test "a refused config write is reported, not swallowed" do
      # `:not_found` is permanent in the sandbox taxonomy, so Retry does not
      # spend its attempts on it and the error comes straight back.
      expect(Sandbox, :write_file, fn _h, _p, _b -> {:error, :not_found} end)

      assert {:error, {:runtime_config, "/tmp/.gemini/settings.json", :not_found}} =
               Gemini.write_config(@handle, %{mcp_servers: %{"a" => %{}}})
    end

    test "prepare_sandbox/3 installs the session-store workaround, then git-inits the workspace" do
      test = self()

      expect(Sandbox, :write_file, fn @handle, path, _body ->
        send(test, {:wrote, path})
        :ok
      end)

      expect(Sandbox, :exec, fn @handle, "bash", ["-lc", script], opts ->
        send(test, {:exec, script, opts[:env]})
        {:ok, "", 0}
      end)

      env = [{"HOME", "/tmp"}]
      assert :ok = Gemini.prepare_sandbox(@handle, nil, env)

      assert_receive {:wrote, "/tmp/gemini-session-consolidate.js"}
      assert_receive {:exec, script, ^env}
      assert script =~ "/tmp/gemini-workspace/.git"
      assert script =~ "git init -q"
    end

    test "a failed workspace init is a tagged error" do
      stub(Sandbox, :write_file, fn _h, _p, _b -> :ok end)

      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "fatal", 128} end)

      assert {:error, {:gemini_workspace_init_exit, 128}} =
               Gemini.prepare_sandbox(@handle, nil, [])

      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:error, :unavailable} end)

      assert {:error, {:gemini_workspace_init, :unavailable}} =
               Gemini.prepare_sandbox(@handle, nil, [])
    end
  end

  describe "OpenCode" do
    test "default_env/2 exports the credential the model's provider needs, plus HOME" do
      creds = %{anthropic_api_key: "a", openai_api_key: "o", gemini_api_key: "g"}

      assert OpenCode.default_env(%{model: "anthropic/claude-sonnet-4-6"}, creds) ==
               [{"ANTHROPIC_API_KEY", "a"}, {"HOME", "/tmp"}]

      assert OpenCode.default_env(%{model: "openai/gpt-5.5"}, creds) ==
               [{"OPENAI_API_KEY", "o"}, {"HOME", "/tmp"}]

      # Not GEMINI_API_KEY. opencode's google provider is `@ai-sdk/google` and
      # reads GOOGLE_GENERATIVE_AI_API_KEY; the key under the other name is
      # ignored and every turn fails to authenticate
      # (managoat/fountain#1460).
      assert OpenCode.default_env(%{model: "google/gemini-3.1-pro-preview"}, creds) ==
               [{"GOOGLE_GENERATIVE_AI_API_KEY", "g"}, {"HOME", "/tmp"}]

      # A provider with no credential on file, an unknown provider, an
      # unparseable model and no model at all: HOME only.
      assert OpenCode.default_env(%{model: "anthropic/x"}, %{anthropic_api_key: ""}) ==
               [{"HOME", "/tmp"}]

      assert OpenCode.default_env(%{model: "openrouter/x"}, creds) == [{"HOME", "/tmp"}]
      assert OpenCode.default_env(%{model: "bare"}, creds) == [{"HOME", "/tmp"}]
      assert OpenCode.default_env(%{model: nil}, creds) == [{"HOME", "/tmp"}]
      assert OpenCode.default_env(nil, creds) == [{"HOME", "/tmp"}]
    end

    test "prepare_sandbox/3 pins OpenCode before preparing its workspace" do
      test = self()

      expect(Sandbox, :exec, 2, fn @handle, "bash", ["-lc", script], opts ->
        send(test, {:exec, script, opts})
        {:ok, "", 0}
      end)

      assert :ok = OpenCode.prepare_sandbox(@handle, nil, [{"HOME", "/tmp"}])

      assert_receive {:exec, installer, opts}
      assert opts[:env] == [{"HOME", "/tmp"}]
      assert installer =~ "opencode-ai@1.18.30"
      assert installer =~ "/home/sprite/.local/bin/opencode"
      assert_receive {:exec, workspace, _opts}
      assert workspace =~ "/tmp/opencode-workspace"
      refute workspace =~ "bun install"
    end

    test "a failed pin prevents workspace preparation and preserves the installer error" do
      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "npm: not found", 127} end)

      assert {:error, {:acp_adapter_install_exit, 127, "npm: not found"}} =
               OpenCode.prepare_sandbox(@handle, nil, [])

      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:error, :unavailable} end)

      assert {:error, {:acp_adapter_install, :unavailable}} =
               OpenCode.prepare_sandbox(@handle, nil, [])
    end

    test "workspace failures retain their existing error after installation" do
      for failure <- [{:ok, "git failed", 17}, {:error, :unavailable}] do
        expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "", 0} end)
        expect(Sandbox, :exec, fn _h, _c, _a, _o -> failure end)

        expected =
          case failure do
            {:ok, _, code} -> {:opencode_install_exit, code}
            {:error, reason} -> {:opencode_install, reason}
          end

        assert {:error, ^expected} = OpenCode.prepare_sandbox(@handle, nil, [])
      end
    end
  end

  describe "ACP.install/3 for an adapter runtime" do
    test "installs the exact pinned version and symlinks it onto PATH" do
      test = self()

      expect(Sandbox, :exec, fn @handle, "bash", ["-lc", script], opts ->
        send(test, {:exec, script, opts})
        {:ok, "0.75.1", 0}
      end)

      assert :ok = ACP.install(@handle, "claude", [{"X", "1"}])

      assert_receive {:exec, script, opts}
      assert opts[:env] == [{"X", "1"}]
      assert script =~ "want=0.75.1"

      assert script =~
               "npm install -g --no-progress --silent @agentclientprotocol/claude-agent-acp@0.75.1"

      assert script =~ "/home/sprite/.local/bin/claude-agent-acp"
    end

    test "codex installs its own adapter the same way" do
      expect(Sandbox, :exec, fn _h, _c, ["-lc", script], _o ->
        assert script =~ "@agentclientprotocol/codex-acp@1.10.0"
        assert script =~ "bin=/home/sprite/.local/bin/codex-acp"
        {:ok, "", 0}
      end)

      assert :ok = ACP.install(@handle, "codex", [])
    end

    test "a package-prefixed version skips npm when the pin is already installed" do
      dir = Path.join(System.tmp_dir!(), "acp-pin-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(
        Path.join(dir, "codex-acp"),
        "#!/bin/sh\necho '@agentclientprotocol/codex-acp 1.10.0'\n"
      )

      File.chmod!(Path.join(dir, "codex-acp"), 0o755)

      expect(Sandbox, :exec, fn _h, _c, ["-lc", script], _o ->
        script = String.replace(script, "/home/sprite/.local/bin", dir)
        # A forbidden npm call fails locally; no real package manager runs.
        script = "npm() { echo unexpected-install; return 91; }\n" <> script
        {output, code} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
        assert code == 0
        refute output =~ "unexpected-install"
        {:ok, output, code}
      end)

      assert :ok = ACP.install(@handle, "codex", [])
    end

    test "a failed install names the exit code and the first 500 bytes of output" do
      long = String.duplicate("e", 600)
      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, long, 1} end)

      assert {:error, {:acp_adapter_install_exit, 1, out}} = ACP.install(@handle, "claude", [])
      assert byte_size(out) == 500

      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:error, :unavailable} end)
      assert {:error, {:acp_adapter_install, :unavailable}} = ACP.install(@handle, "claude", [])
    end
  end
end
