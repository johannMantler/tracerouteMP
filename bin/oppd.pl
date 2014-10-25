#!/usr/bin/perl
#  
#  Copyright 2010 Verein zur Foerderung eines Deutschen Forschungsnetzes e. V.
#  
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#  
#       http://www.apache.org/licenses/LICENSE-2.0
#  
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#  
#  

# See embedded POD below for further information

# TODO
# - Check config statements (die if multiple logfile statements in config etc.)
# - Detect and remove orphaned PID file! Or should it be done in init scripts?
# - LS registration options
#   - ls_register and ls_url should be somehow merged and made configurable for
#     every service individually
#   - Use a decent default for the hostname sent to the LS
#   - hostname, organization and contact should perhaps get an ls_ prefix?
#   - Fail like on missing ls options like on missing ssl options
# - AS options
#   - auth and as_url should be somehow merged and made configurable for
#     every service individually
# - Should there be a timeout for processing a request?
# - Catch more signals? Set to IGNORE or treat them like TERM/INT?

use strict;
use warnings;

#DEBUG
use Data::Dumper;
#DEBUG

use FindBin;
use lib "$FindBin::RealBin/../lib";

# Commen modules for all Hades/oppd daemons:
use locale;
use POSIX qw(setsid setpgid :sys_wait_h);
use Log::Dispatch;
use Log::Dispatch::File;
use Log::Dispatch::Syslog;
use Log::Dispatch::Screen;
use Getopt::Long 2.32 qw(:config auto_help auto_version bundling);
use Pod::Usage;
use Config::General;
# DateTime not needed by now, but this would be necessary, because Hades.pm is
# NOT loaded.
#use DateTime;
#use DateTime::Locale;
#BEGIN {
#  if (DateTime::Locale->load(setlocale(LC_TIME))) {
#    DateTime->DefaultLocale(setlocale(LC_TIME));
#  }
#}


#Added new
use Log::Log4perl qw(:easy);



# Modules for this daemon:
use File::Spec;
use Socket;
use HTTP::Daemon;
#use HTTP::Daemon::SSL qw(debug3);
#$Net::SSLeay::trace = 2;
use HTTP::Daemon::SSL;
use HTTP::Response;

use NMWG;
use perfSONAR;
#use perfSONAR::Echo;
use perfSONAR::SOAP::Message;
use perfSONAR::Client::LS;
use perfSONAR::DataStruct;

use vars qw($VERSION);
$VERSION     = 0.51;

#
# Important variables that should be available and initialised before the
# (possible) execution of the END block
#
my (
  $proc_type, $pidfile_ok, $log, $log_prefix, $shutdown_gracefully,
  $shutting_down
);
INIT {
  $proc_type = "main";  # Some code is executed by all childrens that fork and
                        # do not exec afterwards. So we have to know
                        # what to do exactly.
                        # See e.g. END block and signal handlers for possible
                        # values.
  $pidfile_ok = 0;  # Care about existing pidfile in END
  $log = Log::Dispatch->new();
    # We also need the Log::Dispatch object for option verification quite early
  $log_prefix = ""; # Prepended to log message if set. This is intended for
                    # child processes and should not be "missused"!
  $shutdown_gracefully = 0; # END called without signal is like SIGTERM !!
                            #TODO Use another default?
  $shutting_down = 0; # This is set directly after entering the END block.
                      # Can be used to determine whether the process is
                      # going down at the moment. Important e.g. in signal
                      # handlers!
}


#
# Parse Configuration (commandline and file)
#

my (
  $configfile, $noconfig,
  $detach, $syslog, $logfile, $nologfile, $pidfile, $nopidfile,
  $loglevel, $verbose, $syslog_host, $syslog_ident, $syslog_facility,
  $ls_register, $keepalive, $max_proc,
  @ls_url, $auth, $as_url,
  $hostname, $port, $organization, $contact,
  $ssl, $ssl_cert_file, $ssl_key_file, $ssl_ca_file, $ssl_ca_path,
  $ssl_verify_client, $ssl_trusted_webserver_cn,
);

our %services;
my %messages;
my %lsKeys;

GetOptions(
  "config=s"      => \$configfile,
  "noconfig"      => \$noconfig,
  "detach|D!"     => \$detach,
  "logfile:s"     => \$logfile,
  "nologfile"     => \$nologfile,
  "pidfile:s"     => \$pidfile,
  "nopidfile"     => \$nopidfile,
  "syslog!"       => \$syslog,
  "syslog-host=s"     => \$syslog_host,
  "syslog-ident=s"    => \$syslog_ident,
  "syslog-facility=s" => \$syslog_facility,
  "loglevel=s"    => \$loglevel,
  "verbose|v"     => \$verbose,
  "register!"     => \$ls_register,
  "keepalive=i"   => \$keepalive,
  "max_proc=i"    => \$max_proc,
  "port=s"        => \$port,
  "auth!"         => \$auth,
  "as_url=s"      => \$as_url,
  "ssl!"                => \$ssl,
  "ssl-cert-file=s"     => \$ssl_cert_file,
  "ssl-key-file=s"      => \$ssl_key_file,
  "ssl-ca-file=s"       => \$ssl_ca_file,
  "ssl-ca-path=s"       => \$ssl_ca_path,
  "ssl-verify-client!"  => \$ssl_verify_client,
  "ssl-trusted-webserver-cn=s"  => \$ssl_trusted_webserver_cn,
) or pod2usage(2);

# Determine and load config file
my %Config = ();
my $Config;
if ($noconfig) {
  $configfile = undef;
} else {
  #$configfile ||= "$FindBin::RealBin/../etc/oppd.conf";
  $configfile ||= "/etc/oppd.conf";
  $Config = Config::General->new(
    -ConfigFile => $configfile,
    -ApacheCompatible => 1,
    #-AllowMultiOptions => 'no', # enable for EGEE because no LS is used
    -AutoTrue     => 1, # Could bring in some trouble, but it is really nice ;)
    -IncludeGlob  => 1, # We want to allow something like include oppd.d/*.conf
    -IncludeRelative  => 1, # Especially useful with -IncludeGlob
    -CComments    => 0, # Parsing is obviously broken in 2.36!
                        # Comments are found everywhere...
  );
  %Config = $Config->getall;
}


#
# Calculate options
# First not "undef" value is used.
# Order: command line, config file, default
#
$detach     = get_opt($detach,    $Config{detach},  1);
$nologfile  = get_opt($nologfile, 0); # No nologfile entry in config file!
if ($nologfile) {
  $logfile = undef;
} else {
  $logfile = get_opt($logfile,    $Config{logfile}, 0);
  if (!$logfile && $logfile ne "") {
    # logfile disabled
    $logfile = undef;
  } elsif ($logfile eq "1" || $logfile eq "") {
    # logfile enabled in configuration file or via --logfile without value
    $logfile = "/var/log/oppd.log";
  }
}
$nopidfile  = get_opt($nopidfile, 0); # No nopidfile entry in config file!
if ($nopidfile) {
  $pidfile = undef;
} else {
  $pidfile = get_opt($pidfile,    $Config{pidfile}, 1);
  if (!$pidfile && $pidfile ne "") {
    # pidfile disabled
    $pidfile = undef;
  } elsif ($pidfile eq "1" || $pidfile eq "") {
    # pidfile enabled in configuration file or via --pidfile without value
    $pidfile = "/var/run/oppd.pid";
  }
}
$syslog       = get_opt($syslog,      $Config{syslog},      0);
$syslog_host  = get_opt($syslog_host, $Config{'syslog-host'}, "");
$syslog_ident =
  get_opt($syslog_ident,    $Config{'syslog-ident'},    "oppd");
$syslog_facility =
  get_opt($syslog_facility, $Config{'syslog-facility'}, "daemon");
$loglevel     = get_opt($loglevel,    $Config{loglevel},    "info");
$verbose      = get_opt($verbose,     0); # No verbose entry in config file!
if ($verbose) {
  $loglevel = "info";
} else {
  pod2usage( { -message => "Invalid log level: $loglevel",
               -exitval => 2 } )  unless $log->level_is_valid($loglevel);
}
@ls_url = ();
#LS URL can be one or more, take care of that:
my $ls_opt = $Config{ls_url};
if(ref($ls_opt) eq "ARRAY"){
  print "01\n";
  @ls_url = @{$ls_opt};
} else {
  @ls_url = ($ls_opt) if defined $ls_opt;
}
$ls_register = get_opt($ls_register,  $Config{ls_register},   0);
$keepalive  = get_opt($keepalive, $Config{keepalive},  3600);
$max_proc   = get_opt($max_proc,  $Config{max_proc},   5);
$hostname   = get_opt($hostname,  $Config{hostname},   0);
$port       = get_opt($port,      $Config{port},   8090);
$organization = get_opt($organization, $Config{organization},  0);
$contact    = get_opt($contact,   $Config{contact},   0);
$auth       = get_opt($auth,      $Config{auth},    0);
$as_url     = get_opt($as_url,    $Config{as_url},  "");
$ssl            = get_opt($ssl,           $Config{ssl},           0);
$ssl_cert_file  = get_opt($ssl_cert_file, $Config{ssl_cert_file}, "");
$ssl_key_file   = get_opt($ssl_key_file,  $Config{ssl_key_file},  "");
$ssl_ca_file    = get_opt($ssl_ca_file,   $Config{ssl_ca_file},   "");
$ssl_ca_path    = get_opt($ssl_ca_path,   $Config{ssl_ca_path},   "");
$ssl_verify_client =
  get_opt($ssl_verify_client, $Config{ssl_verify_client}, 1);
$ssl_trusted_webserver_cn =
  get_opt($ssl_trusted_webserver_cn, $Config{ssl_trusted_webserver_cn}, "");

#TODO The following parameters need to be configurable by the user or changed
my $max_conn = $max_proc;
my $conn_timeout = 30;
my $gracetime = 30; # Really usefull as a parameter?
#/TODO

if ($ssl) {
  # We don't want defaults for the SSL related files, but warn instead that
  # something is wrong.
  # We also need to care at least whether $ssl_ca_path really exists, because
  # the module will only spit out a useless warning and then oppd will die.
  # Therefore you can find a lot of file test operators below...
  unless ($ssl_cert_file) {
    pod2usage(
      "No SSL certificate specified. Use --ssl-cert-file or edit config file."
    );
  }
  unless (-f $ssl_cert_file) {
    die "SSL certificate ($ssl_cert_file) not found\n";
  }
  unless(-r _) {
    die "SSL certificate ($ssl_cert_file) not readable\n";
  }
  unless ($ssl_key_file) {
    pod2usage(
      "No SSL key specified. Use --ssl-key-file or edit config file."
    );
  }
  unless (-f $ssl_key_file) {
    die "SSL key file ($ssl_key_file) not found\n";
  }
  unless (-r _) {
    die "SSL key file ($ssl_key_file) not readable\n";
  }
  unless ($ssl_ca_file || $ssl_ca_path || !$ssl_verify_client) {
    pod2usage(
      "No client certificate specified.\n" .
      "Use --ssl-ca-file, --ssl-ca-path, or edit config file.\n" .
      "If you know what you are doing you can also disable client authentication\n" .
      "by using --no-ssl-verify-client or editing config file appropriately.\n"
    );
  }
  if ($ssl_verify_client) {
    if ($ssl_ca_file) {
      unless (-f $ssl_ca_file) {
        die "SSL client certificate file ($ssl_ca_file) not found\n";
      }
      unless (-r _) {
        die "SSL client certificate file ($ssl_ca_file) not readable\n";
      }
    }
    if ($ssl_ca_path) {
      unless (-d $ssl_ca_path) {
        die "SSL client certificate path ($ssl_ca_path) not a directory\n";
      }
      unless (-r _) {
        die "SSL client certificate path ($ssl_ca_path) not readable\n";
      }
    }
  }
}

###################################################################################################################
#Begin new include for LOG4Perl
##################################################################################################################
# Defined loglevel in config file
# 0. trace
# 1. debug
# 2. = info
# 3. = warning
# 4. error
# 5. fatal
# Define this for Log4Perl

if (defined $logfile) {

    #check if $logfile is an absolute path, and add current path if not
    if (!File::Spec->file_name_is_absolute($logfile)){
        $logfile = File::Spec->rel2abs($logfile);
    }
}
    
my %L4P_loglevels = (
	trace => $TRACE,
	debug => $DEBUG,
	info => $INFO,
	warning => $WARN,
	error => $ERROR,
	fatal => $FATAL
);

#Set layout
my $log_layout;
if ($loglevel eq "debug"){
	$log_layout = '%d (%P) <%p> %F{1}:%L %M - %m%n';
}else{
	$log_layout = '%d <%p> %c - %m%n';
}

# Set options for L4P
my %logger_opts = (
    level  => $L4P_loglevels{$loglevel},
    file => "STDERR",
    layout => $log_layout,
);

#log file defined
if ($logfile) {
    $logger_opts{file} = ">>$logfile"; #Append mode
}
# If detach mode log to screen
unless ($detach) {
    $logger_opts{file} = "STDERR"; 
}
Log::Log4perl->easy_init( \%logger_opts );
my $logger = get_logger( "perSONAR-oppd" );

if ($syslog) {
    eval {
        my $syslog_socket = 'unix';
        if ($syslog_host) {
            $Sys::Syslog::host = $syslog_host;
            $syslog_socket = 'inet';
        }
        my $appender = Log::Log4perl::Appender->new(        
            "Log::Dispatch::Syslog",
                name => 'syslog',
                min_level => $loglevel,
                ident => "$syslog_ident",
                facility => "$syslog_facility",
                socket => "$syslog_socket",
                logopt => "ndelay",
                callbacks => sub {
                        my %p=@_;
                        $p{message} = "$log_prefix: $p{message}" if $log_prefix;
                        #TODO Not nice! How can we change this?
                        # callback for SD stuff
                        if ($p{service}) {
                            $p{service} =~ s/\//\_/g;
                            $p{service} .= ".";
                        }else {
                            $p{service} = "";
                        }
                        $p{message} = "OPPD." . $p{service} . uc($p{level}) . "% $p{message}";
                        #/TODO
                        return "$p{message}\n";
                    }, #End callback sub
                ); #End Appender-New'
        $logger->add_appender($appender);
    }; # End eval
  die "Cannot write to syslog: $@\n" if $@;
}
############################################################################################
# Look if a service in config is available
############################################################################################
unless (
  defined($Config{service}) && ref($Config{service}) eq "HASH"
  && %{$Config{service}}
) {
  pod2usage(
    "No services specified in config file"
  );
}
%services = %{$Config{service}};

# More flexible die:
# Put error into Log and afterwards die with same message.
# Also handy, because in the following code $@ is undef in die call:
# $log->error($@); die $@;
$SIG{__DIE__} = sub {
  die @_ if $^S; # Ignore dies from evals
  my $logmsg = join " - ", @_;
  chomp $logmsg; # No new line for Log::Dispatch !
  # We should only be called with initialised $log, but we can be a bit
  # more friendly by only using it if it was initialised:
  $logger->error($logmsg) if defined $logger && UNIVERSAL::isa($logger,'Log::Log4perl');
  die @_;
};

# More flexible warn:
# Put error into Log and afterwards warn with same message.
$SIG{__WARN__} = sub {
  my $logmsg = join " - ", @_;
  chomp $logmsg; # No new line for Log::Dispatch !
  # We should only be called with initialised $log, but we can be a bit
  # more friendly by only using it if it was initialised:
  $logger->warn($logmsg)
    if defined $logger && UNIVERSAL::isa($logger,'Log::Log4perl');
  warn @_;
};


#
# Load Authentication module for AA
#

if ($auth){
  if ($as_url eq ""){
    die ("Authentication not possible: variable $as_url not set!\n");
  }
  eval require perfSONAR::Auth;
  if ($@){
    die ("Error loading module perfSONAR::Auth: $@\n");
  }
}

#
# Load data modules for services
#

foreach my $service (keys %services){
  my $module = $services{$service}->{module};
  eval "use perfSONAR::$module";
  if ($@){
    die "Error loading module perfSONAR::$module: $@\n";
  }
  $services{$service}->{handler} =
    "perfSONAR::$module"->new(%{$services{$service}->{module_param}});
}

#
# Daemonize
#

#First check pidfile path to be absolute!
if ($pidfile){
  if (!File::Spec->file_name_is_absolute($pidfile)){
    $pidfile = File::Spec->rel2abs($pidfile);
  }
}

if ($detach) {
  # Fork once, and let the parent exit.
  my $pid = fork;
  if ($pid) { $proc_type = "dummy"; exit; }
  defined($pid) or die "Could not fork: $!\n";

  # Dissociate from the controlling terminal that started us and stop being
  # part of whatever process group we had been a member of.
  setsid() or die "Cannot start a new session: $!\n";

  # In Proc::Daemon there is a second fork executed with the following comment:
  # "Forks another child process and exits first child. This prevents the
  # potential of acquiring a controlling terminal."
  # This is nowhere else mentioned! Neither in Perl nor standard UNIX
  # documentation.
  # IMPORTANT: If you put a second fork here, the process group is most likely
  #            not correct for sending signals e.g. in the END block!

  # chdir and set umask
  chdir '/' or die "Cannot chdir to '/': $!\n";
  #umask 0;

  setup_pidfile() if defined $pidfile;
    # Do it before closing file handles! We need the error messages!

  # Close default file handles
  close STDIN or die "Could not close STDIN: $!\n";
  close STDOUT or die "Could not close STDOUT: $!\n";
  close STDERR or die "Could not close STDERR: $!\n";
  # Reopen stderr, stdout, stdin to /dev/null
  open(STDIN,  "</dev/null");
  open(STDOUT, ">/dev/null");
  open(STDERR, ">/dev/null");
} else {
  setpgid(0,0) or die "Cannot set process group id: $!\n";
  setup_pidfile() if defined $pidfile;
}

#
# Signal handlers
#

# Note: Signal handler are also called by children, if not changed after fork!

# die on typical signals
$SIG{INT} = $SIG{TERM} = sub {
  $logger->info("Caught SIG$_[0] - initiating shutdown");
  $shutdown_gracefully = $gracetime;
  exit 1;
  # See END {} for shutdown sequence
};
$SIG{USR1} = sub {
  # Gracefull shutdown with timeout
  $logger->info("Caught SIGUSR1 - initiating gracefull shutdown");
  $shutdown_gracefully = $gracetime;
  exit 1;
  # See END {} for shutdown sequence
};
$SIG{USR2} = sub {
  # Gracefull shutdown WITHOUT timeout -> Possibly blocking forever!
  $logger->info("Caught SIGUSR2 - initiating gracefull shutdown");
  $shutdown_gracefully = -1;
  exit 1;
  # See END {} for shutdown sequence
};
$SIG{HUP} = sub {
  $logger->warn("Caught SIGHUP - NO RELOAD SUPPORTED AT THE MOMENT");
  #TODO
};
$SIG{PIPE} = 'IGNORE';
$SIG{TSTP} = $SIG{TTOU} = $SIG{TTIN} = 'IGNORE'; # ignore tty signals
$SIG{CHLD} = \&REAPER; # Care about connection processes. See below.

#
# Inform that everything looks good
#

$logger->info("oppd service started");
$logger->info("available services: " . join(",", sort keys(%services)));
$logger->info("PID $$ written to $pidfile") if defined $pidfile;

#
# Start "daemon", the network side of the job ;-)
# 

#TODO: enable tracing output for our own SOAP implementation

my $http_daemon;
my $errno = 0;
my %server_options = (
  LocalPort => $port, ReuseAddr => 1
);
if ($ssl){
  my %ssl_options = (
    SSL_verify_mode => 0x0,
    SSL_cert_file => $ssl_cert_file,
    SSL_key_file => $ssl_key_file,
    SSL_passwd_cb => sub {
      die "Password protected server key file not supported\n";
    },
  );
  if ($ssl_verify_client) {
    $ssl_options{SSL_verify_mode} = 0x03;
    if ($ssl_ca_file) {
      $ssl_options{SSL_ca_file} = $ssl_ca_file;
    }
    if ($ssl_ca_path) {
      $ssl_options{SSL_ca_path} = $ssl_ca_path;
    }
  }
  $! = 0;
  $http_daemon = HTTP::Daemon::SSL->new(%server_options, %ssl_options);
  $errno = $!;
  if (!$http_daemon && (my $errstr = IO::Socket::SSL->errstr())) {
    # We are perhaps ignoring $! here ...
    die "SSL error while starting daemon: $errstr\n";
  }
} else {
  $! = 0;
  $http_daemon = HTTP::Daemon->new(%server_options);
  $errno = $!;
}

unless ($http_daemon){
  if ($errno != 0) {
    $! = $errno;
    die "Error starting HTTP daemon: $!\n";
  } else {
    die "Unknown error starting HTTP daemon\n";
  }
}

#
# start process for LS registration and keepalive
#

my $ls_reg_pid; # The pid of the LS registration process.
                # "undef", if no such process running (at the moment).
my $ls_reg_starttime = 0; # The time the registration process has started.
my $ls_reg_respawn_threshold = 60; # Respawn threshold for registration process
if ($ls_register){
  if (!@ls_url){
    $logger->error(
      "No URL for LS registration - Continuing without registration"
    );
  } else {
    fork_ls_reg();
  }
}

#
# Accept connections
#

my %connections = (); # We hold the pids for all connection processes to keep
                      # track of the correct number of connections
my %sigchild_pids = (); #Hold here the killed childs to delete from connections
my ($conn, $peer); # We need at least $conn outside the main loop
while (1) {
  # We cannot use 'while (my ($conn, $peer) = $http_daemon->accept)', because
  # HTTP:Daemon returns undef on signals and HTTP::Daemon::SSL also returns
  # undef on failure (see man page).
  ($conn, $peer) = $http_daemon->accept;
  unless (defined $conn) {
    # We haven't set a timeout that can also make accept() return undef!
    next if $!{EINTR};
      # Just ignore if accept() returned because a signal (most likely SIGCHLD)
      # was received. See 'man perlipc'.
    if ($!) {
      $logger->error("Error in incoming connection: $!");
    } elsif (my $errstr = IO::Socket::SSL->errstr()) {
      # SSL stuff is obviously not setting $! ...
      $logger->error("SSL error in incoming connection: $errstr");
    } else {
      $logger->error("Unknown error in incoming connection");
    }
    next;
  }
  my $peer_str = "UNKNOWN";
  if ($peer) {
    my ($port, $iaddr) = sockaddr_in($peer);
    $peer_str = inet_ntoa($iaddr) . ":" . $port;
  }
  $logger->info("Incoming connection from $peer_str");
  if (scalar(keys %connections)+1 > $max_conn) {
    my $msg = "Too many connections";
    $logger->error("$msg - closing connection to $peer_str");
    $conn->send_error(503, $msg); #RC_SERVICE_NOT_AVAILABLE
    close_socket($conn, "Error closing rejected connection");
    next;
  }
  if($ssl and $ssl_trusted_webserver_cn and $conn->peer_certificate("commonName") ne $ssl_trusted_webserver_cn) {
    my $msg = "CN of certificate (".$conn->peer_certificate("commonName").") not matching CN of trusted webserver";
    $log->warning("$msg - closing connection to $peer_str");
    $conn->send_error(503, $msg); #RC_SERVICE_NOT_AVAILABLE
    close_socket($conn, "Error closing rejected connection");
    next;
  }
  $logger->debug("Forking connection process for $peer_str");
  my $pid = fork();
  unless (defined $pid) {
    # The fork failed
    $logger->error("Forking connection process failed: $!");
    # Close the connection, because we have no process to care for it
    close_socket($conn, "Error closing incoming connection after failed fork");
    next;
  }
  unless ($pid == 0) {
    #
    # We are the parent
    #
    # Child cares about the connection -> We can close it
    close_socket($conn, "Error closing incoming connection in parent");
    $logger->debug("Connection process $pid/$peer_str started");
    $connections{$pid} = $peer_str; # We care about our children!
    $logger->debug(
      "Number of connections increased to " . scalar(keys %connections)
    );
    # Sometimes we have the situation that the 
    # The cild kills before parent has init it
    # We should chekc the list for this childs
    # look if killed child exist
    foreach my $child_pid (keys %sigchild_pids){
    	if ($connections{$child_pid}){
    		delete $connections{$child_pid};
    		delete $sigchild_pids{$child_pid};
    	}
    }
    next;
  }

  #
  # We are the child handling the connection
  #

  $proc_type = "connection";
  $log_prefix = "$$/$peer_str";

  $logger->debug("Connection process running");

  #
  # Signal handlers (if different from parent)
  #
  $SIG{CHLD} = 'IGNORE'; # Do not call REAPER and avoid zombie children
  $SIG{USR1} = $SIG{USR2} = 'IGNORE'; # graceful -> do not cut connections!

  # Close the listening socket (always done in children):
  close_socket($http_daemon, "Closing listening socket failed");

  #
  # Handle requests as they come in
  #
  $logger->debug("Setting connection timeout to $conn_timeout");
  # TODO: timeout() is broken with HTTP::Daemon::SSL
  # http://rt.cpan.org/Public/Bug/Display.html?id=45625
  # http://www.perlmonks.org/?node_id=761270
  $conn->timeout($conn_timeout) unless($ssl);
  while (my $request = $conn->get_request) {
    $logger->debug("Incoming request");
    $logger->debug("Disabling connection timeout");
    # TODO: timeout() is broken with HTTP::Daemon::SSL
    $conn->timeout(0) unless($ssl);
    my $response = new HTTP::Response;
    eval {
      #TODO At the moment we only get NMWG messages
      #but we need more undependency from it
      my $soap_message =
        perfSONAR::SOAP::Message->from_http_request($request);
      
      #Use the new DataStruct
      #At the moment NMWG parse to DS
      my $nmwg_message = NMWG::Message->new( ($soap_message->body)[0] );
      #$logger->info(Dumper($nmwg_message->as_string()));
      #TODO: Auth
      if ($auth){
        perfSONAR::Auth::authenticate($soap_message, $nmwg_message, $as_url);
      }
         
      #Create a DataStruct
      my $ds = perfSONAR::DataStruct->new($soap_message->uri,   $nmwg_message,\%services);
      my $nmwg_response;
      if ($ds->{ERROROCCUR}){
      	#Do here response on error
      	$logger->error("A error occured in creating data struct");
      }else{
        #$ds->{SERVICES} = \%services;
        #Run $ds
        perfSONAR->handle_request($ds);
      } 
      
      $nmwg_response = $ds->{REQUESTMSG};
      #We dont need ds 
      $ds = undef;
      #$logger->info($nmwg_response->as_string());
      #TODO $nmwg_message <-> $nmwg_response? clone?
      #TODO what about header?
      $soap_message->body($nmwg_response->as_dom()->documentElement);
      $response->content($soap_message->as_string);
    }; #End eval 
    if (my $eval_err = $@) {
      $log->info("Processing SOAP request failed: $eval_err");
      $response->content(
        perfSONAR::SOAP::Message->new(
          fault => perfSONAR::SOAP::Fault_v1_1->new(
            "", "Server.Internal", $eval_err
          )
        )->as_string
      );
    }
    $logger->debug("Sending response:\n".$response->content());
    $conn->send_response($response);
    $logger->debug("Setting connection timeout to $conn_timeout");
    # TODO: timeout() is broken with HTTP::Daemon::SSL
    $conn->timeout($conn_timeout) unless ($ssl);
  }
  if (my $reason = $conn->reason) {
    $logger->warn("Connection terminated: $reason");
  }
  # Cleanup -> close connection
  close_socket($conn, "Closing connection failed");
  $logger->debug("Exiting connection process");
  exit 0; # We are the child and have done our job -> exit
}


die "Internal error: This code should not be reached!\n";



### END OF MAIN ###



# Returns the first found parameter with a "defined" value
sub get_opt {
  foreach (@_) {
    return $_ if defined;
  }
  return undef;
}


END {
  # END could be executed without most if the initialisation from above already
  # done!
  # At least the following variables should be already available via the INIT
  # block (other should be considered to be possibly undef or empty):
  # $proc_type, $pidfile_ok, $log, $log_prefix, $shutdown_gracefully,
  # $shutting_down
  # Keep this also in mind for subs called in the code below!
  $shutting_down = 1;
  return if $proc_type eq "dummy"; # Do not execute anything below
  my $exitcode = $?; # Save $?
  if ($proc_type eq "main") {
    $logger->info("Starting shutdown sequence");

    my @pids = sort keys %connections;
    push @pids, $ls_reg_pid if $ls_reg_pid;
    
    if ($shutdown_gracefully && @pids) {
      $logger->info("Trying to terminate all known children gracefully");
      my $signal = $shutdown_gracefully > 0 ? "USR1" : "USR2";
      my @pids_new = ();

      foreach my $pid (@pids) {
        next if waitpid($pid, WNOHANG) != 0; # Already dead ...
        next if $pid == $ls_reg_pid; #Dont kill ls child because sending dereg msg
        kill $signal => $pid;
        push @pids_new, $pid;
      }
            
      @pids = @pids_new; @pids_new = ();
      push @pids, $ls_reg_pid if $ls_reg_pid; #LS not killed becaue doing deregister
      if (@pids) {
        # Some processes were signaled
        $logger->info("Sent SIG$signal to " . join(', ', @pids));
        # Wait till processes have ended or timeout is reached.
        # $shutdown_gracefully < 0 => Wait possibly forever!!
        my $timeout = $shutdown_gracefully < 0 ? 0 : $shutdown_gracefully;
        $logger->debug("Waiting for childern to exit" .
          ($timeout ? " with timeout of $timeout s" : " WITHOUT timeout")
        );
        eval {
          local $SIG{ALRM} = sub { die "alarm\n" };
          alarm $timeout;
          do {
            foreach my $pid (@pids) {
              push @pids_new, $pid if waitpid($pid, WNOHANG) == 0;
            }
            @pids = @pids_new; @pids_new = ();
            if (@pids) {
              $logger->debug("Processes alive: " . join(', ', @pids));
              sleep 1;
            }
          } until ! @pids;
          alarm 0;
        };
        die if $@ && $@ ne "alarm\n"; # propagate unexpected errors
      }#End if (@pids)
    }
    while (waitpid(-1,WNOHANG) > 0) {} # wait on all possibly exited children
    if (waitpid(-1, WNOHANG) >= 0) {
      # There are childern alive
      $logger->info("Trying to terminate all children using SIGTERM");
      local $SIG{TERM} = 'IGNORE';
      kill TERM => -$$;
      sleep 1; # Give everyone at least one second!
    }
    if ($pidfile_ok && -e $pidfile) {
      # Clean up PID file
      unlink $pidfile or $log->warning("Cannot delete pid file: $!");
    }
    $logger->info("Exiting");
    while (waitpid(-1,WNOHANG) > 0) {} # wait on all possibly exited children
    if (waitpid(-1, WNOHANG) >= 0) {
      # There is still someone alive! -> Take the axe and cut our branch
      $logger->warn("Not all children exited on SIGTERM -> KILLING EVERYTHING");
      kill KILL => -$$;
    }
  } elsif ($proc_type eq "connection") {
    # We don't want to log as many messages as with the other processes!
    #
    # Close connection socket. Connection is definitively available in
    # connection process, but may be closed. close_socket() is handling this
    # case correctly, though.
    close_socket($conn, "Closing connection failed");
  } elsif ($proc_type eq "lsreg") {
    $logger->info("Starting shutdown sequence for Lookup Service");
    if ($shutdown_gracefully) {
      perfSONAR::Client::LS::deregister();
    } else {
      #TODO Change this? Perhaps a deregistration with a small timeout?
      $logger->warn("Not deregistering services. Not a graceful shutdown.");
      #TODO Quit reg/dereg (close conn) somehow if they are running?
    }
    $logger->info("Exiting");
  } else {
    warn "Internal error: END block executed with unknown process type: " .
      "\"$proc_type\"\n";
  }
  $? = $exitcode; # Restore $?
}

#
# setup pid file
#
sub setup_pidfile {
  die("PID file ($pidfile) contains pid! Already running?\n")
    if -e $pidfile && -s $pidfile;
  open(PIDFILE, ">$pidfile")
    or die("Could not write PID file ($pidfile): $!\n");
  print PIDFILE "$$\n";
  $pidfile_ok = 1;
  close PIDFILE
    or die("Could not write PID file ($pidfile): $!\n");
}


#
# This is our SIGCHLD handler. We have to care of some things:
# - Make sure that connection processes are correctly withdrawn from
#   %connections.
# - Respawn LS registration process.
#
sub REAPER { # see also 'man perlipc'
    # don't change $! and $? outside handler
    local ($!,$?);
    
    while ((my $pid = waitpid(-1,WNOHANG)) > 0) {
        my $reason = " with exit code $?";
        if (exists $connections{$pid}) {
        $logger->info(
        "Connection process $pid for connection $connections{$pid} exited"
        . $reason
      );
      #save childpid for deleting 
      $sigchild_pids{$pid} = 1;
      delete $connections{$pid};
      $logger->debug(
        "Number of connections decreased to " . scalar(keys %connections)
      );
    } elsif ($pid == $ls_reg_pid) {
      $logger->debug("LS registration process $pid exited" . $reason);
      $ls_reg_pid = undef;
      fork_ls_reg() unless $shutting_down;
    } else {
      $log->debug("Unknown child process $pid exited" . $reason);
    }
  }
  $SIG{CHLD} = \&REAPER;  # loathe sysV
}


#
# Close a socket with special care about SSL sockets.
# Do only close sockets that are really open.
#
sub close_socket {
  my ($socket, $err_msg) = @_;
  return 1 unless $socket->opened; # Handle already closed sockets "silently"
  if (UNIVERSAL::isa($socket, "IO::Socket::SSL")) {
    unless ($socket->close(SSL_no_shutdown => 1)) {
      $logger->warn("$err_msg: $?");
      return;
    }
    if(my $errstr = $socket->errstr()) {
      $logger->warn("$err_msg: $errstr");
      return;
    }
    return 1;
  }
  if (UNIVERSAL::isa($socket, "IO::Socket")) {
    unless ($socket->close) {
      $logger->warn("$err_msg: $!");
      return;
    }
    return 1;
  }
  die "Internal error: close_socket(): Not a valid socket!\n";
}


#
# Fork away the child process for LS registration.
#
sub fork_ls_reg {
  my $ppid = $$; # Give our pid to the child
  $logger->info("Starting LS registration process");
  my $pid = fork();
  if (!defined($pid)) {
    #
    # Fork failed
    #
    $logger->warn("Could not fork LS registration process: $!");
    $logger->warn("Continuing without registration");
    return;
  }
  if ($pid != 0) {
    #
    # Child started, we are the parent, and child pid is in $pid
    #
    $ls_reg_pid = $pid;
    $ls_reg_starttime = time;
    return $pid; # return a bit more than just "true"
  }

  #
  # Child process
  #

  $proc_type = "lsreg";
  $log_prefix = "heartbeat/$$";

  # First try to prevent lots of respawns of ls registration process:
  if ($ls_reg_starttime+$ls_reg_respawn_threshold > time) {
      # Our $ls_reg_starttime is still the start time of our predecessor!
    $logger->info(
      "LS registration process respawning too fast" . 
      " - delayed for $ls_reg_respawn_threshold s"
    );
    sleep $ls_reg_respawn_threshold;
  }
  # Check if everything seems ok:
  unless (getppid == $ppid) {
    die "Internal error: Got wrong ppid from getppid!\n";
  }
  $logger->info("LS Registration process started");

  #
  # Signal handlers (if different from parent)
  #
  $SIG{CHLD} = 'IGNORE'; # Do not call REAPER and avoid zombie children

  # Close the listening socket (always done in children):
  close_socket($http_daemon, "Closing listening socket failed");
    
  # Start registration process
  #print Dumper(%services);
  if ($services{"MP/LSToolreg"}){
    $services{"MP/LSToolreg"}->{handler}->run();
  }
  perfSONAR::Client::LS::init(services => \%services,
    							ls_url => \@ls_url,
    							hostname => $hostname, 
    							port => $port,
    							organization => $organization,
    							contact => $contact,
    							log => $logger
  								);
  while (1) {
    sleep $keepalive;
    # Our parent may have died without being able to send us a signal. So take
    # a look whether it's already there and exit if not:
    unless (getppid == $ppid) {
      $logger->info("Parent died - initiating shutdown");
      exit 1;
    }
    perfSONAR::Client::LS::heartbeat();
  }
  die "Internal error: This code should not be reached!\n";
}



__END__



=head1 NAME

B<oppd.pl> - open perl perfSONAR daemon

=head1 SYNOPSIS

B<oppd.pl> [OPTIONS]



=head1 DESCRIPTION

This is the perl perfSONAR deamon script, running different perl perfSONAR
services. 
Services can be configured in the oppd.conf file.
For more information about perfSONAR, see L<http://www.perfsonar.net/>.


=head1 OPTIONS

This is a full list of available command line options. Please keep in mind
that this script does NOT provide the normal Hades command line options
or configuration file options!
Some options might even look familiar, although they are used slightly
different!

Nearly all options have a built in default that can be overwritten using
command line arguments or variables in the configuration file. 
Arguments have precedence over variables in the configuration file.


=over


=item B<--help>

Prints a help message and exits.


=item B<--config>=F<CONFIGFILE>

Read configuration file F<CONFIGFILE> for options.

Default: F</etc/oppd.conf>


=item B<--noconfig>

Do not read any configuration file. The parameter B<--config> is also ignored!

Default: off


=item B<--[no]detach>

Detach from terminal, aka run in background (instead of foreground).
Log messages will not be sent to F<STDERR>.

Default: on

Configuration file: B<detach>


=item B<--logfile>[=F<LOGFILE>]

Append messages to file F<LOGFILE>.

Just use B<--logfile> without the optional value to enable logging to default
log file F</var/log/oppd.log>.

You can use this option together with B<--syslog>.
Messages will then be written to both, log file and system log.

Default: off

Configuration file: B<logfile>


=item B<--nologfile>

Do not write to any log file. The parameter B<--logfile> is also ignored!

Default: off

Configuration file: use B<logfile>


=item B<--[no]syslog>

Whether messages should be written to system log.

You can use this option together with B<--logfile>.
Messages will then be written to both, log file and system log.

Default: off

Configuration file: B<syslog>


=item B<--syslog-host>=I<HOST>

Use I<HOST> as host to which system log messages are forwarded.

If this option is set to a dns name or ip address, all system log messages
are forwarded to the specified remote host.
If set to the empty string ("") logging is done locally.

Default: log locally

Configuration file: B<syslog-host>


=item B<--syslog-ident>=I<IDENT>

The string I<IDENT> will be prepended to all messages in the system log.

Default: I<oppd>

Configuration file: B<syslog-ident>


=item B<--syslog-facility>=I<FACILITY>

Use I<FACILITY> as type of program for system logging.

This string will be used as the system log facility for messages sent to
the system log.

See your C<syslog(3)> documentation for the facilities available on your
system.
Typical facilities are I<auth>, I<authpriv>, I<cron>, I<daemon>, I<kern>,
I<local0> through I<local7>, I<mail>, I<news>, I<syslog>, I<user>, I<uucp>.

Default: I<daemon>

Configuration file: B<syslog-facility>


=item B<--loglevel>=I<LOGLEVEL>

Use I<LOGLEVEL> as log level used for logging to syslog and to the log files.

This option is used for setting the verbosity of the running daemon.
The log levels available are the log levels defined by Log::Dispatch.

This is a list of values that should be accepted:
  0 = debug
  1 = info
  2 = notice
  3 = warning
  4 = err     = error
  5 = crit    = critical
  6 = alert
  7 = emerg   = emergency

Default: I<notice>

Configuration file: B<loglevel>


=item B<--verbose>

Just a handy abbreviation for B<--loglevel>=I<info>.

Default: not set, see B<--loglevel>

Configuration file: use B<loglevel>=I<info>


=item B<--pidfile>[=F<PIDFILE>]

Use PIDFILE as name of pid file.
The pid file contains the Process ID of the running oppd service.

Just use B<--pidfile> without the optional value to use the default pid file
F</var/run/oppd.pid>.

Default: F</var/run/oppd.pid>

Configuration file: B<pidfile>


=item B<--nopidfile>

Do not use a pid file. The parameter B<--pidfile> is also ignored!

Default: off

Configuration file: use B<pidfile>


=item B<--max_proc>=F<number of processes>

Maximum Number of processes to get forked for listening to requests.
This means that the service is able to handle B<--max_proc> 
numbers of requests simultaneously.

Default: 5 


=item B<--port>=PORT

Port number the service is listening to incoming requests.

Default: 8090


=item B<--[no]auth>

Use authentication with an perfSONAR Authentication Server. 
Note that you have to provide the option to specify the URL 
for the Authentication Server also.

Default: disabled


=item B<--as_url>=F<AS URL>

Provide URL for Authentication Server (see above). 
Only needed when authentication is enabled. 
Otherwise this option has no effect.

Default: none


=item B<--[no]register>

Registration to perfSONAR Lookup Server. 
When enabled, sends registration messages to Lookup Server specified by ls_url.

Default: disabled


=item B<--keepalive>=F<keepalive interval>

Interval in seconds when keepalive messages are sent to Lookup Service. 
This option has no effect, if Lookup Service registration is disabled. 
Note that the interval should be as long as possible, as this reduces 
communication overhead.

Default: none. At least 12 hours recommended.


=item B<--ls_url>=F<LS URL>

Provide URL for Lookup Server (see above). 
Only needed when Lookup Service registration is enabled. 
Otherwise this option has no effect.

Default: none


=item B<--hostname>=F<HOSTNAME> 

=item B<--organization>=F<ORGANIZATION>

=item B<--contact>=F<CONATCT>

These information are sent in the registration message to the 
Lookup Service.
If registration is not enabled, these options have no effect.

Default: none


=back



=head1 SIGNALS

The oppd can be controlled by using various signals.


=over


=item SIGHUP

Ignored and daemon is NOT reconfigured at the moment.


=item SIGINT and SIGTERM

Daemon terminates immediately. A SIGKILL is sent to the child processes
shortly after giving them the chance to exit properly by sending them a
SIGTERM.


=item SIGUSR1

Daemon terminates gracefully by sending all child processes a SIGUSR1 and
waiting a specified time (at the moment 30 seconds) before sending them a
SIGKILL.

=for comment TODO There might be an option for $gracetime in the future.


=item SIGUSR2

Daemon terminates gracefully by sending all child processes a SIGUSR2 and
will NEVER send a SIGKILL. The daemon might therefore wait forever and never
return!


=back



=head1 EXAMPLES

Start with a different configuration file:

  $ oppd.pl --config=/usr/local/etc/oppd.conf

Debug the daemon:

  $ oppd.pl --nodetach \
    --loglevel=debug --nologfile --nopidfile --nosyslog

Use other some other options instead of the ones from configuration file:

  $ oppd.pl --port=51234 --nologfile --pidfile=oppd.pid

=head1 SEE ALSO

oppd.conf



=head1 AUTHORS

DFN Labor Erlangen, win-labor@dfn.de
