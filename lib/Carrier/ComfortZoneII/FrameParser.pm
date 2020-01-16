package Carrier::ComfortZoneII::FrameParser;

use strict;

use Data::ParseBinary;
use Digest::CRC qw(crc16);

# Adapted from https://github.com/nebulous/infinitude/blob/master/lib/CarBus/Frame.pm

my $frame_tester = Struct
  (
   "TestFrame",
   Peek  (Byte ("length"), 4),
   Field ("frame", sub { $_->ctx->{length} + 10 }),
   Value ("valid", sub { $_->ctx->{length} > 0 and crc16 ($_->ctx->{frame}) == 0 }),
  );

my $frame_parser = Struct
  (
   "Frame",
   Byte    ("destination"),
   Padding (1),
   Byte    ("source"),
   Padding (1),
   Byte    ("length"),
   Padding (2),
   Enum    (
            Byte("function"),
            reply     => 0x06,
            read      => 0x0B,
            write     => 0x0C,
            error     => 0x15,
            _default_ => $DefaultPass,
           ),
   Array   (sub { $_->ctx->{length} }, Byte ("data")),
   UBInt16 ("checksum"),
  );

sub frame_tester { $frame_tester };
sub frame_parser { $frame_parser };

1;
