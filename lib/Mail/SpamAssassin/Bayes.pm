=head1 NAME

Mail::SpamAssassin::Bayes - determine spammishness using a Bayesian classifier

=head1 SYNOPSIS

=head1 DESCRIPTION

This is a Bayesian-like form of probability-analysis classification, using an
algorithm based on the one detailed in Paul Graham's I<A Plan For Spam> paper
at:

  http://www.paulgraham.com/

It also incorporates some other aspects taken from Graham Robinson's webpage
on the subject at:

  http://radio.weblogs.com/0101454/stories/2002/09/16/spamDetection.html

The results are incorporated into SpamAssassin as the BAYES_* rules.

=head1 METHODS

=over 4

=cut

package Mail::SpamAssassin::Bayes;

use strict;
use bytes;

use Mail::SpamAssassin;
use Mail::SpamAssassin::BayesStore;
use Mail::SpamAssassin::PerMsgStatus;

use vars qw{
  @ISA
  $IGNORED_HDRS
  $MARK_PRESENCE_ONLY_HDRS
  $MIN_SPAM_CORPUS_SIZE_FOR_BAYES
  $MIN_HAM_CORPUS_SIZE_FOR_BAYES
  %HEADER_NAME_COMPRESSION
  $OPPORTUNISTIC_LOCK_VALID
};

@ISA = qw();

# Which headers should we scan for tokens?  Don't use all of them, as it's easy
# to pick up spurious clues from some.  What we now do is use all of them
# *less* these well-known headers; that way we can pick up spammers' tracking
# headers (which are obviously not well-known in advance!).

$IGNORED_HDRS = qr{(?: (?:X-)?Sender    # misc noise
  |Delivered-To |Delivery-Date
  |(?:X-)?Envelope-To
  |X-MIME-Auto[Cc]onverted |X-Converted-To-Plain-Text

  |Received     # handled specially

  |Subject      # not worth a tiny gain vs. to db size increase

  # Date: can provide invalid cues if your spam corpus is
  # older/newer than ham
  |Date

  # List headers: ignore. a spamfiltering mailing list will
  # become a nonspam sign.
  |X-List|(?:X-)?Mailing-List
  |(?:X-)?List-(?:Archive|Help|Id|Owner|Post|Subscribe
    |Unsubscribe|Host|Id|Manager|Admin|Comment
    |Name|Url)
  |X-Unsub(?:scribe)?
  |X-Mailman-Version |X-Been[Tt]here |X-Loop
  |Mail-Followup-To
  |X-eGroups-(?:Return|From)
  |X-MDMailing-List
  |X-XEmacs-List

  # gatewayed through mailing list (thanks to Allen Smith)
  |(?:X-)?Resent-(?:From|To|Date)
  |(?:X-)?Original-(?:From|To|Date)

  # Spamfilter/virus-scanner headers: too easy to chain from
  # these
  |X-MailScanner(?:-SpamCheck)?
  |X-Spam(?:-(?:Status|Level|Flag|Report|Hits|Score|Checker-Version))?
  |X-Antispam |X-RBL-Warning
  |X-MDaemon-Deliver-To |X-Virus-Scanned
  |X-Mass-Check-Id
  |X-Pyzor |X-DCC-\S{2,25}-Metrics
  |X-Filtered-B[Yy] |X-Scanned-By |X-Scanner
  |X-AP-Spam-(?:Score|Status) |X-RIPE-Spam-Status
  |X-SpamCop-[^:]+
  |X-SMTPD |(?:X-)?Spam-Apparently-To
  |SPAM

  # some noisy Outlook headers that add no good clues:
  |Content-Class |Thread-(?:Index|Topic)
  |X-Original[Aa]rrival[Tt]ime

  # Annotations from IMAP, POP, and MH:
  |(?:X-)?Status |X-Flags |Replied |Forwarded
  |Lines |Content-Length
  |X-UIDL?

  # Annotations from Bugzilla
  |X-Bugzilla-[^:]+

  # Annotations from VM: (thanks to Allen Smith)
  |X-VM-(?:Bookmark|(?:POP|IMAP)-Retrieved|Labels|Last-Modified
    |Summary-Format|VHeader|v\d-Data|Message-Order)

)}x;

# Note only the presence of these headers, in order to reduce the
# hapaxen they generate.
$MARK_PRESENCE_ONLY_HDRS = qr{(?: X-Face
  |X-(?:Gnu[Pp][Gg]|[GP]PG)(?:-Key)?-Fingerprint
)}x;

# tweaks tested as of Nov 18 2002 by jm: see SpamAssassin-devel list archives
# for results.  The winners are now the default settings.
use constant IGNORE_TITLE_CASE => 1;
use constant TOKENIZE_LONG_8BIT_SEQS_AS_TUPLES => 1;
use constant TOKENIZE_LONG_TOKENS_AS_SKIPS => 1;

# We store header-mined tokens in the db with a "HHeaderName:val" format.
# some headers may contain lots of gibberish tokens, so allow a little basic
# compression by mapping the header name at least here.  these are the headers
# which appear with the most frequency in my db.  note: this doesn't have to
# be 2-way (ie. LHSes that map to the same RHS are not a problem), but mixing
# tokens from multiple different headers may impact accuracy, so might as well
# avoid this if possible. These are the top ones from my corpus, BTW (jm).
%HEADER_NAME_COMPRESSION = (
  'Message-Id'		=> '*m',
  'Message-ID'		=> '*M',
  'Received'		=> '*r',
  'User-Agent'		=> '*u',
  'References'		=> '*f',
  'In-Reply-To'		=> '*i',
  'From'		=> '*F',
  'Reply-To'		=> '*R',
  'Return-Path'		=> '*p',
  'X-Mailer'		=> '*x',
  'X-Authentication-Warning' => '*a',
  'Organization'	=> '*o',
  'Organisation'        => '*o',
  'Content-Type'	=> '*c',
);

# How big should the corpora be before we allow scoring using Bayesian tests?
# Do not use constants here. Also these may be better as conf items. TODO
$MIN_SPAM_CORPUS_SIZE_FOR_BAYES = 200;
$MIN_HAM_CORPUS_SIZE_FOR_BAYES = 200;

# How many seconds should the opportunistic_expire lock be valid?
$OPPORTUNISTIC_LOCK_VALID = 300;

# Should we use the Robinson f(w) equation from
# http://radio.weblogs.com/0101454/stories/2002/09/16/spamDetection.html ?
# It gives better results, in that scores are more likely to distribute
# into the <0.5 range for nonspam and >0.5 for spam.
use constant USE_ROBINSON_FX_EQUATION_FOR_LOW_FREQS => 1;

# Value for 'x' in the f(w) equation.
# "Let x = the number used when n [hits] is 0."
use constant CHI_ROBINSON_X_CONSTANT  => 0.538;
use constant GARY_ROBINSON_X_CONSTANT => 0.600;

# Value for 's' in the f(w) equation.  "We can see s as the "strength" (hence
# the use of "s") of an original assumed expectation ... relative to how
# strongly we want to consider our actual collected data."  Low 's' means
# trust collected data more strongly.
use constant CHI_ROBINSON_S_CONSTANT  => 0.373;
use constant GARY_ROBINSON_S_CONSTANT => 0.160;

# Should we ignore tokens with probs very close to the middle ground (.5)?
# tokens need to be outside the [ .5-MPS, .5+MPS ] range to be used.
use constant CHI_ROBINSON_MIN_PROB_STRENGTH  => 0.346;
use constant GARY_ROBINSON_MIN_PROB_STRENGTH => 0.430;

# How many of the most significant tokens should we use for the p(w)
# calculation?
use constant N_SIGNIFICANT_TOKENS => 150;

# How long a token should we hold onto?  (note: German speakers typically
# will require a longer token than English ones.)
use constant MAX_TOKEN_LENGTH => 15;

# lower and upper bounds for probabilities; we lock probs into these
# so one high-strength token can't overwhelm a set of slightly lower-strength
# tokens.
use constant PROB_BOUND_LOWER => 0.001;
use constant PROB_BOUND_UPPER => 0.999;

###########################################################################

sub new {
  my $class = shift;
  $class = ref($class) || $class;
  my ($main) = @_;
  my $self = {
    'main'              => $main,
    'log_raw_counts'	=> 0,
    'conf'		=> $main->{conf},

    # Off. See comment above cached_probs_get().
    #'cached_probs'	=> { },
    #'cached_probs_ns'	=> 0,
    #'cached_probs_nn'	=> 0,

  };
  bless ($self, $class);

  $self->{store} = new Mail::SpamAssassin::BayesStore ($self);

  $self;
}

###########################################################################

sub finish {
  my $self = shift;
  if (!$self->{main}->{conf}->{use_bayes}) { return; }
  $self->{store}->untie_db();
}

###########################################################################

sub sanity_check_is_untied {
  my $self = shift;

  # do a sanity check here.  Wierd things happen if we remain tied
  # after compiling; for example, spamd will never see that the
  # number of messages has reached the bayes-scanning threshold.
  if ($self->{store}->{already_tied} || $self->{store}->{is_locked}) {
    warn "SpamAssassin: oops! still tied/locked to bayes DBs, untie'ing\n";
    $self->{store}->untie_db();
  }
}

###########################################################################

# read configuration items to control bayes behaviour.  Called by
# BayesStore::read_db_configs().
sub read_db_configs {
  my ($self) = @_;
  my $conf = $self->{main}->{conf};

  # use of hapaxes.  Set on bayes object, since it controls prob
  # computation.
  $self->{bayes}->{use_hapaxes} = $conf->{bayes_use_hapaxes};

  # Use chi-squared combining instead of Gary-combining (Robinson/Graham-style
  # naive-Bayesian)?
  $self->{bayes}->{use_chi_sq_combining} = $conf->{bayes_use_chi2_combining};

  # Use the appropriate set of constants; the different systems have different
  # optimum settings for these.  (TODO: should these be exposed through Conf?)
  if ($self->{bayes}->{use_chi_sq_combining}) {
    $self->{robinson_x_constant} = CHI_ROBINSON_X_CONSTANT;
    $self->{robinson_s_constant} = CHI_ROBINSON_S_CONSTANT;
    $self->{robinson_min_prob_strength} = CHI_ROBINSON_MIN_PROB_STRENGTH;
  } else {
    $self->{robinson_x_constant} = GARY_ROBINSON_X_CONSTANT;
    $self->{robinson_s_constant} = GARY_ROBINSON_S_CONSTANT;
    $self->{robinson_min_prob_strength} = GARY_ROBINSON_MIN_PROB_STRENGTH;
  }

  $self->{robinson_s_times_x} =
      ($self->{robinson_x_constant} * $self->{robinson_s_constant});
}

###########################################################################

sub tokenize {
  my ($self, $msg, $body) = @_;

  my $wc = 0;
  $self->{tokens} = [ ];

  for (@{$body}) {
    $wc += $self->tokenize_line ($_, '', 1);
  }

  my %hdrs = $self->tokenize_headers ($msg);
  foreach my $prefix (keys %hdrs) {
    $wc += $self->tokenize_line ($hdrs{$prefix}, "H$prefix:", 0);
  }

  my @toks = @{$self->{tokens}}; delete $self->{tokens};
  ($wc, @toks);
}

sub tokenize_line {
  my $self = $_[0];
  my $tokprefix = $_[2];
  my $isbody = $_[3];
  local ($_) = $_[1];

  # include quotes, .'s and -'s for URIs, and [$,]'s for Nigerian-scam strings,
  # and ISO-8859-15 alphas.  Do not split on @'s; better results keeping it.
  # Some useful tokens: "$31,000,000" "www.clock-speed.net" "f*ck" "Hits!"
  tr/-A-Za-z0-9,\@\*\!_'"\$.\241-\377 / /cs;

  # DO split on "..." or "--" or "---"; common formatting error resulting in
  # hapaxes.  Keep the separator itself as a token, though, as long ones can
  # be good spamsigns.
  s/(\w)(\.{3,6})(\w)/$1 $2 $3/gs;
  s/(\w)(\-{2,6})(\w)/$1 $2 $3/gs;

  if (IGNORE_TITLE_CASE) {
    if ($isbody) {
      # lower-case Title Case at start of a full-stop-delimited line (as would
      # be seen in a Western language).
      s/(?:^|\.\s+)([A-Z])([^A-Z]+)(?:\s|$)/ ' '. (lc $1) . $2 . ' ' /ge;
    }
  }

  my $wc = 0;

  foreach my $token (split) {
    $token =~ s/^[-'"\.,]+//;        # trim non-alphanum chars at start or end
    $token =~ s/[-'"\.,]+$//;        # so we don't get loads of '"foo' tokens

    # *do* keep 3-byte tokens; there's some solid signs in there
    my $len = length($token);

    # but extend the stop-list. These are squarely in the gray
    # area, and it just slows us down to record them.
    next if $len < 3 ||
	($token =~ /^(?:a(?:nd|ny|ble|ll|re)|
		m(?:uch|ost|ade|ore|ail|ake|ailing|any|ailto)|
		t(?:his|he|ime|hrough|hat)|
		w(?:hy|here|ork|orld|ith|ithout|eb)|
		f(?:rom|or|ew)| e(?:ach|ven|mail)|
		o(?:ne|ff|nly|wn|ut)| n(?:ow|ot|eed)|
		s(?:uch|ame)| l(?:ook|ike|ong)|
		y(?:ou|our|ou're)|
		The|has|have|into|using|http|see|It's|it's|
		number|just|both|come|years|right|know|already|
		people|place|first|because|
		And|give|year|information|can)$/x);

    if ($len > MAX_TOKEN_LENGTH) {
      if (TOKENIZE_LONG_8BIT_SEQS_AS_TUPLES && $token =~ /[\xa0-\xff]{2}/) {
	# Matt sez: "Could be asian? Autrijus suggested doing character ngrams,
	# but I'm doing tuples to keep the dbs small(er)."  Sounds like a plan
	# to me! (jm)
	while ($token =~ s/^(..?)//) {
	  push (@{$self->{tokens}}, "8:$1"); $wc++;
	}
	next;
      }

      if (TOKENIZE_LONG_TOKENS_AS_SKIPS) {
	# Spambayes trick via Matt: Just retain 7 chars.  Do not retain
	# the length, it does not help; see my mail to -devel of Nov 20 2002.
	# "sk:" stands for "skip".
	$token = "sk:".substr($token, 0, 7);
      }
    }

    $wc++;
    push (@{$self->{tokens}}, $tokprefix.$token);

    # now do some token abstraction; in other words, make them act like
    # patterns instead of text copies.

    # replace digits with 'N'...
    if ($token =~ /\d/) {
      $token =~ s/\d/N/gs;

      # stop-list for numeric tokens.  These are squarely in the gray
      # area, and it just slows us down to record them.
      if ($token !~ /(?:
		  \QN:H*r:NN.NN.NNN\E |
		  \QN:H*r:N.N.N\E |
		  \QN:H*r:NNN.NNN.NNN\E |
		  \QN:H*r:NNNN\E |
		  \QN:H*r:NNN.NN.NN\E |
		  \QN:NNNN\E
		)/x)
      {
	push (@{$self->{tokens}}, 'N:'.$tokprefix.$token);
      }
    }
  }

  return $wc;
}

sub tokenize_headers {
  my ($self, $msg) = @_;

  my $hdrs = $msg->get_all_headers();
  my %parsed = ();

  # we don't care about whitespace; so fix continuation lines to make the next
  # bit easier
  $hdrs =~ s/\n[ \t]+/ /gs;

  # first, keep a copy of Received hdrs, so we can strip down to last 2
  my @rcvdlines = ($hdrs =~ /^Received: [^\n]*$/gim);

  # and now delete lines for headers we don't want (incl all Receiveds)
  $hdrs =~ s/^From \S+[^\n]+$//gim;

  $hdrs =~ s/^${IGNORED_HDRS}: [^\n]*$//gim;

  # and re-add the last 2 received lines: usually a good source of
  # spamware tokens and HELO names.
  if ($#rcvdlines >= 0) { $hdrs .= "\n".$rcvdlines[$#rcvdlines]; }
  if ($#rcvdlines >= 1) { $hdrs .= "\n".$rcvdlines[$#rcvdlines-1]; }

  # remove user-specified headers here, after Received, in case they
  # want to ignore that too
  foreach my $conf (@{$self->{main}->{conf}->{bayes_ignore_headers}}) {
    $hdrs =~ s/^\Q${conf}\E: [^\n]*$//gim;
  }

  while ($hdrs =~ /^(\S+): ([^\n]*)$/gim) {
    my $hdr = $1;
    my $val = $2;

    # special tokenization for some headers:
    if ($hdr =~ /^(?:|X-|Resent-)Message-I[dD]$/) {
      $val = $self->pre_chew_message_id ($val);
    }
    elsif ($hdr eq 'Received') {
      $val = $self->pre_chew_received ($val);
    }
    elsif ($hdr eq 'Content-Type') {
      $val = $self->pre_chew_content_type ($val);
    }
    elsif ($hdr eq 'MIME-Version') {
      $val =~ s/1\.0//;		# totally innocuous
    }
    elsif ($hdr =~ /^${MARK_PRESENCE_ONLY_HDRS}$/i) {
      $val = "1"; # just mark the presence, they create lots of hapaxen
    }

    # replace hdr name with "compressed" version if possible
    if (defined $HEADER_NAME_COMPRESSION{$hdr}) {
      $hdr = $HEADER_NAME_COMPRESSION{$hdr};
    }

    if (exists $parsed{$hdr}) {
      $parsed{$hdr} .= " ".$val;
    } else {
      $parsed{$hdr} = $val;
    }
    dbg ("tokenize: header tokens for $hdr = \"$parsed{$hdr}\"");
  }

  return %parsed;
}

sub pre_chew_content_type {
  my ($self, $val) = @_;

  # hopefully this will retain good bits without too many hapaxen
  if ($val =~ s/boundary=[\"\'](.*?)[\"\']/ /ig) {
    my $boundary = $1;
    $boundary =~ s/[a-fA-F0-9]/H/gs;
    # break up blocks of separator chars so they become their own tokens
    $boundary =~ s/([-_\.=]+)/ $1 /gs;
    $val .= $boundary;
  }

  # stop-list words for Content-Type header: these wind up totally gray
  $val =~ s/\b(?:text|charset)\b//;

  $val;
}

sub pre_chew_message_id {
  my ($self, $val) = @_;
  # we can (a) get rid of a lot of hapaxen and (b) increase the token
  # specificity by pre-parsing some common formats.

  # Outlook Express format:
  $val =~ s/<([0-9a-f]{4})[0-9a-f]{4}[0-9a-f]{4}\$
           ([0-9a-f]{4})[0-9a-f]{4}\$
           ([0-9a-f]{8})\@(\S+)>/ OEA$1 OEB$2 OEC$3 $4 /gx;

  # Exim:
  $val =~ s/<[A-Za-z0-9]{7}-[A-Za-z0-9]{6}-0[A-Za-z0-9]\@//;

  # Sendmail:
  $val =~ s/<20\d\d[01]\d[0123]\d[012]\d[012345]\d[012345]\d\.
           [A-F0-9]{10,12}\@//gx;

  # try to split Message-ID segments on probable ID boundaries. Note that
  # Outlook message-ids seem to contain a server identifier ID in the last
  # 8 bytes before the @.  Make sure this becomes its own token, it's a
  # great spam-sign for a learning system!  Be sure to split on ".".
  $val =~ s/[^_A-Za-z0-9]/ /g;
  $val;
}

sub pre_chew_received {
  my ($self, $val) = @_;

  # Thanks to Dan for these.  Trim out "useless" tokens; sendmail-ish IDs
  # and valid-format RFC-822/2822 dates

  $val =~ s/\swith\sSMTP\sid\sg[\dA-Z]{10,12}\s/ /gs;  # Sendmail
  $val =~ s/\swith\sESMTP\sid\s[\dA-F]{10,12}\s/ /gs;  # Sendmail
  $val =~ s/\bid\s[a-zA-Z0-9]{7,20}\b/ /gs;    # Sendmail
  $val =~ s/\bid\s[A-Za-z0-9]{7}-[A-Za-z0-9]{6}-0[A-Za-z0-9]/ /gs; # exim

  $val =~ s/(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun),\s)?
           [0-3\s]?[0-9]\s
           (?:Jan|Feb|Ma[ry]|Apr|Ju[nl]|Aug|Sep|Oct|Nov|Dec)\s
           (?:19|20)?[0-9]{2}\s
           [0-2][0-9](?:\:[0-5][0-9]){1,2}\s
           (?:\s*\(|\)|\s*(?:[+-][0-9]{4})|\s*(?:UT|[A-Z]{2,3}T))*
           //gx;

  # IPs: break down to nearest /24, to reduce hapaxes -- EXCEPT for
  # IPs in the 10 and 192.168 ranges, they gets lots of significant tokens
  # (on both sides)
  $val =~ s{(\b|[^\d])(\d{1,3}\.)(\d{1,3}\.)(\d{1,3})(\.\d{1,3})(\b|[^\d])}{
           if ($2 eq '10' || ($2 eq '192' && $3 eq '168')) {
             $1.$2.$3.$4.$5.$6;
           } else {
             $1.$2.$3.$4.$6;
           }
         }gex;

  # trim these: they turn out as the most common tokens, but with a
  # prob of about .5.  waste of space!
  $val =~ s/\b(?:with|from|for|SMTP|ESMTP)\b/ /g;

  $val;
}

###########################################################################

sub learn {
  my ($self, $isspam, $msg) = @_;

  if (!$self->{main}->{conf}->{use_bayes}) { return; }
  if (!defined $msg) { return; }
  my $body = $self->get_body_from_msg ($msg);
  my $ret;

  # we still tie for writing here, since we write to the seen db
  # synchronously
  eval {
    local $SIG{'__DIE__'};	# do not run user die() traps in here

    if ($self->{store}->tie_db_writable()) {
      $ret = $self->learn_trapped ($isspam, $msg, $body);

      if (!$self->{main}->{learn_caller_will_untie}) {
        $self->{store}->untie_db();
      }
    }
  };

  if ($@) {		# if we died, untie the dbs.
    my $failure = $@;
    $self->{store}->untie_db();
    die $failure;
  }

  return $ret;
}

# this function is trapped by the wrapper above
sub learn_trapped {
  my ($self, $isspam, $msg, $body) = @_;

  my $msgid = $self->get_msgid ($msg);
  my $seen = $self->{store}->seen_get ($msgid);
  if (defined ($seen)) {
    if (($seen eq 's' && $isspam) || ($seen eq 'h' && !$isspam)) {
      dbg ("$msgid: already learnt correctly, not learning twice");
      return;
    } elsif ($seen !~ /^[hs]$/) {
      warn ("db_seen corrupt: value='$seen' for $msgid. ignored");
    } else {
      dbg ("$msgid: already learnt as opposite, forgetting first");
      $self->forget ($msg);
    }
  }

  if ($isspam) {
    $self->{store}->nspam_nham_change (1, 0);
  } else {
    $self->{store}->nspam_nham_change (0, 1);
  }

  my ($wc, @tokens) = $self->tokenize ($msg, $body);
  my %seen = ();

  for (@tokens) {
    if ($seen{$_}) { next; } else { $seen{$_} = 1; }

    if ($isspam) {
      $self->{store}->tok_count_change (1, 0, $_);
    } else {
      $self->{store}->tok_count_change (0, 1, $_);
    }
  }

  $self->{store}->seen_put ($msgid, ($isspam ? 's' : 'h'));
  1;
}

###########################################################################

sub forget {
  my ($self, $msg) = @_;

  if (!$self->{main}->{conf}->{use_bayes}) { return; }
  if (!defined $msg) { return; }
  my $body = $self->get_body_from_msg ($msg);
  my $ret;

  # we still tie for writing here, since we write to the seen db
  # synchronously
  eval {
    local $SIG{'__DIE__'};	# do not run user die() traps in here

    if ($self->{store}->tie_db_writable()) {
      $ret = $self->forget_trapped ($msg, $body);

      if (!$self->{main}->{learn_caller_will_untie}) {
        $self->{store}->untie_db();
      }
    }
  };

  if ($@) {		# if we died, untie the dbs.
    my $failure = $@;
    $self->{store}->untie_db();
    die $failure;
  }

  return $ret;
}

# this function is trapped by the wrapper above
sub forget_trapped {
  my ($self, $msg, $body) = @_;

  my $msgid = $self->get_msgid ($msg);
  my $seen = $self->{store}->seen_get ($msgid);
  my $isspam;
  if (defined ($seen)) {
    if ($seen eq 's') {
      $isspam = 1;
    } elsif ($seen eq 'h') {
      $isspam = 0;
    } else {
      dbg ("forget: message $msgid not learnt, ignored");
      return;
    }
  }

  if ($isspam) {
    $self->{store}->nspam_nham_change (-1, 0);
  } else {
    $self->{store}->nspam_nham_change (0, -1);
  }

  my ($wc, @tokens) = $self->tokenize ($msg, $body);
  my %seen = ();
  for (@tokens) {
    if ($seen{$_}) { next; } else { $seen{$_} = 1; }

    if ($isspam) {
      $self->{store}->tok_count_change (-1, 0, $_);
    } else {
      $self->{store}->tok_count_change (0, -1, $_);
    }
  }

  $self->{store}->seen_delete ($msgid);
  1;
}

###########################################################################

sub get_msgid {
  my ($self, $msg) = @_;

  my $msgid = $msg->get_header("Message-Id");
  if (!defined $msgid) { $msgid = time.".$$\@sa_generated"; }

  # remove \r and < and > prefix/suffixes
  chomp $msgid;
  $msgid =~ s/^<//; $msgid =~ s/>.*$//g;

  $msgid;
}

sub get_body_from_msg {
  my ($self, $msg) = @_;

  if (!ref $msg) {
    # I have no idea why this seems to happen. TODO
    warn "msg not a ref: '$msg'";
    return [ ];
  }
  my $permsgstatus =
        Mail::SpamAssassin::PerMsgStatus->new($self->{main}, $msg);
  my $body = $permsgstatus->get_decoded_stripped_body_text_array();
  $permsgstatus->finish();

  if (!defined $body) {
    # why?!
    warn "failed to get body for ".$self->{msg}->get_header("Message-Id")."\n";
    return [ ];
  }

  return $body;
}

###########################################################################

sub sync {
  my ($self, $opts) = @_;
  if (!$self->{main}->{conf}->{use_bayes}) { return 0; }
  $self->{store}->sync_journal($opts);
  $self->{store}->expire_old_tokens($opts);
  return 0;
}

###########################################################################

# compute the probability that that token is spammish
sub compute_prob_for_token {
  my ($self, $token, $ns, $nn) = @_;

  my ($s, $n, $atime) = $self->{store}->tok_get ($token);
  return if ($s == 0 && $n == 0);

  if (!USE_ROBINSON_FX_EQUATION_FOR_LOW_FREQS) {
    return if ($s + $n < 10);      # ignore low-freq tokens
  }

  if (!$self->{use_hapaxes}) {
    return if ($s + $n < 2);
  }

  my $prob;

  # Off. See comment above cached_probs_get().
  #use constant CACHE_S_N_TO_PROBS_MAPPING => 1;
  #if (CACHE_S_N_TO_PROBS_MAPPING) {
  #$prob = $self->cached_probs_get ($ns, $nn, $s, $n);
  #if (defined $prob) { return $prob; }
  #}

  my $ratios = ($s / $ns);
  my $ration = ($n / $nn);

  if ($ratios == 0 && $ration == 0) {
    warn "oops? ratios == ration == 0";
    return 0.5;
  } else {
    $prob = ($ratios) / ($ration + $ratios);
  }

  if (USE_ROBINSON_FX_EQUATION_FOR_LOW_FREQS) {
    # use Robinson's f(x) equation for low-n tokens, instead of just
    # ignoring them
    my $robn = $s+$n;
    $prob = ($self->{robinson_s_times_x} + ($robn * $prob))
                             /
		  ($self->{robinson_s_constant} + $robn);
  }

  if ($self->{log_raw_counts}) {
    $self->{raw_counts} .= " s=$s,n=$n ";
  }

  # Off. See comment above cached_probs_get().
  #if (CACHE_S_N_TO_PROBS_MAPPING) {
  #$self->cached_probs_put ($ns, $nn, $s, $n, $prob);
  #}

  return $prob;
}

###########################################################################
# An in-memory cache of { nspam, nham } => probability.
# Off for now: this actually slows things down by about 7%, while
# increasing memory usage!

sub cached_probs_get {
  my ($self, $ns, $nn, $s, $n) = @_;

  my $prob;
  my $shash = $self->{cached_probs}->{$s}; if (!defined $shash) { return undef; }
  $prob = $shash->{$n}; if (!defined $prob) { return undef; }
  return $prob;
}

sub cached_probs_put {
  my ($self, $ns, $nn, $s, $n, $prob) = @_;

  if (exists $self->{cached_probs}->{$s}) {
    $self->{cached_probs}->{$s}->{$n} = $prob;
  } else {
    $self->{cached_probs}->{$s} = { $n => $prob };
  }
}

sub check_for_cached_probs_invalidated {
  my ($self, $ns, $nn) = @_;
  if ($self->{cached_probs_ns} != $ns || $self->{cached_probs_nn} != $nn) {
    $self->{cached_probs} = { };	# blow away the old one
    $self->{cached_probs_ns} = $ns;
    $self->{cached_probs_nn} = $nn;
    return 1;
  }
  return 0;
}

# Check to make sure we can tie() the DB, and we have enough entries to do a scan
sub is_scan_available {
  my $self = shift;

  return 0 unless $self->{main}->{conf}->{use_bayes};
  return 0 unless $self->{store}->tie_db_readonly();

  my ($ns, $nn) = $self->{store}->nspam_nham_get();

  if ($ns < $MIN_SPAM_CORPUS_SIZE_FOR_BAYES) {
    dbg("debug: Only $ns spam(s) in Bayes DB < $MIN_SPAM_CORPUS_SIZE_FOR_BAYES");
    $self->{store}->untie_db();
    return 0;
  }
  if ($nn < $MIN_HAM_CORPUS_SIZE_FOR_BAYES) {
    dbg("debug: Only $nn ham(s) in Bayes DB < $MIN_HAM_CORPUS_SIZE_FOR_BAYES");
    $self->{store}->untie_db();
    return 0;
  }

  return 1;
}

###########################################################################
# Finally, the scoring function for testing mail.

sub scan {
  my ($self, $msg, $body) = @_;

  if ( !$self->is_scan_available() ) {
    goto skip;
  }

  my ($ns, $nn) = $self->{store}->nspam_nham_get();

  if ($self->{log_raw_counts}) {
    $self->{raw_counts} = " ns=$ns nn=$nn ";
  }

  dbg ("bayes corpus size: nspam = $ns, nham = $nn");

  my ($wc, @tokens) = $self->tokenize ($msg, $body);
  my %seen = ();
  my $pw;

  # Off. See comment above cached_probs_get().
  #if (CACHE_S_N_TO_PROBS_MAPPING) {
  #$self->check_for_cached_probs_invalidated($ns, $nn);
  #}

  my %pw = map {
    if ($seen{$_}) {
      ();		# exit map()
    } else {
      $seen{$_} = 1;
      $pw = $self->compute_prob_for_token ($_, $ns, $nn);
      if (!defined $pw) {
	();		# exit map()
      } else {
	($_ => $pw);
      }
    }
  } @tokens;

  if ($wc <= 0) {
    dbg ("cannot use bayes on this message; no tokens found");
    goto skip;
  }

  # now take the $count most significant tokens and calculate probs using
  # Robinson's formula.
  my $count = N_SIGNIFICANT_TOKENS;
  my @sorted = ();

  for (sort {
              abs($pw{$b} - 0.5) <=> abs($pw{$a} - 0.5)
            } keys %pw)
  {
    if ($count-- < 0) { last; }
    my $pw = $pw{$_};
    next if (abs($pw - 0.5) < $self->{robinson_min_prob_strength});

    # enforce (max PROB_BOUND_LOWER (min PROB_BOUND_UPPER (score))) as per
    # Graham; it allows a majority of spam clues to override 1 or 2
    # very-strong nonspam clues.  Moved here from above to save some CPU.
    #
    if ($pw < PROB_BOUND_LOWER) {
      $pw = PROB_BOUND_LOWER;
    } elsif ($pw > PROB_BOUND_UPPER) {
      $pw = PROB_BOUND_UPPER;
    }

    push (@sorted, $pw);

    # update the atime on this token, it proved useful
    $self->{store}->tok_touch ($_);

    dbg ("bayes token '$_' => $pw");
  }

  if ($#sorted < 0) {
    dbg ("cannot use bayes on this message; db not initialised yet");
    goto skip;
  }

  my $score;

  if ($self->{use_chi_sq_combining}) {
    $score = chi_squared_probs_combine (@sorted);
  } else {
    $score = robinson_naive_bayes_probs_combine (@sorted);
  }

  dbg ("bayes: score = $score");

  if ($self->{log_raw_counts}) {
    print "#Bayes-Raw-Counts: $self->{raw_counts}\n";
  }

  $self->{store}->add_touches_to_journal();
  $self->{store}->scan_count_increment();

  $self->opportunistic_expire();
  $self->{store}->untie_db();
  return $score;

skip:
  dbg ("bayes: not scoring message, returning 0.5");
  $self->{store}->untie_db() if ( $self->{store}->{already_tied} );
  return 0.5;           # nice and neutral
}

sub opportunistic_expire {
  my($self) = @_;

  # Is an expire or journal sync running?
  my $running_expire = $self->{store}->get_running_expire_tok();
  if ( defined $running_expire && $running_expire+$OPPORTUNISTIC_LOCK_VALID > time() ) { return; }

  # handle expiry and journal syncing
  if ($self->{store}->expiry_due()) {
    $self->sync();
  }
}

###########################################################################

sub dbg { Mail::SpamAssassin::dbg (@_); }
sub sa_die { Mail::SpamAssassin::sa_die (@_); }

###########################################################################

sub robinson_naive_bayes_probs_combine {
  my (@sorted) = @_;

  my $wc = scalar @sorted;
  my $P = 1;
  my $Q = 1;

  foreach my $pw (@sorted) {
    $P *= (1-$pw);
    $Q *= $pw;
  }
  $P = 1 - ($P ** (1 / $wc));
  $Q = 1 - ($Q ** (1 / $wc));
  return (1 + ($P - $Q) / ($P + $Q)) / 2.0;
}

###########################################################################

# Chi-squared function
sub chi2q {
  my ($x2, $v) = @_;

  die "v must be even in chi2q(x2, v)" if $v & 1;
  my $m = $x2 / 2.0;
  my ($sum, $term);
  $sum = $term = exp(0 - $m);
  for my $i (1 .. (($v/2)-1)) {
    $term *= $m / $i;
    $sum += $term;
  }
  return $sum < 1.0 ? $sum : 1.0;
}

# Chi-Squared method. Produces mostly boolean $result,
# but with a grey area.
sub chi_squared_probs_combine  {
  my (@sorted) = @_;
  # @sorted contains an array of the probabilities

  my ($H, $S);
  my ($Hexp, $Sexp);
  $H = $S = 1.0;
  $Hexp = $Sexp = 0;

  my $num_clues = @sorted;
  use POSIX qw(frexp);

  foreach my $prob (@sorted) {
    $S *= 1.0 - $prob;
    $H *= $prob;
    if ($S < 1e-200) {
      my $e;
      ($S, $e) = frexp($S);
      $Sexp += $e;
    }
    if ($H < 1e-200) {
      my $e;
      ($H, $e) = frexp($H);
      $Hexp += $e;
    }
  }

  use constant LN2 => log(2);

  $S = log($S) + $Sexp + LN2;
  $H = log($H) + $Hexp + LN2;

  my $result;
  if ($num_clues) {
    $S = 1.0 - chi2q(-2.0 * $S, 2 * $num_clues);
    $H = 1.0 - chi2q(-2.0 * $H, 2 * $num_clues);
    $result = (($S - $H) + 1.0) / 2.0;
  } else {
    $result = 0.5;
  }

  return $result;
}

###########################################################################

1;