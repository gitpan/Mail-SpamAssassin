#!/usr/bin/perl -w

BEGIN {
  if (-e 't/test_dir') { # if we are running "t/rule_tests.t", kluge around ...
    chdir 't';
  }

  if (-e 'test_dir') {            # running from test directory, not ..
    unshift(@INC, '../blib/lib');
  }
}

my $prefix = '.';
if (-e 'test_dir') {            # running from test directory, not ..
  $prefix = '..';
}

use strict;
use Test;
use SATest; sa_t_init("get_headers");

use Mail::SpamAssassin;

plan tests => 11;

##############################################

# initialize SpamAssassin
my $sa = create_saobj({'dont_copy_prefs' => 1});

$sa->init(0); # parse rules

my $raw_message = <<'EOF';
To1: <jm@foo>
To2: jm@foo
To3: jm@foo (Foo Blah)
To4: jm@foo, jm@bar
To5: display: jm@foo (Foo Blah), jm@bar ;
To6: Foo Blah <jm@foo>
To7: "Foo Blah" <jm@foo>
To8: "'Foo Blah'" <jm@foo>
To9: "_$B!z8=6b$=$N>l$GEv$?$j!*!zEv_(B_$B$?$k!*!)$/$8!z7|>^%\%s%P!<!z_(B" <jm@foo>
To10: "Some User" <"Some User"@foo>
To11: "Some User"@foo

Blah!

EOF

my $mail = $sa->parse( $raw_message );
my $msg = Mail::SpamAssassin::PerMsgStatus->new($sa, $mail);

##############################################

sub try {
  my ($try, $expect) = @_;
  my $result = $msg->get($try);

  # undef might be valid in some situations, so deal with it...
  if (!defined $expect) {
    return !defined $result;
  }
  elsif (!defined $result) {
    return 0;
  }

  if ($expect eq $result) {
    return 1;
  } else {
    warn "try: '$try' failed! expect: '$expect' got: '$result'\n";
    return 0;
  }
}

ok(try('To1:addr', 'jm@foo'));
ok(try('To2:addr', 'jm@foo'));
ok(try('To3:addr', 'jm@foo'));
ok(try('To4:addr', 'jm@foo'));
ok(try('To5:addr', 'jm@foo'));
ok(try('To6:addr', 'jm@foo'));
ok(try('To7:addr', 'jm@foo'));
ok(try('To8:addr', 'jm@foo'));
ok(try('To9:addr', 'jm@foo'));
ok(try('To10:addr', '"Some User"@foo'));
ok(try('To11:addr', '"Some User"@foo'));
