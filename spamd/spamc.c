/*
 * This code is copyright 2001 by Craig Hughes
 * It is licensed for use with SpamAssassin according to the terms of the Perl Artistic License
 * The text of this license is included in the SpamAssassin distribution in the file named "License"
 */

#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <syslog.h>
#include <sysexits.h>
#include <errno.h>
#include <time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <pwd.h>

#ifndef INADDR_NONE
#define       INADDR_NONE             ((in_addr_t) 0xffffffff)
#endif

/* jm: turned off for now, it should not be necessary. */
#undef USE_TCP_NODELAY

int SAFE_FALLBACK=0;

const int ESC_MSGTOOBIG = 666;

char *msg_buf;
int amount_read;

void print_usage(void)
{
  printf("Usage: spamc [-d host] [-p port] [-f] [-h]\n");
  printf("-d host: specify host to connect to  [default: localhost]\n");
  printf("-p port: specify port for connection [default: 22874]\n");
  printf("-f: fallback safely - in case of comms error, dump original message unchanges instead of setting exitcode\n");
  printf("-s size: specify max message size, any bigger and it will be returned w/out processing [default: 250k]\n");
  printf("-h: print this help message\n");
}

int dump_message(int in,int out)
{
  size_t bytes;
  char buf[8192];

  while((bytes=read(in,buf,8192)) > 0)
  {
    if(bytes != write(out,buf,bytes))
    {
      return EX_IOERR;
    }
  }

  return (0==bytes)?EX_OK:EX_IOERR;
}

int send_message(int in,int out,char *username, int max_size)
{
  size_t bytes;

  if(NULL != username)
  {
    bytes = snprintf(msg_buf,1024,"PROCESS SPAMC/1.1\r\nUser: %s\r\n\r\n",username);
  }
  else
  {
    bytes = snprintf(msg_buf,1024,"PROCESS SPAMC/1.1\r\n\r\n");
  }

  write(out,msg_buf,bytes);

  /* Ok, now we'll read the message into the buffer up to the limit */
  /* Hmm, wonder if this'll just work ;) */
  if((bytes = read(in,msg_buf,max_size+1024)) > max_size)
  {
     /* Message is too big, so return so we can dump the message back out */
     amount_read = bytes;
     shutdown(out,SHUT_WR);
     return ESC_MSGTOOBIG;
  }

  do
  {
    write(out,msg_buf,bytes);
  } while((bytes=read(in,msg_buf,8192)) > 0);

  shutdown(out,SHUT_WR);

  return EX_OK;
}

int read_message(int in, int out)
{
  size_t bytes;
  int flag=0;
  char buf[8192];
  float version; int response=EX_OK;

  /* ch: Just call me Mr. Livingontheedge ;) fixed your bytes+1 kludge below too */
  for(bytes=0;bytes<8192;bytes++)
  {
    if(read(in,&buf[bytes],1) == 0) /* read header one byte at a time */
    {
      /* Read to end of message!  Must be because this is version <1.0 server */
      write(out,buf,bytes); /* so write out the message */
      break; /* if we break here, the while loop below will never be entered and we'll return properly */
    }
    if('\n' == buf[bytes])
    {
      buf[bytes] = '\0';	/* terminate the string */
      if(2 != sscanf(buf,"SPAMD/%f %d %*s",&version,&response))
      {
	syslog (LOG_ERR, "spamd responded with bad string '%s'", buf);
	return EX_PROTOCOL;
      }
      flag = -1; /* Set flag to show we found a header */
      break;
    }
  }
	
  if(!flag)
  {
    /* We never received a header, so it's a long message with version <1.0 server */
    write(out,buf,bytes); /* so write out the message so far */
    /* Now we'll fall into the while loop if there's more message left. */
  }

  if(EX_OK == response)
  {
    while((bytes=read(in,buf,8192)) > 0)
    {
      write(out,buf,bytes);
    }
  }

  shutdown(in,SHUT_RD);

  return response;
}

int
try_to_connect (const struct sockaddr *addr, int *sockptr)
{
#ifdef USE_TCP_NODELAY
  int value;
#endif
  int mysock;
  int origerr;

  if(-1 == (mysock = socket(PF_INET,SOCK_STREAM,0)))
  {
    origerr = errno;	/* take a copy before syslog() */
    syslog (LOG_ERR, "socket() to spamd failed: %m");
    switch(origerr)
    {
    case EPROTONOSUPPORT:
    case EINVAL:
      return EX_SOFTWARE;
    case EACCES:
      return EX_NOPERM;
    case ENFILE:
    case EMFILE:
    case ENOBUFS:
    case ENOMEM:
      return EX_OSERR;
    default:
      return EX_SOFTWARE;
    }
  }
  
#ifdef USE_TCP_NODELAY
  value = 1;		/* make this explicit! */
  if(-1 == setsockopt(mysock,0,TCP_NODELAY,&value,sizeof(value)))
  {
    switch(errno)
    {
    case EBADF:
    case ENOTSOCK:
    case ENOPROTOOPT:
    case EFAULT:
      syslog (LOG_ERR, "setsockopt() to spamd failed: %m");
      return EX_SOFTWARE;

    default:
      break;		/* ignored */
    }
  }
#endif

  if(connect(mysock,(const struct sockaddr *) addr, sizeof(*addr)) < 0)
  {
    origerr = errno;	/* take a copy before syslog() */
    syslog (LOG_ERR, "connect() to spamd failed: %m");
    switch(origerr)
    {
    case EBADF:
    case EFAULT:
    case ENOTSOCK:
    case EISCONN:
    case EADDRINUSE:
    case EINPROGRESS:
    case EALREADY:
    case EAFNOSUPPORT:
      return EX_SOFTWARE;
    case ECONNREFUSED:
    case ETIMEDOUT:
    case ENETUNREACH:
      return EX_UNAVAILABLE;
    case EACCES:
      return EX_NOPERM;
    default:
      return EX_SOFTWARE;
    }
  }

  *sockptr = mysock;

  return EX_OK;
}

int process_message(const char *hostname, int port, char *username, int max_size)
{
  int exstatus;
  int mysock;
  struct sockaddr_in addr;
  struct hostent *hent;
  int origherr;

  memset (&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);

  /* first, try to mangle it directly into an addr.  This will work
   * for numeric IP addresses, but not for hostnames...
   */
  addr.sin_addr.s_addr = inet_addr (hostname);
  if (addr.sin_addr.s_addr == INADDR_NONE) {
    /* If that failed, we can use gethostbyname() to resolve it.
     */
    if (NULL == (hent = gethostbyname(hostname))) {
      origherr = h_errno;	/* take a copy before syslog() */
      syslog (LOG_ERR, "gethostbyname(%s) failed: h_errno=%d",
		    hostname, origherr);
      switch(origherr)
      {
      case HOST_NOT_FOUND:
      case NO_ADDRESS:
      case NO_RECOVERY:
	return EX_NOHOST;
      case TRY_AGAIN:
	return EX_TEMPFAIL;
      }
    }

    memcpy (&addr.sin_addr, hent->h_addr, sizeof(addr.sin_addr));
  }

  exstatus = try_to_connect ((const struct sockaddr *) &addr, &mysock);
  if (0 == exstatus)
  {
    msg_buf = malloc(max_size);
    exstatus = send_message(STDIN_FILENO,mysock,username,max_size);
    if (0 == exstatus)
    {
      exstatus = read_message(mysock,STDOUT_FILENO);
    }
    else if(ESC_MSGTOOBIG == exstatus)
    {
      /* Message was too big, so dump the buffer then bail */
      write(STDOUT_FILENO,msg_buf,amount_read);
      dump_message(STDIN_FILENO,STDOUT_FILENO);
      exstatus = 0;
    }
    free(msg_buf);
  }
  else if(SAFE_FALLBACK) // If connection failed but SAFE_FALLBACK set then dump original message
  {
    return dump_message(STDIN_FILENO,STDOUT_FILENO);
  }

  return exstatus;	/* return the last failure code */
}

void read_args(int argc, char **argv, char **hostname, int *port, int *max_size)
{
  int opt;

  while(-1 != (opt = getopt(argc,argv,"d:p:u:hfs:")))
  {
    switch(opt)
    {
    case 'd':
      {
	*hostname = optarg;	/* fix the ptr to point to this string */
	break;
      }
    case 'p':
      {
	*port = atoi(optarg);
	break;
      }
    case 'f':
      {
	SAFE_FALLBACK = -1;
	break;
      }
    case 'u':
      {
	syslog (LOG_WARNING, "usage: -u arg obsolete, ignored");
	break;
      }
    case 's':
      {
	*max_size = atoi(optarg);
	break;
      }
    case '?': {
	syslog (LOG_ERR, "invalid usage");
	/* NOTE: falls through to usage case below... */
      }
    case 'h':
      {
	print_usage();
	exit(EX_USAGE);
      }
    }
  }
}	

int main(int argc,char **argv)
{
  int port = 22874;
  int max_size = 250*1024;
  char *hostname = "127.0.0.1";
  char *username = NULL;
  struct passwd *curr_user;

  openlog ("spamc", LOG_CONS|LOG_PID, LOG_MAIL);

  curr_user = getpwuid(getuid());
  if (curr_user == NULL) {
    perror ("getpwuid failed");
    return EX_OSERR;
  }
  username = curr_user->pw_name;

  read_args(argc,argv,&hostname,&port,&max_size);

  return process_message(hostname,port,username,max_size);
}
