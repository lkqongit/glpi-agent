package GLPI::Agent::Task::RemoteInventory::Remote::Ssh;

use strict;
use warnings;

use English qw(-no_match_vars);
use UNIVERSAL::require;

use parent 'GLPI::Agent::Task::RemoteInventory::Remote';

use GLPI::Agent::Tools;

use constant    supported => 1;

use constant    supported_modes => qw(ssh libssh2 perl);

my %cache;

sub _ssh {
    my ($self) = @_;

    my @command = qw(ssh -q -o BatchMode=yes);
    push @command, "-p", $self->port() if $self->port() && $self->port() != 22;
    push @command, "-l", $self->user() if $self->user();
    push @command, "-o ConnectTimeout=".$self->timeout() if $self->timeout();
    push @command, map { "-o $_" } grep { !empty($_) && /^\w+=/ } $self->options();

    return @command, $self->host(), "LANG=C";
}

sub disconnect {
    my ($self) = @_;

    if ($self->{_ssh2}) {
        $self->{_ssh2}->disconnect() if $self->{_ssh2}->sock;
        delete $self->{_ssh2};
        $self->{logger}->debug2("[libssh2] Disconnected from '".$self->host()."' remote host...");
    }

    # Cleanup cache
    $self->_reset_cache();
}

# APIs dedicated to Net::SSH2 support
sub _connect {
    my ($self) = @_;

    # We don't need to retry too early if an attempt failed recently
    if ($self->{_ssh2_dont_retry_before}) {
        return 0 if time < $self->{_ssh2_dont_retry_before};
        delete $self->{_ssh2_dont_retry_before};
    }

    unless ($self->{_ssh2} || ($self->mode('ssh') && !$self->mode('libssh2'))) {
        Net::SSH2->require();
        if ($EVAL_ERROR) {
            $self->{logger}->debug("Can't use libssh2: $EVAL_ERROR");
            # Don't retry to load libssh2 before a minute
            $self->{_ssh2_dont_retry_before} = time + 60;
        } else {
            my $timeout = $self->timeout();
            $self->{_ssh2} = Net::SSH2->new(timeout => $timeout * 1000);
            my $version = $self->{_ssh2}->version;
            $self->{logger}->debug2("Using libssh2 $version for ssh remote")
                if $self->{logger};
        }
    }

    my $ssh2 = $self->{_ssh2}
        or return 0;
    return 1 if defined($ssh2->sock);

    my $host = $self->host();
    my $port = $self->port();
    my $remote = $host . ($port && $port == 22 ? "" : ":$port");
    $self->{logger}->debug2("[libssh2] Connecting to '$remote' remote host...");
    if (!$ssh2->connect($host, $port // 22)) {
        my @error = $ssh2->error;
        $self->{logger}->debug("[libssh2] Can't reach $remote for ssh remoteinventory: @error");
        undef $self->{_ssh2};
        # Don't retry to connect with libssh2 before a minute
        $self->{_ssh2_dont_retry_before} = time + 60;
        return 0;
    }

    # Use Trust On First Use policy to verify remote host
    $self->{logger}->debug2("[libssh2] Check remote host key...");
    if ($OSNAME eq 'MSWin32') {
        # On windows, use vardir as HOME to store known_hosts file
        my $home = $self->config->{vardir};
        $ENV{HOME} = $self->config->{vardir};
        my $dotssh = "$home/.ssh";
        mkdir $dotssh unless -d $dotssh;
        unless (-e "$dotssh/known_hosts") {
            # Create empty known_hosts
            my $fh;
            close($fh)
                if open $fh, ">", "$dotssh/known_hosts";
        }
    }
    my $hostkey_checking = Net::SSH2::LIBSSH2_HOSTKEY_POLICY_TOFU();
    foreach my $option ($self->options()) {
        next unless $option =~ /^StrictHostKeyChecking=(yes|no|off|accept-new|ask)$/i;
        if ($option =~ /accept-new$/i) {
            $hostkey_checking = Net::SSH2::LIBSSH2_HOSTKEY_POLICY_TOFU();
        } elsif ($option =~ /yes$/i) {
            $hostkey_checking = Net::SSH2::LIBSSH2_HOSTKEY_POLICY_STRICT();
        } elsif ($option =~ /ask$/i) {
            $hostkey_checking = Net::SSH2::LIBSSH2_HOSTKEY_POLICY_ASK();
        } else {
            $hostkey_checking = Net::SSH2::LIBSSH2_HOSTKEY_POLICY_ADVISORY();
        }
    }
    unless ($ssh2->check_hostkey($hostkey_checking)) {
        my @error = $ssh2->error;
        $self->{logger}->error("[libssh2] Can't trust $remote for ssh remoteinventory: @error");
        undef $self->{_ssh2};
        # Don't retry to connect with libssh2 before a minute
        $self->{_ssh2_dont_retry_before} = time + 60;
        return 0;
    }

    # Support authentication by password
    if ($self->pass()) {
        $self->{logger}->debug2("[libssh2] Trying password authentication...");
        my $user = $self->user();
        unless ($user) {
            if ($ENV{USER}) {
                $user = $ENV{USER};
                $self->{logger}->debug2("[libssh2] Trying '$user' as login");
            } else {
                $self->{logger}->error("[libssh2] No user given for password authentication");
            }
        }
        if ($user) {
            unless ($ssh2->auth_password($user, $self->pass())) {
                my @error = $ssh2->error;
                $self->{logger}->debug("[libssh2] Can't authenticate to $remote with given password for ssh remoteinventory: @error");
            }
            if ($ssh2->auth_ok) {
                $self->{logger}->debug2("[libssh2] Authenticated on $remote remote with given password");
                $self->user($user);
                return 1;
            }
        }
    }

    # Find private keys in default user env
    if (!$self->{_private_keys} || $self->{_private_keys_lastscan} < time-60) {
        $self->{_private_keys} = {};
        foreach my $file (glob($ENV{HOME}."/.ssh/*")) {
            next unless getFirstMatch(
                file    => $file,
                pattern => qr/^-----BEGIN (.*) PRIVATE KEY-----$/,
            );
            my ($key) = $file =~ m{/([^/]+)$};
            $self->{_private_keys}->{$key} = $file;
        }
        $self->{_private_keys_lastscan} = time;
    }

    # Support public key authentication
    my $user = $self->user() // $ENV{USER};
    foreach my $private (sort(keys(%{$self->{_private_keys}}))) {
        $self->{logger}->debug2("[libssh2] Trying publickey authentication using $private key...");
        my $file = $self->{_private_keys}->{$private};
        my $pubkey;
        $pubkey = $file.".pub" if -e $file.".pub";
        next unless $ssh2->auth_publickey($user, $pubkey, $file, $self->pass());
        if ($ssh2->auth_ok) {
            $self->{logger}->debug2("[libssh2] Authenticated on $remote remote with $private key");
            return 1;
        }
    }

    $self->{logger}->error("[libssh2] Can't authenticate on $remote remote host");
    undef $self->{_ssh2};

    # Don't retry libssh2 before a minute
    $self->{_ssh2_dont_retry_before} = time + 60;

    return 0;
}

sub _ssh2_exec_status {
    my ($self, $command) = @_;

    # Support Net::SSH2 facilities to exec command
    return unless $self->_connect();

    my $ret;
    my $chan = $self->{_ssh2}->channel();
    $chan->ext_data('ignore');
    $self->{logger}->debug2("Testing \"$command\"...");
    if ($chan && $chan->exec("LANG=C $command")) {
        $ret = $chan->exit_status();
        $chan->close;
    } else {
        $self->{logger}->debug2("[libssh2] Failed to start '$command'");
    }

    return $ret;
}

sub options {
    my ($self, $options) = @_;

    $self->{_options} = $options if ref($options) eq 'ARRAY';

    return $self->{_options} ? @{$self->{_options}} : ();
}

sub timeout {
    my ($self, $timeout) = @_;

    # Reset Net::SSH2 current client timeout if required
    $self->{_ssh2}->timeout($timeout * 1000) if $timeout && $self->{_ssh2};

    $self->SUPER::timeout($timeout);
}

sub checking_error {
    my ($self) = @_;

    my $libssh2 = $self->_connect();
    return "[libssh2] Can't run simple command on remote, check server is up and ssh access is setup"
        if $self->mode('libssh2') && !$self->mode('ssh') && !$libssh2;

    my $root = $self->getRemoteFirstLine(command => "id -u");

    return "Can't run simple command on remote, check server is up and ssh access is setup"
        unless defined($root) && length($root);

    $self->{logger}->warning("You should execute remote inventory as super-user on remote host")
        unless $root eq "0";

    return "Mode perl required but can't run perl"
        if $self->mode('perl') && ! $self->remoteCanRun("perl");

    my $deviceid = $self->getRemoteFirstLine(file => ".glpi-agent-deviceid");
    if ($deviceid) {
        $self->deviceid(deviceid => $deviceid);
    } else {
        my $hostname = $self->getRemoteHostname()
            or return "Can't retrieve remote hostname";
        $deviceid = $self->deviceid(hostname => $hostname)
            or return "Can't compute deviceid getting remote hostname";

        my $command = "echo $deviceid >.glpi-agent-deviceid";

        # Support Net::SSH2 facilities to exec command
        my $ret = $self->_ssh2_exec_status($command);
        if (defined($ret)) {
            if ($ret) {
                $self->{logger}->warning("[libssh2] Failed to store deviceid");
            } else {
                return '';
            }
        }

        # Don't try ssh command if mode has been set to libssh2 only
        return "[libssh2] Failed to store deviceid on remote"
            if $self->mode('libssh2') && !$self->mode('ssh');

        system($self->_ssh(), "sh", "-c", "'$command'") == 0
            or return "[ssh] Can't store deviceid on remote";
    }

    return '';
}

sub getRemoteFileHandle {
    my ($self, %params) = @_;

    my $command;
    if ($params{file}) {
        # Support Net::SSH2 facilities to read file with sftp protocol
        if ($self->{_ssh2}) {
            # Reconnect if needed
            $self->_connect();
            my $sftp = $self->{_ssh2}->sftp();
            if ($sftp) {
                $self->{logger}->debug2("[libssh2] Trying to read '$params{file}' via sftp subsystem");
                my $fh = $sftp->open($params{file});
                return $fh if $fh;
                my @error = $sftp->error;
                if (@error && $error[0]) {
                    if ($error[0] == 2) { # SSH_FX_NO_SUCH_FILE
                        $self->{logger}->debug2("[libssh2] '$params{file}' file not found");
                        return;
                    } elsif ($error[0] == 3) { # SSH_FX_PERMISSION_DENIED
                        $self->{logger}->debug2("[libssh2] Not authorized to read '$params{file}'");
                        return;
                    } else {
                        $self->{logger}->debug2("[libssh2] Unsupported SFTP error (@error)");
                    }
                }

                # Also log libssh2 error
                @error = $self->{_ssh2}->error();
                $self->{logger}->debug2("Failed to open file with SFTP: libssh2 err code is $error[1]");
                $self->{logger}->debug("Failed to open file with SFTP: $error[2]");
            }
        }
        $command = "cat '$params{file}'";
    } elsif ($params{command}) {
        $command = $params{command};
    } else {
        $self->{logger}->debug("Unsupported getRemoteFileHandle() call with ".join(",",keys(%params))." parameters");
        return;
    }

    # Support Net::SSH2 facilities to exec command
    if ($self->{_ssh2}) {
        # Reconnect if needed
        $self->_connect();
        my $chan = $self->{_ssh2}->channel();
        if ($chan) {
            $chan->ext_data('ignore');
            $self->{logger}->debug2("[libssh2] Running \"$command\"...");
            if ($chan->exec("LANG=C $command")) {
                return $chan;
            }
        }
    }

    # Don't try ssh command if mode has been set to libssh2 only
    if ($self->mode('libssh2') && !$self->mode('ssh')) {
        $self->{logger}->debug("[libssh2] Failed to run \"$command\" in libssh2 mode only");
        return;
    }

    return getFileHandle(
        command => [ $self->_ssh(), $command ],
        logger  => $self->{logger},
        local   => 1
    );
}

sub remoteCanRun {
    my ($self, $binary) = @_;

    my $command = $binary =~ m{^/} ? "test -x '$binary'" : "which $binary >/dev/null";

    # Support Net::SSH2 facilities to exec command
    my $ret = $self->_ssh2_exec_status($command);
    return $ret == 0
        if defined($ret);

    # Don't try ssh command if mode has been set to libssh2 only
    return 0 if $self->mode('libssh2') && !$self->mode('ssh');

    my $stderr = $OSNAME eq 'MSWin32' ? "2>nul" : "2>/dev/null";

    return system($self->_ssh(), $command, $stderr) == 0;
}

sub _reset_cache {
    my ($self) = @_;
    my $cachekey = $self->host();
    $cachekey .= ":".$self->port() if $self->port();
    delete $cache{$cachekey};
}

sub _cache {
    my ($self, $key, $value) = @_;
    my $cachekey = $self->host();
    $cachekey .= ":".$self->port() if $self->port();
    return $cache{$cachekey}->{$key} = $value if defined($value);
    return unless exists($cache{$cachekey}) && defined($cache{$cachekey}->{$key});
    return $cache{$cachekey}->{$key};
}

sub OSName {
    my ($self) = @_;
    my $cached = $self->_cache("_osname");
    return $cached if defined($cached);
    my $osname = lc($self->getRemoteFirstLine(command => "uname -s"));
    if ($osname eq 'sunos') {
        $osname = 'solaris' ;
    } elsif ($osname eq 'hp-ux') {
        $osname = 'hpux';
    }
    return $self->_cache("_osname", $osname);
}

sub remoteGlob {
    my ($self, $glob, $test) = @_;
    return unless $glob;

    my $command = "sh -c 'for f in $glob; do if test ".($test // "-e")." \"\$f\"; then echo \$f; fi; done'";

    my @glob = $self->getRemoteAllLines(
        command => $command
    );

    return @glob;
}

sub getRemoteHostname {
    my ($self) = @_;
    # command is run remotely
    my $hostname = $self->getRemoteFirstLine(command => "hostname");

    # Fallback to get hostname from remote definition
    ($hostname) = $self->host() =~ /^(.*):?(\d+)?$/
        unless $hostname;

    return $hostname;
}

sub getRemoteFQDN {
    my ($self) = @_;
    # command is run remotely
    my $fqdn = $self->getRemoteFirstLine(command => "hostname -f");
    return $fqdn unless empty($fqdn);
    return $self->getRemoteFirstLine(command => "perl -e \"use Net::Domain qw(hostfqdn); print hostfqdn()\"")
        if $self->mode('perl');
}

sub getRemoteHostDomain {
    my ($self) = @_;
    # command will be run remotely
    my $domain = $self->getRemoteFirstLine(command => "hostname -d");
    return $domain unless empty($domain);
    return $self->getRemoteFirstLine(command => "perl -e \"use Net::Domain qw(hostdomain); print hostdomain()\"")
        if $self->mode('perl');
}

sub remoteTestFolder {
    my ($self, $folder) = @_;

    # Support Net::SSH2 facilities to exec command
    my $ret = $self->_ssh2_exec_status("test -d '$folder'");
    return $ret == 0
        if defined($ret);

    # Don't try ssh command if mode has been set to libssh2 only
    return 0 if $self->mode('libssh2') && !$self->mode('ssh');

    return system($self->_ssh(), "test", "-d", "'$folder'") == 0;
}

sub remoteTestFile {
    my ($self, $file, $filetest) = @_;

    # Support Net::SSH2 facilities to stat file with sftp protocol
    if ($self->{_ssh2}) {
        # Reconnect if needed
        $self->_connect();
        my $sftp = $self->{_ssh2}->sftp();
        if ($sftp) {
            if ($filetest && $filetest eq "r") {
                $self->{logger}->debug2("[libssh2] Trying to stat if '$file' is readable via sftp subsystem");
                my $fh = $sftp->open($file);
                return 0 unless $fh;
                close($fh);
                return 1;
            }
            $self->{logger}->debug2("[libssh2] Trying to stat '$file' via sftp subsystem");
            my $stat = $sftp->stat($file);
            return 1 if defined($stat);
            my @error = $sftp->error;
            if (@error && $error[0]) {
                if ($error[0] == 2) { # SSH_FX_NO_SUCH_FILE
                    return 0;
                } elsif ($error[0] == 3) { # SSH_FX_PERMISSION_DENIED
                    $self->{logger}->debug2("[libssh2] Not authorized to access '$file'");
                    return 0;
                } else {
                    $self->{logger}->debug2("[libssh2] Unsupported SFTP error (@error)");
                }
            }

            # Also log libssh2 error
            @error = $self->{_ssh2}->error();
            $self->{logger}->debug2("Failed to stat file with SFTP: libssh2 err code is $error[1]");
            $self->{logger}->debug("Failed to stat file with SFTP: $error[2]");
        }
    }

    my $testflag = $filetest && $filetest eq "r" ? "-r" :  "-e";

    # Support Net::SSH2 facilities to exec command
    my $ret = $self->_ssh2_exec_status("test $testflag '$file'");
    return $ret == 0
        if defined($ret);

    # Don't try ssh command if mode has been set to libssh2 only
    return 0 if $self->mode('libssh2') && !$self->mode('ssh');

    return system($self->_ssh(), "test", $testflag, "'$file'") == 0;
}

sub remoteTestLink {
    my ($self, $link) = @_;

    my $command = "test -h '$link'";

    # Support Net::SSH2 facilities to exec command
    my $ret = $self->_ssh2_exec_status($command);
    return $ret == 0
        if defined($ret);

    # Don't try ssh command if mode has been set to libssh2 only
    return 0 if $self->mode('libssh2') && !$self->mode('ssh');

    return system($self->_ssh(), "test", "-h", "'$link'") == 0;
}

# This API only need to return ctime & mtime
sub remoteFileStat {
    my ($self, $file) = @_;

    # Support Net::SSH2 facilities to stat file with sftp protocol
    if ($self->{_ssh2}) {
        # Reconnect if needed
        $self->_connect();
        my $sftp = $self->{_ssh2}->sftp();
        if ($sftp) {
            $self->{logger}->debug2("[libssh2] Trying to stat '$file' via sftp subsystem");
            my $stat = $sftp->stat($file);
            if (ref($stat) eq 'HASH') {
                return (
                    undef,
                    undef,
                    hex($stat->{mode}),
                    undef,
                    $stat->{uid},
                    $stat->{gid},
                    undef,
                    $stat->{size},
                    $stat->{atime},
                    $stat->{mtime},
                    undef,
                    undef
                );
            }
            my @error = $sftp->error;
            if (@error && $error[0]) {
                if ($error[0] == 2) { # SSH_FX_NO_SUCH_FILE
                    return;
                } elsif ($error[0] == 3) { # SSH_FX_PERMISSION_DENIED
                    $self->{logger}->debug2("[libssh2] Not authorized to access '$file'");
                    return;
                } else {
                    $self->{logger}->debug2("[libssh2] Unsupported SFTP error (@error)");
                }
            }

            # Also log libssh2 error
            @error = $self->{_ssh2}->error();
            $self->{logger}->debug2("Failed to stat file with SFTP: libssh2 err code is $error[1]");
            $self->{logger}->debug("Failed to stat file with SFTP: $error[2]");
        }
    }

    my $stat = $self->getRemoteFirstLine(command => "stat -t '$file'")
        or return;
    my ($name, $size, $bsize, $mode, $uid, $gid, $dev, $ino, $nlink, $major, $minor, $atime, $mtime, $stime, $ctime, $blocks) =
        split(/\s+/, $stat);
    return (undef, $ino, hex($mode), $nlink, $uid, $gid, undef, $size, $atime, $mtime, $ctime, $blocks);
}

sub remoteReadLink {
    my ($self, $link) = @_;
    # command will be run remotely
    return $self->getRemoteFirstLine(command => "readlink '$link'");
}

sub remoteGetNextUser {
    my ($self) = @_;
    unless ($self->{_users} && @{$self->{_users}}) {
        $self->{_users} = [
            map {
                my @entry = split(':', $_);
                {
                    name    => $entry[0],
                    uid     => $entry[2],
                    dir     => $entry[5]
                }
            } getAllLines( file => '/etc/passwd' )
        ];
    }
    return shift(@{$self->{_users}}) if $self->{_users};
}

sub remoteTimeZone {
    my ($self) = @_;

    my ($tz, $tz_name, $tz_offset, $fallback);

    $self->{logger}->debug2("Using date command to get timezone");
    my $timezone = getFirstLine(
        command => 'date +"%Z ; %z"',
        logger  => $self->{logger}
    );
    ($fallback, $tz_offset) = $timezone =~ /^(.*) ; ([-+]?\d+)$/
        unless empty($timezone);

    # Check TZ environment variable
    $timezone = getFirstLine(
        command => 'echo $TZ',
        logger  => $self->{logger}
    );
    $tz_name = $timezone unless empty($timezone);

    # Try other methods (inspired by DateTime::TimeZone::Local::Unix)
    unless ($tz_name) {
        $tz_name = trimWhitespace(getFirstLine(
            file    => '/etc/timezone',
            logger  => $self->{logger}
        ));
    }
    unless ($tz_name) {
        my $link = $self->remoteReadLink('/etc/localtime');
        $tz_name = $1
            if !empty($link) && $link =~ m{zoneinfo/(?:posix/|right/)?(.*)$};
    }
    unless ($tz_name) {
        $tz_name = trimWhitespace(getFirstMatch(
            file    => '/etc/TIMEZONE',
            pattern => qr/^\s*TZ\s*=\s*(\S+)/,
            logger  => $self->{logger}
        ));
    }
    unless ($tz_name) {
        $tz_name = trimWhitespace(getFirstMatch(
            file    => '/etc/sysconfig/clock',
            pattern => qr/^(?:TIME)?ZONE="([^"]+)"/,
            logger  => $self->{logger}
        ));
    }
    unless ($tz_name) {
        $tz_name = trimWhitespace(getFirstMatch(
            file    => '/etc/default/init',
            pattern => qr/^TZ=(.+)/,
            logger  => $self->{logger}
        ));
    }

    $tz->{NAME}   = $tz_name // $fallback
        unless empty($tz_name) && empty($fallback);
    $tz->{OFFSET} = $tz_offset
        unless empty($tz_offset);

    return $tz;
}

sub remotePerlModule {
    my ($self, $module, $version) = @_;

    my $command = "perl -M$module -e " .($version ? "'exit(\$".$module."::VERSION < $version)'" : "1");

    # Support Net::SSH2 facilities to exec command
    my $ret = $self->_ssh2_exec_status($command);
    return $ret == 0
        if defined($ret);

    # Don't try ssh command if mode has been set to libssh2 only
    return 0 if $self->mode('libssh2') && !$self->mode('ssh');

    my $stderr = $OSNAME eq 'MSWin32' ? "2>nul" : "2>/dev/null";

    return system($self->_ssh(), $command, $stderr) == 0;
}

sub remoteGetPrinters {
    my ($self) = @_;

    my @printers;

    if ($self->mode('perl')) {
        my $printer;
        foreach my $line ($self->getRemoteAllLines(
            command => "perl -MNet::CUPS -e 'map { print \"uri: \".\$_->getUri().\"\\nname: \".\$_->getName().\"\\ndriver: \".\$_->getOptionValue(\"printer-make-and-model\").\"\\ndescription: \".\$_->getDescription().\"\\n---\\n\" } Net::CUPS->new->getDestinations()'"
        )) {
            if ($line =~ /^name: (.+)$/) {
                $printer->{NAME} = $1;
            } elsif ($line =~ /^uri: (.+)$/) {
                $printer->{PORT} = $1;
                my ($opts) = $1 =~ /^[^?]+\?(.*)$/;
                my @opts = split("&", $opts // "");
                my ($serial) = map { /^serial=(.+)$/ } grep { /^serial=.+/ } @opts;
                ($serial) = map { /^uuid=(.+)$/ } grep { /^uuid=.+/ } @opts unless $serial;
                $printer->{SERIAL} = $serial if $serial;
            } elsif ($line =~ /^driver: (.+)$/) {
                $printer->{DRIVER} = $1;
            } elsif ($line =~ /^description: (.+)$/) {
                $printer->{DESCRIPTION} = $1;
            } elsif ($line =~ /^---$/) {
                push @printers, $printer if $printer;
                undef $printer;
            } elsif ($printer && $printer->{DESCRIPTION}) {
                $printer->{DESCRIPTION} .= "\n".$line;
            }
        }
    }

    return @printers;
}

1;
