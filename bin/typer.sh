#!/bin/bash
# Author: Xie Chao
set -eu -o pipefail

[[ $# -lt 2 ]] && {
    echo "usage: $(basename "$0") S3://path.bam sample_id [delete]";
    exit 1;
}
BIN="`dirname \"$0\"`"
S3=$1
ID=$2
OUT=hla-$ID

mkdir -p $OUT
TEMP=temp-$RANDOM-$RANDOM-$RANDOM

echo "Extracting reads from S3"
samtools view -u $S3 chr6:29886751-33090696 | samtools view -L $BIN/../data/hla.bed - > ${TEMP}.sam
$BIN/preprocess.pl ${TEMP}.sam | gzip > $OUT/$ID.fq.gz
rm ${TEMP}.sam
echo "Aligning reads to IMGT database"
$BIN/align.pl $OUT/${ID}.fq.gz $OUT/${ID}.tsv
#note: if want to do full resolution typing:
#$BIN/align.pl $OUT/${ID}.fq.gz $OUT/${ID}.tsv full
echo "Typing"
$BIN/typing.r $OUT/${ID}.tsv $OUT/${ID}.hla
echo "Reporting"
$BIN/report.py -in $OUT/${ID}.hla -out $OUT/${ID}.json -subject $ID -sample $ID

#note: if want to do full resolution typing:
#$BIN/full.r $OUT/${ID}.tsv.dna $OUT/${ID}.hla $OUT/${ID}.hla.full

if [ $# -eq 3 ]
then
	rm $OUT/${ID}.tsv
	rm $OUT/${ID}.fq.gz
	rm $OUT/${ID}.hla
fi
