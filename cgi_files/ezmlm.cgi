#!/usr/bin/perl
use strict;
use warnings;

our $VERSION = "5.25";

use lib 'lib';
use Mail::Toaster;
use Mail::Toaster::Ezmlm; 

my $toaster = Mail::Toaster->new(debug=>0);
my $ezmlm = Mail::Toaster::Ezmlm->new( toaster => $toaster );

if ( $ENV{'GATEWAY_INTERFACE'} ) { $ezmlm->process_cgi(br=>"\n", debug=>0); } 
else                             { $ezmlm->process_shell()  };

exit 0;

=head1 NAME

ezmlm.cgi - batch administration tool for ezmlm lists (add lists of users, etc)


=head1 SYNOPSIS 

    ezmlm.cgi -a [ add | remove | list ] -d /path/to/ezmlm/list

      -a   action  - add, remove, list
      -d   dir     - ezmlm list directory
      -f   file    - file containing list of email addresses
      -v   verbose - print debugging options


=head1 DESCRIPTION


=head1 LICENSE

Copyright (c) 2004-2008, The Network People, Inc.  All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut

