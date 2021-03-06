#!/usr/bin/perl
###############################################################################
#
#    app_do_QA.pl
#    
#    Uses qiime scripts + acacia to do mid splitting and denoising
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
use Carp;

#CPAN modules
use File::Basename;
use File::Spec;
use File::Copy;
use File::Temp qw(tempfile);
use List::Util qw(min max);
use Statistics::R;

#locally-written modules
#load the pretty names for the fields
use AppConfig;
use AppCommon;

BEGIN {
    select(STDERR);
    $| = 1;
    select(STDOUT);
    $| = 1;
}

########################################################################
# Globals
########################################################################

#
# Here we keep the default acacia config hash
#
our %acacia_config_hash = (
     ANY_DIFF_SIGNIFICANT_FOR_TWO_SEQS => "TRUE",
     AVG_QUALITY_CUTOFF => 30,
     ERROR_MODEL => "Balzer",
     FASTA => "TRUE",
     FASTA_LOCATION => "good.fasta",
     FASTQ => "FALSE",
     FASTQ_LOCATION => "null",
     FILTER_N_BEFORE_POS => 250,
     FLOW_KEY => "TCAG",
     MAXIMUM_MANHATTAN_DISTANCE => 13,
     MAX_RECURSE_DEPTH => 2,
     MAX_STD_DEV_LENGTH => 2,
     MID_FILE => ".dummmy",
     MID_OPTION => "NO_MID",
     MIN_FLOW_TRUNCATION => 150,
     MIN_READ_REP_BEFORE_TRUNCATION => 0.0,
     OUTPUT_DIR => "denoised_acacia",
     OUTPUT_PREFIX => "acacia_out",
     QUAL_LOCATION => "null",
     REPRESENTATIVE_SEQUENCE => "Mode",
     SIGNIFICANCE_LEVEL => -9,
     SPLIT_ON_MID => "FALSE",
     TRIM_TO_LENGTH => 250,
     TRUNCATE_READ_TO_FLOW => ""
);

######################################################################
# Main
######################################################################

my $options = checkParams();

chdir($options->{'d'}) or die "No such directory: " . $options->{'d'} . "\n";
printAtStart();

my $config_hash;
my $extra_param_hash = {};

open(my $fh, "config.txt");
while (my $line = <$fh>) {
    if ($line =~ /^(\s*)#/) {next};
    if ($line =~ /^(.*)=(.*)$/) {
        $config_hash->{$1} = $2;
    }
}
close($fh);

if (! defined ($config_hash->{PIPELINE})) {
    $config_hash->{PIPELINE} = 'CD_HIT_OTU';
}

if (defined ($config_hash->{DB})) {
    setup_db_paths($extra_param_hash, $config_hash->{DB});
} else {
    setup_db_paths($extra_param_hash);
}

my @pipeline = split /,/, $config_hash->{PIPELINE};

if ($pipeline[0] =~ /^(\s*)CD_HIT_OTU(\s*)$/) {
    cd_hit_otu_pipeline($config_hash, $extra_param_hash);
} elsif ($pipeline[0] =~ /^(\s*)QIIME(\s*)$/) {
    qiime_pipeline($config_hash, $extra_param_hash);
} else {
    print "Unknown pipeline: " . $pipeline[0] . "\n";
}

######################################################################
# Globals
######################################################################


######################################################################
# Pipelines
######################################################################


######################################################################
# QIIME Standard Pipeline
#
# This is the pipeline for standard analysis using QIIME.
#
######################################################################

sub qiime_pipeline {
    
    my ($config_hash, $extra_param_hash) = @_;
    my $pipeline_modifiers = get_parameter_modifiers($config_hash->{PIPELINE});
    
    my $processing_dir = 'processing';
    my $results_dir = 'results';
    
    mkdir($processing_dir) if (! -e $processing_dir);
    mkdir($results_dir) if (! -e $results_dir);
    
    if (! exists ($config_hash->{TRIM_LENGTH})) {
        $config_hash->{TRIM_LENGTH} = 250;
    }
    
    my @starting_samples = split /,/, $config_hash->{SAMPLES};
    
    my %sample_counts;
    if (-e "sample_counts.txt") {
        %sample_counts = %{get_read_counts_from_sample_counts("sample_counts.txt")}
    }
    
    my %sample_for_analysis_hash;
       
    my $need_to_reanalyse = 0;
    if (! -e "sample_exclusion.txt") {
        $config_hash->{SAMPLES_FOR_ANALYSIS} = $config_hash->{SAMPLES};
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        %sample_for_analysis_hash = map {$_ => 1} @starting_samples;
        
    } else {
        my @previous_analysis = split /,/, $config_hash->{SAMPLES_FOR_ANALYSIS};
        my %samples_to_use = %{read_sample_exclusion("sample_exclusion.txt")};
        my @sample_for_analysis_array;
        
        foreach my $sample_name (@starting_samples) {
            if ((defined $samples_to_use{$sample_name}) && $samples_to_use{$sample_name}) {
                push @sample_for_analysis_array, $sample_name;
            }
        }
        
        $config_hash->{SAMPLES_FOR_ANALYSIS} = join ",", @sample_for_analysis_array;
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
        %sample_for_analysis_hash = map {$_ => 1} @sample_for_analysis_array;
        foreach my $sample_name (@previous_analysis) {
            if ((! exists ($sample_for_analysis_hash{$sample_name})) && ($sample_counts{$sample_name} != 0)) {
                $need_to_reanalyse = 1;
                last;
            }
        }
    }
        
    # If we are running for the first time, or if sample_exclusions.txt has been modified,
    # reset the pipeline. 
    
    if (($need_to_reanalyse) || (! exists($config_hash->{PIPELINE_STAGE}))) {
        $config_hash->{PIPELINE_STAGE} = "PREAMBLE";
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    }
        
    if ($config_hash->{PIPELINE_STAGE} eq "PREAMBLE") {
        
    # (Re)create the QIIME mapping file, taking sample_exclusions.txt into account.
        
          my @app_config_files = split /,/, $config_hash->{ORIGINAL_CONFIG_FILES};
        
        my %sample_to_analyse = map {$_ => 1} split /,/, $config_hash->{SAMPLES_FOR_ANALYSIS};
        
        if (! -e "split_libraries") {
            mkdir "split_libraries";
        }
        
       
        foreach my $config_file (@app_config_files) {
            my $config_filename = basename($config_file);
            
            my ($sample_array, $config_array) =
                parse_app_config_files("original_app_configs/$config_filename");
                     
            my $new_sample_array;
            foreach my $sample_array_ptr (@{$sample_array}) {
                if (exists $sample_to_analyse{$sample_array_ptr->[0]}) {
                    push @{$new_sample_array}, $sample_array_ptr;
                }
            }
            
            my $prefix;
            if ($config_filename =~ /app_(.*).config$/) {
                $prefix = $1;
            } else {
                die "Copied config file doesn't match name.\n";
            }
            
            my $qiime_mapping_file = $prefix . "_qiime_mapping.txt";
            create_qiime_mapping_file($qiime_mapping_file, $new_sample_array);
            
            my $params = [{-M => 1,
                        -q => "raw_files/$prefix.qual",
                        -f => "raw_files/$prefix.fasta",
                        -d => '',
                        -m => $qiime_mapping_file,
                        -b => 'variable_length',
                        -a => 2,
                        -H => 10,
                        -o => "split_libraries/$prefix",
                        -l => $config_hash->{TRIM_LENGTH}}];
            
            if (exists($pipeline_modifiers->{STRICT_FILTERING})) {
                
                $params->{'-s'} = 25;
                $params->{'-w'} = 10;
                
            } elsif (exists($pipeline_modifiers->{MEDIUM_FILTERING})) {
                
                $params->{'-s'} = 20;
                $params->{'-w'} = 10;
                
            }
            splitLibraries($params);
        }
        
        
        open(my $out_fa, ">split_libraries/out.fasta");
        open(my $out_qual, ">split_libraries/out.qual");
        
        my $fasta_read_count = 0;
        my $qual_read_count = 0;
        opendir(my $dh, "split_libraries");        
        while (my $dir = readdir($dh)) {
            if (-d "split_libraries/$dir") {
                if (! -e "split_libraries/$dir/seqs.fna") {
                    next;
                }
                open(my $in_fa, "split_libraries/$dir/seqs.fna");
                while (my $line = <$in_fa>) {
                    if ($line =~ /(^>[^\s]*)_[0-9]*(\s.*$)/) {
                        $fasta_read_count++;
                        print {$out_fa} $1 . "_" . $fasta_read_count . $2 . "\n";
                    } else {
                        print {$out_fa} $line;
                    }
                }
                close($in_fa);
                open(my $in_qual, "split_libraries/$dir/seqs_filtered.qual");
                while (my $line = <$in_qual>) {
                    if ($line =~ /(^>[^\s]*)_[0-9]*(\s.*$)/) {
                        $qual_read_count++;
                        print {$out_qual} $1 . "_" . $qual_read_count . $2 . "\n";
                    } else {
                        print {$out_qual} $line; 
                    }
                }
                close($in_qual);
            }
        }
        
        closedir($dh);
        close($out_fa);
        close($out_qual);
        
        if (-z 'seqs.fna') {
            croak "ERROR: No sequences in seqs.fna (no sequences successfully demultiplexed after split_libraries.py).\n" .
            "Check the config file that the barcode/primer sequences are correct.\n"
        }
        
        $config_hash->{PIPELINE_STAGE} = "UCLUST";
        
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "UCLUST") {
    
        my $params = [{'-uchime_ref' => 'split_libraries/out.fasta'},
                 {'-db' => $QIIME_TAX_blast_file,
                  '-strand' => 'both',
                  '-threads' => 10,
                  '-nonchimeras' => 'good.fasta',
                  '-chimeras' => 'bad.fasta'}];
                  
        uclustRemoveChimeras($params);
        
        $config_hash->{PIPELINE_STAGE} = "ACACIA";
        
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    }
    
    my $fasta_output_file = 'good.fasta';
    
    if ($config_hash->{PIPELINE_STAGE} eq "ACACIA") {
        
        if (! exists($pipeline_modifiers->{NO_ACACIA})) {
        
            $acacia_config_hash{TRIM_TO_LENGTH} = $config_hash->{TRIM_LENGTH};
        
            my $config_file = create_acacia_config_file(\%acacia_config_hash);
            
            my $params_array = [["-XX:+UseConcMarkSweepGC",
                                 "-Xmx100G"],
                                 {-jar => '$ACACIA'},
                                 {-c => $config_file}];
            
            mkdir('denoised_acacia');
            
            if (run_acacia($params_array)) {
                die "Acacia failed.\n";
            };
            
            unlink($config_file);
            
            $fasta_output_file = "denoised_acacia/acacia_out_all_tags.seqOut";
        
        }
    
        $config_hash->{PIPELINE_STAGE} = "PICK_OTUS";
    
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "PICK_OTUS") {
    
        print "Picking OTUs for non normalised data set...\n";
        checkAndRunCommand("pick_otus.py", [{-i => $fasta_output_file,
                                             -s => 0.97,
                                             -o => "$processing_dir/uclust_picked_otus"}], DIE_ON_FAILURE);
        
        $config_hash->{PIPELINE_STAGE} = "REP_SET";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    }
    
    my @possible_otu_files = glob("$processing_dir/uclust_picked_otus/*_otus.txt");
    if (scalar @possible_otu_files != 1) {
        if (scalar @possible_otu_files) {
            die "Too many possible uclust otu files.\n";
        } else {
            die "No OTU files found.\n";
        }
    }
   
    if ($config_hash->{PIPELINE_STAGE} eq "REP_SET") {
    
        print "Getting a representative set...\n";
        
        
        checkAndRunCommand("pick_rep_set.py", [{-i => $possible_otu_files[0],
                                                -f => $fasta_output_file,
                                                -o => "$processing_dir/rep_set.fa"}], DIE_ON_FAILURE);
        
        symlink("$results_dir/rep_set.fa", "$processing_dir/rep_set.fa");
        
        $config_hash->{PIPELINE_STAGE} = "ASSIGN_TAXONOMY";
           
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    }
 
    if ($config_hash->{PIPELINE_STAGE} eq "ASSIGN_TAXONOMY") {
    
        my $imputed_file = $QIIME_imputed_file;
        
        checkAndRunCommand("assign_taxonomy.py", [{-i => "$processing_dir/rep_set.fa",
                                                   -t => $extra_param_hash->{DB}->{TAXONOMIES},
                                                   -b => $extra_param_hash->{DB}->{OTUS},
                                                   -m => "blast",
                                                   -a => 10,
                                                   -e => 0.001,
                                                   -o => $processing_dir}], DIE_ON_FAILURE);
        
        $config_hash->{PIPELINE_STAGE} = "GENERATE_OTU_TABLE";
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "GENERATE_OTU_TABLE") {
        
        checkAndRunCommand("make_otu_table.py",  [{-i => $possible_otu_files[0],
                                                   -t => "$processing_dir/rep_set_tax_assignments.txt",
                                                   -o => "$results_dir/non_normalised_otu_table.txt"}], DIE_ON_FAILURE);
        
        
        checkAndRunCommand("reformat_otu_table.py",  [{-i => "$results_dir/non_normalised_otu_table.txt",
                                                       -t => "$processing_dir/rep_set_tax_assignments.txt",
                                                       -o => "$results_dir/non_normalised_otu_table_expanded.tsv"}], IGNORE_FAILURE);
        
        my $otu_sample_counts = get_read_counts_from_OTU_table("$results_dir/non_normalised_otu_table.txt");
        
        use Data::Dumper;
        print Dumper($otu_sample_counts);
        
        # If this is the first run through, create a file to record the sample_counts.
        if (! -e "sample_counts.txt") {
            open($fh, ">sample_counts.txt");
            print {$fh} "#NAME\tREAD COUNT\n";
            foreach my $sample_name (@starting_samples) {
                if (! defined $otu_sample_counts->{$sample_name}) {
                    $otu_sample_counts->{$sample_name} = 0; 
                }
                print {$fh} $sample_name. "\t" . $otu_sample_counts->{$sample_name} ."\n";
                $sample_counts{$sample_name} = $otu_sample_counts->{$sample_name};
            }
            close($fh);
        }
                
        my %previous_analysis_hash = map {$_ => 1} split /,/, $config_hash->{SAMPLES_FOR_ANALYSIS};
       
        open($fh, ">sample_exclusion.txt");
        print {$fh} "#NAME\tREAD COUNT\tUSE\n";
        foreach my $sample_name (@starting_samples) {
            my $use = 0;
            if ($previous_analysis_hash{$sample_name} && $sample_counts{$sample_name}) {
                $use = 1;
            }
            print {$fh} $sample_name. "\t" . $sample_counts{$sample_name} . "\t" . $use . "\n";
        }
        close($fh); 
                
        print "Non-normalized OTU table has now been generated.\n";
        print "\nCheck the " . $options->{'d'} . " sample_exclusion.txt and choose which samples you wish to exclude.\n";
        print "When you have chosen which samples to exclude, run the following command:\n";
        print "      app_run_analysis.pl -d " . $options->{'d'} . "\n\n";
    
        $config_hash->{PIPELINE_STAGE} = "NORMALISATION";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
        exit();
    
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "NORMALISATION") {
        
        normalise_otu_table($options, \%sample_for_analysis_hash, \%sample_counts,
                            $results_dir, $processing_dir);
         
        $config_hash->{PIPELINE_STAGE} = "RAREFACTION";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));

    }
    
    if (($config_hash->{OTU_TABLES_ONLY}) && (! exists($pipeline_modifiers->{OTU_TABLES_ONLY}))) {
    
        print "APP configured to only create OTU tables. Stopping here.";
        
        return;
    
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "RAREFACTION") {
        
        my $max_samples = max(map {$sample_counts{$_}} keys %sample_for_analysis_hash);
        
        my $global_rare_X = int($max_samples / 50) * 50;
        my $global_rare_N = 50;
        
        # Do rarefaction in stages (10-100 in 10s), (100-1000 in 50s), 1000-5000 in 100s, 5000-10000 in 500s.
        
        print "Doing rarefaction stages....\n";
        
        my @rarefaction_stages = ({min => 10, max => 100, step => 10},
                                  {min => 100, max => 1000, step => 50},
                                  {min => 1000, max => 10000, step => 100},
                                  {min => 10000, max => 50000, step => 500},
                                  {min => 50000, max => 100000, step => 1000});
    
        foreach my $stage (@rarefaction_stages) {
            if (($global_rare_X < $stage->{max})) {
                checkAndRunCommand("multiple_rarefactions.py", [{-i => "$results_dir/non_normalised_otu_table.txt",
                                                                 -o => "$processing_dir/rarefied_otu_tables/",
                                                                 -m => $stage->{min},
                                                                 -x => $global_rare_X,
                                                                 -s => $stage->{step},
                                                                 -n => $global_rare_N}], DIE_ON_FAILURE);
                last;
            } else {
                checkAndRunCommand("multiple_rarefactions.py", [{-i => "$results_dir/non_normalised_otu_table.txt",
                                                                 -o => "$processing_dir/rarefied_otu_tables/",
                                                                 -m => $stage->{min},
                                                                 -x => $stage->{max} - $stage->{step},
                                                                 -s => $stage->{step},
                                                                 -n => $global_rare_N}], DIE_ON_FAILURE);
            }
        }
        
        $config_hash->{PIPELINE_STAGE} = "ALPHA_DIVERSITY";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "ALPHA_DIVERSITY") {
        
        print "Calculating (non-phylogeny dependent) alpha diversity metrics....\n";
        
        my $methods_str = join(",", qw(chao1
                                       chao1_confidence
                                       observed_species
                                       simpson
                                       shannon
                                       fisher_alpha));
        
        checkAndRunCommand("alpha_diversity.py", [{-i => "$processing_dir/rarefied_otu_tables/",
                                                   -o => "$processing_dir/alpha_div/",
                                                   -m => $methods_str}], DIE_ON_FAILURE);
        
        $config_hash->{PIPELINE_STAGE} = "ALPHA_DIVERSITY_COLLATION";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "ALPHA_DIVERSITY_COLLATION") {
        
        checkAndRunCommand("collate_alpha.py", [{-i => "$processing_dir/alpha_div/",
                                                 -o => "$processing_dir/alpha_div_collated/"}], DIE_ON_FAILURE);
     
        `cat *qiime_mapping.txt > qiime_mapping.txt`;
     
        foreach my $format (("png", "svg")) {
            checkAndRunCommand("make_rarefaction_plots.py", [{-i => "$processing_dir/alpha_div_collated/",
                                                              -m => "qiime_mapping.txt",
                                                              -o => "$results_dir/alpha_diversity/",
                                                              "--resolution" => 300,
                                                              "--imagetype" => $format}], DIE_ON_FAILURE);
        }
        
        $config_hash->{PIPELINE_STAGE} = "TREE_CREATION";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "TREE_CREATION") {
    
        my $imputed_file = $QIIME_imputed_file;
        
        print "Treeing non normalised data set...\n";
        checkAndRunCommand("align_seqs.py", [{-i => "$processing_dir/cd_hit_otu/OTU_numbered",
                                              -t => $imputed_file,
                                              -p => 0.6,
                                              -o => "$processing_dir/pynast_aligned"}], DIE_ON_FAILURE);
                
        checkAndRunCommand("filter_alignment.py", [{-i => "$processing_dir/pynast_aligned/OTU_numbered_aligned",
                                                    -o => "$processing_dir"}], DIE_ON_FAILURE);
    }    
    
}

######################################################################
# CD-HIT-OTU Pipeline
#
# This is the pipeline for analysis using CD-HIT-OTU.
#
######################################################################

sub cd_hit_otu_pipeline {
    
    my ($config_hash, $extra_param_hash) = @_;
    my $pipeline_modifiers = get_parameter_modifiers($config_hash->{PIPELINE});
    
    my $processing_dir = 'processing';
    my $results_dir = 'results';
    
    mkdir($processing_dir) if (! -e $processing_dir);
    mkdir($results_dir) if (! -e $results_dir);
    
    if (! exists ($config_hash->{TRIM_LENGTH})) {
        $config_hash->{TRIM_LENGTH} = 250;
    }
    
    my @starting_samples = split /,/, $config_hash->{SAMPLES};
    
    my %sample_counts;
    if (-e "sample_counts.txt") {
        %sample_counts = %{get_read_counts_from_sample_counts("sample_counts.txt")}
    }
    
    my %sample_for_analysis_hash;
    
    my $need_to_reanalyse = 0;
    if (! -e "sample_exclusion.txt") {
        $config_hash->{SAMPLES_FOR_ANALYSIS} = $config_hash->{SAMPLES};
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        %sample_for_analysis_hash = map {$_ => 1} @starting_samples;
        
    } else {
        my @previous_analysis = split /,/, $config_hash->{SAMPLES_FOR_ANALYSIS};
        my %samples_to_use = %{read_sample_exclusion("sample_exclusion.txt")};
        my @sample_for_analysis_array;
        
        foreach my $sample_name (@starting_samples) {
            if ((defined $samples_to_use{$sample_name}) && $samples_to_use{$sample_name}) {
                push @sample_for_analysis_array, $sample_name;
            }
        }
        
        $config_hash->{SAMPLES_FOR_ANALYSIS} = join ",", @sample_for_analysis_array;
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
        %sample_for_analysis_hash = map {$_ => 1} @sample_for_analysis_array;
        foreach my $sample_name (@previous_analysis) {
            if ((! exists ($sample_for_analysis_hash{$sample_name})) && ($sample_counts{$sample_name} != 0)) {
                $need_to_reanalyse = 1;
                last;
            }
        }
    }
        
    # If we are running for the first time, or if sample_exclusions.txt has been modified,
    # reset the pipeline. 
    
    if (($need_to_reanalyse) || (! exists($config_hash->{PIPELINE_STAGE}))) {
        $config_hash->{PIPELINE_STAGE} = "PREAMBLE";
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "PREAMBLE") {
        
    # (Re)create the QIIME mapping file, taking sample_exclusions.txt into account.
        
        my @app_config_files = split /,/, $config_hash->{ORIGINAL_CONFIG_FILES};
        
        my %sample_to_analyse = map {$_ => 1} split /,/, $config_hash->{SAMPLES_FOR_ANALYSIS};
        
        if (! -e "split_libraries") {
            mkdir "split_libraries";
        }
        
       
        foreach my $config_file (@app_config_files) {
            my $config_filename = basename($config_file);
            
            my ($sample_array, $config_array) =
                parse_app_config_files("original_app_configs/$config_filename");
                     
            my $new_sample_array;
            foreach my $sample_array_ptr (@{$sample_array}) {
                if (exists $sample_to_analyse{$sample_array_ptr->[0]}) {
                    push @{$new_sample_array}, $sample_array_ptr;
                }
            }
            
            my $prefix;
            if ($config_filename =~ /app_(.*).config$/) {
                $prefix = $1;
            } else {
                die "Copied config file doesn't match name.\n";
            }
            
            my $qiime_mapping_file = $prefix . "_qiime_mapping.txt";
            create_qiime_mapping_file($qiime_mapping_file, $new_sample_array);
            
            my $params = [{-M => 1,
                           -q => "raw_files/$prefix.qual",
                           -f => "raw_files/$prefix.fasta",
                           -d => '',
                           -m => $qiime_mapping_file,
                           -b => 'variable_length',
                           -a => 20,
                           -H => 40,
                           -k => '',
                           -o => "split_libraries/$prefix",
                           -s => 20,
                           -l => $config_hash->{TRIM_LENGTH},
                           -t => ''}];
            
            splitLibraries($params);
        }
        
        
        open(my $out_fa, ">split_libraries/out.fasta");
        open(my $out_qual, ">split_libraries/out.qual");
        
        my $fasta_read_count = 0;
        my $qual_read_count = 0;
        opendir(my $dh, "split_libraries");        
        while (my $dir = readdir($dh)) {
            if (-d "split_libraries/$dir") {
                if (! -e "split_libraries/$dir/seqs.fna") {
                    next;
                }
                open(my $in_fa, "split_libraries/$dir/seqs.fna");
                while (my $line = <$in_fa>) {
                    if ($line =~ /(^>[^\s]*)_[0-9]*(\s.*$)/) {
                        $fasta_read_count++;
                        print {$out_fa} $1 . "_" . $fasta_read_count . $2 . "\n";
                    } else {
                        print {$out_fa} $line;
                    }
                }
                close($in_fa);
                open(my $in_qual, "split_libraries/$dir/seqs_filtered.qual");
                while (my $line = <$in_qual>) {
                    if ($line =~ /(^>[^\s]*)_[0-9]*(\s.*$)/) {
                        $qual_read_count++;
                        print {$out_qual} $1 . "_" . $qual_read_count . $2 . "\n";
                    } else {
                        print {$out_qual} $line; 
                    }
                }
                close($in_qual);
            }
        }
        
        closedir($dh);
        close($out_fa);
        close($out_qual);
        
        if (-z 'seqs.fna') {
            croak "ERROR: No sequences in seqs.fna (no sequences successfully demultiplexed after split_libraries.py).\n" .
            "Check the config file that the barcode/primer sequences are correct.\n"
        }
        
        $config_hash->{PIPELINE_STAGE} = "TRIM_SEQS";
        
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "TRIM_SEQS") {
    
        my $params = [{-f => 'split_libraries/out.fasta',
                       -q => 'split_libraries/out.qual',
                       -b => $config_hash->{TRIM_LENGTH}}];
        
        truncateFastaAndQual($params);
        
        if (-z 'seqs_filtered.fasta') {
          croak "ERROR: No sequences in seqs_filtered.fna (no sequences successfully trimmed after truncate_fasta_qual_files.py).\n" .
          "Check the config file that the barcode/primer sequences are correct.\n"
        }
        
        $config_hash->{PIPELINE_STAGE} = "ACACIA";
        
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    
    }
    
    my $fasta_output_file = 'out_filtered.fasta';
    
    if ($config_hash->{PIPELINE_STAGE} eq "ACACIA") {
    
        my $fasta_output_file = 'seqs_filtered.fasta';
        
        if (! exists($pipeline_modifiers->{NO_ACACIA})) {
        
            $acacia_config_hash{'FASTA_LOCATION'} = 'out_filtered.fasta';
            
            $acacia_config_hash{TRIM_TO_LENGTH} = $config_hash->{TRIM_LENGTH};
            
            my $acacia_config_file = create_acacia_config_file(\%acacia_config_hash);
            
            my $params_array = [["-XX:+UseConcMarkSweepGC",
                                 "-Xmx100G"],
                                 {-jar => '$ACACIA'},
                                 {-c => $acacia_config_file}];
            
            mkdir('denoised_acacia');
            
            if (run_acacia($params_array)) {
                die "Acacia failed.\n";
            };
            
            unlink($acacia_config_file);
            
            $fasta_output_file = "denoised_acacia/acacia_out_all_tags.seqOut";
        }
        
        $config_hash->{PIPELINE_STAGE} = "CD_HIT_OTU";
        
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    
    }
    
    my $cd_hit_otu_dir = dirname(`which cd-hit-otu-all.pl`);
    
    if ($config_hash->{PIPELINE_STAGE} eq "CD_HIT_OTU") {
    
        print "----------------------------------------------------------------\n";
        print "Start TABLE BASED NORMALISATION data set processing...\n";
        print "----------------------------------------------------------------\n";
        print "Copying reads for analysis...\n";
        
        print "Running CD-HIT-OTU\n";
        checkAndRunCommand("$cd_hit_otu_dir/cd-hit-otu-all.pl",
                           [{-i => $fasta_output_file,
                             -m => "false",
                             -o => "$processing_dir/cd_hit_otu"}], DIE_ON_FAILURE);
        
        my $rep_set_otu_array =
            reformat_CDHIT_repset("$processing_dir/cd_hit_otu/OTU",
                                  "$processing_dir/cd_hit_otu/OTU_numbered");
        
        symlink("../$processing_dir/cd_hit_otu/OTU_numbered", "$results_dir/rep_set.fa");

       
        $config_hash->{PIPELINE_STAGE} = "ASSIGN_TAXONOMY";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "ASSIGN_TAXONOMY") {
        
        print "Assigning taxonomy for non normalised data set...\n";
        
        # update our databases (GG by default)
        my $TAX_tax_file = $QIIME_TAX_tax_file;
        my $TAX_blast_file = $QIIME_TAX_blast_file;
        my $TAX_aligned_blast_file = $QIIME_TAX_aligned_blast_file;
        my $imputed_file = $QIIME_imputed_file;
        
        print Dumper($extra_param_hash);
        
        #print "Assign taxonomy method: $assign_taxonomy_method\n";
        #if ($assign_taxonomy_method eq 'blast') {
            checkAndRunCommand("assign_taxonomy.py", [{-i => "$results_dir/rep_set.fa",
                                                       -t => $extra_param_hash->{DB}->{TAXONOMIES},
                                                       -b => $extra_param_hash->{DB}->{OTUS},
                                                       -m => "blast",
                                                       -a => 10,
                                                       -e => 0.001,
                                                       -o => $processing_dir}], DIE_ON_FAILURE);
        #} elsif ($assign_taxonomy_method eq 'bwasw') {
        #    checkAndRunCommand("assign_taxonomy.py", [{-i => "$processing_dir/cd_hit_otu/OTU_numbered",
        #                                                -t => $TAX_tax_file,
        #                                                -d => $TAX_blast_file,
        #                                                -m => "bwasw",
        #                                                -a => $num_threads,
        #                                                -o => $global_TB_processing_dir}], DIE_ON_FAILURE);
        #} else {
        #    die "Unrecognised assign_taxonomy method: '$assign_taxonomy_method'";
        #}
        
        $config_hash->{PIPELINE_STAGE} = "GENERATE_OTU_TABLE";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "GENERATE_OTU_TABLE") {
    
        print "Assigning sample counts to clusters: \n";
        checkAndRunCommand("$cd_hit_otu_dir/clstr_sample_count_matrix.pl",
                           [["_", "$processing_dir/cd_hit_otu/OTU.nr2nd.clstr"]]);
        
        print "Making NON NORMALISED otu table...\n";
        
        create_QIIME_OTU_from_CDHIT("$processing_dir/rep_set_tax_assignments.txt",
                                    "$processing_dir/cd_hit_otu/OTU.nr2nd.clstr.otu.txt",
                                    "$results_dir/non_normalised_otu_table.txt");
        
        print "Reformating OTU table...\n";
        checkAndRunCommand("reformat_otu_table.py",  [{-i => "$results_dir/non_normalised_otu_table.txt",
                                                       -t => "$processing_dir/rep_set_tax_assignments.txt",
                                                       -o => "$results_dir/non_normalised_otu_table_expanded.tsv"}], IGNORE_FAILURE);
    
        my $otu_sample_counts = get_read_counts_from_cd_hit_otu("$processing_dir/cd_hit_otu/OTU.nr2nd.clstr.sample.txt");
        
        print Dumper($otu_sample_counts);
            
        # If this is the first run through, create a file to record the sample_counts.
        if (! -e "sample_counts.txt") {
            open($fh, ">sample_counts.txt");
            print {$fh} "#NAME\tREAD COUNT\n";
            foreach my $sample_name (@starting_samples) {
                if (! defined $otu_sample_counts->{$sample_name}) {
                    $otu_sample_counts->{$sample_name} = 0; 
                }
                print {$fh} $sample_name. "\t" . $otu_sample_counts->{$sample_name} ."\n";
                $sample_counts{$sample_name} = $otu_sample_counts->{$sample_name};
            }
            close($fh);
        }
                
        my %previous_analysis_hash = map {$_ => 1} split /,/, $config_hash->{SAMPLES_FOR_ANALYSIS};
        
        
        open($fh, ">sample_exclusion.txt");
        print {$fh} "#NAME\tREAD COUNT\tUSE\n";
        foreach my $sample_name (@starting_samples) {
            my $use = 0;
            if ($previous_analysis_hash{$sample_name} && $sample_counts{$sample_name}) {
                $use = 1;
            }
            print {$fh} $sample_name. "\t" . $sample_counts{$sample_name} . "\t" . $use . "\n";
        }
        close($fh);
        
        print Dumper(\%sample_counts);
        
        print "##############################################\n";
        print "################ READ THIS ###################\n";
        print "##############################################\n";
        
        print "Non-normalized OTU table has now been generated.\n";
        print "Check the " . $options->{'d'} . "/sample_exclusion.txt and choose which samples you wish to exclude.\n";
        print "      vim " . $options->{'d'} . "/sample_exclusion.txt" . "\n\n";
        print "When you have chosen which samples to exclude, run the following command:\n";
        print "      app_run_analysis.pl -d " . $options->{'d'} . "\n\n";
        
        $config_hash->{PIPELINE_STAGE} = "NORMALISATION";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
        exit();
    
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "NORMALISATION") {
        
        my $normalised_otu_table = normalise_otu_table($options, \%sample_for_analysis_hash, \%sample_counts,
                                                       $results_dir, $processing_dir);
                
        checkAndRunCommand("reformat_otu_table.py",  [{-i => $normalised_otu_table,
                                                       -t => "$processing_dir/rep_set_tax_assignments.txt",
                                                       -o => "$results_dir/normalised_otu_table_expanded.tsv"}], IGNORE_FAILURE);
        
        print "Summarizing by taxa.....\n";
        
        checkAndRunCommand("summarize_taxa.py", [{-i => "$results_dir/normalised_otu_table.txt",
                                                  -o => "$results_dir/breakdown_by_taxonomy/"}], DIE_ON_FAILURE);
         
        $config_hash->{PIPELINE_STAGE} = "RAREFACTION";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    }
    
    if ((uc($config_hash->{OTU_TABLES_ONLY}) eq 'TRUE') && (! exists($pipeline_modifiers->{OTU_TABLES_ONLY}))) {
    
        print "APP configured to only create OTU tables. Stopping here.\n";
        
        return;
    
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "RAREFACTION") {
        
        my $max_samples = max(map {$sample_counts{$_}} keys %sample_for_analysis_hash);
        
        my $global_rare_X = int($max_samples / 50) * 50;
        my $global_rare_N = 50;
        
        # Do rarefaction in stages (10-100 in 10s), (100-1000 in 50s), 1000-5000 in 100s, 5000-10000 in 500s.
        
        print "Doing rarefaction stages....\n";
        
        my @rarefaction_stages = ({min => 10, max => 100, step => 10},
                                  {min => 100, max => 1000, step => 50},
                                  {min => 1000, max => 10000, step => 100},
                                  {min => 10000, max => 50000, step => 500},
                                  {min => 50000, max => 100000, step => 1000});
    
        foreach my $stage (@rarefaction_stages) {
            if (($global_rare_X < $stage->{max})) {
                checkAndRunCommand("multiple_rarefactions.py", [{-i => "$results_dir/non_normalised_otu_table.txt",
                                                                 -o => "$processing_dir/rarefied_otu_tables/",
                                                                 -m => $stage->{min},
                                                                 -x => $global_rare_X,
                                                                 -s => $stage->{step},
                                                                 -n => $global_rare_N}], DIE_ON_FAILURE);
                last;
            } else {
                checkAndRunCommand("multiple_rarefactions.py", [{-i => "$results_dir/non_normalised_otu_table.txt",
                                                                 -o => "$processing_dir/rarefied_otu_tables/",
                                                                 -m => $stage->{min},
                                                                 -x => $stage->{max} - $stage->{step},
                                                                 -s => $stage->{step},
                                                                 -n => $global_rare_N}], DIE_ON_FAILURE);
            }
        }
        
        $config_hash->{PIPELINE_STAGE} = "ALPHA_DIVERSITY";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "ALPHA_DIVERSITY") {
        
        print "Calculating (non-phylogeny dependent) alpha diversity metrics....\n";
        
        my $methods_str = join(",", qw(chao1
                                       chao1_confidence
                                       observed_species
                                       simpson
                                       shannon
                                       fisher_alpha));
        
        checkAndRunCommand("alpha_diversity.py", [{-i => "$processing_dir/rarefied_otu_tables/",
                                                   -o => "$processing_dir/alpha_div/",
                                                   -m => $methods_str}], DIE_ON_FAILURE);
        
        $config_hash->{PIPELINE_STAGE} = "ALPHA_DIVERSITY_COLLATION";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "ALPHA_DIVERSITY_COLLATION") {
        
        checkAndRunCommand("collate_alpha.py", [{-i => "$processing_dir/alpha_div/",
                                                 -o => "$processing_dir/alpha_div_collated/"}], DIE_ON_FAILURE);
     
        `cat *qiime_mapping.txt > qiime_mapping.txt`;
        
        foreach my $format (("png", "svg")) {
            checkAndRunCommand("make_rarefaction_plots.py", [{-i => "$processing_dir/alpha_div_collated/",
                                                              -m => "qiime_mapping.txt",
                                                              -o => "$results_dir/alpha_diversity/",
                                                              "--resolution" => 300,
                                                              "--imagetype" => $format}], DIE_ON_FAILURE);
        }
        
        $config_hash->{PIPELINE_STAGE} = "SETUP_PHYLOGENY_FILES";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "SETUP_PHYLOGENY_FILES") {
    
        my @directories = ("phylogenetic_metrics",
                           "phylogenetic_metrics/blast_substituted_phylogeny",
                           "phylogenetic_metrics/de_novo_phylogeny");
        
        foreach my $top_directory (($results_dir, $processing_dir)) {
            foreach my $directory (@directories) {
                if (! -e "$top_directory/$directory") {
                    mkdir "$top_directory/$directory" or die "Unable to make directory: $top_directory/$directory\n";
                }
            }
        }
        
        $config_hash->{PIPELINE_STAGE} = "DE_NOVO_PHYLOGENY";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "DE_NOVO_PHYLOGENY") {
     
        print "Treeing non normalised data set...\n";
        
        my $dn_processing_dir = "$processing_dir/phylogenetic_metrics/de_novo_phylogeny/";
        my $dn_results_dir = "$results_dir/phylogenetic_metrics/de_novo_phylogeny/";
        
        
        checkAndRunCommand("align_seqs.py", [{-i => "$results_dir/rep_set.fa",
                                              -t => $extra_param_hash->{DB}->{IMPUTED},
                                              -p => 0.6,
                                              -o => "$dn_processing_dir/pynast_aligned"}], DIE_ON_FAILURE);
                
        checkAndRunCommand("filter_alignment.py", [{-i => "$dn_processing_dir/pynast_aligned/rep_set_aligned.fa",
                                                    -o => "$dn_processing_dir"}], DIE_ON_FAILURE);
        
        checkAndRunCommand("make_phylogeny.py", [{-i => "$dn_processing_dir/rep_set_aligned_pfiltered.fasta",
                                                  -r => "midpoint"}], DIE_ON_FAILURE);
        
        print "Calculating (phylogeny dependent) alpha diversity metrics for de novo phylogeny....\n";
        
        checkAndRunCommand("alpha_diversity.py", [{-i => "$processing_dir/rarefied_otu_tables/",
                                                   -t => "$dn_processing_dir/rep_set_aligned_pfiltered.tre",
                                                   -o => "$dn_processing_dir/alpha_div/",
                                                   -m => "PD_whole_tree"}], DIE_ON_FAILURE);
        
        checkAndRunCommand("collate_alpha.py", [{-i => "$dn_processing_dir/alpha_div/",
                                                 -o => "$dn_processing_dir/alpha_div_collated/"}], DIE_ON_FAILURE);
        
        foreach my $format (("png", "svg")) {
            checkAndRunCommand("make_rarefaction_plots.py", [{-i => "$dn_processing_dir/alpha_div_collated/",
                                                              -m => "qiime_mapping.txt",
                                                              -o => "$dn_results_dir/alpha_diversity/",
                                                              "--resolution" => 300,
                                                              "--imagetype" => $format}], DIE_ON_FAILURE);
        }
        
        $config_hash->{PIPELINE_STAGE} = "PREPARE_BETA_DIVERSITY";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
        
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "PREPARE_BETA_DIVERSITY") {
        
        if ((scalar keys %sample_for_analysis_hash) < 2) {
            print "Need more than 1 sample to preform beta diversity.\n";
            print "Stopping here\n";
            
        }
        
        my $min_samples = min(map {$sample_counts{$_}} keys %sample_for_analysis_hash);
        
        my $rare_depth = (int($min_samples / 50) - 1) * 50;
                
        print "Jackknifing in preparation for beta diversity\n";
        
        my $jack_knife_folder = "$processing_dir/rare_tables/JN";
        
        if (! -e $jack_knife_folder) {
            mkdir $jack_knife_folder or die "Unable to make directory: $jack_knife_folder\n";
        }
        
        foreach my $jn_file_counter (0..100) {
            my $jn_from_file = "rarefaction_".$rare_depth."_".$jn_file_counter.".txt";
            copy("$processing_dir/rare_tables/$jn_from_file", "$jack_knife_folder/");
        }        
        
        $config_hash->{PIPELINE_STAGE} = "DE_NOVO_PHYLOGENY_BETA_DIVERSITY";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "DE_NOVO_PHYLOGENY_BETA_DIVERSITY") {
    
        print "Jacknifed beta diversity (de-novo phylogeny)....\n";
        
        my $beta_div_folder = "$results_dir/phylogenetic_metrics/de_novo_phylogeny/beta_diversity/";
        
        if (! -e $beta_div_folder) {
            mkdir $beta_div_folder or die "Unable to make folder: $beta_div_folder\n";
        }
        
        foreach my $OTU_table (('non_normalised_otu_table','normalised_otu_table')) {
            
            my $output_folder = "$results_dir/phylogenetic_metrics/de_novo_phylogeny/beta_diversity/$OTU_table";
            
            if (! -e $output_folder) {
                mkdir $output_folder or die "Unable to make folder: $output_folder\n";
            }
            
            foreach my $method (("weighted_unifrac", "unweighted_unifrac", "euclidean", "hellinger")) {
                jack_knifing($method, "$results_dir/$OTU_table.txt",
                             "$processing_dir/phylogenetic_metrics/de_novo_phylogeny/rep_set_aligned_pfiltered.tre",
                             "$processing_dir/rare_tables/JN", $output_folder);
            }
        }
        $config_hash->{PIPELINE_STAGE} = "BLAST_SUBSTITUTED_PHYLOGENY";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    }
    
    
    if ($config_hash->{PIPELINE_STAGE} eq "BLAST_SUBSTITUTED_PHYLOGENY") {
    
        my $bs_processing_dir = "$processing_dir/phylogenetic_metrics/blast_substituted_phylogeny/";
        
        checkAndRunCommand("generate_fasta_from_taxonomy.py",
                         [{-t => "$processing_dir/rep_set_tax_assignments.txt",
                           -r => "$results_dir/rep_set.fa",
                           -b => $extra_param_hash->{DB}->{IMPUTED},
                           -o => "$bs_processing_dir/blast_substituted_rep_set_aligned.fasta"}],
                       DIE_ON_FAILURE);
        
        checkAndRunCommand("make_phylogeny.py", [{-i => "$bs_processing_dir/blast_substituted_rep_set_aligned.fasta",
                                                  -r => "midpoint"}], DIE_ON_FAILURE);
        
        
        $config_hash->{PIPELINE_STAGE} = "BLAST_SUBSTITUTED_PHYLOGENY_ALPHA_DIVERSITY";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    
    }
    
    if ($config_hash->{PIPELINE_STAGE} eq "BLAST_SUBSTITUTED_PHYLOGENY_ALPHA_DIVERSITY") {
    
        print "Calculating (phylogeny dependent) alpha diversity metrics for blast substituted phylogeny....\n";
        
        my $bs_processing_dir = "$processing_dir/phylogenetic_metrics/blast_substituted_phylogeny/";
        my $bs_results_dir = "$results_dir/phylogenetic_metrics/blast_substituted_phylogeny/";
        
        checkAndRunCommand("alpha_diversity.py", [{-i => "$processing_dir/rarefied_otu_tables/",
                                                   -t => "$bs_processing_dir/blast_substituted_rep_set_aligned.tre",
                                                   -o => "$bs_processing_dir/alpha_div/",
                                                   -m => "PD_whole_tree"}], DIE_ON_FAILURE);
        
        checkAndRunCommand("collate_alpha.py", [{-i => "$bs_processing_dir/alpha_div/",
                                                 -o => "$bs_processing_dir/alpha_div_collated/"}], DIE_ON_FAILURE);
        
        foreach my $format (("png", "svg")) {
            checkAndRunCommand("make_rarefaction_plots.py", [{-i => "$bs_processing_dir/alpha_div_collated/",
                                                              -m => "qiime_mapping.txt",
                                                              -o => "$bs_results_dir/alpha_diversity/",
                                                              "--resolution" => 300,
                                                              "--imagetype" => $format}], DIE_ON_FAILURE);
        }
            
        $config_hash->{PIPELINE_STAGE} = "BLAST_SUBSTITUTED_PHYLOGENY_BETA_DIVERSITY";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    
    }
    
    
    if ($config_hash->{PIPELINE_STAGE} eq "BLAST_SUBSTITUTED_PHYLOGENY_BETA_DIVERSITY") {
        
        print "Jacknifed beta diversity (blast substituted phylogeny)....\n";
        
        my $beta_div_folder = "$results_dir/phylogenetic_metrics/blast_substituted_phylogeny/beta_diversity/";
        
        if (! -e $beta_div_folder) {
            mkdir $beta_div_folder or die "Unable to make folder: $beta_div_folder\n";
        }
        
        foreach my $OTU_table (('non_normalised_otu_table','normalised_otu_table')) {
        
            my $output_folder = "$results_dir/phylogenetic_metrics/blast_substituted_phylogeny/beta_diversity/$OTU_table";
            
            if (! -e $output_folder) {
                mkdir $output_folder or die "Unable to make folder: $output_folder\n";
            }
            
            foreach my $method (("weighted_unifrac", "unweighted_unifrac", "euclidean", "hellinger")) {
                jack_knifing($method, "$results_dir/$OTU_table.txt",
                             "$processing_dir/phylogenetic_metrics/blast_substituted_phylogeny/blast_substituted_rep_set_aligned.tre",
                             "$processing_dir/rare_tables/JN", $output_folder);
            }
        }
    
        $config_hash->{PIPELINE_STAGE} = "NEXT";
            
        create_analysis_config_file("config.txt", convert_hash_to_array($config_hash));
    }
    
    
}

######################################################################
# Pipeline modules
######################################################################

sub splitLibraries
{
    #-----
    # Wrapper for Qiime split libraries
    #
    my ($params) = @_;
    print "Splitting libraries...\n";
    checkAndRunCommand("split_libraries.py", $params, DIE_ON_FAILURE);
}

sub truncateFastaAndQual
{
    my ($params) = @_;
    print "Trimming reads...\n";
    checkAndRunCommand("truncate_fasta_qual_files.py", $params, DIE_ON_FAILURE);
}

sub uclustRemoveChimeras
{
    #-----
    # Remove chimeras using uclust
    #
    my ($params) = @_;

    
    print "Removing chimeras...\n";
        
    checkAndRunCommand("usearch", $params, DIE_ON_FAILURE);
}

sub run_acacia
{
    #-----
    # run acacia on the data
    #
    my ($params) = @_;
       
    print "Denoising using acacia...\n";
    
    # Because acacia's return value is 1 on success (instead of the traditional
    # zero), we need to ignore on failure and test if the stats file was written
    # to.

    
    checkAndRunCommand("java", $params, IGNORE_FAILURE);
    
    
    # TODO: This is lazy. Shouldn't need to call out to global hash.
    my $stats_file = $acacia_config_hash{OUTPUT_DIR} . "/" .
        $acacia_config_hash{OUTPUT_PREFIX} . "_all_tags.stats";
    
    # If the stats file doesn't exist or is zero size, die and raise an error.
    if ((! -e $stats_file) || (-z $stats_file)) {
        print "\n################# WARNING!!!!!!!!!! #################\n" .
              "The ACACIA stats file was not written to!!!\n" .
              "You should check the acacia_standard_error.txt and\n" .
              "acacia_standard_debug.txt in the QA/denoised_acacia/\n" .
              "directory before proceeding to app_make_results.pl to\n" .
              "ensure ACACIA completed successfully.\n" .
              "#####################################################\n\n";   
        return 1;
    }
    #`java -XX:+UseConcMarkSweepGC -Xmx10G -jar \$ACACIA -c $config_filename`;
    #`sed -i -e "s/all_tags_[^ ]* //" $global_acacia_output_dir/$ACACIA_out_file`;
    return 0;
    
}


###############################################################################
# Subs
###############################################################################

sub updateAcaciaConfigHash {
    my ($config_file) = @_;
    open(my $fh, "<", $config_file);
    while (my $line = <$fh>) {
        if ($line =~ /^(.*)=(.*)$/) {
            $acacia_config_hash{$1} = $2;
        }
    }
    close($fh);
}

sub create_acacia_config_file {
    my ($acacia_config_hash) = @_;
    
    my $acacia_config_string =
        join("\n", map({$_ ."=" .$acacia_config_hash->{$_}} sort {$a cmp $b} keys %{$acacia_config_hash}));
    
    # Create a temporary file to dump the config
    my ($tmp_fh, $config_filename) = tempfile("acacia_XXXXXXXX", UNLINK => 0);
    
    # Unbuffer the output of $tmp_fh
    select($tmp_fh);
    $| = 1;
    select(STDOUT);
    
    # Write to the temporary acacia config file
    print {$tmp_fh} $acacia_config_string;
    
    close($tmp_fh);
    
    return $config_filename;
}

sub reformat_CDHIT_repset {
    my ($fasta_file, $output_file) = @_;
    open(my $in_fh, $fasta_file);
    open(my $out_fh, ">$output_file");
    my $return_array;
    my $count = 0;
    while(my $line = <$in_fh>) {
        if ($line =~ /^>(([^\s]*).*)/) {
            print {$out_fh} ">$count $1\n";
            push @{$return_array}, $2;
            $count++;
            
        } else {
            print {$out_fh} $line;
        }
    }
    close($out_fh);
    close($in_fh);
    return $return_array;
}

sub create_QIIME_OTU_from_CDHIT {
    my ($nn_rep_set_tax_assign, $cd_hit_otu_file, $outfile) = @_;
    
    # Read the CD_HIT_OTU OTU table.
    open(my $cd_hit_otu_fh, $cd_hit_otu_file);
    my $header_line = <$cd_hit_otu_fh>;
    my @splitline = split /\t/, $header_line;
    my @headers = @splitline[1..($#splitline-1)];
    
    my @cd_hit_otu_array;
    my $max_sample_count = 0;
    while (my $line = <$cd_hit_otu_fh>) {
        my @splitline = split /\t/, $line;
        #Push everything but the first and last columns;
        my @slice = @splitline[1..($#splitline-1)];
        my $sample_count = scalar @slice;
        $max_sample_count = max($max_sample_count, $sample_count);
        push (@cd_hit_otu_array, \@slice);
    }
    close($cd_hit_otu_fh);
    
    # Create Taxonomy correlations
    my %tax_hash;
    open(my $tax_fh, $nn_rep_set_tax_assign);
    while (my $line = <$tax_fh>) {
        my @splitline = split /\t/, $line;
        $tax_hash{$splitline[0]} = $splitline[1];
    }
    close($tax_fh);
    
    my @sample_counts = (0) x $max_sample_count;
    open(my $out_fh, ">$outfile");
    # Print OTU headers   
    print {$out_fh} "# QIIME v1.3.0 OTU table\n";
    print {$out_fh} join("\t", ("#OTU ID",
                      join("\t", @headers),
                      "Consensus Lineage")), "\n";
    # Print OTU table guts
    for(my $i = 0; $i < scalar @cd_hit_otu_array; $i++) {
        print {$out_fh} join("\t", ($i,
                                    join("\t", @{$cd_hit_otu_array[$i]}),
                                    $tax_hash{$i})), "\n";
        for(my $j = 0; $j < scalar @{$cd_hit_otu_array[$i]}; $j++) {
            $sample_counts[$j] += $cd_hit_otu_array[$i]->[$j];
        }
    }
    close($out_fh);
    return \@sample_counts;
    
}

sub checkParams {
    my @standard_options = ( "help|h+", "d:s");
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
    if(!exists $options{'d'} ) { print "**ERROR: you MUST give a directory\n"; exec("pod2usage $0"); }

    return \%options;
}

sub printAtStart {
print<<"EOF";
---------------------------------------------------------------- 
 $0
 Version $VERSION
 Copyright (C) 2011 Michael Imelfort and Paul Dennis
               2012 Adam Skarshewski
    
 This program comes with ABSOLUTELY NO WARRANTY;
 This is free software, and you are welcome to redistribute it
 under certain conditions: See the source for more details.
---------------------------------------------------------------- 
EOF
}

__DATA__

=head1 NAME

    app_run_analysis.pl

=head1 COPYRIGHT

   copyright (C) 2011 Michael Imelfort and Paul Dennis,
                 2012 Adam Skarshewski

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

   Runs an APP analysis in a folder created by app_create_analysis.
   
=head1 SYNOPSIS

    app_run_analysis.pl -d directory [-help|h]

      -d directory                 Directory created by app_create_analysis.pl to run.
      [-help -h]                   Displays basic usage information
         
=cut
