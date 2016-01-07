# Copyright (c) 2015, Sine Nomine Associates
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
# REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
# INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
# OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
# PERFORMANCE OF THIS SOFTWARE.

package AFS::CellCC::CLI;

use strict;
use warnings;

use 5.008_000;

use IO::Handle;
use Getopt::Long qw(GetOptionsFromArray);
use Log::Log4perl qw(:easy);

use AFS::CellCC;
use AFS::CellCC::Log qw(log_init);
use AFS::CellCC::Config qw(config_load config_get config_parse_override
                           set_daemon);
use AFS::CellCC::Const qw($VERSION);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(run);

# Builtin 'version' subcommand
sub
cmd_version($) {
    print "CellCC version $VERSION\n";
}

my $orig_argv0;

# Builtin 'help' subcommand
sub
cmd_help($$$$) {
    my ($argv, $cmd, $cmd_info, $bare) = @_;
    if ($bare) {
        print "Usage: $orig_argv0 <subcommand> <arguments>\n";
        print "\n";
        print "There are many subcommands to $orig_argv0, with varying arguments.\n";
        print "Try looking up the manpage for '${orig_argv0}' for guidance.\n";
        return;

    } elsif ($cmd_info->{usage}) {
        print "Usage: $orig_argv0 $cmd $cmd_info->{usage}\n";

    } else {
        print "Sorry, there is no help information available for '$cmd'.\n";
    }

    print "\n";
    print "For more information, try looking up the manpage for '${orig_argv0}_$cmd'\n";
}

# Parse options from the -x CLI flag, interpreting 'json:'-prefixed entries as
# json strings.
#
# We take a hashref, where options like '-x foo=bar' have already been parsed,
# and put into the hashref as:
# { foo => 'bar' }
# But options with 'json:' have not yet been parsed as json.
#
# This sub deletes the 'json:' keys, and inserts the 'json:'-less keys with the
# parsed values. The hashref is modified in-place.
sub
_parse_overrides($) {
    my ($overrides) = @_;

    for my $key (keys %$overrides) {
        if ($key =~ m/^json:(.*)$/) {
            my $new_key = $1;
            my $val = $overrides->{$key};

            eval {
                $val = config_parse_override($val);
            };
            if ($@) {
                die("Error parsing -x option for '$new_key':\n  $@");
            }

            # Delete the entry with 'json:' in it, and put the parsed value in
            # the 'json:'-less key. Note that our loop operates on a copy of
            # the list of keys in the %$override hash, so modifying this while
            # we're traversing is fine.
            delete $overrides->{$key};
            $overrides->{$new_key} = $val;
        }
    }
}

# Given a table of commands to run, parse the given argv and run the
# appropriate command. This sub does not return; we either exit or throw
# something.
sub
run($$;$) {
    my ($cmd_table, $argv, $opts) = @_;

    # Always flush stdout, to avoid potential issues with losing output due to
    # buffering. We don't print a bunch of stuff to stdout, so stdout
    # performance is not important.
    STDOUT->autoflush();

    # Setup a couple of subcommands we want to make sure exist.
    $cmd_table->{'version'} = { func => \&cmd_version,
                                noconfig => 1,
                                usage => '',
                              };
    $cmd_table->{'help'} = { func => \&cmd_help,
                             noconfig => 1,
                             usage => '<subcommand>',
                           };

    Getopt::Long::Configure(
        'default',
        'no_auto_abbrev',   # Don't abbreviate opts to uniqueness
        'no_getopt_compat', # Don't allow + instead of -
        'no_ignore_case',   # Require correct case in options
        'no_auto_version',  # Don't provide automatic --version
        'no_auto_help',     # Don't provide automatic --help
        'pass_through',     # Unknown options are not an error
    );

    my $conf_file;
    my $help = 0;
    my $version = 0;
    my %overrides;
    my $exit_code = 0;

    $orig_argv0 = $0;

    GetOptionsFromArray($argv,
                        'config=s' => \$conf_file,
                        'help'     => \$help,
                        'version'  => \$version,
                        'x=s%'     => \%overrides,
    ) or return 1;

    Getopt::Long::Configure(
        'no_pass_through', # Unknown options cause an error
    );

    if ($version) {
        # If someone gave --version, we can ignore everything else and just
        # give the version.
        @$argv = ('version');
    }
    if ($help) {
        # If --help was specified, just act as if we're running the 'help'
        # subcommand.
        unshift(@$argv, 'help');
    }

    my $help_bare;
    my $cmd;
    $cmd = shift @$argv;
    if (!defined($cmd)) {
        # If we weren't given a subcommand, print out a help message.
        $cmd = 'help';
        $exit_code = 1;
    }
    if ($cmd eq 'help') {
        $help = 1;
        $cmd = shift @$argv;
        if (!defined($cmd)) {
            $cmd = 'help';
            $help_bare = 1;
        }
    }

    my $help_info;
    my $help_cmd;
    my $cmd_info = $cmd_table->{$cmd};
    if (!defined($cmd_info)) {
        warn "$0: Unknown sub-command '$cmd'.\n";
        exit(1);
    }
    if ($help) {
        # For 'help' processing, the $cmd_info we looked up is actually for the
        # subcommand we're seeking help for. Change it back so $cmd_info is for
        # the 'help' subcommand, and store the target subcommand info in
        # $help_info.
        $help_info = $cmd_info;
        $help_cmd = $cmd;
        $cmd = 'help';
        $cmd_info = $cmd_table->{$cmd};
    }

    if ($cmd_info->{daemon}) {
        set_daemon();

        # Change our command name, so log message show things like
        # 'cellcc_check-server', instead of all of the different daemons
        # logging messages as just 'cellcc', which is less helpful.
        $0 = "$0_$cmd";
    }
    log_init();

    if ($cmd_info->{remote}) {
        # For commands that are issued via some RPC mechanism (e.g. remctl), do
        # not allow modification of the config via the command line. Otherwise,
        # a remote user could modify the config to bypass authorization checks
        # and let themselves run anything.
        if (%overrides || defined($conf_file)) {
            die("Error: Command-line config changes (-x, --config) are not allowed with this command\n");
        }
    }

    _parse_overrides(\%overrides);

    if ($cmd_info->{admin}) {
        # If we're a command that needs admin access to the database, load the
        # admin config.
        if ($cmd_info->{admin} eq 'try') {
            eval {
                config_load(\%overrides, $conf_file, {admin => 1});
            };
            if ($@) {
                INFO "Failed to load admin config: $@";
                INFO "Loading non-admin config instead";
                config_load(\%overrides, $conf_file);
            }
        } else {
            config_load(\%overrides, $conf_file, {admin => 1});
        }
    } elsif ($cmd_info->{noconfig}) {
        # Don't load config
    } else {
        config_load(\%overrides, $conf_file);
    }

    eval {
        # Now we can finally run the code for our calculated subcommand
        if ($opts->{preamble}) {
            $opts->{preamble}->();
        }
        if ($help) {
            $cmd_info->{func}->($argv, $help_cmd, $help_info, $help_bare);
        } else {
            $cmd_info->{func}->($argv);
        }
    };
    if ($@) {
        my $error = $@;
        if ($error =~ m/^usage at /) {
            cmd_help(undef, $cmd, $cmd_info, undef);
            $exit_code = 1;
        } else {
            if ($cmd_info->{daemon}) {
                # Log the error if we're a daemon. Do _not_ use FATAL here, since
                # for the syslog appender this logs an 'emerg' log, which goes to
                # all consoles by default... I see no easy way to fix that, so
                # just avoid using the FATAL level.
                ERROR $error;
            }
            die($error);
        }
    }
    exit($exit_code);
}

1;
