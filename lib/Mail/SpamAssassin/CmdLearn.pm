package Mail::SpamAssassin::CmdLearn;

use strict;
use bytes;

use Mail::SpamAssassin;
use Mail::SpamAssassin::ArchiveIterator;
use Mail::SpamAssassin::NoMailAudit;
use Mail::SpamAssassin::PerMsgLearner;

use Getopt::Long;
use Pod::Usage;

use vars qw(
  $spamtest %opt $isspam $forget $messagecount $messagelimit
  $rebuildonly $learnprob @targets
);

###########################################################################

sub cmdline_run {
  my ($opts) = shift;

  %opt = ();

  Getopt::Long::Configure(qw(bundling no_getopt_compat
                         permute no_auto_abbrev no_ignore_case));

  GetOptions(
	     'spam'				=> sub { $isspam = 1; },
	     'ham|nonspam'			=> sub { $isspam = 0; },
	     'rebuild'				=> \$rebuildonly,
	     'forget'				=> \$forget,
             'config-file|C=s'                  => \$opt{'config-file'},
             'prefs-file|p=s'                   => \$opt{'prefs-file'},

	     'folders|f=s'			=> \$opt{'folders'},
             'showdots'                         => \$opt{'showdots'},
	     'no-rebuild|norebuild'		=> \$opt{'norebuild'},
	     'local|L'				=> \$opt{'local'},
	     'force-expire'			=> \$opt{'force-expire'},

             'stopafter'                        => \$opt{'stopafter'},
	     'learnprob=f'			=> \$opt{'learnprob'},
	     'randseed=i'			=> \$opt{'randseed'},

             'debug-level|D'                    => \$opt{'debug-level'},
             'version|V'                        => \$opt{'version'},
             'help|h|?'                         => \$opt{'help'},

	     'dir'			=> sub { $opt{'format'} = 'dir'; },
	     'file'			=> sub { $opt{'format'} = 'file'; },
	     'mbox'			=> sub { $opt{'format'} = 'mbox'; },
	     'single'			=> sub { $opt{'format'} = 'single'; },

	     '<>'			=> \&target,
  ) or usage(0, "Unknown option!");

  if (defined $opt{'help'}) { usage(0, "For more information read the manual page"); }
  if (defined $opt{'version'}) {
    print "SpamAssassin version " . Mail::SpamAssassin::Version() . "\n";
    exit 0;
  }

  if ($opt{'force-expire'}) {
    $rebuildonly=1;
  }
  if ( !defined $isspam && !defined $rebuildonly && !defined $forget ) {
    usage(0, "Please select either --spam, --ham, --forget, or --rebuild");
  }

  if (defined($opt{'format'}) && $opt{'format'} eq 'single') {
    $opt{'format'} = 'file';
    push (@ARGV, '-');
  }

  # create the tester factory
  $spamtest = new Mail::SpamAssassin ({
    rules_filename	=> $opt{'config-file'},
    userprefs_filename  => $opt{'prefs-file'},
    debug               => defined($opt{'debug-level'}),
    local_tests_only    => 1,
    dont_copy_prefs     => 1,
    PREFIX              => $main::PREFIX,
    DEF_RULES_DIR       => $main::DEF_RULES_DIR,
    LOCAL_RULES_DIR     => $main::LOCAL_RULES_DIR,
  });

  $spamtest->init (1);

  $spamtest->init_learner({
      force_expire	=> $opt{'force-expire'},
      wait_for_lock	=> 1,
      caller_will_untie	=> 1
  });

  if ($rebuildonly) {
    $spamtest->rebuild_learner_caches({
		verbose => 1,
		showdots => \$opt{'showdots'}
    });
    $spamtest->finish_learner();
    return 0;
  }

  $messagelimit = $opt{'stopafter'};
  $learnprob = $opt{'learnprob'};

  if (defined $opt{'randseed'}) {
    srand ($opt{'randseed'});
  }

  # run this lot in an eval block, so we can catch die's and clear
  # up the dbs.
  eval {
    $SIG{INT} = \&killed;
    $SIG{TERM} = \&killed;

    if ($opt{folders}) {
      open (F, $opt{folders}) || die $!;
      while (<F>) {
	chomp;
	target($_);
      }
      close (F);
    }

    # add leftover args as targets
    foreach (@ARGV) { target($_); }

    my $iter = new Mail::SpamAssassin::ArchiveIterator ({
	'opt_j' => 1,
	'opt_n' => 1,
	'opt_all' => 1,
    });

    $iter->set_functions(\&wanted, sub { });
    $messagecount = 0;

    eval {
      $iter->run (@targets);
    };
    if ($@) { die $@ unless ($@ =~ /HITLIMIT/); }

    print STDERR "\n" if ($opt{showdots});
    warn "Learned from $messagecount messages.\n";

    if (!$opt{norebuild}) {
      $spamtest->rebuild_learner_caches();
    }
  };

  if ($@) {
    my $failure = $@;
    $spamtest->finish_learner();
    die $failure;
  }

  $spamtest->finish_learner();
  return 0;
}

sub killed {
  $spamtest->finish_learner();
  die "interrupted";
}

sub target  {
  my ($target) = @_;
  if (!defined($opt{'format'})) {
    warn "please specify target type with --dir, --file, or --mbox: $target\n";
  }
  else {
    my $class = ($isspam ? "spam" : "ham");
    push (@targets, "$class:" . $opt{'format'} . ":$target");
  }
}

###########################################################################

sub wanted {
  my ($id, $time, $dataref) = @_;

  if (defined($learnprob)) {
    if (int (rand (1/$learnprob)) != 0) {
      print STDERR '_' if ($opt{showdots});
      return;
    }
  }

  if (defined($messagelimit) && $messagecount > $messagelimit)
					{ die 'HITLIMIT'; }

  my $ma = Mail::SpamAssassin::NoMailAudit->new ('data' => $dataref);

  if ($ma->get ("X-Spam-Status")) {
    my $newtext = $spamtest->remove_spamassassin_markup($ma);
    my @newtext = split (/^/m, $newtext);
    $dataref = \@newtext;
    $ma = Mail::SpamAssassin::NoMailAudit->new ('data' => $dataref);
  }

  $ma->{noexit} = 1;
  my $status = $spamtest->learn ($ma, $id, $isspam, $forget);

  if ($status->did_learn()) {
    $messagecount++;
  }

  $status->finish();
  undef $ma;            # clean 'em up
  undef $status;

  print STDERR '.' if ($opt{showdots});
}

###########################################################################

sub usage {
    my ($verbose, $message) = @_;
    my $ver = Mail::SpamAssassin::Version();
    print "SpamAssassin version $ver\n";
    pod2usage(-verbose => $verbose, -message => $message, -exitval => 64);
}

1;
