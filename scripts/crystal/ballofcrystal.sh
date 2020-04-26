#!/bin/bash

FNAMEOUT="mydata"
FIXED="6000"
RATIO="0.99"
SHORTCONF=2
LONGCONF=2
EXTRA_CMS_OPTS=""

EXTRA_GEN_PANDAS_OPTS=""
if [ "$1" == "--csv" ]; then
    EXTRA_GEN_PANDAS_OPTS="--csv"
    echo "CSV will be generated (may take some disk space)"
    NEXT_OP="$2"
else
    NEXT_OP="$1"
fi

if [ "$NEXT_OP" == "" ]; then
    while true; do
        echo "No CNF command line parameter, running predefined CNFs"
        echo "Options are:"
        echo "1 -- countbitswegner064.cnf"
        echo "2 -- goldb-heqc-i10mul.cnf"
        echo "3 -- goldb-heqc-alu4mul.cnf"
        echo "4 -- g2-mizh-md5-48-2.cnf"
        echo "5 -- AProVE07-16.cnf"
        echo "6 -- UTI-20-10p0.cnf-unz"
        echo "7 -- UCG-20-5p0.cnf"

        read -p "Which CNF do you want to run? " myinput
        case $myinput in
            ["1"]* )
                ORIGTIME="101";
                FNAME="countbitswegner064.cnf";
                break;;
            [2]* )
                ORIGTIME="16";
                EXTRA_CMS_OPTS=" --confbtwsimp 100000 "
                FNAME="goldb-heqc-i10mul.cnf";
                break;;
            [3]* )
                ORIGTIME="70.84";
                FNAME="goldb-heqc-alu4mul.cnf";
                break;;
            [4]* )
                # !!SATISFIABLE!!
                FNAME="g2-mizh-md5-48-2.cnf";
                FIXED="10000";
                break;;
            [5]* )
                ORIGTIME="98s";
                FNAME="AProVE07-16.cnf";
                break;;
            [6]* )
                FNAME="UTI-20-10p0.cnf-unz";
                RATIO="0.30"
                FIXED="20000";
                break;;
            [7]* )
                ORIGTIME="197";
                FNAME="UCG-20-5p0.cnf";
                break;;
            * ) echo "Please answer 1-7";;
        esac
    done
else
    if [ "$NEXT_OP" == "-h" ] || [ "$NEXT_OP" == "--help" ]; then
        echo "You must give a CNF file as input"
        exit
    fi
    initial="$(echo ${NEXT_OP} | head -c 1)"
    if [ "$1" == "-" ]; then
        echo "Cannot understand opion, there are no options"
        exit -1
    fi
    FNAME="${NEXT_OP}"
fi

set -e

echo "--> Running on file                   $FNAME"
echo "--> Outputting to data                $FNAMEOUT"
echo "--> Using clause gather ratio of      $RATIO"
echo "--> with fixed number of data points  $FIXED"

if [ "$FNAMEOUT" == "" ]; then
    echo "Error: FNAMEOUT is not set, it's empty. Exiting."
    exit -1
fi

echo "Cleaning up"
(
rm -rf "$FNAME-dir"
mkdir "$FNAME-dir"
cd "$FNAME-dir"
rm -f $FNAMEOUT.d*
rm -f $FNAMEOUT.lemma*
)

set -x


########################
# Build statistics-gathering CryptoMiniSat
########################
./build_stats.sh


(
########################
# Obtain dynamic data in SQLite and DRAT info
########################
cd "$FNAME-dir"
# to be removed: --tern 0
# for var, we need: --bva 0 --scc 0
../cryptominisat5 ${EXTRA_CMS_OPTS} --maxgluehistltlimited 100000 --tern 0 --sqlitedbover 1 --cldatadumpratio "$RATIO" --cllockdatagen 0.5 --clid --sql 2 --sqlitedb "$FNAMEOUT.db-raw" --drat "$FNAMEOUT.drat" --zero-exit-status "../$FNAME" | tee cms-pred-run.out
# --bva 0 --updateglueonanalysis 0 --otfsubsume 0
grep "c conflicts" cms-pred-run.out

########################
# Run our own DRAT-Trim
########################
set +e
a=$(grep "s SATIS" cms-pred-run.out)
retval=$?
set -e
if [[ retval -eq 1 ]]; then
    ../utils/drat-trim/drat-trim "../$FNAME" "$FNAMEOUT.drat" -o "$FNAMEOUT.usedCls" -i
else
    rm -f final.cnf
    touch final.cnf
    cat "../$FNAME" >> final.cnf
    cat dec_list >> final.cnf
    grep ^v cms-pred-run.out | sed "s/v//" | tr -d "\n" | sed "s/  / /g" | sed -e "s/ -/X/g" -e "s/ /Y/g" | sed "s/X/ /g" | sed -E "s/Y([1-9])/ -\1/g" | sed "s/Y0/ 0\n/" >> final.cnf
    ../../utils/cnf-utils/xor_to_cnf.py final.cnf final_good.cnf
    ../tests/drat-trim/drat-trim final_good.cnf "$FNAMEOUT.drat" -o "$FNAMEOUT.usedCls" -i
fi

########################
# Augment, fix up and sample the SQLite data
########################
/usr/bin/time -v ../fill_used_clauses.py "$FNAMEOUT.db-raw" "$FNAMEOUT.usedCls"
cp "$FNAMEOUT.db-raw" "$FNAMEOUT.db"
/usr/bin/time -v ../clean_update_data.py "$FNAMEOUT.db"
/usr/bin/time -v ../check_data_quality.py "$FNAMEOUT.db"
cp "$FNAMEOUT.db" "$FNAMEOUT-min.db"
/usr/bin/time -v ../sample_data.py "$FNAMEOUT-min.db"

########################
# Denormalize the data into a Pandas Table, label it and sample it
########################
../cldata_gen_pandas.py "${FNAMEOUT}-min.db" --limit "$FIXED" --conf 2-2 ${EXTRA_GEN_PANDAS_OPTS} --toppercentileshort 70 --toppercentilelong 70
../vardata_gen_pandas.py "${FNAMEOUT}.db" --limit 1000

mkdir -p ../../src/predict
rm -f ../../src/predict/*.h

####################################
# Clustering for cldata, using cldata dataframe
####################################
# ../clustering.py ${FNAMEOUT}-min.db-cldata-*short*.dat ${FNAMEOUT}-min.db-cldata-*long*.dat --basedir ../../src/predict/ --clusters 4 --scale --nocomputed


####################################
# Create the classifiers
####################################

# TODO: add --csv  to dump CSV
#       then you can play with Weka
#../vardata_predict.py mydata.db-vardata.dat --picktimeonly -q 2 --only 0.99
#../vardata_predict.py vardata-comb --final -q 20 --basedir ../src/predict/ --depth 7 --tree

# for CONF in {0..2}; do
    ../cldata_predict.py "${FNAMEOUT}-min.db-cldata-short-conf-$SHORTCONF.dat" --name short --final --xgboost --basedir ../../src/predict/ --conf $SHORTCONF --prefok 2
    ../cldata_predict.py "${FNAMEOUT}-min.db-cldata-long-conf-$LONGCONF.dat"  --name long  --final --xgboost --basedir ../../src/predict/ --conf $LONGCONF --prefok 2
# done
)

########################
# Build final CryptoMiniSat with the classifier
########################
./build_final_predictor.sh
(
cd "$FNAME-dir"
../cryptominisat5 "../$FNAME" ${EXTRA_CMS_OPTS} --maxgluehistltlimited 100000 --tern 0 --printsol 0 | tee cms-final-run.out
)
exit
