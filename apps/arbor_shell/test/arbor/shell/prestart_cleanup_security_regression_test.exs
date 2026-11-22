Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.PrestartCleanupSecurityRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  @moduletag :fast
  @moduletag :security_regression
  @moduletag timeout: 120_000
  @moduletag skip: not match?({:unix, :darwin}, :os.type())

  # The private translation unit includes the actual production C. Its only
  # synchronization seam delegates (or gates before) the real kill syscall.
  # No production helper name, source-string policy assertion, or START frame.
  @fixture_c ~S'''
  #ifdef __APPLE__
  #define _DARWIN_C_SOURCE
  #endif
  /* PRIVATE ONLY: transparent signal checkpoint around included production C. */
  #include <sys/types.h>
  #include <signal.h>
  #include <unistd.h>
  #include <stddef.h>
  #include <sys/proc.h>
  #include <sys/proc_info.h>
  _Static_assert(PROC_PIDTBSDINFO == 3, "Darwin metadata flavor");
  _Static_assert(sizeof(struct proc_bsdinfo) == 136, "Darwin metadata size");
  _Static_assert(offsetof(struct proc_bsdinfo, pbi_pid) == 12, "Darwin PID offset");
  _Static_assert(offsetof(struct proc_bsdinfo, pbi_uid) == 20, "Darwin UID offset");
  _Static_assert(offsetof(struct proc_bsdinfo, pbi_pgid) == 100, "Darwin PGID offset");
  _Static_assert(offsetof(struct proc_bsdinfo, pbi_start_tvsec) == 120, "Darwin birth seconds offset");
  _Static_assert(offsetof(struct proc_bsdinfo, pbi_start_tvusec) == 128, "Darwin birth microseconds offset");
  _Static_assert(SSTOP == 4 && SZOMB == 5, "Darwin process states");
  #ifndef PRODUCTION_LAUNCHER_SOURCE
  #error "Root must pin the production source include"
  #endif
  #ifndef FIXTURE_GATE_ROOT
  #error "Root must pin the fresh owned regression output root"
  #endif
  static pid_t fixture_parent;
  static int fixture_exec, fixture_checkpointed, fixture_before_kill;
  static char fixture_gate_dir[4096];
  static int fixture_kill(pid_t pid, int sig);
  #define main production_launcher_main
  #define kill fixture_kill
  #include PRODUCTION_LAUNCHER_SOURCE
  #undef kill
  #undef main

  static void fixture_checkpoint(pid_t pid, int sig, int phase, int result) {
    char armed[4096], temporary[4096], checkpoint[4096], release[4096];
    (void)snprintf(armed, sizeof(armed), "%s/armed", fixture_gate_dir);
    if (access(armed, F_OK) != 0) return;
    fixture_checkpointed = 1;
    (void)snprintf(temporary, sizeof(temporary), "%s/signal.tmp", fixture_gate_dir);
    (void)snprintf(checkpoint, sizeof(checkpoint), "%s/signal.txt", fixture_gate_dir);
    (void)snprintf(release, sizeof(release), "%s/release", fixture_gate_dir);
    int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) _exit(120);
    pid_t child = pid < 0 ? -pid : pid;
    if (dprintf(fd, "%ld %ld %d %d %d\n", (long)getpid(), (long)child, sig, phase, result) < 0 ||
        fsync(fd) != 0 || close(fd) != 0 || rename(temporary, checkpoint) != 0) _exit(121);
    fd = open(release, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) _exit(122);
    char byte;
    if (read(fd, &byte, 1) != 1) _exit(123);
    close(fd);
  }

  static int fixture_kill(pid_t pid, int sig) {
    int eligible = fixture_exec && getpid() == fixture_parent && !fixture_checkpointed &&
                   pid != 0 && pid != fixture_parent;
    /* BEFORE mode never delivers this KILL until its controller releases the gate. */
    if (eligible && fixture_before_kill && sig == SIGKILL)
      fixture_checkpoint(pid, sig, 0, -999);
    int result = kill(pid, sig);
    int saved_errno = errno;
    /* AFTER mode checkpoints only after the actual first STOP/KILL succeeded. */
    if (eligible && !fixture_before_kill && result == 0 &&
        (sig == SIGSTOP || sig == SIGKILL)) fixture_checkpoint(pid, sig, 1, result);
    errno = saved_errno;
    return result;
  }

  int main(int argc, char **argv) {
    char active[4096], name[64];
    (void)snprintf(active, sizeof(active), "%s/active_case", FIXTURE_GATE_ROOT);
    int fd = open(active, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 119;
    ssize_t size = read(fd, name, sizeof(name) - 1);
    close(fd);
    if (size <= 0) return 119;
    name[size] = '\0';
    name[strcspn(name, "\n")] = '\0';
    if (strcmp(name, "after_signal") != 0 && strcmp(name, "before_kill") != 0) return 119;
    fixture_before_kill = strcmp(name, "before_kill") == 0;
    int length = snprintf(fixture_gate_dir, sizeof(fixture_gate_dir), "%s/%s", FIXTURE_GATE_ROOT, name);
    if (length < 0 || length >= (int)sizeof(fixture_gate_dir)) return 119;
    fixture_parent = getpid();
    fixture_exec = argc >= 2 && strcmp(argv[1], "exec") == 0;
    return production_launcher_main(argc, argv);
  }
  '''

  @fixture_python ~S'''
  """One native behavioral regression; Root compiles/seals the private fixture first."""
  import argparse, ctypes, errno, hashlib, json, os, select, signal, stat, struct
  import subprocess, sys, time, unittest
  from pathlib import Path

  CONFIG = None
  DARWIN_SSTOP = 4
  DARWIN_SZOMB = 5

  def sha(path):
      return hashlib.sha256(Path(path).read_bytes()).hexdigest()

  def need(value, label):
      if not value:
          raise RuntimeError(label)

  class BSDInfo(ctypes.Structure):
      _fields_ = [(n, ctypes.c_uint32) for n in (
          'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid',
          'svuid', 'svgid', 'rfu')] + [('comm', ctypes.c_char * 16),
          ('name', ctypes.c_char * 32)] + [(n, ctypes.c_uint32) for n in (
          'nfiles', 'pgid', 'pjobc', 'tty', 'tpgid')] + [
          ('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64),
          ('start_usec', ctypes.c_uint64)]

  LIBPROC = None

  def metadata(pid):
      need(type(pid) is int and pid > 1, 'non-owned PID input')
      record = BSDInfo()
      ctypes.set_errno(0)
      size = LIBPROC.proc_pidinfo(pid, 3, 0, ctypes.byref(record), ctypes.sizeof(record))
      if size == 0 and ctypes.get_errno() == errno.ESRCH:
          return None
      need(size == 136 and record.pid == pid, 'owned PID metadata unavailable')
      need(record.start_sec > 0 and record.start_usec < 1000000, 'invalid kernel birth')
      return {k: int(getattr(record, k)) for k in (
          'pid', 'ppid', 'uid', 'pgid', 'status', 'start_sec', 'start_usec')}

  def same_birth(a, b):
      return a is not None and b is not None and all(a[k] == b[k] for k in (
          'pid', 'uid', 'pgid', 'start_sec', 'start_usec'))

  def wait_until(function, seconds):
      end = time.monotonic() + seconds
      while time.monotonic() < end:
          value = function()
          if value:
              return value
          time.sleep(0.01)
      return None

  def read_exact(stream, count, deadline):
      data = b''
      while len(data) < count:
          remaining = deadline - time.monotonic()
          need(remaining > 0 and select.select([stream], [], [], remaining)[0], 'READY deadline')
          chunk = os.read(stream.fileno(), count - len(data))
          need(chunk, 'EOF before READY')
          data += chunk
      return data

  def read_available(stream, limit=65536):
      # A stopped inherited writer may keep this pipe open: EOF is NOT required.
      data = b''
      eof = False
      while select.select([stream], [], [], 0)[0]:
          need(len(data) < limit, 'bounded native output exceeded')
          chunk = os.read(stream.fileno(), min(4096, limit - len(data)))
          if not chunk:
              eof = True
              break
          data += chunk
      return data, eof

  class PreSTARTParentLoss(unittest.TestCase):
      @classmethod
      def setUpClass(cls):
          Path(CONFIG['output']).mkdir(mode=0o700, exist_ok=False)

      def test_after_actual_first_containment_signal(self):
          self.exercise('after_signal')

      def test_parent_dies_before_child_SIGKILL_is_delivered(self):
          self.exercise('before_kill')

      def exercise(self, scenario):
          p = None
          child = None
          bound = None
          result = {'status': 'HOLD', 'START_sent': False, 'cleanup_errors': [],
                    'oracle_reached': False, 'SIGCONT_sent_before_oracle': False}
          work = Path(CONFIG['output']) / scenario
          gate = work
          try:
              work.mkdir(mode=0o700, exist_ok=False)
              (Path(CONFIG['output']) / 'active_case').write_text(scenario + '\n')
              result['scenario'] = scenario
              os.mkfifo(gate / 'release', 0o600)
              target = Path('/usr/bin/true')
              st = target.stat()
              need(stat.S_ISREG(st.st_mode) and sha(target) == CONFIG['target_sha256'], 'target pin')
              cwd = gate.stat()
              argv = [CONFIG['fixture_binary'], 'exec', '10000', '1024'] + [str(v) for v in (
                  st.st_dev, st.st_ino, st.st_size, int(st.st_mtime), int(st.st_ctime), st.st_mode)]
              argv += [sha(target), str(target), str(cwd.st_dev), str(cwd.st_ino), str(gate),
                       '--', str(target)]
              need(len(argv) == 17, 'native argc')
              p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                  stderr=subprocess.PIPE, cwd=gate, start_new_session=True,
                  env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'LANG': 'C'})
              deadline = time.monotonic() + 5
              length = struct.unpack('!I', read_exact(p.stdout, 4, deadline))[0]
              need(length == 9, 'not exact READY frame')
              frame = read_exact(p.stdout, length, deadline)
              need(frame[0] == 1, 'not READY')
              child = int.from_bytes(frame[1:], 'big')
              parent = metadata(p.pid)
              bound = metadata(child)
              need(parent['ppid'] == os.getpid() and parent['uid'] == os.geteuid(), 'parent binding')
              need(bound is not None and bound['ppid'] == p.pid and bound['pgid'] == child
                   and bound['uid'] == os.geteuid(), 'READY child binding')
              result.update(parent_before=parent, child_before=bound)
              (gate / 'armed').write_text('armed after real READY; never START\n')
              p.stdin.close()                  # Real production EOF-before-START path.
              p.stdin = None
              checkpoint = gate / 'signal.txt'
              need(wait_until(checkpoint.is_file, 5), 'no real containment-signal checkpoint')
              values = checkpoint.read_text().split()
              need(len(values) == 5, 'checkpoint shape')
              parent_id, child_id, sent_signal, phase, rc = map(int, values)
              need(parent_id == p.pid and child_id == child, 'checkpoint ownership')
              if scenario == 'after_signal':
                  need(phase == 1 and rc == 0 and sent_signal in
                       (signal.SIGSTOP, signal.SIGKILL), 'actual signal checkpoint')
              else:
                  need(phase == 0 and rc == -999 and sent_signal == signal.SIGKILL,
                       'before-KILL checkpoint')
              need(same_birth(parent, metadata(p.pid)), 'parent birth changed')
              current = metadata(child)
              need(current is None or same_birth(bound, current), 'child birth changed')
              if scenario == 'before_kill':
                  need(current is not None and current['status'] != DARWIN_SZOMB,
                       'before-KILL must positively observe a still-live child')
              result.update(checkpoint_signal=sent_signal, checkpoint_phase=phase,
                            child_at_checkpoint=current,
                            child_stopped_at_checkpoint=current is not None and current['status'] == DARWIN_SSTOP,
                            SIGCONT_sent_before_oracle=False)
              p.kill()                        # Exact unreaped Popen child; never guessed PID/group.
              p.wait(timeout=5)               # Reap parent only; inherited pipes may stay open.
              tail, stdout_eof = read_available(p.stdout)
              errors, stderr_eof = read_available(p.stderr)
              result.update(parent_exit=p.returncode, stderr_bytes=len(errors),
                            stderr_sha256=hashlib.sha256(errors).hexdigest(), tail_bytes=len(tail),
                            stdout_eof_before_oracle=stdout_eof,
                            stderr_eof_before_oracle=stderr_eof)
              absent = wait_until(lambda: metadata(child) is None, 3) is True
              result['child_absent_after_parent_loss'] = absent
              result['oracle_reached'] = True
              result['no_preSTART_STOP'] = (sent_signal == signal.SIGKILL
                  if scenario == 'after_signal' else current['status'] != DARWIN_SSTOP)
              (work / 'observation.json').write_text(json.dumps(result, indent=2) + '\n')
              self.assertTrue(absent, 'positively owned preSTART child survived native-parent loss')
              self.assertTrue(result['no_preSTART_STOP'], 'preSTART child was STOPped')
              result['status'] = 'PASS_real_preSTART_EOF_parent_loss_' + scenario
          finally:
              parent_reaped = False
              child_absent = False
              if p is not None:
                  if p.stdin is not None:
                      p.stdin.close()
                      p.stdin = None
                  if p.poll() is None:
                      p.kill()                # Only the exact still-owned Popen handle.
                  try:
                      p.wait(timeout=5)       # Never wait for inherited pipe EOF here.
                      parent_reaped = True
                  except Exception:
                      result['cleanup_errors'].append('native parent reap unavailable')
              # Rescue the positively bound child BEFORE attempting final pipe drainage.
              if child is not None and bound is not None:
                  try:
                      current = metadata(child)
                      if current is not None:
                          need(same_birth(bound, current), 'refuse reused/unknown child cleanup')
                          if result['oracle_reached']:
                              result['SIGCONT_after_oracle'] = True
                          else:
                              result['SIGCONT_sent_before_oracle'] = True
                          os.kill(child, signal.SIGCONT)
                          need(wait_until(lambda: metadata(child) is None, 5), 'owned child not absent')
                      child_absent = metadata(child) is None
                  except Exception:
                      result['cleanup_errors'].append('exact owned child rescue incomplete')
              if p is not None:
                  try:
                      if parent_reaped and child_absent:
                          tail, errors = p.communicate(timeout=2)
                          result.update(final_tail_bytes=len(tail), final_stderr_bytes=len(errors),
                                        final_stderr_sha256=hashlib.sha256(errors).hexdigest())
                  except Exception:
                      result['cleanup_errors'].append('pipe EOF unavailable after proved child absence')
                  finally:
                      for stream in (p.stdout, p.stderr):
                          if stream is not None:
                              stream.close()
              result['fixture_cleanup_proved'] = (parent_reaped and child_absent and
                                                  not result['cleanup_errors'])
              if work.is_dir():
                  (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
              need(result['fixture_cleanup_proved'], 'fixture cleanup incomplete; retain owned root')
              need(sha(CONFIG['fixture_binary']) == CONFIG['fixture_binary_sha256'], 'fixture changed')
              need(sha(CONFIG['production_source']) == CONFIG['production_source_sha256'], 'source changed')

  if __name__ == '__main__':
      parser = argparse.ArgumentParser()
      parser.add_argument('--plan', required=True)
      parser.add_argument('--plan-sha256', required=True)
      parser.add_argument('--case', required=True, choices=['after_signal', 'before_kill'])
      args = parser.parse_args()
      need(Path(args.plan).is_absolute() and sha(args.plan) == args.plan_sha256, 'absolute plan pin')
      CONFIG = json.loads(Path(args.plan).read_text())
      need(sys.platform == 'darwin', 'Darwin metadata fixture only')
      need(CONFIG['schema'] == 'arbor.shell.preSTART-parent-loss-regression.v1', 'plan schema')
      need(sha(__file__) == CONFIG['test_sha256'], 'test pin')
      for path_key in ('fixture_binary', 'production_source', 'fixture_source'):
          need(Path(CONFIG[path_key]).is_absolute() and sha(CONFIG[path_key]) ==
               CONFIG[path_key + '_sha256'], 'sealed input pin')
      need(CONFIG['compiled_gate_root'] == CONFIG['output'], 'compiled gate-root binding')
      need(Path(CONFIG['output']).is_absolute() and not Path(CONFIG['output']).exists(),
           'fresh owned fixture output')
      LIBPROC = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
      LIBPROC.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                     ctypes.c_void_p, ctypes.c_int]
      LIBPROC.proc_pidinfo.restype = ctypes.c_int
      need(ctypes.sizeof(BSDInfo) == 136, 'pinned Darwin proc_bsdinfo layout')
      selected = ('test_after_actual_first_containment_signal' if args.case == 'after_signal'
                  else 'test_parent_dies_before_child_SIGKILL_is_delivered')
      unittest.main(argv=[__file__, '-v', 'PreSTARTParentLoss.' + selected])
  '''

  test "preSTART child cleanup survives native-parent death after the actual first signal" do
    run_fixture!("after_signal")
  end

  test "preSTART live child exits on pipe EOF if native parent dies before SIGKILL" do
    run_fixture!("before_kill")
  end

  defp run_fixture!(scenario) do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-prestart-regression-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    handle = Helpers.capture_handle!(root)
    result_path = Path.join([root, "run", scenario, "result.json"])

    on_exit(fn ->
      proved =
        with {:ok, bytes} <- File.read(result_path),
             {:ok, %{"fixture_cleanup_proved" => true, "cleanup_errors" => []}} <-
               Jason.decode(bytes),
             do: true

      if proved == true do
        assert :ok = Helpers.rm_fixture!(handle)
      else
        IO.puts("retained unproved owned preSTART fixture: " <> root)
      end
    end)

    c_dir = Path.expand("../../../c_src", __DIR__)
    source = Path.join(c_dir, "arbor_shell_launcher.c")

    units =
      ~w(arbor_shell_archive_stat.c arbor_shell_handle_relative_inode.c arbor_shell_trusted_path_acl.c)

    headers =
      ~w(arbor_shell_archive_stat.h arbor_shell_handle_relative_inode.h arbor_shell_trusted_path_acl.h)

    inputs = [source | Enum.map(units ++ headers, &Path.join(c_dir, &1))]
    before = Map.new(inputs, &{&1, sha!(&1)})
    fixture = Path.join(root, "prestart_parent_loss_fixture.c")
    python = Path.join(root, "test_prestart_parent_loss.py")
    binary = Path.join(root, "prestart_parent_loss_fixture")
    output = Path.join(root, "run")
    File.write!(fixture, @fixture_c, [:exclusive])
    File.write!(python, @fixture_python, [:exclusive])

    compiler = System.find_executable("cc") || flunk("C compiler not found")

    args =
      [
        "-std=c11",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-D_GNU_SOURCE",
        "-D_POSIX_C_SOURCE=200809L",
        "-I",
        c_dir,
        "-DPRODUCTION_LAUNCHER_SOURCE=" <> inspect(source),
        "-DFIXTURE_GATE_ROOT=" <> inspect(output),
        fixture
      ] ++
        Enum.map(units, &Path.join(c_dir, &1)) ++ ["-o", binary]

    {compile_output, compile_exit} = System.cmd(compiler, args, stderr_to_stdout: true)
    assert compile_exit == 0, "private production-C fixture compile failed: " <> compile_output
    File.chmod!(binary, 0o755)

    config = %{
      "schema" => "arbor.shell.preSTART-parent-loss-regression.v1",
      "test_sha256" => sha!(python),
      "fixture_source" => fixture,
      "fixture_source_sha256" => sha!(fixture),
      "production_source" => source,
      "production_source_sha256" => sha!(source),
      "fixture_binary" => binary,
      "fixture_binary_sha256" => sha!(binary),
      "output" => output,
      "compiled_gate_root" => output,
      "target_sha256" => sha!("/usr/bin/true")
    }

    plan = Path.join(root, "fixture-config.json")
    File.write!(plan, Jason.encode!(config), [:exclusive])
    python_executable = System.find_executable("python3") || flunk("Python3 not found")

    {test_output, test_exit} =
      System.cmd(
        python_executable,
        ["-B", python, "--plan", plan, "--plan-sha256", sha!(plan), "--case", scenario],
        stderr_to_stdout: true
      )

    assert Map.new(inputs, &{&1, sha!(&1)}) == before
    assert File.regular?(result_path), "fixture omitted result: " <> test_output
    result = result_path |> File.read!() |> Jason.decode!()

    IO.puts(
      "preSTART-native-regression " <>
        Jason.encode!(%{
          "scenario" => scenario,
          "production_C_sha256" => before[source],
          "fixture_C_sha256" => sha!(fixture),
          "binary_sha256" => config["fixture_binary_sha256"],
          "result" => result
        })
    )

    assert result["cleanup_errors"] == [], "private fixture cleanup was incomplete"
    assert result["fixture_cleanup_proved"] == true
    assert test_exit == 0, "actual native behavioral regression failed: " <> test_output
    assert result["child_absent_after_parent_loss"] == true
    assert result["no_preSTART_STOP"] == true
    assert result["START_sent"] == false
    assert result["SIGCONT_sent_before_oracle"] == false
    refute result["SIGCONT_after_oracle"] == true
    assert String.starts_with?(result["status"], "PASS_real_preSTART_EOF_parent_loss_")
  end

  defp sha!(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
end

defmodule Arbor.Shell.PrestartProtocolSecurityRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Shell
  alias Arbor.Shell.{ExecutablePolicy, Executor, OwnedTreeRegistry, ProcessGroup, TrustedBuild}
  alias Arbor.Shell.TrustedBuild.Lease
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  @moduletag :fast
  @moduletag :security_regression
  @moduletag timeout: 120_000
  @moduletag skip: not match?({:unix, :darwin}, :os.type())

  @protocol_c ~S'''
  #ifdef __APPLE__
  #define _DARWIN_C_SOURCE
  #endif
  #include <arpa/inet.h>
  #include <errno.h>
  #include <fcntl.h>
  #include <limits.h>
  #include <poll.h>
  #include <signal.h>
  #include <stdint.h>
  #include <stdio.h>
  #include <string.h>
  #include <sys/stat.h>
  #include <time.h>
  #include <unistd.h>

  #if !defined(FIXTURE_ROOT) || !defined(FIXTURE_SCOPE) || !defined(NATIVE_DELEGATE) || !defined(FIXTURE_MODE)
  #error "Four literal private fixture bindings are required"
  #endif

  /* Test-private producer only: no fork, START, argv/env log or product hook. */
  enum { TAG_TERMINAL = 3, TAG_ERROR = 4, CMD_CANCEL = 12,
         REASON_TIMEOUT = 1, REASON_CANCELLED = 3 };

  static int64_t now_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return -1;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
  }

  static int write_all(int fd, const void *bytes, size_t count) {
    const uint8_t *p = bytes;
    while (count) {
      ssize_t n = write(fd, p, count);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) return -1;
      p += (size_t)n;
      count -= (size_t)n;
    }
    return 0;
  }

  static int path_for(char *out, size_t size, const char *leaf) {
    int n = snprintf(out, size, "%s/%s", FIXTURE_ROOT, leaf);
    return n >= 0 && (size_t)n < size ? 0 : -1;
  }

  /* Publish complete numeric content without replacing an earlier owner's row. */
  static int numeric_checkpoint(const char *leaf, long number) {
    char target[PATH_MAX], temporary[PATH_MAX], temp_leaf[64], text[64];
    int n = snprintf(temp_leaf, sizeof(temp_leaf), "%s.tmp", leaf);
    if (n < 0 || (size_t)n >= sizeof(temp_leaf) ||
        path_for(target, sizeof(target), leaf) != 0 ||
        path_for(temporary, sizeof(temporary), temp_leaf) != 0) return -1;
    int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    n = snprintf(text, sizeof(text), "%ld\n", number);
    int ok = n > 0 && (size_t)n < sizeof(text) &&
             write_all(fd, text, (size_t)n) == 0 && fsync(fd) == 0;
    if (close(fd) != 0) ok = 0;
    if (!ok || link(temporary, target) != 0) { (void)unlink(temporary); return -1; }
    return unlink(temporary);
  }

  static int await_release(void) {
    char path[PATH_MAX];
    if (path_for(path, sizeof(path), "release") != 0) return -1;
    int64_t begin = now_ms();
    if (begin < 0) return -1;
    int64_t deadline = begin + 10000;
    for (;;) {
      int64_t now = now_ms();
      if (now < 0 || now >= deadline) return -1;
      struct stat s;
      if (lstat(path, &s) == 0)
        return S_ISREG(s.st_mode) && s.st_uid == geteuid() && s.st_nlink == 1 ? 0 : -1;
      if (errno != ENOENT) return -1;
      struct pollfd p = {.fd = STDIN_FILENO, .events = POLLIN | POLLHUP | POLLERR, .revents = 0};
      int rc = poll(&p, 1, 10);
      if (rc < 0) { if (errno == EINTR) continue; return -1; }
      if (p.revents & (POLLHUP | POLLERR | POLLNVAL)) return -1;
      /* POLLIN may be the queued CANCEL: never consume it while gated. */
      if (p.revents & POLLIN) {
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000};
        (void)nanosleep(&delay, NULL);
      }
    }
  }

  static int read_control(void *out, size_t count, int64_t deadline) {
    uint8_t *p = out;
    while (count) {
      int64_t now = now_ms();
      if (now < 0 || now >= deadline) return -1;
      int remaining = (int)(deadline - now);
      struct pollfd fd = {.fd = STDIN_FILENO, .events = POLLIN | POLLHUP | POLLERR, .revents = 0};
      int rc = poll(&fd, 1, remaining);
      if (rc < 0) { if (errno == EINTR) continue; return -1; }
      if (rc == 0 || (fd.revents & (POLLERR | POLLNVAL))) return -1;
      if (!(fd.revents & (POLLIN | POLLHUP))) continue;
      ssize_t n = read(STDIN_FILENO, p, count);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) return -1;
      p += (size_t)n;
      count -= (size_t)n;
    }
    return 0;
  }

  static int frame(uint8_t tag, const void *body, size_t count) {
    if (count > 1024) return -1;
    uint32_t length = htonl((uint32_t)count + 1);
    return write_all(STDOUT_FILENO, &length, 4) == 0 &&
           write_all(STDOUT_FILENO, &tag, 1) == 0 &&
           write_all(STDOUT_FILENO, body, count) == 0 ? 0 : -1;
  }

  static int terminal(uint8_t reason) {
    uint8_t payload[10] = {0};
    uint32_t code = htonl(137);
    payload[0] = reason;
    memcpy(payload + 1, &code, sizeof(code));
    return frame(TAG_TERMINAL, payload, sizeof(payload));
  }

  int main(int argc, char **argv) {
    int selected =
        (argc >= 17 && strcmp(argv[1], "exec") == 0 && strcmp(argv[15], "--") == 0 &&
         strcmp(argv[14], FIXTURE_SCOPE) == 0) ||
        (argc >= 100 && strcmp(argv[1], "trusted-build") == 0 && strcmp(argv[98], "--") == 0 &&
         strcmp(argv[52], FIXTURE_SCOPE) == 0);
    if (!selected) { argv[0] = (char *)NATIVE_DELEGATE; execv(NATIVE_DELEGATE, argv); return 127; }
    if (FIXTURE_ROOT[0] != '/' || FIXTURE_SCOPE[0] != '/' || NATIVE_DELEGATE[0] != '/') return 126;
    int known = strcmp(FIXTURE_MODE, "error") == 0 || strcmp(FIXTURE_MODE, "zero") == 0 ||
        strcmp(FIXTURE_MODE, "malformed") == 0 || strcmp(FIXTURE_MODE, "term_nonzero") == 0 ||
        strcmp(FIXTURE_MODE, "cancel") == 0 || strcmp(FIXTURE_MODE, "timeout") == 0;
    if (!known || signal(SIGPIPE, SIG_IGN) == SIG_ERR ||
        numeric_checkpoint("parent.pid", (long)getpid()) != 0 || await_release() != 0) return 126;
    if (strcmp(FIXTURE_MODE, "zero") == 0) return 0;
    if (strcmp(FIXTURE_MODE, "error") == 0) {
      static const char message[] = "private preSTART fixture error";
      return frame(TAG_ERROR, message, sizeof(message) - 1) == 0 ? 0 : 126;
    }
    if (strcmp(FIXTURE_MODE, "malformed") == 0) {
      uint8_t invalid = 255;
      return frame(TAG_TERMINAL, &invalid, 1) == 0 ? 0 : 126;
    }
    if (strcmp(FIXTURE_MODE, "cancel") == 0) {
      uint32_t length;
      uint8_t command;
      int64_t now = now_ms();
      if (now < 0 || read_control(&length, sizeof(length), now + 10000) != 0 ||
          ntohl(length) != 1 || read_control(&command, 1, now + 10000) != 0 ||
          numeric_checkpoint("received.tag", command) != 0 || command != CMD_CANCEL) return 126;
      return terminal(REASON_CANCELLED) == 0 ? 0 : 126;
    }
    if (terminal(strcmp(FIXTURE_MODE, "timeout") == 0 ? REASON_TIMEOUT : REASON_CANCELLED) != 0)
      return 126;
    return strcmp(FIXTURE_MODE, "term_nonzero") == 0 ? 7 : 0;
  }
  '''

  test "native ERROR before READY is an error, never a controlled terminal" do
    {result, _proof} = public_call("error", :executor)
    assert {:error, {:launcher_error, message}} = result
    assert message == "private preSTART fixture error"
  end

  test "zero native exit without TERM stays unproved under cancellation traffic and a long deadline" do
    {result, proof} = public_call("zero", :executor)
    assert {:error, :teardown_timeout} = result
    assert proof.cancellation_messages > 0
    assert proof.returned_at >= proof.released_at
    assert proof.returned_at - proof.released_at < 5_000
  end

  test "malformed preREADY TERM cannot become a controlled timeout" do
    {result, _proof} = public_call("malformed", :executor)
    assert {:error, :teardown_timeout} = result
  end

  test "valid-looking preREADY TERM cannot hide a nonzero native exit" do
    {result, _proof} = public_call("term_nonzero", :executor)
    assert {:error, :teardown_timeout} = result
  end

  test "actual CMD_CANCEL plus TERM and exit zero preserves cancellation and timeout results" do
    {cancelled, cancel_proof} = public_call("cancel", :open_cancel)
    assert cancelled == {:error, :cancelled_during_setup}
    assert cancel_proof.received_tag == 12
    {timed_out, _proof} = public_call("timeout", :executor)

    assert {:ok, %{exit_code: 137, timed_out: true, killed: true, output_limit_exceeded: false}} =
             timed_out
  end

  test "an actual registered lease retains workspace and source binding after zero exit without TERM" do
    with_lease_fixture("zero", fn lease, source_identity, workspace_identity, ctx ->
      {result, proof} =
        observed_call(ctx, {:lease, lease}, fn ->
          Shell.execute_trusted_build(lease, "deps_get")
        end)

      # Keep the admission oracle at release: shipped code falsely credited
      # setup exit as exhaustion even though its public error shape differed.
      assert match?({:error, _}, result)
      assert {:ok, %{"locked" => true, "completed_phases" => []}} = Lease.view(lease)

      assert {:error, {:cleanup_retained, :exhaustion_unproven, evidence}} =
               Shell.release_trusted_build_lease(lease)

      assert Map.take(evidence, [:path, :device, :minor_device, :inode]) ==
               Map.take(workspace_identity, [:path, :device, :minor_device, :inode])

      assert File.dir?(workspace_identity.path)
      assert {:ok, :trusted_build_source, _} = OwnedTreeRegistry.fetch(source_identity)
      assert proof.returned_at >= proof.released_at
      assert proof.returned_at - proof.released_at < 5_000
    end)
  end

  test "a registered lease with positive timeout TERM proof may clean without claiming Mix success" do
    with_lease_fixture("timeout", fn lease, source_identity, workspace_identity, ctx ->
      {result, _proof} =
        observed_call(ctx, {:lease, lease}, fn ->
          Shell.execute_trusted_build(lease, "deps_get")
        end)

      assert {:ok, %{exit_code: 137, timed_out: true, killed: true}} = result
      assert {:ok, %{"locked" => true, "completed_phases" => []}} = Lease.view(lease)
      assert :ok = Shell.release_trusted_build_lease(lease)
      refute File.exists?(workspace_identity.path)
      assert {:ok, :unbound, _} = OwnedTreeRegistry.fetch(source_identity)
    end)
  end

  defp public_call(mode, kind) do
    with_protocol_fixture(mode, nil, fn ctx ->
      observed_call(ctx, {:caller, self()}, fn ->
        case kind do
          :executor ->
            Executor.run_direct("true", [],
              cwd: ctx.scope,
              timeout: 30_000,
              clear_env: true,
              env: %{}
            )

          :open_cancel ->
            {:ok, executable} = ExecutablePolicy.resolve("true")
            send(self(), {:cancel_shell_execution, nil})

            ProcessGroup.open(
              executable,
              [],
              [cwd: ctx.scope, clear_env: true, env: %{}],
              System.monotonic_time(:millisecond),
              30_000,
              1024
            )
        end
      end)
    end)
  end

  defp observed_call(ctx, owner, call) do
    caller = self()
    token = make_ref()

    observer =
      Task.async(fn ->
        try do
          pid_text =
            wait_until!(
              fn ->
                case File.read(Path.join(ctx.root, "parent.pid")) do
                  {:ok, bytes} -> bytes
                  _ -> false
                end
              end,
              10_000
            )

          {pid, ""} = pid_text |> String.trim() |> Integer.parse()
          assert pid > 1
          wait_until!(fn -> connected_fixture_port(owner, ctx.launcher, pid) end, 5_000)
          released_at = System.monotonic_time(:millisecond)
          File.write!(Path.join(ctx.root, "release"), "release\n", [:exclusive])
          wait_until!(fn -> exact_pid_absent?(pid) end, 15_000)
          exit_observed_at = System.monotonic_time(:millisecond)

          File.write!(Path.join(ctx.root, "producer.absent"), Integer.to_string(pid), [:exclusive])

          count =
            if ctx.mode == "zero" and elem(owner, 0) == :caller,
              do: cancel_traffic(caller, token, System.monotonic_time(:millisecond) + 5_000, 0),
              else: 0

          received =
            case File.read(Path.join(ctx.root, "received.tag")) do
              {:ok, bytes} -> bytes |> String.trim() |> String.to_integer()
              _ -> nil
            end

          {:ok,
           %{
             owned_pid: pid,
             released_at: released_at,
             exit_observed_at: exit_observed_at,
             received_tag: received,
             cancellation_messages: count
           }}
        rescue
          error -> {:error, Exception.message(error)}
        catch
          kind, _reason -> {:error, kind}
        end
      end)

    {result, returned_at} =
      try do
        {call.(), System.monotonic_time(:millisecond)}
      after
        send(observer.pid, {:stop_traffic, token})
      end

    assert {:ok, proof} = Task.await(observer, 30_000)
    {result, Map.put(proof, :returned_at, returned_at)}
  end

  defp cancel_traffic(caller, token, deadline, count) do
    receive do
      {:stop_traffic, ^token} -> count
    after
      1 ->
        if System.monotonic_time(:millisecond) < deadline do
          send(caller, {:cancel_shell_execution, nil})
          cancel_traffic(caller, token, deadline, count + 1)
        else
          count
        end
    end
  end

  defp connected_fixture_port({:caller, owner}, launcher, pid) do
    monitors =
      case Process.info(owner, :monitored_by) do
        {:monitored_by, values} -> values
        _ -> []
      end

    actors = [
      owner
      | Enum.filter(monitors, fn actor ->
          if is_pid(actor) do
            case Process.info(actor, :monitors) do
              {:monitors, values} -> Enum.member?(values, {:process, owner})
              _ -> false
            end
          else
            false
          end
        end)
    ]

    find_connected_port(actors, launcher, pid)
  end

  defp connected_fixture_port({:lease, lease}, launcher, pid) do
    state = :sys.get_state(lease.worker, 5_000)
    assert state.owner == lease.owner

    if state.port_owner_registered and is_pid(state.port_owner_pid) do
      find_connected_port([state.port_owner_pid], launcher, pid)
    else
      false
    end
  end

  defp find_connected_port(actors, launcher, pid) do
    Enum.find_value(actors, false, fn actor ->
      case Process.info(actor, :links) do
        {:links, links} ->
          Enum.find(links, fn port ->
            is_port(port) and Port.info(port, :connected) == {:connected, actor} and
              Port.info(port, :name) == {:name, String.to_charlist(launcher)} and
              Port.info(port, :os_pid) == {:os_pid, pid}
          end)

        _ ->
          false
      end
    end)
  end

  defp exact_pid_absent?(pid) do
    case System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "stat="],
           stderr_to_stdout: true
         ) do
      {bytes, 1} -> String.trim(bytes) == ""
      {_bytes, 0} -> false
      _ -> flunk("owned PID metadata unavailable")
    end
  end

  defp wait_until!(fun, timeout),
    do: wait_until_loop!(fun, System.monotonic_time(:millisecond) + timeout)

  defp wait_until_loop!(fun, deadline) do
    case fun.() do
      value when value not in [false, nil] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("owned protocol fixture observation incomplete")
        else
          receive do
          after
            10 -> :ok
          end

          wait_until_loop!(fun, deadline)
        end
    end
  end

  defp with_protocol_fixture(mode, scope, fun) do
    original_paths = :code.get_path()
    original_ebin = :arbor_shell |> :code.lib_dir() |> to_string() |> Path.join("ebin")
    original_priv = :arbor_shell |> :code.priv_dir() |> to_string()
    original_native = Path.join(original_priv, "arbor_shell_launcher")
    original_identity = file_identity!(original_native)

    root =
      Path.join(
        Helpers.canonical_tmp_dir!(),
        "arbor-prestart-protocol-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    handle = Helpers.capture_handle!(root)
    ebin = Path.join([root, "arbor_shell", "ebin"])
    priv = Path.join([root, "arbor_shell", "priv"])
    launcher = Path.join(priv, "arbor_shell_launcher")
    scope = scope || root
    ctx = %{root: root, scope: scope, mode: mode, launcher: launcher}

    restore = fn ->
      assert true == :code.replace_path(:arbor_shell, String.to_charlist(original_ebin))
      assert :code.get_path() == original_paths
      assert to_string(:code.priv_dir(:arbor_shell)) == original_priv
      assert file_identity!(original_native) == original_identity
    end

    on_exit(fn ->
      restore.()

      if File.regular?(Path.join(root, "producer.absent")) do
        assert :ok = Helpers.rm_fixture!(handle)
      else
        IO.puts("retained unproved protocol fixture: " <> root)
      end
    end)

    File.mkdir_p!(ebin)
    File.mkdir_p!(priv)
    modules = Application.spec(:arbor_shell, :modules)
    assert is_list(modules) and modules != []

    for module <- modules do
      Code.ensure_loaded!(module)
      source = Path.join(original_ebin, Atom.to_string(module) <> ".beam")
      destination = Path.join(ebin, Path.basename(source))
      File.cp!(source, destination)
      assert hash!(source) == hash!(destination)
    end

    File.cp!(Path.join(original_ebin, "arbor_shell.app"), Path.join(ebin, "arbor_shell.app"))
    delegate = Path.join(priv, "native-original")
    File.cp!(original_native, delegate)
    File.chmod!(delegate, 0o755)
    assert hash!(delegate) == elem(original_identity, 1)
    fixture = Path.join(root, "protocol_fixture.c")
    File.write!(fixture, @protocol_c, [:exclusive])
    sdk = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
    compiler = System.find_executable("cc") || flunk("C compiler not found")

    args = [
      "-isysroot",
      sdk,
      "-std=c11",
      "-O2",
      "-Wall",
      "-Wextra",
      "-Werror",
      "-D_GNU_SOURCE",
      "-D_POSIX_C_SOURCE=200809L",
      "-DFIXTURE_ROOT=" <> inspect(root),
      "-DFIXTURE_SCOPE=" <> inspect(scope),
      "-DNATIVE_DELEGATE=" <> inspect(delegate),
      "-DFIXTURE_MODE=" <> inspect(mode),
      fixture,
      "-o",
      launcher
    ]

    {output, status} = System.cmd(compiler, args, stderr_to_stdout: true)
    assert status == 0, "private protocol producer compile failed: " <> output
    File.chmod!(launcher, 0o755)

    try do
      assert true == :code.replace_path(:arbor_shell, String.to_charlist(ebin))
      assert to_string(:code.priv_dir(:arbor_shell)) == priv
      fun.(ctx)
    after
      restore.()
    end
  end

  defp file_identity!(path) do
    {:ok, value} = File.lstat(path, time: :posix)
    assert value.type == :regular

    fields =
      Map.take(Map.from_struct(value), [
        :type,
        :size,
        :mode,
        :links,
        :major_device,
        :minor_device,
        :inode,
        :uid,
        :gid,
        :mtime,
        :ctime
      ])

    {fields, hash!(path)}
  end

  defp hash!(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp with_lease_fixture(mode, fun) do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    handle = Helpers.handle_for_owned!(identity)

    on_exit(fn ->
      if File.exists?(identity.path),
        do: IO.puts("retained owned Lease fixture: " <> identity.path)
    end)

    project = """
    defmodule TrustedBuildFixture.MixProject do
      use Mix.Project
      def project, do: [app: :trusted_build_fixture, version: "0.1.0"]
      def application, do: []
    end
    """

    Helpers.plant_production_child_project!(
      Path.join(parent, "source"),
      project,
      "defmodule TrustedBuildFixture, do: def hello, do: :ok\n"
    )

    :ok = Helpers.plant_fixed_overlay!(identity.path)

    request = %{
      "schema" => "arbor.shell.trusted_build.request.v1",
      "source" => %{
        "schema" => "arbor.shell.trusted_build.source.v1",
        "identity" => %{
          "path" => identity.path,
          "type" => "directory",
          "device" => identity.device,
          "minor_device" => identity.minor_device,
          "inode" => identity.inode
        }
      }
    }

    {:ok, lease, _view} = TrustedBuild.acquire(request, :omit_hex_seed)
    state = :sys.get_state(lease.worker, 5_000)
    workspace = Map.take(state.roots.parent, [:path, :type, :device, :minor_device, :inode])
    scope = state.identities.source.path
    on_exit(fn -> assert :ok = Helpers.stop_retained_worker(lease.worker) end)

    try do
      with_protocol_fixture(mode, scope, fn ctx ->
        cleanup = fn -> cleanup_test_lease!(lease, identity, workspace, handle, ctx.root) end
        on_exit(cleanup)

        try do
          fun.(lease, identity, workspace, ctx)
        after
          cleanup.()
        end
      end)
    after
      assert :ok = Helpers.stop_retained_worker(lease.worker)
    end
  end

  defp cleanup_test_lease!(lease, identity, workspace, handle, fixture_root) do
    assert :ok = Helpers.stop_retained_worker(lease.worker)

    if File.regular?(Path.join(fixture_root, "producer.absent")) do
      # The retention oracle has already run. This is test-owned teardown,
      # never Lease exhaustion evidence or permission to clean an active job.
      for tree <- [workspace, identity] do
        case OwnedTreeRegistry.fetch(tree) do
          {:ok, purpose, _generation} ->
            if purpose != :unbound,
              do: assert(:ok == OwnedTreeRegistry.cas(tree, purpose, :unbound))

            assert :ok == Shell.remove_owned_tree(tree)

          {:error, :owned_tree_not_registered} ->
            assert {:error, :enoent} = File.lstat(tree.path)
        end
      end

      assert :ok = Helpers.rm_fixture!(handle)
    else
      IO.puts("retained Lease trees because native absence is unproved: " <> identity.path)
    end
  end
end
