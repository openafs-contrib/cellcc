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

package AFS::CellCC::Remoteclient;

use strict;
use warnings;

use AFS::CellCC::Config qw(config_get);

use 5.008_000;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(remctl_cmd);

# Get the arguments to run to run a remote 'cellcc remctl' command on another
# machine. That is, call:
#
#     my @remote_cellcc = remctl_cmd(fqdn => 'remote.example.com');
#
# And then run (as in, by calling system()):
#
#     (@remote_cellcc, 'subcommand', 'arg1', 'arg2')
#
# To run the command on the remote machine.
#
# Args: 'fqdn', 'port'
sub
remctl_cmd(%) {
    my %info = @_;

    my $fqdn = $info{fqdn};
    my @remctl_args;

    if (defined($info{port})) {
        push(@remctl_args, '-p', $info{port});
    }

    my $service = config_get('remctl/service');
    if (defined($service)) {
        $service =~ s/<FQDN>/$fqdn/g;
        if ($service =~ m/[<>]/) {
            # In case someone typoes FQDN, or tries to use some other macro name,
            # error out instead of passing something like '-s host/<FDQN>'.
            die("Config error: remctl/service directive looks weird after ".
                "subtitution: $service");
        }

        push(@remctl_args, '-s', $service);
    }

    return (config_get('k5start/command'), '-q',
            '-f', config_get('remctl/client-keytab'),
            config_get('remctl/princ'),
            '--',
            config_get('remctl/command'),
            @remctl_args, $fqdn, 'cellcc', 'remctl');
}
