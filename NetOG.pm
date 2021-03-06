#----------------------------------------------------------------
# Copyright (c) 2002 Benjamin Crowell, all rights reserved.
#
# This software is available under version 2 of the GPL license.
# The software is copyrighted, and you must agree to the
# license in order to have permission to copy it. The full
# text of the license is given in the file titled Copying.
#
#----------------------------------------------------------------

# This file incorporates code from Web Client Programming With Perl.

#use strict;

use Digest::SHA;

package NetOG;

use Cwd;

sub new {
  my $class = shift;
  my %args = (
                DATA_DIR=>find_data_dir(), # relative to where the code is
                @_
                );
  my $self = {};
  bless($self,$class);
  $self->{DATA_DIR} = $args{DATA_DIR};
  $self->{DATA_DIR} =~ s/[^\w\/]//g;
  return $self;
}

sub be_client {
  my $self = shift;
  my %args = @_;

  remember_i_am_client();

  my $err = '';
  if (detect_spotter_version()!=2) {
    set_spotter_version(3);
    $err = $self->be_client_given_spotter_version(3,%args);
    if ($err eq '') {
      return $err;
    }
  }
  set_spotter_version(2);
  $err = $self->be_client_given_spotter_version(2,%args);
  return $err;
}

sub be_client_given_spotter_version {
  my $self = shift;
  my $spotter_version = shift;
  my %args = (
                GB=>'',
                SERVER_KEY=>'', # needn't supply this if it's coming from preferences file associated with the GB
                PASSWORD=>'', # needn't supply this if user has already typed it in and it's in the GradeBook object
                PARS=>{},
                DATA=>'',
                HOST=>'',
                PORT=>80,
                @_
                );
  my $gb = $args{GB};
  my $server_key = $args{SERVER_KEY};
  my $password = $args{PASSWORD};
  my $data = $args{DATA};
  my $pars_ref = $args{PARS};
  my $host = $args{HOST};
  my $port = $args{PORT};

  my $debug = 0;

  #------------ send request --------------
  if (!$server_key) {$server_key = $gb->preferences()->get('server_key')}
  if (!$server_key) {return 'set_server_key'}
  if (!$password) {$password = $gb->password()}
  if ($debug) {print "host=$host, port=$port\n"}
  if (!defined open_TCP('F',$host, $port)) {return "error_connecting"}
  my $date = current_date_string();
  $pars_ref->{'client_date'} = $date;
  my $body = stringify_pars($pars_ref) . "\n" . $data;
  my $use_for_auth = $server_key . hash('spotter_instructor_password',$password) . hash($date,'*',$body);
  my $message =  hash($use_for_auth) . "\n" .  $body;
  my $request = build_post_request(MESSAGE=>$message);
  if ($debug) {print "request:\n============\n$request===========\n"}
  print F ($request);

  #-------------- get response --------------
  <F>; # HTTP line
  while(<F>=~ m/^(\S+):\s+(.+)/) {} # skip headers
  $self->{RESPONSE_AUTH} = <F>;
  my $response_pars_string = '';
  while (<F> =~ m/^([^=]+=[^\n]*)$/) {
    $response_pars_string = $response_pars_string . $1;
  }
  $self->{RESPONSE_PARS} = unstringify_pars($response_pars_string);
  my $err = '';
  if (exists $self->{RESPONSE_PARS}->{'err'}) {$err=$self->{RESPONSE_DATA}}
  $self->{RESPONSE_DATA} = '';
  while (my $line = <F>) {
    $self->{RESPONSE_DATA} = $self->{RESPONSE_DATA} . $line;
  }
  close(F);
  if ($self->{RESPONSE_DATA} =~ m@^<title>404 Not Found</title>@) {$err = 'not_found'}
  return $err;
}

sub build_post_request {
  my %args = (
    CGI_BIN=>'/cgi-bin',
    SCRIPT=>find_server_og_script(),
    MESSAGE=>'',
    @_,
  );
  my $cgi_bin =   $args{CGI_BIN};
  my $script =   $args{SCRIPT};
  my $message =     $args{MESSAGE};
  my $request = "POST $cgi_bin$script HTTP/1.0\r\n"
     ."Accept: */*\r\n"
     ."User-Agent: OpenGrade\r\n"
     ."Content-Length: ".length($message)."\r\n"
             #     ."Content-Type: text/plain\r\n"
     ."\r\n"
     .$message;
  return $request;
}

sub be_server_accepting {
  my $self = shift;
  my %args = (
                PARS=>{},
                DATA=>'',
                @_
                );
  my $content_length = $ENV{"CONTENT_LENGTH"};
  my $stuff;
  #sysread STDIN, $stuff, $content_length; # <-- Didn't work on long requests!
  my $line;
  while((length $stuff)<$content_length && ($line=<STDIN>)) {
    $stuff = $stuff . $line;
  }
  $stuff =~ m/^([^\n<]+)\n(([^=\n]+=[^\n]*\n)*)\n(.*)$/s;
  #open(FILE,">foo"); print FILE "---$content_length\n==================================\n$stuff\n==================================\n1=\n$1\n2=\n$2\n4=\n$4\n"; close FILE;
  my $body = $2."\n".$4;
  $self->{REQUEST_AUTH} = $1;
  $self->{REQUEST_DATA} = $4;
  $self->{REQUEST_PARS} = unstringify_pars($2);
  $self->{CONTENT_HASH} =  hash(($self->{REQUEST_PARS})->{'client_date'},'*',$body);
}

sub be_server_validating {
  my $self = shift;
  my %args = (
                @_
                );
  $self->{VALID} = 0; # guilty until proven innocent
  my $account = $self->request_par('account');
  my $user = $self->request_par('user');
  $account =~ s/[^\w]//g;
  $user =~ s/[^\w]//g;
  my $instructor_info_file = $self->{DATA_DIR}."$account/$user.instructor_info";
  my $sessions_file = $self->{DATA_DIR}."$account/$user.sessions";
  unless (-e $sessions_file) {
    open(F,">$sessions_file") or return 'unable_to_create_sessions_file';
    close F;
  }
  open F, ("<$instructor_info_file") or return 'unable_to_open_instructor_info_file';
  my $password_hash = '';
  my $server_key = '';
  while (my $line = <F>) {
    if ($line =~ m/server_key=\"([^\"]+)\"/) {$server_key = $1}
    if ($line =~ m/password_hash=\"([^\"]+)\"/) {$password_hash = $1}
  }
  close F;
  if ($password_hash eq '') {return 'no_password_hash_found'}
  if ($server_key eq '') {return 'no_server_key_found'}
  $self->{EXPECT_REQUEST_AUTH} = hash($server_key,$password_hash,$self->{CONTENT_HASH});
  if ($self->{EXPECT_REQUEST_AUTH} ne $self->{REQUEST_AUTH}) {return 'incorrect_password_or_server_key'};
  open F , ("<$sessions_file") or return 'unable_to_open_sessions_file_for_input';
  #$self->{VALID} = 1; return; #-----------------
  while (my $line = <F>) {
    chomp $line;
    if ($line eq $self->{EXPECT_REQUEST_AUTH}) {close F; return 'replay_error'}
  }
  close F;
  open F , (">>$sessions_file") or return 'unable_to_open_sessions_file_for_output';
  print F $self->{EXPECT_REQUEST_AUTH}."\n";
  close F;
  $self->{VALID} = 1;
  return '';
}

sub be_server_responding {
  my $self = shift;
  my %args = (
                PARS=>{},
                DATA=>'',
                @_
                );
  # Apache supplies the headers.
  print "\n"; # blank line between header and body of reply
  my $body = stringify_pars($args{PARS})."\n" . $args{DATA};
  print hash($self->{SERVER_KEY},$self->{REQUEST_AUTH},$body)."\n";
  print $body;
}

sub stringify_pars {
  my $pars_ref = shift;
  my %pars = %$pars_ref;
  my $result = '';
  foreach my $par(keys %pars) {
    $result = $result . $par . "=" . stringify($pars{$par}) . "\n";
  }
  return $result;
}

sub unstringify_pars {
  my $string = shift;
  my %pars = ();
  while ($string =~ /([^=\n]+)=([^\n]*)\n/g) {
    $pars{$1} = $2;
  }
  foreach my $par(keys %pars) {
    $pars{$par} = unstringify($pars{$par});
  }
  return \%pars;
}

sub stringify {
  my $x = shift;
  $x =~ s/\n/~~~newline~~~/g;
  $x =~ s/\"/~~~quote~~~/g;
  $x =~ s/\=/~~~equals~~~/g;
  return $x;
}


sub unstringify {
    my $x = shift;
    $x =~ s/~~~newline~~~/\n/g;
    $x =~ s/~~~quote~~~/\"/g;
    $x =~ s/~~~equals~~~/\=/g;
    return $x;
}

sub request_par {
  my $self = shift;
  my $par = shift;
  my $pars_ref = $self->{REQUEST_PARS};
  return $pars_ref->{$par};
}

sub hash {
  return Digest::SHA::sha1_base64(@_);
}

# Automatically adds one to month, so Jan=1, and, if year is less than
# 1900, adds 1900 to it. This should ensure that it works in both Perl 5
# and Perl 6.
sub current_date {
    my $what = shift; #=day, mon, year, ...
    my @tm = localtime;
    if ($what eq "sec") {return $tm[0]}
    if ($what eq "min") {return $tm[1]}
    if ($what eq "hour") {return $tm[2]}
    if ($what eq "day") {return $tm[3]}
    if ($what eq "year") {my $y = $tm[5]; if ($y<1900) {$y=$y+1900} return $y}
    if ($what eq "month") {return ($tm[4])+1}
}

sub current_date_string() {
    return current_date("year")."-".current_date("month")."-".current_date("day")." ".
           current_date("hour").":".current_date("min").":".current_date("sec")
           ;
}



# from Web Client Programming With Perl:

############
# open_TCP #
############
#
# Given ($file_handle, $dest, $port) return 1 if successful, undef when
# unsuccessful.
#
# Input: $fileHandle is the name of the filehandle to use
#        $dest is the name of the destination computer,
#              either IP address or hostname
#        $port is the port number
#
# Output: successful network connection in file handle
#

use Socket;

sub open_TCP
{
  # get parameters
  my ($FS, $dest, $port) = @_;

  #$dest = "lightandmatter.com";

  my $proto = getprotobyname('tcp');
  socket($FS, PF_INET, SOCK_STREAM, $proto);
  my $sin = sockaddr_in($port,inet_aton($dest));
  #print "sin=$sin, dest=$dest, port=$port\n";
  connect($FS,$sin) || return undef;

  my $old_fh = select($FS);
  $| = 1;                         # don't buffer output
  select($old_fh);
  1;
}

BEGIN {

  debugging_output("in begin block, cwd=".getcwd());

  my $spotter_version_detected = -1;
  my $i_am_client = 0;

  sub remember_i_am_client {
    $i_am_client = 1;
  }

  sub set_spotter_version {
    $spotter_version_detected = shift;
  }

  sub detect_spotter_version {
    return 3; ########### autodetection was unreliable, caused problems on multiple occasions
    return $spotter_version_detected if $spotter_version_detected>0;
    if ($i_am_client) {
      return -1; # can't tell without trial and error
    }
    else {
      # I'm running on the server side.
      return 3 if -d 'data'; # spotter 3.x
      return 2; # spotter 2.x
    }
  }

  sub debugging_output {
    my $x = shift;
    if (open(my $FILE, ">>/usr/lib/cgi-bin/spotter3/data/log/debug_netog.log")) {
      print $FILE "$x\n";
      close($FILE);
    }
  }

}

# Locate spotter's data directory, relative to where the cgi code lives.
# Depending on whether they're using spotter 2.x or 3.x, this could  be in two different plaes.
sub find_data_dir {
  if (detect_spotter_version()==3) { return 'data/';} else { return 'spotter/'; }
}

sub find_server_og_script {
  my $x = xyz_find_server_og_script();
  debugging_output($x);
  return $x;
}

# relative to cgi-bin (which is probably not the cwd of this script)
sub xyz_find_server_og_script {
  if (detect_spotter_version()==3) { return '/spotter3/ServerOG.cgi';} else { return '/ServerOG.cgi'; }
}


1;
