#!/usr/bin/perl
###############################################################################
#
#    app_convert.pl
#    
#    Convert a machine generated peak file into a format ready for the app_csv2epi.pl script.
#
#    Copyright (C) 2011 Michael Imelfort and Paul Dennis
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################

#pragmas
use strict;
use warnings;

#core Perl modules
use Getopt::Long;

#CPAN modules

#locally-written modules

BEGIN {
    select(STDERR);
    $| = 1;
    select(STDOUT);
    $| = 1;
}

# get input params and print copyright
printAtStart();
my $options = checkParams();

######################################################################
# CODE HERE
######################################################################
my $global_output_filename = "converted.csv";
if(exists $options->{'out'}) { $global_output_filename = $options->{'out'}; }

# Dilutions!
my $global_dilution_multiplier = 1;
if(exists($options->{'dilution'})) { $global_dilution_multiplier = $options->{'dilution'}; }

# allowable primer lengths
my %global_prim_len_hash = ();
$global_prim_len_hash{'pyroL803Fmix'} = 688;
$global_prim_len_hash{'pyroL926F'} = 565;
$global_prim_len_hash{'1114'} = 500;

# tollerances
my $global_tolerance = 0.1;
print $options->{'tolerance'}."\n";
if(exists($options->{'tolerance'})) { $global_tolerance = $options->{'tolerance'}; }
my %global_prim_len_upper_hash = ();
my %global_prim_len_lower_hash = ();
foreach my $primer (keys %global_prim_len_hash)
{
    $global_prim_len_upper_hash{$primer} = int($global_prim_len_hash{$primer} * (1 + $global_tolerance));
    $global_prim_len_lower_hash{$primer} = int($global_prim_len_hash{$primer} * (1 - $global_tolerance));
}

# used primer lengths
my %global_well_primer_hash = ();

# concentrations
my %global_well_conc_hash = ();

# concentrations
my %global_well_len_hash = ();

# open the pdbe file
open my $pdb_fh, "<", $options->{'pdbe'} or die $!;
while(<$pdb_fh>)
{
    chomp $_;
    my @line_fields = split /,/, $_;
    if(exists($global_prim_len_hash{$line_fields[1]}))
    {
        $global_well_primer_hash{$line_fields[0]} = $line_fields[1];
    }
    else
    {
        die "Unknown primer type: $line_fields[1]\n";
    }
}
close $pdb_fh;

# open the input file
open my $in_fh, "<", $options->{'caliper'} or die "Cannot open input file $!";
# kill the header
<$in_fh>;
# read each line
while(<$in_fh>)
{
    chomp $_;
    my @line_fields = split /,/, $_;
    next if($line_fields[1] =~ /^Ladd/);
    next if($line_fields[2] eq "");
    
    my $well = $line_fields[1];
    if(exists($global_well_primer_hash{$well}))
    {
        my $primer = $global_well_primer_hash{$well};
        my $rec_length = int($line_fields[2]);
        
        # check to see if everything is within bounds
        if($rec_length > $global_prim_len_lower_hash{$primer})
        {
            if($rec_length < $global_prim_len_upper_hash{$primer})
            {
                # check to see we're only adding this guy once
                if(exists $global_well_conc_hash{$well})
                {
                    print "WARNING: Two possible concentration values for well $well.\n";
                    print "\tLast time:\t{$global_well_len_hash{$well} AT $global_well_conc_hash{$well}}\n";
                    print "\tThis time:\t{$line_fields[2] AT $line_fields[3], primer: $primer, length: $global_prim_len_hash{$primer}\n";
                    if($line_fields[3] > $global_well_conc_hash{$well})
                    {
                        $global_well_conc_hash{$well} = $line_fields[3];
                        $global_well_len_hash{$well} = $line_fields[2];                      
                    }
                    print "\tKeeping:\t{$global_well_len_hash{$well} AT $global_well_conc_hash{$well}}\n";
                }
                else
                {
                    $global_well_conc_hash{$well} = $line_fields[3];
                    $global_well_len_hash{$well} = $line_fields[2];
                }
            }
        }
    }
}
close $in_fh;

# open the output file
open my $out_fh, ">", $global_output_filename or die "Cannot open output file $!";
my @well_chars = ('A', 'B', 'C', 'D', 'E', 'F', 'G', 'H');
my @well_nums = (1,2,3,4,5,6,7,8,9,10,11,12);
foreach my $wc (@well_chars)
{
    foreach my $wn (@well_nums)
    {
        my $location = $wc.$wn;
        if(exists $global_well_conc_hash{$location})
        {
            print $out_fh "$location,".($global_well_conc_hash{$location}*$global_dilution_multiplier).",$global_well_primer_hash{$location}\n";
        }
        else
        {
            print "WARNING: Empty well at: $location\n";
        }
    }
}
close $out_fh;

print "Conversion printed to: $global_output_filename\n";
print "All done...\n";
######################################################################
# CUSTOM SUBS
######################################################################


######################################################################
# TEMPLATE SUBS
######################################################################
sub checkParams {
    my @standard_options = ( "help|h+", "caliper|c:s", "pdbe|p:s", "out|o:s", "dilution|d:f", "tolerance|t:f" );
    my %options;

    # Add any other command line options, and the code to handle them
    # 
    GetOptions( \%options, @standard_options );

    # if no arguments supplied print the usage and exit
    #
    exec("pod2usage $0") if (0 == (keys (%options) ));

    # If the -help option is set, print the usage and exit
    #
    exec("pod2usage $0") if $options{'help'};

    # Compulsosy items
    if(!exists $options{'caliper'} ) { print "**ERROR: You need to supply an input file produced by caliper\n"; exec("pod2usage $0"); }
    if(!exists $options{'pdbe'} ) { print "**ERROR: You need to supply an EPI conversion file produced by PyroDB\n"; exec("pod2usage $0"); }
    #if(!exists $options{''} ) { print "**ERROR: \n"; exec("pod2usage $0"); }
    
    return \%options;
}

sub printAtStart {
print<<"EOF";
---------------------------------------------------------------- 
 $0
 Copyright (C) 2011 Michael Imelfort and Paul Dennis
    
 This program comes with ABSOLUTELY NO WARRANTY;
 This is free software, and you are welcome to redistribute it
 under certain conditions: See the source for more details.
---------------------------------------------------------------- 
EOF
}

__DATA__

=head1 NAME

    app_convert.pl

=head1 COPYRIGHT

   copyright (C) 2011 Michael Imelfort and Paul Dennis

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 DESCRIPTION

   Convert a caliper produced peaks csv file to a format suitable for app_csv2epi.pl

=head1 SYNOPSIS

    app_convert.pl -in CSV [-out CSV] [-help|h]
   
    Convert a caliper produced peaks csv file to a format suitable for app_csv2epi.pl
 
    -caliper|c CSV               Caliper generated csv file to convert
    -pdbe|p CSV                  Epi conversion file from PyroDB
    [-dilution|d FLOAT]          Amount samples were diluted by before being run through caliper (Multiply by this number [default: 1])
    [-tolerance|t FLOAT]         Tolerance above and below reported primer length [default: 0.1 (10%)]
    [-out|o CSV]                 Optional output name [default: converted.csv]
    [-help -h]                   Displays basic usage information

=cut
