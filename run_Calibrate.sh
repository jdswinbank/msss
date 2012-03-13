#!/bin/sh
obs_id=$1
beam=$2
band=$3
key=$4
skyModel=$5
calModel=$6
if [ "${beam}" = 0 ]; then
    targ_band=0`echo $band | bc`
    cal_band=`echo $band+16 | bc`
else
    if [ "${beam}" =  1 ]; then
        targ_band=`echo $band+8 | bc`
    cal_band=`echo $band+16 | bc`

    fi
fi

combined=${obs_id}_SAP00${beam}_BAND${band}.MS

echo "Starting run_Calibrate.csh" `date`

#uncomment to move data to your working area
#echo "Gathering data..." `date`
#for node in `seq -w 1 100`; do
#    echo $node
#    scp -r locus$node:/data/scratch/pipeline/${obs_id}*/*SB${band}*_target_sub* .
#    scp -r locus$node:/data/scratch/pipeline/${obs_id}*/*SB${cal_band}*_target_sub* .
#done
#echo "scp-ing done!" `date`

#for file in *MS.dppp; do
#    echo rficonsole -indirect-read $file
#    rficonsole -indirect-read $file
#done
#exit

if [ -d ${combined} ]; then
    echo "Removing ${combined}"
    rm -rf ${combined}
fi

test -d log || mkdir log
test -d plots || mkdir plots

process_subband() {
    num=${1}
    echo "Starting work on subband" $num `date`
    source=${obs_id}_SAP00${beam}_SB${targ_band}${num}_target_sub.MS.dppp
    cal=${obs_id}_SAP002_SB${cal_band}${num}_target_sub.MS.dppp

    makevds ~pizzo/cep2.clusterdesc ${source}
    makevds ~pizzo/cep2.clusterdesc ${cal}
    combinevds ${source}.gds ${source}.vds
    combinevds ${cal}.gds ${cal}.vds

    echo "Calibrating CALIBRATOR..."
    calibrate -f --key ${key}-${num} --cluster-desc ~pizzo/cep2.clusterdesc --db ldb002 --db-user postgres ${cal}.gds ../cal.parset ${calModel} `pwd` > log/calibrate_cal_${num}.txt

    echo "Zapping suspect points..."
    ~swinbank/edit_parmdb/edit_parmdb.py --sigma=1 --auto ${cal}/instrument/

    echo "Making diagnostic plots..."
    ~heald/bin/solplot.py -q -m -o SB${cal_band}${num} ${cal}/instrument/

    echo "Calibrating TARGET..."
    calibrate -f --key ${key}-${num} --cluster-desc ~pizzo/cep2.clusterdesc --db ldb002 --db-user postgres --instrument-db ${cal}/instrument ${source}.gds ../correct.parset /home/hassall/MSSS/dummy.model `pwd` > log/calibrate_image_${num}.txt

    echo "Finished subband" ${num} `date`
}

for num in `seq 0 9`; do
    process_subband $num &
done
wait

echo "msin=[${obs_id}_SAP00${beam}_SB${targ_band}"`seq -s "_target_sub.MS.dppp, ${obs_id}_SAP00${beam}_SB${targ_band}" 0 9`"_target_sub.MS.dppp]"> NDPPP.parset
echo "msin.missingdata=true" >> NDPPP.parset
echo "msin.orderms=false" >> NDPPP.parset
echo "msin.datacolumn=CORRECTED_DATA" >> NDPPP.parset
echo "msout="${combined} >> NDPPP.parset
echo "steps=[]" >> NDPPP.parset
echo "" >> NDPPP.parset

echo "Starting work on combined subbands" `date`
echo "Combining Subbands..."
NDPPP NDPPP.parset

echo "Making FINAL vds"
makevds ~pizzo/cep2.clusterdesc ${combined}
echo "Combining FINAL vds"
combinevds ${combined}.gds ${combined}.vds

echo "rficonsole..."
echo "Removing RFI... " `date`
rficonsole -indirect-read ${combined}

echo "Calibrating FINAL IMAGE"
echo "Starting phase-only calibration" `date`
calibrate -f --key ${key} --cluster-desc ~pizzo/cep2.clusterdesc --db ldb002 --db-user postgres ${combined}.gds ../phaseonly.parset ${skyModel} `pwd` >log/calibrate_final_image2.txt

echo "Finished phase-only calibration" `date`
echo "run_Calibrate.csh Finished" `date`
mv ${key}* log/
mv SB*.pdf plots

