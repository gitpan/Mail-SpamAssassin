# <@LICENSE>
# Copyright 2004 Apache Software Foundation
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

=head1 NAME

Mail::SpamAssassin::Conf::Parser - parse SpamAssassin configuration

=head1 SYNOPSIS

  (see Mail::SpamAssassin)

=head1 DESCRIPTION

Mail::SpamAssassin is a module to identify spam using text analysis and
several internet-based realtime blacklists.

This class is used internally by SpamAssassin to parse its configuration files.
Please refer to the C<Mail::SpamAssassin> documentation for public interfaces.

=head1 STRUCTURE OF A CONFIG BLOCK

This is the structure of a config-setting block.  Each is a hashref which may
contain these keys:

=over 4

=item setting

the name of the setting it modifies, e.g. "required_score". this also doubles
as the default for 'command' (below). THIS IS REQUIRED.

=item command

The command string used in the config file for this setting.  Optional;
'setting' will be used for the command if this is omitted.

=item aliases

An [aryref] of other aliases for the same command.  optional.

=item type

The type of this setting:

           - $CONF_TYPE_STRING: string
           - $CONF_TYPE_NUMERIC: numeric value (float or int)
           - $CONF_TYPE_BOOL: boolean (0 or 1)
           - $CONF_TYPE_TEMPLATE: template, like "report"
           - $CONF_TYPE_ADDRLIST: address list, like "whitelist_from"
           - $CONF_TYPE_HASH_KEY_VALUE: hash key/value pair,
             like "describe" or tflags

If this is set, a 'code' block is assigned based on the type.

Note that C<$CONF_TYPE_HASH_KEY_VALUE>-type settings require that the
value be non-empty, otherwise they'll produce a warning message.

=item code

A subroutine to deal with the setting.  Only used if B<type> is not set.  ONE OF
B<code> OR B<type> IS REQUIRED.  The arguments passed to the function are
C<($self, $key, $value, $line)>, where $key is the setting (*not* the command),
$value is the value string, and $line is the entire line.

There are two special return values that the B<code> subroutine may return
to signal that there is an error in the configuration:

C<$Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE> -- this setting requires
that a value be set, but one was not provided.

C<$Mail::SpamAssassin::Conf::INVALID_VALUE> -- this setting requires a value
from a set of 'valid' values, but the user provided an invalid one.

Any other values -- including C<undef> -- returned from the subroutine are
considered to mean 'success'.

=item default

The default value for the setting.  may be omitted if the default value is a
non-scalar type, which should be set in the Conf ctor.  note for path types:
using "__userstate__" is recommended for defaults, as it allows
Mail::SpamAssassin module users who set that configuration setting, to receive
the correct values.

=item is_priv

Set to 1 if this setting requires 'allow_user_rules' when run from spamd.

=item is_admin

Set to 1 if this setting can only be set in the system-wide config when run
from spamd.  (All settings can be used by local programs run directly by the
user.)

=item is_frequent

Set to 1 if this value occurs frequently in the config. this means it's looked
up first for speed.

=back

=head1 METHODS

=over 4

=cut

package Mail::SpamAssassin::Conf::Parser;

use Mail::SpamAssassin::Conf;
use Mail::SpamAssassin::Constants qw(:sa);
use Mail::SpamAssassin::Logger;

use strict;
use warnings;
use bytes;
use Carp;

use vars qw{
  @ISA
};

@ISA = qw();

###########################################################################

sub new {
  my $class = shift;
  $class = ref($class) || $class;
  my ($conf) = @_;

  my $self = {
    'conf'      => $conf
  };

  $self->{command_luts} = { };
  $self->{command_luts}->{frequent} = { };
  $self->{command_luts}->{remaining} = { };

  bless ($self, $class);
  $self;
}

###########################################################################

sub register_commands {
  my($self, $arrref) = @_;
  my $conf = $self->{conf};

  $self->set_defaults_from_command_list($arrref);
  $self->build_command_luts($arrref);
  push(@{$conf->{registered_commands}}, @{$arrref});
}

sub set_defaults_from_command_list {
  my ($self, $arrref) = @_;
  my $conf = $self->{conf};
  foreach my $cmd (@{$arrref}) {
    # note! exists, not defined -- we want to be able to set
    # "undef" default values.
    if (exists($cmd->{default})) {
      $conf->{$cmd->{setting}} = $cmd->{default};
    }
  }
}

sub build_command_luts {
  my ($self, $arrref) = @_;

  my $conf = $self->{conf};

  my $set;
  foreach my $cmd (@{$arrref}) {
    # first off, decide what set this is in.
    if ($cmd->{is_frequent}) { $set = 'frequent'; }
    else { $set = 'remaining'; }

    # next, its priority (used to ensure frequently-used params
    # are parsed first)
    my $cmdname = $cmd->{command} || $cmd->{setting};
    foreach my $name ($cmdname, @{$cmd->{aliases}}) {
      $self->{command_luts}->{$set}->{$name} = $cmd;
    }
  }
}

###########################################################################

sub parse {
  my ($self, undef, $scoresonly) = @_; # leave $rules in $_[1]

  $self->{scoresonly} = $scoresonly;
  my $conf = $self->{conf};

  # Language selection:
  # See http://www.gnu.org/manual/glibc-2.2.5/html_node/Locale-Categories.html
  # and http://www.gnu.org/manual/glibc-2.2.5/html_node/Using-gettextized-software.html
  my $lang = $ENV{'LANGUAGE'}; # LANGUAGE has the highest precedence but has a
  if ($lang) {                 # special format: The user may specify more than
    $lang =~ s/:.*$//;         # one language here, colon separated. We use the
  }                            # first one only (lazy bums we are :o)
  $lang ||= $ENV{'LC_ALL'};
  $lang ||= $ENV{'LC_MESSAGES'};
  $lang ||= $ENV{'LANG'};
  $lang ||= 'C';               # Nothing set means C/POSIX

  if ($lang =~ /^(C|POSIX)$/) {
    $lang = 'en_US';           # Our default language
  } else {
    $lang =~ s/[@.+,].*$//;    # Strip codeset, modifier/audience, etc.
  }                            # (eg. .utf8 or @euro)

  # get fast-access handles on the command lookup tables
  my $lut_frequent = $self->{command_luts}->{frequent};
  my $lut_remaining = $self->{command_luts}->{remaining};
  my %migrated_keys = map { $_ => 1 }
            @Mail::SpamAssassin::Conf::MIGRATED_SETTINGS;

  $self->{currentfile} = '(no file)';
  my $skip_parsing = 0;
  my @curfile_stack = ();
  my @if_stack = ();
  my @conf_lines = split (/\n/, $_[1]);
  my $line;

  while (defined ($line = shift @conf_lines)) {
    $line =~ s/(?<!\\)#.*$//; # remove comments
    $line =~ s/^\s+//;  # remove leading whitespace
    $line =~ s/\s+$//;  # remove tailing whitespace
    next unless($line); # skip empty lines

    # handle i18n
    if ($line =~ s/^lang\s+(\S+)\s+//) { next if ($lang !~ /^$1/i); }

    my($key, $value) = split(/\s+/, $line, 2);
    $key = lc $key;
    # convert all dashes in setting name to underscores.
    $key =~ s/-/_/g;

    # Do a better job untainting this info ...
    $value = '' unless defined($value);
    $value =~ /^(.*)$/;
    $value = $1;

    my $parse_error;       # undef by default, may be overridden

    # File/line number assertions
    if ($key eq 'file') {
      if ($value =~ /^start\s+(.+)$/) {
        push (@curfile_stack, $self->{currentfile});
        $self->{currentfile} = $1;
        next;
      }

      if ($value =~ /^end\s/) {
        if (scalar @if_stack > 0) {
          my $cond = pop @if_stack;

          if ($cond->{type} eq 'if') {
            warn "config: unclosed 'if' in ".
                  $self->{currentfile}.": if ".$cond->{conditional}."\n";
          }
          else {
            # die seems a bit excessive here, but this shouldn't be possible
            # so I suppose it's okay.
            die "config: unknown 'if' type: ".$cond->{type}."\n";
          }

          $conf->{errors}++;
          @if_stack = ();
        }
        $skip_parsing = 0;

        my $curfile = pop @curfile_stack;
        if (defined $curfile) {
          $self->{currentfile} = $curfile;
        } else {
          $self->{currentfile} = '(no file)';
        }
        next;
      }
    }

    # now handle the commands.
    if ($key eq 'include') {
      $value = $self->fix_path_relative_to_current_file($value);
      my $text = $conf->{main}->read_cf($value, 'included file');
      unshift (@conf_lines, split (/\n/, $text));
      next;
    }

    if ($key eq 'ifplugin') {
      $self->handle_conditional ($key, "plugin ($value)",
                        \@if_stack, \$skip_parsing);
      next;
    }

    if ($key eq 'if') {
      $self->handle_conditional ($key, $value,
                        \@if_stack, \$skip_parsing);
      next;
    }

    # and the endif statement:
    if ($key eq 'endif') {
      my $lastcond = pop @if_stack;
      $skip_parsing = $lastcond->{skip_parsing};
      next;
    }

    # preprocessing? skip all other commands
    next if $skip_parsing;

    if ($key eq 'require_version') {
      # if it wasn't replaced during install, assume current version ...
      next if ($value eq "\@\@VERSION\@\@");

      my $ver = $Mail::SpamAssassin::VERSION;

      # if we want to allow "require_version 3.0" be good for all
      # "3.0.x" versions:
      ## make sure it's a numeric value
      #$value += 0.0;
      ## convert 3.000000 -> 3.0, stay backwards compatible ...
      #$ver =~ s/^(\d+)\.(\d{1,3}).*$/sprintf "%d.%d", $1, $2/e;
      #$value =~ s/^(\d+)\.(\d{1,3}).*$/sprintf "%d.%d", $1, $2/e;

      if ($ver ne $value) {
        warn "config: configuration file \"$self->{currentfile}\" requires version ".
                "$value of SpamAssassin, but this is code version ".
                "$ver. Maybe you need to use ".
                "the -C switch, or remove the old config files? ".
                "Skipping this file";
        $skip_parsing = 1;
        $conf->{errors}++;
      }
      next;
    }

    my $cmd = $lut_frequent->{$key}; # check the frequent command set
    if (!$cmd) {
      $cmd = $lut_remaining->{$key}; # no? try the rest
    }

    # we've either fallen through with no match, in which case this
    # if() will fail, or we have a match.
    if ($cmd) {
      if ($self->{scoresonly}) {              # reading user config from spamd
        if ($cmd->{is_priv} && !$conf->{allow_user_rules}) {
          info("config: not parsing, 'allow_user_rules' is 0: $line");
          goto failed_line;
        }
        if ($cmd->{is_admin}) {
          info("config: not parsing, administrator setting: $line");
          goto failed_line;
        }
      }

      if (!$cmd->{code}) {
        if (! $self->setup_default_code_cb($cmd)) {
          goto failed_line;
        }
      }

      my $ret = &{$cmd->{code}} ($conf, $cmd->{setting}, $value, $line);

      if ($ret && $ret eq $Mail::SpamAssassin::Conf::INVALID_VALUE)
      {
        $parse_error = "config: SpamAssassin failed to parse line, ".
                        "\"$value\" is not valid for \"$key\", ".
                        "skipping: $line";
        goto failed_line;
      }
      elsif ($ret && $ret eq $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE)
      {
        $parse_error = "config: SpamAssassin failed to parse line, ".
                        "no value provided for \"$key\", ".
                        "skipping: $line";
        goto failed_line;
      }
      else {
        next;
      }
    }

    # last ditch: try to see if the plugins know what to do with it
    if ($conf->{main}->call_plugins("parse_config", {
                key => $key,
                value => $value,
                line => $line,
                conf => $conf,
                user_config => $self->{scoresonly}
            }))
    {
      # a plugin dealt with it successfully.
      next;
    }

failed_line:
    my $msg = $parse_error;
    my $is_error = 1;
    if (!$msg) {
      # use a default warning, if a more specific one wasn't output
      if ($migrated_keys{$key}) {
        # this key was moved into a plugin; non-fatal for lint
        $is_error = 0;
        $msg = "config: failed to parse, now a plugin, skipping: $line";
      } else {
        # a real syntax error; this is fatal for --lint
        $msg = "config: failed to parse line, skipping: $line";
      }
    }

    if ($conf->{lint_rules}) {
      warn $msg."\n";
    } else {
      info($msg);
    }

    if ($is_error) {
      $conf->{errors}++;
    }
  }

  $self->lint_check();
  $self->set_default_scores();

  delete $self->{scoresonly};
}

sub handle_conditional {
  my ($self, $key, $value, $if_stack_ref, $skip_parsing_ref) = @_;
  my $conf = $self->{conf};

  my $lexer = ARITH_EXPRESSION_LEXER;
  my @tokens = ($value =~ m/($lexer)/g);

  my $eval = '';
  my $bad = 0;
  foreach my $token (@tokens) {
    if ($token =~ /^(\W+|[\-\+\d\.]+)$/) {
      $eval .= $1." ";          # note: untaints!
    }
    elsif ($token eq 'plugin') {
      # replace with method call
      $eval .= "\$self->cond_clause_plugin_loaded";
    }
    elsif ($token eq 'version') {
      $eval .= $Mail::SpamAssassin::VERSION." ";
    }
    elsif ($token =~ /^(\w[\w\:]+)$/) { # class name
      $eval .= "\"$1\" ";       # note: untaints!
    }
    else {
      $bad++;
      warn "config: unparseable chars in 'if $value': '$token'\n";
    }
  }

  if ($bad) {
    $conf->{errors}++;
    return -1;
  }

  push (@{$if_stack_ref}, {
      type => 'if',
      conditional => $value,
      skip_parsing => $$skip_parsing_ref
    });

  if (eval $eval) {
    # leave $skip_parsing as-is; we may not be parsing anyway in this block.
    # in other words, support nested 'if's and 'require_version's
  } else {
    $$skip_parsing_ref = 1;
  }
}

# functions supported in the "if" eval:
sub cond_clause_plugin_loaded {
  return $_[0]->{conf}->{plugins_loaded}->{$_[1]};
}

# Let's do some linting here ...
# This is called from _parse(), BTW, so we can check for $conf->{tests}
# easily before finish_parsing() is called and deletes it.
#
sub lint_check {
  my ($self) = @_;
  my $conf = $self->{conf};
  my ($k, $v);

  if ($conf->{lint_rules})
  {
    # Check for description and score issues in lint fashion
    while ( ($k,$v) = each %{$conf->{descriptions}} ) {
      if (!exists $conf->{tests}->{$k}) {
        warn "config: warning: description exists for non-existent rule $k\n";
        $conf->{errors}++;
      }
    }

    while ( my($sk) = each %{$conf->{scores}} ) {
      if (!exists $conf->{tests}->{$sk}) {
        warn "config: warning: score set for non-existent rule $sk\n";
        $conf->{errors}++;
      }
    }
  }
}

# we should set a default score for all valid rules...  Do this here
# instead of add_test because mostly 'score' occurs after the rule is
# specified, so why set the scores to default, then set them again at
# 'score'?
# 
sub set_default_scores {
  my ($self) = @_;
  my $conf = $self->{conf};
  my ($k, $v);

  while ( ($k,$v) = each %{$conf->{tests}} ) {
    if ( ! exists $conf->{scores}->{$k} ) {
      # T_ rules (in a testing probationary period) get low, low scores
      my $set_score = ($k =~/^T_/) ? 0.01 : 1.0;

      $set_score = -$set_score if ( $conf->{tflags}->{$k} =~ /\bnice\b/ );
      for my $index (0..3) {
        $conf->{scoreset}->[$index]->{$k} = $set_score;
      }
    }
  }
}

###########################################################################

sub setup_default_code_cb {
  my ($self, $cmd) = @_;
  my $type = $cmd->{type};

  if ($type == $Mail::SpamAssassin::Conf::CONF_TYPE_STRING) {
    $cmd->{code} = \&set_string_value;
  }
  elsif ($type == $Mail::SpamAssassin::Conf::CONF_TYPE_BOOL) {
    $cmd->{code} = \&set_bool_value;
  }
  elsif ($type == $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC) {
    $cmd->{code} = \&set_numeric_value;
  }
  elsif ($type == $Mail::SpamAssassin::Conf::CONF_TYPE_HASH_KEY_VALUE) {
    $cmd->{code} = \&set_hash_key_value;
  }
  elsif ($type == $Mail::SpamAssassin::Conf::CONF_TYPE_ADDRLIST) {
    $cmd->{code} = \&set_addrlist_value;
  }
  elsif ($type == $Mail::SpamAssassin::Conf::CONF_TYPE_TEMPLATE) {
    $cmd->{code} = \&set_template_append;
  }
  else {
    warn "config: unknown conf type $type!";
    return 0;
  }
  return 1;
}

sub set_numeric_value {
  my ($conf, $key, $value, $line) = @_;

  unless (defined $value && $value !~ /^$/) {
    return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
  }
  unless ($value =~ /^-?\d+(?:\.\d+)?$/) {
    return $Mail::SpamAssassin::Conf::INVALID_VALUE;
  }

  $conf->{$key} = $value+0.0;
}

sub set_bool_value {
  my ($conf, $key, $value, $line) = @_;

  unless (defined $value && $value !~ /^$/) {
    return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
  }
  unless ($value =~ /^[01]$/) {
    return $Mail::SpamAssassin::Conf::INVALID_VALUE;
  }

  $conf->{$key} = $value+0;
}

sub set_string_value {
  my ($conf, $key, $value, $line) = @_;

  unless (defined $value && $value !~ /^$/) {
    return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
  }

  $conf->{$key} = $value;
}

sub set_hash_key_value {
  my ($conf, $key, $value, $line) = @_;
  my($k,$v) = split(/\s+/, $value, 2);

  unless (defined $v && $v ne '') {
    return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
  }

  $conf->{$key}->{$k} = $v;
}

sub set_addrlist_value {
  my ($conf, $key, $value, $line) = @_;

  unless (defined $value && $value !~ /^$/) {
    return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
  }
  $conf->{parser}->add_to_addrlist ($key, split (' ', $value));
}

sub remove_addrlist_value {
  my ($conf, $key, $value, $line) = @_;

  unless (defined $value && $value !~ /^$/) {
    return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
  }
  $conf->{parser}->remove_from_addrlist ($key, split (' ', $value));
}

sub set_template_append {
  my ($conf, $key, $value, $line) = @_;
  if ( $value =~ /^"(.*?)"$/ ) { $value = $1; }
  $conf->{$key} .= $value."\n";
}

sub set_template_clear {
  my ($conf, $key, $value, $line) = @_;
  $conf->{$key} = '';
}

###########################################################################

sub finish_parsing {
  my ($self) = @_;
  my $conf = $self->{conf};

  while (my ($name, $text) = each %{$conf->{tests}}) {
    my $type = $conf->{test_types}->{$name};
    my $priority = $conf->{priority}->{$name} || 0;
    $conf->{priorities}->{$priority}++;

    # eval type handling
    if (($type & 1) == 1) {
      my @args;
      if (my ($function, $args) = ($text =~ m/(.*?)\s*\((.*?)\)\s*$/)) {
	if ($args) {
	  # bug 4419: Parse quoted strings, unquoted alphanumerics/floats and
	  # both unquoted IPv4 and IPv6 addresses.  s// is used so that we can
	  # determine whether or not we successfully parsed ALL arguments.
	  while ($args =~ s/^\s*(?:['"](.*?)['"]|([\d\.:A-Za-z]+?))\s*(?:,\s*|$)//) {
	    if (defined $1) {
	      push @args, $1;
	    }
	    else {
	      push @args, $2;
	    }
	  }
	}
        unshift(@args, $function);
	if ($args) {
	  $conf->{errors}++;
	  warn("syntax error (unparsable argument: $args) for eval function: $name: $text");
	}
        elsif ($type == $Mail::SpamAssassin::Conf::TYPE_BODY_EVALS) {
          $conf->{body_evals}->{$priority}->{$name} = \@args;
        }
        elsif ($type == $Mail::SpamAssassin::Conf::TYPE_HEAD_EVALS) {
          $conf->{head_evals}->{$priority}->{$name} = \@args;
        }
        elsif ($type == $Mail::SpamAssassin::Conf::TYPE_RBL_EVALS) {
          # We don't do priorities for $Mail::SpamAssassin::Conf::TYPE_RBL_EVALS
          $conf->{rbl_evals}->{$name} = \@args;
        }
        elsif ($type == $Mail::SpamAssassin::Conf::TYPE_RAWBODY_EVALS) {
          $conf->{rawbody_evals}->{$priority}->{$name} = \@args;
        }
        elsif ($type == $Mail::SpamAssassin::Conf::TYPE_FULL_EVALS) {
          $conf->{full_evals}->{$priority}->{$name} = \@args;
        }
        #elsif ($type == $Mail::SpamAssassin::Conf::TYPE_URI_EVALS) {
        #  $conf->{uri_evals}->{$priority}->{$name} = \@args;
        #}
        else {
          $conf->{errors}++;
	  warn("unknown type $type for $name: $text");
        }
      }
      else {
        $conf->{errors}++;
        warn("syntax error for eval function $name: $text");
      }
    }
    # non-eval tests
    else {
      if ($type == $Mail::SpamAssassin::Conf::TYPE_BODY_TESTS) {
        $conf->{body_tests}->{$priority}->{$name} = $text;
      }
      elsif ($type == $Mail::SpamAssassin::Conf::TYPE_HEAD_TESTS) {
        $conf->{head_tests}->{$priority}->{$name} = $text;
      }
      elsif ($type == $Mail::SpamAssassin::Conf::TYPE_META_TESTS) {
        # Meta Tests must have a priority of at least META_TEST_MIN_PRIORITY,
        # if it's lower then reset the value
        if ($priority < META_TEST_MIN_PRIORITY) {
          # we need to lower the count of the old priority and raise the
          # count of the new priority
          $conf->{priorities}->{$priority}--;
          $priority = META_TEST_MIN_PRIORITY;
          $conf->{priorities}->{$priority}++;
        }
        $conf->{meta_tests}->{$priority}->{$name} = $text;
      }
      elsif ($type == $Mail::SpamAssassin::Conf::TYPE_URI_TESTS) {
        $conf->{uri_tests}->{$priority}->{$name} = $text;
      }
      elsif ($type == $Mail::SpamAssassin::Conf::TYPE_RAWBODY_TESTS) {
        $conf->{rawbody_tests}->{$priority}->{$name} = $text;
      }
      elsif ($type == $Mail::SpamAssassin::Conf::TYPE_FULL_TESTS) {
        $conf->{full_tests}->{$priority}->{$name} = $text;
      }
      else {
        $conf->{errors}++;
        warn("unknown type $type for $name: $text");
      }
    }
  }

  $self->lint_trusted_networks();

  # named this way just in case we ever want a "finish_parsing_start"
  $conf->{main}->call_plugins("finish_parsing_end", { conf => $conf });

  delete $conf->{tests};                # free it up
  delete $conf->{priority};             # free it up
}

###########################################################################

sub lint_trusted_networks {
  my ($self) = @_;
  my $conf = $self->{conf};

  my $nt = $conf->{trusted_networks};
  my $ni = $conf->{internal_networks};

  # validate trusted_networks and internal_networks, bug 4760.
  # check that all internal_networks are listed in trusted_networks
  # too.

  if ($ni->get_num_nets() > 0 && $nt->get_num_nets() > 0) {
    my $replace_nets;
    my @valid_ni = ();

    foreach my $net (@{$ni->{nets}}) {
      # don't check to see if an excluded network is included - that's senseless
      if (!$net->{exclude} && !$nt->contains_net($net)) {
        my $msg = "trusted_networks doesn't contain internal_networks entry '".
                ($net->{as_string})."'\n";

        if ($conf->{lint_rules}) {
          warn $msg;
          $conf->{errors}++;
        }
        $replace_nets = 1;  # and omit it from the new internal set
      }
      else {
        push @valid_ni, $net;
      }
    }

    if ($replace_nets) {
      # something was invalid. replace the old nets list with a fixed version
      # (which may be empty)
      $ni->{nets} = \@valid_ni;
    }
  }
}

###########################################################################

sub add_test {
  my ($self, $name, $text, $type) = @_;
  my $conf = $self->{conf};

  # Don't allow invalid names ...
  if ($name !~ /^\D\w*$/) {
    warn "config: error: rule '$name' has invalid characters ".
	   "(not Alphanumeric + Underscore + starting with a non-digit)\n";
    $conf->{errors}++;
    return;
  }

  # Also set a hard limit for ALL rules (rule names longer than 242
  # characters throw warnings).  Check this separately from the above
  # pattern to avoid vague error messages.
  if (length $name > 200) {
    warn "config: error: rule '$name' is way too long ".
	   "(recommended maximum length is 22 characters)\n";
    $conf->{errors}++;
    return;
  }

  # Warn about, but use, long rule names during --lint
  if ($conf->{lint_rules}) {
    if (length($name) > 50 && $name !~ /^__/ && $name !~ /^T_/) {
      warn "config: warning: rule name '$name' is over 50 chars ".
	     "(recommended maximum length is 22 characters)\n";
      $conf->{errors}++;
    }
  }

  # all of these rule types are regexps
  if ($type == $Mail::SpamAssassin::Conf::TYPE_BODY_TESTS ||
      $type == $Mail::SpamAssassin::Conf::TYPE_FULL_TESTS ||
      $type == $Mail::SpamAssassin::Conf::TYPE_RAWBODY_TESTS ||
      $type == $Mail::SpamAssassin::Conf::TYPE_URI_TESTS)
  {
    return unless $self->is_delimited_regexp_valid($name, $text);
  }
  if ($type == $Mail::SpamAssassin::Conf::TYPE_HEAD_TESTS)
  {
    my ($pat) = ($text =~ /^\s*\S+\s*(?:\=|\!)\~\s*(\S.*?\S)\s*$/);
    $pat =~ s/\s+\[if-unset:\s+(.+)\]\s*$//;
    return unless $self->is_delimited_regexp_valid($name, $pat);
  }
  elsif ($type == $Mail::SpamAssassin::Conf::TYPE_META_TESTS)
  {
    return unless $self->is_meta_valid($name, $text);
  }

  $conf->{tests}->{$name} = $text;
  $conf->{test_types}->{$name} = $type;
  $conf->{tflags}->{$name} ||= '';
  $conf->{priority}->{$name} ||= 0;
  $conf->{source_file}->{$name} = $self->{currentfile};

  if ($self->{scoresonly}) {
    $conf->{user_rules_to_compile}->{$type} = 1;
    $conf->{user_defined_rules}->{$name} = 1;
  }
}

sub add_regression_test {
  my ($self, $name, $ok_or_fail, $string) = @_;
  my $conf = $self->{conf};

  if ($conf->{regression_tests}->{$name}) {
    push @{$conf->{regression_tests}->{$name}}, [$ok_or_fail, $string];
  }
  else {
    # initialize the array, and create one element
    $conf->{regression_tests}->{$name} = [ [$ok_or_fail, $string] ];
  }
}

sub is_meta_valid {
  my ($self, $name, $rule) = @_;

  my $meta = '';

  # Lex the rule into tokens using a rather simple RE method ...
  my $lexer = ARITH_EXPRESSION_LEXER;
  my @tokens = ($rule =~ m/$lexer/g);
  if (length($name) == 1) {
    print "$name $_\n " for @tokens;
  }
  # Go through each token in the meta rule
  foreach my $token (@tokens) {
    # Numbers can't be rule names
    if ($token =~ /^(?:\W+|\d+)$/) {
      $meta .= "$token ";
    }
    # Zero will probably cause more errors
    else {
      $meta .= "0 ";
    }
  }

  my $evalstr = 'my $x = ' . $meta . '; 1;';
  if (eval $evalstr) {
    return 1;
  }
  if ($@) {
    my $err = $@;
    $err =~ s/\s+(?:at|near)\b.*//s;
    $err =~ s/Illegal division by zero/division by zero possible/i;
    warn "config: invalid expression for rule $name: \"$rule\": $err\n";
    $self->{conf}->{errors}++;
    return 0;
  }
}

sub is_delimited_regexp_valid {
  my ($self, $name, $re) = @_;

  unless ($re =~ /^\s*m?(\W).*(?:\1|>|}|\)|\])[a-z]*\s*$/) {
    warn "config: invalid regexp for rule $name: $re: missing or invalid delimiters\n";
    $self->{conf}->{errors}++;
    return 0;
  }
  return $self->is_regexp_valid($name, $re);
}

sub is_regexp_valid {
  my ($self, $name, $re) = @_;

  # OK, try to remove any normal perl-style regexp delimiters at
  # the start and end, and modifiers at the end if present,
  # so we can validate those too.
  my $origre = $re;
  my $safere = $re;
  my $mods = '';
  if ($re =~ s/^m{//) {
    $re =~ s/}([a-z]*)$//; $mods = $1;
  }
  elsif ($re =~ s/^m\(//) {
    $re =~ s/\)([a-z]*)$//; $mods = $1;
  }
  elsif ($re =~ s/^m<//) {
    $re =~ s/>([a-z]*)$//; $mods = $1;
  }
  elsif ($re =~ s/^m(\W)//) {
    $re =~ s/\Q$1\E([a-z]*)$//; $mods = $1;
  }
  elsif ($re =~ s/^\/(.*)\/([a-z]*)$/$1/) {
    $mods = $2;
  }
  else {
    $safere = "m#".$re."#";
  }

  # now prepend the modifiers, in order to check if they're valid
  if ($mods) {
    $re = "(?".$mods.")".$re;
  }

  # note: this MUST use m/...${re}.../ in some form or another, ie.
  # interpolation of the $re variable into a code regexp, in order to test the
  # security of the regexp.  simply using ("" =~ $re) will NOT do that, and
  # will therefore open a hole!
  if (eval { ("" =~ m#${re}#); 1; }) {
    return 1;
  }

  my $err = $@;
  $err =~ s/ at .*? line \d.*$//;
  warn "config: invalid regexp for rule $name: $origre: $err\n";
  $self->{conf}->{errors}++;
  return 0;
}

###########################################################################

sub add_to_addrlist {
  my ($self, $singlelist, @addrs) = @_;
  my $conf = $self->{conf};

  foreach my $addr (@addrs) {
    $addr = lc $addr;
    my $re = $addr;
    $re =~ s/[\000\\\(]/_/gs;			# paranoia
    $re =~ s/([^\*\?_a-zA-Z0-9])/\\$1/g;	# escape any possible metachars
    $re =~ tr/?/./;				# "?" -> "."
    $re =~ s/\*+/\.\*/g;			# "*" -> "any string"
    $conf->{$singlelist}->{$addr} = "^${re}\$";
  }
}

sub add_to_addrlist_rcvd {
  my ($self, $listname, $addr, $domain) = @_;
  my $conf = $self->{conf};

  $addr = lc $addr;
  if ($conf->{$listname}->{$addr}) {
    push @{$conf->{$listname}->{$addr}{domain}}, $domain;
  }
  else {
    my $re = $addr;
    $re =~ s/[\000\\\(]/_/gs;			# paranoia
    $re =~ s/([^\*\?_a-zA-Z0-9])/\\$1/g;	# escape any possible metachars
    $re =~ tr/?/./;				# "?" -> "."
    $re =~ s/\*+/\.\*/g;			# "*" -> "any string"
    $conf->{$listname}->{$addr}{re} = "^${re}\$";
    $conf->{$listname}->{$addr}{domain} = [ $domain ];
  }
}

sub remove_from_addrlist {
  my ($self, $singlelist, @addrs) = @_;
  my $conf = $self->{conf};

  foreach my $addr (@addrs) {
    delete($conf->{$singlelist}->{$addr});
  }
}

sub remove_from_addrlist_rcvd {
  my ($self, $listname, @addrs) = @_;
  my $conf = $self->{conf};

  foreach my $addr (@addrs) {
    delete($conf->{$listname}->{$addr});
  }
}

###########################################################################

sub fix_path_relative_to_current_file {
  my ($self, $path) = @_;

  if (!File::Spec->file_name_is_absolute ($path)) {
    my ($vol, $dirs, $file) = File::Spec->splitpath ($self->{currentfile});
    $path = File::Spec->catpath ($vol, $dirs, $path);
    dbg("plugin: fixed relative path: $path");
  }
  return $path;
}

###########################################################################

1;