#!/usr/bin/perl -wT
#
# ==========================================================================
#
# ZoneMinder External Trigger Script, $Date: 2008-07-25 10:48:16 +0100 (Fri, 25 Jul 2008) $, $Revision: 2612 $
# Copyright (C) 2001-2008 Philip Coombes
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
# ==========================================================================

=head1 NAME

zmtrigger.pl - ZoneMinder External Trigger Script

=head1 DESCRIPTION

This script is used to trigger and cancel alarms from external connections
using an arbitrary text based format.

This script offers generic solution to external triggering of alarms. It
can handle external connections via either internet socket, unix socket or
file/device interfaces. You can either use it 'as is' if you can interface
with the existing format, or override connections and channels to customise
it to your needs.

If enabled by the OPT_TRIGGERS option, Zoneminder service start
zmtrigger.pl which listens for control messages on TCP port 6802.

=head1 TRIGGER MESSAGE FORMAT

B<id>|B<action>|B<score>|B<cause>|B<text>|B<showtext>

=over 4

=item B<id>

  is the id number or name of the ZM monitor.

=item B<action>

  Valid actions are 'on', 'off', 'cancel' or 'show' where
  'on' forces an alarm condition on;
  'off' forces an alarm condition off;
  'cancel' negates the previous 'on' or 'off';
  'show' updates the auxiliary text represented by the %Q 
  placeholder, which can optionally be added to the affected monitor's
  timestamp label format.
  
  Ordinarily you would use 'on' and 'cancel', 'off' would tend to be
  used to suppress motion based events. Additionally 'on' and 'off' can
  take an additional time offset, e.g. on+20 which automatically
  cancel's the previous action after that number of seconds.

=item B<score>

  is the score given to the alarm, usually to indicate it's
  importance. For 'on' triggers it should be non-zero, otherwise it should
  be zero.

=item B<cause>

  is a 32 char max string indicating the reason for, or source of
  the alarm e.g. 'Relay 1 open'. This is saved in the 'Cause' field of the
  event. Ignored for 'off' or 'cancel' messages.

=item B<text>

  is a 256 char max additional info field, which is saved in the
  'Description' field of an event. Ignored for 'off' or 'cancel' messages.

=item B<showtext>

  is up to 32 characters of text that can be displayed in the
  timestamp that is added to images. The 'show' action is designed to
  update this text without affecting alarms but the text is updated, if
  present, for any of the actions. This is designed to allow external input
  to appear on the images captured, for instance temperature or personnel
  identity etc.

=back

Note that multiple messages can be sent at once and should be LF or CRLF
delimited. This script is not necessarily intended to be a solution in
itself, but is intended to be used as 'glue' to help ZoneMinder interface
with other systems. It will almost certainly require some customisation
before you can make any use of it. If all you want to do is generate alarms
from external sources then using the ZoneMinder::SharedMem perl module is
likely to be easier.

=head1 EXAMPLES

  3|on+10|1|motion|text|showtext

Triggers "alarm" on camera #3 for 10 seconds with score=1, cause="motion".

=cut
use strict;
use bytes;

# ==========================================================================
#
# User config
#
# ==========================================================================

use constant MAX_CONNECT_DELAY => 10;
use constant MONITOR_RELOAD_INTERVAL => 300;
use constant SELECT_TIMEOUT => 0.25;

# ==========================================================================
#
# Channel/Connection Modules
#
# ==========================================================================

# Include from system perl paths only
use ZoneMinder;
use ZoneMinder::Trigger::Channel::Inet;
use ZoneMinder::Trigger::Channel::Unix;
use ZoneMinder::Trigger::Channel::Serial;
use ZoneMinder::Trigger::Connection;

my @connections;
push( @connections,
      ZoneMinder::Trigger::Connection->new(
        name=>"Chan1 TCP on port 6802",
        channel=>ZoneMinder::Trigger::Channel::Inet->new( port=>6802 ),
        mode=>"rw"
      )
);
push( @connections,
      ZoneMinder::Trigger::Connection->new(
        name=>"Chan2 Unix Socket at " . $Config{ZM_PATH_SOCKS}.'/zmtrigger.sock',
        channel=>ZoneMinder::Trigger::Channel::Unix->new(
                    path=>$Config{ZM_PATH_SOCKS}.'/zmtrigger.sock'
                 ),
        mode=>"rw"
      )
);
#push( @connections, ZoneMinder::Trigger::Connection->new( name=>"Chan3", channel=>ZoneMinder::Trigger::Channel::File->new( path=>'/tmp/zmtrigger.out' ), mode=>"w" ) );
#push( @connections, ZoneMinder::Trigger::Connection->new( name=>"Chan4", channel=>ZoneMinder::Trigger::Channel::Serial->new( path=>'/dev/ttyS0' ), mode=>"rw" ) );

# ==========================================================================
#
# Don't change anything from here on down
#
# ==========================================================================

use DBI;
#use Socket;
use autouse 'Data::Dumper'=>qw(Dumper);
use POSIX qw( EINTR );
use Time::HiRes qw( usleep );

$| = 1;

$ENV{PATH}  = '/bin:/usr/bin:/usr/local/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

logInit();
logSetSignal();

Info( "Trigger daemon starting\n" );

my $dbh = zmDbConnect();

my $base_rin = '';
foreach my $connection ( @connections )
{
    Info( "Opening connection '$connection->{name}'\n" );
    $connection->open();
}

my @in_select_connections = grep { $_->input() && $_->selectable() } @connections;
my @in_poll_connections = grep { $_->input() && !$_->selectable() } @connections;
my @out_connections = grep { $_->output() } @connections;

foreach my $connection ( @in_select_connections )
{
    vec( $base_rin, $connection->fileno(), 1 ) = 1;
}

my %spawned_connections;
my %monitors;
my $monitor_reload_time = 0;
my $needsReload = 0;
loadMonitors();


$! = undef;
my $rin = '';
my $win = $rin;
my $ein = $win;
my $timeout = SELECT_TIMEOUT;
my %actions;
while( 1 )
{
    $rin = $base_rin;
    # Add the file descriptors of any spawned connections
    foreach my $fileno ( keys(%spawned_connections) )
    {
        vec( $rin, $fileno, 1 ) = 1;
    }

    my $nfound = select( my $rout = $rin, undef, my $eout = $ein, $timeout );
    if ( $nfound > 0 )
    {
        Debug( "Got input from $nfound connections\n" );
        foreach my $connection ( @in_select_connections )
        {
            if ( vec( $rout, $connection->fileno(), 1 ) )
            {
                Debug( "Got input from connection "
                       .$connection->name()
                       ." ("
                       .$connection->fileno()
                       .")\n"
                );
                if ( $connection->spawns() )
                {
                    my $new_connection = $connection->accept();
                    $spawned_connections{$new_connection->fileno()} = $new_connection;
                    Debug( "Added new spawned connection ("
                           .$new_connection->fileno()
                           ."), "
                           .int(keys(%spawned_connections))
                           ." spawned connections\n"
                    );
                }
                else
                {
                    my $messages = $connection->getMessages();
                    if ( defined($messages) )
                    {
                        foreach my $message ( @$messages )
                        {
                            handleMessage( $connection, $message );
                        }
                    }
                }
            }
        }
        foreach my $connection ( values(%spawned_connections) )
        {
            if ( vec( $rout, $connection->fileno(), 1 ) )
            {
                Debug( "Got input from spawned connection "
                       .$connection->name()
                       ." ("
                       .$connection->fileno()
                       .")\n"
                );
                my $messages = $connection->getMessages();
                if ( defined($messages) )
                {
                    foreach my $message ( @$messages )
                    {
                        handleMessage( $connection, $message );
                    }
                }
                else
                {
                    delete( $spawned_connections{$connection->fileno()} );
                    Debug( "Removed spawned connection ("
                           .$connection->fileno()
                           ."), "
                           .int(keys(%spawned_connections))
                           ." spawned connections\n"
                    );
                    $connection->close();
                }
            }
        }
    }
    elsif ( $nfound < 0 )
    {
        if ( $! == EINTR )
        {
            # Do nothing
        }
        else
        {
            Fatal( "Can't select: $!" );
        }
    }

    # Check polled connections
    foreach my $connection ( @in_poll_connections )
    {
        my $messages = $connection->getMessages();
        if ( defined($messages) )
        {
            foreach my $message ( @$messages )
            {
                handleMessage( $connection, $message );
            }
        }
    }

    # Check for alarms that might have happened
    my @out_messages;
    foreach my $monitor ( values(%monitors) )
    {

        if ( ! zmMemVerify($monitor) ) {
          # Our attempt to verify the memory handle failed. We should reload the monitors.
          # Don't need to zmMemInvalidate because the monitor reload will do it.
          $needsReload = 1;
          next;
        }

        my ( $state, $last_event )
            = zmMemRead( $monitor,
                         [ "shared_data:state",
                           "shared_data:last_event"
                         ]
        );

        #print( "$monitor->{Id}: S:$state, LE:$last_event\n" );
        #print( "$monitor->{Id}: mS:$monitor->{LastState}, mLE:$monitor->{LastEvent}\n" );
        if ( $state == STATE_ALARM
             || $state == STATE_ALERT
        ) # In alarm state
        {
            if ( !defined($monitor->{LastEvent})
                 || ($last_event != $monitor->{LastEvent})
            ) # A new event
            {
		system("sh /home/fede/allarme/azioni_allarme --help");
                push( @out_messages, $monitor->{Id}."|on|".time()."|".$last_event );
            }
            else # The same one as last time, so ignore it
            {
                # Do nothing
            }
        }
        elsif ( ($state == STATE_IDLE
                 && $monitor->{LastState} != STATE_IDLE
                )
                || ($state == STATE_TAPE
                    && $monitor->{LastState} != STATE_TAPE
                   )
        ) # Out of alarm state
        {
		if( $state == STATE_IDLE && $monitor->{LastState} != STATE_IDLE )
	   	{
			system("python /home/fede/allarme/bot_send_registration.py");
		}
            push( @out_messages, $monitor->{Id}."|off|".time()."|".$last_event );
        }
        elsif ( defined($monitor->{LastEvent})
                && ($last_event != $monitor->{LastEvent})
        ) # We've missed a whole event
        {
            push( @out_messages, $monitor->{Id}."|on|".time()."|".$last_event );
            push( @out_messages, $monitor->{Id}."|off|".time()."|".$last_event );
        }
	$monitor->{LastState} = $state;
        $monitor->{LastEvent} = $last_event;
    }
    foreach my $connection ( @out_connections )
    {
        if ( $connection->canWrite() )
        {
            $connection->putMessages( \@out_messages );
        }
    }
    foreach my $connection ( values(%spawned_connections) )
    {
        if ( $connection->canWrite() )
        {
            $connection->putMessages( \@out_messages );
        }
    }

    Debug( "Checking for timed actions\n" )
        if ( int(keys(%actions)) );
    my $now = time();
    foreach my $action_time ( sort( grep { $_ < $now } keys( %actions ) ) )
    {
        Info( "Found actions expiring at $action_time\n" );
        foreach my $action ( @{$actions{$action_time}} )
        {
            my $connection = $action->{connection};
            my $message = $action->{message};
            Info( "Found action '$message'\n" );
            handleMessage( $connection, $message );
        }
        delete( $actions{$action_time} );
    }

    # Allow connections to do their own timed actions
    foreach my $connection ( @connections )
    {
        my $messages = $connection->timedActions();
        if ( defined($messages) )
        {
            foreach my $message ( @$messages )
            {
                handleMessage( $connection, $message );
            }
        }
    }
    foreach my $connection ( values(%spawned_connections) )
    {
        my $messages = $connection->timedActions();
        if ( defined($messages) )
        {
            foreach my $message ( @$messages )
            {
                handleMessage( $connection, $message );
            }
        }
    }

    # If necessary reload monitors
    if ( $needsReload || ((time() - $monitor_reload_time) > MONITOR_RELOAD_INTERVAL ))
    {
        foreach my $monitor ( values(%monitors) )
        {
            # Free up any used memory handle
            zmMemInvalidate( $monitor );
        }
        loadMonitors();
        $needsReload = 0;
    }
}
Info( "Trigger daemon exiting\n" );
exit;

sub loadMonitors
{
    Debug( "Loading monitors\n" );
    $monitor_reload_time = time();

    my %new_monitors = ();

    my $sql = "SELECT * FROM Monitors
               WHERE find_in_set( Function, 'Modect,Mocord,Nodect' )".
			   ( $Config{ZM_SERVER_ID} ? 'AND ServerId=?' : '' )
    ;
    my $sth = $dbh->prepare_cached( $sql )
        or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
    my $res = $sth->execute( $Config{ZM_SERVER_ID} ? $Config{ZM_SERVER_ID} : () )
        or Fatal( "Can't execute: ".$sth->errstr() );
    while( my $monitor = $sth->fetchrow_hashref() )
    {
          # Check shared memory ok
          if ( !zmMemVerify( $monitor ) ) {
            zmMemInvalidate( $monitor );
            next;
          }

        if ( defined($monitors{$monitor->{Id}}->{LastState}) )
        {
            $monitor->{LastState} = $monitors{$monitor->{Id}}->{LastState};
        }
        else
        {
            $monitor->{LastState} = zmGetMonitorState( $monitor );
        }
        if ( defined($monitors{$monitor->{Id}}->{LastEvent}) )
        {
            $monitor->{LastEvent} = $monitors{$monitor->{Id}}->{LastEvent};
        }
        else
        {
            $monitor->{LastEvent} = zmGetLastEvent( $monitor );
        }
        $new_monitors{$monitor->{Id}} = $monitor;
    }
    %monitors = %new_monitors;
}

sub handleMessage
{
    my $connection = shift;
    my $message = shift;

    my ( $id, $action, $score, $cause, $text, $showtext )
       = split( /\|/, $message );
    $score = 0 if ( !defined($score) );
    $cause = "" if ( !defined($cause) );
    $text = "" if ( !defined($text) );

    my $monitor = $monitors{$id};
    if ( !$monitor )
    {
        Warning( "Can't find monitor '$id' for message '$message'\n" );
        return;
    }
    Debug( "Found monitor for id '$id'\n" );

    next if ( !zmMemVerify( $monitor ) );

    Debug( "Handling action '$action'\n" );
    if ( $action =~ /^(enable|disable)(?:\+(\d+))?$/ )
    {
        my $state = $1;
        my $delay = $2;
        if ( $state eq "enable" )
        {
            zmMonitorEnable( $monitor );
        }
        else
        {
            zmMonitorDisable( $monitor );
        }
        # Force a reload
        $monitor_reload_time = 0;
        Info( "Set monitor to $state\n" );
        if ( $delay )
        {
            my $action_text = $id."|".( ($state eq "enable")
                                        ? "disable"
                                        : "enable"
                                      );
             handleDelay($delay, $connection, $action_text);
        }
    }
    elsif ( $action =~ /^(on|off)(?:[ \+](\d+))?$/ )
    {
        next if ( !$monitor->{Enabled} );

        my $trigger = $1;
        my $delay = $2;
        my $trigger_data;
        if ( $trigger eq "on" )
        {
            zmTriggerEventOn( $monitor, $score, $cause, $text );
            zmTriggerShowtext( $monitor, $showtext ) if defined($showtext);
            Info( "Trigger '$trigger' '$cause'\n" );
            if ( $delay )
            {
                 my $action_text = $id."|cancel";
                 handleDelay($delay, $connection, $action_text);
            }
        }
        elsif ( $trigger eq "off" )
        {
            if ( $delay ) 
            {
                 my $action_text = $id."|off|0|".$cause."|".$text;
                 handleDelay($delay, $connection, $action_text);
            } else {
                my $last_event = zmGetLastEvent( $monitor );
                zmTriggerEventOff( $monitor );
                zmTriggerShowtext( $monitor, $showtext ) if defined($showtext);
                Info( "Trigger '$trigger'\n" );
                # Wait til it's finished
                while( zmInAlarm( $monitor )
                       && ($last_event == zmGetLastEvent( $monitor ))
                )
                {
                    # Tenth of a second
                    usleep( 100000 );
                }
            zmTriggerEventCancel( $monitor );
            }
        }
    }
    elsif( $action eq "cancel" )
    {
        zmTriggerEventCancel( $monitor );
        zmTriggerShowtext( $monitor, $showtext ) if defined($showtext);
        Info( "Cancelled event\n" );
    }
    elsif( $action eq "show" )
    {
        zmTriggerShowtext( $monitor, $showtext );
        Info( "Updated show text to '$showtext'\n" );
    }
    else
    {
        Error( "Unrecognised action '$action' in message '$message'\n" );
    }
} # end sub handleMessage

sub handleDelay
{
    my $delay = shift;
    my $connection = shift;
    my $action_text = shift;
    
    my $action_time = time()+$delay;
    my $action_array = $actions{$action_time};
    if ( !$action_array )
    {
        $action_array = $actions{$action_time} = [];
    }
    push( @$action_array, { connection=>$connection,
                            message=>$action_text
                          }
    );
    Debug( "Added timed event '$action_text', expires at $action_time (+$delay secs)\n" );
}
1;
__END__
