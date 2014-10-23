#

package Mail::SpamAssassin::EvalTests;
1;

package Mail::SpamAssassin::PerMsgStatus;

use Mail::SpamAssassin::Conf;
use Mail::SpamAssassin::Dns;
use Mail::SpamAssassin::Locales;
use Mail::SpamAssassin::PhraseFreqs;
use Mail::SpamAssassin::TextCat;
use Time::Local;
use strict;

use vars qw{
	$KNOWN_BAD_DIALUP_RANGES
	$CCTLDS_WITH_LOTS_OF_OPEN_RELAYS
	$ROUND_THE_WORLD_RELAYERS
	@PORN_WORDS
};

# persistent spam sources. These are not in the RBL though :(
$KNOWN_BAD_DIALUP_RANGES = q(
    .da.uu.net .prod.itd.earthlink.net .pub-ip.psi.net .prserv.net
);

# sad but true. sort it out, sysadmins!
$CCTLDS_WITH_LOTS_OF_OPEN_RELAYS = qr{(?:kr|cn|cl|ar|hk|il|th|tw|sg|za|tr|ma|ua|in|pe)};
$ROUND_THE_WORLD_RELAYERS = qr{(?:net|com|ca)};

# Porn words will each be prefixed with "\b" but not suffixed so as to pick up word ending variations.
# if you want \b on the end, be sure to add it yourself.
@PORN_WORDS = (qr(\blolita)i,  qr(\bcum)i, qr(\borg[iy])i, qr(\bwild)i, qr(\bfuck)i, qr(\bteen)i,
qr(\baction)i, qr(\bspunk)i, qr(\bpuss)i, qr(\bsuck)i, qr(\bhot)i,
qr(\bvoyeur)i, qr(\ble[sz]b(?:ian|o))i, qr(\banal\b)i, qr(\binterr?acial)i, qr(\basian)i,
qr(\bamateur)i, qr(\bsex+)i, qr(\bslut)i, qr(\bexplicit)i, qr(\bxxx(?:[^x]|\b))i, qr(\blive)i,
qr(\bcelebrity)i, qr(\blick)i, qr(\bsuck)i, qr(\bdorm)i, qr(\bwebcam)i, qr(\bass\b)i, qr(\bschoolgirl)i,
qr(\bstrip)i, qr(\bhorn[yi])i, qr(\berotic)i, qr(\boral)i, qr(\bpenis)i, qr(\bhard.?core)i,
qr(\bblow.?job)i, qr(\bnast[yi])i, qr(\bporn)i, qr(\bwhore)i, qr(\bnaked)i,
qr(\bnude)i, qr(\bvirgin)i, qr(\bnaught[yi])i, qr(\bgirl)i, qr(\bceleb)i, qr(\bbabe)i,
qr(\badult)i, qr(\bskank)i, qr(\btits?)i, qr(\btitties)i
);


# Here's how that RE was determined... relay rape by country (as of my
# spam collection on Dec 12 2001):
#
#     10 in     10 ua     11 ma     11 tr     11 za     12 gr
#     13 pl     14 se     15 hu     17 sg     19 dk     19 pt
#     19 th     21 us     22 hk     24 il     26 ch     27 ar
#     27 es     29 cz     32 cl     32 mx     37 nl     38 fr
#     41 it     43 ru     59 au     62 uk     67 br     70 ca
#    104 tw    111 de    123 jp    130 cn    191 kr
#
# However, since some ccTLDs just have more hosts/domains (skewing those
# figures), I cut down this list using data from
# http://www.isc.org/ds/WWW-200107/. I used both hostcount and domain counts
# for figuring this. any ccTLD with > about 40000 domains is left out of this
# regexp.  Then I threw in some unscientific seasoning to taste. ;)

###########################################################################
# HEAD TESTS:
###########################################################################

sub check_for_from_mx {
  my ($self) = @_;

  my $from = $self->get ('From:addr');
  return 0 unless ($from =~ /\@(\S+)/);
  $from = $1;

  # First check that DNS is available, if not do not perform this check
  return 0 unless $self->is_dns_available();
  $self->load_resolver();

  if ($from eq 'compiling.spamassassin.taint.org') {
    # only used when compiling
    return 0;
  }

  if ($self->{conf}->{check_mx_attempts} < 1) {
    return 0;
  }

  # Try 3 times to protect against temporary outages.  sleep between checks
  # to give the DNS a chance to recover.
  for my $i (1..$self->{conf}->{check_mx_attempts}) {
    my @mx = Net::DNS::mx ($self->{res}, $from);
    dbg ("DNS MX records found: ".scalar (@mx));
    if (scalar @mx > 0) { return 0; }
    if ($i < $self->{conf}->{check_mx_attempts}) {sleep $self->{conf}->{check_mx_delay}; };
  }

  return 1;
}

###########################################################################

sub check_for_bad_dialup_ips {
  my ($self) = @_;
  local ($_);

  my $knownbad = $KNOWN_BAD_DIALUP_RANGES;
  $knownbad =~ s/^\s+//g;
  $knownbad =~ s/\s+$//g;
  $knownbad =~ s/\./\\./g;
  $knownbad =~ s/\s+/\|/g;

  $_ = $self->get ('Received');
  /${knownbad}/o;
}

###########################################################################

sub check_for_from_to_equivalence {
  my ($self) = @_;
  my $from = $self->get ('From:addr');
  my $to = $self->get ('To:addr');

  if ($from eq '' && $to eq '') { return 0; }
  return lc($from) eq lc($to);
}

###########################################################################

# The MTA probably added the Message-ID if either of the following is true:
#
# (1) The Message-ID: comes before a Received: header.
#
# (2) The Message-ID is the first header after all Received headers and
#     the From address domain is not the same as the Message-ID domain and
#     the Message-ID domain matches the last Received "by" domain.
#
# These two tests could be combined into a single rule, but they are
# separated because the first test is more accurate than the second test.
# However, we only run the primary function once for better performance.

sub check_for_mta_message_id_first {
  my ($self) = @_;

  if (! exists $self->{mta_first}) {
    $self->_check_mta_message_id();
  }
  return $self->{mta_first};
}

sub check_for_mta_message_id_later {
  my ($self) = @_;

  if (! exists $self->{mta_later}) {
    $self->_check_mta_message_id();
  }
  return $self->{mta_later};
}

sub _check_mta_message_id {
  my ($self) = @_;

  $self->{mta_first} = 0;
  $self->{mta_later} = 0;

  my $all = $self->get ('ALL');
  my $later_mta;

  if ($all =~ /\nMessage-(ID|Id|id):.*\nReceived:/s) {
    # Message-ID is before a Received
    $later_mta = 1;
  }
  elsif ($all =~ /\nReceived:[^\n]*\n([\t ][^\n]*\n)*Message-(ID|Id|id):/s) {
    # Message-ID is not before a Received but is directly after a Received
    $later_mta = 0;
  }
  else {
    # go fish
    return;
  }

  my $id = $self->get ('Message-Id');

  # exempt certain Message-Id headers (could backfire so be prepared to remove)
  return if $id =~ /\@.*(localhost\.localdomain|linux\.local|yahoo)/;

  # no further checks in simple case
  if ($later_mta) {
    $self->{mta_later} = 1;
    return;
  }

  # further checks required
  my $from = $self->get ('From:addr');
  my $received = $self->get ('Received');
  my @relay;
  my $first;

  # BUG: From:addr sometimes contains whitespace
  $from =~ s/\s+//g;

  # strip down to the host name
  $id =~ s/.*\@//;
  $id =~ s/[>\s]+$//;
  $id = lc($id);
  $from =~ s/.*\@//;
  $from = lc($from);
  while ($received =~ s/[\t ]+by[\t ]+(\w+([\w.-]+\.)+\w+)//i) {
    push (@relay, $1);
  }
  $first = lc(pop(@relay));

  # need to have a dot (test for addr-spec validity should be in another test)
  return if ($id !~ /\./ || $from !~ /\./);

  # strip down to last two parts of hostname
  $id =~ s/.*\.(\S+\.\S+)$/$1/;
  $from =~ s/.*\.(\S+\.\S+)$/$1/;

  # if $from equals $id, then message is much less likely to be spam
  return if $from eq $id;

  # strip down the first relay now
  $first =~ s/.*\.(\S+\.\S+)$/$1/;

  # finally, the test
  if ($first eq $id) {
    $self->{mta_first} = 1;
    return;
  }
}

###########################################################################

# FORGED_HOTMAIL_RCVD
sub check_for_forged_hotmail_received_headers {
  my ($self) = @_;

  my $from = $self->get ('From:addr');
  if ($from !~ /hotmail.com/) { return 0; }

  my $rcvd = $self->get ('Received');
  $rcvd =~ s/\s+/ /gs;		# just spaces, simplify the regexp

  my $ip = $self->get ('X-Originating-Ip');
  if ($ip =~ /\d+\.\d+\.\d+\.\d+/) { $ip = 1; } else { $ip = 0; }

  # Hotmail formats its received headers like this:
  # Received: from hotmail.com (f135.law8.hotmail.com [216.33.241.135])
  # spammers do not ;)

  if ($self->gated_through_received_hdr_remover()) { return 0; }

  if ($rcvd =~ /from \S*hotmail.com \(\S+\.hotmail(?:\.msn|)\.com[ \)]/ && $ip)
                { return 0; }
  if ($rcvd =~ /from \S+ by \S+\.hotmail(?:\.msn|)\.com with HTTP\;/ && $ip)
                { return 0; }

  return 1;
}

###########################################################################

sub check_for_forged_eudoramail_received_headers {
  my ($self) = @_;

  my $from = $self->get ('From:addr');
  if ($from !~ /eudoramail.com/) { return 0; }

  my $rcvd = $self->get ('Received');
  $rcvd =~ s/\s+/ /gs;		# just spaces, simplify the regexp

  my $ip = $self->get ('X-Sender-Ip');
  if ($ip =~ /\d+\.\d+\.\d+\.\d+/) { $ip = 1; } else { $ip = 0; }

  # Eudoramail formats its received headers like this:
  # Received: from Unknown/Local ([?.?.?.?]) by shared1-mail.whowhere.com;
  #      Thu Nov 29 13:44:25 2001
  # Message-Id: <JGDHDEHPPJECDAAA@shared1-mail.whowhere.com>
  # Organization: QUALCOMM Eudora Web-Mail  (http://www.eudoramail.com:80)
  # X-Sender-Ip: 192.175.21.146
  # X-Mailer: MailCity Service

  if ($self->gated_through_received_hdr_remover()) { return 0; }

  if ($rcvd =~ /by \S*whowhere.com\;/ && $ip) { return 0; }
  
  return 1;
}

###########################################################################

sub check_for_forged_excite_received_headers {
  my ($self) = @_;

  my $from = $self->get ('From:addr');
  if ($from !~ /excite.com/) { return 0; }

  my $rcvd = $self->get ('Received');
  $rcvd =~ s/\s+/ /gs;		# just spaces, simplify the regexp

  # Excite formats its received headers like this:
  # Received: from bucky.excite.com ([198.3.99.218]) by vaxc.cc.monash.edu.au
  #    (PMDF V6.0-24 #38147) with ESMTP id
  #    <01K53WHA3OGCA5W9MM@vaxc.cc.monash.edu.au> for luv@luv.asn.au;
  #    Sat, 23 Jun 2001 13:36:20 +1000
  # Received: from hippie.excite.com ([199.172.148.180]) by bucky.excite.com
  #    (InterMail vM.4.01.02.39 201-229-119-122) with ESMTP id
  #    <20010623033612.NRCY6361.bucky.excite.com@hippie.excite.com> for
  #    <luv@luv.asn.au>; Fri, 22 Jun 2001 20:36:12 -0700
  # spammers do not ;)

  if ($self->gated_through_received_hdr_remover()) { return 0; }

  if ($rcvd =~ /from \S*excite.com (\S+) by \S*excite.com/) { return 0; }
  
  return 1;
}

###########################################################################

sub check_for_forged_yahoo_received_headers {
  my ($self) = @_;

  my $from = $self->get ('From:addr');
  if ($from !~ /yahoo.com/) { return 0; }

  my $rcvd = $self->get ('Received');
  $rcvd =~ s/\s+/ /gs;		# just spaces, simplify the regexp

  # not sure about this
  #if ($rcvd !~ /from \S*yahoo\.com/) { return 0; }

  if ($self->gated_through_received_hdr_remover()) { return 0; }

  if ($rcvd =~ /by web\S+\.mail\.yahoo\.com via HTTP/) { return 0; }
  if ($rcvd =~ /by smtp\.\S+\.yahoo\.com with SMTP/) { return 0; }
  if ($rcvd =~
      /from \[\d+\.\d+\.\d+\.\d+\] by \S+\.(?:groups|grp\.scd)\.yahoo\.com with NNFMP/) {
    return 0;
  }
  if ($rcvd =~ /by \w+\.\w+\.yahoo\.com \(\d+\.\d+\.\d+\/\d+\.\d+\.\d+\) id \w+/) {
      # possibly sent from "mail this story to a friend"
      return 0;
  }

  return 1;
}

sub check_for_forged_juno_received_headers {
  my ($self) = @_;

  my $from = $self->get('From:addr');
  if($from !~ /juno.com/) { return 0; }

  if($self->gated_through_received_hdr_remover()) { return 0; }

  my $xmailer = $self->get('X-Mailer');
  my $xorig = $self->get('X-Originating-IP');
  my $rcvd = $self->get('Received');

  if (!$xorig) {  # New style Juno has no X-Originating-IP header, and other changes
    if($rcvd !~ /from.*juno\.com.*\[[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\].*by/) { return 1; }
    if($xmailer !~ /Juno /) { return 1; }
  } else {
    if($rcvd !~ /from.*mail\.com.*\[[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\].*by/) { return 1; }
    if($xorig !~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) { return 1; }
    if($xmailer !~ /mail\.com/) { return 1; }
  }

  return 0;   
}

# ezmlm has a very bad habit of removing Received: headers! bad ezmlm.
#
sub gated_through_received_hdr_remover {
  my ($self) = @_;

  my $txt = $self->get ("Mailing-List");
  if (defined $txt && $txt =~ /^contact \S+\@\S+\; run by ezmlm$/) {
    my $dlto = $self->get ("Delivered-To");
    my $rcvd = $self->get ("Received");

    # ensure we have other indicative headers too
    if ($dlto =~ /^mailing list \S+\@\S+/ &&
      	$rcvd =~ /qmail \d+ invoked from network\); \d+ ... \d+/ &&
      	$rcvd =~ /qmail \d+ invoked by .{3,20}\); \d+ ... \d+/)
    {
      return 1;
    }
  }

  return 0;
}

###########################################################################

sub check_for_bad_helo {
  my ($self) = @_;
  local ($_);
  $_ = $self->get ('X-Authentication-Warning');

  (/host \S+ \[(\S+)\] claimed to be.*\[(\S+)\]/i && $1 ne $2);
}

###########################################################################

sub check_subject_for_lotsa_8bit_chars {
  my ($self) = @_;
  local ($_);

  $_ = $self->get ('Subject');

  # cut [ and ] because 8-bit posts to mailing lists may not get
  # hit otherwise. e.g.: Subject: [ILUG] X�uX .  Also cut
  # *, since mail that goes through spamassassin multiple times will
  # not be tagged on the second pass otherwise.
  s/\[\]\* //g;

  return 1 if ($self->are_more_high_bits_set ($_));
  return 0;
}

sub are_more_high_bits_set {
  my ($self, $str) = @_;

  my @highbits = ($str =~ /[\200-\377]/g);
  my $numhis = $#highbits+1;
  my $numlos = length($str) - $numhis;

  ($numlos <= $numhis && $numhis > 3);
}

###########################################################################

sub check_for_missing_to_header {
  my ($self) = @_;

  my $hdr = $self->get ('To');
  $hdr ||= $self->get ('Apparently-To');
  return 1 if ($hdr eq '');

  return 0;
}

###########################################################################

sub check_from_in_whitelist {
  my ($self) = @_;
  local ($_);
  $_ = $self->get ('From:addr');
  return $self->_check_whitelist ($self->{conf}->{whitelist_from}, $_);
}

sub _check_whitelist {
  my ($self, $list, $addr) = @_;
  $addr = lc $addr;

  if (defined ($list->{$addr})) { return 1; }

  study $addr;
  foreach my $regexp (values %{$list}) {
    if ($addr =~ /$regexp/i) { return 1; }
  }

  return 0;
}

###########################################################################

my $obfu_chars = '*_.,/|-+=';
sub check_obfuscated_words {
    my ($self, $body) = @_;

    foreach my $line (@$body) {
        while ($line =~ /[\w$obfu_chars]/) {
        }
    }
}

###########################################################################

sub check_from_in_blacklist {
  my ($self) = @_;
  local ($_);
  $_ = $self->get ('From:addr');
  return $self->_check_whitelist ($self->{conf}->{blacklist_from}, $_);
}

###########################################################################
# added by DJ

sub check_to_in_whitelist {
  my ($self) = @_;
  local ($_);
  foreach $_ ($self->{main}->find_all_addrs_in_line
  			($self->get ('To') . $self->get ('Cc')))
  {
    if ($self->_check_whitelist ($self->{conf}->{whitelist_to}, $_)) {
      return 1;
    }
  }
}


###########################################################################
# added by DJ

sub check_to_in_more_spam {
  my ($self) = @_;
  local ($_);
  foreach $_ ($self->{main}->find_all_addrs_in_line
  			($self->get ('To') . $self->get ('Cc')))
  {
    if ($self->_check_whitelist ($self->{conf}->{more_spam_to}, $_)) {
      return 1;
    }
  }
}


###########################################################################
# added by DJ

sub check_to_in_all_spam {
  my ($self) = @_;
  local ($_);
  foreach $_ ($self->{main}->find_all_addrs_in_line
  			($self->get ('To') . $self->get ('Cc')))
  {
    if ($self->_check_whitelist ($self->{conf}->{all_spam_to}, $_)) {
      return 1;
    }
  }
}

###########################################################################

sub check_lots_of_cc_lines {
  my ($self) = @_;
  local ($_);
  $_ = $self->get ('Cc');
  my @count = /\n/gs;
  if ($#count > 20) { return 1; }
  return 0;
}

###########################################################################

sub check_from_name_eq_from_address {
  my ($self) = @_;
  local ($_);
  $_ = $self->get ('From');

  /\"(\S+)\" <(\S+)>/ or return 0;
  if ($1 eq $2) { return 1; }
  return 0;
}

###########################################################################

sub check_rbl {
  my ($self, $set, $rbl_domain, $needresult) = @_;
  local ($_);
  # How many IPs max you check in the received lines;
  my $checklast=$self->{conf}->{num_check_received} - 1;
  
  dbg ("checking RBL $rbl_domain, set $set", "rbl", -1);

  my $rcv = $self->get ('Received');
  my @ips = ($rcv =~ /[\[\(](\d+\.\d+\.\d+\.\d+)[\]\)]/g);
  return 0 unless ($#ips >= 0);

  # First check that DNS is available, if not do not perform this check
  return 0 if $self->{conf}->{skip_rbl_checks};
  return 0 unless $self->is_dns_available();
  $self->load_resolver();

  dbg("Got the following IPs: ".join(", ", @ips), "rbl", -3);
  if ($#ips > 1) {
    @ips = @ips[$#ips-$checklast .. $#ips]; # only check the originating IPs
  }
  dbg("But only inspecting the following IPs: ".join(", ", @ips), "rbl", -3);

  if (!defined $self->{$set}->{rbl_IN_As_found}) {
    $self->{$set}->{rbl_IN_As_found} = ' ';
    $self->{$set}->{rbl_matches_found} = ' ';
  }

  init_rbl_check_reserved_ips();
  my $already_matched_in_other_zones = ' '.$self->{$set}->{rbl_matches_found}.' ';
  my $found = 0;

  # First check that DNS is available. If not, do not perform this check.
  # Stop after the first positive.
  eval {
    my $i=0;
    my ($b1,$b2,$b3,$b4);
    my $dialupreturn;
    foreach my $ip (@ips) {
      $i++;
      next if ($ip =~ /${IP_IN_RESERVED_RANGE}/o);
      # Some of the matches in other zones, like a DUL match on a first hop 
      # may be negated by another rule, so preventing a match in two zones
      # is better done with a Z_FUDGE_foo rule that users check_both_rbl_results
      # and sets a negative score to compensate 
      # It's also useful to be able to flag mail that went through an IP that
      # is on two different blacklists  -- Marc
      #next if ($already_matched_in_other_zones =~ / ${ip} /);
      if ($already_matched_in_other_zones =~ / ${ip} /) {
	dbg("Skipping $ip, already matched in other zones for $set", "rbl", -1);
	next;
      }
      next unless ($ip =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/);
     ($b1, $b2, $b3, $b4) = ($1, $2, $3, $4);
      
      # By default, we accept any return on an RBL
      undef $dialupreturn;
      
      # foo-firsthop are special rule names that only match on the
      # first Received line (used to give a negative score to counter the
      # normal dialup rule and not penalize people who relayed through their
      # ISP) -- Marc
      # By default this rule won't get run unless it's the first hop IP
      if ($set =~ /-firsthop$/) {
	if ($#ips>0 and $i == $#ips + 1) {
	  dbg("Set dialupreturn on $ip for first hop", "rbl", -2);
	  $dialupreturn=$self->{conf}->{dialup_codes};
	  die "$self->{conf}->{dialup_codes} undef" if (!defined $dialupreturn);
	} else {
	  dbg("Not running firsthop rule against middle hop or direct dialup IP connection (ip $ip)", "rbl", -2);
	  next;
	}
      }
      
      $found = $self->do_rbl_lookup ($set, "$b4.$b3.$b2.$b1.".$rbl_domain, $ip, $found, $dialupreturn, $needresult);
      dbg("Got $found on $ip (item $i)", "rbl", -3);
    }
  };

  dbg("Check_rbl returning $found", "rbl", -3);
  $found;
}

###########################################################################

sub check_rbl_results_for {
  my ($self, $set, $addr) = @_;

  dbg ("checking RBL results in set $set for $addr", "rbl", -1);
  return 0 if $self->{conf}->{skip_rbl_checks};
  return 0 unless $self->is_dns_available();
  return 0 unless defined ($self->{$set});
  return 0 unless defined ($self->{$set}->{rbl_IN_As_found});

  my $inas = ' '.$self->{$set}->{rbl_IN_As_found}.' ';
  if ($inas =~ / ${addr} /) { return 1; }

  return 0;
}

###########################################################################

sub check_two_rbl_results {
  my ($self, $set1, $addr1, $set2, $addr2) = @_;

  return 0 if $self->{conf}->{skip_rbl_checks};
  return 0 unless $self->is_dns_available();
  return 0 unless defined ($self->{$set1});
  return 0 unless defined ($self->{$set2});
  return 0 unless defined ($self->{$set1}->{rbl_IN_As_found});
  return 0 unless defined ($self->{$set2}->{rbl_IN_As_found});

  my $inas1 = ' '.$self->{$set1}->{rbl_IN_As_found}.' ';
  my $inas2 = ' '.$self->{$set2}->{rbl_IN_As_found}.' ';
  if ($inas1 =~ / ${addr1} / and $inas2 =~ / ${addr2} /) { return 1; }

  return 0;
}


###########################################################################

sub check_for_unique_subject_id {
  my ($self) = @_;
  local ($_);
  $_ = lc $self->get ('Subject');
  study;

  my $id = undef;
  if (/[-_\.\s]{7,}([-a-z0-9]{4,})$/
	|| /\s{3,}[-:\#\(\[]+([-a-z0-9]{4,})[\]\)]+$/
	|| /\s{3,}[:\#\(\[]*([0-9]{4,})[\]\)]*$/
	|| /\s{3,}[-:\#]([a-z0-9]{5,})$/

        # (7217vPhZ0-478TLdy5829qicU9-0@26) and similar
        || /\(([-\w]{7,}\@\d+)\)$/

        # Seven or more digits at the end of a subject is almost certainly
        # a id.
        || /\b(\d{7,})\s*$/

        # A number at the end of the subject, if it's after the end of a
        # sentence (ending in "!" or "?"), is almost certainly an id
        || /[!\?]\s*(\d{4,})\s*$/

        # 9095IPZK7-095wsvp8715rJgY8-286-28 and similar
        || /\b(\w{7,}-\w{7,}-\d+-\d+)\s*$/
     )
  {
    $id = $1;
  }

  if (!defined($id) || $self->word_is_in_dictionary ($id)) {
    return 0;
  } else {
    return 1;
  }
}

# word_is_in_dictionary()
#
# See if the word looks like an English word, by checking if each triplet
# of letters it contains is one that can be found in the English lanugage.
# Does not include triplets only found in proper names, or in the Latin
# and Greek terms that might be found in a larger dictionary

my %triplets = ();
my $triplets_loaded = 0;

sub word_is_in_dictionary {
  my ($self, $word) = @_;
  local ($_);
  local $/ = "\n";		# Ensure $/ is set appropriately

  # $word =~ tr/A-Z/a-z/;	# already done by this stage
  $word =~ s/^\s+//;
  $word =~ s/\s+$//;

  # If it contains a digit, dash, etc, it's not a valid word.
  # Don't reject words like "can't" and "I'll"
  return 0 if ($word =~ /[^a-z\']/);

  # handle a few common "blah blah blah (comment)" styles
  return 1 if ($word eq "ot");	# off-topic
  return 1 if ($word =~ /(?:linux|nix|bsd)/); # not in most dicts
  return 1 if ($word =~ /(?:whew|phew|attn|tha?nx)/);  # not in most dicts

  my $word_len = length($word);

  # Unique IDs probably aren't going to be only one or two letters long
  return 1 if ($word_len < 3);

  if (!$triplets_loaded) {
    my $filename = $self->{main}->{rules_filename} . "/triplets.txt";

    if (!open (TRIPLETS, "<$filename")) {
      dbg ("failed to open '$filename', cannot check dictionary");
      return 1;
    }

    while(<TRIPLETS>) {
      chomp;
      $triplets{$_} = 1;
    }
    close(TRIPLETS);

    $triplets_loaded = 1;
  } # if (!$triplets_loaded)


  my $i;

  for ($i = 0; $i < ($word_len - 2); $i++) {
    my $triplet = substr($word, $i, 3);
    if (!$triplets{$triplet}) {
      dbg ("Unique ID: Letter triplet '$triplet' from word '$word' not valid");
      return 0;
    }
  } # for ($i = 0; $i < ($word_len - 2); $i++)

  # All letter triplets in word were found to be valid
  return 1;
}

###########################################################################

sub get_address_commonality_ratio {
  my ($self, $addr1, $addr2) = @_;


  # Ignore "@" and ".".  "@" will always be the same in both, and the
  # number of "." will almost always be the same
  $addr1 =~ s/[\@\.]//g;
  $addr2 =~ s/[\@\.]//g;

  my %counts1 = ();
  my %counts2 = ();

  map { $counts1{$_}++; } split (//, lc $addr1);
  map { $counts2{$_}++; } split (//, lc $addr2);

  my $different = 0;
  my $same      = 0;
  my $unique    = 0;
  my $char;
  my @chars     = keys %counts1;

  # Extract unique characters, and make the two hashes have the same
  # set of keys
  foreach $char (@chars) {
    if (!defined ($counts2{$char})) {
      $unique += $counts1{$char};
      delete ($counts1{$char});
    }
  }

  @chars = keys %counts2;

  foreach $char (@chars) {
    if (!defined ($counts1{$char})) {
      $unique += $counts2{$char};
      delete ($counts2{$char});
    }
  }

  # Hashes now have identical sets of keys; count the differences
  # between the values.
  @chars = keys %counts1;

  foreach $char (@chars) {
    my $count1 = $counts1{$char} || 0.0;
    my $count2 = $counts2{$char} || 0.0;

    if ($count1 == $count2) {
      $same += $count1;
    }
    else {
      $different += abs($count1 - $count2);
    }
  }

  $different += $unique / 2.0;

  $same ||= 1.0;
  my $ratio = $different / $same;

  #print STDERR "addrcommonality $addr1/$addr2($different<$unique>/$same)"
  # . " = $ratio\n";

  return $ratio;
}

###########################################################################

sub check_for_forged_gw05_received_headers {
  my ($self) = @_;
  local ($_);

  my $rcv = $self->get ('Received');

  # e.g.
  # Received: from mail3.icytundra.com by gw05 with ESMTP; Thu, 21 Jun 2001 02:28:32 -0400
  my ($h1, $h2) = ($rcv =~ 
  	m/\nfrom\s(\S+)\sby\s(\S+)\swith\sESMTP\;\s+\S\S\S,\s+\d+\s+\S\S\S\s+
			\d{4}\s+\d\d:\d\d:\d\d\s+[-+]*\d{4}\n$/xs);

  if (defined ($h1) && defined ($h2) && $h2 !~ /\./) {
    return 1;
  }

  0;
}

###########################################################################

sub check_for_content_type_just_html {
  my ($self) = @_;
  local ($_);

  my $rcv = $self->get ('Received');
  my $ctype = $self->get ('Content-Type');

  # HotMail uses this unfortunately for it's "rich text" control,
  # so we need to exclude that from the test.
  if ($rcv =~ / by hotmail.com /) { return 0; }

  if ($ctype =~ /^text\/html;?\b/i) { return 1; }

  0;
}

###########################################################################

sub check_for_faraway_charset {
  my ($self, $body) = @_;

  my $type = $self->get ('Content-Type');
  $type ||= $self->get ('Content-type');

  my @locales = $self->get_my_locales();

  return 0 if grep { $_ eq "all" } @locales;

  $type = get_charset_from_ct_line ($type);

  if (defined $type &&
    !Mail::SpamAssassin::Locales::is_charset_ok_for_locales
		    ($type, @locales))
  {
    # sanity check.  Some charsets (e.g. koi8-r) include the ASCII
    # 7-bit charset as well, so make sure we actually have a high
    # number of 8-bit chars in the body text first.

    $body = join ("\n", @$body);

    if ($self->are_more_high_bits_set ($body)) {
      return 1;
    }
  }

  0;
}

sub check_for_faraway_charset_in_body {
  my ($self, $fulltext) = @_;

  my $content_type = $self->{msg}->get_header('Content-Type');
  $content_type = '' unless defined $content_type;
  $content_type =~ /\bboundary\s*=\s*["']?(.*?)["']?(?:;|$)/i;
  my $boundary = "\Q$1\E";

  # No message sections to check
  return 0 unless ( defined $boundary );

  while ( $$fulltext =~ /^--$boundary\n((?:[^\n]+\n)+)(.+?)
                      ^--$boundary(?:--)?\n/smxg ) {
              my($header,$sampleofbody) = ($1,$2);

              if ( $header =~ /^Content-Type:\s(.{0,100}charset=[^\n]+)/msi ) {
    my $type = $1;

    my @locales = $self->get_my_locales();

    return 0 if grep { $_ eq "all" } @locales;

    $type = get_charset_from_ct_line ($type);
    if (defined $type &&
      !Mail::SpamAssassin::Locales::is_charset_ok_for_locales
		      ($type, @locales))
    {
      if ($self->are_more_high_bits_set ($sampleofbody)) {
        return 1;
      }
    }
  }
  }

  0;
}

sub check_for_faraway_charset_in_headers {
  my ($self) = @_;
  my $hdr;

  my @locales = $self->get_my_locales();

  return 0 if grep { $_ eq "all" } @locales;

  for my $h (qw(From Subject)) {
# Can't use just get() because it un-mime header
    my @hdrs = $self->{msg}->get_header ($h);
    if ($#hdrs >= 0) {
      $hdr = join (" ", @hdrs);
    } else {
      $hdr = '';
    }
    while ($hdr =~ /=\?(.+?)\?.\?.*?\?=/g) {
      Mail::SpamAssassin::Locales::is_charset_ok_for_locales($1, @locales)
	  or return 1;
    }
  }
  0;
}

sub get_charset_from_ct_line {
  my $type = shift;
  if ($type =~ /charset="([^"]+)"/i) { return $1; }
  if ($type =~ /charset='([^']+)'/i) { return $1; }
  if ($type =~ /charset=(\S+)/i) { return $1; }
  return undef;
}

sub get_my_locales {
  my ($self) = @_;

  my @locales = split (' ', $self->{conf}->{ok_locales});
  my $lang = $ENV{'LC_ALL'};
  $lang ||= $ENV{'LANGUAGE'};
  $lang ||= $ENV{'LC_MESSAGES'};
  $lang ||= $ENV{'LANG'};
  push (@locales, $lang) if defined($lang);
  return @locales;
}

###########################################################################

sub check_for_round_the_world_received {
  my ($self) = @_;
  my ($relayer, $relayerip, $relay);

  my $rcvd = $self->get ('Received');

  # trad sendmail/postfix fmt:
  # Received: from hitower.parkgroup.ru (unknown [212.107.207.26]) by
  #     mail.netnoteinc.com (Postfix) with ESMTP id B8CAC11410E for
  #     <me@netnoteinc.com>; Fri, 30 Nov 2001 02:42:05 +0000 (Eire)
  # Received: from fmx1.freemail.hu ([212.46.197.200]) by hitower.parkgroup.ru
  #     (Lotus Domino Release 5.0.8) with ESMTP id 2001113008574773:260 ;
  #     Fri, 30 Nov 2001 08:57:47 +1000
  if ($rcvd =~ /
  	\nfrom\b.{0,20}\s(\S+\.${CCTLDS_WITH_LOTS_OF_OPEN_RELAYS})\s\(.{0,200}
  	\nfrom\b.{0,20}\s([-_A-Za-z0-9.]+)\s.{0,30}\[(\d+\.\d+\.\d+\.\d+)\]
  /osix) { $relay = $1; $relayer = $2; $relayerip = $3; goto gotone; }

  return 0;

gotone:
  my $revdns = $self->lookup_ptr ($relayerip);
  if (!defined $revdns) { $revdns = '(unknown)'; }

  dbg ("round-the-world: mail relayed through $relay by ".	
  	"$relayerip (HELO $relayer, rev DNS says $revdns");

  if ($revdns =~ /\.${ROUND_THE_WORLD_RELAYERS}$/oi ||
      $relayer =~ /\.${ROUND_THE_WORLD_RELAYERS}$/oi)
  {
    dbg ("round-the-world: yep, I think so");
    return 1;
  }

  dbg ("round-the-world: probably not");
  return 0;
}

###########################################################################

sub check_for_shifted_date {
  my ($self, $min, $max) = @_;

  if (!exists $self->{date_diff}) {
    $self->_check_date_diff();
  }
  return (($min eq 'undef' || $self->{date_diff} >= (3600 * $min)) &&
	  ($max eq 'undef' || $self->{date_diff} < (3600 * $max)));
}

sub _check_date_diff {
  my ($self) = @_;
  local ($_);

  $self->{date_diff} = 0;

  my $rcvd = $self->get ('Received');
  # if we have no Received: headers, chances are we're archived mail
  # with a limited set of headers
  return if (!defined $rcvd || $rcvd eq '');

  # a Resent-Date: header takes precedence over any Date: header
  my $date = $self->get ('Resent-Date');
  if (!defined $date || $date eq '') {
    $date = $self->get ('Date');
  }
  # just return since there's already a good test for this
  return if (!defined $date || $date eq '');

  chomp ($date);
  my $time = $self->_parse_rfc822_date ($date);

  # parse_rfc822_date failed
  return if !defined($time);

  # use second date. otherwise fetchmail Received: hdrs will screw it up
  my @rcvddatestrs = ($rcvd =~ /\s.?\d+ \S\S\S \d+ \d+:\d+:\d+ \S+/g);
  my @rcvddates = ();
  foreach $rcvd (@rcvddatestrs) {
    dbg ("trying Received header date for real time: $rcvd", "datediff", -2);
    $rcvd = $self->_parse_rfc822_date ($rcvd);
    if (defined($rcvd)) {
      push (@rcvddates, $rcvd);
    }
  }

  if ($#rcvddates <= 0) {
    dbg ("no dates found in Received headers, not raising flag", "datediff", -1);
    return;
  }

  my @diffs;

  foreach $rcvd (@rcvddates) {
    my $diff = $time - $rcvd;
    dbg ("time_t from date=$time, rcvd=$rcvd, diff=$diff", "datediff", -2);
    push(@diffs, $diff);
  }

  # if the last Received: header has no difference, then we choose to
  # exclude it
  if ($#diffs > 0 && $diffs[$#diffs] == 0) {
    pop(@diffs);
  }

  # use the date with the smallest absolute difference
  # (experimentally, this results in the fewest false positives)
  @diffs = sort { abs($a) <=> abs($b) } @diffs;
  $self->{date_diff} = $diffs[0];
}

sub _parse_rfc822_date {
  my ($self, $date) = @_;
  local ($_);
  my ($yyyy, $mmm, $dd, $hh, $mm, $ss, $mon, $tzoff);

  # make it a bit easier to match
  $_ = " $date "; s/, */ /gs; s/\s+/ /gs;

  # now match it in parts.  Date part first:
  if (s/ (\d+) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{4}) / /i) {
    $dd = $1; $mon = $2; $yyyy = $3;
  } elsif (s/ (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +(\d+) \d+:\d+:\d+ (\d{4}) / /i) {
    $dd = $2; $mon = $1; $yyyy = $3;
  } elsif (s/ (\d+) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{2,3}) / /i) {
    $dd = $1; $mon = $2; $yyyy = $3;
  } else {
    dbg ("time cannot be parsed: $date");
    return undef;
  }

  # handle two and three digit dates as specified by RFC 2822
  if (defined $yyyy) {
    if (length($yyyy) == 2 && $yyyy < 50) {
      $yyyy += 2000;
    }
    elsif (length($yyyy) != 4) {
      # three digit years and two digit years with values between 50 and 99
      $yyyy += 1900;
    }
  }

  # hh:mm:ss
  if (s/ ([\d\s]\d):(\d\d)(:(\d\d))? / /) {
    $hh = $1; $mm = $2; $ss = $4 || 0;
  }

  # numeric timezones
  if (s/ ([-+]\d{4}) / /) {
    $tzoff = $1;
  }
  # UT, GMT, and North American timezones
  elsif (s/ (UT|GMT|[ECMP][DS]T) / /) {
    if    ($1 eq "UT"  || $1 eq "GMT") { $tzoff = "+0000"; }
    elsif ($1 eq "EDT")                { $tzoff = "-0400"; }
    elsif ($1 eq "EST" || $1 eq "CDT") { $tzoff = "-0500"; }
    elsif ($1 eq "CST" || $1 eq "MDT") { $tzoff = "-0600"; }
    elsif ($1 eq "MST" || $1 eq "PDT") { $tzoff = "-0700"; }
    elsif ($1 eq "PST")                { $tzoff = "-0800"; }
  }
  # all other timezones are considered equivalent to "-0000"
  $tzoff ||= '-0000';

  if (!defined $mmm && defined $mon) {
    my @months = qw(jan feb mar apr may jun jul aug sep oct nov dec);
    $mon = lc($mon);
    my $i; for ($i = 0; $i < 12; $i++) {
      if ($mon eq $months[$i]) { $mmm = $i+1; last; }
    }
  }

  $hh ||= 0; $mm ||= 0; $ss ||= 0; $dd ||= 0; $mmm ||= 0; $yyyy ||= 0;

  my $time;
  eval {		# could croak
    $time = timegm ($ss, $mm, $hh, $dd, $mmm-1, $yyyy);
  };

  if ($@) {
    dbg ("time cannot be parsed: $date, $yyyy-$mmm-$dd $hh:$mm:$ss");
    return undef;
  }

  if ($tzoff =~ /([-+])(\d\d)(\d\d)$/)	# convert to seconds difference
  {
    $tzoff = (($2 * 60) + $3) * 60;
    if ($1 eq '-') {
      $time += $tzoff;
    } else {
      $time -= $tzoff;
    }
  }

  return $time;
}

###########################################################################

sub subject_is_all_caps {
   my ($self) = @_;
   my $subject = $self->get('Subject');

   $subject =~ s/^\s+//;
   $subject =~ s/\s+$//;
   return 0 if $subject !~ /\s/;	# don't match one word subjects
   $subject =~ s/[^a-zA-Z]//g;		# only look at letters
   return length($subject) && ($subject eq uc($subject));
}

###########################################################################
# BODY TESTS:
###########################################################################


sub porn_word_test {
    my ($self, $fulltext) = @_;
    my $hits = 0;
    foreach my $pat (@PORN_WORDS) {
        $hits++ if ($$fulltext =~ /$pat/);
        return 1 if ($hits == 3);
    }
    return 0;
}

sub check_for_very_long_text {
  my ($self, $body) = @_;

  my $count = 0;
  foreach my $line (@{$body}) {
    if (length($line) > 40) { $count++; }
  }
  if ($count > 500) { return 1; }
  return 0;
}

sub check_for_uppercase {
  my ($self, $body, $min, $max) = @_;

  if (exists $self->{uppercase}) {
    return ($self->{uppercase} > $min && $self->{uppercase} <= $max);
  }

  # examine lines in the body that have an intermediate space
  my @lines = grep(/\S\s+\S/, @{$body});

  # strip out lingering base64 (currently possible for forwarded messages)
  @lines = grep(!/^([A-Za-z0-9+\/=]{60,76} ){2}/, @lines);

  # join lines together
  $body = join('', @lines);

  # now count upper and lower case
  my $upper = $body =~ s/([A-Z])/$1/sg;
  my $lower = $body =~ s/([a-z])/$1/sg;

  if (($upper + $lower) == 0) {
    $self->{uppercase} = 0;
  }
  else {
    $self->{uppercase} = ($upper / ($upper + $lower)) * 100;
  }

  return ($self->{uppercase} > $min && $self->{uppercase} <= $max);
}

sub check_for_yelling {
    my ($self, $body) = @_;
    
    if (exists $self->{num_yelling_lines}) {
        return $self->{num_yelling_lines} > 0;
    }

  # Make local copy of lines in the body that have some non-letters
    my @lines = grep(/[^A-Za-z]/, @{$body});

  # Try to eliminate lines which might be newsletter section headers,
  # which are often in all caps; we do this by removing most lines
  # that start with whitespace.  However, some spam will match
  # this as well, so keep lines which have "!" or "$$" (spam often
  # has a yelling line indent with spaces, but surround by dollar
  # signs), or a "." which appears to end a sentence.
  @lines = grep(/^\S|!|\$\$|\.(?:\s|$)/, @lines);

  # Get rid of everything but upper AND lower case letters
    map (s/[^A-Za-z \t]//sg, @lines);

  # Remove leading and trailing whitespace
    map (s/^\s+//, @lines);
    map (s/\s+$//, @lines);

  # Now that we have a mixture of upper and lower case, see if it's
  # 1) All upper case
  # 2) 20 or more characters in length
  # 3) Has at least one whitespace in it; we don't want to catch things
  #    like lines of genetic data ("...AGTAGC...")
    my $num_lines = scalar grep(/\s/, grep(/^[A-Z\s]{20,}$/, @lines) );

    $self->{num_yelling_lines} = $num_lines;

    return ($num_lines > 0);
}

sub check_for_num_yelling_lines {
    my ($self, $body, $threshold) = @_;
    
    $self->check_for_yelling($body);
    
    return ($self->{num_yelling_lines} >= $threshold);
}

sub check_for_mime_excessive_qp {
  my ($self, $body) = @_;

  # Note: We don't use $body because it removes MIME parts.  Instead, we
  # get the raw unfiltered body AND WE MUST NOT CHANGE ANY LINE.
  $body = join('', @{$self->{msg}->get_body()});

  my $length = length($body);
  my $qp = $body =~ s/\=([0-9A-Fa-f]{2})/$1/g;

  # this seems like a decent cutoff
  return ($length != 0 && ($qp > ($length / 20)));
}

# This test should be a nearly zero cost operation done during MIME
# decoding, but this works just fine for now.
sub check_for_mime_missing_boundary {
  my ($self, $body) = @_;
  my $ctype = 0;
  my $name;
  my @boundary;
  my %count;

  # boundaries in header
  my $header_ctype = $self->{msg}->get_header('Content-Type');
  $header_ctype = '' unless defined $header_ctype;
  if ($header_ctype =~ /\bboundary\s*=\s*["']?(.*?)["']?(?:;|$)/i) {
    push (@boundary, "\Q$1\E");
  }

  # Note: We don't use $body because it removes MIME parts.  Instead, we
  # get the raw unfiltered body AND WE MUST NOT CHANGE ANY LINE.
  foreach my $line (@{$self->{msg}->get_body()}) {
    if ($line =~ /^--/) {
      foreach my $boundary (@boundary) {
	if ($line =~ /^--$boundary$/) {
	  $count{$boundary} = 1;
	}
	if ($line =~ /^--$boundary--$/) {
	  $count{$boundary}--;
	}
      }
    }
    if ($line =~ /^Content-[Tt]ype: (\S+?\/\S+?)(?:\;|\s|$)/) {
      $ctype = 1;
    }
    if ($ctype) {
      if ($line =~ /^$/) {
	$ctype = 0;
      }
      elsif ($line =~ /\bboundary\s*=\s*["']?(.*?)["']?(?:;|$)/i) {
        push (@boundary, "\Q$1\E");
      }
    }
  }
  foreach my $boundary (keys %count) {
    return 1 if $count{$boundary} != 0;
  }
  return 0;
}

sub check_language {
  my ($self, $body) = @_;

  my @languages = split (' ', $self->{conf}->{ok_languages});

  return 0 if grep { $_ eq "all" } @languages;

  $body = join ("\n", @{$body});
  $body =~ s/^Subject://i;

  # need about 256 bytes for reasonably accurate match (experimentally derived)
  if (length($body) < 256)
  {
     dbg("Message too short for language analysis");
     return 0;
  }

  my @matches = Mail::SpamAssassin::TextCat::classify($self, $body);
  # not able to get a match, assume it's okay
  if (! @matches) {
    return 0;
  }

  # see if any matches are okay
  foreach my $match (@matches) {
    $match =~ s/\..*//;
    foreach my $language (@languages) {
      if ($match eq $language) {
	return 0;
      }
    }
  }
  return 1;
}

###########################################################################
# FULL-MESSAGE TESTS:
###########################################################################

sub check_razor {
  my ($self, $fulltext) = @_;

  return 0 unless ($self->is_razor_available());
  return 0 if ($self->{already_checked_razor});

  $self->{already_checked_razor} = 1;

  # note: we don't use $fulltext. instead we get the raw message,
  # unfiltered, for razor to check.  ($fulltext removes MIME
  # parts etc.)
  my $full = $self->get_full_message_as_text();
  return $self->razor_lookup (\$full);
}

sub check_dcc {
  my ($self, $fulltext) = @_;

  return 0 unless ($self->is_dcc_available());
  return 0 if ($self->{already_checked_dcc});

   $self->{already_checked_dcc} = 1;

  # note: we don't use $fulltext. instead we get the raw message,
  # unfiltered, for DCC to check.  ($fulltext removes MIME
  # parts etc.)
  my $full = $self->get_full_message_as_text();
  return $self->dcc_lookup (\$full);
}

sub check_for_base64_enc_text {
  my ($self, $fulltext) = @_;

  # If the message itself is base64-encoded, return positive
  my $cte = $self->get('Content-Transfer-Encoding');
  if ( defined $cte && $cte =~ /^\s*base64/i &&
        ($self->get('content-type') =~ /text\//i) ) {
  	return 1;
  }

  if ($$fulltext =~ /\n\n.{0,100}(
    	\nContent-Type:\s*text\/.{0,200}
	\nContent-Transfer-Encoding:\s*base64.*?
	\n\n)/isx)
  {
    my $otherhdrs = $1;
    if ($otherhdrs =~ /^Content-Disposition: (?:attachment|inline)/im) {
      return 0;		# text attachments are OK
    } else {
      return 1;		# no Content-Disp: header found, it's bad
    }
  }

  return 0;
}

###########################################################################

sub check_for_spam_phrases {
  return Mail::SpamAssassin::PhraseFreqs::check_phrase_freqs (@_);
}
sub check_for_spam_phrases_scoring {
  return Mail::SpamAssassin::PhraseFreqs::extra_score_phrase_freqs (@_);
}

###########################################################################

sub check_for_missing_headers { return 0; } # obsolete test

1;
