#!/usr/bin/perl

use lib '.'; use lib 't';
use SATest; sa_t_init("razor");

use constant TEST_ENABLED => (-e 't/do_razor1' || -e 'do_razor1');
use Test; BEGIN { plan tests => TEST_ENABLED ? 2 : 0 };
exit unless TEST_ENABLED;

# ---------------------------------------------------------------------------

my $razor_not_available = 0;

eval {
	require Razor::Client;
};

if ($@) {
	$razor_not_available = "Razor1 is not installed.";
}


%patterns = (

q{ Listed in Razor v1 }, 'spam',

);

sarun ("-t < data/spam/001", \&patterns_run_cb);
skip_all_patterns($razor_not_available);

%patterns = ();
%anti_patterns = (

q{ Listed in Razor v1 }, 'nonspam',

);

sarun ("-t < data/nice/001", \&patterns_run_cb);
skip_all_patterns($razor_not_available);
