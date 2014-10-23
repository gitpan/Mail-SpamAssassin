/*
 * This code is copyright 2001 by Craig Hughes
 * Portions copyright 2002 by Brad Jorsch
 * It is licensed under the same license as Perl itself.  The text of this
 * license is included in the SpamAssassin distribution in the file named
 * "License".
 */

#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>
#include <stdio.h>
#include "utils.h"

/* Dec 13 2001 jm: added safe full-read and full-write functions.  These
 * can cope with networks etc., where a write or read may not read all
 * the data that's there, in one call.
 */
/* Aug 14, 2002 bj: EINTR and EAGAIN aren't fatal, are they? */
/* Aug 14, 2002 bj: moved these to utils.c */
/* Jan 13, 2003 ym: added timeout functionality */

typedef void    sigfunc(int);   /* for signal handlers */

sigfunc* sig_catch(int sig, void (*f)(int))
{
  struct sigaction act, oact;
  act.sa_handler = f;
  act.sa_flags = 0;
  sigemptyset(&act.sa_mask);
  sigaction(sig, &act, &oact);
  return oact.sa_handler;
}

static void catch_alrm(int x) {
  /* dummy */
}

ssize_t timeout_read(ssize_t (*reader)(int d, void *buf, size_t nbytes),
                     int fd, void *buf, size_t nbytes) {
  ssize_t nred;
  sigfunc* sig;

  sig = sig_catch(SIGALRM, catch_alrm);
  if (libspamc_timeout > 0) {
    alarm(libspamc_timeout);
  }

  do {
    nred = reader(fd, buf, nbytes);
  } while(nred < 0 && errno == EAGAIN);

  if(nred < 0 && errno == EINTR)
    errno = ETIMEDOUT;

  if (libspamc_timeout > 0) {
    alarm(0);
  }

  /* restore old signal handler */
  sig_catch(SIGALRM, sig);

  return nred;
}

int
full_read (int fd, unsigned char *buf, int min, int len)
{
  int total;
  int thistime;


  for (total = 0; total < min; ) {
    thistime = timeout_read (read, fd, buf+total, len-total);

    if (thistime < 0) {
      return -1;
    } else if (thistime == 0) {
      /* EOF, but we didn't read the minimum.  return what we've read
       * so far and next read (if there is one) will return 0. */
      return total;
    }

    total += thistime;
  }
  return total;
}

int
full_write (int fd, const unsigned char *buf, int len)
{
  int total;
  int thistime;

  for (total = 0; total < len; ) {
    thistime = write (fd, buf+total, len-total);

    if (thistime < 0) {
      if(EINTR == errno || EAGAIN == errno) continue;
      return thistime;        /* always an error for writes */
    }
    total += thistime;
  }
  return total;
}
