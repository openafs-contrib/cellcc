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

package AFS::CellCC::Log;

use strict;
use warnings;

use Log::Log4perl;

use AFS::CellCC::Config;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(log_init);

# Initialize logging with our builtin default settings.
sub
_builtin_log() {
    my $config;
    my $appenders;
    my $level = uc(AFS::CellCC::Config::config_get('log/level'));

    if (AFS::CellCC::Config::config_get('_daemon')) {
        $appenders = "syslog";
        if ($level eq 'DEBUG') {
            $appenders .= ", screen";
        }
    } else {
        $appenders = "screen";
    }

#log4perl.appender.screen.layout.ConversionPattern = %d{MMM dd HH:mm:ss.SSS} %p: %m{chomp}%n
    $config = <<"EOS";
log4perl.rootLogger = $level, $appenders

log4perl.appender.screen        = Log::Log4perl::Appender::Screen
log4perl.appender.screen.layout = Log::Log4perl::Layout::PatternLayout
log4perl.appender.screen.layout.ConversionPattern = %p: %m{chomp}%n

log4perl.appender.syslog          = Log::Dispatch::Syslog
log4perl.appender.syslog.facility = daemon
log4perl.appender.syslog.logopt   = pid
log4perl.appender.syslog.layout   = Log::Log4perl::Layout::PatternLayout
log4perl.appender.syslog.layout.ConversionPattern = %c:%p: %m{chomp}%n
EOS

    Log::Log4perl->init(\$config);
}

# Initialize the logging subsystem.
sub
log_init() {
    my $config = AFS::CellCC::Config::config_get('log/config');
    if (AFS::CellCC::Config::config_get('_daemon') && defined($config)) {
        Log::Log4perl->init($config);
    } else {
        _builtin_log();
    }
}
