=head1 NAME

Mail::SpamAssassin - Mail::Audit spam detector plugin

=head1 SYNOPSIS

  my $mail = Mail::SpamAssassin::NoMailAudit->new();

  my $spamtest = Mail::SpamAssassin->new();
  my $status = $spamtest->check ($mail);

  if ($status->is_spam ()) {
    $status->rewrite_mail ();
    $mail->accept("spamfolder");

  } else {
    $mail->accept();		# to default incoming mailbox
  }
  ...


=head1 DESCRIPTION

Mail::SpamAssassin is a module to identify spam using text analysis and several
internet-based realtime blacklists.

Using its rule base, it uses a wide range of heuristic tests on mail headers
and body text to identify "spam", also known as unsolicited commercial email.

Once identified, the mail can then be optionally tagged as spam for later
filtering using the user's own mail user-agent application.

This module also implements a Mail::Audit plugin, allowing SpamAssassin to be
used in a Mail::Audit filter.  If you wish to use a command-line filter tool,
try the C<spamassassin> or C<spamd> tools provided.

Note that, if you're using Mail::Audit, the constructor for the Mail::Audit
object must use the C<nomime> option, like so:

        my $ma = new Mail::Audit ( nomime => 1 );

SpamAssassin also includes support for reporting spam messages to collaborative
filtering databases, such as Vipul's Razor ( http://razor.sourceforge.net/ ).

=head1 METHODS

=over 4

=cut

package Mail::SpamAssassin;

# We do our best to make SA run with any Perl downto 5.005. You might want to
# read <http://www.perldoc.com/perl5.8.0/pod/perl56delta.html> if you plan to 
# hack SA and are used to Perl 5.6+.
# (jm: Matt's just saying that 'cos they use 5.005 in MessageLabs ;)
use 5.005;

use Mail::SpamAssassin::Conf;
use Mail::SpamAssassin::ConfSourceSQL;
use Mail::SpamAssassin::PerMsgStatus;
use Mail::SpamAssassin::NoMailAudit;

use File::Basename;
use File::Path;
use File::Spec 0.8;
use File::Copy;
use Cwd;
use Config;

# Load Time::HiRes if it's available
BEGIN {
  eval { require Time::HiRes };
  Time::HiRes->import( qw(time) ) unless $@;
}

use vars qw{
	@ISA $VERSION $SUB_VERSION @EXTRA_VERSION $HOME_URL $DEBUG $TIMELOG
        $IS_DEVEL_BUILD
	@default_rules_path @default_prefs_path
	@default_userprefs_path @default_userstate_dir
	@site_rules_path
};

$VERSION = "2.44";              # update after release
$IS_DEVEL_BUILD = 0;            # change for release versions

# Create the hash so that it really points to something, otherwise we can't
# get a reference to it -- Marc
$TIMELOG->{dummy}=0;
@ISA = qw();

# SUB_VERSION is now <revision>-<yyyy>-<mm>-<dd>-<state>
$SUB_VERSION = lc(join('-', (split(/[ \/]/, '$Id: SpamAssassin.pm,v 1.115.2.24 2003/01/30 16:15:18 msquadrat Exp $'))[2 .. 5, 8]));

# If you hacked up your SA, add a token to identify it here. Eg.: I use
# "mss<number>", <number> increasing with every hack.
# Deersoft might want to use "pro" :o)
@EXTRA_VERSION = qw();

if ($IS_DEVEL_BUILD) {
  push(@EXTRA_VERSION, 'cvs');
}

sub Version { join('-', $VERSION, @EXTRA_VERSION) }

$HOME_URL = "http://spamassassin.org/";

# note that the CWD takes priority.  This is required in case a user
# is testing a new version of SpamAssassin on a machine with an older
# version installed.  Unless you can come up with a fix for this that
# allows "make test" to work, don't change this.
@default_rules_path = (
	'./rules',
	'../rules',
        '__def_rules_dir__',
        '__prefix__/share/spamassassin',
        '/usr/local/share/spamassassin',
  	'/usr/share/spamassassin',
);

# first 3 are BSDish, latter 2 Linuxish
@site_rules_path = (
        '__local_rules_dir__',
        '__prefix__/etc/mail/spamassassin',
        '__prefix__/etc/spamassassin',
        '/usr/local/etc/spamassassin',
	'/usr/pkg/etc/spamassassin',
        '/usr/etc/spamassassin',
  	'/etc/mail/spamassassin',
  	'/etc/spamassassin',
);

@default_prefs_path = (
        '__local_rules_dir__/user_prefs.template',
        '__prefix__/etc/mail/spamassassin/user_prefs.template',
        '__prefix__/share/spamassassin/user_prefs.template',
	'/etc/spamassassin/user_prefs.template',
        '/etc/mail/spamassassin/user_prefs.template',
        '/usr/local/share/spamassassin/user_prefs.template',
        '/usr/share/spamassassin/user_prefs.template',
);

@default_userprefs_path = (
        '~/.spamassassin/user_prefs',
);

@default_userstate_dir = (
        '~/.spamassassin',
);

###########################################################################

=item $f = new Mail::SpamAssassin( [ { opt => val, ... } ] )

Constructs a new C<Mail::SpamAssassin> object.  You may pass the
following attribute-value pairs to the constructor.

=over 4

=item rules_filename

The filename to load spam-identifying rules from. (optional)

=item userprefs_filename

The filename to load preferences from. (optional)

=item userstate_dir

The directory user state is stored in. (optional)

=item config_text

The text of all rules and preferences.  If you prefer not to load the rules
from files, read them in yourself and set this instead.  As a result, this will
override the settings for C<rules_filename> and C<userprefs_filename>.

=item local_tests_only

If set to 1, no tests that require internet access will be performed. (default:
0)

=item dont_copy_prefs

If set to 1, the user preferences file will not be created if it doesn't
already exist. (default: 0)

=item save_pattern_hits

If set to 1, the patterns hit can be retrieved from the
C<Mail::SpamAssassin::PerMsgStatus> object.  Used for debugging.

=item home_dir_for_helpers

If set, the B<HOME> environment variable will be set to this value
when using test applications that require their configuration data,
such as Razor, Pyzor and DCC.

=back

If none of C<rules_filename>, C<userprefs_filename>, or C<config_text> is set,
the C<Mail::SpamAssassin> module will search for the configuration files in the
usual installed locations.

=cut

sub new {
  my $class = shift;
  $class = ref($class) || $class;

  my $self = shift;
  if (!defined $self) { $self = { }; }
  bless ($self, $class);

  $DEBUG->{enabled} = 0;
  if (defined $self->{debug} && $self->{debug} > 0) { $DEBUG->{enabled} = 1; }

  # This should be moved elsewhere, I know, but SA really needs debug sets 
  # I'm putting the intialization here for now, move it if you want

  # For each part of the code, you can set debug levels. If the level is
  # progressive, use negative numbers (the more negative, the move debug info
  # is put out), and if you want to use bit fields, use positive numbers
  # All code path debug codes should be listed here with a value of 0 if you
  # want them disabled -- Marc

  $DEBUG->{datediff}=-1;
  $DEBUG->{razor}=-3;
  $DEBUG->{rbl}=0;
  $DEBUG->{timelog}=0;
  $DEBUG->{dnsavailable}=-2;
  # Bitfield:
  # header regex: 1 | body-text: 2 | uri tests: 4 | raw-body-text: 8
  # full-text regexp: 16 | run_eval_tests: 32 | run_rbl_eval_tests: 64
  $DEBUG->{rulesrun}=64;

  $self->{conf} ||= new Mail::SpamAssassin::Conf ($self);

  $self->{save_pattern_hits} ||= 0;

  $self;
}

###########################################################################

=item $status = $f->check ($mail)

Check a mail, encapsulated in a C<Mail::Audit> object, to determine if
it is spam or not.

Returns a C<Mail::SpamAssassin::PerMsgStatus> object which can be
used to test or manipulate the mail message.

Note that the C<Mail::SpamAssassin> object can be re-used for further messages
without affecting this check; in OO terminology, the C<Mail::SpamAssassin>
object is a "factory".   However, if you do this, be sure to call the
C<finish()> method on the status objects when you're done with them.

=cut

sub check {
  my ($self, $mail_obj) = @_;
  local ($_);

  timelog("Starting SpamAssassin Check", "SAfull", 1);
  $self->init(1);
  timelog("Init completed");
  my $mail = $self->encapsulate_mail_object ($mail_obj);
  my $msg = Mail::SpamAssassin::PerMsgStatus->new($self, $mail);
  chomp($TIMELOG->{mesgid} = ($mail_obj->get("Message-Id") || 'nomsgid'));
  $TIMELOG->{mesgid} =~ s#<(.*)>#$1#;
  # Message-Id is used for a filename on disk, so we can't have '/' in it.
  $TIMELOG->{mesgid} =~ s#/#-#g;
  timelog("Created message object, checking message", "msgcheck", 1);
  $msg->check();
  timelog("Done checking message", "msgcheck", 2);
  timelog("Done running SpamAssassin", "SAfull", 2);
  $msg;
}

###########################################################################

=item $status = $f->check_message_text ($mailtext)

Check a mail, encapsulated in a plain string, to determine if it is spam or
not.

Otherwise identical to C<$f->check()> above.

=cut

sub check_message_text {
  my ($self, $mailtext) = @_;
  my @lines = split (/^/m, $mailtext);
  my $mail_obj = Mail::SpamAssassin::NoMailAudit->new ('data' => \@lines);
  return $self->check ($mail_obj);
}

###########################################################################

=item $f->report_as_spam ($mail, $options)

Report a mail, encapsulated in a C<Mail::Audit> object, as human-verified spam.
This will submit the mail message to live, collaborative, spam-blocker
databases, allowing other users to block this message.

Options is an optional reference to a hash of options.  Currently these
can be:

=over 4

=item dont_report_to_razor

Inhibits reporting of the spam to Razor; useful if you know it's already
been listed there.

=back

=cut

sub report_as_spam {
  my ($self, $mail, $options) = @_;
  local ($_);

  $self->init(1);
  $mail = $self->encapsulate_mail_object ($mail);

  require Mail::SpamAssassin::Reporter;
  $mail = Mail::SpamAssassin::Reporter->new($self, $mail, $options);
  $mail->report ();
}

###########################################################################

=item $f->add_address_to_whitelist ($addr)

Given a string containing an email address, add it to the automatic
whitelist database.

=cut

sub add_address_to_whitelist {
  my ($self, $addr) = @_;
  my $list = Mail::SpamAssassin::AutoWhitelist->new($self);
  if ($list->add_known_good_address ($addr)) {
    print "SpamAssassin auto-whitelist: adding address: $addr\n";
  }
  $list->finish();
}

=item $f->add_all_addresses_to_whitelist ($mail)

Given a mail message, find as many addresses in the usual headers (To, Cc, From
etc.), and the message body, and add them to the automatic whitelist database.

=cut

sub add_all_addresses_to_whitelist {
  my ($self, $mail_obj) = @_;

  my $list = Mail::SpamAssassin::AutoWhitelist->new($self);
  foreach my $addr ($self->find_all_addrs_in_mail ($mail_obj)) {
    if ($list->add_known_good_address ($addr)) {
      print "SpamAssassin auto-whitelist: adding address: $addr\n";
    }
  }
  $list->finish();
}

###########################################################################

=item $f->remove_address_from_whitelist ($addr)

Given a string containing an email address, remove it from the automatic
whitelist database.

=cut

sub remove_address_from_whitelist {
  my ($self, $addr) = @_;
  my $list = Mail::SpamAssassin::AutoWhitelist->new($self);
  if ($list->remove_address ($addr)) {
    print "SpamAssassin auto-whitelist: removing address: $addr\n";
  }
  $list->finish();
}

=item $f->remove_all_addresses_from_whitelist ($mail)

Given a mail message, find as many addresses in the usual headers (To, Cc, From
etc.), and the message body, and remove them from the automatic whitelist
database.

=cut

sub remove_all_addresses_from_whitelist {
  my ($self, $mail_obj) = @_;

  my $list = Mail::SpamAssassin::AutoWhitelist->new($self);
  foreach my $addr ($self->find_all_addrs_in_mail ($mail_obj)) {
    if ($list->remove_address ($addr)) {
      print "SpamAssassin auto-whitelist: removing address: $addr\n";
    }
  }
  $list->finish();
}

###########################################################################

=item $f->add_address_to_blacklist ($addr)

Given a string containing an email address, add it to the automatic
whitelist database with a high score, effectively blacklisting them.

=cut

sub add_address_to_blacklist {
  my ($self, $addr) = @_;
  my $list = Mail::SpamAssassin::AutoWhitelist->new($self);
  if ($list->add_known_bad_address ($addr)) {
    print "SpamAssassin auto-whitelist: blacklisting address: $addr\n";
  }
  $list->finish();
}

=item $f->add_all_addresses_to_blacklist ($mail)

Given a mail message, find as many addresses in the usual headers (To,
Cc, From etc.), and the message body, and adds them to the automatic
whitelist database with a high score, effectively blacklisting them.

=cut

sub add_all_addresses_to_blacklist {
  my ($self, $mail_obj) = @_;

  my $list = Mail::SpamAssassin::AutoWhitelist->new($self);
  foreach my $addr ($self->find_all_addrs_in_mail ($mail_obj)) {
    if ($list->add_known_bad_address ($addr)) {
      print "SpamAssassin auto-whitelist: blacklisting address: $addr\n";
    }
  }
  $list->finish();
}

###########################################################################

=item $f->reply_with_warning ($mail, $replysender)

Reply to the sender of a mail, encapsulated in a C<Mail::Audit> object,
explaining that their message has been added to spam-tracking databases
and deleted.  To be used in conjunction with C<report_as_spam>.  The
C<$replysender> argument should contain an email address to use as the
sender of the reply message.

=cut

sub reply_with_warning {
  my ($self, $mail, $replysender) = @_;
  $self->init(1);
  $mail = $self->encapsulate_mail_object ($mail);

  require Mail::SpamAssassin::Replier;
  $mail = Mail::SpamAssassin::Replier->new ($self, $mail);
  $mail->reply ($replysender);
}

###########################################################################

=item $text = $f->remove_spamassassin_markup ($mail)

Returns the text of the message, with any SpamAssassin-added text (such
as the report, or X-Spam-Status headers) stripped.

Note that the B<$mail> object is not modified.

=cut

sub remove_spamassassin_markup {
  my ($self, $mail_obj) = @_;
  local ($_);

  $self->init(1);
  my $mail = $self->encapsulate_mail_object ($mail_obj);
  my $hdrs = $mail->get_all_headers();

  # remove DOS line endings
  $hdrs =~ s/\r//gs;

  # de-break lines on SpamAssassin-modified headers.
  1 while $hdrs =~ s/(\n(?:X-Spam|Subject)[^\n]+?)\n[ \t]+/$1 /gs;

  # reinstate the old content type
  if ($hdrs =~ /^X-Spam-Prev-Content-Type: /m) {
    $hdrs =~ s/\nContent-Type: [^\n]*?\n/\n/gs;
    $hdrs =~ s/\nX-Spam-Prev-(Content-Type: [^\n]*\n)/\n$1/gs;

    # remove embedded spaces where they shouldn't be; a common problem
    $hdrs =~ s/(Content-Type: .*?boundary=\".*?) (.*?\".*?\n)/$1$2/gs;
  }

  # reinstate the old content transfer encoding
  if ($hdrs =~ /^X-Spam-Prev-Content-Transfer-Encoding: /m) {
    $hdrs =~ s/\nContent-Transfer-Encoding: [^\n]*?\n/\n/gs;
    $hdrs =~ s/\nX-Spam-Prev-(Content-Transfer-Encoding: [^\n]*\n)/\n$1/gs;
  }

  # remove the headers we added
  1 while $hdrs =~ s/\nX-Spam-[^\n]*?\n/\n/gs;

  my $tag = $self->{conf}->{subject_tag};

  while ( $tag =~ /(_HITS_|_REQD_)/g ) {
       my $typeoftag = $1;
       $hdrs =~ s/^Subject: (\D*)\d\d\.\d\d/Subject: $1$typeoftag/m;
  } # Wow. Very Hackish.

  1 while $hdrs =~ s/^Subject: \Q${tag}\E /Subject: /gm;

  # ok, next, the report.
  # This is a little tricky since we can have either 0, 1 or 2 reports;
  # 0 for the non-spam case, 1 for normal filtering, and 2 for -t (where
  # an extra report is appended at the end of the mail).

  my @newbody = ();
  my $inreport = 0;
  foreach $_ (@{$mail->get_body()})
  {
    s/\r?$//;	# DOS line endings

    if (/^SPAM: ----/ && $inreport == 0) {
      # we've just entered a report.  If there's a blank line before the
      # report, get rid of it...
      if ($#newbody > 0 && $newbody[$#newbody-1] =~ /^$/) {
	pop (@newbody);
      }
      # and skip on to the next line...
      $inreport = 1; next;
    }

    if ($inreport && /^$/) {
      # blank line at end of report; skip it.  Also note that we're
      # now out of the report.
      $inreport = 0; next;
    }

    # finally, if we're not in the report, add it to the body array
    if (!$inreport) {
      push (@newbody, $_);
    }
  }

  return $hdrs."\n".join ('', @newbody);
}

###########################################################################

=item $f->read_scoreonly_config ($filename)

Read a configuration file and parse only scores from it.  This is used
to safely allow multi-user daemons to read per-user config files
without having to use C<setuid()>.

=cut

sub read_scoreonly_config {
  my ($self, $filename) = @_;

  if (!open(IN,"<$filename")) {
    # the file may not exist; this should not be verbose
    dbg ("read_scoreonly_config: cannot open \"$filename\": $!");
    return;
  }
  my $text = join ('',<IN>);
  close IN;

  $self->{conf}->parse_scores_only ($text);
  if ($self->{conf}->{allow_user_rules}) {
      dbg("finishing parsing!");
      $self->{conf}->finish_parsing();
  }
}

###########################################################################

=item $f->load_scoreonly_sql ($username)

Read configuration paramaters from SQL database and parse scores from it.  This
will only take effect if the perl C<DBI> module is installed, and the
configuration parameters C<user_scores_dsn>, C<user_scores_sql_username>, and
C<user_scores_sql_password> are set correctly.

=cut

sub load_scoreonly_sql {
  my ($self, $username) = @_;

  my $src = Mail::SpamAssassin::ConfSourceSQL->new ($self);
  $src->load($username);
}


###########################################################################

=item $f->set_persistent_address_list_factory ($factoryobj)

Set the persistent address list factory, used to create objects for the
automatic whitelist algorithm's persistent-storage back-end.  See
C<Mail::SpamAssassin::PersistentAddrList> for the API these factory objects
must implement, and the API the objects they produce must implement.

=cut

sub set_persistent_address_list_factory {
  my ($self, $fac) = @_;
  $self->{pers_addr_list_factory} = $fac;
}

###########################################################################

=item $f->compile_now ($use_user_prefs)

Compile all patterns, load all configuration files, and load all
possibly-required Perl modules.

Normally, Mail::SpamAssassin uses lazy evaluation where possible, but if you
plan to fork() or start a new perl interpreter thread to process a message,
this is suboptimal, as each process/thread will have to perform these actions.

Call this function in the master thread or process to perform the actions
straightaway, so that the sub-processes will not have to.

If C<$use_user_prefs> is 0, this will initialise the SpamAssassin
configuration without reading the per-user configuration file and it will
assume that you will call C<read_scoreonly_config> at a later point.

=cut

sub compile_now {
  my ($self, $use_user_prefs) = @_;

  # note: this may incur network access. Good.  We want to make sure
  # as much as possible is preloaded!
  # Timelog uses the Message-ID for the filename on disk, so let's set that
  # to a value easy to recognize. It'll show when spamd was restarted -- Marc
  my @testmsg = ("From: ignore\@compiling.spamassassin.taint.org\n", 
    "Message-Id:  <".time."\@spamassassin_spamd_init>\n", "\n",
    "I need to make this message body somewhat long so TextCat preloads\n"x20);

  dbg ("ignore: test message to precompile patterns and load modules");
  $self->init($use_user_prefs);
  my $mail = Mail::SpamAssassin::NoMailAudit->new(data => \@testmsg);
  $self->check($mail)->finish();

  # load SQL modules now as well
  my $dsn = $self->{conf}->{user_scores_dsn};
  if ($dsn ne '') {
    Mail::SpamAssassin::ConfSourceSQL::load_modules();
  }

  1;
}

###########################################################################

=item $failed = $f->lint_rules ()

Syntax-check the current set of rules.  Returns the number of 
syntax errors discovered, or 0 if the configuration is valid.

=cut

sub lint_rules {
  my ($self) = @_;

  dbg ("ignore: using a test message to lint rules");
  my @testmsg = ("From: ignore\@compiling.spamassassin.taint.org\n", 
    "Subject: \n",
    "Message-Id:  <".time."\@lint_rules>\n", "\n",
    "I need to make this message body somewhat long so TextCat preloads\n"x20);

  $self->{lint_rules} = $self->{conf}->{lint_rules} = 1;
  $self->{syntax_errors} = 0;
  $self->{rule_errors} = 0;

  $self->init(1);
  $self->{syntax_errors} += $self->{conf}->{errors};

  my $mail = Mail::SpamAssassin::NoMailAudit->new(data => \@testmsg);
  my $status = $self->check($mail);
  $self->{syntax_errors} += $status->{rule_errors};
  $status->finish();

  return ($self->{syntax_errors});
}

###########################################################################

=item $f->init ($use_user_prefs)

Read and parse the current configuration. C<$use_user_prefs> can
be C<0> (do not read user preferences) or C<1> (do).

=cut

sub init {
  my ($self, $use_user_pref) = @_;

  if ($self->{_initted}) { return; }
  $self->{_initted} = 1;

  #fix spamd reading root prefs file
  unless (defined $use_user_pref) {
    $use_user_pref = 1;
  }

  if (!defined $self->{config_text}) {
    $self->{config_text} = '';

    my $fname = $self->first_existing_path (@default_rules_path);
    $self->{rules_filename} or $self->{config_text} .= $self->read_cf ($fname, 'default rules dir');

    if (-f "$fname/languages") {
	$self->{languages_filename} = "$fname/languages";
    }

    $fname = $self->{rules_filename};
    $fname ||= $self->first_existing_path (@site_rules_path);
    $self->{config_text} .= $self->read_cf ($fname, 'site rules dir');

    if (-f "$fname/languages") {
	$self->{languages_filename} = "$fname/languages";
    }

    if ( $use_user_pref != 0 ) {
      $self->create_dotsa_dir_if_needed();

      my $old_prefs_name = $self->first_existing_path ('~/.spamassassin.cf');
      if (!-f $old_prefs_name) { $old_prefs_name = undef; }

      # user prefs file
      $fname = $self->{userprefs_filename};

      if (!defined $fname) {
        $fname ||= $self->first_existing_path (@default_userprefs_path);

        if (defined $old_prefs_name && -f $old_prefs_name) {
          dbg ("migrating $old_prefs_name to $fname");
          rename ($old_prefs_name, $fname) or
                        warn "rename $old_prefs_name to $fname failed: $!\n";
        }
      }

      if (defined $fname) {
        if (!-f $fname && !$self->create_default_prefs($fname)) {
          warn "Failed to create default prefs file $fname: $!\n";
        }
      }

      $self->{config_text} .= $self->read_cf ($fname, 'user prefs file');
    }
  }

  if ($self->{config_text} !~ /\S/) {
    warn "No configuration text or files found! Please check your setup.\n";
  }

  $self->{conf}->parse_rules ($self->{config_text});
  $self->{conf}->finish_parsing ();

  delete $self->{config_text};

  # TODO -- open DNS cache etc. if necessary
}

###########################################################################
# non-public methods.

sub read_cf {
  my ($self, $path, $desc) = @_;

  return '' unless defined ($path);

  dbg ("using \"$path\" for $desc");
  my $txt = '';

  if (-d $path) {
    foreach my $file ($self->get_cf_files_in_dir ($path)) {
      open (IN, "<".$file) or warn "cannot open \"$file\": $!\n", next;
      $txt .= "file start $file\n";     # let Conf know
      $txt .= join ('', <IN>);
      # add an extra \n in case file did not end in one.
      $txt .= "\nfile end $file\n";     
      close IN;
    }

  } elsif (-f $path && -s _ && -r _) {
    open (IN, "<".$path) or warn "cannot open \"$path\": $!\n";
    $txt .= "file start $path\n";
    $txt = join ('', <IN>);
    $txt .= "file end $path\n";
    close IN;
  }

  return $txt;
}

sub create_dotsa_dir_if_needed {
  my ($self,$userdir) = @_;

  # user state directory
  my $fname = $self->{userstate_dir};
  $fname ||= $self->first_existing_path (@default_userstate_dir);
  #
  # If vpopmail is enabled then set fname to virtual homedir
  #
  if (defined $userdir) {
    $fname = "$userdir/.spamassassin";
  }

  if (defined $fname && !$self->{dont_copy_prefs}) {
    dbg ("using \"$fname\" for user state dir");

    if (!-d $fname) {
      # not being able to create the *dir* is not worth a warning at all times
      mkpath ($fname, 0, 0700) or dbg ("mkdir $fname failed: $!\n");
    }
  }
}

=item $f->create_default_prefs ()

Copy default prefs file into home directory for later use and modification.

=cut

sub create_default_prefs {
  #
  # $userdir will only exist if vpopmail config is enabled thru spamd
  # Its value will be the virtual user's maildir
  #
  my ($self,$fname,$user,$userdir) = @_;

  if (!$self->{dont_copy_prefs} && !-f $fname)
  {
    #
    # Pass on the value of $userdir for virtual users in vpopmail
    # otherwise it is empty and the user's normal homedir is used
    #
    $self->create_dotsa_dir_if_needed($userdir);

    # copy in the default one for later editing
    my $defprefs = $self->first_existing_path
			(@Mail::SpamAssassin::default_prefs_path);
    
    if (!open (IN, "<$defprefs")) {
      warn "cannot open $defprefs: $!";
    } else {
      open (OUT, ">$fname") or warn "cannot write to $fname: $!";
      while (<IN>) {
        /^\#\* / and next;
        print OUT;
      }
      close OUT;
      close IN;
    }

    if (copy ($defprefs, $fname)) {
      if ( $< == 0 && $> == 0 && defined $user) {
	# chown it
	my ($uid,$gid) = (getpwnam($user))[2,3];
	unless (chown $uid, $gid, $fname) {
	   warn "Couldn't chown $fname to $uid:$gid for $user: $!\n";
	}
      }
     warn "Created user preferences file: $fname\n";
     return(1);

   } else {
     warn "Failed to create user preferences file: $!\n".
			 "\"$fname\" from default \"$defprefs\".\n";
   }
 }
 elsif ($self->{dont_copy_prefs}) { return 1; }
 
 return(0);
}

###########################################################################

sub expand_name ($) {
  my ($self, $name) = @_;
  my $home = $ENV{'HOME'} || '';

  if ($^O =~ /mswin|(?<!bs)dos|os2/oi) {
	  my $userprofile = $ENV{'USERPROFILE'} || '';

	  return $userprofile if ($userprofile && $userprofile =~ m/^[a-z]\:[\/\\]/oi);
	  return $userprofile if ($userprofile =~ m/^\\\\/o);

	  return $home if ($home && $home =~ m/^[a-z]\:[\/\\]/oi);
	  return $home if ($home =~ m/^\\\\/o);

	  return '';
  }
  else {
	  return $home if ($home && $home =~ /\//o);
	  return (getpwnam($name))[7] if ($name ne '');
	  return (getpwuid($>))[7];
  }
}

sub sed_path {
  my ($self, $path) = @_;
  return undef if (!defined $path);
  $path =~ s/__local_rules_dir__/$self->{LOCAL_RULES_DIR} || ''/ges;
  $path =~ s/__def_rules_dir__/$self->{DEF_RULES_DIR} || ''/ges;
  $path =~ s{__prefix__}{$self->{PREFIX} || $Config{prefix} || '/usr'}ges;
  $path =~ s/^\~([^\/]*)/$self->expand_name($1)/es;
  $path;
}

sub first_existing_path {
  my $self = shift;
  my $path;
  foreach my $p (@_) {
    $path = $self->sed_path ($p);
    if (defined $path && -e $path) { return $path; }
  }
  $path;
}

sub get_cf_files_in_dir {
  my ($self, $dir) = @_;

  opendir(SA_CF_DIR, $dir) or warn "cannot opendir $dir: $!\n";
  my @cfs = grep { /\.cf$/ && -f "$dir/$_" } readdir(SA_CF_DIR);
  closedir SA_CF_DIR;

  return map { "$dir/$_" } sort { $a cmp $b } @cfs;	# sort numerically
}

###########################################################################

sub encapsulate_mail_object {
  my ($self, $mail_obj) = @_;

  # first, check to see if this is not actually a Mail::Audit object;
  # it could also be an already-encapsulated Mail::Audit wrapped inside
  # a Mail::SpamAssassin::Message.
  if ($mail_obj->{is_spamassassin_wrapper_object}) {
    return $mail_obj;
  }
  
  if ($self->{use_my_mail_class}) {
    my $class = $self->{use_my_mail_class};
    (my $file = $class) =~ s/::/\//g;
    require "$file.pm";
    return $class->new($mail_obj);
  }

  # new versions of Mail::Audit can have one of 2 different base classes. URGH.
  # we can tell which class, by querying the is_mime() method.  Support for
  # MIME::Entity contributed by Andrew Wilson <andrew@rivendale.net>.
  #
  my $ismime = 0;

  $self->{mail_audit_supports_encapsulation} = 0;

  if ($mail_obj->can ("is_mime")) {
    $self->{mail_audit_supports_encapsulation} = 1;
    $ismime = $mail_obj->is_mime();

  } elsif ($mail_obj->can ("replace_header")) {
    $self->{mail_audit_supports_encapsulation} = 1;
  }

  if ($ismime) {
    require Mail::SpamAssassin::EncappedMIME;
    return  Mail::SpamAssassin::EncappedMIME->new($mail_obj);
  } elsif ($self->{mail_audit_supports_encapsulation}) {
    require Mail::SpamAssassin::EncappedMessage;
    return  Mail::SpamAssassin::EncappedMessage->new($mail_obj);
  } else {
    require Mail::SpamAssassin::ExposedMessage;
    return  Mail::SpamAssassin::ExposedMessage->new($mail_obj);
  }
}

sub find_all_addrs_in_mail {
  my ($self, $mail_obj) = @_;

  $self->init(1);
  my $mail = $self->encapsulate_mail_object ($mail_obj);

  my @addrlist = ();
  foreach my $header (qw(To From Cc Reply-To Sender
  				Errors-To Mail-Followup-To))
  {
    my @hdrs = $mail->get_header ($header);
    if ($#hdrs < 0) { next; }
    push (@addrlist, $self->find_all_addrs_in_line (join (" ", @hdrs)));
  }

  # find addrs in body, too
  foreach my $line (@{$mail->get_body()}) {
    push (@addrlist, $self->find_all_addrs_in_line ($line));
  }

  my @ret = ();
  my %done = ();

  foreach $_ (@addrlist) {
    s/^mailto://;       # from Outlook "forwarded" message
    next if defined ($done{$_}); $done{$_} = 1;
    push (@ret, $_);
  }

  @ret;
}

sub find_all_addrs_in_line {
  my ($self, $line) = @_;

  my @addrs = ();
  my %seen = ();
  while ($line =~ s/([-a-z0-9_\+\:\.\/]+
	      \@[-a-z0-9_\+\:\.\/]+
	      \.[-a-z0-9_\+\:\.\/]+)//ix)
  {
    my $addr = $1;
    $addr =~ s/^mailto://;
    next if (defined ($seen{$addr})); $seen{$addr} = 1;
    push (@addrs, $addr);
  }

  return @addrs;
}

# First argument is the message you want to log for that time
# wheredelta is 1 for starting a split on the stopwatch, and 2 for showing the
# instant delta (used to show how long a specific routine took to run)
# deltaslot says which stopwatch you are working with (needs to match for begin
# and end obviously)
sub timelog {
  my ($msg, $deltaslot, $wheredelta) = @_;
  my $now=time;
  my $tl=$Mail::SpamAssassin::TIMELOG;
  my $dbg=$Mail::SpamAssassin::DEBUG;

  if (defined($deltaslot) and ($deltaslot eq "SAfull") and defined($wheredelta) and ($wheredelta eq 1)) {
    $tl->{'start'}=$now;
    # Because spamd is long running, we need to close and re-open the log file
    if ($tl->{flushedlogs}) {
	$tl->{flushedlogs}=0;
	$tl->{mesgid}="";
	@{$tl->{keeplogs}} = ();
	close(LOG);
    }
  } 

  if (defined $wheredelta) {
    $tl->{stopwatch}->{$deltaslot}=$now if ($wheredelta eq 1);
    if ($wheredelta eq 2) {
      if (not defined $tl->{stopwatch}->{$deltaslot}) {
	warn("Error: got end of time log for $deltaslot but never got the start\n");
      } else {
	$msg.=sprintf(" (Delta: %.3fs)", 
	  $now - $tl->{stopwatch}->{$deltaslot} );
      }
    }
  }

  $msg=sprintf("%.3f: $msg\n", $now - ($tl->{start}||0));

  if (not ($tl->{logpath} and $tl->{mesgid})) {
    push (@{$tl->{keeplogs}}, $msg);
    print $msg if ($dbg->{timelog});
    dbg("Log not yet opened, continuing", "timelog", -2);
    return;
  } 
  if (not $tl->{flushedlogs} and $tl->{logpath} and $tl->{mesgid}) {
    my $file="$tl->{logpath}/".sprintf("%.4f",time)."_$tl->{mesgid}";

    $tl->{flushedlogs}=1;
    dbg("Flushing logs to $file", "timelog", -2);
    open (LOG, ">>$file") or warn("Can't open $file: $!");

    while (defined ($_ = shift(@{$tl->{keeplogs}})))
    {
      print LOG $_;
    }
    dbg("Done flushing logs", "timelog", -2);
  }
  print LOG $msg;
  print $msg if ($dbg->{timelog});
}


# Only the first argument is needed, and it can be a reference to a list if
# you want
sub dbg {
  my $dbg=$Mail::SpamAssassin::DEBUG;

  return unless $dbg->{enabled};

  my ($msg, $codepath, $level) = @_;

  $msg=join('',@{$msg}) if (ref $msg);

  if (defined $codepath) {
    if (not defined $dbg->{$codepath}) {
      warn("dbg called with codepath $codepath, but it's not defined, skipping (message was \"$msg\"\n");
      return 0;
    } elsif (not defined $level) {
      warn("dbg called with codepath $codepath, but no level threshold (message was \"$msg\"\n");
    }
  }
  # Negative levels are just level numbers, the more negative, the more debug
  return if (defined $level and $level<0 and not $dbg->{$codepath} <= $level);
  # Positive levels are bit fields
  return if (defined $level and $level>0 and not $dbg->{$codepath} & $level);

  warn "debug: $msg\n";
}

# sa_die -- used to die with a useful exit code.

sub sa_die {
  my $exitcode = shift;
  warn @_;
  exit $exitcode;
}

1;
__END__

###########################################################################

=back

=head1 PREREQUISITES

C<Mail::Audit>
C<Mail::Internet>

=head1 COREQUISITES

C<Net::DNS>

=head1 MORE DOCUMENTATION

See also http://spamassassin.org/ for more information.

=head1 SEE ALSO

C<Mail::SpamAssassin::Conf>
C<Mail::SpamAssassin::PerMsgStatus>
C<spamassassin>

=head1 AUTHOR

Justin Mason E<lt>jm /at/ jmason.orgE<gt>

=head1 COPYRIGHT

SpamAssassin is distributed under Perl's Artistic license.

=head1 AVAILABILITY

The latest version of this library is likely to be available from CPAN
as well as:

  http://spamassassin.org/

=cut



