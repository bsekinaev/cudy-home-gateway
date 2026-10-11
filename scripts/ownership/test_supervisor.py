"""Compile and exercise the actual Linux ownership primitive; never run PassWall."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'native/vtest-supervisor.c'
FIXTURE = r'''
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
static void *thread(void *v) { return v; }
int main(int argc, char **argv) {
    if (argc != 4 || strcmp(argv[1], "run") || strcmp(argv[2], "-c")) return 97;
    char path[1024];
    ssize_t n = readlink(argv[3], path, sizeof(path)-1);
    if (n < 0) return 98;
    path[n] = 0;
    FILE *cfg = fopen(argv[3], "r");
    if (!cfg) return 99;
    int mode = fgetc(cfg); fclose(cfg);
    char *last = strrchr(path, '/'); strcpy(last + 1, "pid");
    strcpy(last + 1, "pid.new");
    FILE *pid = fopen(path, "w");
    if (!pid) return 90;
    fprintf(pid, "%d\n", getpid());
    if (fclose(pid)) return 90;
    char final[1024]; strcpy(final, path); strcpy(strrchr(final, '/') + 1, "pid");
    if (rename(path, final)) return 90;
    strcpy(last + 1, "pid");
    if (mode == 'S') return 0;
    if (mode == 'F') return fork() == -1 && errno == EPERM ? 0 : 96;
    if (mode == 'T') {
        pthread_t t;
        if (pthread_create(&t, NULL, thread, NULL)) return 95;
        return pthread_join(t, NULL);
    }
#ifdef __x86_64__
    if (mode == 'A') {
        long value;
        __asm__ volatile("int $0x80" : "=a"(value) : "a"(20) : "memory");
        return value > 0 ? 92 : 91;
    }
#endif
    if (mode == 'D') return fcntl(42, F_GETFD) == -1 && errno == EBADF ? 0 : 94;
    if (mode == 'I') signal(SIGTERM, SIG_IGN);
    strcpy(last + 1, "heartbeat");
    unsigned tick = 0;
    for (;;) {
        FILE *pulse = fopen(path, "w");
        if (!pulse) return 93;
        fprintf(pulse, "%u\n", ++tick); fclose(pulse);
        struct timespec pause = {0, 10000000}; nanosleep(&pause, NULL);
    }
}
'''


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.runs = self.base / 'runs'
        self.runs.mkdir(mode=0o700)
        self.run_id = 'a' * 32
        self.run = self.runs / self.run_id
        self.run.mkdir(mode=0o700)
        self.config = self.run / 'config.json'
        self.write_config('S')
        self.fixture = self.base / 'xray'
        self.executable = self.base / 'supervisor'
        (self.base / 'fixture.c').write_text(FIXTURE)
        self.compile(self.base / 'fixture.c', self.fixture, ['-pthread'])
        self.compile(SOURCE, self.executable, ['-DHG_TEST_BUILD',
                     '-DXRAY_PATH="' + str(self.fixture) + '"', '-DRUN_BASE="' + str(self.runs) + '"'])

    def compile(self, source, output, flags=(), extra=()):
        subprocess.run(['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                        *flags, str(source), *map(str, extra), '-o', str(output)], check=True, capture_output=True)

    def write_config(self, mode):
        self.config.write_text(mode)
        self.config.chmod(0o600)

    def cli(self, run_id=None, seconds='1'):
        return subprocess.run([str(self.executable), run_id or self.run_id, seconds],
                              capture_output=True, text=True, timeout=5)

    def start(self, mode='I', seconds='10', **kwargs):
        self.write_config(mode)
        child = subprocess.Popen([str(self.executable), self.run_id, seconds],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, **kwargs)
        self.addCleanup(self.finish, child)
        deadline = time.monotonic() + 2
        while not (self.run / 'pid').exists() and child.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue((self.run / 'pid').exists(), child.communicate() if child.poll() is not None else '')
        pid = int((self.run / 'pid').read_text())
        return child, pid

    @staticmethod
    def finish(child):
        if child.poll() is None: child.kill()
        child.communicate(timeout=3)

    def running(self, pid):
        # The executor may mount /proc from a different PID namespace. Observe
        # this fixture's work directly; never trust/read/kill an external PID.
        del pid
        path = self.run / 'heartbeat'
        before = path.read_bytes() if path.exists() else b''
        time.sleep(0.1)
        after = path.read_bytes() if path.exists() else b''
        return after != before

    def test_success_has_fixed_output_and_no_private_paths(self):
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'DONE')
        self.assertNotIn(str(self.base), result.stdout + result.stderr)

    def test_timeout_kills_only_owned_child_even_when_term_ignored(self):
        unrelated = subprocess.Popen(['sleep', '30'])
        self.addCleanup(self.finish, unrelated)
        child, pid = self.start(seconds='1')
        out, err = child.communicate(timeout=4)
        self.assertEqual(child.returncode, 124, err)
        self.assertEqual(json.loads(out)['status'], 'TIMEOUT')
        self.assertFalse(self.running(pid))
        self.assertIsNone(unrelated.poll())

    def test_cancel_escalates_and_reaps_owned_child(self):
        child, pid = self.start()
        child.send_signal(signal.SIGTERM)
        out, err = child.communicate(timeout=3)
        self.assertEqual(child.returncode, 130, err)
        self.assertEqual(json.loads(out)['status'], 'CANCELLED')
        self.assertFalse(self.running(pid))

    def test_supervisor_sigkill_kills_child_without_cleanup_scan(self):
        child, pid = self.start()
        child.kill(); child.communicate(timeout=2)
        deadline = time.monotonic() + 2
        while self.running(pid) and time.monotonic() < deadline: time.sleep(0.01)
        self.assertFalse(self.running(pid))

    def test_new_processes_denied_and_threads_supported(self):
        for mode in ('F', 'T'):
            (self.run / 'execution.intent').unlink(missing_ok=True)
            self.write_config(mode)
            result = self.cli()
            self.assertEqual(result.returncode, 0, mode + result.stdout + result.stderr)

    @unittest.skipUnless(os.uname().machine == 'x86_64', 'x86 alternate ABI regression')
    def test_alternate_syscall_abi_kills_child(self):
        self.write_config('A')
        result = self.cli()
        self.assertEqual(result.returncode, 70)
        self.assertEqual(json.loads(result.stdout)['status'], 'FAILED')
        self.assertFalse((self.runs / 'active').exists())

    def test_inherited_ignored_sigchld_is_reset(self):
        result = subprocess.run([str(self.executable), self.run_id, '1'],
                                preexec_fn=lambda: signal.signal(signal.SIGCHLD, signal.SIG_IGN),
                                capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.runs / 'active').exists())

    def test_inherited_blocked_signals_are_unblocked_for_cancel(self):
        child, pid = self.start(preexec_fn=lambda: signal.pthread_sigmask(
            signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT, signal.SIGCHLD}))
        child.send_signal(signal.SIGTERM)
        out, err = child.communicate(timeout=3)
        self.assertEqual(child.returncode, 130, out + err)
        self.assertFalse(self.running(pid))

    def test_prelaunch_signal_does_not_consume_or_execute(self):
        hook = self.base / 'cancel-fsync.c'
        hook.write_text('#define _GNU_SOURCE\n#include <unistd.h>\n#include <signal.h>\n#include <sys/syscall.h>\nint hg_test_fsync(int fd) { int rc = syscall(SYS_fsync, fd); raise(SIGTERM); return rc; }\n')
        self.compile(SOURCE, self.executable, ['-DHG_TEST_BUILD', '-Dfsync=hg_test_fsync',
                     '-DXRAY_PATH="' + str(self.fixture) + '"', '-DRUN_BASE="' + str(self.runs) + '"'], [hook])
        result = self.cli()
        self.assertEqual(result.returncode, 130, result.stdout + result.stderr)
        self.assertFalse((self.run / 'pid').exists())
        self.assertFalse((self.run / 'execution.intent').exists())
        self.assertFalse((self.runs / 'active').exists())

    def test_cancel_during_fork_never_receives_exec_grant(self):
        hook = self.base / 'cancel-fork.c'
        hook.write_text('#define _GNU_SOURCE\n#include <unistd.h>\n#include <signal.h>\n#include <sys/syscall.h>\npid_t hg_test_fork(void) { raise(SIGTERM); return syscall(SYS_clone, SIGCHLD, 0, 0, 0, 0); }\n')
        self.compile(SOURCE, self.executable, ['-DHG_TEST_BUILD', '-Dfork=hg_test_fork',
                     '-DXRAY_PATH="' + str(self.fixture) + '"', '-DRUN_BASE="' + str(self.runs) + '"'], [hook])
        result = self.cli()
        self.assertEqual(result.returncode, 130, result.stdout + result.stderr)
        self.assertFalse((self.run / 'pid').exists())
        self.assertFalse((self.run / 'execution.intent').exists())
        self.assertFalse((self.runs / 'active').exists())

    def test_unreapable_wait_boundary_has_final_deadline_and_fence(self):
        hook = self.base / 'unreapable.c'
        hook.write_text('#include <sys/types.h>\n#include <sys/wait.h>\npid_t hg_test_waitpid(pid_t pid,int *status,int options) { (void)pid; (void)status; (void)options; return 0; }\n')
        self.compile(SOURCE, self.executable, ['-DHG_TEST_BUILD', '-Dwaitpid=hg_test_waitpid',
                     '-DXRAY_PATH="' + str(self.fixture) + '"', '-DRUN_BASE="' + str(self.runs) + '"'], [hook])
        child, pid = self.start(seconds='1')
        out, err = child.communicate(timeout=6)
        self.assertEqual(child.returncode, 70, out + err)
        self.assertEqual(json.loads(out)['status'], 'RECOVERY_REQUIRED')
        self.assertTrue((self.runs / 'active').exists())
        self.assertTrue((self.run / 'execution.intent').exists())
        self.assertFalse(self.running(pid))

    def test_inherited_descriptor_is_closed(self):
        self.write_config('D')
        with self.config.open('rb') as file:
            os.dup2(file.fileno(), 42)
            try:
                result = subprocess.run([str(self.executable), self.run_id, '1'], pass_fds=(42,),
                                        capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            finally: os.close(42)

    def test_parallel_and_replayed_runs_never_execute(self):
        child, pid = self.start()
        self.assertEqual(self.cli().returncode, 73)
        child.send_signal(signal.SIGTERM)
        child.communicate(timeout=3)
        self.assertFalse(self.running(pid))
        result = self.cli()
        self.assertEqual(result.returncode, 75)
        self.assertEqual(json.loads(result.stdout)['status'], 'RUN_ALREADY_CONSUMED')
        self.assertFalse((self.runs / 'active').exists())

    def test_sigkill_retains_global_resource_fence(self):
        child, pid = self.start()
        child.kill(); child.communicate(timeout=2)
        self.assertTrue((self.runs / 'active').exists())
        self.assertTrue((self.run / 'execution.intent').exists())
        result = self.cli()
        self.assertEqual(result.returncode, 70)
        self.assertEqual(json.loads(result.stdout)['status'], 'RECOVERY_REQUIRED')
        self.assertFalse(self.running(pid))

    def test_invalid_input_never_launches(self):
        for run_id, seconds in [('../escape', '1'), ('a' * 32, '0'), ('a' * 32, '601'), ('a' * 32, '1;id')]:
            self.assertEqual(self.cli(run_id, seconds).returncode, 2)
        self.assertFalse((self.run / 'pid').exists())

    def test_config_permissions_fifo_symlink_and_binary_symlink_rejected(self):
        self.config.chmod(0o644)
        self.assertEqual(self.cli().returncode, 70)
        self.config.unlink(); os.mkfifo(self.config, 0o600)
        self.assertEqual(self.cli().returncode, 70)
        self.config.unlink(); self.config.symlink_to(self.base / 'missing')
        self.assertEqual(self.cli().returncode, 70)
        self.config.unlink(); self.write_config('S')
        moved = self.base / 'real-xray'; self.fixture.rename(moved); self.fixture.symlink_to(moved)
        self.assertEqual(self.cli().returncode, 70)
        self.assertFalse((self.run / 'pid').exists())

    def test_untrusted_parent_or_symlink_ancestor_rejected(self):
        self.runs.chmod(0o777)
        self.assertEqual(self.cli().returncode, 70)
        self.runs.chmod(0o700)
        moved = self.base / 'real-runs'; self.runs.rename(moved); self.runs.symlink_to(moved)
        self.assertEqual(self.cli().returncode, 70)

    def test_cancel_eintr_during_intent_fsync_cleans_unlaunched_run(self):
        hook = self.base / 'cancel-intent-eintr.c'
        hook.write_text('#define _GNU_SOURCE\n#include <unistd.h>\n#include <signal.h>\n#include <errno.h>\n#include <sys/syscall.h>\nint hg_test_fsync(int fd) { static int call; if (++call == 3) { raise(SIGTERM); errno=EINTR; return -1; } return syscall(SYS_fsync, fd); }\n')
        self.compile(SOURCE, self.executable, ['-DHG_TEST_BUILD', '-Dfsync=hg_test_fsync',
                     '-DXRAY_PATH="' + str(self.fixture) + '"', '-DRUN_BASE="' + str(self.runs) + '"'], [hook])
        result = self.cli()
        self.assertEqual(result.returncode, 130, result.stdout + result.stderr)
        self.assertFalse((self.run / 'pid').exists())
        self.assertFalse((self.run / 'execution.intent').exists())
        self.assertFalse((self.runs / 'active').exists())

    def test_production_binary_disabled_without_local_authorization(self):
        production = self.base / 'production'
        self.compile(SOURCE, production)
        result = subprocess.run([str(production), self.run_id, '1'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 77)
        self.assertEqual(json.loads(result.stdout)['status'], 'DISABLED')


if __name__ == '__main__': unittest.main()
