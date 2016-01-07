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

package AFS::CellCC::CLI::ccc_debug;

use strict;
use warnings;

use 5.008_000;

use Getopt::Long qw(GetOptionsFromArray);
use Log::Log4perl qw(:easy);

use AFS::CellCC::Check;
use AFS::CellCC::CLI;
use AFS::CellCC::DB;
use AFS::CellCC::Remoteclient;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(main);

sub
parse_error() {
    die("$0: Error parsing arguments\n");
}

# The 'kill-job' subcommand.
sub
cmd_killjob($) {
    my ($argv) = @_;

    GetOptionsFromArray($argv) or parse_error();

    if (@$argv != 1) {
        die('usage');
    }

    my ($jobid) = @$argv;

    AFS::CellCC::DB::kill_job(jobid => $jobid);

    print "Job $jobid killed\n";
}

# The 'test-alert' subcommand.
sub
cmd_testalert($) {
    my ($argv) = @_;

    GetOptionsFromArray($argv) or parse_error();

    if (@$argv != 0) {
        die('usage');
    }

    AFS::CellCC::Check::test_alert();

    print "Test alerts sent\n";
}

# The 'ping-remctl' command.
sub
cmd_pingremctl($) {
    my ($argv) = @_;

    GetOptionsFromArray($argv) or parse_error();

    if (@$argv != 1) {
        die('usage');
    }

    my ($fqdn) = @$argv;
    my @cmd = AFS::CellCC::Remoteclient::remctl_cmd(fqdn => $fqdn);
    push(@cmd, 'ping');
    print "+ ".join(' ', @cmd)."\n";
    exec { $cmd[0] } @cmd;
}

sub
main($$) {
    my ($argv0, $argvref) = @_;
    my %cmd_table;

    # Don't alter the original args
    my @argv = @$argvref;

    $cmd_table{'kill-job'} = { func => \&cmd_killjob,
                               admin => 1,
                               usage => "<jobid>",
                             };
    $cmd_table{'test-alert'} = { func => \&cmd_testalert,
                                 usage => '',
                               };
    $cmd_table{'ping-remctl'} = { func => \&cmd_pingremctl,
                                  usage => '<host>',
                                };

    AFS::CellCC::CLI::run(\%cmd_table, \@argv);
}

1;
