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

package AFS::CellCC::Remote;

use strict;
use warnings;

use 5.008_000;

use Getopt::Long qw(GetOptionsFromArray);
use File::Basename;
use File::Copy;
use File::Spec;
use Log::Log4perl qw(:easy);

use AFS::CellCC::Config qw(config_get);
use AFS::CellCC::Dump;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(run_remctl);

sub
parse_error() {
    die("Internal error: error parsing arguments\n");
}

# The 'get-dump' command.
sub
cmd_getdump($) {
    my ($argv) = @_;

    GetOptionsFromArray($argv) or parse_error();

    if (@$argv != 1) {
        die("Usage: $0 get-dump <filename>\n");
    }

    my ($filename) = @$argv;

    my $path = AFS::CellCC::Dump::get_dump_path($filename);

    if (-t STDOUT) {
        die("STDOUT is a tty; refusing to dump file. Pipe through 'cat' to override\n");
    }

    binmode STDOUT;
    copy($path, \*STDOUT)
        or die("Copy failed: $!\n");
}

# The 'remove-dump' command.
sub
cmd_removedump($) {
    my ($argv) = @_;

    GetOptionsFromArray($argv) or parse_error();

    if (@$argv != 1) {
        die("Usage: $0 remove-dump <filename>\n");
    }

    my ($filename) = @$argv;

    my $path = AFS::CellCC::Dump::get_dump_path($filename);

    unlink($path)
        or die("Cannot remove dump: $!\n");
}

# The 'ping' command.
sub
cmd_ping($) {
    print "CellCC remote communication is working\n";
}

my %cmd_table = (
    ping => { func => \&cmd_ping },
    'get-dump' => { func => \&cmd_getdump },
    'remove-dump' => { func => \&cmd_removedump },
);

# Run the appropriate subcommand according to the arguments in @$argref.
sub
_run($) {
    my ($argref) = @_;
    my @argv = @$argref;
    my $cmd = shift @argv;

    if (!defined($cmd)) {
        die("Internal error: no command specified\n");
    }

    my $cmdinfo = $cmd_table{$cmd};
    if (!defined($cmdinfo)) {
        die("Internal error: unrecognized command $cmd\n");
    }

    $cmdinfo->{func}->(\@argv);
}

# Run the appropriate remctl backend command, according to the arguments in
# @$argv.
sub
run_remctl($) {
    my ($argv) = @_;

    # remctld will put the accessing principal in the REMUSER env var
    if (!defined($ENV{REMUSER})) {
        die("REMUSER environment variable is not set. If you are running this ".
            "through remctl, this is an internal error. If you are running ".
            "this manually, set REMUSER to the accessing principal.\n");
    }
    if ($ENV{REMUSER} ne config_get('remctl/princ')) {
        ERROR "remctl access denied for accessing principal ".$ENV{REMUSER};
        die("Access denied\n");
    }

    _run($argv);
}
