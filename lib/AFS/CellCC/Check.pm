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

package AFS::CellCC::Check;

use strict;
use warnings;

use Log::Log4perl qw(:easy);
use JSON::PP;
use DateTime;

use AFS::CellCC::Config qw(config_get);
use AFS::CellCC::DB qw(describe_jobs
                       job_error
                       job_reset
                       archive_job
                       update_job
                       kill_job
                       jobinfo_stringify
                       find_jobs);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(check_jobs);

# Generate an alert of type $type for job %$a_job, and add the alert to the
# @$alerts array.
sub
_alert($$$) {
    my ($a_job, $alerts, $type) = @_;

    DEBUG "Generating alert $type for job $a_job->{jobid}";

    my $job = jobinfo_stringify($a_job);

    push(@$alerts, { alert => $type,
                     job => $job });
}

# Given the state a job failed in, find out what state that job should be
# transitioned to, so it can be retried.
sub
_retry_state($$) {
    my ($job, $old_state) = @_;

    my %table = (
        DUMP_WORK => 'DUMP_START',
        XFER_WORK => 'XFER_START',
        RESTORE_WORK => 'RESTORE_START',
        RELEASE_WORK => 'RELEASE_START',
        DELETE_DEST_WORK => 'DELETE_DEST_START',
    );

    if (!(exists $table{$old_state})) {
        die("Internal error: we were told to retry job ".$job->{jobid}.", ".
            "but state $old_state is un-retriable\n");
    }

    return $table{$old_state};
}

# Check if a job is in an error state and should be retried. If it should be
# retried, change the job to an appropriate state.
sub
_check_reset($$) {
    my ($job, $alerts) = @_;
    if ($job->{state} ne 'ERROR') {
        return 0;
    }

    if ($job->{errors} >= config_get('check/error-limit')) {
        my $send_alert = 0;
        if (!defined($job->{errorlimit_mtime})) {
            DEBUG "No previous errorlimit alert for job $job->{jobid}";
            $send_alert = 1;

        } else {
            my $seconds = $job->{now_server}->subtract_datetime_absolute($job->{errorlimit_mtime})->seconds;
            DEBUG "Last errorlimit alert for job $job->{jobid} was $seconds seconds ago";
            if ($seconds >= config_get('check/alert-errlimit-interval')) {
                $send_alert = 1;
            }
        }

        if ($send_alert) {
            _alert($job, $alerts, 'ALERT_ERRORLIMIT');
            update_job(jobid => $job->{jobid},
                       dvref => \$job->{dv},
                       timeout => 0,
                       errorlimit_mtime => 1);
        }

    } else {
        job_reset(jobid => $job->{jobid},
                  dvref => \$job->{dv},
                  to_state => _retry_state($job, $job->{last_good_state}));
        _alert($job, $alerts, 'ALERT_RETRY');
    }
    return 1;
}

# Retry the error'd job associated with the given jobid.
sub
retry_job($) {
    my ($jobid) = @_;
    my @jobs = describe_jobs(jobid => $jobid);
    if (@jobs > 1) {
        confess("Internal DB Error: more than one job found for jobid $jobid?");
    }

    if (@jobs < 1) {
        die("Error: job $jobid does not exist\n");
    }

    my $job = $jobs[0];
    if ($job->{state} ne 'ERROR') {
        die("Error: job $jobid is still running (state $job->{state}). It ".
            "should be in ERROR state to retry it.\n");
    }

    if ($job->{errors} < config_get('check/error-limit')) {
        WARN "Job $jobid has only seen $job->{errors}, which is below the ".
             "limit of ".config_get('check/error-limit');
        WARN "This job should be retried automatically by the check-server, ".
             "but we will retry it now anyway, as requested."
    }

    job_reset(jobid => $job->{jobid},
              dvref => \$job->{dv},
              errors => 0,
              to_state => _retry_state($job, $job->{last_good_state}));
}

# Check if the given job is done. If it's done, get rid of it.
sub
_check_done($$) {
    my ($job, $alerts) = @_;

    if ($job->{state} eq 'RELEASE_DONE') {
        # noop
    } elsif ($job->{state} eq 'DELETE_DEST_DONE') {
        # noop
    } else {
        # If we've reached here, the job isn't done yet. So, don't process it.
        return 0;
    }

    INFO "Cleaning up finished job $job->{jobid} (vol $job->{volname}, $job->{src_cell} -> $job->{dst_cell})";

    if (config_get('check/archive-jobs')) {
        DEBUG "archiving job $job->{jobid}";
        archive_job(jobid => $job->{jobid},
                    dv => $job->{dv});
    }
    kill_job(jobid => $job->{jobid},
             dv => $job->{dv});
    return 1;
}

# Check if the given job has expired. If it has expired, error out the job and
# create an alert.
sub
_check_expired($$) {
    my ($job, $alerts) = @_;
    if ($job->{expired}) {
        _alert($job, $alerts, 'ALERT_EXPIRED');
        job_error(jobid => $job->{jobid},
                  dvref => \$job->{dv});
        return 1;
    }
    return 0;
}

# Check if a job hasn't done anything in a while. If so, generate the
# appropriate alert.
sub
_check_old($$) {
    my ($job, $alerts) = @_;
    if ($job->{stale_seconds} > config_get('check/alert-stale-seconds')) {
        _alert($job, $alerts, 'ALERT_STALE');
        return 1;
    }
    if ($job->{age_seconds} > config_get('check/alert-old-seconds')) {
        _alert($job, $alerts, 'ALERT_OLD');
        return 1;
    }
    return 0;
}

# Check the given job, if there are any problems with it that warrant sending
# an alert. If so, generate an alert for it, and add it to the @$alerts array.
sub
_check_job($$) {
    my ($job, $alerts) = @_;

    DEBUG "Checking jobid $job->{jobid}";

    # Look through all jobs, and see if they need restarting or warrant an
    # alert, etc
    for my $func (\&_check_reset,
                  \&_check_done,
                  \&_check_expired,
                  \&_check_old,) {

        my $done = $func->($job, $alerts);
        if ($done) {
            return;
        }
    }
}

# Generate the text for a human-readable alert. We just return the string to
# send to the administrator for the alert.
sub
_alert_text_single($) {
    my ($alert) = @_;
    my $type = $alert->{alert};
    my $job = $alert->{job};

    my $stale_secs = config_get('check/alert-stale-seconds');
    my $old_secs = config_get('check/alert-old-seconds');

    my %desc_table = (
        ALERT_ERRORLIMIT =>
            "This job has failed too many times and will not be retried.\n".
            "If you have fixed the issue causing it to fail, you can cause\n".
            "it to be retried again with 'cellcc retry-job <jobid>'.",

        ALERT_EXPIRED =>
            "This job has taken too long to proceed to the next stage, though\n".
            "it does not indicate failure. A stage may be stuck, or maybe was\n".
            "killed uncleanly. CellCC will attempt to retry it.",

        ALERT_RETRY =>
            "An error caused this job to fail to sync its volume. CellCC\n".
            "will retry the sync at the point of failure.",

        ALERT_STALE =>
            "This job has been stuck in the same stage for longer than\n".
            "$stale_secs seconds without proceeding.",

        ALERT_OLD =>
            "This job does not appear to be stuck, but it was started over\n".
            "$old_secs seconds ago, and still has not finished.",
    );

    my $desc = $desc_table{$type};
    if (!defined($desc)) {
        die("Unable to handle alert type '$type'\n");
    }
    $desc =~ s/^/   /gm;

    my $status = $job->{state};
    if ($job->{state} eq 'ERROR') {
        $status .= "/".$job->{last_good_state};
    }
    if ($job->{description}) {
        $status .= " ($job->{description})";
    }
    if ($job->{status_fqdn}) {
        $status .= " (host $job->{status_fqdn})";
    }

    return <<"EOS";

 - $type for volume '$job->{volname}' ($job->{src_cell} -> $job->{dst_cell})
$desc

   Details:
   Job ID: $job->{jobid}
   Started on: $job->{ctime}
   Last heard from: $job->{mtime}
   Current time: $job->{now_server}
   Status: $status
EOS
}

# Given an array of alerts, construct a human-readable text message to describe
# the alerts, and return the message.
sub
_alert_text($) {
    my ($alerts) = @_;
    my $message = "";

    $message .= "CellCC has detected the following ".@$alerts." problem(s), which may require attention:\n";

    for my $alert (@$alerts) {
        $message .= _alert_text_single($alert);
    }
    return $message;
}

# Given an array of alerts, construct a JSON-encoded string of info describing
# the alerts.
sub
_alert_json($) {
    my ($alerts) = @_;
    return JSON::PP->new->encode({ alerts => $alerts });
}

# Run the given alert command ($cmd) with the given $data on stdin.
sub
_run_alert($$) {
    my ($cmd, $data) = @_;
    my $cmd_str = $cmd;
    my $pid;
    my $ph;

    if (ref($cmd) eq 'ARRAY') {
        $pid = open($ph, '|-', @$cmd);
        $cmd_str = join(' ', @$cmd);

    } else {
        $pid = open($ph, '|-', $cmd);
    }

    if (!defined($pid)) {
        die("Cannot execute alert command '$cmd_str': $!\n");
    }

    DEBUG "Running alert command '$cmd_str' in pid $pid";
    DEBUG "Sending alert data $data";

    print $ph "$data\n";

    close($ph)
        or die("Alert command '$cmd_str' failed: $?\n");
}

# Given an array of alerts, send out some formatted alerts to administrators
# according to the configured commands.
sub
_send_alerts($) {
    my ($alerts) = @_;
    if (@$alerts) {
        # If we have accumulated any alerts, send them out
        my $cmd;
        my $data;
        $cmd = config_get('check/alert-cmd/txt');
        if (defined($cmd)) {
            $data = _alert_text($alerts);
            _run_alert($cmd, $data);
        }

        $cmd = config_get('check/alert-cmd/json');
        if (defined($cmd)) {
            $data = _alert_json($alerts);
            _run_alert($cmd, $data);
        }

        if (config_get('check/alert-log')) {
            $data = _alert_text($alerts);
            for my $line (split /^/, $data) {
                chomp $line;
                WARN "$line";
            }
        }
    }
}

# Look through all running jobs, and check them for issues. We retry jobs that
# need retrying, and send out any appropriate alerts.
sub
check_jobs() {
    my @jobs = describe_jobs();
    my $alerts = [];

    for my $job (@jobs) {
        eval {
            _check_job($job, $alerts);
        };
        if ($@) {
            my $error = $@;
            ERROR "Error checking jobid $job->{jobid}: $error";
        }
    }

    _send_alerts($alerts);
}

# Generate some example 'test' alerts, and send them out.
sub
test_alert() {
    my $jobs = AFS::CellCC::DB::describe_dummy_jobs(5);
    my $alerts = [];

    _alert($jobs->[0], $alerts, 'ALERT_ERRORLIMIT');
    _alert($jobs->[1], $alerts, 'ALERT_RETRY');
    _alert($jobs->[2], $alerts, 'ALERT_STALE');
    _alert($jobs->[3], $alerts, 'ALERT_OLD');
    _alert($jobs->[4], $alerts, 'ALERT_EXPIRED');

    _send_alerts($alerts);
}

1;
