#

package Mail::SpamAssassin::Dns;
1;

package Mail::SpamAssassin::PerMsgStatus;

use Mail::SpamAssassin::Conf;
use IO::Socket;
use Carp;
use strict;

use vars qw{
	$KNOWN_BAD_DIALUP_RANGES $IP_IN_RESERVED_RANGE
	$EXISTING_DOMAIN $IS_DNS_AVAILABLE
};

$EXISTING_DOMAIN = 'microsoft.com.';

$IP_IN_RESERVED_RANGE = undef;

$IS_DNS_AVAILABLE = undef;

###########################################################################

sub do_rbl_lookup {
  my ($self, $dom, $found) = @_;
  return $found if $found;

  my $q = $self->{res}->search ($dom); if ($q) {
    foreach my $rr ($q->answer) {
      if ($rr->type eq "A") {
	$self->test_log ("RBL check: found relay ".$dom);
	return ($found+1);
      }
    }
  }
  return 0;
}

# Initialize a regexp for reserved IPs, i.e. ones that could be
# used inside a company and be the first or second relay hit by
# a message. Some companies use these internally and translate
# them using a NAT firewall. These are listed in the RBL as invalid
# originators -- which is true, if you receive the mail directly
# from them; however we do not, so we should ignore them.
#
sub init_rbl_check_reserved_ips {
  return if defined ($IP_IN_RESERVED_RANGE);

  $IP_IN_RESERVED_RANGE = '^(?:';
  foreach my $top8bits (qw(
                    [012]
                    5
                    7
                    10
                    23
                    27
                    31
                    37
                    39
                    41
                    42
                    58
                    59
                    60
                    6[5-9]
                    [789][0-9]
                    1[01][0-9]
                    12[0-7]
                    197
                    21[7-9]
                    22[0-3]
                    24[0-9]
                    25[0-5]
                  ))
  {
    $IP_IN_RESERVED_RANGE .= $top8bits . '\.|';
  }
  $IP_IN_RESERVED_RANGE =~ s/\|$/\)/;
}

###########################################################################

sub is_razor_available {
  my ($self) = @_;
  my $razor_avail = 0;

  eval '
    use Razor::Signature; 
    use Razor::String;
    $razor_avail = 1;
    1;
  ';

  dbg ("is Razor available? $razor_avail");

  return $razor_avail;
}

sub razor_lookup {
  my ($self, $site, $fulltext) = @_;

  my @msg = split (/\n/, $fulltext);

  $site =~ /^(\S+):(\d+)$/;
  my $Rserver = $1;
  my $Rport   = $2;
  my $sock = new IO::Socket::INET PeerAddr => $Rserver,
				  PeerPort => $Rport, 
				  Proto    => 'tcp';
  if (!$sock) {
    dbg ("failed to connect to Razor server $Rserver:$Rport, ignoring Razor");
    return 0;
  }

  my $sig = 'x';
  my $response = '';

  eval q{
    use Razor::String;
    use Razor::Signature; 

    $sig = Razor::Signature->hash (\@msg);
    undef @msg;		# no longer needed

    my %message;
    $message{'key'} = $sig;
    $message{'action'} = "lookup";
    my $str = Razor::String::hash2str ( {%message} );

    $sock->autoflush;
    print $sock "$str\n.\n";
    $response = join ('', <$sock>);
    undef $sock;

  1;} or warn "razor check failed: $! $@";

  if ($response =~ /Positive $sig/) { return 1; }
  return 0;
}

###########################################################################

sub load_resolver {
  my ($self) = @_;

  if (defined $self->{res}) { return 1; }
  $self->{no_resolver} = 1;

  eval '
    use Net::DNS;
    $self->{res} = new Net::DNS::Resolver;
    if (defined $self->{res}) {
      $self->{no_resolver} = 0;
    }
    1;
  ';   #  or warn "eval failed: $@ $!\n";
  dbg ("is Net::DNS::Resolver unavailable? $self->{no_resolver}");

  return (!$self->{no_resolver});
}

sub lookup_mx {
  my ($self, $dom) = @_;

  return 0 unless $self->load_resolver();
  my $ret = 0;

  dbg ("looking up MX for '$dom'");
  eval '
    if (mx ($self->{res}, $dom)) { $ret = 1; }
    1;
  ' or die "MX lookup died: $@ $!\n";
  dbg ("MX for '$dom' exists? $ret");

  return $ret;
}

sub is_dns_available {
  my ($self) = @_;

  return $IS_DNS_AVAILABLE if (defined $IS_DNS_AVAILABLE);

  $IS_DNS_AVAILABLE = 0;
  goto done unless $self->load_resolver();
  goto done unless $self->lookup_mx ($EXISTING_DOMAIN);

  $IS_DNS_AVAILABLE = 1;

done:
  dbg ("is DNS available? $IS_DNS_AVAILABLE");
  return $IS_DNS_AVAILABLE;
}

###########################################################################

1;
