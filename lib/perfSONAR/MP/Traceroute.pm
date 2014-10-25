package perfSONAR::MP::Traceroute;
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
=head1 NAME

perfSONAR::MP::Traceroute

=head1 DESCRIPTION

This class runs measurementds for Traceroute. It use as base class the MP class. All Traceroute specific 
definitions done here. This class has no concstructor defined. Ituse the new method from MP class

=cut


use strict;
use warnings;


#DEBUG
use Data::Dumper;
#DEBUG

use version;
our $VERSION = 0.53;

use Log::Log4perl qw(get_logger);
use base qw(perfSONAR::MP);
use POSIX;


=head2 run()

The run method starts a Traceroute measurement and use the runMeasurement()
method from perfSONAR::MP. To start the measurement a data struct as 
input is needed. For example to start a Traceroute measurement:

1. $owamp = perfSONAR::MP::Traceroute->new();
2.$ds = perfSONAR::DataStruct->new($uri, $message);
3. $owamp->run();

=cut
sub run{
    my ($self, $ds) = @_;
    $self->{LOGGER} = get_logger(__PACKAGE__);
    $self->{DS} = $ds;
    $self->runMeasurement();
}


=head2 createCommandLine({})

To start a measurement with owamp a commandline expression is needed. 
This expression will be created here. As input a hash parameter of owamp options is needed.
On success it will return a array with owamp options and parameters. On errpr it 
will return an array with ("ERROR,error message as string).

=cut
sub createCommandLine {
    my ($self,%parameters) = @_;
    my @commandline;
    my $errormsg;
    my $ds = $self->{DS};
    
	#Look for the output type
    if ($parameters{"output"} && $parameters{"output"} eq "summary"){
    	$self->{OUTPUTTYPE} =  "summary";
    }
    elsif ($parameters{"output"} && ($parameters{"output"} eq "machine_readable")){
    	$self->{OUTPUTTYPE} =  "machine_readable";
    }
    elsif ($parameters{"output"} && ($parameters{"output"} eq "raw")){
    	$self->{OUTPUTTYPE} =  "raw"; 
    }
    elsif ($parameters{"output"} ){
    	#unknown output type
    	$errormsg = "You choose a unknown output type: $parameters{output}.";
        $self->{LOGGER}->error($errormsg);
        return "ERROR", $errormsg, "error.mp.traceroute";    	
    }
    else{
    	#No output type defined
    	push @commandline, "-R";
        $self->{OUTPUTTYPE} =  "raw";
    }
    
    #Append destination
    if ($parameters{"dst"} ) {
		push @commandline, $parameters{"dst"};
    }
    else{
    	$errormsg = "No destination address specified.";
        $self->{LOGGER}->error($errormsg);
        return "ERROR", $errormsg, "error.mp.traceroute";
    }

    push @commandline , "-p", $parameters{port} if($parameters{"port"});
    
    return @commandline;
    
}


=head2 parse_result({})

After a measurement call the result message of the tool should be parsed.
This method will be called from the MP class. The measurement result 
in $$ds->{PARAMS}->{$id}->{MEASRESULT}will be used. On success it returns 
a array. The elements of the array are hashes. On error the $$ds->{ERROROCCUR}
will be set to 1. For this $$ds->{RETURNMSG} will be set to the error string.

=cut
sub parse_result {
  
    my ($self, $ds, $id) = @_;
    my $result = $$ds->{SERVICE}->{DATA}->{$id}->{MEASRESULT};
    my @result = split(/\n/, $result);
    my $time = time;
    my @datalines = (); 
    my $logger = get_logger(__PACKAGE__);

    #
    # for now only raw is possible
    #
    if ($self->{OUTPUTTYPE} eq  "raw") {
    	
    	#
    	# parse every line that is returned from
    	# the traceroute tool
    	#
    	foreach my $resultline (@result) {
    		$resultline = trim($resultline);
    		my %data_hash;
    		
    		#
    		# find the hop number at
    		# the beginning of the line
    		#
   			if ($resultline =~ /^(\d+)\s+/) {
				
				# trim the line
				$data_hash{"hop"} = trim($1);

				#
				# Is a valid response with hostname and hostip, no asterix
				#
   			    if ($resultline =~ /^\d+\s+([^\s^\*]+)\s+([^\s^\*]+)/ ) {
   			    	
   			    	#
   			    	# put the result into the Hash Datastruct.
   			    	#
   			    	my $host = trim($1);
   			    	my $ip = trim($2);
   			    	my @times = ( $resultline =~ /\d+\.\d+ ms/g );
   			    	my $responseTimes = "";
   			    	
   			    	$ip =~ s/(\(|\))//g;
   			    	
   			    	$data_hash{'hostname'} = $host;
   			    	$data_hash{'hostip'} = $ip;
   			    	foreach my $time (@times) {
	   			    	$time =~ /(\d+\.\d+) ms/;
	   			    	$responseTimes = join(' ', $responseTimes, $1);
	   			    }#End foreach
	   			    $data_hash{'responseTimes'} = trim($responseTimes);
   			    } else { # response does not match so is unknown
   			    	$data_hash{'unknown'} = "true";
   			    }
   			    push @datalines, \%data_hash;
   			}#End if
    	}#End foreach 
    }#End if

    return @datalines;
}

=head2 selftest()
Define here the steps for the selftest
=cut
sub selftest {
	my ($self, $ds, $id) = @_;
	$self->{LOGGER} = get_logger(__PACKAGE__);
	my $params = $$ds->{SERVICE}->{DATA};
	my @datalines;
	
	foreach my $id (keys %{$params}){
		my %data_hash;
		$data_hash{'traceroute_command_test'} = [$self->checkTool("traceroute")];
		push @datalines, \%data_hash;
		$$ds->{SERVICE}->{DATA}->{$id}->{MRESULT} = \@datalines
	}#End foreach
	return;
}

=head2 trim()
tiny helper to trim a string
=cut
sub trim {
	my $string = shift;
	$string =~ s/^\s+//;
    $string =~ s/\s+$//;
    
    return $string;
}

1;
