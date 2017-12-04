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

package AFS::CellCC::Dump;

use strict;
use warnings;

use 5.008_000;

use File::Basename;
use File::stat;
use File::Temp;

# This turns on the DEBUG, INFO, WARN, ERROR functions
use Log::Log4perl qw(:easy);

use AFS::CellCC;
use AFS::CellCC::Config qw(config_get);
use AFS::CellCC::DB qw(db_rw find_update_jobs update_job job_error);
use AFS::CellCC::VOS qw(vos_auth find_volume volume_exists volume_times);
use AFS::CellCC::Util qw(spawn_child monitor_child describe_file pretty_bytes scratch_ok
                         calc_checksum);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(process_dumps);

# Do what is needed after a volume dump has been successfully generated. We
# currently just calculate a checksum for the dump blob, and update the
# database to give the dump filename and metadata.
sub
_dump_success($$$) {
    my ($jobsref, $prev_state, $dump_fh) = @_;
    my @jobs = @$jobsref;
    my $done_state = 'DUMP_DONE';
    my $filesize = stat($dump_fh)->size;

    my @link_fhs;
    my $dump_dir = dirname($dump_fh->filename);

    seek($dump_fh, 0, 0);

    # Note that this checksum doesn't need to by cryptographically secure. md5
    # should be fine.
    my $algo = config_get('dump/checksum');
    my $checksum = calc_checksum($jobsref, $dump_fh, $filesize, $algo, $prev_state);

    # Hardlink $dump_fh to another shallow "copy" for each job.
    # We could reuse $dump_fh here for one of the jobs, instead of making a
    # hard link for each job. But do the hardlink for everyone, to keep the
    # behavior more consistent for all jobs.
    for my $job (@jobs) {
        my $fh = File::Temp->new(DIR => $dump_dir,
                                 TEMPLATE => "cccdlink_job$job->{jobid}_XXXXXX",
                                 SUFFIX => '.dump');

        # Note that we are unlinking the underlying temp file out from under
        # File::Temp. This means that the filehandle for each $fh does not
        # point to the same file as $fh->filename. This is okay for us, since
        # we don't actually write to $fh (we're just hard-linking to the
        # filename), but it's a little strange compared to what File::Temp
        # normally expects. This doesn't seem to cause any problems for our usage (File::Temp
        # will unlink the file anyway), but note that directly calling methods
        # like $fh->unlink0 or $fh->unlink1 probably will not work.
        unlink($fh->filename)
            or die("Cannot remove tmp link file: $!\n");

        link($dump_fh->filename, $fh->filename)
            or die("Cannot create dump hardlink: $!\n");

        push(@link_fhs, $fh);
    }

    # Get rid of the dump_fh file; we don't need it anymore, since we just use
    # the link files from now on.
    unlink($dump_fh->filename)
        or die("Cannot remove dump file: $!\n");
    $dump_fh->unlink_on_destroy(0);
    close($dump_fh);

    db_rw(sub($) {
        my ($dbh) = @_;
        for my $i (0 .. $#jobs) {
            my $base_file = basename($link_fhs[$i]->filename);
            my $job = $jobs[$i];

            update_job(dbh => $dbh,
                       jobid => $job->{jobid},
                       dvref => \$job->{dv},
                       from_state => $prev_state,
                       to_state => $done_state,
                       dump_fqdn => config_get('fqdn'),
                       dump_method => 'remctl',
                       dump_port => config_get('remctl/port'),
                       dump_filename => $base_file,
                       dump_checksum => $checksum,
                       dump_filesize => $filesize,
                       timeout => undef,
                       description => "Waiting to xfer dump file");
        }
    });

    # Keep the dump files around; we've reported to the db that we have them.
    for my $fh (@link_fhs) {
        $fh->unlink_on_destroy(0);
    }
}

# Get the estimated dump size for the given volume.
sub
_get_size($$$$) {
    my ($volname, $server, $partition, $lastupdate) = @_;

    my $vos = vos_auth();
    my $result = $vos->size(id => $volname, dump => 1, time => $lastupdate)
        or die("vos size error: ".$vos->errors());
    my $size = $result->dump_size;
    if (!defined($size)) {
        die;
    }
    return $size;
}

# Returns a timestamp if we should dump from that timestamp (0 for a full dump,
# or the timestamp from which we should be dumping incremental changes). Or,
# returns undef if we should not sync the volume at all.
sub
_calc_incremental($$) {
    my ($job, $state) = @_;

    if (!config_get('dump/incremental/enabled')) {
        DEBUG "Not checking remote volume; incremental dumps are not configured";
        return 0;
    }

    my $skip_unchanged = 0;
    if (config_get('dump/incremental/skip-unchanged')) {
        $skip_unchanged = 1;
    }

    my $error_fail = 1;
    if (config_get('dump/incremental/fulldump-on-error')) {
        $error_fail = 0;
    }

    update_job(jobid => $job->{jobid},
               dvref => \$job->{dv},
               from_state => $state,
               timeout => 1200,
               description => "Checking remote volume metadata");

    if (!volume_exists($job->{volname}, $job->{dst_cell})) {
        # Volume does not exist, so we'll be doing a full dump
        return 0;
    }

    my $remote_times;
    my $local_times;
    eval {
        $remote_times = volume_times($job->{volname}, $job->{dst_cell});

        update_job(jobid => $job->{jobid},
                   dvref => \$job->{dv},
                   from_state => $state,
                   timeout => 1200,
                   description => "Checking local volume metadata");

        $local_times = volume_times($job->{volname}, $job->{src_cell});

        if ($remote_times->{update} > $local_times->{update}) {
            # The remote volume appears to have data newer than the local
            # volume? That doesn't make any sense...
            die("Weird times on volume $job->{volname}: remote update ".
                "$remote_times->{update} local update $local_times->{update}\n");
        }
    };
    if ($@) {
        if ($error_fail) {
            die("Error when getting metadata for remote volume $job->{volname}: $@\n");
        }
        WARN "Encountered error when fetching metadata for remote volume ".
             "$job->{volname} (jobid $job->{jobid}), forcing full dump. Error: $@";
        return 0;
    }

    if ($skip_unchanged) {
        if ($remote_times->{update} == $local_times->{update}) {
            # The "last update" timestamp matches on the local and remote
            # volumes, so the remote volume probably does not need any update
            # at all.
            return undef;
        }
    }

    # The remote volume needs an update. Subtract 3 seconds from the lastupdate
    # time as a "fudge factor", like the normal "vos release" does.
    if ($remote_times->{update} <= 3) {
        return 0;
    }
    return $remote_times->{update} - 3;
}

# Dump the volume associated with the given jobs. We calculate some info about
# the volume, dump it to disk, and report the result to the database. All of
# the jobs in $jobsref must be for the same volume, and that volume must be
# identical in the destination cells (specifically, so we can use the same
# incremental dump for all jobs in the array).
sub
_do_dump($$$) {
    my ($server, $jobsref, $prev_state) = @_;
    my @jobs = @$jobsref;
    my $state = 'DUMP_WORK';

    # The job that we're considering to actually do the dump (the other jobs
    # are effectively just waiting for this job to finish the dump)
    my $dumpjob = $jobs[0];

    my $volname = $dumpjob->{volname}.".readonly";

    my $jobids = join(',', map { $_->{jobid} } @jobs);
    my $dst_cells = join(',', map { $_->{dst_cell} } @jobs);

    db_rw(sub ($) {
        my ($dbh) = @_;
        for my $job (@jobs) {
            update_job(dbh => $dbh,
                       jobid => $job->{jobid},
                       dvref => \$job->{dv},
                       from_state => $prev_state,
                       to_state => $state,
                       timeout => 300,
                       description => "Checking local volume state");
        }
    });

    my $lastupdate = _calc_incremental($dumpjob, $state);
    if (!defined($lastupdate)) {
        # _calc_incremental said we can skip syncing the volume, so transition
        # the job straight to the final stage
        DEBUG "volume $volname appears to not need a sync";
        db_rw(sub ($) {
            my ($dbh) = @_;
            for my $job (@jobs) {
                update_job(dbh => $dbh,
                           jobid => $job->{jobid},
                           dvref => \$job->{dv},
                           from_state => $state,
                           to_state => 'RELEASE_DONE',
                           timeout => 0,
                           description => "Remote volume appears to be up to date; skipping sync");
            }
        });
        return;
    }

    DEBUG "got lastupdate time $lastupdate for volname $volname";

    my $partition;
    ($server, $partition) = find_volume(name => $volname,
                                        type => 'RO',
                                        server => $server,
                                        cell => $dumpjob->{src_cell});

    my $dump_size = _get_size($volname, $server, $partition, $lastupdate);
    DEBUG "got dump size $dump_size for volname $volname";

    if (!scratch_ok($jobsref, $prev_state, $dump_size,
                    config_get('dump/scratch-dir'),
                    config_get('dump/scratch-minfree'))) {
        return;
    }

    db_rw(sub ($) {
        my ($dbh) = @_;
        for my $job (@jobs) {
            update_job(dbh => $dbh,
                       jobid => $job->{jobid},
                       dvref => \$job->{dv},
                       from_state => $state,
                       vol_lastupdate => $lastupdate,
                       timeout => 120,
                       description => "Starting to dump volume via job $dumpjob->{jobid}");

            $job->{vol_lastupdate} = $lastupdate;
        }
    });

    my $stderr_fh = File::Temp->new(TEMPLATE => "cccdump_job$dumpjob->{jobid}_XXXXXX",
                                    TMPDIR => 1, SUFFIX => '.stderr');

    # Determine a filename where we can put our dump blob
    my $dump_fh = File::Temp->new(DIR => config_get('dump/scratch-dir'),
                                  TEMPLATE => "cccdump_job$dumpjob->{jobid}_XXXXXX",
                                  SUFFIX => '.dump');

    # Start dumping the volume
    my $pid = spawn_child(name => 'vos dump handler',
                          stderr => $stderr_fh->filename,
                          cb => sub {
        my $vos = vos_auth();
        $vos->dump(id => $volname,
                   file => $dump_fh->filename,
                   server => $server,
                   partition => $partition,
                   time => $dumpjob->{vol_lastupdate},
                   cell => $dumpjob->{src_cell})
        or die("vos dump error: ".$vos->errors());
    });
    eval {
        # Wait for dump process to die
        my $last_bytes;
        my $last_time;
        my $pretty_total = pretty_bytes($dump_size);

        monitor_child($pid, { name => 'vos dump handler',
                              error_fh => $stderr_fh,
                              cb_intervals => config_get('dump/monitor-intervals'),
                              cb => sub {
            my ($interval) = @_;

            my ($pretty_bytes, $pretty_rate) = describe_file($dump_fh->filename,
                                                             \$last_bytes,
                                                             \$last_time);

            my $descr = "Running vos dump via job $dumpjob->{jobid} ($pretty_bytes / $pretty_total dumped, $pretty_rate)";

            db_rw(sub ($) {
                my ($dbh) = @_;
                for my $job (@jobs) {
                    update_job(dbh => $dbh,
                               jobid => $job->{jobid},
                               dvref => \$job->{dv},
                               from_state => $state,
                               timeout => $interval+60,
                               description => $descr);
                }
            });
        }});
        $pid = undef;
    };
    if ($@) {
        my $error = $@;
        # Kill our child dumping process, so it doesn't hang around
        if (defined($pid)) {
            WARN "Encountered error while dumping for job(s) $jobids; killing dumping pid $pid";
            kill('INT', $pid);
            $pid = undef;
        }
        die($error);
    }

    db_rw(sub ($) {
        my ($dbh) = @_;
        for my $job (@jobs) {
            update_job(dbh => $dbh,
                       jobid => $job->{jobid},
                       dvref => \$job->{dv},
                       from_state => $state,
                       timeout => 120,
                       description => "Processing finished dump file");
        }
    });

    DEBUG "vos dump successful, processing dump file";
    _dump_success($jobsref, $state, $dump_fh);

    INFO "Finished performing dump for job(s) $jobids (vol '$dumpjob->{volname}', $dumpjob->{src_cell} -> ($dst_cells))";
}

# Find all jobs for the given src/dst cells that need dumps, and perform the
# dumps for them. The dumps are scheduled in child processes using the given
# $pm Parallel::ForkManager object.
sub
process_dumps($$$@) {
    my ($pm, $server, $src_cell, @dst_cells) = @_;
    my $prev_state = 'NEW';
    my $start_state = 'DUMP_START';

    my @jobs;

    # Transition all NEW jobs to DUMP_START, and then find all DUMP_START jobs
    @jobs = find_update_jobs(src_cell => $src_cell,
                             dst_cells => \@dst_cells,
                             from_state => $prev_state,
                             to_state => $start_state,
                             timeout => 3600,
                             description => "Waiting for dump to be scheduled");

    for my $job (@jobs) {
        my $pid = $pm->start();
        if ($pid) {
            # In parent
            DEBUG "Spawned child pid $pid to handle dump for job ".$job->{jobid};
            next;
        }

        # In child
        eval {
            eval {
                _do_dump($server, [$job], $start_state);
            };
            if ($@) {
                my $error = $@;
                ERROR "Error when performing dump for job $job->{jobid}:";
                ERROR $error;
                job_error(jobid => $job->{jobid}, dvref => \$job->{dv});
                $pm->finish(1);
            } else {
                $pm->finish(0);
            }
        };
        # Make sure the child exits, and we don't propagate control back up to
        # our caller.
        exit(1);
    }
}

# Given a bare filename for a dump blob, return the full path to the dump blob
# on disk, suitable for opening.
sub
get_dump_path($) {
    my ($orig_filename) = @_;
    my ($filename, $dirs, undef) = fileparse($orig_filename);
    if (($dirs ne '.') && ($dirs ne '') && ($dirs ne './')) {
        # Make sure the requester cannot just retrieve/unlink any file; just
        # those in our scratch dir
        die("Got dir '$dirs': Directories are not allowed, only bare filenames\n");
    }
    return File::Spec->catfile(config_get('dump/scratch-dir'), $filename);
}

# Given a bare filename for a dump blob, 'cat' the contents of the dump blob to
# stdout.
sub
cat_dump($) {
    my ($orig_filename) = @_;
    my $path = _get_path($orig_filename);

    if (-t STDOUT) {
        die("STDOUT is a tty; refusing to dump file. Pipe through 'cat' to override\n");
    }

    binmode STDOUT;
    copy($path, \*STDOUT)
        or die("Copy failed: $!\n");
}

# Given a bare filename for a dump blob, remove the blob from disk.
sub
remove_dump($) {
    my ($orig_filename) = @_;
    my $path = _get_path($orig_filename);

    unlink($path)
        or die("Cannot remove dump: $!\n");
}

1;
