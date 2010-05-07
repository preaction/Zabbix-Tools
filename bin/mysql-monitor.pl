#!/usr/bin/env perl

# Report the status of various mysql stuff

use Getopt::Long;
use DBI;
use Pod::Usage;

my ( $user, $pass, $repair, $threshold, $kill );

GetOptions(
    'h|help'            => sub { print pod2usage( verbose => 1 ) && exit 0 },
    'man'               => sub { print pod2usage( verbose => 2 ) && exit 0 },
    'u:s'               => \$user,
    'p:s'               => \$pass,
    'repair'            => \$repair,
    't|threshold:i'     => \$threshold,
    'kill'              => \$kill,
);

my $command = $ARGV[0];
pod2usage( msg => "Must specify a command" )        unless $command;
pod2usage( msg => "Invalid command '$command'" )    unless main->can( $command );

my $dbh = DBI->connect( 'dbi:mysql:', $user, $pass, { RaiseError => 1 } ) 
    or die $DBI::errstr;

print main->can( $command )->();

sub check_tables {
    my $exit    = 0; # Default to okay

    # Get all databases
    my $dbs = $dbh->selectcol_arrayref( "SHOW DATABASES" );

    # Get all tables in these databases
    my @tables  = ();
    DB: for my $db ( @$dbs ) {
        next DB if $db eq 'mysql'
                || $db eq 'information_schema';
        my $quoted_db = $dbh->quote_identifier( $db );
        push @tables, 
            map { $quoted_db . "." . $dbh->quote_identifier( $_ ) }
            @{ $dbh->selectcol_arrayref( "SHOW TABLES IN $quoted_db" ) }
            ;
    }

    my $checks = $dbh->selectall_arrayref( "CHECK TABLE " . join( ", ", @tables ) );
    for my $check ( @$checks ) {
        my ( $table, undef, $status, $text ) = @$check;
        if ( lc $status eq "error" ) {
            my $corrupt = 1;
            if ( $repair ) {
                # Try to repair
                my $repair = $dbh->selectall_arrayref( "REPAIR TABLE " . $table );
                my $repair_status   = $repair->[2];
                my $repair_text     = $repair->[3];
                if ( lc $repair_text eq 'ok' ) {
                    # Repair success!
                    $corrupt = 0;
                }
            }
            if ( $corrupt ) {
                warn sprintf "%s is corrupt: %s\n", $table, $text;
                $exit++;
            }
        }
    }

    return $exit;
}

sub long_query {
    my $exit    = 0; # Default to okay
    my $proc    = $dbh->selectall_arrayref( "SHOW FULL PROCESSLIST" );

    for my $p ( @$proc ) {
        my $p_id    = $p->[0];
        my $p_time  = $p->[5];
        my $p_query = $p->[7];
        if ( $p_time > $threshold ) {
            # Try to kill the query
            warn sprintf "Query over time threshold (ran for %s) '%s'\n", 
                $p_time, $p_query
                ;
            # Do not kill "REPAIR TABLE" or "OPTIMIZE TABLE" will result in a 
            # corrupt table
            # http://dev.mysql.com/doc/refman/5.1/en/kill.html
            if ( $kill && lc $p_query !~ /^repair table/ 
                && lc $p_query !~ /^optimize table/ ) {
                $dbh->do( "KILL QUERY " . $dbh->quote( $p_id ) );
            }
            else {
                $exit++;
            }
        }
    }

    return $exit;
}



__END__

=head1 NAME

mysql-monitor.pl -- Report the status of various mysql stuff

=head1 USAGE

 mysql-monitor.pl [-u user] [-p password] <command> [arguments]

 mysql-monitor.pl check_tables [--repair]

 mysql-monitor.pl long_query --threshold=<seconds> [--kill]

=head1 COMMANDS

=head2 check_tables

Check the tables, prints any that need repair. Exits with the number of
tables that are corrupt.

=head3 Arguments

=over 4

=item --repair

Try to automatically repair the table, only report if failed

=back

=head2 long_query

Check for long-running queries and kill if desired.

=head3 Arguments

=over 4

=item --threshold

Number of seconds before a query should be killed.

=item --kill

If set, try to kill the query automatically. Will not kill queries that
will result in corrupted tables (REPAIR TABLE and OPTIMIZE TABLE).

=back

=head1 ZABBIX

To use this in zabbix, you must edit your zabbix_agentd.conf to add:

 UserParameter=mysql.monitor[*],mysql-monitor.pl -u<user> -p<password> $1 $2

Then you can configure new items like so:

 mysql.monitor[check_tables,--repair]

Commands will return 0 if everything is okay, so if the result is >0, there 
is a problem that needs to be looked into.

=head1 AUTHOR

Copyright 2010 Doug Bell (doug@plainblack.com)

