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

package AFS::CellCC::CLI::cellcc;

use strict;
use warnings;

use 5.008_000;

use Getopt::Long qw(GetOptionsFromArray);
use File::Basename;
use File::Spec;
use JSON::PP;
use Log::Log4perl qw(:easy);

use AFS::CellCC::Check;
use AFS::CellCC::CLI;
use AFS::CellCC::Remote;
use AFS::CellCC::DB;
use AFS::CellCC::Util;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(main);

sub
parse_error() {
    die("$0: Error parsing arguments\n");
}

# The 'start-sync' subcommand.
sub
cmd_startsync($) {
    my ($argv) = @_;
    my $qname;
    my $delete = 0;

    GetOptionsFromArray($argv, 'queue=s' => \$qname,
                               'delete' => \$delete) or parse_error();

    if (@$argv != 2) {
        die('usage');
    }

    my ($src_cell, $volname) = @$argv;

    my @jobs = AFS::CellCC::startsync($qname, $src_cell, $volname, {delete => $delete});
    for my $job (@jobs) {
        print "[jobid $job->{jobid}]: volume $volname, cell $src_cell -> $job->{cell}\n";
    }
    if (@jobs) {
        print "\nSuccessfully started syncing volume '$volname'\n";
    } else {
        print "Volume '$volname' not synced (it was probably filtered out)\n";
    }
}

# The 'dump-server' subcommand.
sub
cmd_dumpserver($) {
    my ($argv) = @_;
    my $once = 0;

    GetOptionsFromArray($argv, 'once' => \$once) or parse_error();

    if (@$argv < 3) {
        die('usage');
    }

    my ($server, $src_cell, @dst_cells) = @$argv;
    AFS::CellCC::dumpserver($server, $src_cell, \@dst_cells, {once => $once});
}

# The 'restore-server' subcommand.
sub
cmd_restoreserver($) {
    my ($argv) = @_;
    my $once = 0;

    GetOptionsFromArray($argv, 'once'=> \$once) or parse_error();

    if (@$argv != 1) {
        die('usage');
    }

    my ($dst_cell) = @$argv;
    AFS::CellCC::restoreserver($dst_cell, {once => $once});
}

# The 'check-server' subcommand.
sub
cmd_checkserver($) {
    my ($argv) = @_;
    my $once = 0;

    GetOptionsFromArray($argv, 'once'=> \$once) or parse_error();

    if (@$argv != 0) {
        die('usage');
    }

    AFS::CellCC::checkserver({once => $once});
}

# The 'jobs' subcommand.
sub
cmd_jobs($) {
    my ($argv) = @_;
    my $format = 'txt';
    my $show_errors;

    GetOptionsFromArray($argv, 'format=s' => \$format,
                               'errors' => \$show_errors) or parse_error();

    if (@$argv != 0) {
        die('usage');
    }
    if ($format eq 'txt') {
    } elsif ($format eq 'json') {
    } else {
        die("Unrecognized format '$format'\n");
    }

    my @raw_jobs = AFS::CellCC::DB::describe_jobs();
    my @jobs;
    for my $raw_job (@raw_jobs) {
        if (($raw_job->{state} ne 'ERROR') && $show_errors) {
            # Don't show a non-error job, if we're just supposed to show
            # errors
            next;
        }
        push(@jobs, AFS::CellCC::DB::jobinfo_stringify($raw_job));
    }

    if ($format eq 'txt') {
        if (not @jobs) {
            print "No running jobs found\n";
        }

        for my $job (@jobs) {
            my $dump_filesize = "unknown";
            if (defined($job->{dump_filesize})) {
                $dump_filesize = AFS::CellCC::Util::pretty_bytes($job->{dump_filesize});
            }

            for my $field (qw(timeout deadline status_fqdn)) {
                if (!defined($job->{$field})) {
                    $job->{$field} = "unknown";
                }
            }

            my $state = $job->{state};
            if ($state eq 'ERROR') {
                $state .= "/".$job->{last_good_state};
            }

            print "\njobid $job->{jobid}:\n";
            print "    Volume: $job->{volname}\n";
            print "    Source cell: $job->{src_cell}\n";
            print "    Destination cell: $job->{dst_cell}\n";
            print "    DV: $job->{dv}\n";
            print "    Queue: $job->{qname}\n";
            print "    State: $state\n";
            print "    Errors: $job->{errors}\n";
            print "    ctime: $job->{ctime}\n";
            print "    mtime: $job->{mtime}\n";
            print "    deadline: $job->{deadline}\n";
            print "    timeout: $job->{timeout}\n";
            print "    Dump size: $dump_filesize\n";
            print "    Last host: \"$job->{status_fqdn}\"\n";
            print "    Last known status: \"$job->{description}\"\n";
        }

    } elsif ($format eq 'json') {
        print JSON::PP->new->encode({ jobs => [@jobs] });
    }
}

# The 'remctl' subcommand.
sub
cmd_remctl($) {
    my ($argv) = @_;

    AFS::CellCC::Remote::run_remctl($argv);
}

# The 'retry-job' subcommand.
sub
cmd_retryjob($) {
    my ($argv) = @_;

    GetOptionsFromArray($argv) or parse_error();

    if (@$argv != 1) {
        die('usage');
    }

    my ($jobid) = @$argv;

    AFS::CellCC::Check::retry_job($jobid);

    print "Job $jobid successfully retried.\n";
}

# The 'config' subcommand.
sub
cmd_config($) {
    my ($argv) = @_;
    my $check = 0;
    my $dump = 0;
    my $dump_all = 0;
    my $expected_args = 1;
    my $bad = 0;

    GetOptionsFromArray($argv, 'check' => \$check,
                               'dump' => \$dump,
                               'dump-all' => \$dump_all) or parse_error();

    my $flags = $check + $dump + $dump_all;
    if ($flags > 1) {
        $bad = 1;
    }
    if ($flags != 0) {
        $expected_args = 0;
    }
    if (@$argv != $expected_args) {
        $bad = 1;
    }
    if ($bad) {
        die('usage');
    }

    if (@$argv) {
        my ($key) = @$argv;
        print AFS::CellCC::Config::config_get_printable($key);
    }
    if ($check) {
        AFS::CellCC::Config::config_check();
    }
    if ($dump) {
        print AFS::CellCC::Config::config_dump()."\n";
    }
    if ($dump_all) {
        print AFS::CellCC::Config::config_dump(include_defaults => 1)."\n";
    }
}

# The 'vars' subcommand.
sub
cmd_vars($) {
    my ($argv) = @_;

    GetOptionsFromArray($argv) or parse_error();

    my %vars = (
        PREFIX        => $AFS::CellCC::Const::PREFIX,
        BINDIR        => $AFS::CellCC::Const::BINDIR,
        LOCALSTATEDIR => $AFS::CellCC::Const::LOCALSTATEDIR,
        SYSCONFDIR    => $AFS::CellCC::Const::SYSCONFDIR,

        CONF_DIR      => $AFS::CellCC::Const::CONF_DIR,
        BLOB_DIR      => $AFS::CellCC::Const::BLOB_DIR,
    );

    for my $arg (@$argv ? @$argv : sort keys %vars) {
        if (!exists $vars{$arg}) {
            die("Unknown var '$arg'\n");
        }
        print "$arg = ".$vars{$arg}."\n";
    }
}

sub
main($$) {
    my ($argv0, $argvref) = @_;

    # Don't alter the original args
    my @argv = @$argvref;

    my %cmd_table = (
        jobs => { func => \&cmd_jobs,
                  usage => "[--format <format>]",
                },
        remctl => { func => \&cmd_remctl,
                    daemon => 1,
                    remote => 1,
                  },
        vars => { func => \&cmd_vars,
                  noconfig => 1, },
        config => { func => \&cmd_config,
                    admin => 'try',
                    usage => "<--check | --dump | --dump-all | <key> >",
                  },

        'retry-job' => { func => \&cmd_retryjob,
                         admin => 1,
                         usage => "<jobid>",
                       },

        'start-sync' => { func => \&cmd_startsync,
                          admin => 1,
                          usage => "[--queue <qname>] [--delete] <src_cell> <volume_name>",
                        },

        'dump-server' => { func => \&cmd_dumpserver,
                           admin => 1,
                           daemon => 1,
                           usage => "[--once] <server> <src_cell> <dst_cell1> [<dst_cell2> ... <dst_cellN>]",
                         },

        'restore-server' => { func => \&cmd_restoreserver,
                              admin => 1,
                              daemon => 1,
                              usage => "[--once] <dst_cell>",
                            },

        'check-server' => { func => \&cmd_checkserver,
                            admin => 1,
                            daemon => 1,
                            usage => "[--once]",
                          },
    );

    AFS::CellCC::CLI::run(\%cmd_table, \@argv);
}

1;
