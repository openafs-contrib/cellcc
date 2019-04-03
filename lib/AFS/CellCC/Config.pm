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

package AFS::CellCC::Config;

use strict;
use warnings;

# We could use other JSON modules if available, but we don't care so much
# about speed, and this one is more common.
use JSON::PP;
use Net::Domain qw(hostfqdn);
use Log::Log4perl qw(:easy);
use Data::Dumper;

use AFS::CellCC::Log qw(log_init);
use AFS::CellCC::Const qw($CONF_DIR $BLOB_DIR);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(config_load config_get config_parse_override set_daemon);

# Pre-populate our config with some builtin values
my %CONF = (
    '_config_file' => "$CONF_DIR/cellcc.json",
    '_config_file_admin' => "$CONF_DIR/cellcc_admin.json",
    '_daemon' => 0,
);
my @CONF_ARGS;

my $force_debug = 0;
if ($ENV{CELLCC_DEBUG}) {
    # Allow the caller to turn debugging code on very early, before we parse
    # our config or even command-line arguments. This allows debugging of the
    # config/CLI parsing if needed
    $force_debug = 1;
}

my $_default_check_intervals = [1, 1, 5, 30];

# Calculate and return our default FQDN, to be used if an FQDN is not
# explicitly configured.
sub
_default_fqdn($) {
    my ($conf) = @_;
    my $fqdn = hostfqdn();
    if (!defined($fqdn)) {
        # This is a long message, but oh well. I want to let them know what's
        # going on.
        die("Cannot determine fqdn automatically. You must either specify ".
            "the 'fqdn' config directive, or configure the machine to allow ".
            "Net::Domain to determine your FQDN\n");
    }
    if (config_get('_daemon', {conf => $conf})) {
        INFO "Using hostname FQDN '$fqdn'";
    } else {
        DEBUG "Using hostname FQDN '$fqdn'";
    }
    return $fqdn;
}

# Here are all of the config directives we understand.
# 'key' means the key this entry is for (a plain string, or a regex)
# 'type' is the type the entry should be, in the form of what ref() should
#        return. If not specified, defaults to 'SCALAR'
my @directives = (
    { key => 'db/ro/dsn', },
    { key => 'db/ro/user', },
    { key => 'db/ro/pass', },

    { key => 'db/rw/dsn',
      default => sub { config_get('db/ro/dsn', {conf => $_[0]}) },
    },
    { key => 'db/rw/user', },
    { key => 'db/rw/pass', },

    { key => qr:^cells/[^/]+/dst-cells$:, type => 'ARRAY', },

    { key => 'volume-filter/command', default => undef, },

    { key => 'dump/monitor-intervals', default => $_default_check_intervals,
      type => 'ARRAY', },
    { key => 'dump/checksum', default => 'MD5', },
    { key => 'dump/scratch-dir', default => "$BLOB_DIR/dump-scratch", },
    { key => 'dump/scratch-minfree', default => "100M", },
    { key => 'dump/check-interval', default => 60, },
    { key => 'dump/max-parallel', default => 10, },
    { key => 'dump/incremental/enabled', default => 0, },
    { key => 'dump/incremental/skip-unchanged', default => 0, },
    { key => 'dump/incremental/fulldump-on-error', default => 0, },

    { key => 'restore/monitor-intervals', default => $_default_check_intervals,
      type => 'ARRAY', },
    { key => 'restore/scratch-dir', default => "$BLOB_DIR/restore-scratch", },
    { key => 'restore/scratch-minfree', default => "100M", },
    { key => 'restore/check-interval', default => 60, },
    { key => 'restore/queues', type => 'HASH', default => {}, },
    { key => qr:^restore/queues/[^/]+/max-parallel$:, default => 1, },
    { key => qr:^restore/queues/[^/]+/release/flags$:, type => 'HASH', default => {}, },
    { key => qr:^restore/queues/[^/]+/release/flags/[^/]+$:, },

    { key => 'xfer/monitor-intervals', default => $_default_check_intervals,
      type => 'ARRAY', },

    { key => 'release/monitor-intervals', default => $_default_check_intervals,
      type => 'ARRAY', },

    { key => 'vos/localauth', default => 0, },
    { key => 'vos/command', default => 'vos', },
    { key => 'vos/princ', default => undef, },
    { key => 'vos/keytab', default => "$CONF_DIR/vos.keytab", },

    { key => 'aklog/command', default => 'aklog', },

    { key => 'k5start/command', default => 'k5start', },

    { key => 'log/level', default => 'info', },
    { key => 'log/config', default => undef, },

    { key => 'fqdn', default => sub { _default_fqdn($_[0]) }, },

    { key => 'remctl/port', default => '4373', },
    { key => 'remctl/princ', },
    { key => 'remctl/service', default => 'host/<FQDN>', }, # <FQDN> gets replaced by the hostname
    { key => 'remctl/client-keytab', default => "$CONF_DIR/remctl-client.keytab", },
    { key => 'remctl/command', default => 'remctl', },

    { key => 'pick-sites/command', },

    { key => 'check/check-interval', default => 60, },
    { key => 'check/error-limit', default => 5, },
    { key => 'check/alert-errlimit-interval', default => 60*60*6, }, # 6 hours
    { key => 'check/alert-stale-seconds', default => 60*30, }, # 30 mins
    { key => 'check/alert-old-seconds', default => 60*60*24, }, # 1 day
    { key => 'check/alert-cmd/txt', default => undef, },
    { key => 'check/alert-cmd/json', default => undef, },
    { key => 'check/alert-log', default => 1, },
    { key => 'check/archive-jobs', default => 1, },
);

# Read in the contents of a whole file
sub
_slurp($) {
    my ($config) = @_;
    my $buf;

    open(my $fh, '<', $config) or die("Cannot open config file $config: $!\n");

    local $/ = undef;
    $buf = <$fh>;
    close($fh);

    return $buf;
}

# Overrides directives in the $dst hash with values in the $src hash
sub _merge($$);
sub
_merge($$) {
    my ($dst, $src) = @_;

    keys %$src;
    while (my ($key, $val) = each %$src) {

        if (!defined($dst->{$key})) {
            # Value doesn't exist in original hash, so just copy the new value
            $dst->{$key} = $val;
            next;
        }

        if ((ref($dst->{$key}) eq 'HASH') && (ref($val) eq 'HASH')) {
            # We have 2 hashes, so merge those
            _merge($dst->{$key}, $val);
            next;
        }

        # Otherwise, we either have 2 scalars, or 2 arrays, or we're merging
        # a hash ref into an array ref or something. We don't handle "merging"
        # in any of those cases, so just copy the value over.
        $dst->{$key} = $val;
    }
}

# Handles the include directives in a single config file. Takes a config
# hashref, the name of the 'includes' field, and the filename for the current
# config.
sub
_handle_inc($$$) {
    my ($conf, $name, $conf_file) = @_;

    my $val = $conf->{$name};
    if (!defined($val)) {
        return;
    }

    delete $conf->{$name};

    if (ref($val) eq '') {
        $val = [$val];
    }

    if (ref($val) ne 'ARRAY') {
        die("Config error: Bad format for $name in $conf_file\n");
    }

    # For each filename we got, look up the file relative to the current
    # config filename, and expand it as a glob pattern (so we can include
    # e.g. '/etc/foo.d/*.json'
    my @files = map {
        my $pat = File::Spec->rel2abs($_, $conf_file);
        return bsd_glob($pat, 0);
    } @$val;

    for my $file (@files) {
        _load_file($conf, $file);
    }
}

# Load the config file specified by 'conf_file', and handle all includes, etc
# for it.
# The loaded data gets set into the given $conf hashref.
sub
_load_file($$) {
    my ($conf, $conf_file) = @_;

    my $json = _slurp($conf_file);

    my $new_conf = JSON::PP->new->relaxed->allow_barekey->decode($json);

    _handle_inc($new_conf, 'include', $conf_file);

    _merge($conf, $new_conf);
}

# Return an array of all keys in the given config hash. 'key' here means the
# fully-qualified config directive key, e.g. 'db/ro/dsn', so we must
# recursively traverse the config hashref to find all fully-qualified key
# names.
sub _allkeys($);
sub
_allkeys($) {
    my ($conf) = @_;
    my @keys;

    for my $key (keys %$conf) {
        my $val = $conf->{$key};
        if (ref($val) eq 'HASH') {
            for my $subkey (_allkeys($val)) {
                push(@keys, _arr2key($key, $subkey));
            }
        } else {
            push(@keys, $key);
        }
    }
    return @keys;
}

# Find information about a configuration directive
sub
_find_dirinfo($) {
    my ($key) = @_;
    my $dirinfo;

    for my $dir (@directives) {
        if (ref($dir->{key}) eq 'Regexp') {
            # If we have a regex, see if this $dir if the right dir by
            # seeing if the regex matches.
            if ($key =~ m/$dir->{key}/) {
                $dirinfo = $dir;
            }
        } else {
            # Otherwise, we have a plain string, so just compare via normal
            # string equality.
            if ($dir->{key} eq $key) {
                $dirinfo = $dir;
            }
        }
        if (defined($dirinfo)) {
            # We found our dir; we can stop
            last;
        }
    }

    return $dirinfo;
}

# Check if the given config hash is valid. Currently this just means we check
# that all required config directives are provided.
sub
_check($) {
    my ($conf) = @_;

    for my $key (_allkeys($conf)) {

        # For each key, find a corresponding entry in @directives
        my $dirinfo = _find_dirinfo($key);
        if (!defined($dirinfo)) {
            die("Unknown config directive '$key'\n");
        }

        my $val = config_get($key, {conf => $conf});
        my $got_ref = ref($val);
        if ($got_ref eq '') {
            $got_ref = 'SCALAR';
        }

        my $expected_ref = $dirinfo->{type};
        if (!defined($expected_ref)) {
            $expected_ref = 'SCALAR';
        }

        if ($got_ref ne $expected_ref) {
            die("Wrong type for config directive '$key'; got $got_ref, ".
                "expected $expected_ref\n");
        }
    }
}

# Take a full key (e.g. 'foo/bar/baz') and return an array of key elements
# (e.g. ('foo', 'bar', 'baz')
sub
_key2arr($) {
    my ($full_key) = @_;
    return split(m:/:, $full_key);
}

sub
_arr2key(@) {
    my (@arr) = @_;
    return join('/', @arr);
}

sub
set_daemon() {
    $CONF{'_daemon'} = 1;
}

# Sets the configuration key $full_key in $conf to $val.
sub
_set($$$) {
    my ($conf, $full_key, $val) = @_;
    my @keys = _key2arr($full_key);
    my $last_key = pop(@keys);

    for my $key (@keys) {
        if (!exists($conf->{$key})) {
            $conf->{$key} = {};
        }
        if (ref($conf->{$key}) ne 'HASH') {
            $conf->{$key} = {};
        }

        $conf = $conf->{$key};
    }

    $conf->{$last_key} = $val;
}

# config_get('foo/bar') retrieves the config directive 'foo/bar' from the
# loaded configuration.
#
# $opts is a hashref for:
# - $opts->{conf} says to use a different config hash. by default we use the
#                 global loaded config hash.
sub
config_get($;$) {
    my ($full_key, $opts) = @_;
    my $val;
    my $found = 0;
    my $root = \%CONF;
    if (defined($opts->{conf})) {
        $root = $opts->{conf};
    }

    # Special case for debugging, if we have forced debugging on
    if (($full_key eq 'log/level') && $force_debug) {
        return 'debug';
    }

    $val = $root;

    # Traverse down the config hash via the keys in $full_key
    for my $key (_key2arr($full_key)) {
        if (ref($val) ne 'HASH') {
            # The full path to $full_key doesn't seem to exist
            $val = undef;
            $found = 0;
            last;
        }
        if (exists($val->{$key})) {
            $val = $val->{$key};
            $found = 1;
        } else {
            $val = undef;
            $found = 0;
            last;
        }
    }

    if (!$found) {
        # We don't have a value; see if there's a default for this
        # directive
        my $dirinfo = _find_dirinfo($full_key);
        if (!defined($dirinfo)) {
            die("Internal error: unknown config directive '$full_key'\n");
        }
        if (exists $dirinfo->{default}) {
            if (ref($dirinfo->{default}) eq 'CODE') {
                $val = $dirinfo->{default}->($root, $full_key);
            } else {
                $val = $dirinfo->{default};
            }
            # Set this default value in the config hash, so we don't need
            # to calculate the default every time we look at this
            _set($root, $full_key, $val);
            $found = 1;
        }
    }
    if (!$found) {
        die("Configuration error: Directive '$full_key' not specified\n");
    }
    return $val;
}

# Load configuration from disk into the global config. $overrides is a hashref
# containing config overrides (e.g. $overrides->{'foo.bar'} = 'baz' overrides
# config directive foo.bar to the value 'baz'). The optional
# $override_conf_file specifies a config file to read, instead of the default
# config. $opts is a hashref for some options:
# - 'admin' specifies to load the admin config by default
sub
config_load($;$$) {
    my ($overrides, $override_conf_file, $opts) = @_;
    my @conf_files;

    if (!defined($opts)) {
        $opts = {};
    }

    # Use the provided config file if it was provided; otherwise use our
    # builtin defaults.
    if (defined($override_conf_file)) {
        push(@conf_files, $override_conf_file);
    } else {
        push(@conf_files, config_get('_config_file'));
        if ($opts->{admin}) {
            push(@conf_files, config_get('_config_file_admin'));
        }
    }

    # Load the data from those config files
    my %conf;
    for my $file (@conf_files) {
        DEBUG "Loading configuration file $file";
        eval {
            _load_file(\%conf, $file);
        };
        if ($@) {
            die("Configuration error ($file): $@");
        }
    }

    eval {
        # Override any config directives with the given overrides
        for my $key (keys %$overrides) {
            _set(\%conf, $key, $overrides->{$key});
        }

        # Check that the config data we have loaded is okay
        _check(\%conf);

        # Preserve builtin values (those prefixed with '_')
        for my $key (grep(/^_/, keys(%CONF))) {
            $conf{$key} = $CONF{$key};
        }

        # If we don't have a hard-coded fqdn set, make sure the default function
        # runs early to calculate what our fqdn should be. This avoids
        # recalculating this repeatedly if we e.g. regularly spawn child processes
        # that need the fqdn.
        config_get('fqdn', {conf => \%conf});

        my %old_conf = %CONF;

        # Install our new config
        %CONF = %conf;

        eval {
            # Reinitialize our logging, in case any logging-related directives
            # have changed.
            log_init();
        };
        if ($@) {
            # If logging failed to reinitialize, assume it was due to some
            # problem with the new config. Go back to the old config.
            my $error = $@;
            %CONF = %old_conf;
            die($error);
        }

        # Save the arguments we were called with, so we can reload the config
        # later on with the exact same overrides, config file path, etc
        @CONF_ARGS = ({ %$overrides }, $override_conf_file, { %$opts });
        if (config_get('_daemon')) {
            $SIG{HUP} = \&_config_reload;
        }
    };
    if ($@) {
        die("Configuration error: $@");
    }
}

sub
_config_reload {
    INFO "Received HUP, reloading configuration";
    eval {
        config_load($CONF_ARGS[0], $CONF_ARGS[1], $CONF_ARGS[2]);
    };
    if ($@) {
        ERROR $@;
        ERROR "Errors in new configuration; keeping old configuration";
    } else {
        INFO "New configuration loaded successfully";
    }
}

# Gets the value for the given config directive, as a JSON-encoded string.
sub
config_get_printable($) {
    my ($key) = @_;
    my $val = config_get($key);
    return JSON::PP->new->allow_nonref->indent->space_after->encode($val);
}

# Check the loaded configuration for errors.
sub
config_check() {
    my @errors;
    # For each key, just try to retrieve the key. If we can't get a key, that's
    # an error, so the config is not OK.
    for my $dir (@directives) {
        if (ref($dir->{key}) eq '') {
            # Only do this for scalar keys; checking regex etc isn't feasible
            eval {
                config_get($dir->{key});
            };
            if ($@) {
                push(@errors, $@);
            }
        }
    }
    if (@errors) {
        my $error_str = join('', @errors);
        chomp $error_str;
        die("Configuration is maybe not okay. The following issues were found:\n".
            "$error_str\n");
    }
}

# Return a JSON-encoded copy of the currently-loaded configuration. If
# 'include_defaults' is set, we also return information on default values, even
# if they're not explicitly specified in the config.
sub
config_dump(%) {
    my %opts = @_;
    my $conf_ref;

    if ($opts{include_defaults}) {
        my %conf;
        for my $dir (@directives) {
            if (ref($dir->{key}) eq '') {
                # Only do this for normal scalar keys, not regexes, etc
                eval {
                    # If we get an error, still try to continue, but whine about it
                    _set(\%conf, $dir->{key}, config_get($dir->{key}));
                };
                if ($@) {
                    WARN $@;
                }
            }
        }
        # The above loop doesn't handle things like regex keys; merge in the
        # real config hash, so regex keys also get dumped.
        _merge(\%conf, \%CONF);
        # Get rid of "internal" config keys; they begin with "_"
        for my $key (keys %conf) {
            if ($key =~ m/^_/) {
                delete $conf{$key};
            }
        }

        $conf_ref = \%conf;
    } else {
        $conf_ref = \%CONF;
    }

    return JSON::PP->new->indent->space_after->encode($conf_ref);
}

# Parse a hash of (key, value) pairs, as received from the command-line. Some
# values need to be parsed as json (see the manpage for cellcc(1)); the rest
# are left alone.
sub
config_parse_override($) {
    my ($val) = @_;
    return JSON::PP->new->relaxed->allow_barekey->allow_nonref->decode($val);
}

1;
