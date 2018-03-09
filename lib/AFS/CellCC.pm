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

package AFS::CellCC;

use strict;
use warnings;

use DBI;
use Parallel::ForkManager;
use Log::Log4perl qw(:easy);
use POSIX qw(WIFSIGNALED WTERMSIG WEXITSTATUS);
use Errno qw(EINTR);

use AFS::CellCC::CLI;
use AFS::CellCC::Check;
use AFS::CellCC::Config qw(config_get);
use AFS::CellCC::Const qw($VERSION_STRING);
use AFS::CellCC::DB qw(db_rw create_job);
use AFS::CellCC::Dump;
use AFS::CellCC::Util qw(spawn_child);
use AFS::CellCC::Restore;
use AFS::CellCC::VOS qw(volume_exists);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(startsync);

# This determines whether the given volume should be excluded from being synced
# to destination cells. We return 1 if the volume should be excluded (and thus,
# not synced), and we return 0 if the volume should be included (and thus, the
# volume should be synced).
sub
_exclude_volume($$$$$) {
    my ($qname, $src_cell, $volname, $dst_cell, $opts) = @_;
    my $filter = config_get('volume-filter/command');
    if (!defined($filter)) {
        return 0;
    }

    my $operation = 'sync';
    if ($opts->{delete} || $opts->{forcedelete}) {
        $operation = 'delete';
    }

    my $command = "CELLCC_FILTER_VOLUME='$volname' ".
                  "CELLCC_FILTER_SRC_CELL='$src_cell' ".
                  "CELLCC_FILTER_DST_CELL='$dst_cell' ".
                  "CELLCC_FILTER_QNAME='$qname' ".
                  "CELLCC_FILTER_OPERATION='$operation' ".
                  "$filter";

    DEBUG "running volume-filter command '$command'";

    open(my $ph, '-|', $command)
        or die("Cannot run volume-filter: $!\n");

    my $exclude;

    while (<$ph>) {
        chomp;
        DEBUG "volume-filter command got output $_";
        if (m/^#/ or m/^\s*$/) {
            # Ignore comment/blank lines
            next;
        }
        if (defined($exclude)) {
            # We already have an answer from the volume-filter command; if it
            # gave us more data, that's an error.
            die("volume-filter command gave extra output '$_'\n");
        }

        if ($_ eq 'exclude') {
            $exclude = 1;
        } elsif ($_ eq 'include') {
            $exclude = 0;
        } else {
            die("volume-filter command gave unrecognized output: $_\n");
        }
    }

    close($ph)
        or die("volume-filter: Error running '$command': errno ".($!+0)." exit status $?\n");

    if (!defined($exclude)) {
        die("volume-filter: command '$command' did not output anything useful\n");
    }

    DEBUG "_exclude_volume($qname, $src_cell, $volname, $dst_cell) returning $exclude";

    return $exclude;
}

# Start syncing the given volume from the given source cell. The cells that the
# volume is synced to is specified in the configuration, not in any arguments
# here.
#
# This returns an array of hashrefs containing information about the jobs that
# were created to do the sync. Each hashref looks like this:
# {
#    cell => 'dest.example.com',
#    jobid => 5,
# }
sub
startsync($$$;$) {
    my ($qname, $src_cell, $volname, $opts) = @_;
    my @jobs;
    my $start_state = 'NEW';

    if (!defined($qname)) {
        $qname = 'default';
    }

    if (!defined($opts)) {
        $opts = {};
    }

    if ($opts->{delete} || $opts->{forcedelete}) {
        if (!$opts->{forcedelete} && volume_exists($volname, $src_cell)) {
            die("Error: Volume $volname still exists in cell $src_cell\n");
        }
        $start_state = 'DELETE_NEW';
    }

    my $config_dst_cells = config_get('cells/'.$src_cell.'/dst-cells');

    # If the configured filter-volume command says to not sync a volume from
    # the src cell to this dest cell, skip that dest cell
    my @dst_cells;
    for my $dst_cell (@$config_dst_cells) {
        if (!_exclude_volume($qname, $src_cell, $volname, $dst_cell, $opts)) {
            push(@dst_cells, $dst_cell);
        }
    }

    db_rw(sub($) {
        my ($dbh) = @_;
        for my $dst_cell (@dst_cells) {
            my $jobid;
            $jobid = create_job(dbh => $dbh,
                                src_cell => $src_cell,
                                dst_cell => $dst_cell,
                                volname => $volname,
                                qname => $qname,
                                state => $start_state,
                                description => "Waiting for sync to start");
            push(@jobs, { cell => $dst_cell, jobid => $jobid });
        }
    });

    return @jobs;
}

# Run the 'dump-server' daemon. If $opts->{once} is set, we just check for jobs
# to run once. Otherwise, we periodically re-check for jobs to run, and
# continue forever until we are killed by a signal.
sub
dumpserver($$$;$) {
    my ($server, $src_cell, $dst_cells, $opts) = @_;
    my $once = 0;

    if (!defined($opts)) {
        $opts = {};
    }
    if ($opts->{once}) {
        $once = 1;
    }

    my $pm = Parallel::ForkManager->new(config_get('dump/max-parallel'));

    my $term_handler = 'DEFAULT';

    if (!$once) {
        INFO "CellCC dump-server $VERSION_STRING starting up";
        INFO "Using server $server to sync from cell $src_cell to ".join(',', @$dst_cells);
        $term_handler = sub {
            INFO "shutting down";
            exit(0);
        };
    }

    local $SIG{INT} = $term_handler;
    local $SIG{TERM} = $term_handler;

    while (1) {
        eval {
            AFS::CellCC::Dump::process_dumps($pm, $server, $src_cell, @$dst_cells);
        };
        if ($@) {
            my $error = $@;
            if ($once) {
                die($error);
            }
            ERROR $error;
        }

        if ($once) {
            last;
        }

        my $seconds = config_get('dump/check-interval');
        sleep($seconds);
    }

    $pm->wait_all_children();
}

# Run the 'restore-server' daemon. If $opts->{once} is set, we just check for
# jobs to run once. Otherwise, we periodically re-check for jobs to run, and
# continue forever until we are killed by a signal.
#
# We effectively run one restore-server per queue in parallel, for all queues
# defined in the config under 'restore/queues/<queue>'. For each queue we spawn
# a child process and run AFS::CellCC::Restore::server inside of it.
sub
restoreserver($;$) {
    my ($dst_cell, $opts) = @_;

    # Get a list of configured queues, making sure that a 'default' queue
    # always exists. Sorry about the ugly syntax.
    my @queues = keys %{ { %{config_get('restore/queues')}, default => undef } };

    my $parent_pm = Parallel::ForkManager->new(scalar @queues);

    my $exit_code = 0;
    # Keep track of what child restore-server processes are running
    my %child_pids;

    $parent_pm->run_on_finish(sub {
        my ($pid, $exit_code) = @_;
        my $queue = 'unknown';

        if ($child_pids{$pid}) {
            $queue = $child_pids{$pid};
        }
        delete $child_pids{$pid};
        DEBUG "Child $pid (queue $queue) exited with code $exit_code";
    });

    # When we stop running, make sure to kill any child restore-server
    # processes that are still running.
    my $term_handler = sub {
        INFO "Shutting down restore-server children...";
        for my $pid (keys %child_pids) {
            DEBUG "Sending TERM to pid $pid";
            kill('TERM', $pid);
        }
        $parent_pm->wait_all_children();
        INFO "Exiting with code $exit_code";
        exit($exit_code);
    };

    my $old_hup = $SIG{HUP};
    if (ref($old_hup) ne 'CODE') {
        $old_hup = undef;
    }
    my $hup_handler = sub {
        # Call old HUP handler, if there is one
        if (defined($old_hup)) {
            $old_hup->(@_);
        }
        INFO "Sending HUP to restore-server children...";
        for my $pid (keys %child_pids) {
            DEBUG "Sending TERM to pid $pid";
            kill('HUP', $pid);
        }
    };

    local $SIG{INT} = $term_handler;
    local $SIG{TERM} = $term_handler;
    local $SIG{HUP} = $hup_handler;

    eval {
        for my $queue (@queues) {
            my $pid = $parent_pm->start();
            if ($pid) {
                # Parent
                DEBUG "Spawned pid $pid to handle queue $queue";
                $child_pids{$pid} = $queue;
                next;
            }

            # Child
            eval {
                eval {
                    AFS::CellCC::Restore::server($queue, $dst_cell, $opts);
                };
                if ($@) {
                    ERROR $@;
                    $parent_pm->finish(1);
                }
                $parent_pm->finish(0);
            };
            # Make sure our child exits, and we don't start processing e.g. the
            # cleanup code below in our child process.
            exit(1);
        }
    };
    if ($@) {
        ERROR $@;
        $exit_code = 1;
        # Make sure we kill the child restore-server processes
        $term_handler->();

    } else {
        $parent_pm->wait_all_children();
    }
}

# Run the 'check-server' daemon. If $opts->{once} is set, we just check for
# jobs to run once. Otherwise, we periodically re-check for jobs to run, and
# continue forever until we are killed by a signal.
sub
checkserver($) {
    my ($opts) = @_;
    my $once = 0;

    if (!defined($opts)) {
        $opts = {};
    }

    if ($opts->{once}) {
        $once = 1;
    }

    my $term_handler = 'DEFAULT';

    if (!$once) {
        INFO "CellCC check-server $VERSION_STRING starting up";
        $term_handler = sub {
            INFO "shutting down";
            exit(0);
        };
    }

    local $SIG{INT} = $term_handler;
    local $SIG{TERM} = $term_handler;

    while (1) {
        eval {
            AFS::CellCC::Check::check_jobs();
        };
        if ($@) {
            my $error = $@;
            if ($once) {
                die($error);
            }
            ERROR $error;
        }

        if ($once) {
            last;
        }

        my $seconds = config_get('check/check-interval');
        sleep($seconds);
    }
}

1;
