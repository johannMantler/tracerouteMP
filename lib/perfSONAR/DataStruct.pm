package perfSONAR::DataStruct;
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
use strict;
use warnings;


#DEBUG
use Data::Dumper;
#DEBUG

use version;
our $VERSION = 0.52;

=head1 NAME

perfSONAR::DataStruct - Main class for all data types NMWG..etc used in OPPD.

=head1 DESCRIPTION

All servuces need this data struct to handle request and response. So the services dont depend on a
special datatype or protocol like NMWG. So it is possible to bind oppd on different protocolls. If you want 
to use NMWG, use the method nmwg2DS to convert the NMWG type in this main data struct.

The structure is defined as follow:
        
$self   ERROROCCUR If error occur set to 1. Default 0
        ERRORMSG    If error occur here is the error msg
        LS_REGISTER True if lookup service registration is on otherwise False
        WARN     Here are the warninhs stored
            |-OCCUR   If warninhs occur this is set to 1 default 0
            |- MSG     If warninhs occur all messages are here
        SERVICES   The availible services as Reference
        REQUESTMSG A reference to the requested message type with the handlers
        DOECHO     If echo is requested set to 1. Default 0
        DOSELFTEST If selftest is requested set to 1. Default 0
        RETURNMSG  
        SERVICE     The called service with his parameters and resul tdata.
          |-NAME    The name of the service
          |-DATA    All informations for the service
             |-$id 
                |-STORE       Store in a SQL MA
                    |-DOIT Undef for not storing otherwise 1
                    |-PARAMS The parameters for store message         The id defines a service call (measurement) with the parameters and result
                |- PARAMS   The parameters for a service. This is a hash with options and values
                |-MRESULT   The result of a measurement command as a array of data hashes.
                            All requests return a array. If a call was not succesfull,
                            ERROROCCUR set to 1 then this array is used as a error container
                            where @[0] contains the error occurnes for example ERROR BWCTL
                                  @[lastitem] error types
                                  and the lines betwenn this contains the error messages      
                 


To use the service part in a service define self or by the request data the id. In NMWG is this given by data id element in the request message.
The PARAMS field should be a hash with options and values. So a service can use it. The service puts the reuslt data as a array of hashes in the RESULTDATA
field. For details see the specific service.

=head1 Methods

=cut

#Here are everything to use
use Log::Log4perl qw(get_logger);
use Carp;


=head2 new({})

Creates a new object, accepts at the moment a perfSONAR::SOAP::Message. 

=cut

sub new {
    my ( $class, $uri, $msg, $services_ref ) = @_;
    my $self = {}; 
    $self->{LOGGER} = get_logger(__PACKAGE__);
    $self->{ERROROCCUR} = 0;   #If error occur set to 1
    $self->{STORE}->{DOIT} = undef;
    $self->{ERRMSG} = "";   #If error occur look here for error message at the moment only string message is supported
    $self->{LS_REGISTER} = undef;
    $self->{SERVICE} = undef;   #The request message
    $self->{SERVICES} = $services_ref;
    $self->{RETURNMSG} = undef;
    $self->{PARAMS} = {};     #The measurement parameters defined by a ID
    $self->{DOECHO} = 0;   #Do a status report for the selected service
    $self->{WARN}->{OCCUR} = 0;
    $self->{WARN}->{MSG} = "";
    
    #Check if uri is given
    if (!$uri){
        croak "No service specified!";
    }
    else{
    	$self->{URI} = $uri;
    }    
    
    $self->{"known_parameters"} = {
        src => 1,
        dst => 1,
        interval => 1,
        duration => 1,
        windowSize => 1,
        protocol => 1,
        bufferSize => 1,
        bandwidth => 1,
        login => 1,
        password => 1,
        TOS => 1,
        
        #more owamp
        count => 1,
        timeout => 1,
        size  => 1,
        units  => 1,
        send_schedule  => 1,
	wait  => 1,
        percentile  => 1,
        one_way  => 1,
        DSCP  => 1,
        PHB  => 1,
        enddelay  => 1,
        startdelay  => 1,
        bucket_width  => 1,
        intermediates  => 1,
        output  => 1,
        port  => 1,
        portrange  => 1,
	ppsts  => 1,
        individual => 1, #TODO check this parameter
        
        #store parameters
        uri => 1,
        dataref => 1,,
        
        #Hades MA
        startTime => 1,
        endTime=> 1,
        packetsize => 1,
        precedence => 1,
        groupsize => 1,
        interval => 1,
        mid => 1,
    };

    $self->{"unsupported_parameters"} = {
        advisoryWindowsize => 1,
        scheduleInterval => 1,
        numberOfTests => 1,
        latest => 1,
        alpha => 1,
        
        #owamp specific
        save_summary => 1,
        directory => 1,
        no_summary => 1,
    };
    
    
    bless $self, $class;
    
    #Look if message is nmwg message
    if ( $msg && ref( $msg ) eq 'NMWG::Message') {
        $self->{LOGGER}->debug("Get a NMWG message request");
        use perfSONAR::DataStruct::NMWG;
        my $nmwgds = perfSONAR::DataStruct::NMWG->new();
        $nmwgds->nmwg2ds($msg,$self);
        $self->{$self->{DSTYPE}} = $nmwgds;
    }    
    
    return $self;
}



1;
