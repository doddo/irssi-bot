package Gutta::Plugins::Nagios;
# does something with Nagios

use parent Gutta::Plugin;

use HTML::Strip;
use LWP::UserAgent;
use XML::FeedPP;
use MIME::Base64;
use JSON;
use strict;
use warnings;
use Data::Dumper;
use DateTime::Format::Strptime;
use Getopt::Long qw(GetOptionsFromArray);
use Switch;


=head1 NAME

Gutta::Plugins::Nagios


=head1 SYNOPSIS

Provides Nagios connection to gutta bot


=head1 DESCRIPTION

Add support to have gutta check the nagios rest api for hostgroup status and send any alarms encounterd into the target channel or channels.

say this:

 '!monitor config --username monitor --password monitor --nagios-server 192.168.60.182'

to configure a connection to monitor at 192.168.60.182 using username monitor and password monitor.

Then start using it:

!monitor hostgroup unix-servers --irc-server .* --to-channel #test123123

To add op5 irc monitoring for all servers in the unix-servers hostgroups on all servers, and send messages Crit, Warns and Clears to channel #test123123

Similarly

!unmoniutor hostgroup unix-servers

will remove monitoring for said server

Also you can do this:

!monitor host <hostid> --irc-server .* --to-channel #test123123

to add a single host.

=cut

my $log;

sub _initialise
{
    # called when plugin is istansiated
    my $self = shift;
    # The logger
    $log = Log::Log4perl->get_logger(__PACKAGE__);

    # initialise the database if need be.
    $self->_dbinit();

    # this one should start in its own thread.
    $self->{want_own_thread} = 1;
}

sub _commands
{
    my $self = shift;
    # the commands registered by this pluguin.
    #
    return {
        "monitor" => sub { $self->monitor(@_) },
      "unmonitor" => sub { $self->unmonitor(@_) },
    }
}

sub _setup_shema
{
    my $self = shift;

    my @queries  = (qq{
    CREATE TABLE IF NOT EXISTS monitor_hostgroups (
         irc_server TEXT NOT NULL,
            channel TEXT NOT NULL,
          hostgroup TEXT NOT NULL,
         last_check INTEGER DEFAULT 0,
      CONSTRAINT uniq_hgconf UNIQUE (irc_server, channel, hostgroup)
    )}, qq{
    CREATE TABLE IF NOT EXISTS monitor_hosts (
         irc_server TEXT NOT NULL,
            channel TEXT NOT NULL,
               host TEXT NOT NULL,
         last_check INTEGER DEFAULT 0,
      CONSTRAINT uniq_hconf UNIQUE (irc_server, channel, host)
    )}, qq{
    CREATE TABLE IF NOT EXISTS monitor_hoststatus (
          host_name TEXT PRIMARY KEY,
              state INTEGER NOT NULL,
      plugin_output TEXT,
          timestamp INTEGER DEFAULT 0
    )}, qq{
    CREATE TABLE IF NOT EXISTS monitor_servicedetail (
          host_name TEXT NOT NULL,
            service TEXT NOT NULL,
              state INTEGER DEFAULT 0,
      plugin_output TEXT,
   has_been_checked INTEGER DEFAULT 0,
          timestamp INTEGER DEFAULT 0,
    FOREIGN KEY (host_name) REFERENCES monitor_hoststatus(host_name),
      CONSTRAINT uniq_service UNIQUE (host_name, service)
    )}, qq{
    CREATE TABLE IF NOT EXISTS monitor_hosts_from_hostgroup (
          host_name TEXT NOT NULL,
          hostgroup TEXT NOT NULL,
    FOREIGN KEY (host_name) REFERENCES monitor_hoststatus(host_name),
    FOREIGN KEY (hostgroup) REFERENCES monitor_hostgroups(hostgroup),
      CONSTRAINT uniq_hgconf UNIQUE (host_name, hostgroup)
    )}, qq{
    CREATE TABLE IF NOT EXISTS monitor_message_hosts (
          host_name TEXT PRIMARY KEY,
          old_state INTEGER,
    FOREIGN KEY (host_name) REFERENCES monitor_hoststatus(host_name)
    )}, qq{
    CREATE TABLE IF NOT EXISTS monitor_message_servicedetail (
          host_name TEXT NOT NULL,
            service TEXT NOT NULL,
          old_state INTEGER,
    FOREIGN KEY (host_name) REFERENCES monitor_hoststatus(host_name),
    FOREIGN KEY (service) REFERENCES monitor_servicedetail(service),
      CONSTRAINT uniq_service_per_host UNIQUE (host_name, service)
    )});

    return @queries;

}


sub monitor
{
    my $self = shift;
    my $server = shift;
    my $msg = shift;
    my $nick = shift;
    my $mask = shift;
    my $target = shift;
    my $rest_of_msg = shift;

    # they need something to monitor.
    return unless $rest_of_msg;

    my @irc_cmds;

    # get the commands.
    my ($subcmd, @values) = split(/\s+/, $rest_of_msg);

    switch (lc($subcmd))
    {
        case 'hostgroup' { @irc_cmds = $self->_monitor_hostgroup(@values) }
        case      'host' { @irc_cmds = $self->_monitor_host(@values) }
        case    'config' { @irc_cmds = $self->_monitor_config(@values) }
        case      'dump' { @irc_cmds = $self->_monitor_login(@values) }
        case   'runonce' { @irc_cmds = ($self->_monitor_runonce(@values), $self->heartbeat_res("exampleserver")) }
    }

    return map { sprintf 'msg %s %s: %s', $target, $nick, $_ } @irc_cmds;
}

sub _monitor_hostgroup
{
    my $self = shift;
    my $hostgroup = shift;
    my @args = @_;

    my $server;
    my $channel;

    my $ret = GetOptionsFromArray(\@args,
        'irc-server=s' => \$server,
        'to-channel=s' => \$channel,
    ) or return "invalid options supplied.";

    $log->debug("setting up hostgroup config for $channel on server(s) mathcing $server\n");

    # get a db handle.
    my $dbh = $self->dbh();

    # Insert the stuff ino the database
    my $sth = $dbh->prepare(qq{INSERT OR REPLACE INTO monitor_hostgroups
        (hostgroup, irc_server, channel) VALUES(?,?,?)}) or return $dbh->errstr;

    # And DO it.
    $sth->execute($hostgroup, $server, $channel) or return $dbh->errstr;

    # the PRIVMSG to return.
    return "OK - added monitoring for hostgroup:[$hostgroup] on  channel:[$channel] for servers matching re:[$server]";
}

sub _monitor_config
{
    # Configure monitor, for example what nagios server is it?
    # who is the user and what is the password etc etc
    my $self = shift;
    my @args = @_;
    my %config;

    my $ret = GetOptionsFromArray(\@args, \%config,
           'username=s',
           'password=s',
     'check-interval=s',
      'nagios-server=s',
    ) or return "invalid options supplied:";

    while(my ($key, $value) = each %config)
    {
        $log->info("setting $key to $value for " . __PACKAGE__ . ".");
        $self->set_config($key, $value);
    }

    return 'got it.'
}

sub unmonitor
{
    my $self = shift;
    my $server = shift;
    my $msg = shift;
    my $nick = shift;
    my $mask = shift;
    my $target = shift;
    my $rest_of_msg = shift;

    # they need someonw to slap
    return unless $rest_of_msg;

    #TODO FIX THIS BORING.

    return;
}


sub _monitor_runonce
{
    my $self = shift;

    my $dbh = $self->dbh();

    # check what hostgroups are configured for monitoring.
    my $sth = $dbh->prepare(qq{SELECT DISTINCT hostgroup FROM monitor_hostgroups});
    $sth->execute();

    $log->debug(sprintf 'got %i hostgroups from db.', $sth->rows );

    # the hoststatus which've been fetched from the db
    my $db_hoststatus = $self->_db_get_hosts();

    # the servicestatus which've been fetched from the db.
    #

    #  After having gotten db_hoststatus and db_servicedetail, and read it into vars, now we replace
    #  the stuff in the database with what is found in the API. We'll compare them later.
    #
    #  This means that if crash here, then the data will have to be downloaded atain, but that's OK

    my $db_servicestatus = $self->_db_get_servicestatus();


    $log->trace(Dumper($db_servicestatus));

    # now remove the hostgroups from the monitor_hosts_from_hostgroup, it will need new hosts now.
    my $sth2 = $dbh->prepare('DELETE FROM monitor_hosts_from_hostgroup');
    $sth2->execute();

    # prepare a new statement to re-populate that hostgroup...
    $sth2 = $dbh->prepare('INSERT OR IGNORE INTO monitor_hosts_from_hostgroup (host_name, hostgroup) VALUES (?,?)');

    # Prepare to add a new host into monitor_hoststatus
    my $sth3 = $dbh->prepare('INSERT OR REPLACE INTO monitor_hoststatus (host_name, state, plugin_output, timestamp) VALUES(?,?,?,?)');

    # the same service status we just are about to get from the API.
    my %api_servicestatus;

    # Status of the host (We get them from the hostgroup)
    my %api_hoststatus;

    # Loop through all the configured hostgroups, and fetch node status for them.
    while ( my ($hostgroup) = $sth->fetchrow_array())
    {
        $log->debug("processing $hostgroup.....");

        my ($rval, $payload_or_message) = $self->__get_request(sprintf '/status/hostgroup/%s', $hostgroup);

        # do something with the payload.
        if ($rval)
        {
            my $payload = from_json($payload_or_message, { utf8 => 1 });
            my $timestamp = time;

            my $members = @$payload{'members_with_state'};

            foreach my $member (@$members)
            {
                my ($hostname, $state, $has_been_checked) = @$member;

                $log->debug(sprintf 'got %s with state %i. been checked=%i', $hostname, $state, $has_been_checked);
                # GET servicestatus AND some "valuable" info from the monitor API
                (my $plugin_output, %{$api_servicestatus{$hostname}}) = $self->_api_get_host($hostname);

                # create the hoststatus hash to look the same as what we got from the db earlier (hopefully)
                %{$api_hoststatus{$hostname}} = (
                               state => $state,
                    has_been_checked => $has_been_checked,
                       plugin_output => $plugin_output,
                );


                $log->trace(Dumper(%{$api_hoststatus{$hostname}}));

                # Add to monitor_hosts_from_hostgroup (so we know what hostgroups this host belong to
                $sth2->execute($hostname, $hostgroup);
                # And insert the state of the host here.
                $sth3->execute($hostname, $state, $plugin_output, $timestamp);

            }
        }
    }


    # Insert the host status stuff into the database...
    $self->__insert_new_servicestatus(\%api_servicestatus);


    # OK so lets compare few things.
    foreach my $hostname (keys %api_servicestatus)
    {
        $log->debug("processing $hostname ...");
        $log->trace(Dumper($api_hoststatus{$hostname}));

        # check if new host exists in the database or not.
        unless ($$db_hoststatus{$hostname})
        {
            # TODO: handle the new host here.
            $log->debug(sprintf 'no known status for %s from the database', $hostname);
            next;
        } elsif ($$db_hoststatus{$hostname}{'state'} != $api_hoststatus{$hostname}{'state'}){
            # HOST STATUS CHANGE HERE.
            # This is important, because if a host is down, we dont want to send the alarms for that host.
            $log->debug(Dumper($api_hoststatus{$hostname}));
            $self->__insert_hosts_to_msg([$hostname, $$db_hoststatus{$hostname}{'state'}]);
        }
        #
        #   Here comes the service checks, but we're only interrested in those
        #   if the host itself is up, because if host is down, everything will alarm.
        #
        if ($api_hoststatus{$hostname}{'state'} == 0)
        {
            #   Check all services
            foreach my $service (keys %{$api_servicestatus{$hostname}})
            {
                $log->trace("processing $service for $hostname");
                # check if the service is defined in the database or not.
                unless ($$db_servicestatus{$hostname}{$service})
                {
                    # TODO: handle the new service def for new host here.
                    if ($api_servicestatus{$hostname}{$service}{'state'} != 0)
                    {
                        $self->__insert_services_to_msg([$hostname,$service,undef]);
                    }

                    $log->debug(sprintf 'no previous service %s for host %s from the database:%s', $service, $hostname, Dumper(%{$$db_servicestatus{$hostname}{$service}}));
                    next;
                }

                #
                # get the service state from API and database
                #
                my $api_sstate = $api_servicestatus{$hostname}{$service}{'state'};
                my $db_sstate  = $$db_servicestatus{$hostname}{$service}{'state'};


                if ($api_sstate != $db_sstate)
                {
                    #
                    # Here we got a diff between what nagios says and last "known" status (ie what it said last time
                    # we checked, that's why this is an event we can send an alarm to or some such)
                    #
                    $log->debug(sprintf 'service "%s" for host "%s" have changed state from %s to %s.:%s', $service, $hostname, $db_sstate, $api_sstate, $api_servicestatus{$hostname}{$service}{'plugin_output'});


                    # Prepare tha database for the new message about what's changed.
                    $self->__insert_services_to_msg([$hostname, $service, $db_sstate]);

                } else {
                    $log->debug(sprintf 'service "%s" for host "%s" remain %i.', $service, $hostname, $db_sstate);
                }
            }
        }
    }


    # OK lets update the database.
    #
    # First remove everyting (almost)!!
=pod
    $sth = $dbh->prepare(qq{
        DELETE FROM monitor_servicedetail
          WHERE NOT host_name IN (SELECT DISTINCT host FROM monitor_hosts)});


     SELECT monitor_hosts_from_hostgroup.hostgroup,
                   monitor_servicedetail.host_name,
                   monitor_servicedetail.service,
                   monitor_servicedetail.state
             FROM  monitor_servicedetail
        INNER JOIN monitor_hosts_from_hostgroup
      ON monitor_hosts_from_hostgroup.host_name = monitor_servicedetail.host_name;



    $sth->execute();
=cut
    $sth = $dbh->prepare(qq{
        REPLACE INTO monitor_servicedetail (
                host_name,
                  service,
                    state,
         has_been_checked) VALUES (?,?,?,?)
     });

    # to update host status.
    $sth2 = $dbh->prepare('UPDATE  monitor_hoststatus SET state = ? where host_name = ?');

    #foreach my $hostname (keys %api_servicestatus)



    # TODO: Fix tomorrow.

    #$sth = $dbh->prepare(qq{
    #    INSERT INTO monitor_servicedetail host_name, service, state, has_been_checked
    #            VALUES (?,?,?,?)});




    return;
}

sub _api_get_host
{
    my $self = shift;
    my $host = shift;
    my %host_services;
    my $hostinfo; # the ref to json if succesful
    # make an API call to the monitor server to fetch info about the host.


    my ($rval, $payload_or_message) = $self->__get_request(sprintf '/status/host/%s', $host);

    if ($rval)
    {
        $hostinfo = from_json(($payload_or_message), { utf8 => 1 });
    } else {
        $log->warn("unable to pull data from $host: $payload_or_message");
        return;
    }

    my $services = @$hostinfo{'services_with_info'};
    $log->trace($services);

    # Get all the services
    foreach my $service (@$services)
    {
        $log->trace(Dumper($service));
        my ($servicename, $state, $has_been_checked, $plugin_output) = @$service;
        %{$host_services{$servicename}} = (
                   'state' => $state,
           'plugin_output' => $plugin_output,
               'host_name' => $host,
        'has_been_checked' => $has_been_checked,
        );
        $log->trace(sprintf 'from nagios: service for "%s": "%s" with state %i: "%s"', $host, $servicename, $state, $plugin_output);
    }

    # status message in human readable format.
    my $plugin_output = $$hostinfo{'plugin_output'};

    return $plugin_output,  %host_services;
}


sub _db_get_hosts
{
    my $self = shift;
    my $dbh = $self->dbh();

    my $sth = $dbh->prepare('SELECT state, host_name FROM monitor_hoststatus');

    $sth->execute();


    my $hosts = $sth->fetchall_hashref('host_name');

    $log->trace(Dumper($hosts));

    return $hosts;
}

sub _db_get_servicestatus
{
    my $self = shift;
    my $dbh = $self->dbh();
    # Here the last known statuses are fetched from the database !!
    my $sth = $dbh->prepare('SELECT state, host_name, has_been_checked, service FROM monitor_servicedetail');

    $sth->execute();


    my $hosts = $sth->fetchall_hashref([ qw/host_name service/ ]);

    $log->trace(Dumper($hosts));

    return $hosts;
}

sub __get_request
{
    my $self = shift;
    # the API path.
    my $path = shift;

    my $password = $self->get_config('password');
    my $username = $self->get_config('username');
    my $nagios_server = $self->get_config('nagios-server');
    my $apiurl = sprintf 'https://%s/api%s?format=json', $nagios_server, $path;

    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new(GET => $apiurl);

    if ($username && $password)
    {
        $log->info(sprintf 'setting authorization headers username=%s, password=[SECRET]', $username);
        $req->authorization_basic($username, $password);
    }

    # Do the download.
    my $response = $ua->request($req);

    # dome logging
    if ($response->is_success)
    {
        $log->debug("SUCCESSFULLY downloaded $apiurl");
        return 1, $response->decoded_content;
    } else {
        $log->warn(sprintf "ERROR on attempted download of %s:%s", $apiurl, $response->status_line);
        return 0, $response->status_line;
    }
}

sub __insert_new_servicestatus
{
    my $self = shift;
    my $hoststatus = shift;
    my $dbh = $self->dbh();


    my $rc  = $dbh->begin_work;

    # timestamp

    my $timestamp = time;

    # prepairng to insert new stuff.
    my $sth  = $dbh->prepare(qq{INSERT OR REPLACE INTO monitor_servicedetail
                           (host_name,
                                service,
                            plugin_output,
                                      state,
                             has_been_checked,
                                     timestamp) VALUES(?,?,?,?,?,?)});

    while (my ($hostname, $services) = each (%{$hoststatus}))
    {
        while (my ($service, $sd) = each (%{$services}))
        {
            $log->debug("I NOW AM DOING THIS for $hostname - $service `$$sd{plugin_output}`");
            unless($sth->execute($$sd{'host_name'}, $service, $$sd{'plugin_output'}, $$sd{'state'}, $$sd{'has_been_checked'}, $timestamp))
            {
                $log->warn(sprintf 'Updating monitor_servicedetail failed with msg:"%s". Rolling back.', $dbh->errstr());
                $dbh->rollback;
                last;
            }
        }
    }
    unless ($dbh->commit)
    {
        $log->warn(sprintf 'unable to save new monitor servicedetail:"%s"', $dbh->errstr());
        $dbh->rollback or $log->warn("unable to roll back the changes in the db:" . $dbh->errstr());
    }
}


sub __insert_hosts_to_msg
{
    # insert a few rows to this table, and then gutta the bot knows what to msg in the channels about when the time comes.
    # here are specific things for the HOSTS which gutta monitors.
    my $self = shift;
    my @hosts_to_msg = @_;
    my $dbh = $self->dbh();

    my $sth = $dbh->prepare('INSERT OR REPLACE INTO monitor_message_hosts (host_name, old_state) VALUES(?,?)');

    foreach my $what2add (@hosts_to_msg)
    {
        my ($host_name, $old_state) = @{$what2add};
        $sth->execute($host_name, $old_state);
    }


}

sub __insert_services_to_msg
{
    # insert a few rows to this table, and then gutta the bot knows what to msg in the channels about when the time comes.
    # here are specific things for the HOSTS services to monitor about.
    my $self = shift;
    my @hosts_to_msg = @_;
    my $dbh = $self->dbh();

    my $sth = $dbh->prepare('INSERT OR REPLACE INTO monitor_message_servicedetail
                                        (host_name, service, old_state) VALUES(?,?,?)');

    foreach my $what2add (@hosts_to_msg)
    {
        my ($host_name, $service, $old_state) = @{$what2add};
        $sth->execute($host_name, $service, $old_state);
    }
}

sub _heartbeat_act
{
    #  Gets called when the heartbeat is time to act.
    #
    #


    my $self = shift;
    $self->_monitor_runonce;
}

sub heartbeat_res
{
    # the response gets populated if anything new is found, and then it
    # is sent to the server.
    my $self = shift;
    my $server = shift;

    my $dbh = $self->dbh();
    my $sth;

    # The responses to return from this sub.
    # It's a flat list of IRC PRIVMSGS
    my @responses;

    # timestamp
    my $timestamp = time; # TODO add timestamp to filter out "stale" alarms (it easy)

    # WHO TO SEND WHAT TO =
    $sth  = $dbh->prepare(qq{
      SELECT DISTINCT irc_server, channel, host_name
        FROM  (SELECT irc_server, channel, host_name
                FROM monitor_hosts_from_hostgroup a
          INNER JOIN monitor_hostgroups b
                  ON a.hostgroup = b.hostgroup)
    });

    $sth->execute();
    my $servchan = $sth->fetchall_hashref([ qw/irc_server channel host_name/ ]);

    $sth = $dbh->prepare(qq{
          SELECT a.host_name,
                 b.plugin_output,
                 b.state
            FROM monitor_message_hosts a
      INNER JOIN monitor_hoststatus b
              ON a.host_name = b.host_name
      INNER JOIN monitor_hosts_from_hostgroup c
              on c.host_name = a.host_name
    });

    $sth->execute();
    my $hoststatus = $sth->fetchall_hashref([qw/host_name/]);


    # All the new alarms for this run, which should be sent as appropriate.
    $sth = $dbh->prepare(qq{
         SELECT a.host_name,
                b.service,
                b.plugin_output,
                b.state,
                b.timestamp
           FROM monitor_message_servicedetail a
     INNER JOIN monitor_servicedetail b
             ON a.host_name = b.host_name
            AND a.service = b.service
     INNER JOIN monitor_hosts_from_hostgroup c
             ON a.host_name = c.host_name
          WHERE a.host_name
         NOT IN ( SELECT host_name
                    FROM monitor_hoststatus
                   WHERE state != 0 )
    });



    $sth->execute();
    my $services = $sth->fetchall_hashref([ qw/host_name service/ ] );

    $log->debug("  SERVCHAN:" . Dumper($servchan));
    $log->debug("HOSTSTATUS:" . Dumper($hoststatus));
    $log->debug("  SERVICES:" . Dumper($services));

    while (my ($server_re, $chan) = each (%{$servchan}))
    {
        # step 1. is filtering out what server is coming and see what is relevant
        if ($server =~ qr/$server_re/)
        {
            # server match found here. so continuing exploring.
            $log->info("'$server' matches regex '$server_re': Proceeding.");

            # extract all the channels to queue IRC messages responses here.
            while (my ($channel, $hosts) = each (%{$chan}))
            {
                while (my ($host_name, $host_msg_cfg) = each (%{$hosts}))
                {
                    $log->debug("evaluating $$host_msg_cfg{'host_name'}");
                    # First: a check here to see what's up with the HOSTS
                    # TODO: a check here to see if joined to chan
                    #(no supprort for that yet thoough)
                    if ($$hoststatus{$$host_msg_cfg{'host_name'}})
                    {
                        # TODO: here can check if keys %{chan} > X to determine if something is *really* messed up
                        # and write something about that, because there's a risk of flooding if sending too many PRIVMSGS.
                        # and if 20+ hosts are down or uå, you can bundle the names and say THESE ARE DOWN (list of hosts)
                        # and these hosts are UP (list of hosts)
                       
                        # First take relevant info here so as to not have to type so much.
                        my $s = $$hoststatus{$$host_msg_cfg{'host_name'}};
                        $log->debug("Will send a message about $$host_msg_cfg{'host_name'} to $channel, saying  this: " . Dumper($s));
                        # Format a nicely formatted message here TODO: color support.
                        push @responses, sprintf 'msg %s %s is %s: %s', $channel, $$s{'host_name'}, $$s{'state'} , $$s{'plugin_output'};
                    } elsif ($$services{$$host_msg_cfg{'host_name'}}) {
                        # TODO: here can check if keys %{chan} > X to determine if something is *really* messed up
                        # and write something about that, because there's a risk of flooding if sending too many PRIVMSGS.
                        # and if 20+ services are down, you can bundle the names and say THESE HOSTS ARE X (list of hosts)

                        # First take relevant info here so as to not have to type so much.
                        my $s = $$services{$$host_msg_cfg{'host_name'}};
                        $log->debug("Will send a message about $$host_msg_cfg{'host_name'} to $channel, saying  this: " . Dumper($s));
                        while (my ($service_name, $service_data) = each (%{$s}))
                        {
                            $log->debug("Will send a message about $$host_msg_cfg{'host_name'} service $service_name to $channel, saying  this: " . Dumper($service_data));
                            push @responses, sprintf 'msg %s %s "%s" is %s: %s', $channel, $$s{'host_name'}, $service_name, $$service_data{'state'} , $$service_data{'plugin_output'};
                        }
                    }
                }
            }
        } else {
            $log->info("$server DOES NOT match regex $server_re: Skipping.");

        }
    }

    #
    # OK removing the junk from the db, I dont think this is thread safe
    #
    $sth = $dbh->prepare('DELETE FROM monitor_message_servicedetail');
    $sth->execute;
    $sth = $dbh->prepare('DELETE FROM monitor_message_hosts');
    $sth->execute;

    return @responses;
}


1;
