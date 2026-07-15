/* LightSSS: lightweight simulation snapshot via copy-on-write fork().
 * See include/lightsss.h for the design overview. */
#include <lightsss.h>
#include <common.h>

#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/resource.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>

/* Implemented in cpu_exec.cc: drains the pipeline so committed stores reach
 * the host memory buffer, then writes an architectural checkpoint to `dir`.
 * Runs inside the throwaway snapshot child. */
void cpu_exec_lightsss_snapshot(const char *dir);

static int s_enabled = 0;
static char s_dir[1024] = {0};
static pid_t s_slave_pid = -1;
static int s_atexit_registered = 0;

void lightsss_configure(const char *dir)
{
  s_enabled = 1;
  if (dir != NULL && dir[0] != '\0')
  {
    strncpy(s_dir, dir, sizeof(s_dir) - 1);
    s_dir[sizeof(s_dir) - 1] = '\0';
  }
  else
  {
    strncpy(s_dir, "lightsss-snapshot", sizeof(s_dir) - 1);
  }
  /* Safety net: guarantee the snapshot child is reaped on *any* exit path so a
   * surviving child can never keep the inherited stdout/stderr pipe open and
   * hang an outer `| tee`. lightsss_finish() is idempotent / a no-op once the
   * child is gone, so registering it once is sufficient. */
  if (!s_atexit_registered)
  {
    atexit(lightsss_finish);
    s_atexit_registered = 1;
  }
  Log(FMT_GREEN("lightsss: enabled, snapshot checkpoint dir = %s"), s_dir);
}

bool lightsss_enabled(void) { return s_enabled != 0; }

/* Reap the current snapshot child, if any. `do_save` selects whether to ask
 * the child to dump its checkpoint (SIGUSR1) or silently discard (SIGTERM). */
static void reap_slave(int do_save)
{
  if (s_slave_pid <= 0)
    return;
  kill(s_slave_pid, do_save ? SIGUSR1 : SIGTERM);
  int wstatus = 0;
  while (waitpid(s_slave_pid, &wstatus, 0) < 0 && errno == EINTR)
  {
  }
  s_slave_pid = -1;
}

void lightsss_fork_at_progress(void)
{
  if (!s_enabled)
    return;

  /* Reaching a new progress point means the previous window was divergence
   * free, so the old snapshot is no longer the closest rewind point. */
  reap_slave(/*do_save=*/0);

  /* Block the control signals before forking so the child cannot miss an
   * early SIGUSR1/SIGTERM (it inherits the blocked mask and consumes them via
   * sigwait). The parent restores its own mask immediately after. */
  sigset_t set, old;
  sigemptyset(&set);
  sigaddset(&set, SIGUSR1);
  sigaddset(&set, SIGTERM);
  sigprocmask(SIG_BLOCK, &set, &old);

  fflush(NULL);
  pid_t pid = fork();
  if (pid < 0)
  {
    Error("lightsss: fork failed: %s -- snapshot disabled for this point", strerror(errno));
    sigprocmask(SIG_SETMASK, &old, NULL);
    return;
  }

  if (pid == 0)
  {
    /* Snapshot child: COW-frozen at the current progress point. Drop to the
     * lowest scheduling priority so the blocked snapshot never competes with
     * the live parent simulation for CPU. The wait itself is a sigwait(), so
     * the child sleeps in the kernel and consumes ~0 CPU until signalled. */
    if (nice(19) < 0)
    {
      /* Best-effort priority drop; ignore failure (e.g. EPERM/rlimit). */
    }
    /* Wait for the parent's verdict. SIGUSR1 -> dump checkpoint; anything
     * else -> discard. */
    int sig = 0;
    if (sigwait(&set, &sig) == 0 && sig == SIGUSR1)
    {
      cpu_exec_lightsss_snapshot(s_dir);
    }
    /* _exit() avoids running the parent's atexit/Verilator destructors and
     * flushing shared stdio buffers a second time. */
    _exit(0);
  }

  /* Parent. */
  sigprocmask(SIG_SETMASK, &old, NULL);
  s_slave_pid = pid;
}

void lightsss_trigger_save(void)
{
  if (!s_enabled || s_slave_pid <= 0)
    return;
  Log(FMT_RED("lightsss: divergence detected -- waking snapshot child (pid %d) to dump checkpoint to %s"),
      (int)s_slave_pid, s_dir);
  reap_slave(/*do_save=*/1);
  Log(FMT_GREEN("lightsss: snapshot checkpoint written; reload with --ckpt-load=%s and replay with -c 0 for a waveform of the failing window"),
      s_dir);
}

void lightsss_finish(void)
{
  reap_slave(/*do_save=*/0);
}
