#!/usr/bin/perl

use lib '.'; use lib 't';
use SATest; sa_t_init("db_based_whitelist");
use Test; BEGIN { plan tests => 15 };

# ---------------------------------------------------------------------------

%is_nonspam_patterns = (
q{ Subject: Re: [SAtalk] auto-whitelisting}, 'subj',
);
%is_spam_patterns = (
q{Subject: 4000           Your Vacation Winning !}, 'subj',
);

%patterns = %is_nonspam_patterns;
$scr_test_args = "-M Mail::SpamAssassin::DBBasedAddrList";

# 3 times, to get into the whitelist:
ok (sarun ("-L -t < data/nice/002", \&patterns_run_cb)); ok_all_patterns();
ok (sarun ("-L -t < data/nice/002", \&patterns_run_cb)); ok_all_patterns();
ok (sarun ("-L -t < data/nice/002", \&patterns_run_cb)); ok_all_patterns();
ok (sarun ("-L -t < data/nice/002", \&patterns_run_cb)); ok_all_patterns();

%patterns = %is_spam_patterns;
ok (sarun ("-L -t < data/spam/004", \&patterns_run_cb)); ok_all_patterns();

