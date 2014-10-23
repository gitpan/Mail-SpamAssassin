#!/usr/bin/perl

use lib '.'; use lib 't';
use SATest; sa_t_init("spf");
use Test;

use constant TEST_ENABLED => (-e 't/do_net');
use constant HAS_SPFQUERY => eval { require Mail::SPF::Query; };

BEGIN {
  
  plan tests => ((TEST_ENABLED && HAS_SPFQUERY) ? 2 : 0);

};

exit unless (TEST_ENABLED && HAS_SPFQUERY);

# ---------------------------------------------------------------------------

%patterns = (
    q{ SPF_HELO_PASS }, 'helo_pass',
    q{ SPF_PASS }, 'pass',
);

sarun ("-t < data/nice/spf1", \&patterns_run_cb);
ok_all_patterns();

