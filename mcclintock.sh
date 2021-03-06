#!/bin/bash -l

# Argument order: reference consensus gfflocations fastq1 fastq2
# Print usage if user is incorrect:
if (( $# != 6 ))
then
	printf "This script takes the following inputs and will run 5 different transposable element (TE) detection methods:\n"
	printf "Argument 1: A reference genome sequence in fasta format.\n"
	printf "Argument 2: The consensus sequences of the TEs for the species in fasta format.\n"
	printf "Argument 3: The locations of known TEs in the reference genome in GFF 3 format. This must include a unique ID attribute for every entry.\n"
	printf "Argument 4: A tab delimited file with one entry per ID in the GFF file and two columns: the first containing the ID and the second containing the TE family it belongs to.\n"
	printf "Argument 5: The absolute path of the first fastq file from a paired end read, this should be named ending _1.fastq.\n"
	printf "Argument 6: The absolute path of the second fastq file from a paired end read, this should be named ending _2.fastq.\n"
	exit
fi

genome=${1##*/}
genome=${genome%%.*}
sample=${5##*/}
sample=${sample%%_1.f*}

printf "\nCreating directory structure...\n\n"

# Set up folder structure
test_dir=`pwd`
mkdir $test_dir/$genome/
mkdir $test_dir/$genome/reference
mkdir $test_dir/$genome/$sample
mkdir $test_dir/$genome/$sample/fastq
mkdir $test_dir/$genome/$sample/bam
mkdir $test_dir/$genome/$sample/sam

# Copy inout files in to sample directory (neccessary for RelocaTE)
reference_genome_file=${1##*/}
cp -n $1 $test_dir/$genome/reference/$reference_genome_file
consensus_te_seqs_file=${2##*/}
cp -n $2 $test_dir/$genome/reference/$consensus_te_seqs_file
te_locations_file=${3##*/}
cp -n $3 $test_dir/$genome/reference/$te_locations_file
te_families_file=${4##*/}
cp -n $4 $test_dir/$genome/reference/$te_families_file
fastq1_file=${5##*/}
cp -s $5 $test_dir/$genome/$sample/fastq/$fastq1_file
fastq2_file=${6##*/}
cp -s $6 $test_dir/$genome/$sample/fastq/$fastq2_file

# Assign variables to input files
reference_genome=$test_dir/$genome/reference/$reference_genome_file
consensus_te_seqs=$test_dir/$genome/reference/$consensus_te_seqs_file
te_locations=$test_dir/$genome/reference/$te_locations_file
te_families=$test_dir/$genome/reference/$te_families_file
fastq1=$test_dir/$genome/$sample/fastq/$fastq1_file
fastq2=$test_dir/$genome/$sample/fastq/$fastq2_file

# Create indexes of reference genome
samtools faidx $reference_genome
bwa index $reference_genome

# Extract sequence of all reference TE copies
# Cut first line if it begins with #
grep -v '^#' $te_locations | awk -F'[\t=;]' 'BEGIN {OFS = "\t"}; {printf $1"\t"$2"\t"; for(x=1;x<=NF;x++) if ($x~"ID") printf $(x+1); print "\t"$4,$5,$6,$7,$8,"ID="}' | awk -F'\t' '{print $0$3";Name="$3";Alias="$3}' > edited.gff
mv edited.gff $te_locations
bedtools getfasta -name -fi $reference_genome -bed $te_locations -fo $test_dir/$genome/reference/all_te_seqs.fasta
all_te_seqs=$test_dir/$genome/reference/all_te_seqs.fasta

printf "\nCreating bam alignment...\n\n"

# Create sam and bam files for input
bwa mem -v 0 $reference_genome $fastq1 $fastq2 > $test_dir/$genome/$sample/sam/$sample.sam
sort --temporary-directory=. $test_dir/$genome/$sample/sam/$sample.sam > $test_dir/$genome/$sample/sam/sorted$sample.sam
rm $test_dir/$genome/$sample/sam/$sample.sam
mv $test_dir/$genome/$sample/sam/sorted$sample.sam $test_dir/$genome/$sample/sam/$sample.sam 
sam=$test_dir/$genome/$sample/sam/$sample.sam
sam_folder=$test_dir/$genome/$sample/sam

samtools view -Sb $sam > $test_dir/$genome/$sample/bam/$sample.bam
samtools sort $test_dir/$genome/$sample/bam/$sample.bam $test_dir/$genome/$sample/bam/sorted$sample
rm $test_dir/$genome/$sample/bam/$sample.bam 
mv $test_dir/$genome/$sample/bam/sorted$sample.bam $test_dir/$genome/$sample/bam/$sample.bam 
bam=$test_dir/$genome/$sample/bam/$sample.bam 
samtools index $bam

# Run RelocaTE

printf "\nRunning RelocaTE pipeline...\n\n"

# Add TSD lengths to consensus TE sequences
awk '{if (/>/) print $0" TSD=UNK"; else print $0}' $consensus_te_seqs > $test_dir/$genome/reference/reloca_te_seqs.fasta
relocate_te_seqs=$test_dir/$genome/reference/reloca_te_seqs.fasta

cd RelocaTE
bash runrelocate.sh $relocate_te_seqs $reference_genome $test_dir/$genome/$sample/fastq $sample $te_locations

# Run ngs_te_mapper pipeline

printf "\nRunning ngs_te_mapper pipeline...\n\n"

cd ../ngs_te_mapper

bash runngstemapper.sh $consensus_te_seqs $reference_genome $sample $fastq1 $fastq2 

# Run RetroSeq

printf "\nRunning RetroSeq pipeline...\n\n"

cd ../RetroSeq
bash runretroseq.sh $consensus_te_seqs $bam $reference_genome 

# Run TE-locate

printf "\nRunning TE-locate pipeline...\n\n"

# Adjust hierachy levels
cd ../TE-locate
perl TE_hierarchy.pl $te_locations $te_families Alias
telocate_te_locations=${te_locations%.*}
telocate_te_locations=$telocate_te_locations"_HL.gff"

bash runtelocate.sh $sam_folder $reference_genome $telocate_te_locations 2 $sample

# Run PoPoolationTE

printf "\nRunning PoPoolationTE pipeline...\n\n"

# Create te_hierachy
printf "insert\tid\tfamily\tsuperfamily\tsuborder\torder\tclass\tproblem\n" > $test_dir/$genome/reference/te_hierarchy
awk '{printf $0"\t"$2"\t"$2"\tna\tna\tna\t0\n"}' $te_families >> $test_dir/$genome/reference/te_hierarchy
te_hierarchy=$test_dir/$genome/reference/te_hierarchy

cd ../popoolationte
bash runpopoolationte.sh $reference_genome $all_te_seqs $te_hierarchy $fastq1 $fastq2 $te_locations
