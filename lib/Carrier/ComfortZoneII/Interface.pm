package Carrier::ComfortZoneII::Interface;

use strict;

use Carrier::ComfortZoneII::FrameParser;
use Digest::CRC qw(crc16);
use IO::Socket;
use MIME::Base64 qw(encode_base64 decode_base64);
use Params::Validate qw(:all);

###############################################################################

our $PROTOCOL_SIZE    = 10;
our $MIN_MESSAGE_SIZE = $PROTOCOL_SIZE + 1;
our $MAX_MESSAGE_SIZE = $PROTOCOL_SIZE + 255;

our $FRAME_TESTER = Carrier::ComfortZoneII::FrameParser::frame_tester;
our $FRAME_PARSER = Carrier::ComfortZoneII::FrameParser::frame_parser;

our %SYSTEM_MODE =
  (
   0 => "Heat",
   1 => "Cool",
   2 => "Auto",
   3 => "E Heat",
   4 => "Off",
  );

our @WEEKDAY = qw(Sun Mon Tue Wed Thu Fri Sat);

###############################################################################

sub new {
  #
  # Constructor. Required arguments:
  #
  #   connect => either host:port or /dev/ttyXXX
  #   zones   => the number of zones in your system
  #
  my $proto = shift;
  my $class = ref ($proto) || $proto;

  my $self =
    {
     validate
       (@_,
        {
         connect => 1,
         zones   => { type => SCALAR, regex => qr/^[1-8]$/               },
         id      => { type => SCALAR, regex => qr/^\d+$/,  default => 99 },
        })
    };

  $self->{fh}     = undef;
  $self->{buffer} = '';
  $self->{short}  = 0;

  bless  $self, $class;
  return $self;
}

sub fh {
  #
  # Get a filehandle for serial communication. Open or connect if not
  # already done.
  #
  my ($self) = @_;

  return $self->{fh} if defined $self->{fh};

  my $connect = $self->{connect};

  if (ref $connect) {

    $self->{fh} = $connect;

  } elsif ($connect =~ /:/) {

    my ($host, $port) = split /:/, $connect;
    $self->{fh} = IO::Socket::IP->new
      (
       PeerHost => $host,
       PeerPort => $port,
      )
      or die "Error connecting to $connect: $!\n";

  } else {

    require IO::Termios;

    eval {
      $self->{fh} = IO::Termios->open ($connect, "9600,8,n,1")
        or die "$!\n";
    };

    die "Error connecting to $connect as serial device: $@" if $@;

  }

  return $self->{fh};
}

sub try ($) {
  #
  # Attempt an I/O operation. Return on success, die on failure, exit
  # on EOF.
  #
  my ($len) = @_;

  return if $len > 0;
  exit   if defined $len;

  die "Error: $!\n";
}

sub get_frame {
  #
  # Read until a valid frame is found, and return it. Collisions are
  # expected, so a sliding-window approach is used.
  #
  my ($self) = @_;

  while (1) {
    if ($self->{short} or not length $self->{buffer}) {
      #
      # The buffer is empty, or is too short, or is long enough but
      # still doesn't contain a valid frame. Read more bytes.
      #
      try $self->fh->sysread (my $tmp, $MAX_MESSAGE_SIZE);

      $self->{buffer} .= $tmp;
      $self->{short}   = 0;
    }

    my $len = length $self->{buffer};

    if ($len < $MIN_MESSAGE_SIZE) {
      $self->{short} = 1;
      next;
    }

    #
    # The buffer is long enough so we'll search for a valid frame.
    # Partial or invalid frames can appear at any time, so we need to
    # search the whole buffer. If a valid frame is found, we'll
    # fast-forward the buffer to after the frame and then return it.
    #
    for my $offset (0..$len-$MIN_MESSAGE_SIZE) {
      my $test_frame = eval { $FRAME_TESTER->parse (substr ($self->{buffer}, $offset)) };
      next if $@;

      if ($test_frame and $test_frame->{valid}) {
        my $raw   = $test_frame->{frame};
        my $frame = $FRAME_PARSER->parse ($raw);

        $self->{buffer} = substr $self->{buffer}, $offset + length $raw;

        return $frame;
      }
    }

    #
    # No valid frame was found so we need some more bytes.
    #
    $self->{short} = 1;
  }
}

sub get_reply_frame {
  #
  # Read frames until we get a reply to the message we just sent.
  # Cross-talk is common so we'll let up to 5 frames go by before
  # giving up on finding a matching reply.
  #
  my ($self, $function, @match) = @_;
  my $count = 0;

  for (1..5) {
    my $f = $self->get_frame;

    next unless ($f->{destination} == $self->{id});

    if ($f->{function} eq "error") {
      return $f;
    } elsif ($f->{function} ne "reply") {
      next;
    }

    if ($function eq "read") {
      next unless
        (
         $f->{data}->[0] == $match[0] and
         $f->{data}->[1] == $match[1] and
         $f->{data}->[2] == $match[2]
        );
    }

    return $f;
  }

  return;
}

sub print_frame {
  #
  # Print a frame in human-readable format.
  #
  my ($self, $f) = @_;

  my $src  = $f->{source};
  my $dst  = $f->{destination};
  my $fun  = $f->{function};
  my $data = join ".", @{$f->{data}};

  printf "%02d -> %02d  %-5s  %s\n", $src, $dst, $fun, $data;
}

sub print_reply {
  #
  # Print a simple acknowledgement of a reply frame.
  #
  my ($self, $f) = @_;

  my $reply = $f->{data}->[0];

  if ($reply == 0) {
    print "Ok\n";
  } else {
    print "Reply code $reply\n";
  }
}

sub make_message {
  #
  # Compose a message frame to be sent. This should probably use the
  # build capability of Data::ParseBinary, with the struct defined in
  # Carrier::ComfortZoneII::FrameParser.
  #
  my ($self, $destination, $function, @data) = @_;

  my %functions =
    (
     reply => 0x06,
     read  => 0x0B,
     write => 0x0C,
     error => 0x15,
    );

  my $function_code = $functions{$function}
    or die "Invalid function: $function\n";

  my @bytes =
    (
     $destination, 0,  # Destination
     $self->{id},  0,  # Source
     scalar (@data),   # Data length
     0, 0,             # Reserved
     $function_code,   # Function
     @data,            # Data
    );

  my $message = pack ("C*", @bytes);
  my $crc     = pack ("S",  crc16 ($message));

  return ($message . $crc);
}

sub send_with_reply {
  #
  # Send a message and wait for a reply. If our message is the victim
  # of a collision, it will never reach its destination, so we'll
  # re-send it up to 5 times. Die if we get an error response, or no
  # response even after retries.
  #
  my ($self, $destination, $function, @data) = @_;

  my $m = $self->make_message ($destination, $function, @data);

  for (1..5) {
    try $self->fh->syswrite ($m);
    my $f = $self->get_reply_frame ($function, @data);

    unless ($f) {
      sleep 3;
      next;
    }

    die "Error reply received\n" if $f->{function} eq "error";
    return $f;
  }

  die "No reply received\n";
}

sub decode_temperature {
  #
  # Turn a two-byte temperature value into integer degrees.
  #
  my ($self, $high, $low) = @_;

  sprintf "%d", ((($high << 8) + $low) / 16);
}

sub get_status_data {
  #
  # Build a data structure that reflects the overall current status of
  # the system with all known values.
  #
  my ($self, $raw_input) = @_;

  my @queries = qw(9.3 9.4 9.5 1.9 1.12 1.16 1.17 1.18 1.24);
  my %data;

  if ($raw_input) {

    my @frames = $self->decode_raw ($raw_input);

    for my $frame (@frames) {
      my $data = $frame->{data};
      my $key  = join ".", $data->[1], $data->[2];

      $data{$key} = $data;
    }

    for my $key (@queries) {
      exists $data{$key}
        or die "Incomplete raw input (missing data for $key)\n";
    }

  } else {

    for my $query (@queries) {
      my ($table, $row) = split /\./, $query;

      my $f = $self->send_with_reply ($table, "read", 0, $table, $row);
      $data{$query} = $f->{data};
    }

  }

  my @raw;
  for my $row (sort keys %data) {
    my @values = @{$data{$row}};

    push @raw, scalar @values;
    push @raw, @values;
  }

  my $raw = encode_base64 (pack ("C*", @raw), "");

  my @zones;
  my $status =
    {
     time => time,
     raw  => $raw,
    };

  my ($ampm, $day, $hour, $min, $sec) = ("am", @{$data{"1.18"}}[3..6]);
  if ($hour == 0) {
    $hour  = 12;
  } elsif ($hour >= 12) {
    $ampm  = "pm";
    $hour -= 12 if $hour > 12;
  }

  my $system_time = sprintf "%s %02d:%02d%s", $WEEKDAY[$day], $hour, $min, $ampm;

  $status->{system_mode}      = $SYSTEM_MODE{$data{"1.12"}->[4]};
  $status->{effective_mode}   = $SYSTEM_MODE{$data{"1.12"}->[6]};
  $status->{system_time}      = $system_time;
  $status->{outside_temp}     = $self->decode_temperature ($data{"9.3"}->[4], $data{"9.3"}->[5]);
  $status->{air_handler_temp} =  $data{"9.3"} ->[6];
  $status->{reverse}          = ($data{"9.5"} ->[3]  & 0x10) ? 1 : 0;
  $status->{fan}              = ($data{"9.5"} ->[3]  & 0x20) ? 1 : 0;
  $status->{compressor_1}     = ($data{"9.5"} ->[3]  & 0x01) ? 1 : 0;
  $status->{compressor_2}     = ($data{"9.5"} ->[3]  & 0x02) ? 1 : 0;
  $status->{aux_heat_1}       = ($data{"9.5"} ->[3]  & 0x04) ? 1 : 0;
  $status->{aux_heat_2}       = ($data{"9.5"} ->[3]  & 0x08) ? 1 : 0;
  $status->{zone1_humidity}   =  $data{"1.9"} ->[4];
  $status->{all_mode}         =  $data{"1.12"}->[15];
  $status->{fan_mode}         = ($data{"1.17"}->[3]  & 0x04) ? "Always On" : "Auto";

  $status->{compressor}       = $status->{compressor_1} || $status->{compressor_2};
  $status->{aux_heat}         = $status->{aux_heat_1}   || $status->{aux_heat_2};

  for my $zone (0..$self->{zones}-1) {
    my $bit = 1 << $zone;

    $zones[$zone]->{damper_position} = sprintf "%d", 100 * ($data{"9.4"}->[$zone+3] / 15);
    $zones[$zone]->{cool_setpoint}   = $data{"1.16"}->[$zone+3];
    $zones[$zone]->{heat_setpoint}   = $data{"1.16"}->[$zone+11];
    $zones[$zone]->{temperature}     = $data{"1.24"}->[$zone+3];
    $zones[$zone]->{temporary}       = $data{"1.12"}->[9]  & $bit;
    $zones[$zone]->{hold}            = $data{"1.12"}->[10] & $bit;
    $zones[$zone]->{out}             = $data{"1.12"}->[12] & $bit;
  }

  if (my $all = $status->{all_mode}) {
    for my $zone (0..$self->{zones}-1) {
      $zones[$zone]->{cool_setpoint} = $zones[$all-1]->{cool_setpoint};
      $zones[$zone]->{heat_setpoint} = $zones[$all-1]->{heat_setpoint};
      $zones[$zone]->{temporary}     = $zones[$all-1]->{temporary};
      $zones[$zone]->{hold}          = $zones[$all-1]->{hold};
      $zones[$zone]->{out}           = $zones[$all-1]->{out};
    }
  }

  $status->{zones} = [@zones];
  return $status;
}

sub decode_raw {
  #
  # Turn a "raw" status_data result back into the original frames
  #

  my ($self, $raw) = @_;

  my @raw = unpack ("C*", decode_base64 ($raw));
  my @frames;

  while (@raw) {
    my $length = shift  @raw;
    my @bytes  = splice @raw, 0, $length;

    my $frame =
      {
       source      => $bytes[1],
       destination => $self->{id},
       function    => "reply",
       data        => [@bytes],
      };

    push @frames, $frame;
  }

  return @frames;
}
