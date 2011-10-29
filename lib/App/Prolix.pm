use strict;
use warnings;

package App::Prolix;
# ABSTRACT: trim chatty command outputs

use Moose;
use String::ShellQuote ();

use v5.10;

{
package App::Prolix::ConfigFileRole;

use Moose::Role;
with 'MooseX::ConfigFromFile';
use JSON 2.0;

sub get_config_from_file {
    my($file) = @_;
    open my $fh, "<", $file or confess "open: $file: $!";
    local $/;
    my $json = <$fh>;
    close $fh or die "close: $file: $!";
    return JSON->new->relaxed->utf8->decode($json);
}

}

use IPC::Run ();
use Term::ReadKey ();
use Term::ReadLine;
use Try::Tiny;
use IO::File;

use App::Prolix::MooseHelpers;

with 'App::Prolix::ConfigFileRole';
with 'MooseX::Getopt';

# Flags affecting overall run style.
has_option 'verbose' => (isa => 'Bool', cmd_aliases => 'v',
    documentation => 'Prints extra information.');
has_option 'pipe' => (isa => 'Bool', cmd_aliases => 'p',
    documentation => 'Reads from stdin instead of interactively.');
has_option 'log' => (isa => 'Str', cmd_aliases => 'l');

# Flags affecting filtering.
has_option 'ignore_re' => (isa => 'ArrayRef', cmd_aliases => 'r',
    'default' => sub { [] },
    documentation => 'Ignore lines matching this regexp.');
has_option 'ignore_line' => (isa => 'ArrayRef', cmd_aliases => 'i',
    'default' => sub { [] },
    documentation => 'Ignore lines exactly matching this.');
has_option 'ignore_substring' => (isa => 'ArrayRef', cmd_aliases => 'b',
    'default' => sub { [] },
    documentation => 'Ignore lines containing this substring.');
has_option 'snippet' => (isa => 'ArrayRef', cmd_aliases => 's',
    'default' => sub { [] },
    documentation => 'Snip lines. Use s/search_re/replace/ syntax.');

# Internal attributes (leading _ means not GetOpt).
has_rw '_cmd' => (isa => 'ArrayRef', 'default' => sub { [] });

has_rw '_out' => (isa => 'ScalarRef[Str]', default => \&_strref);
has_rw '_err' => (isa => 'ScalarRef[Str]', default => \&_strref);

has_rw '_log' => (isa => 'FileHandle');
has_rw '_term' => (isa => 'Term::ReadLine');
has_rw '_snippet' => (isa => 'ArrayRef', 'default' => sub { [] });

has_counter '_suppressed';
has_counter '_output_lines';

sub run {
    my($self) = @_;
    
    if ($self->verbose) {
        $SIG{USR1} = \&_dump_stack;
    }

    $self->open_log;
    $self->import_snippet($_) for @{$self->snippet};

    if ($self->need_pipe) {
        $self->run_pipe;
    } else {
        $self->run_spawn;
    }

    if ($self->verbose) {
        say "Done. " . $self->stats;
    }

    $self->close_log;
}

sub need_pipe {
    my($self) = @_;
    return $self->pipe || @{$self->_cmd} == 0;
}

sub open_log {
    my($self) = @_;

    return if not defined $self->log;

    my $now = $self->now_stamp;
    my $filename = $self->log;
    $filename = ($self->need_pipe ? 'prolix.%d' : ($self->_cmd->[0] . '.%d')) if
        $filename eq 'auto';
    $filename = File::Spec->catfile(File::Spec->tmpdir, $filename) if
        $filename !~ m{[/\\]};  # Put in /tmp/ or similar unless we got a path.
    $filename =~ s/%d/$now/;  # TODO(gaal): implement incrementing %n.

    say "Logging output to $filename" if $self->verbose;

    my $fh = IO::File->new($filename, 'w') or die "open: $filename: $!";
    $self->_log($fh);
}

sub close_log {
    my($self) = @_;
    $self->_log->close if $self->_log;
}

# Like: (DateTime->new->iso8601 =~ s/[-:]//g), but I didn't want to add
# a big dependency.
sub now_stamp {
    my($self) = @_;

    my(@t) = localtime;  # Should this be gmtime?
    return sprintf "%4d%02d%02dT%02d%02d",
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];  # Ahh, UNIX.
}

sub stats {
    my($self) = @_;
    return "Suppressed " . $self->_suppressed . "/" .
        $self->_output_lines . " lines.";
}

# returns a fresh reference to a string.
sub _strref {
    return \(my $throwaway = '');
}

sub run_pipe {
    my($self) = @_;

    say "Running in pipe mode" if $self->verbose;

    while (<STDIN>) {
        chomp;
        $self->on_out($_)
    }
}

sub run_spawn {
    my($self) = @_;
    say "Running: " .
        String::ShellQuote::shell_quote_best_effort(@{$self->_cmd})
        if $self->verbose;

    Term::ReadKey::ReadMode('noecho');
    END { Term::ReadKey::ReadMode('normal'); }

    $self->_term(Term::ReadLine->new('prolix'));
    my $attribs = $self->_term->Attribs;
    $attribs->{completion_entry_function} =
        $attribs->{list_completion_function};
    $attribs->{completion_word} = [qw(
        help
        ignore_line
        ignore_re
        ignore_substr
        pats
        quit
        snippet
        stats
    )];

    my $t = IPC::Run::timer(0.3);
    my $ipc = IPC::Run::start $self->_cmd,
        \undef,  # no stdin
        $self->_out,
        $self->_err,
        $t;
    $t->start;
    my $pumping = 1;
    while ($pumping && $ipc->pump) {
        $self->consume;
        try {
            $self->try_user_input;
        } catch {
            when (/prolix-quit/) {
                $ipc->kill_kill;
                $pumping = 0;
            }
            default { die $_ }
        };
        $t->start(0.3);
    }
    $t->reset;
    $ipc->finish;
    $self->consume_final;

    Term::ReadKey::ReadMode('normal');
}

sub _dump_stack {
    print Carp::longmess("************");
    $SIG{USR1} = \&_dump_stack;
}

sub try_user_input {
    my($self) = @_;
    return if not defined Term::ReadKey::ReadKey(-1);

    # Enter interactive prompt mode. We hope this will be brief, and
    # IPC::Run can buffer our watched command in the meanhwile.

    Term::ReadKey::ReadMode('normal');
    while (my $cmd = $self->_term->readline("prolix>")) {
        $self->_term->addhistory($cmd);
        $self->handle_user_input($cmd);
    }
    Term::ReadKey::ReadMode('restore');  # into noecho, we hope!
}

sub handle_user_input {
    my($self, $cmd) = @_;
    given ($cmd) {
        when (/^\s*stack\s*$/) { _dump_stack }
        when (/^\s*bufs\s*$/) { $self->dump_bufs }
        when (/^\s*q|quit\s*$/) { die "prolix-quit\n" }
        when (/^\s*h|help\s*$/) { $self->help_interactive }
        when (/^\s*pats\s*$/) { $self->dump_pats }
        when (/^\s*stats\s*$/) { say $self->stats }
        when (/^\s*(ignore_(?:line|re|substring))\s+(.*)/) {
            my($ignore_type, $pat) = ($1, $2);
            push @{ $self->$ignore_type }, $pat;
        }
        when (/^\s*snippet\s(.*)/) {
            push @{ $self->snippet }, $1;
            $self->import_snippet($1);
        }
        default { say "unknown command. try 'help'." }
    }
}

sub import_snippet {
    my($self, $snippet) = @_;

    # $snippet =~ s/^s(.)(.*)(.)$/$2/ or die<<".";  # support flex delims?
    # TODO(gaal): use Data::Munge's replace here to support backrefs.
    my ($search, $replace) = $snippet =~ m,^s/(.*)/(.*)/$, or die<<".";
*** Usage: snippet s/find_re/replace/

    Backreferences are not yet supported.
.
    push @{ $self->_snippet }, sub {
        my($line) = @_;
        $line =~ s/$search/$replace/;
        return $line;
    };
}

sub dump_pats {
    my($self) = @_;

    say "* ignored lines";
    say for @{ $self->ignore_line };
    say "* ignored patterns";
    say for @{ $self->ignore_re };
    say "* ignored substrings";
    say for @{ $self->ignore_substring };
    say "* snippets";
    say for @{ $self->snippet };
}

sub help_interactive {
    my($self) = @_;

    say <<"EOF";
ignore_line      - add a full match to ignore
ignore_re        - add an ignore pattern, e.g. ^(FINE|DEBUG)
ignore_substring - add a partial match to ignore
pats             - list ignore patterns
quit             - terminate running program
stats            - print stats
snippet          - add a snippet expression, e.g. s/^(INFO|WARNING|ERROR) //

To keep going, just enter an empty line.
EOF
}

sub dump_bufs {
    my($self) = @_;
    warn "Out: [" . ${$self->_out} . "]\n" .
        "Err: [" . ${$self->_err} . "]\n";
}

sub consume {
    my($self) = @_;

    while (${$self->_out} =~ s/^(.*?)\n//) {
        $self->on_out($1);
    }
    while (${$self->_err} =~ s/^(.*?)\n//) {
        $self->on_err($1);
    }
}

# like consume, but does not require a trailing newline.
sub consume_final {
    my($self) = @_;

    if (length ${$self->_out} > 0) {
        $self->on_out($_) for split /\n/, ${$self->_out};
    }
    if (length ${$self->_err} > 0) {
        $self->on_err($_) for split /\n/, ${$self->_err};
    }
}

sub snip_line {
    my($self, $line) = @_;

    $line = $_->($line) for @{$self->_snippet};

    return $line;
}

sub ok_line {
    my($self, $line) = @_;

    for my $exact (@{$self->ignore_line}) {
        if ($line eq $exact) {
            return;
        }
    }
    for my $sub (@{$self->ignore_substring}) {
        if (index($line, $sub) >= 0) {
            return;
        }
    }
    for my $pat (@{$self->ignore_re}) {
        if ($line =~ $pat) {
            return;
        }
    }
    return 1;
}

# One day, we might paint this in a different color or something.
sub on_err { goto &on_out }

sub on_out {
    my($self, $line) = @_;
    
    $self->inc__output_lines;
    if ($self->ok_line($line)) {
        $line = $self->snip_line($line);

        say $line;
        if ($self->_log) {
            $self->_log->print("$line\n");
        }
    } else {
        $self->inc__suppressed;
    }
}

6;
