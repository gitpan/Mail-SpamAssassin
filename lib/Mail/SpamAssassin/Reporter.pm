# Mail::SpamAssassin::Reporter - report a message as spam

package Mail::SpamAssassin::Reporter;

use Carp;
use strict;

use vars	qw{
  	@ISA
};

@ISA = qw();

###########################################################################

sub new {
  my $class = shift;
  $class = ref($class) || $class;
  my ($main, $msg, $options) = @_;

  my $self = {
    'main'		=> $main,
    'msg'		=> $msg,
    'options'		=> $options,
  };

  bless ($self, $class);
  $self;
}

###########################################################################

sub report {
  my ($self) = @_;

  my $text = $self->{main}->remove_spamassassin_markup ($self->{msg});

  if (!$self->{main}->{local_tests_only}
  	&& !$self->{options}->{dont_report_to_razor}
	&& $self->is_razor_available())
  {
    if ($self->razor_report($text)) {
      dbg ("SpamAssassin: spam reported to Razor.");
    }
  }
}

###########################################################################
# non-public methods.

sub is_razor_available {
  my ($self) = @_;
  
  eval {
    require Razor::Client;
  };
  if ($@) {
    dbg ( "Razor is not available" );
    return 0;
  } else {
    dbg ("Razor is available");
    return 1;
  }
}

sub razor_report {
  my ($self, $fulltext) = @_;

  my @msg = split (/^/m, $fulltext);
  my $config = $self->{main}->{conf}->{razor_config};
  my %options = (
    'debug'     => $Mail::SpamAssassin::DEBUG
  );
  my $response;

  # razor also debugs to stdout. argh. fix it to stderr...
  if ($Mail::SpamAssassin::DEBUG) {
    open (OLDOUT, ">&STDOUT");
    open (STDOUT, ">&STDERR");
  }

  eval {
    require Razor::Client;
    local ($^W) = 0;            # argh, warnings in Razor

    my $rc = Razor::Client->new ($config, %options);
    die "undefined Razor::Client\n" if (!$rc);

    if ($Razor::Client::VERSION >= 1.12) {
      my $respary = $rc->report ('spam' => \@msg);
      for my $resp (@$respary) { $response .= $resp; }
    } else {
      $response = $rc->report (\@msg);
    }

    dbg ("Razor: spam reported, response is \"$response\".");
  };
  
  if ($@) {
    warn "razor-report failed: $! $@";
    undef $response;
  }

  if ($Mail::SpamAssassin::DEBUG) {
    open (STDOUT, ">&OLDOUT");
    close OLDOUT;
  }

  if (defined($response) && $response+0) {
    return 1;
  } else {
    return 0;
  }
}

###########################################################################

sub dbg { Mail::SpamAssassin::dbg (@_); }

1;
