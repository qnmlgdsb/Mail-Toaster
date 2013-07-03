package Mail::Toaster::Setup;

use strict;
use warnings;

use Carp;
use Config;
use Cwd;
use Data::Dumper;
use File::Copy;
use File::Path;
use English qw( -no_match_vars );
use Params::Validate qw( :all );
use Sys::Hostname;

use lib 'lib';
use parent 'Mail::Toaster::Base';

sub apache {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts, } );

    return $p{test_ok} if defined $p{test_ok};

    my $ver   = $self->conf->{install_apache} or do {
        $self->audit( "apache: installing, skipping (disabled)" );
        return;
    };

    require Cwd;
    my $old_directory = Cwd::cwd();

    if ( lc($ver) eq "apache1" or $ver == 1 ) {
        my $src = $self->conf->{'toaster_src_dir'} || "/usr/local/src";
        $self->apache->install_apache1( $src );
    }
    elsif ( lc($ver) eq "ssl" ) {
        $self->apache->install_ssl_certs( type=>'rsa' );
    }
    else {
        $self->apache->install_2;
    }

    chdir $old_directory if $old_directory;
    $self->apache->startup;
    return 1;
}

sub apache_conf_fixup {
# makes changes necessary for Apache to start while running in a jail

    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $httpdconf = $self->apache->conf_get_dir;

    unless ( -e $httpdconf ) {
        print "Could not find your httpd.conf file!  FAILED!\n";
        return 0;
    }

    return if hostname !~ /^jail/;    # we're running in a jail

    my @lines = $self->util->file_read( $httpdconf );
    foreach my $line (@lines) {
        if ( $line =~ /^Listen 80/ ) { # this is only tested on FreeBSD
            my @ips = $self->util->get_my_ips(only=>"first", verbose=>0);
            $line = "Listen $ips[0]:80";
        }
    }

    $self->util->file_write( "/var/tmp/httpd.conf", lines => \@lines );

    return unless $self->util->install_if_changed(
        newfile  => "/var/tmp/httpd.conf",
        existing => $httpdconf,
        clean    => 1,
        notify   => 1,
    );

    return 1;
}

sub autorespond {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_autorespond'} or do {
        $self->audit( "autorespond install skipped (disabled)" );
        return;
    };

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->freebsd->install_port( "autorespond" );
    }

    my $autorespond = $self->util->find_bin( "autorespond", fatal => 0, verbose => 0 );

    # return success if it is installed.
    if ( $autorespond &&  -x $autorespond ) {
        $self->audit( "autorespond: installed ok (exists)" );
        return 1;
    }

    if ( $ver eq "port" ) {
        print
"autorespond: port install failed, attempting to install from source.\n";
        $ver = "2.0.5";
    }

    my @targets = ( 'make', 'make install' );

    if ( $OSNAME eq "darwin" || $OSNAME eq "freebsd" ) {
        print "autorespond: applying strcasestr patch.\n";
        my $sed = $self->util->find_bin( "sed", verbose => 0 );
        my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local";
        $prefix =~ s/\//\\\//g;
        @targets = (
            "$sed -i '' 's/strcasestr/strcasestr2/g' autorespond.c",
            "$sed -i '' 's/PREFIX=\$(DESTDIR)\\/usr/PREFIX=\$(DESTDIR)$prefix/g' Makefile",
            'make', 'make install'
        );
    }

    $self->util->install_from_source(
        package        => "autorespond-$ver",
        site           => 'http://www.inter7.com',
        url            => '/devel',
        targets        => \@targets,
        bintest        => 'autorespond',
        source_sub_dir => 'mail',
    );

    if ( $self->util->find_bin( "autorespond", fatal => 0, verbose => 0, ) ) {
        $self->audit( "autorespond: installed ok" );
        return 1;
    }

    return 0;
}

sub clamav {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $prefix   = $self->conf->{'toaster_prefix'}      || "/usr/local";
    my $confdir  = $self->conf->{'system_config_dir'}   || "/usr/local/etc";
    my $share    = "$prefix/share/clamav";
    my $clamuser = $self->conf->{'install_clamav_user'} || "clamav";
    my $ver      = $self->conf->{'install_clamav'} or do {
        $self->audit( "clamav: installing, skipping (disabled)" );
        return;
    };

    my $installed;

    # install via ports if selected
    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->freebsd->install_port( "clamav", flags => "BATCH=yes WITHOUT_LDAP=1",);

        $self->clamav_update() or return;
        $self->clamav_perms () or return;
        $self->clamav_start () or return;
        return 1;
    }

    # add the clamav user and group
    unless ( getpwuid($clamuser) ) {
        $self->group_add( "clamav", "90" );
        $self->user_add( $clamuser, 90, 90 );
    }

    unless ( getpwnam($clamuser) ) {
        print "User clamav user installation FAILED, I cannot continue!\n";
        return 0;
    }

    # install via ports if selected
    if ( $OSNAME eq "darwin" && $ver eq "port" ) {
        if ( $self->darwin->install_port( "clamav" ) ) {
            $self->audit( "clamav: installing, ok" );
        }
        $self->clamav_update( ) or return;
        $self->clamav_perms ( ) or return;
        $self->clamav_start ( ) or return;
        return 1;
    }

    # port installs didn't work out, time to build from sources

    # set a default version of ClamAV if not provided
    if ( $ver eq "1" ) { $ver = "0.96.1"; }; # latest as of 6/2010

    # download the sources, build, and install ClamAV
    $self->util->install_from_source(
        package        => 'clamav-' . $ver,
        site           => 'http://' . $self->conf->{'toaster_sf_mirror'},
        url            => '/clamav',
        targets        => [ './configure', 'make', 'make install' ],
        bintest        => 'clamdscan',
        source_sub_dir => 'mail',
    );

    $self->util->find_bin( "clamdscan", fatal => 0 ) or
        return $self->error( "clamav: install FAILED" );

    $self->audit( "clamav: installed ok" );

    $self->clamav_update() or return;
    $self->clamav_perms () or return;
    $self->clamav_start () or return;
}

sub clamav_perms {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $prefix  = $self->conf->{'toaster_prefix'}      || "/usr/local";
    my $confdir = $self->conf->{'system_config_dir'}   || "/usr/local/etc";
    my $clamuid = $self->conf->{'install_clamav_user'} || "clamav";
    my $share   = "$prefix/share/clamav";

    foreach my $file ( $share, "$share/daily.cvd", "$share/main.cvd",
        "$share/viruses.db", "$share/viruses.db2", "/var/log/clamav/freshclam.log", ) {

        if ( -e $file ) {
            print "setting the ownership of $file to $clamuid.\n";
            $self->util->chown( $file, uid => $clamuid, gid => 'clamav' );
        };
    }

    $self->util->syscmd( "pw user mod clamav -G qmail" )
        or return $self->error( "failed to add clamav to the qmail group" );

    return 1;
}

sub clamav_start {
    # get ClamAV running
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    if ( $self->util->is_process_running('clamd') ) {
        $self->audit( "clamav: starting up, ok (already running)" );
    }

    print "Starting up ClamAV...\n";

    if ( $OSNAME ne "freebsd" ) {
        $self->util->_incomplete_feature( {
                mess   => "start up ClamAV on $OSNAME",
                action =>
'You will need to start up ClamAV yourself and make sure it is configured to launch at boot time.',
            }
        );
        return;
    };

    $self->freebsd->conf_check(
        check => "clamav_clamd_enable",
        line  => 'clamav_clamd_enable="YES"',
    );

    $self->freebsd->conf_check(
        check => "clamav_freshclam_enable",
        line  => 'clamav_freshclam_enable="YES"',
    );

    print "(Re)starting ClamAV's clamd...";
    my $start = "/usr/local/etc/rc.d/clamav-freshclam";
    $start = "$start.sh" if ! -x $start;

    if ( -x $start ) {
        system "$start restart";
        print "done.\n";
    }
    else {
        print
            "ERROR: I could not find the startup (rc.d) file for clamAV!\n";
    }

    print "(Re)starting ClamAV's freshclam...";
    $start = "/usr/local/etc/rc.d/clamav-clamd";
    $start = "$start.sh" if ! -x $start;
    system "$start restart";

    if ( $self->util->is_process_running('clamd', verbose=>0) ) {
        $self->audit( "clamav: starting up, ok" );
    }

    # These are no longer required as the FreeBSD ports now installs
    # startup files of its own.
    foreach ( qw/ clamav.sh freshclam.sh / ) {
        unlink "/usr/local/etc/rc.d/$_" if -e "/usr/local/etc/rc.d/$_";
    };

    return 1;
}

sub clamav_update {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    # set up freshclam (keeps virus databases updated)
    my $logfile = "/var/log/clamav/freshclam.log";
    unless ( -e $logfile ) {
        $self->util->syscmd( "touch $logfile", verbose=>0 );
        $self->util->chmod( file => $logfile, mode => '0644', verbose=>0 );
        $self->clamav_perms(  verbose=>0 );
    }

    my $freshclam = $self->util->find_bin( "freshclam", verbose=>0 )
        or return $self->error( "couldn't find freshclam!", fatal=>0);

    $self->util->syscmd( "$freshclam", verbose => 0, fatal => 0 );
    return 1;
}

sub config {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    # apply the platform specific changes to the config file
    $self->config_tweaks();

    my $file_name = "toaster-watcher.conf";
    my $file_path = $self->util->find_config( $file_name );
    $self->refresh_config( $file_path ) or return;

### start questions
    $self->config_hostname();
    $self->config_postmaster();
    $self->config_test_email();
    $self->config_test_email_pass();
    $self->config_vpopmail_mysql_pass();
    $self->config_openssl();
    $self->config_webmail_passwords();
### end questions
### don't forget to add changed fields to the list in save_changes

    $self->config_save_changes( $file_path );
    $self->config_install($file_name, $file_path );
};

sub config_apply_tweaks {
    my $self = shift;
    my %p = validate( @_,
        {   file    => { type => SCALAR },
            changes => { type => ARRAYREF },
            $self->get_std_opts
        },
    );

# changes is a list (array) of changes to apply to a text file
# each change is a hash with two elements: search, replace. the contents of
# file is searched for lines that matches search. Matches are replaced by the
# replace string. If search2 is also supplied and search does not match,
# search2 will be replaced.
# Ex:
# $changes = (
#    { search  => '#ssl_cert = /etc/ssl/certs/server.pem',
#      replace => 'ssl_cert = /etc/ssl/certs/server.pem',
#    },
# );
#
    # read in file
    my @lines = $self->util->file_read( $p{file} ) or return;

    my $total_found = 0;
    foreach my $e ( @{ $p{changes} } ) {
        my $search = $e->{search} or next;
        my $replace = $e->{replace} or next;
        my $search2 = $e->{search2};
        my $found = 0;

        if ( $search2 && $search2 eq 'section' ) {
# look for a multiline pattern such as: protocol manageseive {  ....  }
            my (@after, $in);
            foreach my $line ( @lines ) {
                if ( $in ) {
                    next if $line !~ /^ \s* \} \s* $/xms;
                    $in = 0;
                    next;
                }
                if ( $search eq $line ) {
                    $found++;
                    $in++;
                    next;
                };
                push @after, $line if ! $in;
            };
            @lines = @after;
        };
# search entire file for $search string
        for ( my $i = 0; $i < scalar @lines; $i++ ) {
            if ( $lines[$i] eq $search ) {
                $lines[$i] = $replace;
                $found++;
            };
        }
# search entire file for $search2 string
        if ( ! $found && $search2 ) {
            for ( my $i = 0; $i < scalar @lines; $i++ ) {
                if ( $lines[$i] eq $search2 ) {
                    $lines[$i] = $replace;
                    $found++;
                };
            }
        };
        $self->error( "attempt to replace\n$search\n\twith\n$replace\n\tfailed",
            fatal => 0) if ( ! $found && ! $e->{nowarn} );
        $total_found += $found;
    };

    $self->audit( "config_tweaks replaced $total_found lines",verbose=>$p{verbose} );

    $self->util->file_write( $p{file}, lines => \@lines );
};

sub config_hostname {
    my $self = shift;

    return if ( $self->conf->{'toaster_hostname'} && $self->conf->{'toaster_hostname'} ne "mail.example.com" );

    $self->conf->{'toaster_hostname'} = $self->util->ask(
        "the hostname of this mail server",
        default  => hostname,
    );
    chomp $self->conf->{'toaster_hostname'};

    $self->audit( "toaster hostname set to " . $self->conf->{'toaster_hostname'} );
};

sub config_install {
    my $self = shift;
    my ($file_name, $file_path) = @_;

    # install $file_path in $prefix/etc/toaster-watcher.conf if it doesn't exist
    # already
    my $config_dir = $self->conf->{'system_config_dir'} || '/usr/local/etc';

    # if $config_dir is missing, create it
    $self->util->mkdir_system( dir => $config_dir ) if ! -e $config_dir;

    my @configs = (
        { newfile  => $file_path, existing => "$config_dir/$file_name", mode => '0640', overwrite => 0 },
        { newfile  => $file_path, existing => "$config_dir/$file_name-dist", mode => '0640', overwrite => 1 },
        { newfile  => 'toaster.conf-dist', existing => "$config_dir/toaster.conf", mode => '0644', overwrite => 0 },
        { newfile  => 'toaster.conf-dist', existing => "$config_dir/toaster.conf-dist", mode => '0644', overwrite => 1 },
    );

    foreach ( @configs ) {
        next if -e $_->{existing} && ! $_->{overwrite};
        $self->util->install_if_changed(
            newfile  => $_->{newfile},
            existing => $_->{existing},
            mode     => $_->{mode},
            clean    => 0,
            notify   => 1,
            verbose  => 0,
        );
    };
}

sub config_openssl {
    my $self = shift;
    # OpenSSL certificate settings

    # country
    if ( $self->conf->{'ssl_country'} eq "SU" ) {
        print "             SSL certificate defaults\n";
        $self->conf->{'ssl_country'} =
          uc( $self->util->ask( "your 2 digit country code (US)", default  => "US" )
          );
    }
    $self->audit( "config: ssl_country, (" . $self->conf->{'ssl_country'} . ")" );

    # state
    if ( $self->conf->{'ssl_state'} eq "saxeT" ) {
        $self->conf->{'ssl_state'} =
          $self->util->ask( "the name (non abbreviated) of your state" );
    }
    $self->audit( "config: ssl_state, (" . $self->conf->{'ssl_state'} . ")" );

    # locality (city)
    if ( $self->conf->{'ssl_locality'} eq "dnalraG" ) {
        $self->conf->{'ssl_locality'} =
          $self->util->ask( "the name of your locality/city" );
    }
    $self->audit( "config: ssl_locality, (" . $self->conf->{'ssl_locality'} . ")" );

    # organization
    if ( $self->conf->{'ssl_organization'} eq "moc.elpmaxE" ) {
        $self->conf->{'ssl_organization'} = $self->util->ask( "the name of your organization" );
    }
    $self->audit( "config: ssl_organization, (" . $self->conf->{'ssl_organization'} . ")" );
};

sub config_postmaster {
    my $self = shift;

    return if ( $self->conf->{'toaster_admin_email'} && $self->conf->{'toaster_admin_email'} ne "postmaster\@example.com" );

    $self->conf->{'toaster_admin_email'} = $self->util->ask(
        "the email address for administrative emails and notices\n".
            " (probably yours!)",
        default => "postmaster",
    ) || 'root';

    $self->audit(
        "toaster admin emails sent to " . $self->conf->{'toaster_admin_email'} );
};

sub config_save_changes {
    my $self = shift;
    my ($file_path) = @_;

    my @fields = qw/ toaster_hostname toaster_admin_email toaster_test_email
        toaster_test_email_pass vpopmail_mysql_pass ssl_country ssl_state
        ssl_locality ssl_organization install_squirrelmail_sql_pass
        install_roundcube_db_pass install_spamassassin_dbpass
        phpMyAdmin_controlpassword
        /;
    push @fields, 'vpopmail_mysql_pass' if $self->conf->{'vpopmail_mysql'};

    my @lines = $self->util->file_read( $file_path, verbose => 0 );
    foreach my $key ( @fields ) {
        foreach my $line (@lines) {
            if ( $line =~ /^$key\s*=/ ) {
# format the config entries to match config file format
                $line = sprintf( '%-34s = %s', $key, $self->conf->{$key} );
            }
        };
    };

    $self->util->file_write( "/tmp/toaster-watcher.conf", lines => \@lines );

    my $r = $self->util->install_if_changed(
            newfile  => "/tmp/toaster-watcher.conf",
            existing => $file_path,
            mode     => '0640',
            clean    => 1,
            notify   => -e $file_path ? 1 : 0,
    )
    or return $self->error( "installing /tmp/toaster-watcher.conf to $file_path failed!" );

    my $status = $r == 1 ? "ok" : "ok (current)";
    $self->audit( "config: updating $file_path, $status" );
    return $r;
};

sub config_test_email {
    my $self = shift;

    return if $self->conf->{'toaster_test_email'} ne "test\@example.com";

    $self->conf->{'toaster_test_email'} = $self->util->ask(
        "an email account for running tests",
        default  => "postmaster\@" . $self->conf->{'toaster_hostname'}
    );

    $self->audit( "toaster test account set to ".$self->conf->{'toaster_test_email'} );
};

sub config_test_email_pass {
    my $self = shift;

    return if ( $self->conf->{'toaster_test_email_pass'} && $self->conf->{'toaster_test_email_pass'} ne "cHanGeMe" );

    $self->conf->{'toaster_test_email_pass'} = $self->util->ask( "the test email account password" );

    $self->audit(
        "toaster test password set to ".$self->conf->{'toaster_test_email_pass'} );
};

sub config_tweaks {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $status = "ok";

    my $file = $self->util->find_config( 'toaster-watcher.conf' );

    # verify that find_config worked and $file is readable
    return $self->error( "config_tweaks: read test on $file, FAILED",
        fatal => $p{fatal} ) if ! -r $file;

    my %changes;
    %changes = $self->config_tweaks_freebsd() if $OSNAME eq 'freebsd';
    %changes = $self->config_tweaks_darwin()  if $OSNAME eq 'darwin';
    %changes = $self->config_tweaks_linux()   if $OSNAME eq 'linux';

    %changes = $self->config_tweaks_testing(%changes);
    %changes = $self->config_tweaks_mysql(%changes);

    # foreach key of %changes, apply to $conf
    my @lines = $self->util->file_read( $file );
    foreach my $line (@lines) {
        next if $line =~ /^#/;  # comment lines
        next if $line !~ /=/;   # not a key = value

        my ( $key, $val ) = $self->util->parse_line( $line, strip => 0 );

        if ( defined $changes{$key} && $changes{$key} ne $val ) {
            $status = "changed";
            #print "\t setting $key to ". $changes{$key} . "\n";
            $line = sprintf( '%-34s = %s', $key, $changes{$key} );
            print "\t$line\n";
        }
    }
    return 1 unless ( $status && $status eq "changed" );

    # ask the user for permission to install
    return 1
      if ! $self->util->yes_or_no(
'config_tweaks: The changes shown above are recommended for use on your system.
May I apply the changes for you?',
        timeout => 30,
      );

    # write $conf to temp file
    $self->util->file_write( "/tmp/toaster-watcher.conf", lines => \@lines );

    # if the file ends with -dist, then save it back with out the -dist suffix
    # the find_config sub will automatically prefer the newer non-suffixed one
    if ( $file =~ m/(.*)-dist\z/ ) {
        $file = $1;
    };

    # update the file if there are changes
    my $r = $self->util->install_if_changed(
        newfile  => "/tmp/toaster-watcher.conf",
        existing => $file,
        clean    => 1,
        notify   => 0,
        verbose    => 0,
    );

    return 0 unless $r;
    $r == 1 ? $r = "ok" : $r = "ok (current)";
    $self->audit( "config_tweaks: updated $file, $r" );
}

sub config_tweaks_darwin {
    my $self = shift;

    $self->audit( "config_tweaks: applying Darwin tweaks" );

    return (
        toaster_http_base    => '/Library/WebServer',
        toaster_http_docs    => '/Library/WebServer/Documents',
        toaster_cgi_bin      => '/Library/WebServer/CGI-Executables',
        toaster_prefix       => '/opt/local',
        toaster_src_dir      => '/opt/local/src',
        system_config_dir    => '/opt/local/etc',
        vpopmail_valias      => '0',
        install_mysql        => '0      # 0, 1, 2, 3, 40, 41, 5',
        install_portupgrade  => '0',
        filtering_maildrop_filter_file => '/opt/local/etc/mail/mailfilter',
        qmail_mysql_include  => '/opt/local/lib/mysql/libmysqlclient.a',
        vpopmail_home_dir    => '/opt/local/vpopmail',
        vpopmail_mysql       => '0',
        smtpd_use_mysql_relay_table => '0',
        qmailadmin_spam_command => '| /opt/local/bin/maildrop /opt/local/etc/mail/mailfilter',
        qmailadmin_http_images  => '/Library/WebServer/Documents/images',
        apache_suexec_docroot   => '/Library/WebServer/Documents',
        apache_suexec_safepath  => '/opt/local/bin:/usr/bin:/bin',
    );
};

sub config_tweaks_freebsd {
    my $self = shift;
    $self->audit( "config_tweaks: applying FreeBSD tweaks" );

    return (
        install_squirrelmail => 'port    # 0, ver, port',
        install_autorespond  => 'port    # 0, ver, port',
        install_ezmlm        => 'port    # 0, ver, port',
        install_courier_imap => '0       # 0, ver, port',
        install_dovecot      => 'port    # 0, ver, port',
        install_clamav       => 'port    # 0, ver, port',
        install_ripmime      => 'port    # 0, ver, port',
        install_cronolog     => 'port    # ver, port',
        install_daemontools  => 'port    # ver, port',
        install_qmailadmin   => 'port    # 0, ver, port',
        install_djbdns       => 'port    # ver, port',
    )
}

sub config_tweaks_linux {
    my $self = shift;
    $self->audit( "config_tweaks: applying Linux tweaks " );

    return (
        toaster_http_base           => '/var/www',
        toaster_http_docs           => '/var/www',
        toaster_cgi_bin             => '/usr/lib/cgi-bin',
        vpopmail_valias             => '0',
        install_mysql               => '0      # 0, 1, 2, 3, 40, 41, 5',
        vpopmail_mysql              => '0',
        smtpd_use_mysql_relay_table => '0',
        qmailadmin_http_images      => '/var/www/images',
        apache_suexec_docroot       => '/var/www',
        apache_suexec_safepath      => '/usr/local/bin:/usr/bin:/bin',
        install_dovecot             => '1.0.2',
    )
}

sub config_tweaks_mysql {
    my ($self, %changes) = @_;

    return %changes if $self->conf->{install_mysql};
    return %changes if ! $self->util->yes_or_no("Enable MySQL support?");

    $self->audit( "config_tweaks: applying MT testing tweaks" );

    $changes{'install_mysql'}   = '55      # 0, 1, 2, 3, 40, 41, 5, 55';
    $changes{'install_mysqld'}  = '1       # 0, 1';
    $changes{'vpopmail_mysql'}  = '1         # disables all mysql options';
    $changes{'smtpd_use_mysql_relay_table'} = 1;
    $changes{'install_squirrelmail_sql'}    = 1;
    $changes{'install_spamassassin_sql'}    = 1;

    return %changes;
};

sub config_tweaks_testing {
    my ($self, %changes) = @_;

    my $hostname = hostname;
    return %changes if ( ! $hostname || $hostname ne 'jail.simerson.net' );

    $self->audit( "config_tweaks: applying MT testing tweaks" );

    $changes{'toaster_hostname'}      = 'jail.simerson.net';
    $changes{'toaster_admin_email'}   = 'postmaster@jail.simerson.net';
    $changes{'toaster_test_email'}    = 'test@jail.simerson.net';
    $changes{'toaster_test_email_pass'}   = 'sdfsdf';
    $changes{'install_squirrelmail_sql'}  = '1';
    $changes{'install_phpmyadmin'}        = '1';
    $changes{'install_sqwebmail'}         = 'port';
    $changes{'install_vqadmin'}           = 'port';
    $changes{'install_openldap_client'}   = '1';
    $changes{'install_ezmlm_cgi'}         = '1';
    $changes{'install_dspam'}             = '1';
    $changes{'install_pyzor'}             = '1';
    $changes{'install_bogofilter'}        = '1';
    $changes{'install_dcc'}               = '1';
    $changes{'install_lighttpd'}          = '1';
    $changes{'install_apache'}            = '22';
    $changes{'install_courier_imap'}      = 'port';
    $changes{'install_gnupg'}             = 'port';
    $changes{'vpopmail_default_domain'}   = 'jail.simerson.net';
    $changes{'pop3_ssl_daemon'}           = 'qpop3d';
    $changes{'install_spamassassin_flags'}= '-v -u spamd -q -A 10.0.1.67 -H /var/spool/spamd -x';
    $changes{'install_isoqlog'}           = 'port    # 0, ver, port';

    return %changes;
}

sub config_vpopmail_mysql_pass {
    my $self = shift;

    return if ! $self->conf->{'vpopmail_mysql'};
    return if ( $self->conf->{'vpopmail_mysql_pass'}
        && $self->conf->{'vpopmail_mysql_pass'} ne "supersecretword" );

    $self->conf->{'vpopmail_mysql_pass'} =
        $self->util->ask( "the password for securing vpopmails "
            . "database connection. You MUST enter a password here!",
        );

    $self->audit( "vpopmail MySQL password set to ".$self->conf->{'vpopmail_mysql_pass'});
}

sub config_webmail_passwords {
    my $self = shift;

    if ( $self->conf->{install_squirrelmail} &&
         $self->conf->{install_squirrelmail_sql} &&
         $self->conf->{install_squirrelmail_sql_pass} eq 'chAnge7his' ) {
         $self->conf->{install_squirrelmail_sql_pass} =
            $self->util->ask("squirrelmail database password");
    };

    if ( $self->conf->{install_roundcube} &&
         $self->conf->{install_roundcube_db_pass} eq 'To4st3dR0ndc@be' ) {
         $self->conf->{install_roundcube_db_pass} =
            $self->util->ask("roundcube database password");
    };

    if ( $self->conf->{install_spamassassin} &&
         $self->conf->{install_spamassassin_sql} &&
         $self->conf->{install_spamassassin_dbpass} eq 'assSPAMing' ) {
         $self->conf->{install_spamassassin_dbpass} =
            $self->util->ask("spamassassin database password");
    };

    if ( $self->conf->{install_phpmyadmin} &&
         $self->conf->{phpMyAdmin_controlpassword} eq 'pmapass') {
         $self->conf->{phpMyAdmin_controlpassword} =
            $self->util->ask("phpMyAdmin control password");
    };

    return 1;
};

sub courier_imap {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $ver = $self->conf->{'install_courier_imap'} or do {
        $self->audit( "courier: installing, skipping (disabled)" );
        $self->courier_startup_freebsd() if $OSNAME eq 'freebsd'; # enable startup
        return;
    };

    $self->audit("courier $ver is selected" );

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->audit("using courier from FreeBSD ports" );
        $self->courier_authlib();
        $self->courier_imap_freebsd();
        $self->courier_startup();
        return 1 if $self->freebsd->is_port_installed( "courier-imap", verbose=>0);
    }
    elsif ( $OSNAME eq "darwin" ) {
        return $self->darwin->install_port( "courier-imap", );
    }

    # if a specific version has been requested, install it from sources
    # but first, a default for users who didn't edit toaster-watcher.conf
    $ver = "4.8.0" if ( $ver eq "port" );

    my $site    = "http://" . $self->conf->{'toaster_sf_mirror'};
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";
    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";

    $ENV{"HAVE_OPEN_SMTP_RELAY"} = 1;    # circumvent bug in courier

    my $conf_args = "--prefix=$prefix --exec-prefix=$prefix --without-authldap --without-authshadow --with-authvchkpw --sysconfdir=/usr/local/etc/courier-imap --datadir=$prefix/share/courier-imap --libexecdir=$prefix/libexec/courier-imap --enable-workarounds-for-imap-client-bugs --disable-root-check --without-authdaemon";

    print "./configure $conf_args\n";
    my $make = $self->util->find_bin( "gmake", verbose=>0, fatal=>0 ) ||
        $self->util->find_bin( "make", verbose=>0);
    my @targets = ( "./configure " . $conf_args, $make, "$make install" );

    $self->util->install_from_source(
        package        => "courier-imap-$ver",
        site           => $site,
        url            => "/courier",
        targets        => \@targets,
        bintest        => "imapd",
        source_sub_dir => 'mail',
    );

    $self->courier_startup();
}

sub courier_imap_freebsd {
    my $self = shift;

#   my @defs = "WITH_VPOPMAIL=1";
#   push @defs, "WITHOUT_AUTHDAEMON=1";
#   push @defs, "WITH_CRAM=1";
#   push @defs, "AUTHMOD=authvchkpw";

    $self->freebsd->install_port( "courier-imap",
        #flags  => join( ",", @defs ),
        options => "#\n# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for courier-imap-4.1.1,1
_OPTIONS_READ=courier-imap-4.1.1,1
WITH_OPENSSL=true
WITHOUT_FAM=true
WITHOUT_DRAC=true
WITHOUT_TRASHQUOTA=true
WITHOUT_GDBM=true
WITHOUT_IPV6=true
WITHOUT_AUTH_LDAP=true
WITHOUT_AUTH_MYSQL=true
WITHOUT_AUTH_PGSQL=true
WITHOUT_AUTH_USERDB=true
WITH_AUTH_VCHKPW=true",
    );
}

sub courier_authlib {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $prefix  = $self->conf->{'toaster_prefix'}    || "/usr/local";
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";

    if ( $OSNAME ne "freebsd" ) {
        print "courier-authlib build support is not available for $OSNAME yet.\n";
        return 0;
    };

    if ( ! $self->freebsd->is_port_installed( "courier-authlib" ) ) {

        unlink "/var/db/ports/courier-authlib/options"
            if -f "/var/db/ports/courier-authlib/options";

        if ( -d "/usr/ports/security/courier-authlib" ) {

            $self->freebsd->install_port( "courier-authlib",
                options => "
# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for courier-authlib-0.58_2
_OPTIONS_READ=courier-authlib-0.58_2
WITHOUT_GDBM=true
WITHOUT_AUTH_LDAP=true
WITHOUT_AUTH_MYSQL=true
WITHOUT_AUTH_PGSQL=true
WITHOUT_AUTH_USERDB=true
WITH_AUTH_VCHKPW=true",
            );
        }

        if ( -d "/usr/ports/mail/courier-authlib-vchkpw" ) {
            $self->freebsd->install_port( "courier-authlib-vchkpw",
                flags => "AUTHMOD=authvchkpw",
            );
        }
    }

    # install a default authdaemonrc
    my $authrc = "$confdir/authlib/authdaemonrc";

    if ( ! -e $authrc ) {
        if ( -e "$authrc.dist" ) {
            print "installing default authdaemonrc.\n";
            copy("$authrc.dist", $authrc);
        }
    };

    if ( `grep 'authmodulelist=' $authrc | grep ldap` ) {
        $self->config_apply_tweaks(
            file => $authrc,
            changes => [
                {   search  => q{authmodulelist="authuserdb authvchkpw authpam authldap authmysql authpgsql"},
                    replace => q{authmodulelist="authvchkpw"},
                },
            ],
        );
        $self->audit( "courier_authlib: fixed up $authrc" );
    }

    $self->freebsd->conf_check(
        check => "courier_authdaemond_enable",
        line  => "courier_authdaemond_enable=\"YES\"",
    );

    if ( ! -e "/var/run/authdaemond/pid" ) {
        my $start = "$prefix/etc/rc.d/courier-authdaemond";
        foreach ( $start, "$start.sh" ) {
            $self->util->syscmd( "$_ start", verbose=>0) if -x $_;
        };
    };
    return 1;
}

sub courier_ssl {
    my $self = shift;

    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";
    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $share   = "$prefix/share/courier-imap";

    # apply ssl_ values from t-w.conf to courier's .cnf files
    if ( ! -e "$share/pop3d.pem" || ! -e "$share/imapd.pem" ) {
        my $pop3d_ssl_conf = "$confdir/courier-imap/pop3d.cnf";
        my $imapd_ssl_conf = "$confdir/courier-imap/imapd.cnf";

        my $common_name = $self->conf->{'ssl_common_name'} || $self->conf->{'toaster_hostname'};
        my $org      = $self->conf->{'ssl_organization'};
        my $locality = $self->conf->{'ssl_locality'};
        my $state    = $self->conf->{'ssl_state'};
        my $country  = $self->conf->{'ssl_country'};

        my $sed_command = "sed -i .bak -e 's/US/$country/' ";
        $sed_command .= "-e 's/NY/$state/' ";
        $sed_command .= "-e 's/New York/$locality/' ";
        $sed_command .= "-e 's/Courier Mail Server/$org/' ";
        $sed_command .= "-e 's/localhost/$common_name/' ";

        print "$sed_command\n";
        system "$sed_command $pop3d_ssl_conf $imapd_ssl_conf";
    };

    # use the toaster generated cert, if available
    my $crt = "/usr/local/openssl/certs/server.pem";
    foreach my $courier_pem ( "$share/pop3d.pem", "$share/imapd.pem" ) {
        copy( $crt, $courier_pem ) if ( -f $crt && ! -e $courier_pem );
    };

    # generate self-signed SSL certificates for pop3/imap
    if ( ! -e "$share/pop3d.pem" ) {
        chdir $share;
        $self->util->syscmd( "./mkpop3dcert", verbose => 0 );
    }

    if ( !-e "$share/imapd.pem" ) {
        chdir $share;
        $self->util->syscmd( "./mkimapdcert", verbose => 0 );
    }
};

sub courier_startup {

    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $ver     = $self->conf->{'install_courier_imap'};
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";

    chdir("$confdir/courier-imap") or
        return $self->error( "could not chdir $confdir/courier-imap.");

    copy( "pop3d.cnf.dist",       "pop3d.cnf" )    if ( !-e "pop3d.cnf" );
    copy( "pop3d.dist",           "pop3d" )        if ( !-e "pop3d" );
    copy( "pop3d-ssl.dist",       "pop3d-ssl" )    if ( !-e "pop3d-ssl" );
    copy( "imapd.cnf.dist",       "imapd.cnf" )    if ( !-e "imapd.cnf" );
    copy( "imapd.dist",           "imapd" )        if ( !-e "imapd" );
    copy( "imapd-ssl.dist",       "imapd-ssl" )    if ( !-e "imapd-ssl" );
    copy( "quotawarnmsg.example", "quotawarnmsg" ) if ( !-e "quotawarnmsg" );

    $self->courier_ssl();

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->courier_startup_freebsd();
    }
    else {
        my $libe = "$prefix/libexec/courier-imap";
        if ( -e "$libe/imapd.rc" ) {
            print "creating symlinks in /usr/local/sbin for courier daemons\n";
            symlink( "$libe/imapd.rc",     "$prefix/sbin/imap" );
            symlink( "$libe/pop3d.rc",     "$prefix/sbin/pop3" );
            symlink( "$libe/imapd-ssl.rc", "$prefix/sbin/imapssl" );
            symlink( "$libe/pop3d-ssl.rc", "$prefix/sbin/pop3ssl" );
        }
        else {
            print
              "FAILURE: sorry, I can't find the courier rc files on $OSNAME.\n";
        }
    }

    $self->courier_authlib();

    unless ( -e "/var/run/imapd-ssl.pid" ) {
        $self->util->syscmd( "$prefix/sbin/imapssl start", verbose=>0 )
          if -x "$prefix/sbin/imapssl";
    }

    unless ( -e "/var/run/imapd.pid" ) {
        $self->util->syscmd( "$prefix/sbin/imap start", verbose=>0 )
          if -x "$prefix/sbin/imapssl";
    }

    unless ( -e "/var/run/pop3d-ssl.pid" ) {
        $self->util->syscmd( "$prefix/sbin/pop3ssl start", verbose=>0 )
          if -x "$prefix/sbin/pop3ssl";
    }

    if ( $self->conf->{'pop3_daemon'} eq "courier" ) {
        if ( !-e "/var/run/pop3d.pid" ) {
            $self->util->syscmd( "$prefix/sbin/pop3 start", verbose=>0 )
              if -x "$prefix/sbin/pop3";
        }
    }
}

sub courier_startup_freebsd {
    my $self = shift;

    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";

    # cleanup stale links, created long ago when rc.d files had .sh endings
    foreach ( qw/ imap imapssl pop3 pop3ssl / ) {
        if ( -e "$prefix/sbin/$_" ) {
            readlink "$prefix/sbin/$_" or unlink "$prefix/sbin/$_";
        };
    };

    if ( ! -e "$prefix/sbin/imap" ) {
        $self->audit( "setting up startup file shortcuts for daemons");
        symlink( "$confdir/rc.d/courier-imap-imapd", "$prefix/sbin/imap" );
        symlink( "$confdir/rc.d/courier-imap-pop3d", "$prefix/sbin/pop3" );
        symlink( "$confdir/rc.d/courier-imap-imapd-ssl", "$prefix/sbin/imapssl" );
        symlink( "$confdir/rc.d/courier-imap-pop3d-ssl", "$prefix/sbin/pop3ssl" );
    }

    my $start = $self->conf->{install_courier_imap} ? 'YES' : 'NO';

    $self->freebsd->conf_check(
        check => "courier_imap_imapd_enable",
        line  => "courier_imap_imapd_enable=\"$start\"",
    );

    $self->freebsd->conf_check(
        check => "courier_imap_imapdssl_enable",
        line  => "courier_imap_imapdssl_enable=\"$start\"",
    );

    $self->freebsd->conf_check(
        check => "courier_imap_imapd_ssl_enable",
        line  => "courier_imap_imapd_ssl_enable=\"$start\"",
    );

    $self->freebsd->conf_check(
        check => "courier_imap_pop3dssl_enable",
        line  => "courier_imap_pop3dssl_enable=\"$start\"",
    );

    $self->freebsd->conf_check(
        check => "courier_imap_pop3d_ssl_enable",
        line  => "courier_imap_pop3d_ssl_enable=\"$start\"",
    );

    if ( $self->conf->{'pop3_daemon'} eq "courier" ) {
        $self->freebsd->conf_check(
            check => "courier_imap_pop3d_enable",
            line  => "courier_imap_pop3d_enable=\"$start\"",
        );
    }
};

sub cronolog {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_cronolog'} or do {
        $self->audit( "cronolog: skipping install (disabled)");
        return;
    };

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        return $self->cronolog_freebsd();
    }

    if ( $self->util->find_bin( "cronolog", fatal => 0 ) ) {
        $self->audit( "cronolog: install cronolog, ok (exists)",verbose=>1 );
        return 2;
    }

    $self->audit( "attempting cronolog install from source");

    if ( $ver eq "port" ) { $ver = "1.6.2" };  # a fallback version

    $self->util->install_from_source(
        package => "cronolog-$ver",
        site    => 'http://www.cronolog.org',
        url     => '/download',
        targets => [ './configure', 'make', 'make install' ],
        bintest => 'cronolog',
    );

    $self->util->find_bin( "cronolog" ) or return;

    $self->audit( "cronolog: install cronolog, ok" );
    return 1;
}

sub cronolog_freebsd {
    my $self = shift;
    return $self->freebsd->install_port( "cronolog",
        fatal => 0,
        options => "#\n
# This file is generated by mail-toaster
# No user-servicable parts inside!
# Options for cronolog-1.6.2_1
_OPTIONS_READ=cronolog-1.6.2_1
WITHOUT_SETUID_PATCH=true",
    );
};

sub daemontools {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $ver = $self->conf->{'install_daemontools'} or do {
        $self->audit( "daemontools: installing, (disabled)" );
        return;
    };

    $self->daemontools_freebsd() if $OSNAME eq "freebsd";

    if ( $OSNAME eq "darwin" && $ver eq "port" ) {
        $self->darwin->install_port( "daemontools" );

        print
"\a\n\nWARNING: there is a bug in the OS 10.4 kernel that requires daemontools to be built with a special tweak. This must be done once. You will be prompted to install daemontools now. If you haven't already allowed this script to build daemontools from source, please do so now!\n\n";
        sleep 2;
    }

    # see if the svscan binary is already installed
    $self->util->find_bin( "svscan", fatal => 0, verbose => 0 ) and do {
        $self->audit( "daemontools: installing, ok (exists)" );
        return 1;
    };

    $self->daemontools_src();
};

sub daemontools_src {
    my $self = shift;

    my $ver = $self->conf->{'install_daemontools'};
    $ver = "0.76" if $ver eq "port";

    my $package = "daemontools-$ver";
    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";

    my @targets = ('package/install');
    my @patches;
    my $patch_args = "";    # cannot be undef

    if ( $OSNAME eq "darwin" ) {
        print "daemontools: applying fixups for Darwin.\n";
        @targets = (
            "echo cc -Wl,-x > src/conf-ld",
            "echo $prefix/bin > src/home",
            "echo x >> src/trypoll.c",
            "cd src",
            "make",
        );
    }
    elsif ( $OSNAME eq "linux" ) {
        print "daemontools: applying fixups for Linux.\n";
        @patches    = ('daemontools-0.76.errno.patch');
        $patch_args = "-p0";
    }
    elsif ( $OSNAME eq "freebsd" ) {
        @targets = (
            'echo "' . $self->conf->{'toaster_prefix'} . '" > src/home',
            "cd src", "make",
        );
    }

    $self->util->install_from_source(
        package    => $package,
        site       => 'http://cr.yp.to',
        url        => '/daemontools',
        targets    => \@targets,
        patches    => \@patches,
        patch_args => $patch_args,
        patch_url  => "$self->conf->{'toaster_dl_site'}$self->conf->{'toaster_dl_url'}/patches",
        bintest    => 'svscan',
    );

    if ( $OSNAME =~ /darwin|freebsd/i ) {

        # manually install the daemontools binaries in $prefix/local/bin
        chdir "$self->conf->{'toaster_src_dir'}/admin/$package";

        foreach ( $self->util->file_read( "package/commands" ) ) {
            my $install = $self->util->find_bin( 'install' );
            $self->util->syscmd( "$install src/$_ $prefix/bin", verbose=>0 );
        }
    }

    return 1;
}

sub daemontools_freebsd {
    my $self = shift;
    return $self->freebsd->install_port( "daemontools",
        options => '# This file is generated by Mail Toaster
# Options for daemontools-0.76_15
_OPTIONS_READ=daemontools-0.76_15
WITH_MAN=true
WITHOUT_S_EARLY=true
WITH_S_NORMAL=true
WITHOUT_SIGQ12=true
WITH_TESTS=true',
        fatal => 0,
    );
};

sub daemontools_test {
    my $self = shift;

    print "checking daemontools binaries...\n";
    my @bins = qw{ multilog softlimit setuidgid supervise svok svscan tai64nlocal };
    foreach my $test ( @bins ) {
        my $bin = $self->util->find_bin( $test, fatal => 0, verbose=>0);
        $self->toaster->test("  $test", -x $bin );
    };

    return 1;
}

sub dependencies {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $qmaildir = $self->conf->{'qmail_dir'} || "/var/qmail";

    if ( $OSNAME eq "freebsd" ) {
        $self->dependencies_freebsd();
        $self->freebsd->install_port( "p5-Net-DNS",
            options => "#\n# This file was generated by mail-toaster
# Options for p5-Net-DNS-0.58\n_OPTIONS_READ=p5-Net-DNS-0.58\nWITHOUT_IPV6=true",
        );
    }
    elsif ( $OSNAME eq "darwin" ) {
        my @dports =
          qw/ cronolog gdbm gmake ucspi-tcp daemontools DarwinPortsStartup /;

        push @dports, qw/aspell aspell-dict-en/ if $self->conf->{'install_aspell'};
        push @dports, "ispell"   if $self->conf->{'install_ispell'};
        push @dports, "maildrop" if $self->conf->{'install_maildrop'};
        push @dports, "openldap" if $self->conf->{'install_openldap_client'};
        push @dports, "gnupg"    if $self->conf->{'install_gnupg'};

        foreach (@dports) { $self->darwin->install_port( $_ ) }
    }
    else {
        $self->dependencies_other();
    };

    $self->util->install_module( "Params::Validate" );
    $self->util->install_module( "IO::Compress" );
    $self->util->install_module( "Compress::Raw::Zlib" );
    $self->util->install_module( "Crypt::PasswdMD5" );
    $self->util->install_module( "Net::DNS" );
    $self->util->install_module( "Quota", fatal => 0 ) if $self->conf->{'install_quota_tools'};
    $self->util->install_module( "Date::Format", port => "p5-TimeDate");
    $self->util->install_module( "Date::Parse" );
    $self->util->install_module( "Mail::Send",  port => "p5-Mail-Tools");

    if ( ! -x "$qmaildir/bin/qmail-queue" ) {
        $self->conf->{'qmail_chk_usr_patch'} = 0;
        $self->qmail->netqmail_virgin();
    }

    $self->daemontools();
    $self->autorespond();
}

sub dependencies_freebsd {
    my $self = shift;
    my $package = $self->conf->{'package_install_method'} || "packages";

    $self->periodic_conf();    # create /etc/periodic.conf
    $self->gmake_freebsd();
    $self->openssl_install();
    $self->stunnel() if $self->conf->{'pop3_ssl_daemon'} eq "qpop3d";
    $self->ucspi_tcp_freebsd();
    $self->cronolog_freebsd();

    my @to_install = { port => "p5-Params-Validate"  };

    push @to_install, { port => "setquota" }  if $self->conf->{'install_quota_tools'};
    push @to_install, { port => "portaudit" } if $self->conf->{'install_portaudit'};
    push @to_install, { port => "ispell", category => 'textproc' }
        if $self->conf->{'install_ispell'};
    push @to_install, { port => 'gdbm'  };
    push @to_install, { port  => 'openldap23-client',
        check    => "openldap-client",
        category => 'net',
        } if $self->conf->{'install_openldap_client'};
    push @to_install, { port  => "qmail",
        flags   => "BATCH=yes",
        options => "#\n# Installed by Mail::Toaster
# Options for qmail-1.03_7\n_OPTIONS_READ=qmail-1.03_7",
    };
    push @to_install, { port => "qmailanalog", fatal => 0 };
    push @to_install, { port => "qmail-notify", fatal => 0 }
        if $self->conf->{'install_qmail_notify'};

    # if package method is selected, try it
    if ( $package eq "packages" ) {
        foreach ( @to_install ) {
            my $port = $_->{port} || $_->{name};
            $self->freebsd->install_package( $port, fatal => 0 );
        };
    }

    foreach my $port (@to_install) {

        $self->freebsd->install_port( $port->{'port'},
            flags   => defined $port->{'flags'}  ? $port->{'flags'} : q{},
            options => defined $port->{'options'}? $port->{'options'}: q{},
            check   => defined $port->{'check'}  ? $port->{'check'}  : q{},
            fatal   => defined $port->{'fatal'}  ? $port->{'fatal'} : 1,
            category=> defined $port->{category} ? $port->{category} : '',
        );
    }
};

sub dependencies_other {
    my $self = shift;
    print "no ports for $OSNAME, installing from sources.\n";

    if ( $OSNAME eq "linux" ) {
        my $vpopdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
        $self->qmail->install_qmail_groups_users();

        $self->util->syscmd( "groupadd -g 89 vchkpw" );
        $self->util->syscmd( "useradd -g vchkpw -d $vpopdir vpopmail" );
        $self->util->syscmd( "groupadd clamav" );
        $self->util->syscmd( "useradd -g clamav clamav" );
    }

    my @progs = qw(gmake expect cronolog autorespond );
    push @progs, "setquota" if $self->conf->{'install_quota_tools'};
    push @progs, "ispell" if $self->conf->{'install_ispell'};
    push @progs, "gnupg" if $self->conf->{'install_gnupg'};

    foreach (@progs) {
        if ( $self->util->find_bin( $_, verbose=>0,fatal=>0 ) ) {
            $self->audit( "checking for $_, ok" );
        }
        else {
            print "$_ not installed. FAILED, please install manually.\n";
        }
    }
}

sub djbdns {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{'install_djbdns'} ) {
        $self->audit( "djbdns: installing, skipping (disabled)" );
        return;
    };

    $self->daemontools();
    $self->ucspi_tcp();

    return $self->audit( "djbdns: installing djbdns, ok (already installed)" )
        if $self->util->find_bin( 'tinydns', fatal => 0 );

    if ( $OSNAME eq "freebsd" ) {
        $self->djbdns_freebsd();

        return $self->audit( "djbdns: installing djbdns, ok" )
            if $self->util->find_bin( 'tinydns', fatal => 0 );
    }

    return $self->djbdns_src();
};

sub djbdns_src {
    my $self = shift;

    my @targets = ( 'make', 'make setup check' );

    if ( $OSNAME eq "linux" ) {
        unshift @targets,
          'echo gcc -O2 -include /usr/include/errno.h > conf-cc';
    }

    $self->util->install_from_source(
        package => "djbdns-1.05",
        site    => 'http://cr.yp.to',
        url     => '/djbdns',
        targets => \@targets,
        bintest => 'tinydns',
    );
}

sub djbdns_freebsd {
    my $self = shift;
    $self->freebsd->install_port( "djbdns",
        options => "#\n
# Options for djbdns-1.05_13
_OPTIONS_READ=djbdns-1.05_13
WITHOUT_DUMPCACHE=true
WITHOUT_IPV6=true
WITHOUT_IGNOREIP=true
WITHOUT_JUMBO=true
WITH_MAN=true
WITHOUT_PERSISTENT_MMAP=true
WITHOUT_SRV=true\n",
    );
};

sub docs {
    my $self = shift;

    my $cmd;

    if ( !-f "README" && !-f "lib/toaster.conf.pod" ) {
        print <<"EO_NOT_IN_DIST_ERR";

   ERROR: This setup target can only be run in the Mail::Toaster distibution directory!

    Try switching into there and trying again.
EO_NOT_IN_DIST_ERR

        return;
    };

    # convert pod to text files
    my $pod2text = $self->util->find_bin( "pod2text", verbose=>0);

    $self->util->syscmd("$pod2text bin/toaster_setup.pl       > README", verbose=>0);
    $self->util->syscmd("$pod2text lib/toaster.conf.pod          > doc/toaster.conf", verbose=>0);
    $self->util->syscmd("$pod2text lib/toaster-watcher.conf.pod  > doc/toaster-watcher.conf", verbose=>0);


    # convert pod docs to HTML pages for the web site

    my $pod2html = $self->util->find_bin("pod2html", verbose=>0);

    $self->util->syscmd( "$pod2html --title='toaster.conf' lib/toaster.conf.pod > doc/toaster.conf.html",
        verbose=>0, );
    $self->util->syscmd( "$pod2html --title='watcher.conf' lib/toaster-watcher.conf.pod  > doc/toaster-watcher.conf.html",
        verbose=>0, );
    $self->util->syscmd( "$pod2html --title='mailadmin' bin/mailadmin > doc/mailadmin.html",
        verbose=>0, );

    my @modules = qw/ Toaster   Apache  CGI     Darwin   DNS
            Ezmlm     FreeBSD   Logs    Mysql   Perl
            Qmail     Setup   Utility /;

    MODULE:
    foreach my $module (@modules ) {
        if ( $module =~ m/\AToaster\z/ ) {
            $cmd = "$pod2html --title='Mail::Toaster' lib/Mail/$module.pm > doc/modules/$module.html";
            print "$cmd\n";
            next MODULE;
            $self->util->syscmd( $cmd, verbose=>0 );
        };

        $cmd = "$pod2html --title='Mail::Toaster::$module' lib/Mail/Toaster/$module.pm > doc/modules/$module.html";
        warn "$cmd\n";
        $self->util->syscmd( $cmd, verbose=>0 );
    };

    unlink <pod2htm*>;
    #$self->util->syscmd( "rm pod2html*");
};

sub domainkeys {

    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( !$self->conf->{'qmail_domainkeys'} ) {
        $self->audit( "domainkeys: installing, skipping (disabled)" );
        return 0;
    }

    # test to see if it is installed.
    if ( -f "/usr/local/include/domainkeys.h" ) {
        $self->audit( "domainkeys: installing domainkeys, ok (already installed)" );
        return 1;
    }

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "libdomainkeys" );

        # test to see if it installed.
        if ( -f "/usr/local/include/domainkeys.h" ) {
            $self->audit( "domainkeys: installing domainkeys, ok (already installed)" );
            return 1;
        }
    }

    my @targets = ( 'make', 'make setup check' );

    if ( $OSNAME eq "linux" ) {
        unshift @targets,
          'echo gcc -O2 -include /usr/include/errno.h > conf-cc';
    }

    $self->util->install_from_source(
        package => "libdomainkeys-0.68",
        site    => 'http://superb-east.dl.sourceforge.net',
        url     => '/sourceforge/domainkeys',
        targets => \@targets,
    );
}

sub dovecot {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_dovecot'} or do {
        $self->audit( "dovecot install not selected.");
        return;
    };

    if ( $ver eq "port" || $ver eq "1" ) {

        if ( $self->util->find_bin( "dovecot", fatal => 0 ) ) {
            print "dovecot: is already installed...done.\n\n";
            return $self->dovecot_start();
        }

        print "dovecot: installing...\n";

        if ( $OSNAME eq "freebsd" ) {
            $self->dovecot_install_freebsd() or return;
            return $self->dovecot_start();
        }
        elsif ( $OSNAME eq "darwin" ) {
            return 1 if $self->darwin->install_port( "dovecot" );
        }

        if ( $self->util->find_bin( "dovecot", fatal => 0 ) ) {
            print "dovecot: install successful.\n";
            return $self->dovecot_start();
        }

        $ver = "1.0.7";
    }

    my $dovecot = $self->util->find_bin( "dovecot", fatal => 0 );
    if ( -x $dovecot ) {
        my $installed = `$dovecot --version`;

        if ( $ver eq $installed ) {
            print
              "dovecot: the selected version ($ver) is already installed!\n";
            $self->dovecot_start();
            return 1;
        }
    }

    $self->util->install_from_source(
        package        => "dovecot-$ver",
        site           => 'http://www.dovecot.org',
        url            => '/releases',
        targets        => [ './configure', 'make', 'make install' ],
        bintest        => 'dovecot',
        verbose          => 1,
        source_sub_dir => 'mail',
    );

    $self->dovecot_start();
}

sub dovecot_1_conf {
    my $self = shift;

    my $dconf = '/usr/local/etc/dovecot.conf';
    if ( ! -f $dconf ) {
        foreach ( qw{ /opt/local/etc /etc } ) {
            $dconf = "$_/dovecot.conf";
            last if -e $dconf;
        };
        if ( ! -f $dconf ) {
            return $self->error( "could not locate dovecot.conf. Toaster modifications not applied.");
        };
    };

    my $updated = `grep 'Mail Toaster' $dconf`;
    if ( $updated ) {
        $self->audit( "Toaster modifications detected, skipping config" );
        return 1;
    };

    $self->config_apply_tweaks(
        file => $dconf,
        changes => [
            {   search  => "protocols = imap pop3 imaps pop3s managesieve",
                replace => "protocols = imap pop3 imaps pop3s",
                nowarn  => 1,
            },
            {   search  => "protocol pop3 {",
                search2 => "section",
                replace => "protocol pop3 {
  pop3_uidl_format = %08Xu%08Xv
  mail_plugins = quota
  pop3_client_workarounds = outlook-no-nuls oe-ns-eoh
}",
            },
            {   search  => "protocol managesieve {",
                search2 => "section",
                replace => " ",
                nowarn  => 1,   # manageseive is optional build
            },
            {   search  => "#shutdown_clients = yes",
                replace => "#shutdown_clients = yes\nshutdown_clients = no",
            },
            {   search  => "#ssl_cert_file = /etc/ssl/certs/dovecot.pem",
                replace => "#ssl_cert_file = /etc/ssl/certs/dovecot.pem
ssl_cert_file = /var/qmail/control/servercert.pem",
            },
            {   search  => "#ssl_key_file = /etc/ssl/private/dovecot.pem",
                replace => "#ssl_key_file = /etc/ssl/private/dovecot.pem
ssl_key_file = /var/qmail/control/servercert.pem",
            },
            {   search  => "#login_greeting = Dovecot ready.",
                replace => "#login_greeting = Dovecot ready.
login_greeting = Mail Toaster (Dovecot) ready.",
            },
            {
                search  => "mail_location = mbox:~/mail/:INBOX=/var/mail/%u",
                replace => "#mail_location = mbox:~/mail/:INBOX=/var/mail/%u
mail_location = maildir:~/Maildir",
            },
            {   search  => "first_valid_uid = 1000",
                replace => "#first_valid_uid = 1000
first_valid_uid = 89",
            },
            {   search  => "#last_valid_uid = 0",
                replace => "#last_valid_uid = 0
last_valid_uid = 89",
            },
            {   search  => "first_valid_gid = 1000",
                replace => "#first_valid_gid = 1000
first_valid_gid = 89",
            },
            {   search  => "#last_valid_gid = 0",
                replace => "#last_valid_gid = 0\nlast_valid_gid = 89",
            },
            {   search  => "  #mail_plugins = ",
                replace => "  #mail_plugins = \n  mail_plugins = quota imap_quota",
            },
            {   search  => "  sendmail_path = /usr/sbin/sendmail",
                replace => "#  sendmail_path = /usr/sbin/sendmail
  sendmail_path = /var/qmail/bin/sendmail",
            },
            {   search  => "auth_username_format = %Ln",
                replace => "#auth_username_format = %Ln
auth_username_format = %Lu",
                nowarn  => 1,
            },
            {   search  => "  mechanisms = plain login",
                replace => "  mechanisms = plain login digest-md5 cram-md5",
            },
            {   search  => "  passdb pam {",
                search2 => "section",
                replace => " ",
            },
            {   search  => "  #passdb vpopmail {",
                replace => "  passdb vpopmail {\n  }",
            },
            {   search  => "  #userdb vpopmail {",
                replace => "  userdb vpopmail {\n  }",
            },
            {   search  => "  user = root",
                replace => "  user = vpopmail",
            },
            {   search  => "  #quota = maildir",
                replace => "  quota = maildir",
            },
        ],
    );
    return 1;
};

sub dovecot_2_conf {
    my $self = shift;

    my $dconf = '/usr/local/etc/dovecot';
    return if ! -d $dconf;

    if ( ! -f "$dconf/dovecot.conf" ) {
        my $ex = '/usr/local/share/doc/dovecot/example-config';

        foreach ( qw/ dovecot.conf / ) {
            if ( -f "$ex/$_" ) {
                copy("$ex/$_", $dconf);
            };
        };
        system "cp $ex/conf.d /usr/local/etc/dovecot";
    };

    my $updated = `grep 'Mail Toaster' $dconf/dovecot.conf`;
    if ( $updated ) {
        $self->audit( "Toaster modifications detected, skipping config" );
        return 1;
    };

    $self->config_apply_tweaks(
        file => "$dconf/dovecot.conf",
        changes => [
            {   search  => "#login_greeting = Dovecot ready.",
                replace => "#login_greeting = Dovecot ready.
login_greeting = Mail Toaster (Dovecot) ready.",
            },
            {   search  => "#listen = *, ::",
                replace => "#listen = *, ::\nlisten = *",
            },
        ],
    );

    $self->config_apply_tweaks(
        file => "$dconf/conf.d/10-auth.conf",
        changes => [
            {   search  => "#auth_username_format =",
                replace => "#auth_username_format =\nauth_username_format = %Lu",
                nowarn  => 1,
            },
            {   search  => "auth_mechanisms = plain",
                replace => "auth_mechanisms = plain login digest-md5 cram-md5",
            },
            {   search  => "!include auth-system.conf.ext",
                replace => "#!include auth-system.conf.ext",
                nowarn  => 1,
            },
            {   search  => "#!include auth-vpopmail.conf.ext",
                replace => "!include auth-vpopmail.conf.ext",
                nowarn  => 1,
            },
        ],
    );

    $self->config_apply_tweaks(
        file => "$dconf/conf.d/10-ssl.conf",
        changes => [
            {   search  => "ssl_cert = </etc/ssl/certs/dovecot.pem",
                replace => "#ssl_cert = </etc/ssl/certs/dovecot.pem
ssl_cert = </var/qmail/control/servercert.pem",
            },
            {   search  => "ssl_key = </etc/ssl/private/dovecot.pem",
                replace => "#ssl_key = </etc/ssl/private/dovecot.pem
ssl_key = </var/qmail/control/servercert.pem",
            },
        ],
    );

    $self->config_apply_tweaks(
        file => "$dconf/conf.d/10-mail.conf",
        changes => [
            {
                search  => "#mail_location = ",
                replace => "#mail_location =
mail_location = maildir:~/Maildir",
            },
            {   search  => "#first_valid_uid = 500",
                replace => "#first_valid_uid = 500\nfirst_valid_uid = 89",
            },
            {   search  => "#last_valid_uid = 0",
                replace => "#last_valid_uid = 0\nlast_valid_uid = 89",
            },
            {   search  => "first_valid_gid = 1",
                replace => "#first_valid_gid = 1\nfirst_valid_gid = 89",
            },
            {   search  => "#last_valid_gid = 0",
                replace => "#last_valid_gid = 0\nlast_valid_gid = 89",
            },
            {   search  => "#mail_plugins =",
                replace => "#mail_plugins =\nmail_plugins = quota",
            },
        ],
    );

    $self->config_apply_tweaks(
        file => "$dconf/conf.d/20-pop3.conf",
        changes => [
            {   search => "  #pop3_client_workarounds = ",
                replace => "  #pop3_client_workarounds = \n  pop3_client_workarounds = outlook-no-nuls oe-ns-eo",
            },
        ],
    );

    $self->config_apply_tweaks(
        file => "$dconf/conf.d/15-lda.conf",
        changes => [
            {   search  => "#sendmail_path = /usr/sbin/sendmail",
                replace => "#sendmail_path = /usr/sbin/sendmail\nsendmail_path = /var/qmail/bin/sendmail",
            },
        ],
    );

    $self->config_apply_tweaks(
        file => "$dconf/conf.d/90-quota.conf",
        changes => [
            {   search  => "  #quota = maildir:User quota",
                replace => "  quota = maildir:User quota",
            },
        ],
    );

    $self->config_apply_tweaks(
        file => "$dconf/conf.d/20-imap.conf",
        changes => [
            {   search  => "  #mail_plugins = ",
                replace => "  #mail_plugins = \n  mail_plugins = \$mail_plugins imap_quota",
            },
        ],
    );
};

sub dovecot_install_freebsd {
    my $self = shift;

    return 1 if $self->freebsd->is_port_installed('dovecot');

    $self->audit( "starting port install of dovecot" );

    $self->freebsd->install_port( "dovecot",
        options => "
# This file is generated by Mail Toaster.
# Options for dovecot-1.2.4_1
_OPTIONS_READ=dovecot-1.2.4_1
WITH_KQUEUE=true
WITH_SSL=true
WITHOUT_IPV6=true
WITH_POP3=true
WITH_LDA=true
WITHOUT_MANAGESIEVE=true
WITHOUT_GSSAPI=true
WITH_VPOPMAIL=true
WITHOUT_BDB=true
WITHOUT_LDAP=true
WITHOUT_PGSQL=true
WITHOUT_MYSQL=true
WITHOUT_SQLITE=true
",
    ) or return;

    return if ! $self->freebsd->is_port_installed('dovecot');

    my $config = "/usr/local/etc/dovecot.conf";
    if ( ! -e $config ) {
        if ( -e "/usr/local/etc/dovecot-example.conf" ) {
            copy("/usr/local/etc/dovecot-example.conf", $config);
        }
        else {
            $self->error("unable to find dovecot.conf sample", fatal => 0);
            sleep 3;
            return;
        };
    };

    return 1;
}

sub dovecot_start {

    my $self = shift;

    unless ( $OSNAME eq "freebsd" ) {
        $self->error( "sorry, no dovecot startup support on $OSNAME", fatal => 0);
        return;
    };

    $self->dovecot_1_conf();
    $self->dovecot_2_conf();

    # append dovecot_enable to /etc/rc.conf
    $self->freebsd->conf_check(
        check => "dovecot_enable",
        line  => 'dovecot_enable="YES"',
    );

    # start dovecot
    if ( -x "/usr/local/etc/rc.d/dovecot" ) {
        $self->util->syscmd("/usr/local/etc/rc.d/dovecot restart", verbose=>0);
    };
}

sub enable_all_spam {
    my $self  = shift;

    my $qmail_dir = $self->conf->{'qmail_dir'} || "/var/qmail";
    my $spam_cmd  = $self->conf->{'qmailadmin_spam_command'} ||
        '| /usr/local/bin/maildrop /usr/local/etc/mail/mailfilter';

    my @domains = $self->qmail->get_domains_from_assign(
            assign => "$qmail_dir/users/assign",
        );

    my $number_of_domains = @domains;
    $self->audit( "enable_all_spam: found $number_of_domains domains.");

    for (my $i = 0; $i < $number_of_domains; $i++) {

        my $domain = $domains[$i]{'dom'};
        $self->audit( "Enabling spam processing for $domain mailboxes");

        my @paths = `~vpopmail/bin/vuserinfo -d -D $domain`;

        PATH:
        foreach my $path (@paths) {
            chomp($path);
            if ( ! $path || ! -d $path) {
                $self->audit( "  $path does not exist!");
                next PATH;
            };

            my $qpath = "$path/.qmail";
            if (-f $qpath) {
                $self->audit( "  .qmail already exists in $path.");
                next PATH;
            };

            $self->audit( "  .qmail created in $path.");
            system "echo \"$spam_cmd \" >> $path/.qmail";

            my $uid = getpwnam("vpopmail");
            my $gid = getgrnam("vchkpw");
            chown( $uid, $gid, "$path/.qmail" );
            chmod oct('0644'), "$path/.qmail";
        }
    }

    return 1;
}

sub expat {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( !$self->conf->{'install_expat'} ) {
        $self->audit( "expat: installing, skipping (disabled)" );
        return;
    }

    if ( $OSNAME eq "freebsd" ) {
        if ( -d "/usr/ports/textproc/expat" ) {
            return $self->freebsd->install_port( "expat" );
        }
        else {
            return $self->freebsd->install_port( "expat", dir => 'expat2');
        }
    }
    elsif ( $OSNAME eq "darwin" ) {
        $self->darwin->install_port( "expat" );
    }
    else {
        print "Sorry, build support for expat on $OSNAME is incomplete.\n";
    }
}

sub expect {

    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( $OSNAME eq "freebsd" ) {
        return $self->freebsd->install_port( "expect",
            flags => "WITHOUT_X11=yes",
            fatal => $p{fatal},
        );
    }
    return;
}

sub ezmlm {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver     = $self->conf->{'install_ezmlm'};
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";

    if ( !$ver ) {
        $self->audit( "installing Ezmlm-Idx, (disabled)", verbose=>1 );
        return;
    }

    my $ezmlm = $self->util->find_bin( 'ezmlm-sub',
        dir   => '/usr/local/bin/ezmlm',
        fatal => 0,
    );

    if ( $ezmlm && -x $ezmlm ) {
        $self->audit( "installing Ezmlm-Idx, ok (installed)",verbose=>1 );
        return $self->ezmlm_cgi();
    }

    $self->ezmlm_freebsd_port() and return 1;
    $self->ezmlm_src();
};

sub ezmlm_src {
    my $self = shift;
    print "ezmlm: attemping to install ezmlm from sources.\n";

    my $ezmlm_dist = "ezmlm-0.53";
    my $ver     = $self->conf->{'install_ezmlm'};
    my $idx     = "ezmlm-idx-$ver";
    my $site    = "http://untroubled.org/ezmlm";
    my $src     = $self->conf->{'toaster_src_dir'} || "/usr/local/src/mail";
    my $httpdir = $self->conf->{'toaster_http_base'} || "/usr/local/www";
    my $cgi     = $self->toaster->get_toaster_cgibin() or die "unable to determine cgi-bin dir\n";

    $self->util->cwd_source_dir( "$src/mail" );

    if ( -d $ezmlm_dist ) {
        unless (
            $self->util->source_warning( package => $ezmlm_dist, src => "$src/mail" ) )
        {
            carp "\nezmlm: OK then, skipping install.\n";
            return;
        }
        else {
            print "ezmlm: removing any previous build sources.\n";
            $self->util->syscmd( "rm -rf $ezmlm_dist" );
        }
    }

    $self->util->get_url( "$site/archive/$ezmlm_dist.tar.gz" )
        if ! -e "$ezmlm_dist.tar.gz";

    $self->util->get_url( "$site/archive/$ver/$idx.tar.gz" )
        if ! -e "$idx.tar.gz";

    $self->util->extract_archive( "$ezmlm_dist.tar.gz" )
      or croak "Couldn't expand $ezmlm_dist.tar.gz: $!\n";

    $self->util->extract_archive( "$idx.tar.gz" )
      or croak "Couldn't expand $idx.tar.gz: $!\n";

    $self->util->syscmd( "mv $idx/* $ezmlm_dist/", );
    $self->util->syscmd( "rm -rf $idx", );

    chdir($ezmlm_dist);

    $self->util->syscmd( "patch < idx.patch", );
    $self->ezmlm_conf_fixups();

    $self->util->syscmd( "make" );
    $self->util->syscmd( "chmod 775 makelang" );

#$self->util->syscmd( "make mysql" );  # haven't figured this out yet (compile problems)
    $self->util->syscmd( "make man" );
    $self->util->syscmd( "make setup");

    $self->ezmlm_cgi();
    return 1;
}

sub ezmlm_conf_fixups {
    my $self = shift;

    if ( $OSNAME eq "darwin" ) {
        my $local_include = "/usr/local/mysql/include";
        my $local_lib     = "/usr/local/mysql/lib";

        if ( !-d $local_include ) {
            $local_include = "/opt/local/include/mysql";
            $local_lib     = "/opt/local/lib/mysql";
        }

        $self->util->file_write( "sub_mysql/conf-sqlcc",
            lines => ["-I$local_include"],
        );

        $self->util->file_write( "sub_mysql/conf-sqlld",
            lines => ["-L$local_lib -lmysqlclient -lm"],
        );
    }
    elsif ( $OSNAME eq "freebsd" ) {
        $self->util->file_write( "sub_mysql/conf-sqlcc",
            lines => ["-I/usr/local/include/mysql"],
        );

        $self->util->file_write( "sub_mysql/conf-sqlld",
            lines => ["-L/usr/local/lib/mysql -lmysqlclient -lnsl -lm"],
        );
    }

    $self->util->file_write( "conf-bin", lines => ["/usr/local/bin"] );
    $self->util->file_write( "conf-man", lines => ["/usr/local/man"] );
    $self->util->file_write( "conf-etc", lines => ["/usr/local/etc"] );
};

sub ezmlm_cgi {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    return 1 if ! $self->conf->{'install_ezmlm_cgi'};

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "p5-Archive-Tar",
            options=>"#
# This file was generated by Mail::Toaster
# No user-servicable parts inside!
# Options for p5-Archive-Tar-1.30
_OPTIONS_READ=p5-Archive-Tar-1.30
WITHOUT_TEXT_DIFF=true",
        );
    }

    $self->util->install_module( "Email::Valid" );
    $self->util->install_module( "Mail::Ezmlm" );

    return 1;
}

sub ezmlm_freebsd_port {
    my $self = shift;

    return if $OSNAME ne "freebsd";
    return if $self->conf->{'install_ezmlm'} ne "port";
    return 1 if $self->freebsd->is_port_installed( "ezmlm", fatal=>0 );

    my $defs = '';
    my $opts = "WITHOUT_MYSQL=true";
    if ( $self->conf->{'install_ezmlm_mysql'} ) {
        $defs .= "WITH_MYSQL=yes";
        $opts = "WITH_MYSQL=true";
    };

    $self->freebsd->install_port( "ezmlm-idx",
        options => "# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for ezmlm-idx-7.1.1_1
_OPTIONS_READ=ezmlm-idx-7.1.1_1
$opts
WITHOUT_SQLITE=true
WITHOUT_PGSQL=true",
        flags   => $defs,
    )
    or return $self->error( "ezmlm-idx install failed" );

    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";
    chdir("$confdir/ezmlm");
    copy( "ezmlmglrc.sample", "ezmlmglrc" )
        or $self->util->error( "copy ezmlmglrc failed: $!");

    copy( "ezmlmrc.sample", "ezmlmrc" )
        or $self->util->error( "copy ezmlmrc failed: $!");

    copy( "ezmlmsubrc.sample", "ezmlmsubrc" )
        or $self->util->error( "copy ezmlmsubrc failed: $!");

    return $self->ezmlm_cgi();
};

sub filtering {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( $OSNAME eq "freebsd" ) {

        $self->maildrop();

        $self->freebsd->install_port( "p5-Archive-Tar",
			options=> "# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for p5-Archive-Tar-1.30
_OPTIONS_READ=p5-Archive-Tar-1.30
WITHOUT_TEXT_DIFF=true",
        );

        $self->freebsd->install_port( "p5-Mail-Audit" );
        $self->freebsd->install_port( "unzip" );

        $self->razor();

        $self->freebsd->install_port( "pyzor" ) if $self->conf->{'install_pyzor'};
        $self->freebsd->install_port( "bogofilter" ) if $self->conf->{'install_bogofilter'};
        $self->freebsd->install_port( "dcc-dccd",
            flags => "WITHOUT_SENDMAIL=yes",
            options => "# This file generated by mail-toaster
# Options for dcc-dccd-1.3.116
_OPTIONS_READ=dcc-dccd-1.3.116
WITH_DCCIFD=true
WITHOUT_DCCM=true
WITH_DCCD=true
WITH_DCCGREY=true
WITH_IPV6=true
WITHOUT_ALT_HOME=true
WITHOUT_PORTS_SENDMAIL=true\n",
            ) if $self->conf->{'install_dcc'};

        $self->freebsd->install_port( "procmail" ) if $self->conf->{'install_procmail'};
        $self->freebsd->install_port( "p5-Email-Valid" );
    }

    $self->spamassassin;
    $self->razor;
    $self->clamav;
    $self->simscan;
}

sub filtering_test {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    $self->simscan_test( );

    print "\n\nFor more ways to test your Virus scanner, go here:
\n\t http://www.testvirus.org/\n\n";
}

sub gmake_freebsd {
    my $self = shift;

# iconv to suppress a prompt, and because gettext requires it
    $self->freebsd->install_port( 'libiconv',
        options => "#\n# This file was generated by mail-toaster
# Options for libiconv-1.13.1_1
_OPTIONS_READ=libiconv-1.13.1_1
WITH_EXTRA_ENCODINGS=true
WITHOUT_EXTRA_PATCHES=true\n",
    );

# required by gmake
    $self->freebsd->install_port( "gettext",
        options => "#\n# This file was generated by mail-toaster
# Options for gettext-0.14.5_2
_OPTIONS_READ=gettext-0.14.5_2\n",
    );

    $self->freebsd->install_port( 'gmake' );
};

sub gnupg_install {
    my $self = shift;
    return if ! $self->conf->{'install_gnupg'};

    if ( $self->conf->{package_install_method} eq 'packages' ) {
        $self->freebsd->install_package( "gnupg", verbose=>0, fatal => 0 );
        return 1 if $self->freebsd->is_port_installed('gnupg');
    };

    $self->freebsd->install_port( "gnupg",
        verbose   => 0,
        options => "# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for gnupg-1.4.5
_OPTIONS_READ=gnupg-1.4.5
WITHOUT_LDAP=true
WITHOUT_LIBICONV=true
WITHOUT_LIBUSB=true
WITHOUT_SUID_GPG=true
WITH_NLS=true",
    );
};

sub group_add {
    my $self = shift;
    my ($group, $gid) = @_;
    return if ! $group;
    return if $self->group_exists($group);
    my $cmd;
    if ( $OSNAME eq 'linux' ) {
        $cmd = $self->util->find_bin('groupadd');
        $cmd .= " -g $gid" if $gid;
        $cmd .= " $group";
    }
    elsif ( $OSNAME eq 'freebsd' ) {
        $cmd = $self->util->find_bin( 'pw' );
        $cmd .= " groupadd -n $group";
        $cmd .= " -g $gid" if $gid;
    }
    elsif ( $OSNAME eq 'darwin' ) {
        $cmd = $self->util->find_bin( "dscl", fatal => 0 );
        my $path = "/groups/$group";
        if ($cmd) {    # use dscl 10.5+
            $self->util->syscmd( "$cmd . -create $path" );
            $self->util->syscmd( "$cmd . -createprop $path gid $gid") if $gid;
            $self->util->syscmd( "$cmd . -createprop $path passwd '*'" );
        }
        else {
            $cmd = $self->util->find_bin( "niutil", fatal => 0 );
            $self->util->syscmd( "$cmd -create . $path" );
            $self->util->syscmd( "$cmd -createprop . $path gid $gid") if $gid;
            $self->util->syscmd( "$cmd -createprop . $path passwd '*'" );
        }
        return 1;
    }
    else {
        warn "unable to create users on OS $OSNAME\n";
        return;
    };
    return $self->util->syscmd( $cmd );
};

sub group_exists {
    my $self = shift;
    my $group = lc(shift) or die "missing group";
    my $gid = getgrnam($group);
    return ( $gid && $gid > 0 ) ? $gid : undef;
};

sub has_module {
    my $self = shift;
    my ($name, $ver) = @_;

## no critic ( ProhibitStringyEval )
    eval "use $name" . ($ver ? " $ver;" : ";");
## use critic

    !$EVAL_ERROR;
};

sub imap_test_auth {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    $self->imap_test_auth_nossl();
    $self->imap_test_auth_ssl();
};

sub imap_test_auth_nossl {
    my $self = shift;

    my $r = $self->util->install_module("Mail::IMAPClient", verbose => 0);
    $self->toaster->test("checking Mail::IMAPClient", $r );
    if ( ! $r ) {
        print "skipping imap test authentications\n";
        return;
    };

    # an authentication that should succeed
    my $imap = Mail::IMAPClient->new(
        User     => $self->conf->{'toaster_test_email'} || 'test2@example.com',
        Password => $self->conf->{'toaster_test_email_pass'} || 'cHanGeMe',
        Server   => 'localhost',
    );
    if ( !defined $imap ) {
        $self->toaster->test( "imap connection", $imap );
        return;
    };

    $self->toaster->test( "authenticate IMAP user with plain passwords",
        $imap->IsAuthenticated() );

    my @features = $imap->capability
        or warn "Couldn't determine capability: $@\n";
    $self->audit( "Your IMAP server supports: " . join( ',', @features ) );
    $imap->logout;

    print "an authentication that should fail\n";
    $imap = Mail::IMAPClient->new(
        Server => 'localhost',
        User   => 'no_such_user',
        Pass   => 'hi_there_log_watcher'
    )
    or do {
        $self->toaster->test( "imap connection that should fail", 0);
        return 1;
    };
    $self->toaster->test( "  imap connection", $imap->IsConnected() );
    $self->toaster->test( "  test auth that should fail", !$imap->IsAuthenticated() );
    $imap->logout;
    return;
};

sub imap_test_auth_ssl {
    my $self = shift;

    my $user = $self->conf->{'toaster_test_email'}      || 'test2@example.com';
    my $pass = $self->conf->{'toaster_test_email_pass'} || 'cHanGeMe';

    my $r = $self->util->install_module( "IO::Socket::SSL", verbose => 0,);
    $self->toaster->test( "checking IO::Socket::SSL ", $r);
    if ( ! $r ) {
        print "skipping IMAP SSL tests due to missing SSL support\n";
        return;
    };

    require IO::Socket::SSL;
    my $socket = IO::Socket::SSL->new(
        PeerAddr => 'localhost',
        PeerPort => 993,
        Proto    => 'tcp'
    );
    $self->toaster->test( "  imap SSL connection", $socket);
    return if ! $socket;

    print "  connected with " . $socket->get_cipher() . "\n";
    print $socket ". login $user $pass\n";
    ($r) = $socket->peek =~ /OK/i;
    $self->toaster->test( "  auth IMAP SSL with plain password", $r ? 0 : 1);
    print $socket ". logout\n";
    close $socket;

#  no idea why this doesn't work, so I just forge an authentication by printing directly to the socket
#	my $imapssl = Mail::IMAPClient->new( Socket=>$socket, User=>$user, Password=>$pass) or warn "new IMAP failed: ($@)\n";
#	$imapssl->IsAuthenticated() ? print "ok\n" : print "FAILED.\n";

# doesn't work yet because courier doesn't support CRAM-MD5 via the vchkpw auth module
#	print "authenticating IMAP user with CRAM-MD5...";
#	$imap->connect;
#	$imap->authenticate();
#	$imap->IsAuthenticated() ? print "ok\n" : print "FAILED.\n";
#
#	print "logging out...";
#	$imap->logout;
#	$imap->IsAuthenticated() ? print "FAILED.\n" : print "ok.\n";
#	$imap->IsConnected() ? print "connection open.\n" : print "connection closed.\n";

}

sub is_newer {
    my $self  = shift;
    my %p = validate( @_, { 'min' => SCALAR, 'cur' => SCALAR, $self->get_std_opts } );

    my ( $min, $cur ) = ( $p{'min'}, $p{'cur'} );

    my @mins = split( q{\.}, $min );
    my @curs = split( q{\.}, $cur );

    #use Data::Dumper;
    #print Dumper(@mins, @curs);

    if ( $curs[0] > $mins[0] ) { return 1; }    # major version num
    if ( $curs[1] > $mins[1] ) { return 1; }    # minor version num
    if ( $curs[2] && $mins[2] && $curs[2] > $mins[2] ) { return 1; }    # revision level
    if ( $curs[3] && $mins[3] && $curs[3] > $mins[3] ) { return 1; }    # just in case

    return 0;
}

sub isoqlog {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $ver = $self->conf->{'install_isoqlog'}
        or return $self->audit( "install_isoqlog is disabled",verbose=>1 );

    my $return = 0;

    if ( $ver eq "port" ) {
        if ( $OSNAME eq "freebsd" ) {
            $self->freebsd->install_port( "isoqlog" );
            $self->isoqlog_conf();
            return 1 if $self->freebsd->is_port_installed( "isoqlog", %p );
        }
        else {
            return $self->error(
                "isoqlog: install_isoqlog = port is not valid for $OSNAME" );
        }
    }
    else {
        if ( $self->util->find_bin( "isoqlog", fatal => 0 ) ) {
            $self->isoqlog_conf();
            $self->audit( "isoqlog: install, ok (exists)" );
            return 2;
        }
    }

    return $return if $self->util->find_bin( "isoqlog", fatal => 0 );

    $self->audit( "isoqlog not found. Attempting source install ($ver) on $OSNAME!");

    $ver = 2.2 if ( $ver eq "port" || $ver == 1 );

    my $configure = "./configure ";

    if ( $self->conf->{'toaster_prefix'} ) {
        $configure .= "--prefix=" . $self->conf->{'toaster_prefix'} . " ";
        $configure .= "--exec-prefix=" . $self->conf->{'toaster_prefix'} . " ";
    }

    if ( $self->conf->{'system_config_dir'} ) {
        $configure .= "--sysconfdir=" . $self->conf->{'system_config_dir'} . " ";
    }

    $self->audit( "isoqlog: building with $configure" );

    $self->util->install_from_source(
        package => "isoqlog-$ver",
        site    => 'http://www.enderunix.org',
        url     => '/isoqlog',
        targets => [ $configure, 'make', 'make install', 'make clean' ],
        bintest => 'isoqlog',
        source_sub_dir => 'mail',
        %p
    );

    if ( $self->conf->{'toaster_prefix'} ne "/usr/local" ) {
        symlink( "/usr/local/share/isoqlog",
            $self->conf->{'toaster_prefix'} . "/share/isoqlog" );
    }

    if ( $self->util->find_bin( "isoqlog", fatal => 0 ) ) {
        return $self->isoqlog_conf();
    };

    return;
}

sub isoqlog_conf {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    # isoqlog doesn't honor --sysconfdir yet
    #my $etc = $self->conf->{'system_config_dir'} || "/usr/local/etc";
    my $etc  = "/usr/local/etc";
    my $file = "$etc/isoqlog.conf";

    if ( -e $file ) {
        $self->audit( "isoqlog_conf: creating $file, ok (exists)" );
        return 2;
    }

    my @lines;

    my $htdocs = $self->conf->{'toaster_http_docs'} || "/usr/local/www/data";
    my $hostn  = $self->conf->{'toaster_hostname'}  || hostname;
    my $logdir = $self->conf->{'qmail_log_base'}    || "/var/log/mail";
    my $qmaild = $self->conf->{'qmail_dir'}         || "/var/qmail";
    my $prefix = $self->conf->{'toaster_prefix'}    || "/usr/local";

    push @lines, <<EO_ISOQLOG;
#isoqlog Configuration file

logtype     = "qmail-multilog"
logstore    = "$logdir/send"
domainsfile = "$qmaild/control/rcpthosts"
outputdir   = "$htdocs/isoqlog"
htmldir     = "$prefix/share/isoqlog/htmltemp"
langfile    = "$prefix/share/isoqlog/lang/english"
hostname    = "$hostn"

maxsender   = 100
maxreceiver = 100
maxtotal    = 100
maxbyte     = 100
EO_ISOQLOG

    $self->util->file_write( $file, lines => \@lines )
        or $self->error( "couldn't write $file: $!");
    $self->audit( "isoqlog_conf: created $file, ok" );

    $self->util->syscmd( "isoqlog", fatal => 0 );

    # if missing, create the isoqlog web directory
    if ( ! -e "$htdocs/isoqlog" ) {
        mkdir oct('0755'), "$htdocs/isoqlog";
    };

    # to fix the missing images problem, add a web server alias like:
    # Alias /isoqlog/images/ "/usr/local/share/isoqlog/htmltemp/images/"
}

sub lighttpd {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{install_lighttpd} ) {
        $self->audit("skipping lighttpd install (disabled)");
        return;
    };

    if ( $OSNAME eq 'freebsd' ) {
        $self->lighttpd_freebsd();
    }
    else {
        $self->util->find_bin( 'lighttpd', fatal=>0)
            or return $self->error("no support for install lighttpd on $OSNAME. Report this error to support\@tnpi.net");
    };

    $self->lighttpd_config();
    $self->lighttpd_vhost();
    $self->php();
    $self->lighttpd_start();
    return 1;
};

sub lighttpd_freebsd {
    my $self = shift;

    $self->freebsd->install_port( "lighttpd",
        options => "#\n# This file was generated by mail-toaster
# Options for lighttpd-1.4.26_3
_OPTIONS_READ=lighttpd-1.4.26_3
WITH_BZIP2=true
WITHOUT_CML=true
WITHOUT_FAM=true
WITHOUT_GDBM=true
WITHOUT_H264=true
WITHOUT_IPV6=true
WITHOUT_MAGNET=true
WITHOUT_MEMCACHE=true
WITHOUT_MYSQL=true
WITHOUT_NODELAY=true
WITHOUT_OPENLDAP=true
WITH_OPENSSL=true
WITH_SPAWNFCGI=true
WITHOUT_VALGRIND=true
WITHOUT_WEBDAV=true\n",
    );

    $self->freebsd->conf_check(
        check => "lighttpd_enable",
        line  => 'lighttpd_enable="YES"',
    );

    my @logs = qw/ lighttpd.error.log lighttpd.access.log /;
    foreach ( @logs ) {
        $self->util->file_write( "/var/log/$_", lines => [' '] )
            if ! -e "/var/log/$_";
        $self->util->chown("/var/log/$_", uid => 'www', gid => 'www');
    };
};

sub lighttpd_config {
    my $self = shift;

    my $letc = '/usr/local/etc';
    $letc = "$letc/lighttpd" if -d "$letc/lighttpd";

    my $lconf = "$letc/lighttpd.conf";

    `grep toaster $letc/lighttpd.conf`
        and return $self->audit("lighttpd configuration already done");

    my $cgi_bin = $self->conf->{toaster_cgi_bin} || '/usr/local/www/cgi-bin.toaster/';
    my $htdocs = $self->conf->{toaster_http_docs} || '/usr/local/www/toaster';

    $self->config_apply_tweaks(
        file    => "$letc/lighttpd.conf",
        changes => [
            {   search  => q{#                               "mod_redirect",},
                replace => q{                                "mod_redirect",},
            },
            {   search  => q{#                               "mod_alias",},
                replace => q{                                "mod_alias",},
            },
            {   search  => q{#                               "mod_auth",},
                replace => q{                                "mod_auth",},
            },
            {   search  => q{#                               "mod_setenv",},
                replace => q{                                "mod_setenv",},
            },
            {   search  => q{#                               "mod_fastcgi",},
                replace => q{                                "mod_fastcgi",},
            },
            {   search  => q{#                               "mod_cgi",},
                replace => q{                                "mod_cgi",},
            },
            {   search  => q{#                               "mod_compress",},
                replace => q{                                "mod_compress",},
            },
            {   search  => q{server.document-root        = "/usr/local/www/data/"},
                replace => qq{server.document-root        = "$htdocs/"},
            },
            {   search  => q{server.document-root = "/usr/local/www/data/"},
                replace => qq{server.document-root = "$htdocs/"},
            },
            {   search  => q{var.server_root = "/usr/local/www/data"},
                replace => qq{var.server_root = "$htdocs"},
            },
            {   search  => q{#include_shell "cat /usr/local/etc/lighttpd/vhosts.d/*.conf"},
                replace => q{include_shell "cat /usr/local/etc/lighttpd/vhosts.d/*.conf"},
            },
            {   search  => q'$SERVER["socket"] == "0.0.0.0:80" { }',
                replace => q'#$SERVER["socket"] == "0.0.0.0:80" { }',
            },
        ],
    );

    $self->config_apply_tweaks(
        file    => "$letc/modules.conf",
        changes => [
            {   search  => q{#  "mod_alias",},
                replace => q{  "mod_alias",},
            },
            {   search  => q{#  "mod_auth",},
                replace => q{  "mod_auth",},
            },
            {   search  => q{#  "mod_redirect",},
                replace => q{  "mod_redirect",},
            },
            {   search  => q{#  "mod_setenv",},
                replace => q{  "mod_setenv",},
            },
            {   search  => q{#include "conf.d/cgi.conf"},
                replace => q{include "conf.d/cgi.conf"},
            },
            {   search  => q{#include "conf.d/fastcgi.conf"},
                replace => q{include "conf.d/fastcgi.conf"},
            },
        ],
    );

    return 1;
};

sub lighttpd_start {
    my $self = shift;

    if ( $OSNAME eq 'freebsd' ) {
        system "/usr/local/etc/rc.d/lighttpd restart";
        return 1;
    }
    elsif ( $OSNAME eq 'linux' ) {
        system "service lighttpd start";
        return 1;
    };
    print "not sure how to start lighttpd on $OSNAME\n";
    return;
};

sub lighttpd_vhost {
    my $self = shift;

    my $letc = '/usr/local/etc';
    $letc = "$letc/lighttpd" if -d "$letc/lighttpd";

    my $www   = '/usr/local/www';
    my $cgi_bin = $self->conf->{toaster_cgi_bin} || "$www/cgi-bin.toaster/";
    my $htdocs = $self->conf->{toaster_http_docs} || "$www/toaster";

    my $vhost = '
alias.url = (  "/cgi-bin/"       => "' . $cgi_bin . '/",
               "/sqwebmail/"     => "' . $htdocs . '/sqwebmail/",
               "/qmailadmin/"    => "' . $htdocs . '/qmailadmin/",
               "/squirrelmail/"  => "' . $www . '/squirrelmail/",
               "/roundcube/"     => "' . $www . '/roundcube/",
               "/v-webmail/"     => "' . $www . '/v-webmail/htdocs/",
               "/horde/"         => "' . $www . '/horde/",
               "/awstatsclasses" => "' . $www . '/awstats/classes/",
               "/awstatscss"     => "' . $www . '/awstats/css/",
               "/awstatsicons"   => "' . $www . '/awstats/icons/",
               "/awstats/"       => "' . $www . '/awstats/cgi-bin/",
               "/munin/"         => "' . $www . '/munin/",
               "/rrdutil/"       => "/usr/local/rrdutil/html/",
               "/isoqlog/images/"=> "/usr/local/share/isoqlog/htmltemp/images/",
               "/phpMyAdmin/"    => "' . $www . '/phpMyAdmin/",
            )

$HTTP["url"] =~ "^/awstats/" {
    cgi.assign = ( "" => "/usr/bin/perl" )
}
$HTTP["url"] =~ "^/cgi-bin" {
    cgi.assign = ( "" => "" )
}
$HTTP["url"] =~ "^/ezmlm.cgi" {
    cgi.assign = ( "" => "/usr/bin/perl" )
}

# redirect users to a secure connection
$SERVER["socket"] == ":80" {
   $HTTP["host"] =~ "(.*)" {
      url.redirect = ( "^/(.*)" => "https://%1/$1" )
   }
}

$SERVER["socket"] == ":443" {
   ssl.engine   = "enable"
   ssl.pemfile = "/usr/local/openssl/certs/server.pem"
# sqwebmail needs this
   setenv.add-environment = ( "HTTPS" => "on" )
}

fastcgi.server = (
                    ".php" =>
                       ( "localhost" =>
                         (
                           "socket"       => "/tmp/php-fastcgi.socket",
                           "bin-path"     => "/usr/local/bin/php-cgi",
                           "idle-timeout" => 1200,
                           "min-procs"    => 1,
                           "max-procs"    => 3,
                           "bin-environment" => (
                                "PHP_FCGI_CHILDREN"     => "2",
                                "PHP_FCGI_MAX_REQUESTS" => "100"
                           ),
                        )
                     )
                  )

auth.backend               = "htdigest"
auth.backend.htdigest.userfile = "/usr/local/etc/WebUsers"

auth.require   = (   "/isoqlog" =>
                     (
                         "method"  => "digest",
                         "realm"   => "Admins Only",
                         "require" => "valid-user"
                      ),
                     "/cgi-bin/vqadmin" =>
                     (
                         "method"  => "digest",
                         "realm"   => "Admins Only",
                         "require" => "valid-user"
                      ),
                     "/ezmlm.cgi" =>
                     (
                         "method"  => "digest",
                         "realm"   => "Admins Only",
                         "require" => "valid-user"
                      )
#                     "/munin" =>
#                     (
#                         "method"  => "digest",
#                         "realm"   => "Admins Only",
#                         "require" => "valid-user"
#                      )
                  )
';

    $self->util->file_write("$letc/vhosts.d/mail-toaster.conf", lines => [ $vhost ],);
    return 1;
};

sub logmonster {
    my $self = shift;
    my $verbose = $self->verbose;

    my %p = validate( @_, {
            fatal   => { type => BOOLEAN, optional => 1, default => 1 },
            verbose => { type => BOOLEAN, optional => 1, default => $verbose },
            test_ok => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{fatal};
       $verbose = $p{verbose};

    my $perlbin = $self->util->find_bin( "perl", verbose => $verbose );

    my @targets = ( "$perlbin Makefile.PL", "make", "make install" );
    push @targets, "make test" if $verbose;

    $self->util->install_module_from_src( 'Apache-Logmonster',
        site    => 'http://www.tnpi.net',
        archive => 'Apache-Logmonster',
        url     => '/internet/www/logmonster',
        targets => \@targets,
        verbose => $verbose,
    );
}

sub maildrop {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $ver = $self->conf->{'install_maildrop'} or do {
        $self->audit( "skipping maildrop install, not enabled.");
        return 0;
    };

    my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local";

    if ( $ver eq "port" || $ver eq "1" ) {
        if ( $OSNAME eq "freebsd" ) {
            $self->freebsd->install_port( "maildrop", flags => "WITH_MAILDIRQUOTA=1",);
        }
        elsif ( $OSNAME eq "darwin" ) {
            $self->darwin->install_port( "maildrop" );
        }
        $ver = "2.5.0";
    }

    $self->util->find_bin( "maildrop", fatal => 0 )
        or $self->util->install_from_source(
                package => 'maildrop-' . $ver,
                site    => 'http://' . $self->conf->{'toaster_sf_mirror'},
                url     => '/courier',
                targets => [
                    './configure --prefix=' . $prefix . ' --exec-prefix=' . $prefix,
                    'make',
                    'make install-strip',
                    'make install-man'
                ],
                source_sub_dir => 'mail',
            );

    my $etcmail = "$prefix/etc/mail";
    unless ( -d $etcmail ) {
        mkdir( $etcmail, oct('0755') )
          or $self->util->mkdir_system( dir => $etcmail, mode=>'0755' );
    }

    $self->maildrop_filter();
    $self->maildrop_imap_subscribe();
    $self->maildrop_filter_logs();
};

sub maildrop_filter {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $logbase = $self->conf->{'qmail_log_base'};

    if ( !$logbase ) {
        $logbase = -d "/var/log/qmail" ? "/var/log/qmail" : "/var/log/mail";
    }

    my $filterfile = $self->conf->{'filtering_maildrop_filter_file'}
      || "$prefix/etc/mail/mailfilter";

    my ( $path, $file ) = $self->util->path_parse($filterfile);

    $self->util->mkdir_system( dir => $path )  if ! -d $path;

    return $self->error( "$path doesn't exist and I couldn't create it.")
        if ! -d $path;

    my @lines = $self->maildrop_filter_file( logbase => $logbase );

    my $user  = $self->conf->{'vpopmail_user'}  || "vpopmail";
    my $group = $self->conf->{'vpopmail_group'} || "vchkpw";

    # if the mailfilter file doesn't exist, create it
    if ( -e $filterfile ) {
        $self->util->file_write( "$filterfile.new", lines => \@lines, mode  =>'0600' );
        $self->util->install_if_changed(
            newfile  => "$filterfile.new",
            existing => $filterfile,
            mode     => '0600',
            clean    => 0,
            notify   => 1,
            archive  => 1,
        );
    }
    else {
        $self->util->file_write( $filterfile, lines => \@lines, mode  => '0600' );
        $self->audit("installed new $filterfile, ok");
    };

    $self->util->chown( $filterfile, uid => $user, gid => $group );

    $file = "/etc/newsyslog.conf";
    if ( -e $file  && ! `grep maildrop $file`) {
        $self->util->file_write( $file,
            lines =>
            ["/var/log/mail/maildrop.log $user:$group 644	3	1000 *	Z"],
            append => 1,
        );
    };
    return 1;
}

sub maildrop_filter_file {
    my $self  = shift;
    my %p = validate( @_, { 'logbase' => SCALAR, $self->get_std_opts, },);

    my $logbase = $p{'logbase'};

    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $filterfile = $self->conf->{'filtering_maildrop_filter_file'}
      || "$prefix/etc/mail/mailfilter";

    my @lines = 'SHELL="/bin/sh"';
    push @lines, <<"EOMAILDROP";
import EXT
import HOST
VHOME=`pwd`
TIMESTAMP=`date "+\%b \%d \%H:\%M:\%S"`

##
#  title:  mailfilter-site
#  author: Matt Simerson
#  version 2.17
#
#  This file is automatically generated by toaster_setup.pl,
#  DO NOT HAND EDIT, your changes may get overwritten!
#
#  Make changes to toaster-watcher.conf, and run
#  toaster_setup.pl -s maildrop to rebuild this file. Old versions
#  are preserved as $filterfile.timestamp
#
#  Usage: Install this file in your local etc/mail/mailfilter. On
#  your system, this is $prefix/etc/mail/mailfilter
#
#  Create a .qmail file in each users Maildir as follows:
#  echo "| $prefix/bin/maildrop $prefix/etc/mail/mailfilter" \
#      > ~vpopmail/domains/example.com/user/.qmail
#
#  You can also use qmailadmin v1.0.26 or higher to do that for you
#  via it is --enable-modify-spam and --enable-spam-command options.
#  This is the default behavior for your Mail::Toaster.
#
# Environment Variables you can import from qmail-local:
#  SENDER  is  the envelope sender address
#  NEWSENDER is the forwarding envelope sender address
#  RECIPIENT is the envelope recipient address, local\@domain
#  USER is user
#  HOME is your home directory
#  HOST  is the domain part of the recipient address
#  LOCAL is the local part
#  EXT  is  the  address extension, ext.
#  HOST2 is the portion of HOST preceding the last dot
#  HOST3 is the portion of HOST preceding the second-to-last dot
#  HOST4 is the portion of HOST preceding the third-to-last dot
#  EXT2 is the portion of EXT following the first dash
#  EXT3 is the portion following the second dash;
#  EXT4 is the portion following the third dash.
#  DEFAULT  is  the  portion corresponding to the default part of the .qmail-... file name
#  DEFAULT is not set if the file name does not end with default
#  DTLINE  and  RPLINE are the usual Delivered-To and Return-Path lines, including newlines
#
# qmail-local will be calling maildrop. The exit codes that qmail-local
# understands are:
#     0 - delivery is complete
#   111 - temporary error
#   xxx - unknown failure
##
EOMAILDROP

    $self->conf->{'filtering_verbose'} ? push @lines, qq{logfile "$logbase/maildrop.log"}
                               : push @lines, qq{#logfile "$logbase/maildrop.log"};

    push @lines, <<'EOMAILDROP2';
log "$TIMESTAMP - BEGIN maildrop processing for $EXT@$HOST ==="

# I have seen cases where EXT or HOST is unset. This can be caused by
# various blunders committed by the sysadmin so we should test and make
# sure things are not too messed up.
#
# By exiting with error 111, the error will be logged, giving an admin
# the chance to notice and fix the problem before the message bounces.

if ( $EXT eq "" )
{
        log "  FAILURE: EXT is not a valid value"
        log "=== END ===  $EXT@$HOST failure (EXT variable not imported)"
        EXITCODE=111
        exit
}

if ( $HOST eq "" )
{
        log "  FAILURE: HOST is not a valid value"
        log "=== END ===  $EXT@$HOST failure (HOST variable not imported)"
        EXITCODE=111
        exit
}

EOMAILDROP2

    my $spamass_method = $self->conf->{'filtering_spamassassin_method'};

    if ( $spamass_method eq "user" || $spamass_method eq "domain" ) {

        push @lines, <<"EOMAILDROP3";
##
# Note that if you want to pass a message larger than 250k to spamd
# and have it processed, you will need to also set spamc -s. See the
# spamc man page for more details.
##

exception {
	if ( /^X-Spam-Status: /:h )
	{
		# do not pass through spamassassin if the message already
		# has an X-Spam-Status header.

		log "Message already has X-Spam-Status header, skipping spamc"
	}
	else
	{
		if ( \$SIZE < 256000 ) # Filter if message is less than 250k
		{
			`test -x $prefix/bin/spamc`
			if ( \$RETURNCODE == 0 )
			{
				log `date "+\%b \%d \%H:\%M:\%S"`" \$PID - running message through spamc"
				exception {
					xfilter '$prefix/bin/spamc -u "\$EXT\@\$HOST"'
				}
			}
			else
			{
				log "   WARNING: no $prefix/bin/spamc binary!"
			}
		}
	}
}
EOMAILDROP3

    }

    push @lines, <<"EOMAILDROP4";
##
# Include any rules set up for the user - this gives the
# administrator a way to override the sitewide mailfilter file
#
# this is also the "suggested" way to set individual values
# for maildrop such as quota.
##

`test -r \$VHOME/.mailfilter`
if( \$RETURNCODE == 0 )
{
	log "   including \$VHOME/.mailfilter"
	exception {
		include \$VHOME/.mailfilter
	}
}

##
# create the maildirsize file if it does not already exist
# (could also be done via "deliverquota user\@dom.com 10MS,1000C)
##

`test -e \$VHOME/Maildir/maildirsize`
if( \$RETURNCODE == 1)
{
	VUSERINFO="$prefix/vpopmail/bin/vuserinfo"
	`test -x \$VUSERINFO`
	if ( \$RETURNCODE == 0)
	{
		log "   creating \$VHOME/Maildir/maildirsize for quotas"
		`\$VUSERINFO -Q \$EXT\@\$HOST`

		`test -s "\$VHOME/Maildir/maildirsize"`
   		if ( \$RETURNCODE == 0 )
   		{
     			`/usr/sbin/chown vpopmail:vchkpw \$VHOME/Maildir/maildirsize`
				`/bin/chmod 640 \$VHOME/Maildir/maildirsize`
		}
	}
	else
	{
		log "   WARNING: cannot find vuserinfo! Please edit mailfilter"
	}
}

EOMAILDROP4

    my $head = $self->util->find_bin( 'head' );

    push @lines, <<"EOMAILDROP5";
##
# Set MAILDIRQUOTA. If this is not set, maildrop and deliverquota
# will not enforce quotas for message delivery.
##

`test -e \$VHOME/Maildir/maildirsize`
if( \$RETURNCODE == 0)
{
	MAILDIRQUOTA=`$head -n1 \$VHOME/Maildir/maildirsize`
}

# if the user does not have a Spam folder, create it.

`test -d \$VHOME/Maildir/.Spam`
if( \$RETURNCODE == 1 )
{

    MAILDIRMAKE="$prefix/bin/maildirmake"
    `test -x \$MAILDIRMAKE`
    if ( \$RETURNCODE == 1 )
    {
        MAILDIRMAKE="$prefix/bin/maildrop-maildirmake"
        `test -x \$MAILDIRMAKE`
    }

    if ( \$RETURNCODE == 1 )
    {
        log "   WARNING: no maildirmake!"
    }
    else
    {
        log "   creating \$VHOME/Maildir/.Spam "
        `\$MAILDIRMAKE -f Spam \$VHOME/Maildir`
        `$prefix/sbin/subscribeIMAP.sh Spam \$VHOME`
    }
}

##
# The message should be tagged, so lets bag it.
##
# HAM:  X-Spam-Status: No, score=-2.6 required=5.0
# SPAM: X-Spam-Status: Yes, score=8.9 required=5.0
#
# Note: SA < 3.0 uses "hits" instead of "score"
#
# if ( /^X-Spam-Status: *Yes/)  # test if spam status is yes
# The following regexp matches any spam message and sets the
# variable \$MATCH2 to the spam score.

if ( /X-Spam-Status: Yes/:h)
{
    if ( /X-Spam-Status: Yes, (hits|score)=([\\d\\.\\-]+)\\s/:h)
    {
EOMAILDROP5

    my $discard   = $self->conf->{'filtering_spama_discard_score'};
    my $pyzor     = $self->conf->{'filtering_report_spam_pyzor'};
    my $sa_report = $self->conf->{'filtering_report_spam_spamassassin'};

    if ($discard) {

        push @lines, <<"EOMAILDROP6";
	# if the message scored a $discard or higher, then there is no point in
	# keeping it around. SpamAssassin already knows it as spam, and
	# has already "autolearned" from it if you have that enabled. The
	# end user likely does not want it. If you wanted to cc it, or
	# deliver it elsewhere for inclusion in a spam corpus, you could
	# easily do so with a cc or xfilter command

        if ( \$MATCH2 >= $discard )   # from Adam Senuik post to mail-toasters
        {
EOMAILDROP6

        if ( $pyzor && !$sa_report ) {

            push @lines, <<"EOMAILDROP7";
            `test -x $prefix/bin/pyzor`
            if( \$RETURNCODE == 0 )
            {
                # if the pyzor binary is installed, report all messages with
                # high spam scores to the pyzor servers

                log "   SPAM: score \$MATCH2: reporting to Pyzor"
                exception {
                    xfilter "$prefix/bin/pyzor report"
                }
            }
EOMAILDROP7
        }

        if ($sa_report) {

            push @lines, <<"EOMAILDROP8";

            # new in version 2.5 of Mail::Toaster mailfiter
            `test -x $prefix/bin/spamassassin`
            if( \$RETURNCODE == 0 )
            {
                # if the spamassassin binary is installed, report messages with
                # high spam scores to spamassassin (and consequently pyzor, dcc,
                # razor, and SpamCop)

                log "   SPAM: score \$MATCH2: reporting spam via spamassassin -r"
                exception {
                    xfilter "$prefix/bin/spamassassin -r"
                }
            }
EOMAILDROP8
        }

        push @lines, <<"EOMAILDROP9";
                log "   SPAM: score \$MATCH2 exceeds $discard: nuking message!"
                log "=== END === \$EXT\@\$HOST success (discarded)"
                EXITCODE=0
                exit
            }
EOMAILDROP9
    }

    push @lines, <<"EOMAILDROP10";
        log "   SPAM: score \$MATCH2: delivering to \$VHOME/Maildir/.Spam"
        log "=== END ===  \$EXT\@\$HOST success"
        exception {
            to "\$VHOME/Maildir/.Spam"
        }
    }
    else
    {
        log "   SpamAssassin regexp match error!"
    }
}

if ( /^X-Spam-Status: No, (score|hits)=([\\d\\.\\-]+)\\s/:h)
{
    log "   message is SA clean (\$MATCH2)"
}

EOMAILDROP10

if ( $self->conf->{install_dspam} ) {

    push @lines, <<"EOMAILDROP_DSPAM";
if ( /^X-DSPAM-Result: /:h )
{
    log "   has X-DSPAM-Result header"
}
else
{
    if ( \$SIZE < 4194304 ) # Filter if message is less than 4MB
    {
        `test -x $prefix/bin/dspam`
        if ( \$RETURNCODE == 0 )
        {
            log `date "+\%b \%d \%H:\%M:\%S"`" \$PID - running message through dspam"
            exception {
                xfilter '$prefix/bin/dspam --user \$EXT\@\$HOST --process --deliver=innocent,spam --stdout'
            }
        }
        else
        {
            log "   WARNING: no $prefix/bin/dspam binary!"
        }
    }
}

##
# Check for DSPAM tag
##
# HAM:  X-DSPAM-Result: Innocent, probability=0.0000, confidence=0.94
# SPAM: X-DSPAM-Result: Spam, probability=1.0000, confidence=0.99
#

if ( /X-DSPAM-Result: /:h)
{
    if ( /X-DSPAM-Result: Spam/:h)
    {
        if ( /X-DSPAM-Result: Spam, probability=([\\d\\.]+), confidence=([\\d\\.]+)/:h)
        {
            if ( \$MATCH1 == 1 && \$MATCH2 >= .50 )
            {
                if ( /^X-Spam-Status: /:h )
                {
                    if ( /X-Spam-Status: Yes/:h)
                    {
                        log "   DSPAM: delivering spam (\$MATCH2) to \$VHOME/Maildir/.Spam"
                        log "=== END ===  \$EXT\@\$HOST success"
                        exception {
                            to "\$VHOME/Maildir/.Spam"
                        }
                    }
                    else
                    {
                        log "   DSPAM says spam (\$MATCH2) SA says no"
                    }
                }
            }
            else
            {
                log "   DSPAM suspects spam (\$MATCH2)"
            }
        }
        else
        {
            log "   DSPAM regexp match error!"
        }
    }
    else
    {
        log "   dspam says innocent"
    }
}

EOMAILDROP_DSPAM
;
};

    push @lines, <<"EOMAILDROP11";
##
# Include any other rules that the user might have from
# sqwebmail or other compatible program
##

`test -r \$VHOME/Maildir/.mailfilter`
if( \$RETURNCODE == 0 )
{
	log "   including \$VHOME/Maildir/.mailfilter"
	exception {
		include \$VHOME/Maildir/.mailfilter
	}
}

`test -r \$VHOME/Maildir/mailfilter`
if( \$RETURNCODE == 0 )
{
	log "   including \$VHOME/Maildir/mailfilter"
	exception {
		include \$VHOME/Maildir/mailfilter
	}
}

log "   delivering to \$VHOME/Maildir"

# make sure the deliverquota binary exists and is executable
# if not, then we cannot enforce quotas. If we do not check
# and the binary is missing, maildrop silently discards mail.

DELIVERQUOTA="$prefix/bin/deliverquota"
`test -x \$DELIVERQUOTA`
if ( \$RETURNCODE == 1 )
{
	DELIVERQUOTA="$prefix/bin/maildrop-deliverquota"
    `test -x \$DELIVERQUOTA`
}

if ( \$RETURNCODE == 1 )
{
    log "   WARNING: no deliverquota!"
    log "=== END ===  \$EXT\@\$HOST success"
    exception {
        to "\$VHOME/Maildir"
    }
}
else
{
	exception {
		xfilter "\$DELIVERQUOTA -w 90 \$VHOME/Maildir"
	}

	##
	# check to make sure the message was delivered
	# returncode 77 means that out maildir was overquota - bounce mail
	##
	if( \$RETURNCODE == 77)
	{
		#log "   BOUNCED: bouncesaying '\$EXT\@\$HOST is over quota'"
		log "=== END ===  \$EXT\@\$HOST  bounced"
		to "|/var/qmail/bin/bouncesaying '\$EXT\@\$HOST is over quota'"
	}
	else
	{
		log "=== END ===  \$EXT\@\$HOST  success (quota)"
		EXITCODE=0
		exit
	}
}

log "WARNING: This message should never be printed!"
EOMAILDROP11

    return @lines;
}

sub maildrop_filter_logs {
    my $self = shift;

    my $log = $self->conf->{'qmail_log_base'} || "/var/log/mail";

    $self->util->mkdir_system( dir => $log, verbose => 0 ) if ! -d $log;

    $self->util->chown( $log,
        uid   => $self->conf->{'qmail_log_user'}  || 'qmaill',
        gid   => $self->conf->{'qmail_log_group'} || 'qnofiles',
        sudo  => $UID == 0 ? 0 : 1,
    );

    my $logf = "$log/maildrop.log";

    $self->util->file_write( $logf, lines => ["begin"] ) if ! -e $logf;

    $self->util->chown( $logf,
        uid   => $self->conf->{'vpopmail_user'}  || "vpopmail",
        gid   => $self->conf->{'vpopmail_group'} || "vchkpw",
        sudo  => $UID == 0 ? 0 : 1,
    );
}

sub maildrop_imap_subscribe {
    my $self = shift;
    my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $sub_file = "$prefix/sbin/subscribeIMAP.sh";

    my $sub_bin = $self->util->find_bin( "$prefix/sbin/subscribeIMAP.sh", verbose => 0, fatal => 0 );
    return 1 if ( $sub_bin && -e $sub_bin );

    my $chown = $self->util->find_bin( 'chown' );
    my $chmod = $self->util->find_bin( 'chmod' );

    my @lines = '#!/bin/sh
#
# This subscribes the folder passed as $1 to courier imap
# so that Maildir reading apps (Sqwebmail, Courier-IMAP) and
# IMAP clients (squirrelmail, Mailman, etc) will recognize the
# extra mail folder.

# Matt Simerson - 12 June 2003

LIST="$2/Maildir/courierimapsubscribed"

if [ -f "$LIST" ]; then
	# if the file exists, check it for the new folder
	TEST=`cat "$LIST" | grep "INBOX.$1"`

	# if it is not there, add it
	if [ "$TEST" = "" ]; then
		echo "INBOX.$1" >> $LIST
	fi
else
	# the file does not exist so we define the full list
	# and then create the file.
	FULL="INBOX\nINBOX.Sent\nINBOX.Trash\nINBOX.Drafts\nINBOX.$1"

	echo -e $FULL > $LIST
	' . $chown . ' vpopmail:vchkpw $LIST
	' . $chmod . ' 644 $LIST
fi
';

    $self->util->file_write( $sub_file, lines => \@lines );

    $self->util->chmod(
        file_or_dir => $sub_file,
        mode        => '0555',
        sudo        => $UID == 0 ? 0 : 1,
    );
};

sub maillogs {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    my %args = $self->get_std_args( %p );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $user  = $self->conf->{'qmail_log_user'}  || "qmaill";
    my $group = $self->conf->{'qmail_log_group'} || "qnofiles";
    my $logdir = $self->conf->{'qmail_log_base'} || "/var/log/mail";

    my $uid = getpwnam($user);
    my $gid = getgrnam($group);

    return $self->error( "The user $user or group $group does not exist." )
        unless ( defined $uid && defined $gid );

    $self->toaster->supervise_dirs_create( verbose=>1 );
    $self->maillogs_create_dirs();

    my $maillogs = $self->util->find_bin( 'maillogs', verbose => 0);

    my @multilogs = ( "$logdir/send/sendlog", "$logdir/smtp/smtplog",
                      "$logdir/pop3/pop3log" );

    foreach my $processor ( @multilogs  ) {
        my $r = $self->util->install_if_changed(
            newfile  => $maillogs,
            existing => $processor,
            uid      => $uid,
            gid      => $gid,
            mode     => '0755',
            clean    => 0,
        ) or next;

        $r = $r == 1 ? "ok" : "ok (same)";
        $self->audit( "maillogs: update $processor, $r", verbose=>1);
    };

    $self->cronolog();
    $self->isoqlog();

    $self->logs->verify_settings();
}

sub maillogs_create_dirs {
    my $self = shift;

    my $user  = $self->conf->{'qmail_log_user'}  || "qmaill";
    my $group = $self->conf->{'qmail_log_group'} || "qnofiles";
    my $uid = getpwnam($user);
    my $gid = getgrnam($group);

    # if it exists, make sure it's owned by qmail:qnofiles
    my $logdir = $self->conf->{'qmail_log_base'} || "/var/log/mail";
    if ( -w $logdir ) {
        chown( $uid, $gid, $logdir )
            or $self->error( "Couldn't chown $logdir to $uid: $!");
        $self->audit( "maillogs: set ownership of $logdir to $user",verbose=>1 );
    }

    if ( ! -d $logdir ) {
        mkdir( $logdir, oct('0755') )
            or $self->error( "maillogs: couldn't create $logdir: $!" );
        chown( $uid, $gid, $logdir )
            or $self->error( "maillogs: couldn't chown $logdir: $!");
        $self->audit( "maillogs: created $logdir", verbose=>1 );
    }

    foreach my $prot (qw/ send smtp pop3 submit /) {
        my $dir = "$logdir/$prot";
        if ( -d $dir ) {
            $self->audit( "maillogs: create $dir, (exists)", verbose=>1 );
        }
        else {
            mkdir( $dir, oct('0755') )
              or $self->error( "maillogs: couldn't create $dir: $!" );
            $self->audit( "maillogs: created $dir", verbose=>1);
        }
        chown( $uid, $gid, $dir )
          or $self->error( "maillogs: chown $dir failed: $!");
    }
};

sub mrm {

    my $self  = shift;
    my $verbose = $self->{'verbose'};

    my %p = validate( @_, {
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'verbose'   => { type => BOOLEAN, optional => 1, default => $verbose },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $verbose = $p{'verbose'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $perlbin = $self->util->find_bin( "perl" );

    my @targets = ( "$perlbin Makefile.PL", "make", "make install" );
    push @targets, "make test" if $verbose;

    $self->util->install_module_from_src(
        'Mysql-Replication',
        archive => 'Mysql-Replication.tar.gz',
        url     => '/internet/sql/mrm',
        targets => \@targets,
    );
}

sub munin {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{install_munin} ) {
        $self->audit("skipping munin install (disabled)");
        return;
    };

    $self->rrdtool();

    return $self->audit("no munin install support for $OSNAME")
        if $OSNAME ne 'freebsd';

    $self->freebsd->install_port('p5-Date-Manip');
    $self->munin_node();
    $self->freebsd->install_port('munin-master');

    return 1;
};

sub munin_node {
    my $self = shift;

    $self->freebsd->install_port('munin-node');
    $self->freebsd->conf_check(
        check => "munin_node_enable",
        line  => 'munin_node_enable="YES"',
    );

    my $locals = '';
    foreach ( @{ $self->util->get_my_ips( exclude_internals => 0 ) } ) {
        my ($a,$b,$c,$d) = split( /\./, $_ );
        $locals .= "allow ^$a\\.$b\\.$c\\.$d" . '$';
    };

    my $munin_etc = '/usr/local/etc/munin';
    $self->config_apply_tweaks(
        file => "$munin_etc/munin-node.conf",
        changes => [
            {   search => q{allow ^127\.0\.0\.1$},
                replace => q{allow ^127\.0\.0\.1$} . qq{\n$locals\n},
            }
        ],
    );

    $self->util->file_write( "$munin_etc/plugin-conf.d/plugins.conf",
        append => 1,
        lines => [ "\n[qmailqstat]\nuser qmails\nenv.qmailstat /var/qmail/bin/qmail-qstat"],
    ) if ! `grep qmailqstat "$munin_etc/plugin-conf.d/plugins.conf"`;

    my @setup_links = `/usr/local/sbin/munin-node-configure --suggest --shell`;
       @setup_links = grep {/^ln/} @setup_links;
       @setup_links = grep {!/sendmail_/} @setup_links;
       @setup_links = grep {!/ntp_/} @setup_links;

    foreach ( @setup_links ) { system $_; };

    my $t_ver = $Mail::Toaster::VERSION;
    my $dist = "/usr/local/src/Mail-Toaster-$t_ver";
    if ( -d $dist ) {
        my @plugins = qw/ qmail_rbl spamassassin /;
        foreach ( @plugins ) {
            copy("$dist/contrib/munin/$_", "$munin_etc/plugins" );
            chmod oct('0755'), "$munin_etc/plugins/$_";
        };
        copy ("$dist/contrib/logtail", "/usr/local/bin/logtail");
        chmod oct('0755'), "/usr/local/bin/logtail";
    };

    system "/usr/local/etc/rc.d/munin-node", "restart";
};

sub mysql {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{install_mysql} ) {
        $self->audit("skipping mysql install (disabled)");
        return;
    };

    return $self->mysql->install( verbose => $p{verbose} );
}

sub nictool {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts, },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    $self->conf->{'install_expat'} = 1;    # this must be set for expat to install

    $self->expat();
    $self->rsync();
    $self->djbdns();
    $self->mysql();

    # make sure these perl modules are installed
    $self->util->install_module( "LWP::UserAgent", port => 'p5-libwww' );
    $self->util->install_module( "SOAP::Lite");
    $self->util->install_module( "RPC::XML" );
    $self->util->install_module( "DBI" );
    $self->util->install_module( "DBD::mysql" );

    if ( $OSNAME eq "freebsd" ) {
        if ( $self->conf->{'install_apache'} == 2 ) {
            $self->freebsd->install_port( "p5-Apache-DBI", flags => "WITH_MODPERL2=yes",);
        }
    }

    $self->util->install_module( "Apache::DBI" );
    $self->util->install_module( "Apache2::SOAP" );

    # install NicTool Server
    my $perlbin   = $self->util->find_bin( "perl", fatal => 0 );
    my $version   = "NicToolServer-2.06";
    my $http_base = $self->conf->{'toaster_http_base'};

    my @targets = ( "$perlbin Makefile.PL", "make", "make install" );

    push @targets, "make test";

    push @targets, "mv ../$version $http_base"
      unless ( -d "$http_base/$version" );

    push @targets, "ln -s $http_base/$version $http_base/NicToolServer"
      unless ( -l "$http_base/NicToolServer" );

    $self->util->install_module_from_src( $version,
        archive => "$version.tar.gz",
        site    => 'http://www.nictool.com',
        url     => '/download/',
        targets => \@targets,
    );

    # install NicTool Client
    $version = "NicToolClient-2.06";
    @targets = ( "$perlbin Makefile.PL", "make", "make install" );
    push @targets, "make test";

    push @targets, "mv ../$version $http_base" if ( !-d "$http_base/$version" );
    push @targets, "ln -s $http_base/$version $http_base/NicToolClient"
      if ( !-l "$http_base/NicToolClient" );

    $self->util->install_module_from_src( $version,
        archive => "$version.tar.gz",
        site    => 'http://www.nictool.com',
        url     => '/download/',
        targets => \@targets,
    );
}

sub openssl_cert {
    my $self = shift;

    my $dir = "/usr/local/openssl/certs";
    my $csr = "$dir/server.csr";
    my $crt = "$dir/server.crt";
    my $key = "$dir/server.key";
    my $pem = "$dir/server.pem";

    $self->util->mkdir_system(dir=>$dir, verbose=>0) if ! -d $dir;

    my $openssl = $self->util->find_bin('openssl', verbose=>0);
    system "$openssl genrsa 1024 > $key" if ! -e $key;
    $self->error( "ssl cert key generation failed!") if ! -e $key;

    system "$openssl req -new -key $key -out $csr" if ! -e $csr;
    $self->error( "cert sign request ($csr) generation failed!") if ! -e $csr;

    system "$openssl req -x509 -days 999 -key $key -in $csr -out $crt" if ! -e $crt;
    $self->error( "cert generation ($crt) failed!") if ! -e $crt;

    system "cat $key $crt > $pem" if ! -e $pem;
    $self->error( "pem generation ($pem) failed!") if ! -e $pem;

    return 1;
};

sub openssl_conf {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts, },);
    return $p{test_ok} if defined $p{test_ok};

    if ( !$self->conf->{'install_openssl'} ) {
        $self->audit( "openssl: configuring, skipping (disabled)" );
        return;
    }

    return if ( defined $self->conf->{'install_openssl_conf'}
                    && !$self->conf->{'install_openssl_conf'} );

    # make sure openssl libraries are available
    $self->openssl_install();

    my $sslconf = $self->openssl_conf_find_config();

    # get/set the settings to alter
    my $country  = $self->conf->{'ssl_country'}      || "US";
    my $state    = $self->conf->{'ssl_state'}        || "Texas";
    my $org      = $self->conf->{'ssl_organization'} || "DisOrganism, Inc.";
    my $locality = $self->conf->{'ssl_locality'}     || "Dallas";
    my $name     = $self->conf->{'ssl_common_name'}  || $self->conf->{'toaster_hostname'}
      || "mail.example.com";
    my $email = $self->conf->{'ssl_email_address'}   || $self->conf->{'toaster_admin_email'}
      || "postmaster\@example.com";

    # update openssl.cnf with our settings
    my $inside;
    my $discard;
    my @lines = $self->util->file_read( $sslconf, verbose=>0 );
    foreach my $line (@lines) {

        next if $line =~ /^#/;    # comment lines
        $inside++ if ( $line =~ /req_distinguished_name/ );
        next unless $inside;
        $discard++ if ( $line =~ /emailAddress_default/ && $line !~ /example\.com/ );

        $line = "countryName_default\t\t= $country"
            if $line =~ /^countryName_default/;
        $line = "stateOrProvinceName_default\t= $state"
            if $line =~ /^stateOrProvinceName_default/;
        $line = "localityName\t\t\t= Locality Name (eg, city)\nlocalityName_default\t\t= $locality" if $line =~ /^localityName\s+/;

        $line = "0.organizationName_default\t= $org"
            if $line =~ /^0.organizationName_default/;
        $line = "commonName_max\t\t\t= 64\ncommonName_default\t\t= $name"
            if $line =~ /^commonName_max/;
        $line = "emailAddress_max\t\t= 64\nemailAddress_default\t\t= $email"
            if $line =~ /^emailAddress_max/;
    }

    if ($discard) {
        $self->audit( "openssl: updating $sslconf, ok (no change)" );
        return 2;
    }

    my $tmpfile = "/tmp/openssl.cnf";
    $self->util->file_write( $tmpfile, lines => \@lines, verbose => 0 );
    $self->util->install_if_changed(
        newfile  => $tmpfile,
        existing => $sslconf,
        verbose    => 0,
    );

    return $self->openssl_cert();
}

sub openssl_conf_find_config {
    my $self = shift;

    # figure out where openssl.cnf is
    my $sslconf = "/etc/ssl/openssl.cnf";

    if ( $OSNAME eq "freebsd" ) {
        $sslconf = "/etc/ssl/openssl.cnf";   # built-in
        $self->openssl_conf_freebsd( $sslconf );
    }
    elsif ( $OSNAME eq "darwin" ) {
        $sslconf = "/System/Library/OpenSSL/openssl.cnf";
    }
    elsif ( $OSNAME eq "linux" ) {
        if ( ! -e $sslconf ) {
# centos (and probably RedHat/Fedora)
            $sslconf = "/etc/share/ssl/openssl.cnf";
        };
    }

    $self->error( "openssl: could not find your openssl.cnf file!") if ! -e $sslconf;
    $self->error( "openssl: no write permission to $sslconf!" ) if ! -w $sslconf;

    $self->audit( "openssl: found $sslconf, ok" );
    return $sslconf;
};

sub openssl_conf_freebsd {
    my $self = shift;
    my $conf = shift or return;

    if ( ! -e $conf && -e '/usr/local/openssl/openssl.cnf.sample' ) {
        mkpath "/etc/ssl";
        system "cp /usr/local/openssl/openssl.cnf.sample $conf";
    };

    if ( -d "/usr/local/openssl" ) {
        if ( ! -e "/usr/local/openssl/openssl.cnf" ) {
            symlink($conf, "/usr/local/openssl/openssl.cnf");
        };
    };
};

sub openssl_get_ciphers {
    my $self = shift;
    my $ciphers = shift;
    my $openssl = $self->util->find_bin( 'openssl', verbose=>0 );

    my $s = $ciphers eq 'all'    ? 'ALL'
        : $ciphers eq 'high'   ? 'HIGH:!SSLv2'
        : $ciphers eq 'medium' ? 'HIGH:MEDIUM:!SSLv2'
        : $ciphers eq 'pci'    ? 'DEFAULT:!ADH:!LOW:!EXP:!SSLv2:+HIGH:+MEDIUM'
        :                        'DEFAULT';
    $ciphers = `$openssl ciphers $s`;
    chomp $ciphers;
    return $ciphers;
};

sub openssl_install {
    my $self = shift;

    return if ! $self->conf->{'install_openssl'};

    if ( $OSNAME eq 'freebsd' ) {
        if (!$self->freebsd->is_port_installed( 'openssl' ) ) {
            $self->openssl_install_freebsd();
        };
    }
    else {
        my $bin = $self->util->find_bin('openssl',verbose=>0,fatal=>0);
        if ( ! $bin ) {
            warn "no openssl support for OS $OSNAME, please install manually.\n";
        }
        else {
            warn "using detected openssl on $OSNAME.\n";
        };
    };
};

sub openssl_install_freebsd {
    my $self = shift;

    return $self->freebsd->install_port( 'openssl',
        category=> 'security',
        options => "# This file is auto-generated by mail-toaster
# No user-servicable parts inside!
# Options for openssl-1.0.0_1
_OPTIONS_READ=openssl-1.0.0_1
WITHOUT_I386=true
WITH_SSE2=true
WITH_ASM=true
WITH_ZLIB=true
WITHOUT_MD2=true
WITHOUT_RC5=true
WITHOUT_RFC3779=true
WITHOUT_DTLS_BUGS=true
WITHOUT_DTLS_RENEGOTIATION=true
WITHOUT_DTLS_HEARTBEAT=true
WITHOUT_TLS_EXTRACTOR=true
WITHOUT_SCTP=true",
    );
};

sub periodic_conf {

    return if -e "/etc/periodic.conf";

    open my $PERIODIC, '>>', '/etc/periodic.conf';
    print $PERIODIC '
#--periodic.conf--
# 210.backup-aliases
daily_backup_aliases_enable="NO"                       # Backup mail aliases

# 440.status-mailq
daily_status_mailq_enable="YES"                         # Check mail status
daily_status_mailq_shorten="NO"                         # Shorten output
daily_status_include_submit_mailq="NO"                 # Also submit queue

# 460.status-mail-rejects
daily_status_mail_rejects_enable="NO"                  # Check mail rejects
daily_status_mail_rejects_logs=3                        # How many logs to check
#-- end --
';
    close $PERIODIC;
}

sub pop3_test_auth {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my @features;

    $OUTPUT_AUTOFLUSH = 1;

    my $r = $self->util->install_module( "Mail::POP3Client", verbose => 0,);
    $self->toaster->test("checking Mail::POP3Client", $r );
    if ( ! $r ) {
        print "skipping POP3 tests\n";
        return;
    };

    my %auths = (
        'POP3'          => { type => 'PASS',     descr => 'plain text' },
        'POP3-APOP'     => { type => 'APOP',     descr => 'APOP' },
        'POP3-CRAM-MD5' => { type => 'CRAM-MD5', descr => 'CRAM-MD5' },
        'POP3-SSL'      => { type => 'PASS', descr => 'plain text', ssl => 1 },
        'POP3-SSL-APOP' => { type => 'APOP', descr => 'APOP', ssl => 1 },
        'POP3-SSL-CRAM-MD5' => { type => 'CRAM-MD5', descr => 'CRAM-MD5', ssl => 1 },
    );

    foreach ( sort keys %auths ) {
        $self->pop3_auth( $_, $auths{$_} );
    }

    return 1;
}

sub pop3_auth {
    my $self = shift;
    my ( $name, $v ) = @_;

    my $type  = $v->{'type'};
    my $descr = $v->{'descr'};

    my $user = $self->conf->{'toaster_test_email'}        || 'test2@example.com';
    my $pass = $self->conf->{'toaster_test_email_pass'}   || 'cHanGeMe';
    my $host = $self->conf->{'pop3_ip_address_listen_on'} || 'localhost';
    $host = "localhost" if ( $host =~ /system|qmail|all/i );

    my $pop = Mail::POP3Client->new(
        HOST      => $host,
        AUTH_MODE => $type,
        USESSL    => $v->{ssl} ? 1 : 0,
    );

    $pop->User($user);
    $pop->Pass($pass);
    $pop->Connect() >= 0 || warn $pop->Message();
    $self->toaster->test( "  $name authentication", ($pop->State() eq "TRANSACTION"));

    if ( my @features = $pop->Capa() ) {
        #print "  POP3 server supports: " . join( ",", @features ) . "\n";
    }
    $pop->Close;
}

sub php {
    my $self = shift;

    if ( $OSNAME eq 'freebsd' ) {
        return $self->php_freebsd();
    };

    my $php = $self->util->find_bin('php',fatal=>0);
    $self->error( "no php install support for $OSNAME yet, and php is not installed. Please install and try again." );
    return;
};

sub php_freebsd {
    my $self = shift;

    my $apache = $self->conf->{install_apache} ? 'WITH' : 'WITHOUT';

    $self->freebsd->install_port( "php5",
        category=> 'lang',
        options => "#\n# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for php5-5.3.2_1
_OPTIONS_READ=php5-5.3.2_1
WITH_CLI=true
WITH_CGI=true
${apache}_APACHE=true
WITHOUT_DEBUG=true
WITH_SUHOSIN=true
WITHOUT_MULTIBYTE=true
WITH_IPV6=true
WITHOUT_MAILHEAD=true
WITHOUT_LINKTHR=true\n",
    ) or return;

    my $config = "/usr/local/etc/php.ini";
    if ( ! -e $config ) {
        copy("$config-production", $config) if -e "$config-production";
        chmod oct('0644'), $config;

        $self->config_apply_tweaks(
            file => "/usr/local/etc/php.ini",
            changes => [
                {   search  => q{;include_path = ".:/php/includes"},
                    replace => q{include_path = ".:/usr/local/share/pear"},
                },
            ],
        );
    };

    return 1 if -f $config;
    return;
};

sub phpmyadmin {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    unless ( $self->conf->{'install_phpmyadmin'} ) {
        print "phpMyAdmin install disabled. Set install_phpmyadmin in "
            . "toaster-watcher.conf if you want to install it.\n";
        return 0;
    }

    # prevent t1lib from installing X11
    if ( $OSNAME eq "freebsd" ) {
        $self->php();
        $self->freebsd->install_port( "t1lib", flags => "WITHOUT_X11=yes" );
        $self->freebsd->install_port( "php5-gd" );
    }

    $self->mysql->phpmyadmin_install;
}

sub portmaster {
    my $self = shift;

    if ( ! $self->conf->{install_portmaster} ) {
        $self->audit("install portmaster skipped, not selected", verbose=>1);
        return;
    };

    $self->freebsd->install_port( "portmaster" );
};

sub ports {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $self->freebsd->update_ports() if $OSNAME eq "freebsd";
    return $self->darwin->update_ports()  if $OSNAME eq "darwin";

    print "Sorry, no ports support for $OSNAME yet.\n";
    return;
}

sub qmailadmin {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $ver = $self->conf->{'install_qmailadmin'} or do {
        $self->audit( "skipping qmailadmin install, it's not selected!");
        return;
    };

    my $package = "qmailadmin-$ver";
    my $site    = "http://" . $self->conf->{'toaster_sf_mirror'};
    my $url     = "/qmailadmin/qmailadmin-stable/$ver";

    my $toaster = "$self->conf->{'toaster_dl_site'}$self->conf->{'toaster_dl_url'}";
    $toaster ||= "http://mail-toaster.org";

    my $cgi     = $self->conf->{'qmailadmin_cgi-bin_dir'};

    unless ( $cgi && -e $cgi ) {
        $cgi = $self->conf->{'toaster_cgi_bin'};
        mkpath $cgi if ! -e $cgi;

        unless ( $cgi && -e $cgi ) {
            my $httpdir = $self->conf->{'toaster_http_base'} || "/usr/local/www";
            $cgi = "$httpdir/cgi-bin";
            $cgi = "$httpdir/cgi-bin.mail" if -d "$httpdir/cgi-bin.mail";
        }
    }

    my $docroot = $self->conf->{'qmailadmin_http_docroot'};
    unless ( $docroot && -e $docroot ) {
        $docroot = $self->conf->{'toaster_http_docs'};
        unless ( $docroot && -e $docroot ) {
            if ( -d "/usr/local/www/mail" ) {
                $docroot = "/usr/local/www/mail";
            }
            elsif ( -d "/usr/local/www/data/mail" ) {
                $docroot = "/usr/local/www/data/mail";
            }
            else { $docroot = "/usr/local/www/data"; }
        }
    }

    my ($help);
    $help++ if $self->conf->{'qmailadmin_help_links'};

    if ( $ver eq "port" ) {
        if ( $OSNAME ne "freebsd" ) {
            print
              "FAILURE: Sorry, no port install of qmailadmin (yet). Please edit
toaster-watcher.conf and select a version of qmailadmin to install.\n";
            return 0;
        }

        $self->qmailadmin_port_install();
        $self->qmailadmin_help() if $help;
        return 1;
    }

    my $conf_args;

    if ( -x "$cgi/qmailadmin" ) {
        return 0
          unless $self->util->yes_or_no(
            "qmailadmin is installed, do you want to reinstall?",
            timeout  => 60,
          );
    }

    if ( $self->conf->{'qmailadmin_domain_autofill'} ) {
        $conf_args = " --enable-domain-autofill=Y";
        print "domain autofill: yes\n";
    }

    if ( $self->util->yes_or_no( "\nDo you want spam options? " ) ) {
        $conf_args .=
            " --enable-modify-spam=Y"
            . " --enable-spam-command=\""
            . $self->conf->{'qmailadmin_spam_command'} . "\"";
    }

    if ( $self->conf->{'qmailadmin_modify_quotas'} ) {
        $conf_args .= " --enable-modify-quota=y";
        print "modify quotas: yes\n";
    }

    if ( $self->conf->{'qmailadmin_install_as_root'} ) {
        $conf_args .= " --enable-vpopuser=root";
        print "install as root: yes\n";
    }

    $conf_args .= " --enable-htmldir=" . $docroot . "/qmailadmin";
    $conf_args .= " --enable-imagedir=" . $docroot . "/qmailadmin/images";
    $conf_args .= " --enable-imageurl=/qmailadmin/images";
    $conf_args .= " --enable-cgibindir=" . $cgi;
    $conf_args .= " --enable-autoresponder-path=".$self->conf->{'toaster_prefix'}."/bin";

    if ( defined $self->conf->{'qmailadmin_catchall'} ) {
        $conf_args .= " --disable-catchall" if ! $self->conf->{'qmailadmin_catchall'};
    };

    if ( $self->conf->{'qmailadmin_help_links'} ) {
        $conf_args .= " --enable-help=y";
        $help = 1;
    }

    if ( $OSNAME eq "darwin" ) {
        my $vpopdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
        $self->util->syscmd( "ranlib $vpopdir/lib/libvpopmail.a", verbose => 0 );
    }

    my $make = $self->util->find_bin( "gmake", fatal=>0, verbose=>0) ||
        $self->util->find_bin( "make", verbose=>0 );

    $self->util->install_from_source(
        package   => $package,
        site      => $site,
        url       => $url,
        targets   =>
          [ "./configure " . $conf_args, "$make", "$make install-strip" ],
        source_sub_dir => 'mail',
    );

    $self->qmailadmin_help() if $help;

    return 1;
}

sub qmailadmin_help {
    my $self = shift;

    my $ver     = $self->conf->{'qmailadmin_help_links'} or return;
    my $cgi     = $self->conf->{'qmailadmin_cgi-bin_dir'};
    my $docroot = $self->conf->{qmailadmin_http_docroot} || $self->conf->{toaster_http_docs};
    my $helpdir = $docroot . "/qmailadmin/images/help";

    if ( -d $helpdir ) {
        $self->audit( "qmailadmin: installing help files, ok (exists)" );
        return 1;
    }

    my $src  = $self->conf->{'toaster_src_dir'} || "/usr/local/src";
       $src .= "/mail";

    print "qmailadmin: Installing help files in $helpdir\n";
    $self->util->cwd_source_dir( $src );

    my $helpfile = "qmailadmin-help-$ver";
    unless ( -e "$helpfile.tar.gz" ) {
        my $url = "http://$self->conf->{toaster_sf_mirror}/qmailadmin/qmailadmin-help/$ver/$helpfile.tar.gz";
        print "qmailadmin: fetching helpfile tarball from $url.\n";
        $self->util->get_url( $url );
    }

    if ( !-e "$helpfile.tar.gz" ) {
        carp "qmailadmin: FAILED: help files couldn't be downloaded!\n";
        return;
    }

    $self->util->extract_archive( "$helpfile.tar.gz" );

    move( $helpfile, $helpdir ) or
        $self->error( "Could not move $helpfile to $helpdir");

    $self->audit( "qmailadmin: installed help files, ok" );
}

sub qmailadmin_port_install {
    my $self = shift;
    my $cgi = $self->conf->{qmailadmin_cgi_bin_dir} || $self->conf->{toaster_cgi_bin};
    my $docroot = $self->conf->{qmailadmin_http_docroot} || $self->conf->{toaster_http_docs};

    my ( @args, $cgi_sub, $docroot_sub );

    push @args, "WITH_DOMAIN_AUTOFILL=yes" if $self->conf->{'qmailadmin_domain_autofill'};
    push @args, "WITH_MODIFY_QUOTA=yes"    if $self->conf->{'qmailadmin_modify_quotas'};
    push @args, "WITH_HELP=yes" if $self->conf->{'qmailadmin_help_links'};
    if ( defined $self->conf->{'qmailadmin_catchall'} ) {
        push @args, "WITHOUT_CATCHALL=yes" if ! $self->conf->{'qmailadmin_catchall'};
    };
    push @args, 'CGIBINSUBDIR=""';

    if ( $cgi && $cgi =~ /\/usr\/local\/(.*)$/ ) {
        $cgi_sub = $1;
        chop $cgi_sub if $cgi_sub =~ /\/$/; # remove trailing /
        push @args, "CGIBINDIR=\"$cgi_sub\"";
    }

    if ( $docroot =~ /\/usr\/local\/(.*)$/ ) {
        chop $cgi_sub if $cgi_sub =~ /\/$/; # remove trailing /
        $docroot_sub = $1;
    }
    push @args, "WEBDATADIR=\"$docroot_sub\"";
    push @args, 'WEBDATASUBDIR="qmailadmin"';

    push @args, "QMAIL_DIR=\"$self->conf->{'qmail_dir'}\""
        if $self->conf->{'qmail_dir'} ne "/var/qmail";

    if ( $self->conf->{'qmailadmin_spam_option'} ) {
        push @args, "WITH_SPAM_DETECTION=yes";
        push @args, "SPAM_COMMAND=\"$self->conf->{'qmailadmin_spam_command'}\""
            if $self->conf->{'qmailadmin_spam_command'};
    }

    $self->freebsd->install_port( "qmailadmin", flags => join( ",", @args ) );

    if ( $self->conf->{'qmailadmin_install_as_root'} ) {
        my $gid = getgrnam("vchkpw");
        chown( 0, $gid, "/usr/local/$cgi_sub/qmailadmin" );
    }
}

sub qpsmtpd {
    my $self = shift;

# install Qmail::Deliverable
# install vpopmaild service

# install qpsmtpd
print '
- git clone https://github.com/qpsmtpd-dev/qpsmtpd-dev
- cp -r config.sample config
- chown smtpd:smtpd qpsmtpd
- chmod +s qpsmtpd
';

# install qpsmtpd service
print '
- services stop
- rm /var/service/smtp
- stop toaster-watcher and do previous step again
- ln -s /usr/local/src/qpsmtpd-dev/  /var/serivces/qpsmtpd
- cp /var/qmail/supervise/smtp/log/run log/run
';

# install qpsmtpd SSL certs
print '
- add clamav user to smtpd user group
- echo 0770 > config/spool_perms   # Hmmmm... quite open.. how did we do
this with current toaster? clamav needs to read vpopmail files
- echo /var/spool/clamd > spool_dir
- edits in config/plugins
  - disable: ident/geoip
  - disable: quit_fortune
  - enable: auth/auth_checkpassword
checkpw /usr/local/vpopmail/bin/vchkpw true /usr/bin/true
  - disable: auth/auth_flat_file
  - disable: dspam learn_from_sa 7 reject 1
  - enable: virus/clamdscan deny_viruses yes
clamd_socket /var/run/clamav/clamd.sock max_size 3072
  - enable: queue/qmail-queue
  - enable: sender_permitted_from
  - install Qmail::Deliverable
  - enable: qmail_deliverable
  - install clamav::client
- edit run file QPUSER=vpopmail
- services start
- clamdscan plugin modification:

# cat qmail-deliverable/run
#!/bin/sh
MAXRAM=50000000
BIN=/usr/local/bin
PATH=/usr/local/vpopmail/bin
exec $BIN/softlimit -m $MAXRAM $BIN/qmail-deliverabled -f 2>&1

# cat vpopmaild/run
#!/bin/sh
BIN=/usr/local/bin
VPOPDIR=/usr/local/vpopmail
exec 2>&1
exec $BIN/tcpserver -vHRD 127.0.0.1 89 $VPOPDIR/bin/vpopmaild
';

};

sub razor {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $ver = $self->conf->{'install_razor'} or do {
        $self->audit( "razor: installing, skipping (disabled)" );
        return;
    };

    return $p{test_ok} if defined $p{test_ok}; # for testing

    $self->util->install_module( "Digest::Nilsimsa" );
    $self->util->install_module( "Digest::SHA1" );

    if ( $ver eq "port" ) {
        if ( $OSNAME eq "freebsd" ) {
            $self->freebsd->install_port( "razor-agents" );
        }
        elsif ( $OSNAME eq "darwin" ) {
            # old ports tree, deprecated
            $self->darwin->install_port( "razor" );
            # this one should work
            $self->darwin->install_port( "p5-razor-agents" );
        }
    }

    if ( $self->util->find_bin( "razor-client", fatal => 0 ) ) {
        print "It appears you have razor installed, skipping manual build.\n";
        $self->razor_config();
        return 1;
    }

    $ver = "2.80" if ( $ver == 1 || $ver eq "port" );

    $self->util->install_module_from_src( 'razor-agents-' . $ver,
        archive => 'razor-agents-' . $ver . '.tar.gz',
        site    => 'http://umn.dl.sourceforge.net/sourceforge',
        url     => '/razor',
    );

    $self->razor_config();
    return 1;
}

sub razor_config {
    my $self  = shift;

    print "razor: beginning configuration.\n";

    if ( -d "/etc/razor" ) {
        print "razor_config: it appears you have razor configured, skipping.\n";
        return 1;
    }

    my $client = $self->util->find_bin( "razor-client", fatal => 0 );
    my $admin  = $self->util->find_bin( "razor-admin",  fatal => 0 );

    # for old versions of razor
    if ( -x $client && !-x $admin ) {
        $self->util->syscmd( $client, verbose=>0 );
    }

    unless ( -x $admin ) {
        print "FAILED: couldn't find $admin!\n";
        return 0;
    }

    $self->util->syscmd( "$admin -home=/etc/razor -create -d", verbose=>0 );
    $self->util->syscmd( "$admin -home=/etc/razor -register -d", verbose=>0 );

    my $file = "/etc/razor/razor-agent.conf";
    if ( -e $file ) {
        my @lines = $self->util->file_read( $file );
        foreach my $line (@lines) {
            if ( $line =~ /^logfile/ ) {
                $line = 'logfile                = /var/log/razor-agent.log';
            }
        }
        $self->util->file_write( $file, lines => \@lines, verbose=>0 );
    }

    $file = "/etc/newsyslog.conf";
    if ( -e $file ) {
        if ( !`grep razor-agent $file` ) {
            $self->util->file_write( $file,
                lines  => ["/var/log/razor-agent.log	600	5	1000 *	Z"],
                append => 1,
                verbose  => 0,
            );
        }
    }

    print "razor: configuration completed.\n";
    return 1;
}

sub refresh_config {
    my ($self, $file_path) = @_;

    if ( ! -f $file_path ) {
        $self->audit( "config: $file_path is missing!, FAILED" );
        return;
    };

    warn "found: $file_path \n" if $self->{verbose};

    # refresh our $conf
    my $conf = $self->util->parse_config( $file_path,
        verbose => $self->{verbose},
        fatal => $self->{fatal},
    );

    $self->set_config($conf);

    warn "refreshed \$conf from: $file_path \n" if $self->{verbose};
    return $conf;
};

sub ripmime {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_ripmime'};
    if ( !$ver ) {
        print "ripmime install not selected.\n";
        return 0;
    }

    print "rimime: installing...\n";

    if ( $ver eq "port" || $ver eq "1" ) {

        if ( $self->util->find_bin( "ripmime", fatal => 0 ) ) {
            print "ripmime: is already installed...done.\n\n";
            return 1;
        }

        if ( $OSNAME eq "freebsd" ) {
            if ( $self->freebsd->install_port( "ripmime" ) ) {
                return 1;
            }
        }
        elsif ( $OSNAME eq "darwin" ) {
            if ( $self->darwin->install_port( "ripmime" ) ) {
                return 1;
            }
        }

        if ( $self->util->find_bin( "ripmime", fatal => 0 ) ) {
            print "ripmime: ripmime has been installed successfully.\n";
            return 1;
        }

        $ver = "1.4.0.6";
    }

    my $ripmime = $self->util->find_bin( "ripmime", fatal => 0 );
    if ( -x $ripmime ) {
        my $installed = `$ripmime -V`;
        ($installed) = $installed =~ /v(.*) - /;

        if ( $ver eq $installed ) {
            print
              "ripmime: the selected version ($ver) is already installed!\n";
            return 1;
        }
    }

    $self->util->install_from_source(
        package        => "ripmime-$ver",
        site           => 'http://www.pldaniels.com',
        url            => '/ripmime',
        targets        => [ 'make', 'make install' ],
        bintest        => 'ripmime',
        verbose          => 1,
        source_sub_dir => 'mail',
    );
}

sub rrdtool {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);
    return $p{test_ok} if defined $p{test_ok}; # for testing

    unless ( $self->conf->{'install_rrdutil'} ) {
        print "install_rrdutil is not set in toaster-watcher.conf! Skipping.\n";
        return;
    }

    if ( $OSNAME eq "freebsd" ) {

# the newer (default) version of rrdtool requires an obscene amount
# of x11 software be installed. Install the older one instead.
        $self->freebsd->install_port('rrdtool',
            dir     => 'rrdtool12',
            options => "#\n# Options for rrdtool-1.2.30_1
    _OPTIONS_READ=rrdtool-1.2.30_1
    WITHOUT_PYTHON_MODULE=true
    WITHOUT_RUBY_MODULE=true
    WITH_PERL_MODULE=true\n",
        );
    }
    elsif ( $OSNAME eq "darwin" ) {
        $self->darwin->port_install( port_name => "rrdtool" );
    }

    return 1 if -x $self->util->find_bin( 'rrdtool', fatal => 0 );

    $self->util->install_from_source(
        package => "rrdtool-1.2.23",
        site    => 'http://people.ee.ethz.ch',
        url     => '/~oetiker/webtools/rrdtool/pub',
        targets => [ './configure', 'make', 'make install' ],
        patches => [ ],
        bintest => 'rrdtool',
        verbose   => 1,
    );
}

sub roundcube {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{'install_roundcube'} ) {
        $self->audit( "not installing roundcube, not selected!" );
        return;
    };

    if ( $OSNAME eq "freebsd" ) {
        $self->php() or return;
        $self->roundcube_freebsd() or return;
    }
    else {
        print
"please install roundcube manually. Support for install on $OSNAME is not available yet.\n";
        return;
    }

    return 1;
}

sub roundcube_freebsd {
    my $self = shift;
    my $mysql = $self->conf->{install_mysql} ? 'WITH_MYSQL' : 'WITHOUT_MYSQL';
    my $sqlite = $self->conf->{install_mysql} ? 'WITHOUT_SQLITE' : 'WITH_SQLITE';

    $self->freebsd->install_port( "roundcube",
        category=> 'mail',
        options => "# This file generated by Mail::Toaster
# Options for roundcube-0.3_1,1
_OPTIONS_READ=roundcube-0.3_1,1
$mysql=true
WITHOUT_PGSQL=true
$sqlite=true
WITHOUT_SSL=true
WITHOUT_LDAP=true
WITHOUT_PSPELL=true
WITHOUT_NSC=true
WITHOUT_AUTOCOMP=true
",
    ) or return;

    $self->roundcube_config();
};

sub roundcube_config {
    my $self = shift;
    my $rcdir = "/usr/local/www/roundcube";
    my $config = "$rcdir/config";

    foreach my $c ( qw/ db.inc.php main.inc.php / ) {
        copy( "$config/$c.dist", "$config/$c" ) if ! -e "$config/$c";
    };

    if ( ! -f "$config/db.inc.php" ) {
        warn "unable to find roundcube/config/db.inc.php. Edit it with appropriate DSN settings\n";
        return;
    };

    $self->config_apply_tweaks(
        file => "$config/main.inc.php",
        changes => [
            {   search  => q{$rcmail_config['default_host'] = '';},
                replace => q{$rcmail_config['default_host'] = 'localhost';},
            },
            {   search  => q{$rcmail_config['session_lifetime'] = 10;},
                replace => q{$rcmail_config['session_lifetime'] = 30;},
            },
            {   search  => q{$rcmail_config['imap_auth_type'] = null;},
                replace => q{$rcmail_config['imap_auth_type'] = plain;},
            },
        ],
    );

    if ( $self->conf->{install_mysql} ) {
        return $self->roundcube_config_mysql();
    }
    else {
        return $self->roundcube_config_sqlite();
    };
};

sub roundcube_config_mysql {
    my $self = shift;

    my $rcdir = "/usr/local/www/roundcube";
    my $config = "$rcdir/config/db.inc.php";
    my $pass = $self->conf->{install_roundcube_db_pass};

    if ( ! `grep mysql $config | grep ':pass'` ) {
        $self->audit( "roundcube database permission already configured",verbose=>1 );
        return 1;
    };

    $self->config_apply_tweaks(
        file => $config,
        changes => [
            {   search  => q{$rcmail_config['db_dsnw'] = 'mysql://roundcube:pass@localhost/roundcubemail';},
                replace => "\$rcmail_config['db_dsnw'] = 'mysql://roundcube:$pass\@localhost/roundcubemail';",
            },
        ],
        verbose => 1,
    );

    my $host = $self->conf->{vpopmail_mysql_repl_master};
    my $dot = $self->mysql->parse_dot_file( ".my.cnf", "[mysql]", 0 )
        || { user => 'root', pass => '', host => $host };
    my ( $dbh, $dsn, $drh ) = $self->mysql->connect( $dot );
    return if !$dbh;


    my $sth = $self->mysql->query( $dbh, "USE roundcubemail" );
    if ( $sth->errstr ) {
        $self->mysql->query( $dbh, "CREATE DATABASE roundcubemail" );
        if ( $sth->errstr ) {
            $sth->finish;
            $self->error( "roundcube database creation failed. Configure manually" );
            return;
        };

        $sth = $self->mysql->query( $dbh, "GRANT ALL PRIVILEGES ON roundcubemail.* to 'roundcube'\@'$host' IDENTIFIED BY '$pass'" );
        if ( $sth->errstr ) {
            $sth->finish;
            $self->error( "roundcube database configuration failed. Configure manually" );
            return;
        };
        $self->audit( "configured roundcube database privileges (ok)",verbose=>1 );

        my $mysql = $self->util->find_bin('mysql');
        my $initial = "$rcdir/SQL/mysql.initial.sql";
        system "mysql roundcubemail < $initial" and
            return $self->error("failed to import mysql databases, try manually running this command\n\t: mysql roundcubemail < $initial\n",verbose=>1);
        $self->audit( "roundcube database initialized",verbose=>1 );
    };

    $sth->finish;
    return 1;
};

sub roundcube_config_sqlite {
    my $self = shift;

    my $rcdir = "/usr/local/www/roundcube";
    my $config = "$rcdir/config/db.inc.php";

    my $spool = '/var/spool/roundcubemail';
    mkpath $spool;
    my (undef,undef,$uid,$gid) = getpwnam('www');
    chown $uid, $gid, $spool;

    # configure roundcube to use sqlite for DB
    $self->config_apply_tweaks(
        file => $config,
        changes => [
            {   search  => q{$rcmail_config['db_dsnw'] = 'mysql://roundcube:pass@localhost/roundcubemail';},
                replace => q{$rcmail_config['db_dsnw'] = 'sqlite:////var/spool/roundcubemail/sqlite.db?mode=0646';},
            },
        ],
    );
};

sub rsync {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "rsync",
            options => "#\n
# This file is generated by mail-toaster
# No user-servicable parts inside!
# Options for rsync-3.0.7
_OPTIONS_READ=rsync-3.0.7
WITHOUT_POPT_PORT=true
WITH_SSH=true
WITHOUT_FLAGS=true
WITHOUT_ATIMES=true
WITHOUT_ACL=true
WITHOUT_ICONV=true
WITHOUT_TIMELIMIT=true\n",
        );
    }
    elsif ( $OSNAME eq "darwin" ) {
        $self->darwin->install_port( "rsync" );
    }
    else {
        die
"please install rsync manually. Support for $OSNAME is not available yet.\n";
    }

    return $self->util->find_bin('rsync',verbose=>0);
}

sub set_config {
    my $self = shift;
    my $newconf = shift;
    return $self->conf if ! $newconf;
    $self->conf( $newconf );
    return $newconf;
};

sub simscan {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_simscan'} or do {
        $self->audit( "simscan: installing, skipping (disabled)" );
        return;
    };

    if ( $OSNAME eq 'freebsd' ) {
        my $r = $self->simscan_freebsd_port();
        return $r if $ver eq 'port';
    };

    my $user    = $self->conf->{'simscan_user'} || "clamav";
    my $reje    = $self->conf->{'simscan_spam_hits_reject'};
    my $qdir    = $self->conf->{'qmail_dir'};
    my $custom  = $self->conf->{'simscan_custom_smtp_reject'};

    if ( -x "$qdir/bin/simscan" ) {
        return 0
            if ! $self->util->yes_or_no(
                "simscan is already installed, do you want to reinstall?",
                timeout => 60,
            );
    }

    my $bin;
    my $confcmd = "./configure ";
    $confcmd .= "--enable-user=$user ";
    $confcmd .= $self->simscan_ripmime( $ver );
    $confcmd .= $self->simscan_clamav;
    $confcmd .= $self->simscan_spamassassin;
    $confcmd .= $self->simscan_regex;
    $confcmd .= "--enable-received=y "       if $self->conf->{'simscan_received'};
    $confcmd .= "--enable-spam-hits=$reje "  if ($reje);
    $confcmd .= "--enable-attach=y " if $self->conf->{'simscan_block_attachments'};
    $confcmd .= "--enable-qmaildir=$qdir "   if $qdir;
    $confcmd .= "--enable-qmail-queue=$qdir/bin/qmail-queue " if $qdir;
    $confcmd .= "--enable-per-domain=y "     if $self->conf->{'simscan_per_domain'};
    $confcmd .= "--enable-custom-smtp-reject=y " if $custom;
    $confcmd .= "--enable-spam-passthru=y " if $self->conf->{'simscan_spam_passthru'};

    if ( $self->conf->{'simscan_quarantine'} && -d $self->conf->{'simscan_quarantine'} ) {
        $confcmd .= "--enable-quarantinedir=$self->conf->{'simscan_quarantine'}";
    }

    print "configure: $confcmd\n";
    my $patches = [];
    push @$patches, 'simscan-1.4.0-clamav.3.patch' if $confcmd =~ /clamavdb/;

    $self->util->install_from_source(
       'package'      => "simscan-$ver",
#       site           => 'http://www.inter7.com',
        site           => "http://downloads.sourceforge.net",
        url            => '/simscan',
        targets        => [ $confcmd, 'make', 'make install-strip' ],
        bintest        => "$qdir/bin/simscan",
        source_sub_dir => 'mail',
        patches        => $patches,
        patch_url      => "$self->conf->{'toaster_dl_site'}$self->conf->{'toaster_dl_url'}/patches",
    );

    $self->simscan_conf();
}

sub simscan_clamav {
    my ( $self ) = @_;

    return '' if ! $self->conf->{'simscan_clamav'};

    my $bin = $self->util->find_bin( "clamdscan", fatal => 0 );
    croak "couldn't find $bin, install ClamAV!\n" if !-x $bin;

    my $cmd .= "--enable-clamdscan=$bin ";
    $cmd .= "--enable-clamavdb-path=";
    $cmd .= -d "/var/db/clamav"  ?  "/var/db/clamav "
          : -d "/usr/local/share/clamav" ? "/usr/local/share/clamav "
          : -d "/opt/local/share/clamav" ? "/opt/local/share/clamav "
          : croak "can't find the ClamAV db path!";

    $bin = $self->util->find_bin( "sigtool", fatal => 0 );
    croak "couldn't find $bin, install ClamAV!" if ! -x $bin;
    $cmd .= "--enable-sigtool-path=$bin ";
    return $cmd;
};

sub simscan_conf {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my ( $file, @lines );

    my $reje = $self->conf->{'simscan_spam_hits_reject'};

    my @attach;
    if ( $self->conf->{'simscan_block_attachments'} ) {

        $file = "/var/qmail/control/ssattach";
        foreach ( split( /,/, $self->conf->{'simscan_block_types'} ) ) {
            push @attach, ".$_";
        }
        $self->util->file_write( $file, lines => \@attach );
    }

    $file = "/var/qmail/control/simcontrol";
    if ( !-e $file ) {
        my @opts;
        $self->conf->{'simscan_clamav'}
          ? push @opts, "clam=yes"
          : push @opts, "clam=no";

        $self->conf->{'simscan_spamassassin'}
          ? push @opts, "spam=yes"
          : push @opts, "spam=no";

        $self->conf->{'simscan_trophie'}
          ? push @opts, "trophie=yes"
          : push @opts, "trophie=no";

        $reje
          ? push @opts, "spam_hits=$reje"
          : print "no reject.\n";

        if ( @attach > 0 ) {
            my $line  = "attach=";
            my $first = shift @attach;
            $line .= "$first";
            foreach (@attach) { $line .= ":$_"; }
            push @opts, $line;
        }

        @lines = "#postmaster\@example.com:" . join( ",", @opts );
        push @lines, "#example.com:" . join( ",", @opts );
        push @lines, "#";
        push @lines, ":" . join( ",",             @opts );

        if ( -e $file ) {
            $self->util->file_write( "$file.new", lines => \@lines );
            print
"\nNOTICE: simcontrol written to $file.new. You need to review and install it!\n";
        }
        else {
            $self->util->file_write( $file, lines => \@lines );
        }
    }

    my $user  = $self->conf->{'simscan_user'}       || 'simscan';
    my $group = $self->conf->{'smtpd_run_as_group'} || 'qmail';

    $self->util->syscmd( "pw user mod simscan -G qmail,clamav" );
    $self->util->chown( '/var/qmail/simscan', uid => $user, gid => $group );
    $self->util->chown( '/var/qmail/bin/simscan', uid => $user, gid=>$group );
    $self->util->chmod( dir => '/var/qmail/simscan', mode => '0770' );

    if ( -x "/var/qmail/bin/simscanmk" ) {
        $self->util->syscmd( "/var/qmail/bin/simscanmk" );
        system "/var/qmail/bin/simscanmk";
    }
}

sub simscan_freebsd_port {
    my $self = shift;

    my @args;
    push @args, "SPAMC_ARGS=" . $self->conf->{simscan_spamc_args} if $self->conf->{simscan_spamc_args};
    push @args, 'SPAM_HITS=' . $self->conf->{simscan_spam_hits_reject} if $self->conf->{simscan_spam_hits_reject};
    push @args, 'SIMSCAN_USER=' . $self->conf->{simscan_user} if $self->conf->{simscan_user};
    push @args, 'QUARANTINE_DIR=' . $self->conf->{simscan_quarantine} if $self->conf->{'simscan_quarantine'};
    push @args, 'QMAIL_PREFIX=' . $self->conf->{qmail_dir} || '/var/qmail';

    $self->freebsd->install_port( "simscan",
        category => 'mail',
        flags => join( ",", @args ),
        options => "# This file is generated by Mail::Toaster
# No user-servicable parts inside!
# Options for simscan-1.4.0_6
_OPTIONS_READ=simscan-1.4.0_6
WITH_CLAMAV=true
WITH_RIPMIME=true
WITH_SPAMD=true
WITH_USER=true
WITH_DOMAIN=true
WITH_ATTACH=true
WITHOUT_DROPMSG=true
WITHOUT_PASSTHRU=true
WITH_HEADERS=true
WITHOUT_DSPAM=true",
    );

    return $self->simscan_conf();
};

sub simscan_regex {
    my ($self) = @_;
    return '' if ! $self->conf->{'simscan_regex_scanner'};

    my $config = "--enable-regex=y ";

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "pcre" );
        $config .= "--with-pcre-include=/usr/local/include ";
    }
    else {
        print "\n\nWARNING: is pcre installed?\n\n";
    }
    return $config;
};

sub simscan_ripmime {
    my ($self, $ver ) = @_;

    if ( ! $self->is_newer( min => "1.0.8", cur => $ver ) ) {
        print "ripmime doesn't work with simcan < 1.0.8\n";
        return '';
    };

    return "--disable-ripmime " if ! $self->conf->{'simscan_ripmime'};

    my $bin = $self->util->find_bin( "ripmime", fatal => 0, verbose=>0);
    unless ( -x $bin ) {
        croak "couldn't find $bin, install ripmime!\n";
    }
    $self->ripmime();
    return "--enable-ripmime=$bin ";
};

sub simscan_spamassassin {
    my ($self) = @_;

    return '' if ! $self->conf->{'simscan_spamassassin'};

    my $spamc = $self->util->find_bin( "spamc", fatal => 0 );
    my $cmd = "--enable-spam=y --enable-spamc-user=y --enable-spamc=$spamc ";

    my $spamc_args = $self->conf->{'simscan_spamc_args'};
    $cmd .= "--enable-spamc-args=$spamc_args " if $spamc_args;

    if ( $self->conf->{'simscan_received'} ) {
        my $bin = $self->util->find_bin( "spamassassin", fatal => 0 );
        croak "couldn't find $bin, install SpamAssassin!\n" if !-x $bin;
        $cmd .= "--enable-spamassassin-path=$bin ";
    }
    return $cmd;
};

sub simscan_test {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $qdir = $self->conf->{'qmail_dir'};

    if ( ! $self->conf->{'install_simscan'} ) {
        print "simscan installation disabled, skipping test!\n";
        return;
    }

    print "testing simscan...";
    my $scan = "$qdir/bin/simscan";
    unless ( -x $scan ) {
        print "FAILURE: Simscan could not be found at $scan!\n";
        return;
    }

    $ENV{"QMAILQUEUE"} = $scan;
    $self->toaster->email_send( type => "clean" );
    $self->toaster->email_send( type => "attach" );
    $self->toaster->email_send( type => "virus" );
    $self->toaster->email_send( type => "clam" );
    $self->toaster->email_send( type => "spam" );
}

sub smtp_test_auth {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my @modules = ('IO::Socket::INET', 'IO::Socket::SSL', 'Net::SSLeay', 'Socket qw(:DEFAULT :crlf)');
    foreach ( @modules ) {
        eval "use $_";
        die $@ if $@;
        $self->toaster->test( "loading $_", 'ok' );
    };

    Net::SSLeay::load_error_strings();
    Net::SSLeay::SSLeay_add_ssl_algorithms();
    Net::SSLeay::randomize();

    my $host = $self->conf->{'smtpd_listen_on_address'} || 'localhost';
       $host = 'localhost' if ( $host =~ /system|qmail|all/i );





    my $smtp = Net::SMTP_auth->new($host);
    $self->toaster->test( "connect to smtp port on $host", $smtp );
    return 0 if ! defined $smtp;

    my @auths = $smtp->auth_types();
    $self->toaster->test( "  get list of SMTP AUTH methods", scalar @auths);
    $smtp->quit;

    $self->smtp_test_auth_pass($host, \@auths);
    $self->smtp_test_auth_fail($host, \@auths);
};

sub smtp_test_auth_pass {
    my $self = shift;
    my $host = shift;
    my $auths = shift or die "invalid params\n";

    my $user = $self->conf->{'toaster_test_email'}      || 'test2@example.com';
    my $pass = $self->conf->{'toaster_test_email_pass'} || 'cHanGeMe';

    # test each authentication method the server advertises
    foreach (@$auths) {

        my $smtp = Net::SMTP_auth->new($host);
        my $r = $smtp->auth( $_, $user, $pass );
        $self->toaster->test( "  authentication with $_", $r );
        next if ! $r;

        $smtp->mail( $self->conf->{'toaster_admin_email'} );
        $smtp->to('postmaster');
        $smtp->data();
        $smtp->datasend("To: postmaster\n");
        $smtp->datasend("\n");
        $smtp->datasend("A simple test message\n");
        $smtp->dataend();

        $smtp->quit;
        $self->toaster->test("  sending after auth $_", 1 );
    }
}

sub smtp_test_auth_fail {
    my $self = shift;
    my $host = shift;
    my $auths = shift or die "invalid params\n";

    my $user = 'non-exist@example.com';
    my $pass = 'non-password';

    foreach (@$auths) {
        my $smtp = Net::SMTP_auth->new($host);
        my $r = $smtp->auth( $_, $user, $pass );
        $self->toaster->test( "  failed authentication with $_", ! $r );
        $smtp->quit;
    }
}

sub socklog {
    my $self  = shift;
    my %p = validate( @_, { 'ip' => SCALAR, $self->get_std_opts, },);

    my $ip    = $p{'ip'};

    my $user  = $self->conf->{'qmail_log_user'}  || "qmaill";
    my $group = $self->conf->{'qmail_log_group'} || "qnofiles";

    my $uid = getpwnam($user);
    my $gid = getgrnam($group);

    my $logdir = $self->conf->{'qmail_log_base'};
    unless ( -d $logdir ) { $logdir = "/var/log/mail" }

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "socklog" );
    }
    else {
        print "\n\nNOTICE: Be sure to install socklog!!\n\n";
    }
    $self->socklog_qmail_control( "send", $ip, $user, undef, $logdir );
    $self->socklog_qmail_control( "smtp", $ip, $user, undef, $logdir );
    $self->socklog_qmail_control( "pop3", $ip, $user, undef, $logdir );

    unless ( -d $logdir ) {
        mkdir( $logdir, oct('0755') ) or croak "socklog: couldn't create $logdir: $!";
        chown( $uid, $gid, $logdir ) or croak "socklog: couldn't chown  $logdir: $!";
    }

    foreach my $prot (qw/ send smtp pop3 /) {
        unless ( -d "$logdir/$prot" ) {
            mkdir( "$logdir/$prot", oct('0755') )
              or croak "socklog: couldn't create $logdir/$prot: $!";
        }
        chown( $uid, $gid, "$logdir/$prot" )
          or croak "socklog: couldn't chown $logdir/$prot: $!";
    }
}

sub socklog_qmail_control {
    my ( $self, $serv, $ip, $user, $supervise, $log ) = @_;

    $ip        ||= "192.168.2.9";
    $user      ||= "qmaill";
    $supervise ||= "/var/qmail/supervise";
    $log       ||= "/var/log/mail";

    my $run_f = "$supervise/$serv/log/run";

    if ( -s $run_f ) {
        print "socklog_qmail_control skipping: $run_f exists!\n";
        return 1;
    }

    print "socklog_qmail_control creating: $run_f...";
    my @socklog_run_file = <<EO_SOCKLOG;
#!/bin/sh
LOGDIR=$log
LOGSERVERIP=$ip
PORT=10116

PATH=/var/qmail/bin:/usr/local/bin:/usr/bin:/bin
export PATH

exec setuidgid $user multilog t s4096 n20 \
  !"tryto -pv tcpclient -v \$LOGSERVERIP \$PORT sh -c 'cat >&7'" \
  \${LOGDIR}/$serv
EO_SOCKLOG
    $self->util->file_write( $run_f, lines => \@socklog_run_file );

#	open(my $RUN, ">", $run_f) or croak "socklog_qmail_control: couldn't open for write: $!";
#	close $RUN;
    chmod oct('0755'), $run_f or croak "socklog: couldn't chmod $run_f: $!";
    print "done.\n";
}

sub spamassassin {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok};

    if ( !$self->conf->{'install_spamassassin'} ) {
        $self->audit( "spamassassin: installing, skipping (disabled)" );
        return;
    }

    if ( $OSNAME eq "freebsd" ) {
        $self->spamassassin_freebsd();
    }
    elsif ( $OSNAME eq "darwin" ) {
        $self->darwin->install_port( "procmail" )
            if $self->conf->{'install_procmail'};
        $self->darwin->install_port( "unzip" );
        $self->darwin->install_port( "p5-mail-audit" );
        $self->darwin->install_port( "p5-mail-spamassassin" );
        $self->darwin->install_port( "bogofilter" ) if $self->conf->{'install_bogofilter'};
    }

    $self->util->install_module( "Time::HiRes" );
    $self->util->install_module( "Mail::Audit" );
    $self->util->install_module( "HTML::Parser" );
    $self->util->install_module( "Archive::Tar" );
    $self->util->install_module( "NetAddr::IP" );
    $self->util->install_module( "LWP::UserAgent" );  # used by sa-update
    $self->util->install_module( "Mail::SpamAssassin" );
    $self->maildrop( );

    $self->spamassassin_sql();
}

sub spamassassin_freebsd {
    my $self = shift;

    my $mysql = "WITHOUT_MYSQL=true";
    if ( $self->conf->{install_spamassassin_sql} ) {
        $mysql = "WITH_MYSQL=true";
    };

    $self->freebsd->install_port( "p5-Mail-SPF" );
    $self->freebsd->install_port( "p5-Mail-SpamAssassin",
        category => 'mail',
        flags => "WITHOUT_SSL=1 BATCH=yes",
        options => "# This file is generated by Mail::Toaster
# Options for p5-Mail-SpamAssassin-3.2.5_2
_OPTIONS_READ=p5-Mail-SpamAssassin-3.2.5_2
WITH_AS_ROOT=true
WITH_SPAMC=true
WITHOUT_SACOMPILE=true
WITH_DKIM=true
WITHOUT_SSL=true
WITH_GNUPG=true
$mysql
WITHOUT_PGSQL=true
WITH_RAZOR=true
WITH_SPF_QUERY=true
WITH_RELAY_COUNTRY=true",
        verbose => 0,
    );

    # the old port didn't install the spamd.sh file
    # new versions install sa-spamd.sh and require the rc.conf flag
    my $start = -f "/usr/local/etc/rc.d/spamd.sh" ? "/usr/local/etc/rc.d/spamd.sh"
                : -f "/usr/local/etc/rc.d/spamd"    ? "/usr/local/etc/rc.d/spamd"
                : "/usr/local/etc/rc.d/sa-spamd";   # current location, 9/23/06

    my $flags = $self->conf->{'install_spamassassin_flags'};

    $self->freebsd->conf_check(
        check => "spamd_enable",
        line  => 'spamd_enable="YES"',
        verbose => 0,
    );

    $self->freebsd->conf_check(
        check => "spamd_flags",
        line  => qq{spamd_flags="$flags"},
        verbose => 0,
    );

    $self->gnupg_install();
    $self->spamassassin_update();

    unless ( $self->util->is_process_running("spamd") ) {
        if ( -x $start ) {
            print "Starting SpamAssassin...";
            $self->util->syscmd( "$start restart", verbose=>0 );
            print "done.\n";
        }
        else { print "WARN: couldn't start SpamAssassin's spamd.\n"; }
    }
};

sub spamassassin_sql {

    # set up the mysql database for use with SpamAssassin
    # http://svn.apache.org/repos/asf/spamassassin/branches/3.0/sql/README

    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{'install_mysql'} || ! $self->conf->{'install_spamassassin_sql'} ) {
        print "SpamAssasin MySQL integration not selected. skipping.\n";
        return 0;
    }

    if ( $OSNAME eq "freebsd" ) {
        $self->spamassassin_sql_freebsd();
    }
    else {
        $self->spamassassin_sql_manual();
    };
};

sub spamassassin_sql_manual {
    my $self = shift;

    print
"Sorry, automatic MySQL SpamAssassin setup is not available on $OSNAME yet. You must
do this process manually by locating the *_mysql.sql files that arrived with SpamAssassin. Run
each one like this:
	mysql spamassassin < awl_mysql.sql
	mysql spamassassin < bayes_mysql.sql
	mysql spamassassin < userpref_mysql.sql

Then configure SpamAssassin to use them by creating a sql.cf file in SpamAssassin's etc dir with
the following contents:

	user_scores_dsn                 DBI:mysql:spamassassin:localhost
	user_scores_sql_username        $self->conf->{'install_spamassassin_dbuser'}
	user_scores_sql_password        $self->conf->{'install_spamassassin_dbpass'}

	# default query
	#SELECT preference, value FROM _TABLE_ WHERE username = _USERNAME_ OR username = '\@GLOBAL' ORDER BY username ASC
	# global, then domain level
	#SELECT preference, value FROM _TABLE_ WHERE username = _USERNAME_ OR username = '\@GLOBAL' OR username = '@~'||_DOMAIN_ ORDER BY username ASC
	# global overrides user prefs
	#SELECT preference, value FROM _TABLE_ WHERE username = _USERNAME_ OR username = '\@GLOBAL' ORDER BY username DESC
	# from the SA SQL README
	#user_scores_sql_custom_query     SELECT preference, value FROM _TABLE_ WHERE username = _USERNAME_ OR username = '\$GLOBAL' OR username = CONCAT('%',_DOMAIN_) ORDER BY username ASC

	bayes_store_module              Mail::SpamAssassin::BayesStore::SQL
	bayes_sql_dsn                   DBI:mysql:spamassassin:localhost
	bayes_sql_username              $self->conf->{'install_spamassassin_dbuser'}
	bayes_sql_password              $self->conf->{'install_spamassassin_dbpass'}
	#bayes_sql_override_username    someusername

	auto_whitelist_factory       Mail::SpamAssassin::SQLBasedAddrList
	user_awl_dsn                 DBI:mysql:spamassassin:localhost
	user_awl_sql_username        $self->conf->{'install_spamassassin_dbuser'}
	user_awl_sql_password        $self->conf->{'install_spamassassin_dbpass'}
	user_awl_sql_table           awl
";
};

sub spamassassin_sql_freebsd {
    my $self = shift;

    # is SpamAssassin installed?
    if ( ! $self->freebsd->is_port_installed( "p5-Mail-SpamAssassin" ) ) {
        print "SpamAssassin is not installed, skipping database setup.\n";
        return;
    }

    # have we been here already?
    if ( -f "/usr/local/etc/mail/spamassassin/sql.cf" ) {
        print "SpamAssassing database setup already done...skipping.\n";
        return 1;
    };

    print "SpamAssassin is installed, setting up MySQL databases\n";

    my $user = $self->conf->{'install_spamassassin_dbuser'};
    my $pass = $self->conf->{'install_spamassassin_dbpass'};

    my $dot = $self->mysql->parse_dot_file( ".my.cnf", "[mysql]", 0 );
    my ( $dbh, $dsn, $drh ) = $self->mysql->connect( $dot, 1 );

    if ($dbh) {
        my $query = "use spamassassin";
        my $sth = $self->mysql->query( $dbh, $query, 1 );
        if ( $sth->errstr ) {
            print "oops, no spamassassin database.\n";
            print "creating MySQL spamassassin database.\n";
            $query = "CREATE DATABASE spamassassin";
            $sth   = $self->mysql->query( $dbh, $query );
            $query =
"GRANT ALL PRIVILEGES ON spamassassin.* TO $user\@'localhost' IDENTIFIED BY '$pass'";
            $sth = $self->mysql->query( $dbh, $query );
            $sth = $self->mysql->query( $dbh, "flush privileges" );
            $sth->finish;
        }
        else {
            print "spamassassin: spamassassin database exists!\n";
            $sth->finish;
        }
    }

    my $mysqlbin = $self->util->find_bin( 'mysql', fatal => 0 );
    if ( ! -x $mysqlbin ) {
        $mysqlbin = $self->util->find_bin( 'mysql5' );
    };
    my $sqldir = "/usr/local/share/doc/p5-Mail-SpamAssassin/sql";
    foreach my $f (qw/bayes_mysql.sql awl_mysql.sql userpref_mysql.sql/) {
        if ( ! -f "$sqldir/$f" ) {
            warn "missing .sql file: $f\n";
            next;
        };
        if ( `grep MyISAM "$sqldir/$f"` ) {
            my @lines = $self->util->file_read( "$sqldir/$f" );
            foreach my $line (@lines) {
                if ( $line eq ') TYPE=MyISAM;' ) {
                    $line = ');';
                };
            };
            $self->util->file_write( "$sqldir/$f", lines=>\@lines );
        };
        $self->util->syscmd( "$mysqlbin spamassassin < $sqldir/$f" );
    }

    my $file = "/usr/local/etc/mail/spamassassin/sql.cf";
    unless ( -f $file ) {
        my @lines = <<EO_SQL_CF;
loadplugin Mail::SpamAssassin::Plugin::AWL

user_scores_dsn                 DBI:mysql:spamassassin:localhost
user_scores_sql_username        $self->conf->{'install_spamassassin_dbuser'}
user_scores_sql_password        $self->conf->{'install_spamassassin_dbpass'}
#user_scores_sql_table           userpref

bayes_store_module              Mail::SpamAssassin::BayesStore::SQL
bayes_sql_dsn                   DBI:mysql:spamassassin:localhost
bayes_sql_username              $self->conf->{'install_spamassassin_dbuser'}
bayes_sql_password              $self->conf->{'install_spamassassin_dbpass'}
#bayes_sql_override_username    someusername

auto_whitelist_factory          Mail::SpamAssassin::SQLBasedAddrList
user_awl_dsn                    DBI:mysql:spamassassin:localhost
user_awl_sql_username           $self->conf->{'install_spamassassin_dbuser'}
user_awl_sql_password           $self->conf->{'install_spamassassin_dbpass'}
user_awl_sql_table              awl
EO_SQL_CF
        $self->util->file_write( $file, lines => \@lines );
    }
}

sub spamassassin_update {
    my $self = shift;

    my $update = $self->util->find_bin( "sa-update", fatal => 0 ) or return;
    system $update and do {
        $self->error( "error updating spamassassin rules", fatal => 0);
    };
    $self->audit( "trying again without GPG" );

    system "$update --nogpg" and
        return $self->error( "error updating spamassassin rules", fatal => 0);

    return 1;
};

sub squirrelmail {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_squirrelmail'} or do {
        $self->audit( 'skipping squirrelmail install (disabled)');
        return;
    };

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->php();
        $self->squirrelmail_freebsd() and return;
    };

    $ver = "1.4.6" if $ver eq 'port';

    print "squirrelmail: attempting to install from sources.\n";

    my $htdocs = $self->conf->{'toaster_http_docs'} || "/usr/local/www/data";
    my $srcdir = $self->conf->{'toaster_src_dir'}   || "/usr/local/src";
    $srcdir .= "/mail";

    unless ( -d $htdocs ) {
        $htdocs = "/var/www/data" if ( -d "/var/www/data" );    # linux
        $htdocs = "/Library/Webserver/Documents"
          if ( -d "/Library/Webserver/Documents" );             # OS X
    }

    if ( -d "$htdocs/squirrelmail" ) {
        print "Squirrelmail is already installed, I won't install it again!\n";
        return 0;
    }

    $self->util->install_from_source(
        package        => "squirrelmail-$ver",
        site           => "http://" . $self->conf->{'toaster_sf_mirror'},
        url            => "/squirrelmail",
        targets        => ["mv $srcdir/squirrelmail-$ver $htdocs/squirrelmail"],
        source_sub_dir => 'mail',
    );

    $self->squirrelmail_config();
    $self->squirrelmail_mysql();
}

sub squirrelmail_freebsd {
    my $self = shift;

    my @squirrel_flags;
    push @squirrel_flags, 'WITH_APACHE2=1' if ( $self->conf->{'install_apache'} == 2 );
    push @squirrel_flags, 'WITH_DATABASE=1' if $self->conf->{'install_squirrelmail_sql'};

    $self->freebsd->install_port( "squirrelmail",
        flags => join(',', @squirrel_flags),
    );
    $self->freebsd->install_port( "squirrelmail-quota_usage-plugin" );

    return if ! $self->freebsd->is_port_installed( "squirrelmail" );
    my $sqdir = "/usr/local/www/squirrelmail";
    return if ! -d $sqdir;

    $self->squirrelmail_config();
    $self->squirrelmail_mysql();

    return 1;
}

sub squirrelmail_mysql {
    my $self  = shift;

    return if ! $self->conf->{'install_mysql'};
    return if ! $self->conf->{'install_squirrelmail_sql'};

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "pear-DB" );

        print
'\nHEY!  You need to add include_path = ".:/usr/local/share/pear" to php.ini.\n\n';

        $self->freebsd->install_port( "php5-mysql" );
        $self->freebsd->install_port( "squirrelmail-sasql-plugin" );
    }

    my $db   = "squirrelmail";
    my $user = "squirrel";
    my $pass = $self->conf->{'install_squirrelmail_sql_pass'} || "secret";
    my $host = "localhost";

    my $dot = $self->mysql->parse_dot_file( ".my.cnf", "[mysql]", 0 );
    my ( $dbh, $dsn, $drh ) = $self->mysql->connect( $dot, 1 );

    if ($dbh) {
        my $query = "use squirrelmail";
        my $sth   = $self->mysql->query( $dbh, $query, 1 );

        if ( !$sth->errstr ) {
            print "squirrelmail: squirrelmail database already exists.\n";
            $sth->finish;
            return 1;
        }

        print "squirrelmail: creating MySQL database for squirrelmail.\n";
        $query = "CREATE DATABASE squirrelmail";
        $sth   = $self->mysql->query( $dbh, $query );

        $query =
"GRANT ALL PRIVILEGES ON $db.* TO $user\@'$host' IDENTIFIED BY '$pass'";
        $sth = $self->mysql->query( $dbh, $query );

        $query =
"CREATE TABLE squirrelmail.address ( owner varchar(128) DEFAULT '' NOT NULL,
nickname varchar(16) DEFAULT '' NOT NULL, firstname varchar(128) DEFAULT '' NOT NULL,
lastname varchar(128) DEFAULT '' NOT NULL, email varchar(128) DEFAULT '' NOT NULL,
label varchar(255), PRIMARY KEY (owner,nickname), KEY firstname (firstname,lastname));
";
        $sth = $self->mysql->query( $dbh, $query );

        $query =
"CREATE TABLE squirrelmail.global_abook ( owner varchar(128) DEFAULT '' NOT NULL, nickname varchar(16) DEFAULT '' NOT NULL, firstname varchar(128) DEFAULT '' NOT NULL,
lastname varchar(128) DEFAULT '' NOT NULL, email varchar(128) DEFAULT '' NOT NULL,
label varchar(255), PRIMARY KEY (owner,nickname), KEY firstname (firstname,lastname));";

        $sth = $self->mysql->query( $dbh, $query );

        $query =
"CREATE TABLE squirrelmail.userprefs ( user varchar(128) DEFAULT '' NOT NULL, prefkey varchar(64) DEFAULT '' NOT NULL, prefval BLOB DEFAULT '' NOT NULL, PRIMARY KEY (user,prefkey))";
        $sth = $self->mysql->query( $dbh, $query );

        $sth->finish;
        return 1;
    }

    print "

WARNING: I could not connect to your database server!  If this is a new install,
you will need to connect to your database server and run this command manually:

mysql -u root -h $host -p
CREATE DATABASE squirrelmail;
GRANT ALL PRIVILEGES ON $db.* TO $user\@'$host' IDENTIFIED BY '$pass';
CREATE TABLE squirrelmail.address (
owner varchar(128) DEFAULT '' NOT NULL,
nickname varchar(16) DEFAULT '' NOT NULL,
firstname varchar(128) DEFAULT '' NOT NULL,
lastname varchar(128) DEFAULT '' NOT NULL,
email varchar(128) DEFAULT '' NOT NULL,
label varchar(255),
PRIMARY KEY (owner,nickname),
KEY firstname (firstname,lastname)
);
CREATE TABLE squirrelmail.global_abook (
owner varchar(128) DEFAULT '' NOT NULL,
nickname varchar(16) DEFAULT '' NOT NULL,
firstname varchar(128) DEFAULT '' NOT NULL,
lastname varchar(128) DEFAULT '' NOT NULL,
email varchar(128) DEFAULT '' NOT NULL,
label varchar(255),
PRIMARY KEY (owner,nickname),
KEY firstname (firstname,lastname)
);
CREATE TABLE squirrelmail.userprefs (
user varchar(128) DEFAULT '' NOT NULL,
prefkey varchar(64) DEFAULT '' NOT NULL,
prefval BLOB DEFAULT '' NOT NULL,
PRIMARY KEY (user,prefkey)
);
quit;

If this is an upgrade, you can probably ignore this warning.

";
}

sub squirrelmail_config {
    my $self  = shift;

    my $sqdir = "/usr/local/www/squirrelmail";
    return 1 if -e "$sqdir/config/config.php";

    chdir("$sqdir/config");
    print "squirrelmail: installing a default config.php\n";

    copy('config_default.php', 'config.php');

    my $mailhost = $self->conf->{'toaster_hostname'};
    my $dsn      = '';

    if ( $self->conf->{'install_squirrelmail_sql'} ) {
        my $pass = $self->conf->{install_squirrelmail_sql_pass} || 's3kret';
        $dsn = "mysql://squirrel:$pass\@localhost/squirrelmail";
    }

    my $string = <<"EOCONFIG";
<?php
\$signout_page  = 'https://$mailhost/';
\$provider_name     = 'Powered by Mail::Toaster';
\$provider_uri     = 'http://www.tnpi.net/wiki/Mail_Toaster';
\$domain                 = '$mailhost';
\$useSendmail            = true;
\$imap_server_type       = 'dovecot';
\$addrbook_dsn = '$dsn';
\$prefs_dsn = '$dsn';
?>
EOCONFIG
      ;

    $self->util->file_write( "config_local.php", lines => [ $string ] );

    if ( -d "$sqdir/plugins/sasql" ) {
        if ( ! -e "$sqdir/plugins/sasql/sasql_conf.php" ) {
            copy('sasql_conf.php.dist', 'sasql_conf.php');
        };

        my $user = $self->conf->{install_spamassassin_dbuser};
        my $pass = $self->conf->{install_spamassassin_dbpass};
        $self->config_apply_tweaks(
            file => "$sqdir/plugins/sasql/sasql_conf.php",
            changes => [
                {   search  => q{$SqlDSN = 'mysql://<user>:<pass>@<host>/<db>';},
                    replace => "\$SqlDSN = 'mysql://$user:$pass\@localhost/spamassassin'",
                },
            ],
        );
    };
}

sub sqwebmail {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok};

    my $ver = $self->conf->{'install_sqwebmail'} or do {
        $self->audit( 'skipping sqwebmail install (disabled)');
        return;
    };

    my $httpdir = $self->conf->{'toaster_http_base'} || "/usr/local/www";
    my $cgi     = $self->conf->{'toaster_cgi_bin'};
    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";

    unless ( $cgi && -d $cgi ) { $cgi = "$httpdir/cgi-bin" }

    my $datadir = $self->conf->{'toaster_http_docs'};
    unless ( -d $datadir ) {
        if    ( -d "$httpdir/data/mail" ) { $datadir = "$httpdir/data/mail"; }
        elsif ( -d "$httpdir/mail" )      { $datadir = "$httpdir/mail"; }
        else { $datadir = "$httpdir/data"; }
    }

    my $mime = -e "$prefix/etc/apache2/mime.types"  ? "$prefix/etc/apache2/mime.types"
             : -e "$prefix/etc/apache22/mime.types" ? "$prefix/etc/apache22/mime.types"
             : "$prefix/etc/apache/mime.types";

    my $cachedir = "/var/run/sqwebmail";

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        return $self->sqwebmail_freebsd_port();
    };

    $ver = "5.3.1" if $ver eq "port";

    if ( -x "$prefix/libexec/sqwebmail/sqwebmaild" ) {
        if ( !$self->util->yes_or_no(
                "Sqwebmail is already installed, re-install it?",
                timeout  => 300
            )
          )
        {
            print "ok, skipping.\n";
            return;
        }
    }

    my $package = "sqwebmail-$ver";
    my $site    = "http://" . $self->conf->{'toaster_sf_mirror'} . "/courier";
    my $src     = $self->conf->{'toaster_src_dir'} || "/usr/local/src";

    $self->util->cwd_source_dir( "$src/mail" );

    if ( -d "$package" ) {
        unless ( $self->util->source_warning( $package, 1, $src ) ) {
            carp "sqwebmail: OK, skipping sqwebmail.\n";
            return;
        }
    }

    unless ( -e "$package.tar.bz2" ) {
        $self->util->get_url( "$site/$package.tar.bz2" );
        unless ( -e "$package.tar.bz2" ) {
            croak "sqwebmail FAILED: coudn't fetch $package\n";
        }
    }

    $self->util->extract_archive( "$package.tar.bz2" );

    chdir($package) or croak "sqwebmail FAILED: coudn't chdir $package\n";

    my $cmd = "./configure --prefix=$prefix --with-htmldir=$prefix/share/sqwebmail "
        . "--with-cachedir=/var/run/sqwebmail --enable-webpass=vpopmail "
        . "--with-module=authvchkpw --enable-https --enable-logincache "
        . "--enable-imagedir=$datadir/webmail --without-authdaemon "
        . "--enable-mimetypes=$mime --enable-cgibindir=" . $cgi;

    if ( $OSNAME eq "darwin" ) { $cmd .= " --with-cacheowner=daemon"; };

    my $make  = $self->util->find_bin("gmake", fatal=>0, verbose=>0);
    $make   ||= $self->util->find_bin("make", fatal=>0, verbose=>0);

    $self->util->syscmd( $cmd );
    $self->util->syscmd( "$make configure-check" );
    $self->util->syscmd( "$make check" );
    $self->util->syscmd( "$make" );

    my $share = "$prefix/share/sqwebmail";
    if ( -d $share ) {
        $self->util->syscmd( "make install-exec" );
        print
          "\n\nWARNING: I have only installed the $package binaries, thus\n";
        print "preserving any custom settings you might have in $share.\n";
        print
          "If you wish to do a full install, overwriting any customizations\n";
        print "you might have, then do this:\n\n";
        print "\tcd $src/mail/$package; make install\n";
    }
    else {
        $self->util->syscmd( "$make install" );
        chmod oct('0755'), $share;
        chmod oct('0755'), "$datadir/sqwebmail";
        copy( "$share/ldapaddressbook.dist", "$share/ldapaddressbook" )
          or croak "copy failed: $!";
    }

    $self->util->syscmd( "$make install-configure", fatal => 0 );
    $self->sqwebmail_conf();
}

sub sqwebmail_conf {
    my $self  = shift;
    my %p = validate(@_, { $self->get_std_opts },);

    my $cachedir = "/var/run/sqwebmail";
    my $prefix   = $self->conf->{'toaster_prefix'} || "/usr/local";

    unless ( -e $cachedir ) {
        my $uid = getpwnam("bin");
        my $gid = getgrnam("bin");
        mkdir( $cachedir, oct('0755') );
        chown( $uid, $gid, $cachedir );
    }

    my $file = "/usr/local/etc/sqwebmail/sqwebmaild";
    return if ! -w $file;

    my @lines = $self->util->file_read( $file );
    foreach my $line (@lines) { #
        if ( $line =~ /^[#]{0,1}PIDFILE/ ) {
            $line = "PIDFILE=$cachedir/sqwebmaild.pid";
        };
    };
    $self->util->file_write( $file, lines=>\@lines );
}

sub sqwebmail_freebsd_port {
    my $self = shift;

    $self->gnupg_install();
    $self->courier_authlib();

    my $cgi     = $self->conf->{'toaster_cgi_bin'};
    my $datadir = $self->conf->{'toaster_http_docs'};
    my $cachedir = "/var/run/sqwebmail";

    if ( $cgi     =~ /\/usr\/local\/(.*)$/ ) { $cgi     = $1; }
    if ( $datadir =~ /\/usr\/local\/(.*)$/ ) { $datadir = $1; }

    my @args = "WITHOUT_AUTHDAEMON=yes";
    push @args, "CGIBINDIR=$cgi";
    push @args, "CGIBINSUBDIR=''";
    push @args, "WEBDATADIR=$datadir";
    push @args, "CACHEDIR=$cachedir";

    $self->freebsd->install_port( "sqwebmail",
        flags => join( ",", @args ),
        options => "# This file is generated by Mail::Toaster
# Options for sqwebmail-5.4.1
_OPTIONS_READ=sqwebmail-5.4.1
WITH_CACHEDIR=true
WITHOUT_FAM=true
WITHOUT_GDBM=true
WITH_GZIP=true
WITH_HTTPS=true
WITHOUT_HTTPS_LOGIN=true
WITH_ISPELL=true
WITH_MIMETYPES=true
WITHOUT_SENTRENAME=true
WITHOUT_CHARSET=true
WITHOUT_AUTH_LDAP=true
WITHOUT_AUTH_MYSQL=true
WITHOUT_AUTH_PGSQL=true
WITHOUT_AUTH_USERDB=true
WITH_AUTH_VCHKPW=true",
        );

    $self->freebsd->conf_check(
        check => "sqwebmaild_enable",
        line  => 'sqwebmaild_enable="YES"',
    );

    $self->sqwebmail_conf();

    print "sqwebmail: starting sqwebmaild.\n";
    my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $start  = "$prefix/etc/rc.d/sqwebmail-sqwebmaild";

        -x $start      ? $self->util->syscmd( "$start start" )
    : -x "$start.sh" ? $self->util->syscmd( "$start.sh start" )
    : carp "could not find the startup file for sqwebmaild!\n";

    $self->freebsd->is_port_installed( "sqwebmail" );
}

sub stunnel {
    my $self = shift;

    return $self->stunnel_freebsd() if $OSNAME eq 'freebsd';

    my $stunnel = $self->util->find_bin('stunnel', fatal=>0);

    $self->error("stunnel is not installed and you selected pop3_ssl_daemon eq 'qpop3d'. Either install stunnel or change your configuration settings." ) if ! -x $stunnel;
    return;
};

sub stunnel_freebsd {
    my $self = shift;
    return $self->freebsd->install_port( "stunnel",
        options => "#
# This file was generated by mail-toaster\n
# Options for stunnel-4.33
_OPTIONS_READ=stunnel-4.33
WITHOUT_FORK=true
WITH_PTHREAD=true
WITHOUT_UCONTEXT=true
WITHOUT_DH=true
WITHOUT_IPV6=true
WITH_LIBWRAP=true\n",
    );
};

sub supervise {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $supervise = $self->conf->{'qmail_supervise'} || "/var/qmail/supervise";
    my $prefix    = $self->conf->{'toaster_prefix'}  || "/usr/local";

    $self->toaster->supervise_dirs_create(%p);
    $self->toaster->service_dir_create(%p);

    $self->qmail->control_create(%p);
    $self->qmail->install_qmail_control_files(%p);
    $self->qmail->install_qmail_control_log_files(%p);

    $self->startup_script();
    $self->toaster->service_symlinks();
    $self->qmail->config();
    $self->supervise_startup(%p);
};

sub supervise_startup {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $svok = $self->util->find_bin( 'svok', verbose => 0);
    my $svc_dir = $self->conf->{qmail_service} || '/var/service';
    if ( (system "$svok $svc_dir/send") == 0 ) {
        $self->audit("supervised processes are already started");
        return;
    };

    my $start  = $self->util->find_bin( 'services', verbose => 0);
    print "\n\nStarting up qmail services (Ctrl-C to cancel).

If there's problems, you can stop all supervised services by running:\n
          $start stop\n
\n\nStarting in 5 seconds: ";
    foreach ( 1 .. 5 ) { print '.'; sleep 1; };
    print "\n";

    system "$start start";
}

sub startup_script {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $dl_site = $self->conf->{'toaster_dl_site'} || "http://www.tnpi.net";
    my $dl_url = "$dl_site/internet/mail/toaster";

    # make sure the service dir is set up
    return $self->error( "the service directories don't appear to be set up. I refuse to start them until this is fixed.") unless $self->toaster->service_dir_test();

    return $p{test_ok} if defined $p{test_ok};

    return $self->startup_script_freebsd() if $OSNAME eq 'freebsd';
    return $self->startup_script_darwin()  if $OSNAME eq 'darwin';

    $self->error( "There is no startup script support written for $OSNAME. If you know the proper method of doing so, please have a look at $dl_url/start/services.txt, adapt it to $OSNAME, and send it to matt\@tnpi.net." );
};

sub startup_script_darwin {
    my $self = shift;

    my $start = "/Library/LaunchDaemons/to.yp.cr.daemontools-svscan.plist";
    my $dl_site = $self->conf->{'toaster_dl_site'} || "http://www.tnpi.net";
    my $dl_url = "$dl_site/internet/mail/toaster";

    unless ( -e $start ) {
        $self->util->get_url( "$dl_url/start/to.yp.cr.daemontools-svscan.plist" );
        my $r = $self->util->install_if_changed(
            newfile  => "to.yp.cr.daemontools-svscan.plist",
            existing => $start,
            mode     => '0551',
            clean    => 1,
        ) or return;
        $r == 1 ? $r = "ok" : $r = "ok (current)";
        $self->audit( "startup_script: updating $start, $r" );
    }

    my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local";
    $start = "$prefix/sbin/services";

    if ( -w $start ) {
        $self->util->get_url( "$dl_url/start/services-darwin.txt" );

        my $r = $self->util->install_if_changed(
            newfile  => "services-darwin.txt",
            existing => $start,
            mode     => '0551',
            clean    => 1,
        ) or return;

        $r == 1 ? $r = "ok" : $r = "ok (current)";

        $self->audit( "startup_script: updating $start, $r" );
    }
};

sub startup_script_freebsd {
    my $self = shift;

    # The FreeBSD port for daemontools includes rc.d/svscan so we use it
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";
    my $start = "$confdir/rc.d/svscan";

    unless ( -f $start ) {
        print "WARNING: no svscan, is daemontools installed?\n";
        print "\n\nInstalling a generic startup file....";

        my $dl_site = $self->conf->{'toaster_dl_site'} || "http://www.tnpi.net";
        my $dl_url = "$dl_site/internet/mail/toaster";
        $self->util->get_url( "$dl_url/start/services.txt" );
        my $r = $self->util->install_if_changed(
            newfile  => "services.txt",
            existing => $start,
            mode     => '0751',
            clean    => 1,
        ) or return;

        $r == 1 ? $r = "ok" : $r = "ok (current)";

        $self->audit( "startup_script: updating $start, $r" );
    }

    $self->freebsd->conf_check(
        check => "svscan_enable",
        line  => 'svscan_enable="YES"',
    );

    # if the qmail start file is installed, nuke it
    unlink "$confdir/rc.d/qmail.sh" if -e "$confdir/rc.d/qmail";
    unlink "$confdir/rc.d/qmail.sh" if -e "$confdir/rc.d/qmail.sh";

    my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $sym = "$prefix/sbin/services";
    return 1 if ( -l $sym && -x $sym ); # already exists

    unlink $sym
        or return $self->error( "Please [re]move '$sym' and run again.",fatal=>0) if -e $sym;

    symlink( $start, $sym );
    $self->audit( "startup_script: added $sym as symlink to $start");
};

sub test {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    print "testing...\n";

    $self->test_qmail();
    sleep 1;
    $self->daemontools_test();
    sleep 1;
    $self->ucspi_test();
    sleep 1;

    $self->dump_audit(quiet=>1);  # clear audit history

    $self->test_supervised_procs();
    sleep 1;
    $self->test_logging();
    sleep 1;
    $self->vpopmail_test();
    sleep 1;

    $self->toaster->check_processes();
    sleep 1;
    $self->test_network();
    sleep 1;
    $self->test_crons();
    sleep 1;

    $self->qmail->check_rcpthosts();
    sleep 1;

    if ( ! $self->util->yes_or_no( "skip the mail scanner tests?", timeout  => 10 ) ) {
        $self->filtering_test();
    };
    sleep 1;

    if ( ! $self->util->yes_or_no( "skip the authentication tests?", timeout  => 10) ) {
        $self->test_auth();
    };

    # there's plenty more room here for more tests.

    # test DNS!
    # make sure primary IP is not reserved IP space
    # test reverse address for this machines IP
    # test resulting hostname and make sure it matches
    # make sure server's domain name has NS records
    # test MX records for server name
    # test for SPF records for server name

    # test for low disk space on /, qmail, and vpopmail partitions

    print "\ntesting complete.\n";
}

sub test_auth {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    $self->test_auth_setup() or return;

    $self->imap_test_auth();
    $self->pop3_test_auth();
    $self->smtp_test_auth();

    print
"\n\nNOTICE: It is normal for some of the tests to fail. This test suite is useful for any mail server, not just a Mail::Toaster. \n\n";

    # webmail auth
    # other ?
}

sub test_auth_setup {
    my $self = shift;

    my $qmail_dir = $self->conf->{'qmail_dir'};
    my $assign    = "$qmail_dir/users/assign";
    my $email     = $self->conf->{'toaster_test_email'};
    my $pass      = $self->conf->{'toaster_test_email_pass'};

    my $domain = ( split( '@', $email ) )[1];
    print "test_auth: testing domain is: $domain.\n";

    if ( ! -e $assign || ! grep {/:$domain:/} `cat $assign` ) {
        print "domain $domain is not set up.\n";
        return if ! $self->util->yes_or_no( "may I add it for you?", timeout => 30 );

        my $vpdir = $self->conf->{'vpopmail_home_dir'};
        system "$vpdir/bin/vadddomain $domain $pass";
        system "$vpdir/bin/vadduser $email $pass";
    }

    open( my $ASSIGN, '<', $assign) or return;
    return if ! grep {/:$domain:/} <$ASSIGN>;
    close $ASSIGN;

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "p5-Mail-POP3Client" ) or return;
        $self->freebsd->install_port( "p5-Mail-IMAPClient" ) or return;
        $self->freebsd->install_port( "p5-Net-SMTP_auth"   ) or return;
        $self->freebsd->install_port( "p5-IO-Socket-SSL"   ) or return;
    }
    return 1;
};

sub test_crons {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $tw = $self->util->find_bin( 'toaster-watcher.pl', verbose => 0);
    my $vpopdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    my @crons = ( "$vpopdir/bin/clearopensmtp", $tw);

    my $sqcache = "/usr/local/share/sqwebmail/cleancache.pl";
    push @crons, $sqcache if ( $self->conf->{'install_sqwebmail'} && -x $sqcache);

    print "checking cron processes\n";

    foreach (@crons) {
        $self->toaster->test("  $_", system( $_ ) ? 0 : 1 );
    }
}

sub test_dns {

    print <<'EODNS'
People forget to even have DNS setup on their Toaster, as Matt has said before. If someone forgot to configure DNS, chances are, little or nothing will work -- from port fetching to timely mail delivery.

How about adding a simple DNS check to the Toaster Setup test suite? And in the meantime, you could give some sort of crude benchmark, depending on the circumstances of the test data.  I am not looking for something too hefty, but something small and sturdy to make sure there is a good DNS server around answering queries reasonably fast.

Here is a sample of some DNS lookups you could perform.  What I would envision is that there were around 20 to 100 forward and reverse lookups, and that the lookups were timed.  I guess you could look them up in parallel, and wait a maximum of around 15 seconds for all of the replies.  The interesting thing about a lot of reverse lookups is that they often fail because no one has published them.

Iteration 1: lookup A records.
Iteration 2: lookup NS records.
Iteration 3: lookup MX records.
Iteration 4: lookup TXT records.
Iteration 5: Repeat step 1, observe the faster response time due to caching.

Here's a sample output!  Wow.

#toaster_setup.pl -s dnstest
Would you like to enter a local domain so I can test it in detail?
testmydomain-local.net
Would you like to test domains with underscores in them? (y/n)n
Testing /etc/rc.conf for a hostname= line...
This box is known as smtp.testmydomain-local.net
Verifying /etc/hosts exists ... Okay
Verifying /etc/host.conf exists ... Okay
Verifying /etc/nsswitch.conf exists ... Okay
Doing reverse lookups in in-addr.arpa using default name service....
Doing forward A lookups using default name service....
Doing forward NS lookups using default name service....
Doing forward MX lookups using default name service....
Doing forward TXT lookups using default name service....
Results:
[Any errors, like...]
Listing Reverses Not found:
10.120.187.45 (normal)
169.254.89.123 (normal)
Listing A Records Not found:
example.impossible.nonexistent.bogus.co.nl (normal)
Listing TXT Records Not found:
Attempting to lookup the same A records again....  Hmmm. much faster!
Your DNS Server (or its forwarder) seems to be caching responses. (Good)

Checking local domain known as testmydomain-local.net
Checking to see if I can query the testmydomain-local.net NS servers and retrieve the entire DNS record...
ns1.testmydomain-local.net....yes.
ns256.backup-dns.com....yes.
ns13.ns-ns-ns.net...no.
Do DNS records agree on all DNS servers?  Yes. identical.
Skipping SOA match.

I have discovered that testmydomain-local.net has no MX records.  Shame on you, this is a mail server!  Please fix this issue and try again.

I have discovered that testmydomain-local.net has no TXT records.  You may need to consider an SPF v1 TXT record.

Here is a dump of your domain records I dug up for you:
xoxoxoxox

Does hostname agree with DNS?  Yes. (good).

Is this machine a CNAME for something else in DNS?  No.

Does this machine have any A records in DNS?  Yes.
smtp.testmydomain-local.net is 192.168.41.19.  This is a private IP.

Round-Robin A Records in DNS pointing to another machine/interface?
No.

Does this machine have any CNAME records in DNS?  Yes. aka
box1.testmydomain-local.net
pop.testmydomain-local.net
webmail.testmydomain-local.net

***************DNS Test Output complete

Sample Forwards:
The first few may be cached, and the last one should fail.  Some will have no MX server, some will have many.  (The second to last entry has an interesting mail exchanger and priority.)  Many of these will (hopefully) not be found in even a good sized DNS cache.

I have purposely listed a few more obscure entries to try to get the DNS server to do a full lookup.
localhost
<vpopmail_default_domain if set>
www.google.com
yahoo.com
nasa.gov
sony.co.jp
ctr.columbia.edu
time.nrc.ca
distancelearning.org
www.vatican.va
klipsch.com
simerson.net
warhammer.mcc.virginia.edu
example.net
foo.com
example.impossible.nonexistent.bogus.co.nl

[need some obscure ones that are probably always around, plus some non-US sample domains.]

Sample Reverses:
Most of these should be pretty much static.  Border routers, nics and such.  I was looking for a good range of IP's from different continents and providers.  Help needed in some networks.  I didn't try to include many that don't have a published reverse name, but many examples exist in case you want to purposely have some.
127.0.0.1
224.0.0.1
198.32.200.50	(the big daddy?!)
209.197.64.1
4.2.49.2
38.117.144.45
64.8.194.3
72.9.240.9
128.143.3.7
192.228.79.201
192.43.244.18
193.0.0.193
194.85.119.131
195.250.64.90
198.32.187.73
198.41.3.54
198.32.200.157
198.41.0.4
198.32.187.58
198.32.200.148
200.23.179.1
202.11.16.169
202.12.27.33
204.70.25.234
207.132.116.7
212.26.18.3
10.120.187.45
169.254.89.123

[Looking to fill in some of the 12s, 50s and 209s better.  Remove some 198s]

Just a little project.  I'm not sure how I could code it, but it is a little snippet I have been thinking about.  I figure that if you write the code once, it would be quite a handy little feature to try on a server you are new to.

Billy

EODNS
      ;
}

sub test_logging {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    print "do the logging directories exist?\n";
    my $q_log = $self->conf->{'qmail_log_base'};
    foreach ( '', "pop3", "send", "smtp", "submit" ) {
        $self->toaster->test("  $q_log/$_", -d "$q_log/$_" );
    }

    print "checking log files?\n";
    my @active_log_files = ( "clean.log", "maildrop.log", "watcher.log",
                    "send/current",  "smtp/current",  "submit/current" );

    push @active_log_files, "pop3/current" if $self->conf->{'pop3_daemon'} eq 'qpop3d';

    foreach ( @active_log_files ) {
        $self->toaster->test("  $_", -f "$q_log/$_" );
    }
}

sub test_network {
    my $self = shift;
    return if $self->util->yes_or_no( "skip the network listener tests?",
            timeout  => 10,
        );

    my $netstat = $self->util->find_bin( "netstat", fatal => 0, verbose=>0 );
    return unless ($netstat && -x $netstat);

    if ( $OSNAME eq "freebsd" ) { $netstat .= " -alS " }
    if ( $OSNAME eq "darwin" )  { $netstat .= " -al " }
    if ( $OSNAME eq "linux" )   { $netstat .= " -a --numeric-hosts " }
    #if ( $OSNAME eq "linux" )   { $netstat .= " -an " }
    else { $netstat .= " -a " }
    ;    # should be pretty safe

    print "checking for listening tcp ports\n";
    my @listeners = `$netstat | grep -i listen`;
    foreach (qw( smtp http pop3 imap https submission pop3s imaps )) {
        $self->toaster->test("  $_", scalar grep {/$_/} @listeners );
    }

    print "checking for udp listeners\n";
    my @udps;
    push @udps, "snmp" if $self->conf->{'install_snmp'};

    foreach ( @udps ) {
        $self->toaster->test("  $_", `$netstat | grep $_` );
    }
}

sub test_qmail {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $qdir = $self->conf->{'qmail_dir'};
    print "does qmail's home directory exist?\n";
    $self->toaster->test("  $qdir", -d $qdir );

    print "checking qmail directory contents\n";
    my @tests = qw(alias boot control man users bin doc queue);
    push @tests, "configure" if ( $OSNAME eq "freebsd" );    # added by the port
    foreach (@tests) {
        $self->toaster->test("  $qdir/$_", -d "$qdir/$_" );
    }

    print "is the qmail rc file executable?\n";
    $self->toaster->test(  "  $qdir/rc", -x "$qdir/rc" );

    print "do the qmail users exist?\n";
    foreach (
        $self->conf->{'qmail_user_alias'}  || 'alias',
        $self->conf->{'qmail_user_daemon'} || 'qmaild',
        $self->conf->{'qmail_user_passwd'} || 'qmailp',
        $self->conf->{'qmail_user_queue'}  || 'qmailq',
        $self->conf->{'qmail_user_remote'} || 'qmailr',
        $self->conf->{'qmail_user_send'}   || 'qmails',
        $self->conf->{'qmail_log_user'}    || 'qmaill',
      )
    {
        $self->toaster->test("  $_", $self->user_exists($_) );
    }

    print "do the qmail groups exist?\n";
    foreach ( $self->conf->{'qmail_group'}     || 'qmail',
              $self->conf->{'qmail_log_group'} || 'qnofiles',
        ) {
        $self->toaster->test("  $_", scalar getgrnam($_) );
    }

    print "do the qmail alias files have contents?\n";
    my $q_alias = "$qdir/alias/.qmail";
    foreach ( qw/ postmaster root mailer-daemon / ) {
        $self->toaster->test( "  $q_alias-$_", -s "$q_alias-$_" );
    }
}

sub test_supervised_procs {
    my $self = shift;

    print "do supervise directories exist?\n";
    my $q_sup = $self->conf->{'qmail_supervise'} || "/var/qmail/supervise";
    $self->toaster->test("  $q_sup", -d $q_sup);

    # check supervised directories
    foreach (qw/smtp send pop3 submit/) {
        $self->toaster->test( "  $q_sup/$_",
            $self->toaster->supervised_dir_test( prot => $_, verbose=>1 ) );
    }

    print "do service directories exist?\n";
    my $q_ser = $self->conf->{'qmail_service'};

    my @active_service_dirs;
    foreach ( qw/ smtp send / ) {
        push @active_service_dirs, $self->toaster->service_dir_get( prot => $_ );
    }

    push @active_service_dirs, $self->toaster->service_dir_get( prot => 'pop3' )
        if $self->conf->{'pop3_daemon'} eq 'qpop3d';

    push @active_service_dirs, $self->toaster->service_dir_get( prot => "submit" )
        if $self->conf->{'submit_enable'};

    foreach ( $q_ser, @active_service_dirs ) {
        $self->toaster->test( "  $_", -d $_ );
    }

    print "are the supervised services running?\n";
    my $svok = $self->util->find_bin( "svok", fatal => 0 );
    foreach ( @active_service_dirs ) {
        $self->toaster->test( "  $_", system("$svok $_") ? 0 : 1 );
    }
};

sub ucspi_tcp {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    # pre-declarations. We configure these for each platform and use them
    # at the end to build ucspi_tcp from source.

    my $patches = [];
    my @targets = ( 'make', 'make setup check' );

    if ( $self->conf->{install_mysql} && $self->conf->{'vpopmail_mysql'} ) {
        $patches = ["ucspi-tcp-0.88-mysql+rss.patch"];
    }

    if ( $OSNAME eq "freebsd" ) {
        # install it from ports so it is registered in the ports db
        $self->ucspi_tcp_freebsd();
    }
    elsif ( $OSNAME eq "darwin" ) {
        $patches = ["ucspi-tcp-0.88-mysql+rss-darwin.patch"];
        @targets = $self->ucspi_tcp_darwin();
    }
    elsif ( $OSNAME eq "linux" ) {
        @targets = (
            "echo gcc -O2 -include /usr/include/errno.h > conf-cc",
            "make", "make setup check"
        );

#		Need to test MySQL patch on linux before enabling it.
#		$patches = ['ucspi-tcp-0.88-mysql+rss.patch', 'ucspi-tcp-0.88.errno.patch'];
#		$patch_args = "-p0";
    }

    # see if it is installed
    my $tcpserver = $self->util->find_bin( "tcpserver", fatal => 0, verbose=>0 );
    if ( $tcpserver ) {
        if ( ! $self->conf->{install_mysql} || !$self->conf->{'vpopmail_mysql'} ) {
            $self->audit( "ucspi-tcp: install, ok (exists)" );
            return 2; # we don't need mysql
        }
        my $strings = $self->util->find_bin( "strings", verbose=>0 );
        if ( grep( /sql/, `$strings $tcpserver` ) ) {
            $self->audit( "ucspi-tcp: mysql support check, ok (exists)" );
            return 1;
        }
        $self->audit( "ucspi-tcp is installed but w/o mysql support, " .
            "compiling from sources.");
    }

    # save some bandwidth
    if ( -e "/usr/ports/distfiles/ucspi-tcp-0.88.tar.gz" ) {
        copy( "/usr/ports/distfiles/ucspi-tcp-0.88.tar.gz",
              "/usr/local/src/ucspi-tcp-0.88.tar.gz"
        );
    }

    $self->util->install_from_source(
        package   => "ucspi-tcp-0.88",
        patches   => $patches,
        patch_url => "$self->conf->{'toaster_dl_site'}$self->conf->{'toaster_dl_url'}/patches",
        site      => 'http://cr.yp.to',
        url       => '/ucspi-tcp',
        targets   => \@targets,
    );

    return $self->util->find_bin( "tcpserver", fatal => 0, verbose => 0 ) ? 1 : 0;
}

sub ucspi_tcp_darwin {
    my $self = shift;

    my @targets = "echo '/opt/local' > conf-home";

    if ( $self->conf->{'vpopmail_mysql'} ) {
        my $mysql_prefix = "/opt/local";
        if ( !-d "$mysql_prefix/include/mysql" ) {
            if ( -d "/usr/include/mysql" ) {
                $mysql_prefix = "/usr";
            }
        }
        push @targets,
"echo 'gcc -s -I$mysql_prefix/include/mysql -L$mysql_prefix/lib/mysql -lmysqlclient' > conf-ld";
        push @targets,
            "echo 'gcc -O2 -I$mysql_prefix/include/mysql' > conf-cc";
    }

    push @targets, "make";
    push @targets, "make setup";
    return @targets;
};

sub ucspi_tcp_freebsd {
    my $self = shift;
    $self->freebsd->install_port( "ucspi-tcp",
        flags   => "BATCH=yes WITH_RSS_DIFF=1",
        options => "#\n# This file is auto-generated by 'make config'.
# No user-servicable parts inside!
# Options for ucspi-tcp-0.88_2
_OPTIONS_READ=ucspi-tcp-0.88_2
WITHOUT_MAN=true
WITH_RSS_DIFF=true
WITHOUT_SSL=true
WITHOUT_RBL2SMTPD=true\n",
    );
};

sub ucspi_test {
    my $self  = shift;

    print "checking ucspi-tcp binaries...\n";
    foreach (qw( tcprules tcpserver rblsmtpd tcpclient recordio )) {
        $self->toaster->test("  $_", $self->util->find_bin( $_, fatal => 0, verbose=>0 ) );
    }

    if ( $self->conf->{install_mysql} && $self->conf->{'vpopmail_mysql'} ) {
        my $tcpserver = $self->util->find_bin( "tcpserver", fatal => 0, verbose=>0 );
        $self->toaster->test( "  tcpserver mysql support",
            scalar `strings $tcpserver | grep sql`
        );
    }

    return 1;
}

sub user_add {
    my ($self, $user, $uid, $gid, %opts) = @_;

    return if ! $user;
    return if $self->user_exists($user);

    my $homedir = $opts{homedir};
    my $shell = $opts{shell} || '/sbin/nologin';

    my $cmd;
    if ( $OSNAME eq 'linux' ) {
        $cmd = $self->util->find_bin( 'useradd' );
        $cmd .= " -s $shell";
        $cmd .= " -d $homedir" if $homedir;
        $cmd .= " -u $uid" if $uid;
        $cmd .= " -g $gid" if $gid;
        $cmd .= " -m $user";
    }
    elsif ( $OSNAME eq 'freebsd' ) {
        $cmd = $self->util->find_bin( 'pw' );
        $cmd .= " useradd -n $user -s $shell";
        $cmd .= " -d $homedir" if $homedir;
        $cmd .= " -u $uid " if $uid;
        $cmd .= " -g $gid " if $gid;
        $cmd .= " -m -h-";
    }
    elsif ( $OSNAME eq 'darwin' ) {
        $cmd = $self->util->find_bin( 'dscl', fatal => 0 );
        my $path = "/users/$user";
        if ( $cmd ) {
            $self->util->syscmd( "$cmd . -create $path" );
            $self->util->syscmd( "$cmd . -createprop $path uid $uid");
            $self->util->syscmd( "$cmd . -createprop $path gid $gid");
            $self->util->syscmd( "$cmd . -createprop $path shell $shell" );
            $self->util->syscmd( "$cmd . -createprop $path home $homedir" ) if $homedir;
            $self->util->syscmd( "$cmd . -createprop $path passwd '*'" );
        }
        else {
            $cmd = $self->util->find_bin( 'niutil' );
            $self->util->syscmd( "$cmd -createprop . $path uid $uid");
            $self->util->syscmd( "$cmd -createprop . $path gid $gid");
            $self->util->syscmd( "$cmd -createprop . $path shell $shell");
            $self->util->syscmd( "$cmd -createprop . $path home $homedir" ) if $homedir;
            $self->util->syscmd( "$cmd -createprop . $path _shadow_passwd");
            $self->util->syscmd( "$cmd -createprop . $path passwd '*'");
        };
        return 1;
    }
    else {
        warn "cannot add user on OS $OSNAME\n";
        return;
    };
    return $self->util->syscmd( $cmd );
};

sub user_exists {
    my $self = shift;
    my $user = lc(shift) or die "missing user";
    my $uid = getpwnam($user);
    return ( $uid && $uid > 0 ) ? $uid : undef;
};

sub vpopmail {
    shift @_;
    require Mail::Toaster::Setup::Vpopmail;
    my $vpopmail = Mail::Toaster::Setup::Vpopmail->new;
    return $vpopmail->install(@_);
};

sub vqadmin {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{'install_vqadmin'} ) {
        $self->audit( "vqadmin: installing, skipping (disabled)" );
        return;
    }

    my $cgi  = $self->conf->{'toaster_cgi_bin'}   || "/usr/local/www/cgi-bin";
    my $data = $self->conf->{'toaster_http_docs'} || "/usr/local/www/data";

    if ( $cgi && $cgi =~ /\/usr\/local\/(.*)$/ ) {
        $cgi = $1;
        chop $cgi if $cgi =~ /\/$/; # remove trailing /
    }

    if ( $data =~ /\/usr\/local\/(.*)$/ ) {
        chop $data if $data =~ /\/$/; # remove trailing /
        $data = $1;
    }

    my @defs = 'CGIBINDIR="' . $cgi . '"';
    push @defs, 'WEBDATADIR="' . $data . '"';

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "vqadmin", flags => join( ",", @defs ) )
            and return 1;
    }

    my $make  = $self->util->find_bin("gmake", fatal=>0, verbose=>0);
    $make   ||= $self->util->find_bin("make", fatal=>0, verbose=>0);

    print "trying to build vqadmin from sources\n";

    $self->util->install_from_source(
        package        => "vqadmin",
        site           => "http://vpopmail.sf.net",
        url            => "/downloads",
        targets        => [ "./configure ", $make, "$make install-strip" ],
        source_sub_dir => 'mail',
    );
}

sub webmail {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    # if the cgi_files dir is not available, we can't do much.
    my $tver = $Mail::Toaster::VERSION;
    my $dir = './cgi_files';
    if ( ! -d $dir ) {
        if ( -d "/usr/local/src/Mail-Toaster-$tver/cgi_files" ) {
            $dir = "/usr/local/src/Mail-Toaster-$tver/cgi_files";
        }
    };

    return $self->error( "You need to run this target while in the Mail::Toaster directory!\n"
        . "Try this instead:

   cd /usr/local/src/Mail-Toaster-$tver
   bin/toaster_setup.pl -s webmail

You are currently in " . Cwd::cwd ) if ! -d $dir;

    # set the hostname in mt-script.js
    my $hostname = $self->conf->{'toaster_hostname'};

    my @lines = $self->util->file_read("$dir/mt-script.js");
    foreach my $line ( @lines ) {
        if ( $line =~ /\Avar mailhost / ) {
            $line = qq{var mailhost = 'https://$hostname'};
        };
    }
    $self->util->file_write( "$dir/mt-script.js", lines => \@lines );

    my $htdocs = $self->conf->{'toaster_http_docs'} || '/usr/local/www/toaster';
    my $rsync = $self->rsync() or return;

    my $cmd = "$rsync -av $dir/ $htdocs/";
    print "about to run cmd: $cmd\n";

    print "\a";
    return if ! $self->util->yes_or_no(
            "\n\n\t CAUTION! DANGER! CAUTION!

    This action will install the Mail::Toaster webmail interface. Doing
    so may overwrite existing files in $htdocs. Is is safe to proceed?\n\n",
            timeout  => 60,
          );

    $self->util->syscmd( $cmd );
    return 1;
};

1;
__END__;


=head1 NAME

Mail::Toaster::Setup -  methods to configure and build all the components of a modern email server.

=head1 DESCRIPTION

The meat and potatoes of toaster_setup.pl. This is where the majority of the work gets done. Big chunks of the code and logic for getting all the various applications and scripts installed and configured resides in here.


=head1 METHODS

All documented methods in this package (shown below) accept two optional arguments, verbose and fatal. Setting verbose to zero will supress nearly all informational and debugging output. If you want more output, simply pass along verbose=>1 and status messages will print out. Fatal allows you to override the default behaviour of these methods, which is to die upon error. Each sub returns 0 if the action failed and 1 for success.

 arguments required:
   varies (most require conf)

 arguments optional:
   verbose - print status messages
   fatal   - die on errors (default)

 result:
   0 - failure
   1 - success

 Examples:

   1. $setup->apache( verbose=>0, fatal=>0 );
   Try to build apache, do not print status messages and do not die on error(s).

   2. $setup->apache( verbose=>1 );
   Try to build apache, print status messages, die on error(s).

   3. if ( $setup->apache( ) { print "yay!\n" };
   Test to see if apache installed correctly.

=over

=item new

To use any methods in Mail::Toaster::Setup, you must create a setup object:

  use Mail::Toaster::Setup;
  my $setup = Mail::Toaster::Setup->new;

From there you can run any of the following methods via $setup->method as documented below.

Many of the methods require $conf, which is a hashref containing the contents of toaster-watcher.conf.

=item clamav

Install ClamAV, configure the startup and config files, download the latest virus definitions, and start up the daemons.


=item config - personalize your toaster-watcher.conf settings

There are a subset of the settings in toaster-watcher.conf which must be personalized for your server. Things like the hostname, where you store your configuration files, html documents, passwords, etc. This function checks to make sure these settings have been changed and prompts for any necessary changes.

 required arguments:
   conf


=item config_tweaks

Makes changes to the config file, dynamically based on detected circumstances such as a jailed hostname, or OS platform. Platforms like FreeBSD, Darwin, and Debian have package management capabilities. Rather than installing software via sources, we prefer to try using the package manager first. The toaster-watcher.conf file typically includes the latest stable version of each application to install. This subroutine will replace those version numbers with with 'port', 'package', or other platform specific tweaks.

=item daemontools

Fetches sources from DJB's web site and installs daemontools, per his instructions.

=item dependencies

  $setup->dependencies( );

Installs a bunch of dependency programs that are needed by other programs we will install later during the build of a Mail::Toaster. You can install these yourself if you would like, this does not do anything special beyond installing them:

ispell, gdbm, setquota, expect, maildrop, autorespond, qmail, qmailanalog, daemontools, openldap-client, Crypt::OpenSSL-RSA, DBI, DBD::mysql.

required arguments:
  conf

result:
  1 - success
  0 - failure


=item djbdns

Fetches djbdns, compiles and installs it.

  $setup->djbdns( );

 required arguments:
   conf

 result:
   1 - success
   0 - failure


=item expect

Expect is a component used by courier-imap and sqwebmail to enable password changing via those tools. Since those do not really work with a Mail::Toaster, we could live just fine without it, but since a number of FreeBSD ports want it installed, we install it without all the extra X11 dependencies.


=item ezmlm

Installs Ezmlm-idx. This also tweaks the port Makefile so that it will build against MySQL 4.0 libraries if you don't have MySQL 3 installed. It also copies the sample config files into place so that you have some default settings.

  $setup->ezmlm( );

 required arguments:
   conf

 result:
   1 - success
   0 - failure


=item filtering

Installs SpamAssassin, ClamAV, simscan, QmailScanner, maildrop, procmail, and programs that support the aforementioned ones. See toaster-watcher.conf for options that allow you to customize which programs are installed and any options available.

  $setup->filtering();


=item maildrop

Installs a maildrop filter in $prefix/etc/mail/mailfilter, a script for use with Courier-IMAP in $prefix/sbin/subscribeIMAP.sh, and sets up a filter debugging file in /var/log/mail/maildrop.log.

  $setup->maildrop( );


=item maildrop_filter

Creates and installs the maildrop mailfilter file.

  $setup->maildrop_filter();


=item maillogs

Installs the maillogs script, creates the logging directories (toaster_log_dir/), creates the qmail supervise dirs, installs maillogs as a log post-processor and then builds the corresponding service/log/run file to use with each post-processor.

  $setup->maillogs();



=item mattbundle

Downloads and installs the latest version of MATT::Bundle.

  $setup->mattbundle(verbose=>1);

Don't do it. Matt::Bundle has been deprecated for years now.


=item mysql

Installs mysql server for you, based on your settings in toaster-watcher.conf. The actual code that does the work is in Mail::Toaster::Mysql so read the man page for Mail::Toaster::Mysql for more info.

  $setup->mysql( );


=item startup_script

Sets up the supervised mail services for Mail::Toaster

	$setup->startup_script( );

If they don't already exist, this sub will create:

	daemontools service directory (default /var/service)
	symlink to the services script

The services script allows you to run "services stop" or "services start" on your system to control the supervised daemons (qmail-smtpd, qmail-pop3, qmail-send, qmail-submit). It affects the following files:

  $prefix/etc/rc.d/[svscan|services].sh
  $prefix/sbin/services


=item test

Run a variety of tests to verify that your Mail::Toaster installation is working correctly.


=back


=head1 DEPENDENCIES

    IO::Socket::SSL


=head1 AUTHOR

Matt Simerson - matt@tnpi.net


=head1 SEE ALSO

The following are all perldoc pages:

 Mail::Toaster
 Mail::Toaster::Conf
 toaster.conf
 toaster-watcher.conf

 http://mail-toaster.org/

=cut
