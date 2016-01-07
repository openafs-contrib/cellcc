use strict;
use warnings;
use ExtUtils::MakeMaker;

my %opts = (
    NAME => 'AFS::CellCC',
    VERSION_FROM => 'lib/AFS/CellCC/Const.pm',
    EXE_FILES => [
        'bin/cellcc',
        'bin/ccc-debug',
    ],
    PREREQ_PM => {
        'DBIx::Simple' => 0,
        'DateTime::Format::MySQL' => 0,
        'Log::Log4perl' => 0,
        'Digest::MD5' => 0,
        'JSON::PP' => 0,
    },
    AUTHOR => 'Sine Nomine Associates <info@sinenomine.net>',
);

# All of this extra crud is so we can get these configurable constants stored
# in AFS::CellCC::Const (PREFIX, SYSCONFDIR, etc).
my %vars = (
    # Defaults here are relative to PREFIX
    SYSCONFDIR => {default => 'etc'},
    LOCALSTATEDIR => {default => 'var/lib'},

    # Use the makemaker INSTALLSCRIPT var be the same as our BINDIR var
    BINDIR => {alias => 'INSTALLSCRIPT'},
);

# Filter out our 'extra' variables from ARGV, so MakeMaker doesn't complain
# about them.
my @new_argv;
for my $arg (@ARGV) {
    if ($arg =~ m/^(.*)=(.*)$/) {
        my ($key, $val) = ($1, $2);
        if (exists $vars{$key}) {
            my $alias = $vars{$key}->{alias};
            if (defined($alias)) {
                push(@new_argv, "$alias=$val");
            } else {
                $vars{$key}->{value} = $val;
            }
        } else {
            push(@new_argv, $arg);
        }
    }
}
@ARGV = @new_argv;

# Add our 'extra' variables to the constants that are written to our makefile,
# so we can access them via PM_FILTER.
sub
MY::constants {
    package MY;
    my $self = shift;
    my $str = $self->SUPER::constants(@_)."\n";
    for my $key (keys %vars) {
        my $value = $vars{$key}->{value};
        if (!$value) {
            if (exists $vars{$key}->{default}) {
                $value .= $self->{PREFIX}."/".$vars{$key}->{default};
            } elsif (exists $vars{$key}->{alias}) {
                $value = $self->{$vars{$key}->{alias}};
            }
        }
        $str .= "$key = $value\n";
        print "$key = $value\n";
    }
    return $str;
}

# Filter out all occurrences of e.g. @sysconfdir@ with e.g. /etc
# This may not work on non-Unix, but we don't care, at least for now.
my @subs;
for my $var (keys %vars, 'PREFIX') {
    my $lcvar = lc $var;
    my $sub = "s|\\\@$lcvar\\\@|\$($var)|g;";
    push(@subs, $sub);
}
my $filter = "$^X -pe \"".join(' ', @subs)."\"";
$opts{PM_FILTER} = $filter;

WriteMakefile(%opts);
