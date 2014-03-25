package Gutta::Plugin;
use Gutta::DBI;
use Storable;
use strict;
use warnings;
use DateTime;

sub new 
{
    my $class = shift;
    my $dt =  DateTime->new( year=>(2000+int(rand(10))));
    my $self = bless {
                data => {},
            datafile => undef,
     heartbeat_act_s => 58,   # default act on heartbeats ~ every 58 secs.
    heartbeat_act_ts => time, # Setting timestamp "time is now"
                  db => Gutta::DBI->instance(),
    }, $class;

    $self->_initialise();
    warn "creating new class\n";
    return $self;
}

sub process_msg
{
    #  process incoming messages
    my $self = shift;
    return ();
}

sub process_privmsg
{
    #  process incoming messages
    my $self = shift;
    return ();
}

sub _initialise
{
    # called when plugin is istansiated
    my $self = shift;
    $self->{triggers} = $self->_triggers();
    $self->{commands} = $self->_commands();

    $self->{datafile} = "Gutta/Data/" . __PACKAGE__ . ".data",
}

sub _get_triggers
{
    my $self = shift;
    # override this in plugin to set custom triggers
    #
    # The dispatch table for "triggers" which will be triggered
    # when one of them matches the IRC message.
    $self->{triggers} ||= $self->_set_triggers();

    return $self->{triggers};
}

sub _get_commands
{
    my $self = shift;
    # override this in plugin to set custom commands
    #
    # The dispatch table for "commands", which is the first word sent to Gutta
    # it may be prefixed with $CMDPREFIX in parent, depending on context:
    #  (private vs public msg)
    #
    return $self->{commands};
}

sub _triggers
{
    my $self = shift;
    # override this in plugin to set custom triggers
    #
    # The dispatch table for "triggers" which will be triggered
    # when one of them matches the IRC message.

    return ;
}

sub _commands
{
    my $self = shift;
    # override this in plugin to set custom commands
    #
    # The dispatch table for "commands", which is the first word sent to Gutta
    # it may be prefixed with $CMDPREFIX in parent, depending on context:
    #  (private vs public msg)
    #
    return ;
}

sub load
{
    # load $self->{data} from file
    my $self = shift;
    $self->save() unless -f $self->{datafile};
    $self->{data} = retrieve($self->{datafile});

}

sub save
{ 
    # save $self->{data} to file
    my $self = shift;
    store \%{$self->{data}}, $self->{datafile};
}

sub heartbeat
{
    # the plugins can handle heartbeats to act upon things outside of the irssi
    my $self = shift;
    my $nowt = time;

    if (($nowt - $self->{heartbeat_act_ts}) >= $self->{heartbeat_act_s})
    {
        warn sprintf "heartbeat called for heartbeat act because delta between %s minus %s was %i", $nowt, $self->{heartbeat_act_ts}, ($nowt - $self->{heartbeat_act_ts});
        $self->{heartbeat_act_ts} = $nowt;
        $self->_heartbeat_act;
    }
}

sub _heartbeat_act
{
    # here is acting to the heartbeats. the plugins wanna override 
    # this function, but the mechanics for *when* to act 
    # pretty much should be the same
    #
    # This is a "void" function. --  Data collected here
    # gets returned by called from heartbeat_res for every connected
    # to server
}


sub heartbeat_res
{
    # Here process irc commands from the plugin from each connected to server
    # The heartbeat sets the date, the result returns it
    my $self = shift;
    my $servername = shift;

    return undef;
}

sub dbh
{
    # Here we supply the database handle for gutta
    #
    my $self = shift;
    return $self->{db}->dbh();
}



sub _dbinit
{
    # DBinit provides support for plugins to initialise their db:s, 
    # it runs the sql from the _setup_shema method
    # the $self->setup_shema() class.
    # this can be called multiple times by passing different tables to setup_schema
    my $self = shift;
    my $dbh = $self->dbh();

    my $query = $self->_setup_shema() || return;

    my $sth = $dbh->prepare($query) or die "unable to run: $query\n";
    $sth->execute() or  die "unable to execute; $query\n";

}

sub _setup_shema
{
    my $self = shift;
    my $target_shema = shift;
    #
    # Child Plugins override this method to return the SQL needed to initialise the $target_shema
    # table.
    # It can be arbitrary SQL in here, so use with caution-
    #
    return undef;
}


sub command
{
    my $self = shift;
    my $command = shift;
    # Left in @_ = $server, $msg, $nick, $mask, $target
    # it will be passed on to the command
    # DO IT (something like this) = shift;
    #
    $self->{commands} ||= $self->_commands();
    return unless $self->{commands};

    return $self->{commands}{$command}->(@_);
}

sub trigger
{
    my $self = shift;
    my $trigger = shift;
    # Left in @_ = $server, $msg, $nick, $mask, $target, $match =  the match in $msg
    # it will be passwed on to the trigger.
    # DO IT (something like this) = shift;
    #
    $self->{triggers} ||= $self->_triggers();
    return unless $self->{triggers};

    
    return $self->{triggers}{$trigger}->(@_);
}

1;
