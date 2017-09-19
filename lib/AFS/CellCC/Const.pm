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

package AFS::CellCC::Const;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw($PREFIX
                    $BINDIR
                    $LOCALSTATEDIR
                    $SYSCONFDIR
                    $VERSION
                    $VERSION_STRING
                    $CONF_DIR
                    $BLOB_DIR
);

our $VERSION = "1.014";
our $VERSION_STRING = "v$VERSION";
$VERSION_STRING =~ s/[.]0+/./g;
$VERSION_STRING =~ s/[.][.]/.0./g;
$VERSION_STRING =~ s/[.]$/.0/g;
# $VERSION_STRING .= "-customtag";

our $PREFIX = '@prefix@';
our $BINDIR = '@bindir@';
our $LOCALSTATEDIR = '@localstatedir@';
our $SYSCONFDIR = '@sysconfdir@';

our $CONF_DIR = "$SYSCONFDIR/cellcc";
our $BLOB_DIR = "$LOCALSTATEDIR/cellcc";
