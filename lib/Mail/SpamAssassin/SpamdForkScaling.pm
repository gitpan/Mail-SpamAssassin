# spamd prefork scaling, using an Apache-based algorithm
#
# <@LICENSE>
# Copyright 2004 Apache Software Foundation
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

package Mail::SpamAssassin::SpamdForkScaling;

use strict;
use warnings;
use bytes;
use Errno qw();

use Mail::SpamAssassin::Util;
use Mail::SpamAssassin::Logger;

use vars qw {
  @PFSTATE_VARS %EXPORT_TAGS @EXPORT_OK
};

use base qw( Exporter );

@PFSTATE_VARS = qw(
  PFSTATE_ERROR PFSTATE_STARTING PFSTATE_IDLE PFSTATE_BUSY PFSTATE_KILLED
  PFORDER_ACCEPT 
);

%EXPORT_TAGS = (
  'pfstates' => [ @PFSTATE_VARS ]
);
@EXPORT_OK = ( @PFSTATE_VARS );

use constant PFSTATE_ERROR       => -1;
use constant PFSTATE_STARTING    => 0;
use constant PFSTATE_IDLE        => 1;
use constant PFSTATE_BUSY        => 2;
use constant PFSTATE_KILLED      => 3;

use constant PFORDER_ACCEPT      => 10;

###########################################################################

# we use the following protocol between the master and child processes to
# control when they accept/who accepts: server tells a child to accept with a
# PF_ACCEPT_ORDER, child responds with "B$pid\n" when it's busy, and "I$pid\n"
# once it's idle again.  In addition, the parent sends PF_PING_ORDER
# periodically to ping the child processes.  Very simple protocol.  Note that
# the $pid values are packed into 4 bytes so that the buffers are always of a
# known length; if you need to transfer longer data, assign a new protocol verb
# (the first char) and use the length of the following data buffer as the
# packed value.
use constant PF_ACCEPT_ORDER     => "A....\n";
use constant PF_PING_ORDER       => "P....\n";

# timeout for a sysread() on the command channel.  if we go this long
# without a message from the spamd parent or child, it's an error.
use constant TOUT_READ_MAX       => 300;

# interval between "ping" messages from the spamd parent to all children,
# used as a sanity check to ensure TOUT_READ_MAX isn't hit when things
# are functional.
use constant TOUT_PING_INTERVAL  => 150;

###########################################################################

sub new {
  my $class = shift;
  $class = ref($class) || $class;

  my $self = shift;
  if (!defined $self) { $self = { }; }
  bless ($self, $class);

  $self->{kids} = { };
  $self->{overloaded} = 0;
  $self->{min_children} ||= 1;
  $self->{server_last_ping} = time;

  $self;
}

###########################################################################
# Parent methods

sub add_child {
  my ($self, $pid) = @_;
  $self->set_child_state ($pid, PFSTATE_STARTING);
}

# this is called by the SIGCHLD handler in spamd.  The idea is that
# main_ping_kids etc. can mark a child as probably dead ("K" state), but until
# SIGCHLD is received, the process is still around (in some form), so it
# shouldn't be removed from the list until it's confirmed dead.
#
sub child_exited {
  my ($self, $pid) = @_;

  delete $self->{kids}->{$pid};

  # remove the child from the backchannel list, too
  $self->{backchannel}->delete_socket_for_child($pid);

  # ensure we recompute, so that we don't try to tell that child to
  # accept a request, only to find that it's died in the meantime.
  $self->compute_lowest_child_pid();
}

sub child_error_kill {
  my ($self, $pid, $sock) = @_;

  warn "prefork: killing failed child $pid ".
            ($sock ? "fd=".$sock->fileno : "");

  # close the socket and remove the child from our list
  $self->set_child_state ($pid, PFSTATE_KILLED);

  kill 'INT' => $pid
    or warn "prefork: kill of failed child $pid failed: $!\n";

  $self->{backchannel}->delete_socket_for_child($pid);
  if ($sock) {
    $sock->close;
  }

  warn "prefork: killed child $pid";
}

sub set_child_state {
  my ($self, $pid, $state) = @_;

  # I keep misreading this -- so: this says, if the child is starting, or is
  # dying, or it has an entry in the {kids} hash, then allow the state to be
  # set.  otherwise the update can be ignored.
  if ($state == PFSTATE_STARTING || $state == PFSTATE_KILLED || exists $self->{kids}->{$pid})
  {
    $self->{kids}->{$pid} = $state;
    dbg("prefork: child $pid: entering state $state");
    $self->compute_lowest_child_pid();

  } else {
    dbg("prefork: child $pid: ignored new state $state, already exited?");
  }
}

sub compute_lowest_child_pid {
  my ($self) = @_;

  my @pids = grep { $self->{kids}->{$_} == PFSTATE_IDLE }
        keys %{$self->{kids}};

  my $l = shift @pids;
  foreach my $p (@pids) {
    if ($l > $p) { $l = $p };
  }
  $self->{lowest_idle_pid} = $l;

  dbg("prefork: new lowest idle kid: ".
            ($self->{lowest_idle_pid} ? $self->{lowest_idle_pid} : 'none'));
}

###########################################################################

sub set_server_fh {
  my ($self, $fh) = @_;
  $self->{server_fh} = $fh;
  $self->{server_fileno} = $fh->fileno();
}

sub main_server_poll {
  my ($self, $tout) = @_;

  my $rin = ${$self->{backchannel}->{selector}};
  if ($self->{overloaded}) {
    # don't select on the server fh -- we already KNOW that's ready,
    # since we're overloaded
    vec($rin, $self->{server_fileno}, 1) = 0;
  }

  my ($rout, $eout, $nfound, $timeleft);

  # use alarm to back up select()'s built-in alarm, to debug theo's bug
  eval {
    Mail::SpamAssassin::Util::trap_sigalrm_fully(sub { die "tcp timeout"; });
    alarm ($tout*2) if ($tout);
    ($nfound, $timeleft) = select($rout=$rin, undef, $eout=$rin, $tout);
  };
  alarm 0;

  if ($@) {
    warn "prefork: select timeout failed! recovering\n";
    sleep 1;        # avoid overload
    return;
  }

  if (!defined $nfound) {
    warn "prefork: select returned undef! recovering\n";
    sleep 1;        # avoid overload
    return;
  }

  # errors on the handle?
  # return them immediately, they may be from a SIGHUP restart signal
  if (vec ($eout, $self->{server_fileno}, 1)) {
    warn "prefork: select returned error on server filehandle: $!\n";
    return;
  }

  # any action?
  if (!$nfound) {
    # none.  periodically ping the children though just to ensure
    # they're still alive and can hear us
    
    my $now = time;
    if ($now - $self->{server_last_ping} > TOUT_PING_INTERVAL) {
      $self->main_ping_kids($now);
    }
    return;
  }

  # were the kids ready, or did we get signal?
  if (vec ($rout, $self->{server_fileno}, 1)) {
    # dbg("prefork: server fh ready");
    # the server socket: new connection from a client
    if (!$self->order_idle_child_to_accept()) {
      # dbg("prefork: no idle kids, noting overloaded");
      # there are no idle kids!  we're overloaded, mark that
      $self->{overloaded} = 1;
    }
    return;
  }

  # otherwise it's a status report from a child.
  foreach my $fh ($self->{backchannel}->select_vec_to_fh_list($rout))
  {
    # just read one line.  if there's more lines, we'll get them
    # when we re-enter the can_read() select call above...
    if ($self->read_one_message_from_child_socket($fh) == PFSTATE_IDLE)
    {
      dbg("prefork: child reports idle");
      if ($self->{overloaded}) {
        # if we were overloaded, then now that this kid is idle,
        # we can use it to handle the waiting connection.  zero
        # the overloaded flag, anyway; if there's >1 waiting
        # conn, they'll show up next time we do the select.

        dbg("prefork: overloaded, immediately telling kid to accept");
        if (!$self->order_idle_child_to_accept()) {
          # this can happen if something is buggy in the child, and
          # it has to be killed, resulting in no idle kids left
          warn "prefork: lost idle kids, so still overloaded";
          $self->{overloaded} = 1;
        }
        else {
          dbg("prefork: no longer overloaded");
          $self->{overloaded} = 0;
        }
      }
    }
  }

  # now that we've ordered some kids to accept any new connections,
  # increase/decrease the pool as necessary
  $self->adapt_num_children();
}

sub main_ping_kids {
  my ($self, $now) = @_;

  $self->{server_last_ping} = $now;

  my ($sock, $kid);
  while (($kid, $sock) = each %{$self->{backchannel}->{kids}}) {
    $self->syswrite_with_retry($sock, PF_PING_ORDER) and next;

    warn "prefork: write of ping failed to $kid fd=".$sock->fileno.": ".$!;

    # note: this is safe according to the note in perldoc -f each; 'it is
    # always safe to delete the item most recently returned by each()'
    $self->child_error_kill($kid, $sock);
  }
}

sub read_one_message_from_child_socket {
  my ($self, $sock) = @_;

  # "I  b1 b2 b3 b4 \n " or "B  b1 b2 b3 b4 \n "
  my $line;
  my $nbytes = $self->sysread_with_timeout($sock, \$line, 6, TOUT_READ_MAX);

  if (!defined $nbytes || $nbytes == 0) {
    dbg("prefork: child closed connection");

    # stop it being select'd
    my $fno = $sock->fileno;
    if (defined $fno) {
      vec(${$self->{backchannel}->{selector}}, $fno, 1) = 0;
      $sock->close();
    }

    return PFSTATE_ERROR;
  }
  if ($nbytes < 6) {
    warn("prefork: child gave short message: len=$nbytes bytes=".
	 join(" ", unpack "C*", $line));
  }

  chomp $line;
  if ($line =~ s/^I//) {
    my $pid = unpack("N1", $line);
    $self->set_child_state ($pid, PFSTATE_IDLE);
    return PFSTATE_IDLE;
  }
  elsif ($line =~ s/^B//) {
    my $pid = unpack("N1", $line);
    $self->set_child_state ($pid, PFSTATE_BUSY);
    return PFSTATE_BUSY;
  }
  else {
    die "prefork: unknown message from child: '$line'";
    return PFSTATE_ERROR;
  }
}

###########################################################################

sub order_idle_child_to_accept {
  my ($self) = @_;

  my $kid = $self->{lowest_idle_pid};
  if (defined $kid)
  {
    my $sock = $self->{backchannel}->get_socket_for_child($kid);
    if (!$sock)
    {
      # this should not happen, but if it does, trap it here
      # before we attempt to call a method on an undef object
      warn "prefork: oops! no socket for child $kid, killing";
      $self->child_error_kill($kid, $sock);

      # retry with another child
      return $self->order_idle_child_to_accept();
    }

    if (!$self->syswrite_with_retry($sock, PF_ACCEPT_ORDER))
    {
      # failure to write to the child; bad news.  call it dead
      warn "prefork: killing rogue child $kid, failed to write on fd ".$sock->fileno.": $!\n";
      $self->child_error_kill($kid, $sock);

      # retry with another child
      return $self->order_idle_child_to_accept();
    }

    dbg("prefork: ordered $kid to accept");

    # now wait for it to say it's done that
    return $self->wait_for_child_to_accept($sock);

  }
  else {
    dbg("prefork: no spare children to accept, waiting for one to complete");
    return undef;
  }
}

sub wait_for_child_to_accept {
  my ($self, $sock) = @_;

  while (1) {
    my $state = $self->read_one_message_from_child_socket($sock);
    if ($state == PFSTATE_BUSY) {
      return 1;     # 1 == success
    }
    if ($state == PFSTATE_ERROR) {
      return undef;
    }
    else {
      die "prefork: ordered child to accept, but child reported state '$state'";
    }
  }
}

sub child_now_ready_to_accept {
  my ($self, $kid) = @_;
  if ($self->{waiting_for_idle_child}) {
    my $sock = $self->{backchannel}->get_socket_for_child($kid);
    $self->syswrite_with_retry($sock, PF_ACCEPT_ORDER)
        or die "prefork: $kid claimed it was ready, but write failed on fd ".
                            $sock->fileno.": ".$!;
    $self->{waiting_for_idle_child} = 0;
  }
}

###########################################################################
# Child methods

sub set_my_pid {
  my ($self, $pid) = @_;
  $self->{pid} = $pid;  # save calling $$ all the time
}

sub update_child_status_idle {
  my ($self) = @_;
  # "I  b1 b2 b3 b4 \n "
  $self->report_backchannel_socket("I".pack("N",$self->{pid})."\n");
}

sub update_child_status_busy {
  my ($self) = @_;
  # "B  b1 b2 b3 b4 \n "
  $self->report_backchannel_socket("B".pack("N",$self->{pid})."\n");
}

sub report_backchannel_socket {
  my ($self, $str) = @_;
  my $sock = $self->{backchannel}->get_parent_socket();
  $self->syswrite_with_retry($sock, $str)
        or write "syswrite() to parent failed: $!";
}

sub wait_for_orders {
  my ($self) = @_;

  my $sock = $self->{backchannel}->get_parent_socket();
  while (1) {
    # "A  .  .  .  .  \n "
    my $line;
    my $nbytes = $self->sysread_with_timeout($sock, \$line, 6, TOUT_READ_MAX);
    if (!defined $nbytes || $nbytes == 0) {
      if ($sock->eof()) {
        dbg("prefork: parent closed, exiting");
        exit;
      }
      die "prefork: empty order from parent";
    }
    if ($nbytes < 6) {
      warn("prefork: parent gave short message: len=$nbytes bytes=".
	   join(" ", unpack "C*", $line));
    }

    chomp $line;
    if (index ($line, "P") == 0) {  # string starts with "P" = ping
      dbg("prefork: periodic ping from spamd parent");
      next;
    }
    if (index ($line, "A") == 0) {  # string starts with "A" = accept
      return PFORDER_ACCEPT;
    }
    else {
      die "prefork: unknown order from parent: '$line'";
    }
  }
}

###########################################################################

sub sysread_with_timeout {
  my ($self, $sock, $lineref, $toread, $timeout) = @_;

  $$lineref = '';   # clear the output buffer
  my $readsofar = 0;
  my $deadline; # we only set this if the first read fails
  my $buf;

retry_read:
  my $nbytes = $sock->sysread($buf, $toread);

  if (!defined $nbytes) {
    unless ((exists &Errno::EAGAIN && $! == &Errno::EAGAIN)
        || (exists &Errno::EWOULDBLOCK && $! == &Errno::EWOULDBLOCK))
    {
      # an error that wasn't non-blocking I/O-related.  that's serious
      return undef;
    }

    # ok, we didn't get it first time.  we'll have to start using
    # select() and timeouts (which is slower).  Don't warn just yet,
    # as it's quite acceptable in our design to have to "block" on
    # sysread()s here.

    my $now = time();
    my $tout = $timeout;
    if (!defined $deadline) {
      # set this.  it'll be close enough ;)
      $deadline = $now + $timeout;
    }
    elsif ($now > $deadline) {
      # timed out!  report failure
      warn "prefork: sysread(".$sock->fileno.") failed after $timeout secs";
      return undef;
    }
    else {
      $tout = $deadline - $now;     # the remaining timeout
      $tout = 1 if ($tout <= 0);    # ensure it's > 0
    }

    dbg("prefork: sysread(".$sock->fileno.") not ready, wait max $tout secs");
    my $rin = '';
    vec($rin, $sock->fileno, 1) = 1;
    select($rin, undef, undef, $tout);
    goto retry_read;

  }
  elsif ($nbytes == 0) {        # EOF
    return $readsofar;          # may be a partial read, or 0 for EOF

  }
  elsif ($nbytes == $toread) {  # a complete read, nice.
    $readsofar += $nbytes;
    $$lineref .= $buf;
    return $readsofar;

  }
  else {
    # we want to know about this.  this is not supposed to happen!
    warn "prefork: partial read of $nbytes, toread=".$toread.
            "sofar=".$readsofar." fd=".$sock->fileno.", recovering";
    $readsofar += $nbytes;
    $$lineref .= $buf;
    $toread -= $nbytes;
    goto retry_read;
  }

  die "assert: should not get here";
}

sub syswrite_with_retry {
  my ($self, $sock, $buf) = @_;

  my $written = 0;

retry_write:
  my $nbytes = $sock->syswrite($buf);
  if (!defined $nbytes) {
    unless ((exists &Errno::EAGAIN && $! == &Errno::EAGAIN)
        || (exists &Errno::EWOULDBLOCK && $! == &Errno::EWOULDBLOCK))
    {
      # an error that wasn't non-blocking I/O-related.  that's serious
      return undef;
    }

    warn "prefork: syswrite(".$sock->fileno.") failed, retrying...";

    # give it 5 seconds to recover.  we retry indefinitely.
    my $rout = '';
    vec($rout, $sock->fileno, 1) = 1;
    select(undef, $rout, undef, 5);

    goto retry_write;
  }
  else {
    $written += $nbytes;
    $buf = substr($buf, $nbytes);

    if ($buf eq '') {
      return $written;      # it's complete, we can return
    }
    else {
      warn "prefork: partial write of $nbytes, towrite=".length($buf).
            " sofar=".$written." fd=".$sock->fileno.", recovering";
      goto retry_write;
    }
  }

  die "assert: should not get here";
}

###########################################################################
# Master server code again

# this is pretty much the algorithm from perform_idle_server_maintainance() in
# Apache's "prefork" MPM.  However: we don't do exponential server spawning,
# since our servers are a lot more heavyweight than theirs is.

sub adapt_num_children {
  my ($self) = @_;

  my $kids = $self->{kids};
  my $statestr = '';
  my $num_idle = 0;
  my @pids = sort { $a <=> $b } keys %{$kids};
  my $num_servers = scalar @pids;

  foreach my $pid (@pids) {
    my $k = $kids->{$pid};
    if ($k == PFSTATE_IDLE) {
      $statestr .= 'I';
      $num_idle++;
    }
    elsif ($k == PFSTATE_BUSY) {
      $statestr .= 'B';
    }
    elsif ($k == PFSTATE_KILLED) {
      $statestr .= 'K';
    }
    elsif ($k == PFSTATE_ERROR) {
      $statestr .= 'E';
    }
    elsif ($k == PFSTATE_STARTING) {
      $statestr .= 'S';
    }
    else {
      $statestr .= '?';
    }
  }
  info("prefork: child states: ".$statestr."\n");

  # just kill off/add one at a time, to avoid swamping stuff and
  # reacting too quickly; Apache emulation
  if ($num_idle < $self->{min_idle}) {
    if ($num_servers < $self->{max_children}) {
      $self->need_to_add_server($num_idle);
    } else {
      info("prefork: server reached --max-clients setting, consider raising it\n");
    }
  }
  elsif ($num_idle > $self->{max_idle} && $num_servers > $self->{min_children}) {
    $self->need_to_del_server($num_idle);
  }
}

sub need_to_add_server {
  my ($self, $num_idle) = @_;
  my $cur = ${$self->{cur_children_ref}};
  $cur++;
  dbg("prefork: adjust: increasing, not enough idle children ($num_idle < $self->{min_idle})");
  main::spawn();
  # servers will be started once main_server_poll() returns
}

sub need_to_del_server {
  my ($self, $num_idle) = @_;
  my $cur = ${$self->{cur_children_ref}};
  $cur--;
  my $pid;
  foreach my $k (keys %{$self->{kids}}) {
    my $v = $self->{kids}->{$k};
    if ($v == PFSTATE_IDLE)
    {
      # kill the highest; Apache emulation, exploits linux scheduler
      # behaviour (and is predictable)
      if (!defined $pid || $k > $pid) {
        $pid = $k;
      }
    }
  }

  if (!defined $pid) {
    # this should be impossible. assert it
    die "prefork: oops! no idle kids in need_to_del_server?";
  }

  # warning: race condition if these two lines are the other way around.
  # see bug 3983, comment 37 for details
  $self->set_child_state ($pid, PFSTATE_KILLED);
  kill 'INT' => $pid;

  dbg("prefork: adjust: decreasing, too many idle children ($num_idle > $self->{max_idle}), killed $pid");
}

1;

__END__
