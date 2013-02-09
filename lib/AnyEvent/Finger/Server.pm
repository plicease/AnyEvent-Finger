package AnyEvent::Finger::Server;

use strict;
use warnings;
use v5.10;
use Carp qw( carp croak );
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket qw( tcp_server );
use AnyEvent::Finger::Transaction;
use AnyEvent::Finger::Request;
use AnyEvent::Finger::Response;

# ABSTRACT: Simple asynchronous finger server
# VERSION

=head1 SYNOPSIS

 use AnyEvent::Finger::Server;
 my $server = AnyEvent::Finger::Server->new;
 
 my %users = (
   grimlock => "ME GRIMLOCK HAVE PLAN",
   optimus  => "Freedom is the right of all sentient beings.",
 );
 
 $server->start(sub {
   my($tx) = @_;
   if($tx->req->listing_request)
   {
     # respond if remote requests list of users
     $tx->res->say('users:', keys %users);
     $tx->res->done;
   }
   else
   {
     # respond if user exists
     if(defined $users{$tx->req->username})
     {
       $tx->res->say($users{$tx->req->username});
       $tx->res->done;
     }
     # respond if user does not exist
     else
     {
       $tx->res->say('no such user');
       $tx->res->done;
     }
   }
 });

=head1 DESCRIPTION

Provide a simple asynchronous finger server.

=head1 CONSTRUCTOR

The constructor takes the following optional arguments:

=over 4

=item *

hostname (default 127.0.0.1)

The hostname to connect to.

=item *

port (default 79)

The port to connect to.

=item *

on_error (carp error)

A callback subref to be called on error (either connection or transmission error).
Passes the error string as the first argument to the callback.

=item *

on_bind

A callback subref to be called when the port number is known.  This is
useful when ephemeral port is used but other parts of the code depend on it.
The first argument to the callback will be the L<AnyEvent::Finger::Server>
object.

=item *

forward_deny (0)

Deny forward requests, (for example: C<finger@host1@host2@...> style requests).  
If neither C<forward_deny> or C<forward> is specified then forward requests will 
be passed on to the callback, like all other requests.

=item *

forward (0)

Forward forward requests.  This can be set to either 1, or an instance of
L<AnyEvent::Finger::Client> which will be used to forward requests.  If neither
C<forward_deny> or C<forward> is specified then forward requests will be passed
on to the callback, like all other requests.

=back

=cut

sub new
{
  my $class = shift;
  my $args     = ref $_[0] eq 'HASH' ? (\%{$_[0]}) : ({@_});
  bless {
    hostname     => $args->{hostname},  
    port         => $args->{port}         // 79,
    on_error     => $args->{on_error}     // sub { carp $_[0] },
    on_bind      => $args->{on_bind}      // sub { },
    forward_deny => $args->{forward_deny} // 0,
    forward      => $args->{forward}      // 0,
  }, $class;
}

=head1 METHODS

=head2 $server-E<gt>start( $callback )

Start the finger server.  The callback will be called each time a
client connects.

 $callback->($tx)

The first argument passed to the callback is the transaction object,
which is an instance of L<AnyEvent::Finger::Transaction>.  The most
important members of these objects that you will want to interact
with are C<$tx-E<gt>req> for the request (an instance of 
L<AnyEvent::Finger::Request>) and C<$tx-E<gt>res> for the response
interface (an instance of L<AnyEvent::Finger::Response>).

With the response object you can return a whole response at one time:

 $tx->res->say(
   "this is the first line", 
   "this is the second line", 
   "there will be no forth line",
 );
 $tx->res->done;

or you can send line one at a time as they become available (possibly
asynchronously).

 # $dbh is a DBI database handle
 my $sth = $dbh->prepare("select user_name from user_list");
 while(my $h = $sth->fetchrow_hashref)
 {
   $tx->res->say($h->{user_name});
 }
 $tx->res->done;

The server will unbind from its port and stop if the server
object falls out of scope, or if the C<stop> method (see below)
is called.
 
=cut

sub start
{
  my $self     = shift;
  my $callback = shift;
  my $args     = ref $_[0] eq 'HASH' ? (\%{$_[0]}) : ({@_});

  croak "already started" if $self->{guard};

  $args->{$_} //= $self->{$_}
    for qw( hostname port on_error on_bind forward forward_deny );

  my $forward = $args->{forward} // $self->{forward};
  if($forward)
  {
    unless(ref $forward)
    {
      require AnyEvent::Finger::Client;
      $args->{forward} = AnyEvent::Finger::Client->new;
    }
  }
    
  my $cb = sub {
    my ($fh, $host, $port) = @_;

    my $handle;
    $handle = AnyEvent::Handle->new(
      fh       => $fh,
      on_error => sub {
        my ($hdl, $fatal, $msg) = @_;
        $args->{on_error}->($msg);
        $_[0]->destroy;
      },
      on_eof   => sub {
        $handle->destroy;
      },
    );

    $handle->push_read( line => sub {
      my($handle, $line) = @_;
      $line =~ s/\015?\012//g;

      my $res = sub {
        my $lines = shift;
        $lines = [ $lines ] unless ref $lines eq 'ARRAY';
        foreach my $line (@$lines)
        {
          if(defined $line)
          {
            $handle->push_write($line . "\015\012");
          }
          else
          {
            $handle->destroy;
            return;
          }
        }
      };

      bless $res, 'AnyEvent::Finger::Response';
      my $req = AnyEvent::Finger::Request->new($line);
      
      my $tx = bless { 
        req            => $req, 
        res            => $res,
        remote_port    => $port,
        local_port     => $self->{bindport},
        remote_address => $host,
      }, 'AnyEvent::Finger::Transaction';
      
      if($args->{forward_deny} && $tx->req->forward_request)
      {
        $res->(['finger forwarding service denied', undef]);
        return;
      }
      
      if($forward && $req->forward_request)
      {
      
        my $host = pop @{ $req->hostnames };
        my $new_request = join '@', $req->username, @{ $req->hostnames };
        $new_request = '/W ' . $new_request if $req->verbose;
        $forward->finger($new_request, sub {
          my $lines = shift;
          push @$lines, undef;
          $res->($lines);
        }, { hostname => $host });
        return;
      }

      $callback->($tx);
    });
  };
  
  my $port = $args->{port};
  undef $port if $port == 0;
  
  $self->{guard} = tcp_server $args->{hostname}, $port, $cb, sub {
    my($fh, $host, $port) = @_;
    $self->{bindport} = $port;
    $args->{on_bind}->($self);
  };
  
  $self;
}

=head2 $server-E<gt>bindport

The bind port.  If port is set to zero in the constructor or on
start, then an ephemeral port will be used, and you can get the
port number here.  This value is not available until the socket
has been allocated and bound to a port, so if you need this
value after calling C<start> but before any clients have connected
use the C<on_bind> callback.

=cut

sub bindport { shift->{bindport} }

=head2 $server-E<gt>stop

Stop the server and unbind to the port.

=cut

sub stop
{
  my($self) = @_;
  delete $self->{guard};
  delete $self->{bindport};
  $self;
}

1;
