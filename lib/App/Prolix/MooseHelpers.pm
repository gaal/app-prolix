package App::Prolix::MooseHelpers;
# ABSTRACT: Moose helpers for App::Prolix

use Moose ();
use Moose::Exporter;
use warnings;

Moose::Exporter->setup_import_methods(
    with_meta => [ 'has_counter', 'has_rw', 'has_option' ]);

sub has_rw {
    my ($meta, $name, %options) = @_;
    $meta->add_attribute(
        $name,
        is => 'rw',
        %options
    );
}

sub has_option {
    my ($meta, $name, %options) = @_;
    $meta->add_attribute(
        $name,
        is => 'rw',
        metaclass => 'Getopt',
        %options
    );
}

sub has_counter {
    my ($meta, $name, %options) = @_;
    $meta->add_attribute(
        $name,
        traits => ['Counter'],
        is => 'ro',
        isa     => 'Num',
        default => 0,
        handles => {
            ('inc_' . $name)   => 'inc',
            ('dec_' . $name)   => 'dec',
            ('reset_' . $name) => 'reset',
        },
        %options
    );
}

1;

