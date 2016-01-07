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

package AFS::CellCC::VOS;

use strict;
use warnings;

use 5.008_000;

use Log::Log4perl qw(:easy);
use Carp;
use DateTime::Format::Strptime;

# Ugly hack: to avoid rpmbuild from automatically determining AFS::Command::VOS
# as a dependency, do the equivalent statements instead of a 'use'. AFS::Command
# does not have a readily-available rpm, so just require the user to install it
# via whatever means necessary. If this seems not required anymore, just change
# this crud to a plain "use AFS::Command::VOS;".
BEGIN { require AFS::Command::VOS; AFS:Command::VOS->import(); }

use AFS::CellCC::Config qw(config_get);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(vos_auth vos_unauth find_volume volume_exists volume_times
                    check_volume_sites volume_all_sites);

# Are these two sites (servers) the same?
sub
_site_eq($$) {
    my ($srv1, $srv2) = @_;
    # Now just a string comparison. But in the future, this may need to evolve
    # to something better, like looking up the names in DNS and comparing the
    # results, something like that.
    return $srv1 eq $srv2;
}

# Check if the aklog command we're giving to k5start is actually usable. If
# not, log a warning to at least give a hint as to why k5start may not be
# working.
my $_aklog_warned = 0;
sub
_check_aklog($) {
    my ($aklog) = @_;
    my $abs_aklog;

    if ($_aklog_warned) {
        # Only warn once about this
        return;
    }

    if (File::Spec->file_name_is_absolute($aklog)) {
        $abs_aklog = $aklog;
    } else {
        # If we don't have an absolute path to aklog, look for aklog in our
        # PATH.
        if (defined($ENV{PATH})) {
            for my $dir (split(/:/, $ENV{PATH})) {
                if (-x File::Spec->catfile($dir, $aklog)) {
                    $abs_aklog = $aklog;
                }
            }
        }
    }

    if (!defined($abs_aklog)) {
        WARN "Could not find aklog command '$aklog' in PATH";
        $_aklog_warned = 1;

    } elsif (!-x $abs_aklog) {
        WARN "aklog command '$abs_aklog' is not executable";
        $_aklog_warned = 1;
    }
}

# Common code for vos_auth/vos_unauth. The opts hash consists of arguments to
# give to all 'vos' commands by default.
sub
_vos($%) {
    my ($auth, %opts) = @_;
    my $command = config_get('vos/command');

    if ($auth) {
        if (config_get('vos/localauth')) {
            # If we're supposed to run as localauth, all we need is the
            # -localauth flag
            $opts{localauth} = 1;
        } else {
            # Without localauth, we need to authenticate with a krb5 keytab
            my $k5start = config_get('k5start/command');
            my $keytab = config_get('vos/keytab');
            $ENV{AKLOG} = config_get('aklog/command');
            my $princ = config_get('vos/princ');
            if (!defined($princ)) {
                $princ = '-U';
            }
            _check_aklog($ENV{AKLOG});
            $command = "$k5start -q -t -f $keytab $princ -- $command";
        }

    } else {
        $opts{noauth} = 1;
    }

    my $vos = AFS::Command::VOS->new(%opts,
                                     command => $command,
                                     timestamps => 1);
    return $vos;
}

# Get an authenticated VOS object according to our config.
sub
vos_auth(%) {
    my (%opts) = @_;
    return _vos(1, %opts);
}

# Get an unauthenticated VOS object according to our config.
sub
vos_unauth(%) {
    my (%opts) = @_;
    return _vos(0, %opts);
}

# Does the given $volume exist in $cell?
sub
volume_exists($$) {
    my ($volname, $cell) = @_;
    my $vos = vos_unauth();
    my $res = $vos->listvldb(name => $volname, cell => $cell);
    if ($res) {
        return 1;
    }
    my $errors = $vos->errors();
    if (!defined($errors)) {
        die("Misc vos listvldb error (maybe vos isn't in our path?)\n");
    }
    if ($errors =~ m/VLDB: no such entry/s) {
        return 0;
    }
    die("vos listvldb error: $errors\n");
}

# Given a volume name and cell, return the various timestamps for the volume,
# as unix timestamps. For now, only give an RW volume (RO volumes would have
# multiple sets of times).
# Returns a hashref with the following elements:
#  - creation: The "Creation" time
#  - copyTime: The "Copy" time
#  - backupTime: The "Backup" time
#  - access: The "Last Access" time
#  - update: The "Last Update" time
sub
volume_times($$) {
    my ($volname, $cell) = @_;
    my $vos = vos_unauth();
    my $res = $vos->examine(id => $volname, cell => $cell)
        or die("Error running vos examine $volname: ".$vos->errors()."\n");

    my @headers = $res->getVolumeHeaders();
    if (@headers != 1) {
        die("vos examine error: got ".scalar(@headers)." volume headers\n");
    }
    my $header = $headers[0];

    my $strp = DateTime::Format::Strptime->new(pattern => '%a %b %d %H:%M:%S %Y',
                                               on_error => 'croak',
                                               time_zone => 'GMT');

    my $ret = {};
    for my $attr (qw(creation copyTime backupTime access update)) {
        my $val = $header->getAttribute($attr);

        if (!defined($val)) {
            # In some weird cases, 'vos' can just... not output anything for
            # some of these time values. Just treat a nonexistent value as a
            # "Never".
            $val = 'Never';
        }
        DEBUG "Got volume $volname time attribute $attr ".$val;

        # Some version of DateTime::Format::Strptime cannot handle days with
        # leading spaces, e.g. "Mon Jun  1 18:04:16 2015". See
        # <https://rt.cpan.org/Public/Bug/Display.html?id=58459>. So collapse
        # multiple whitespace chars into a single whitespace char, to work around this.
        $val =~ s/(\s)\s*/$1/g;
        if ($val eq 'Never') {
            $ret->{$attr} = 0;
        } else {
            $ret->{$attr} = $strp->parse_datetime($val)->epoch;
        }
    }
    return $ret;
}

# Find the server and partition a volume is on. Arguments:
#  - name: The volume name
#  - cell: The cell to look in
#  - type: The volume type. e.g. 'RW' or 'RO'
#
# If the volume is found, we return a (server, partition) pair.
sub
find_volume(%) {
    my (%args) = @_;
    my $server;
    my $partition;

    my $vos = vos_unauth();

    DEBUG "Calling listvldb for volume ".$args{name};

    for my $arg (qw(name cell type)) {
        if (!$args{$arg}) {
            confess("Internal error: find_volume missing arg '$arg'");
        }
    }

    my $res = $vos->listvldb(name => $args{name}, cell => $args{cell})
        or die("vos listvldb error: ".$vos->errors());

    # Find what partition to use, and do some sanity checks
    for my $entry ($res->getVLDBEntries()) {

        DEBUG "Got vlentry ".$entry->name;

        if ($entry->locked) {
            die("Error: vldb entry ".$entry->name." is locked; volume may not be stable");
        }
        for my $site ($entry->getVLDBSites()) {
            if ($site->status) {
                die("Error: vldb entry ".$entry->name." site has status '".$site->status."'; ".
                    "volume may not be stable\n");
            }
            DEBUG "vlentry ".$entry->name." site ".$site->type." ".$site->server." ".$site->partition;
            if ($site->type eq $args{type}) {
                if ($args{server} && !_site_eq($site->server, $args{server})) {
                    next;
                }
                $server = $site->server;
                $partition = $site->partition;
            }
        }
    }

    if (!defined($server) || !defined($partition)) {
        die("Error: cannot find appropriate $args{type} site for volume $args{name} (cell $args{cell})\n");
    }
    return ($server, $partition);
}

# Find all sites for the given volume in the given cell. Returns an array of
# hashrefs, containing the following:
#  - {name}: The name of the volume (including the trailing .readonly or .backup)
#  - {type}: RW, RO, or BK
#  - {server}: The server of this site
#  - {partition}: The partition of this site
sub
volume_all_sites($$) {
    my ($volname, $cell) = @_;
    my $vos = vos_unauth();

    my $res = $vos->listvldb(name => $volname, cell => $cell)
        or die("vos listvldb error: ".$vos->errors());

    my @entries = $res->getVLDBEntries();
    if (@entries != 1) {
        die("Got @entries from a single vos listvldb\n");
    }

    my $entry = $entries[0];
    if ($entry->locked) {
        die("Error: vldb entry ".$entry->name." is locked");
    }

    my @ret;

    for my $site ($entry->getVLDBSites()) {
        my $retentry = {};

        $retentry->{type} = $site->type;

        if ($site->type eq 'RW') {
            $retentry->{name} = $volname;
        } elsif ($site->type eq 'RO') {
            $retentry->{name} = $volname.".readonly";
        } elsif ($site->type eq 'BK') {
            $retentry->{name} = $volname.".backup";
        } else {
            die("Unknown vldb type ".$site->type." for volume $volname cell $cell\n");
        }

        $retentry->{server} = $site->server;
        $retentry->{partition} = $site->partition;

        push @ret, $retentry;
    }

    return @ret;
}

# Check the given volume ($volname) in the given $cell, and check that the
# volume isn't "weird" in any way. That is, it's not locked and it doesn't have
# any interrupted/ongoing releases, etc.
sub
check_volume_sites($$) {
    my ($volname, $cell) = @_;
    my $vos = vos_unauth();

    my $res = $vos->listvldb(name => $volname, cell => $cell)
        or die("vos listvldb error: ".$vos->errors());

    for my $entry ($res->getVLDBEntries()) {
        if ($entry->locked) {
            die("Error: vldb entry ".$entry->name." is locked\n");
        }
        for my $site ($entry->getVLDBSites()) {
            if ($site->status) {
                die("Error: vldb entry ".$entry->name." site has status '".$site->status."'\n");
            }
        }
    }

    DEBUG "vldb status for $cell:$volname looks okay";
}

1;
