package Debug;

=head1 NAME

Debug - allows for basic data dumping and introspection.

=cut

####----------------------------------------------------------------###
##  Copyright 2014 - Bluehost                                         #
##  Distributed under the Perl Artistic License without warranty      #
####----------------------------------------------------------------###

use strict;
use base qw(Exporter);
our @EXPORT    = qw(debug debug_warn debug_dlog);
our @EXPORT_OK = qw(debug_text debug_html debug_plain caller_trace);
our $QR_TRACE1 = qr{ \A (?: /[^/]+ | \.)* / (?: perl | lib | cgi(?:-bin)? ) / (.+) \Z }x;
our $QR_TRACE2 = qr{ \A .+ / ( [\w\.\-]+ / [\w\.\-]+ ) \Z }x;

my %LINE_CACHE;
my $DEPARSE;

sub set_deparse { $DEPARSE = 1 }

sub _dump {
    local $Data::Dumper::Deparse   = $DEPARSE && eval {require B::Deparse};
    local $Data::Dumper::Sortkeys  = 1;
    local $Data::Dumper::Useqq     = 1;
    local $Data::Dumper::Quotekeys = 0;

    my $ref;
    for (ref($_[0]) eq 'ARRAY' ? @{ $_[0] } : @_) { last if UNIVERSAL::isa($_, 'HASH') && ($ref = $_->{'dbh_cache'}) }
    local @$ref{keys %$ref} = ('hidden')x(keys %$ref) if $ref;

    return Data::Dumper->Dumpperl(\@_);
}

###----------------------------------------------------------------###

sub _what_is_this {
    my ($pkg, $file, $line_n, $called) = caller(1);
    $called =~ s/.+:://;

    my $line = '';
    if (defined $LINE_CACHE{"$file:$line_n"}) {
        # Just use global cache
        $line = $LINE_CACHE{"$file:$line_n"};
    }
    else {
        if (open my $fh, '<', $file) {
            my $n = 0;
            my $ignore_after = $line_n + 1000;
            while (defined(my $l = <$fh>)) {
                if (++$n == $line_n) {
                    $LINE_CACHE{"$file:$line_n"} = $line = $l;
                }
                elsif ($l =~ /debug/) {
                    $LINE_CACHE{"$file:$n"} = $l;
                }
                elsif ($n > $ignore_after) {
                    last;
                }
            }
            close $fh;
        }
        $line ||= "";
        $LINE_CACHE{"$file:$line_n"} = $line;
    }

    $file =~ s/$QR_TRACE1/$1/ || $file =~ s/$QR_TRACE2/$1/; # trim up extended filename

    require Data::Dumper;
    # WARNING: Must require module BEFORE setting Data::Dumper::* stuff! -- Rob Brown -- 2010-08-18
    # I'm not sure why, but if you require AFTER setting, it barfs with horrible scary warn spewage:
    # Use of uninitialized value in numeric gt (>) at /usr/lib64/perl5/5.8.8/x86_64-linux-thread-multi/Data/Dumper.pm line 97.
    # Use of uninitialized value in subroutine entry at /usr/lib64/perl5/5.8.8/x86_64-linux-thread-multi/Data/Dumper.pm line 179.
    local $Data::Dumper::Indent = 1 if $called eq 'debug_warn' || $called eq 'debug_dlog';

    # dump it out
    my @dump = map {_dump($_)} @_;
    my @var  = ('$VAR') x @dump;
    my $hold;
    if ($line =~ s/^ .*\b \Q$called\E ( \s* \( \s* | \s+ )//x
        && ($hold = $1)
        && ($line =~ s/ \s* \b if \b .* \n? $ //x
            || $line =~ s/ \s* ; \s* $ //x
            || $line =~ s/ \s+ $ //x)) {
        $line =~ s/ \s*\) $ //x if $hold =~ /^\s*\(/;
        my @_var = map {/^[\"\']/ ? 'String' : $_} split (/\s*,\s*/, $line);
        @var = @_var if $#var == $#_var;
    }

    # spit it out
    if ($called eq 'debug_html'
        || ($called eq 'debug' && $ENV{'REQUEST_METHOD'})) {
        my $html = "<pre style=\"text-align:left\"><b>$called: $file line $line_n</b>\n";
        for (0 .. $#dump) {
            $dump[$_] =~ s/(?<!\\)\\n/\n/g;
            $dump[$_] = _html_quote($dump[$_]);
            $dump[$_] =~ s|\$VAR1|<span class=debugvar><b>$var[$_]</b></span>|g;
            $html .= $dump[$_];
        }
        $html .= "</pre>\n";
        return $html if $called eq 'debug_html';
        my $typed = content_typed();
        print_content_type();
        print $typed ? $html : "<!DOCTYPE html>$html";
    } else {
        my $txt = ($called eq 'debug_dlog') ? '' : "$called: $file line $line_n\n";
        for (0 .. $#dump) {
            $dump[$_] =~ s|\$VAR1|$var[$_]|g;
            $txt .= $dump[$_];
        }
        $txt =~ s/\s*$/\n/;
        return $txt if $called eq 'debug_text';

        if ($called eq 'debug_warn') {
            warn $txt;
        }
        elsif ($called eq 'debug_dlog') {
            require DLog;
            DLog->new->dlog($txt, {caller => 2});
        }
        else {
            print $txt;
        }
    }
    return @_[0..$#_];
}

sub debug      { &_what_is_this }
sub debug_warn { &_what_is_this }
sub debug_text { &_what_is_this }
sub debug_html { &_what_is_this }
sub debug_dlog { &_what_is_this }

sub debug_plain {
    require Data::Dumper;
    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Terse = 1;
    my $dump = join "\n", map {_dump($_)} @_;
    print $dump if !defined wantarray;
    return $dump;
}

sub content_typed {
    my $self = shift || __PACKAGE__->new;

    if (my $r = $self->apache_request) {
        return $r->bytes_sent;
    } else {
        return $ENV{'CONTENT_TYPED'} ? 1 : undef;
    }
}

sub print_content_type {
    my ($self, $type, $charset) = (@_ && ref $_[0]) ? @_ : (undef, @_);
    $self = __PACKAGE__->new if ! $self;

    if ($type) {
        die "Invalid type: $type" if $type !~ m|^[\w\-\.]+/[\w\-\.\+]+$|; # image/vid.x-foo
    } else {
        $type = 'text/html';
    }
    $type .= "; charset=$charset" if $charset && $charset =~ m|^[\w\-\.\:\+]+$|;

    if (my $r = $self->apache_request) {
        return if $r->bytes_sent;
        $r->content_type($type);
        $r->send_http_header if $self->is_mod_perl_1;
    } else {
        if (! $ENV{'CONTENT_TYPED'}) {
            print "Content-Type: $type\r\n\r\n";
            $ENV{'CONTENT_TYPED'} = '';
        }
        $ENV{'CONTENT_TYPED'} .= sprintf("%s, %d\n", (caller)[1,2]);
    }
}

sub _html_quote {
    my $value = shift;
    return '' if ! defined $value;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    return $value;
}

sub caller_trace {
    eval { require 5.8.0 } || return ['Caller trace requires perl 5.8'];
    require Carp::Heavy;
    local $Carp::MaxArgNums = 5;
    local $Carp::MaxArgLen  = 20;
    my $i    = shift || 0;
    my $skip = shift || {};
    my @i = ();
    my $max1 = 0;
    my $max2 = 0;
    my $max3 = 0;
    while (my %i = Carp::caller_info(++$i)) {
        next if $skip->{$i{file}};
        $i{sub_name} =~ s/\((.*)\)$//;
        $i{args} = $i{has_args} ? $1 : "";
        $i{sub_name} =~ s/^.*?([^:]+)$/$1/;
        $i{file} =~ s/$QR_TRACE1/$1/ || $i{file} =~ s/$QR_TRACE2/$1/;
        $max1 = length($i{sub_name}) if length($i{sub_name}) > $max1;
        $max2 = length($i{file})     if length($i{file})     > $max2;
        $max3 = length($i{line})     if length($i{line})     > $max3;
        push @i, \%i;
    }
    foreach my $ref (@i) {
        $ref = sprintf("%-${max1}s at %-${max2}s line %${max3}s", $ref->{sub_name}, $ref->{file}, $ref->{line})
            . ($ref->{args} ? " ($ref->{args})" : "");
    }
    return \@i;
}

###----------------------------------------------------------------###

1;

__END__

=head1 SYNOPSIS

  use Data::Debug; # auto imports debug, debug_warn
  use Data::Debug qw(debug debug_text caller_trace);

  my $hash = {
      foo => ['a', 'b', 'Foo','a', 'b', 'Foo','a', 'b', 'Foo','a'],
  };

  debug $hash; # or debug_warn $hash;

  debug;

  debug "hi";

  debug $hash, "hi", $hash;

  debug \@INC; # print to STDOUT, or format for web if $ENV{REQUEST_METHOD}

  debug_warn \@INC;  # same as debug but to STDOUT

  print FOO debug_text \@INC; # same as debug but return dump

  # ALSO #

  use Data::Debug qw(debug);

  debug; # same as debug

=head1 DESCRIPTION

Uses the base Data::Dumper of the distribution and gives it nicer formatting - and
allows for calling just about anytime during execution.

Calling Data::Debug::set_deparse() will allow for dumped output of subroutines
if available.

   perl -e 'use Data::Debug;  debug "foo", [1..10];'

See also L<Data::Dumper>.

Setting any of the Data::Dumper globals will alter the output.

=head1 SUBROUTINES

=over 4

=item C<debug>

Prints out pretty output to STDOUT.  Formatted for the web if on the web.

It also returns the items called for it so that it can be used inline.

   my $foo = debug [2,3]; # foo will contain [2,3]

=item C<debug_dlog>

Sends the debug output to the dlog system.

=item C<debug_warn>

Prints to STDERR.  If during a web request and /var/log/httpd/debug_log exists
the output will go there rather than to error_log.  (But in that case you
really should be using debug_dlog.

=item C<debug_text>

Return the text as a scalar.

=item C<debug_plain>

Return a plainer string as a scalar.  This basically just avoids the attempt to
get variable names and line numbers and such.

If passed multiple values, each value is joined by a newline.  This has the
effect of placing an empty line between each one since each dump ends in a
newline already.

If called in void context, it displays the result on the default filehandle
(usually STDOUT).

=item C<caller_trace>

Caller trace returned as an arrayref.  Suitable for use like "debug caller_trace".
This does require at least perl 5.8.0's Carp.

=back

=head1 AUTHORS

Originally this was borrowed from CGI::Ex (written by Paul Seamons).  It
has since had many customizations and optimizations by various people.

=cut
