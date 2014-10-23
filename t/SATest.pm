# common functionality for tests.
# imported into main for ease of use.

package main;

use Cwd;
use File::Path;

# Set up for testing. Exports (as global vars):
# out: $home: $HOME env variable
# out: $cwd: here
# out: $scr: spamassassin script
#
sub sa_t_init {
  my $tname = shift;

  $scr = $ENV{'SCRIPT'};
  $scr ||= "../spamassassin";

  $spamd = $ENV{'SPAMD_SCRIPT'};
  $spamd ||= "../spamd/spamd -x";

  $spamc = $ENV{'SPAMC_SCRIPT'};
  $spamc ||= "../spamd/spamc";

  $spamdport = 48373;		# whatever

  $scr_cf_args = "-c ../rules -p ../rules/user_prefs.template";
  $scr_pref_args = "";
  $scr_test_args = "";

  (-f "t/test_dir") && chdir("t");        # run from ..
  rmtree ("log");
  mkdir ("log", 0755);

  $home = $ENV{'HOME'};
  $home ||= $ENV{'WINDIR'} if (defined $ENV{'WINDIR'});
  $cwd = getcwd;

  $ENV{'TEST_DIR'} = $cwd;
  $testname = $tname;
}

sub sa_t_finish {
  # no-op currently
}

sub tstfile {
  my $file = shift;
  open (OUT, ">log/mail.txt") or die;
  print OUT $file; close OUT;
}

sub tstprefs {
  my $lines = shift;
  open (OUT, ">log/tst.cf") or die;
  print OUT $lines; close OUT;
  $scr_pref_args = "-p log/tst.cf";
}

# Run spamassassin. Calls back with the output.
# in $args: arguments to run with
# in $read_sub: callback for the output (should read from <IN>).
# This is called with no args.
#
# out: $sa_exitcode global: exitcode from sitescooper
# ret: undef if sitescooper fails, 1 for exit 0
#
sub sarun {
  my $args = shift;
  my $read_sub = shift;

  rmtree ("log/outputdir.tmp"); # some tests use this
  mkdir ("log/outputdir.tmp", 0755);

  %found = ();
  %found_anti = ();

  if (defined $ENV{'SA_ARGS'}) {
    $args = $ENV{'SA_ARGS'} . " ". $args;
  }
  $args = "$scr_cf_args $scr_pref_args $scr_test_args $args";

  # added fix for Windows tests from Rudif
  my $scrargs = "$scr $args";
  $scrargs =~ s!/!\\!g if ($^O =~ /^MS(DOS|Win)/i);
  print ("\t$scrargs\n");
  system ("$scrargs > log/$testname.${Test::ntest}");
  $sa_exitcode = ($?>>8);
  if ($sa_exitcode != 0) { return undef; }
  &checkfile ("$testname.${Test::ntest}", $read_sub);
  1;
}

sub sdrun {
  my $sdargs = shift;
  my $args = shift;
  my $read_sub = shift;

  rmtree ("log/outputdir.tmp"); # some tests use this
  mkdir ("log/outputdir.tmp", 0755);

  if (defined $ENV{'SC_ARGS'}) {
    $args = $ENV{'SC_ARGS'} . " ". $args;
  }

  start_spamd ($sdargs);

  my $spamcargs;
  if($args !~ /(?:-p\s*[0-9]+|-o)/)
  {
    $spamcargs = "$spamc -p $spamdport $args";
  }
  else
  {
    $spamcargs = "$spamc $args";
  }
  $spamcargs =~ s!/!\\!g if ($^O =~ /^MS(DOS|Win)/i);

  print ("\t$spamcargs\n");
  system ("$spamcargs > log/$testname.out");

  $sa_exitcode = ($?>>8);
  if ($sa_exitcode != 0) { return undef; }
  &checkfile ("$testname.out", $read_sub);

  stop_spamd ();

  1;
}

sub start_spamd {
  my $sdargs = shift;

  if (defined $ENV{'SD_ARGS'}) {
    $sdargs = $ENV{'SD_ARGS'} . " ". $sdargs;
  }

  my $spamdargs;
  if($sdargs !~ /(?:-p\s*[0-9]+|-o)/)
  {
    $spamdargs = "$spamd -D -p $spamdport $sdargs";
  }
  else
  {
    $spamdargs = "$spamd -D $sdargs";
  }
  $spamdargs =~ s!/!\\!g if ($^O =~ /^MS(DOS|Win)/i);

  print ("\t$spamdargs > log/$testname.spamd 2>&1 &\n");
  system ("$spamdargs > log/$testname.spamd 2>&1 &");

  # now find the PID
  $spamd_pid = 0;
  my $retries = 20;
  while ($spamd_pid <= 0) {
    if (open (IN, "<log/$testname.spamd")) {
      while (<IN>) {
	/Address already in use/ and $retries = 0;
	/server pid: (\d+)/ and $spamd_pid = $1;
      }
      close IN;
      last if ($spamd_pid);
    }

    sleep 2;
    if ($retries-- <= 0) {
      warn "spamd start failed";
      warn "\n\nMaybe you need to kill a running spamd process?\n\n";
      return 0;
    }
  }

  1;
}

sub stop_spamd {
  print ("Killed ",kill (15, $spamd_pid)," spamd instances\n");
}

# ---------------------------------------------------------------------------

sub checkfile {
  my $filename = shift;
  my $read_sub = shift;

  # print "Checking $filename\n";
  if (!open (IN, "< log/$filename")) {
    warn "cannot open log/$filename"; return undef;
  }
  &$read_sub();
  close IN;
}

# ---------------------------------------------------------------------------

sub pattern_to_re {
  my $pat = shift;
  $pat = quotemeta($pat);

  # make whitespace irrelevant; match any amount as long as the
  # non-whitespace chars are OK.
  $pat =~ s/\\\s/\\s\*/gs;
  $pat;
}

# ---------------------------------------------------------------------------

sub patterns_run_cb {
  local ($_);
  $_ = join ('', <IN>);

  foreach my $pat (sort keys %patterns) {
    my $safe = pattern_to_re ($pat);
    # print "JMD $patterns{$pat}\n";
    if ($_ =~ /${safe}/s) {
      $found{$patterns{$pat}}++;
    }
  }
  foreach my $pat (sort keys %anti_patterns) {
    my $safe = pattern_to_re ($pat);
    # print "JMD $patterns{$pat}\n";
    if ($_ =~ /${safe}/s) {
      $found_anti{$anti_patterns{$pat}}++;
    }
  }
}

sub ok_all_patterns {
  foreach my $pat (sort keys %patterns) {
    my $type = $patterns{$pat};
    print "\tChecking $type\n";
    if (defined $found{$type}) {
      ok ($found{$type} == 1) or warn "Found more than once: $type\n";
    } else {
      warn "\tNot found: $type = $pat\n";
      ok (0);                     # keep the right # of tests
    }
  }
  foreach my $pat (sort keys %anti_patterns) {
    my $type = $anti_patterns{$pat};
    print "\tChecking for anti-pattern $type\n";
    if (defined $found_anti{$type}) {
      warn "\tFound anti-pattern: $type = $pat\n";
      ok (0);
    }
    else
    {
      ok (1);
    }
  }
}

sub skip_all_patterns {
  my $skip = shift;
  foreach my $pat (sort keys %patterns) {
    my $type = $patterns{$pat};
    print "\tChecking $type\n";
    if (defined $found{$type}) {
      skip ($skip, $found{$type} == 1) or warn "Found more than once: $type\n";
      warn "\tThis test should have been skipped: $skip\n" if $skip;
    } else {
      if ($skip) {
        warn "\tTest skipped: $skip\n";
      } else {
        warn "\tNot found: $type = $pat\n";
      }
      skip ($skip, 0);                     # keep the right # of tests
    }
  }
  foreach my $pat (sort keys %anti_patterns) {
    my $type = $anti_patterns{$pat};
    print "\tChecking for anti-pattern $type\n";
    if (defined $found_anti{$type}) {
      warn "\tFound anti-pattern: $type = $pat\n";
      skip ($skip, 0);
    }
    else
    {
      skip ($skip, 1);
    }
  }
}

sub clear_pattern_counters {
  %found = ();
  %found_anti = ();
}

1;
