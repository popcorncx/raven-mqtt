#!/usr/bin/perl

use strict;
use warnings;
use autodie;

use Device::SerialPort;
use XML::Simple qw{ XMLin };
use Net::MQTT::Simple;
use JSON qw{ to_json };
use Date::Format qw{ time2str };

#

my $MQTT_HOST       = '10.0.0.21';
my $MQTT_TOPIC_ROOT = 'home/power';

my $PORT_NAME = '/dev/ttyUSB0';

my $TIMEOUT = 60;

#

my $port = Device::SerialPort->new($PORT_NAME)
	|| die "Can't open $PORT_NAME: $!\n";

$port->baudrate(115200);
$port->databits(8);
$port->parity("none");
$port->stopbits(1);

$port->read_char_time(0);     # don't wait for each character
$port->read_const_time(1000); # 1 second per unfulfilled "read" call

$port->write_settings or die 'write_settings';

#

my $mqtt = MQTT->new($MQTT_HOST);
$mqtt->last_will( "$MQTT_TOPIC_ROOT/status" => 'died' );
$mqtt->publish( "$MQTT_TOPIC_ROOT/status" => 'startup' );

#

my $buffer = q{};

# we are making the assumption that we will see InstantaneousDemand messages
# every 5-10 seconds, so if no messsages for a while something is wrong

local $SIG{'ALRM'} = sub {
	warn $buffer;
	$mqtt->publish( "$MQTT_TOPIC_ROOT/status" => 'timeout' );
	die("TimeOut $TIMEOUT");
};
alarm( $TIMEOUT );

#

my @MESSAGE_TYPES = qw{
	InstantaneousDemand
	CurrentSummationDelivered
	ConnectionStatus
	TimeCluster
	MeterInfo
	NetworkInfo
};

#

READ: while (1)
{
	my ($count, $saw) = $port->read(255);
	next READ if not $count;
	$buffer .= $saw;

	# TODO it would be good to have an XML parser (SAX?) that read directly from the serial port
	# stream and triggered when it saw the messages, this seems like a hack...

	foreach my $type ( @MESSAGE_TYPES )
	{
		my ($fragment) = $buffer =~ m{ ( <$type> .*? </$type> ) }smx;

		if ( $fragment )
		{
			alarm( $TIMEOUT );

			# remove fragment from buffer (and any leading whitespace to keep it clean)
			$buffer =~ s{ \s* \Q$fragment\E \s* }{}smx;

			my $parsed = eval {
				XMLin(
					$fragment,
					'KeepRoot' => 1,
					'SuppressEmpty' => q{},
				)
			};

			if ( $parsed )
			{
				my $payload = $parsed->{$type};

				# convert and cleanup to make it easer to handle the mqtt message

				if ( $payload->{'TimeStamp'} ) {
					$payload->{'TimeStamp'} = parse_time($payload->{'TimeStamp'}),
				}
				if ( $payload->{'UTCTime'} ) {
					$payload->{'_parsed'} = parse_time($payload->{'UTCTime'});
				}

				if ( $payload->{'SummationDelivered'} ) {
					$payload->{'SummationDelivered'} = get_reading( $payload, 'SummationDelivered' );
				}
				if ( $payload->{'SummationReceived'} ) {
					$payload->{'SummationReceived'} = get_reading( $payload, 'SummationReceived' );
				}
				if ( $payload->{'Demand'} ) {
					$payload->{'Demand'} = get_reading( $payload, 'Demand' ) * 1000; # reported as KW, we want W
				}
				delete $payload->{'Multiplier'};
				delete $payload->{'Divisor'};
				delete $payload->{'DigitsLeft'};
				delete $payload->{'DigitsRight'};
				delete $payload->{'SuppressLeadingZero'};

				if ( $payload->{'LinkStrength'} ) {
					$payload->{'LinkStrength'} = oct($payload->{'LinkStrength'});
				}

				$payload->{'_time'} = time();

				$mqtt->publish( "$MQTT_TOPIC_ROOT/$type" => to_json( $payload, { 'canonical' => 1 } ) );
			}
			else
			{
				$mqtt->publish( "$MQTT_TOPIC_ROOT/status" => 'invalid' );
			}
		}
	}

	# TODO this is only going to remove messages from the buffer that we know how to
	# handle, does it need to periodically clear the buffer?
}

die 'Should never exit READ loop';

########

sub average
{
	my @values = @_;

	return int( sum(@values) / scalar(@values) );
}

sub get_reading
{
	my ($data, $field) = @_;

	my $reading = oct( $data->{$field} );

	if ( my $multiplier = oct( $data->{'Multiplier'} ) )
	{
		$reading = $reading * $multiplier;
	}

	if ( my $divisor = oct( $data->{'Divisor'} ) )
	{
		$reading = $reading / $divisor;
	}

	return $reading;
}

sub parse_time
{
	my ($time) = @_;

	# 946684800 is 2000-01-01 2000 00:00:00 UTC

	return time2str('%Y-%m-%dT%H:%M:%S%z',  oct($time) + 946684800);
}

# subclass only to set the identifer
package MQTT;
use base 'Net::MQTT::Simple';
sub _client_identifier { 'raven' };

