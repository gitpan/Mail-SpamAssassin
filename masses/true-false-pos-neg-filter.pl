#!/usr/bin/perl -w

use strict;
use warnings;

my $threshold = 5;
my %is_spam = ();
my %id_spam = ();
my %lines = ();
my %scores = ();
my $cffile = "craig-evolve.scores";

print "Reading scores...";
readscores();
print "Reading logs...";
readlogs();
print "Sorting messages...";
sortmessages();

sub sortmessages {
    my ($yy,$nn,$yn,$ny) = (0,0,0,0);

    open(YY,">truepos.log");
    open(NN,">trueneg.log");
    open(YN,">falseneg.log");
    open(NY,">falsepos.log");

    for my $count (0..scalar(keys %lines)-1) {
	
	if($is_spam{$count})
	{
	    if($id_spam{$count})
	    {
		print YY $lines{$count};
		$yy++;
	    }
	    else
	    {
		print YN $lines{$count};
		$yn++;
	    }
	}
	else
	{
	    if($id_spam{$count})
	    {
		print NY $lines{$count};
		$ny++;
	    }
	    else
	    {
		print NN $lines{$count};
		$nn++;
	    }
	}
    }

    print "$yy,$nn,$yn,$ny\n";

    close YY;
    close NY;
    close YN;
    close NN;
}

sub readlogs {
    my $count = 0;

    foreach my $file ("spam.log", "nonspam.log") {
	open (IN, "<$file");

	while (<IN>) {
	    my $this_line = $_;
	    /^.\s+(\d+)\s+\S+\s*/ or next;
	    my $hits = $1;

	    $_ = $'; #'closing quote for emacs coloring
	    s/,,+/,/g; s/^\s+//; s/\s+$//;
	    my $msg_score = 0;
	    foreach my $tst (split (/,/, $_)) {
		next if ($tst eq '');
		if (!defined $scores{$tst}) {
		    warn "unknown test in $file, ignored: $tst\n";
		    next;
		}
		$msg_score += $scores{$tst};
	    }

	    $lines{$count} = $this_line;
	    
	    if ($msg_score >= $threshold) {
		$id_spam{$count} = 1;
	    } else {
		$id_spam{$count} = 0;
	    }

	    if ($file eq "spam.log") {
		$is_spam{$count} = 1;
	    } else {
		$is_spam{$count} = 0;
	    }
	    $count++;
	} 
	close IN;
    }
    print "$count\n";
}

sub readscores {
    open (IN, "<$cffile") or warn "cannot read $cffile\n";
    while (<IN>) {
	s/#.*$//g;
	s/^\s+//;
	s/\s+$//;
	
	if (/^(header|body|full)\s+(\S+)\s+/) {
	    $scores{$2} ||= 1;
	} elsif (/^score\s+(\S+)\s+(.+)$/) {
	    $scores{$1} = $2;
	}
    }
    close IN;

    print scalar(keys %scores),"\n";
}

