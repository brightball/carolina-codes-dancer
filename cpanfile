requires 'Dancer2',       '>= 2.1.0';
requires 'Plack',         '>= 1.0054';
requires 'HTTP::Message',  '>= 7.04';
requires 'HTTP::Tiny',     '>= 0.096';
requires 'DBI',            '>= 1.652';
requires 'DBD::Pg',        '>= 3.21.2';
requires 'JSON',           '>= 4.11';
requires 'URI',            '>= 5.36';
requires 'JSON::MaybeXS',  '>= 1.004008';

on 'develop' => sub {
    requires 'Perl::Critic', '>= 1.156';
    requires 'Perl::Tidy',   '>= 20260826';
    requires 'CPAN::Audit',  '>= 20260622.001';
};
