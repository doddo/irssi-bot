# == WHAT
# All around bot.
#
# == WHO
# Based on "All around bot" by Jeroen Van den Bossche, 2012
# Fork By PETTER H 2014
#
# == INSTALL
# Save it in ~/.irssi/scripts/ and do /script load bot.pl
# OR
# Save it in ~/.irssi/scripts/autorun and (re)start Irssi

use strict;
use warnings;
use Irssi;
use LWP::Simple;
use HTML::TokeParser;
use Data::Dumper;
use Storable;
use vars qw($VERSION %IRSSI);

$VERSION = '0.1';
%IRSSI = (
    authors => 'Petter H',
    name => 'gutta',
    description => 'All around Irssi bots brother gutta.',
    license => 'GPL',
);


# loading the brainfile
#
# creat it if need be#
my $brainfile = 'brainfile';
unless ( -f $brainfile)
{
   create_brainfile($brainfile);
}
# and then load it
my $brain = retrieve($brainfile);


sub create_brainfile
{
    my $brainfile = shift;
    warn "initialising new brain file\n";
    my %brain = (
        karma => {},
    );
    store \%brain, $brainfile;
}

sub process_message 
{
    my $server = shift;
    my $msg = shift;
    my $nick = shift;
    my $target = shift;
    my $save;

    while ($msg =~ m/([\S]{2,100})(\+\+|--)/g)
    {
         $server->command("msg $target " . karma($1,$2,$nick));
         $save = 1;
    }

    if ($msg =~ m/^srank\s+(\S+)?/) {
        $server->command("msg $target " . $_) foreach srank($1)
    } elsif ($msg =~ m/^\s*!ibood/) {
        $server->command("msg $target " . ibood());
    } elsif ($msg =~m/^\s*!slap\s+(\S+)/){
        $server->command("msg $target " . slap($1));
    }
    

    store $brain, $brainfile if $save;
}

sub slap
{
    my $target = shift;
    return "$target got slapped around a bit with a large trout.";

}

sub ibood
{
    my $url = "http://ibood.com/be/nl/";
    my $html = get($url);
    my $parser = HTML::TokeParser->new(\$html);
    my ($title, $price) = 0;
    while ( my $token = $parser->get_tag("a") )
    {
        if ($token->[1]{id} and ($token->[1]{id} eq "link_product"))
        {
            $title = $parser->get_trimmed_text;
            last;
        }
    }
    $parser = HTML::TokeParser->new(\$html);
    while ( my $token = $parser->get_tag("span") )
    {
        if ($token->[1]{class} and ($token->[1]{class} eq "price"))
        {
            $parser->get_tag("span");
            $price = $parser->get_text;
            last;
        }
    }
    return "iBood: $title. (\x{20AC}$price) $url";
}

sub karma
{
  my $target = shift;
  my $modifier = shift;
  my $user = shift;

  if (($modifier eq '++') and 
      ($user ne $target))
  {
    $$brain{'karma'}{lc($target)}++;
  } else {
    $$brain{'karma'}{lc($target)}--;
  }
  
  return "$target now has " . $$brain{'karma'}{lc($target)} . " points of karma." ;
}

sub srank
{
    my $target = shift;
    my @sranks;
    warn("OK KALLE");
    my @karmalist = sort { $$brain{'karma'}{$b} <=> $$brain{'karma'}{$a} } keys %{$$brain{'karma'}};
    @karmalist = grep(/$target/i, @karmalist) if $target;
    foreach (@karmalist)
    {
        push(@sranks, $_ . " (" . $$brain{'karma'}{$_} .")");
        last if (scalar @sranks >10);
    }
    return @sranks;
}

Irssi::signal_add_last('message public', sub {
    my $server = shift;
    my $msg = shift;
    my $nick = shift;
    my $mask = shift;
    my $target = shift;
    Irssi::signal_continue($server, $msg, $nick, $mask, $target);
    eval {
        process_message($server, $msg, $nick, $target) if $nick ne $server->{nick};
    };
    warn ($@) if $@;
});
=pod
Irssi::signal_add_last('message own_public', sub {
    my ($server, $msg, $target) = @_;
    Irssi::signal_continue($server, $msg, $target);
    process_message($server, $msg,$target);
});
=cut
