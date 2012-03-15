#!/bin/bash
obs_id=$1
beam=$2
band=$3
skyModel=$4
calModel=$5
if [ "${beam}" = 0 ]; then
    targ_band=0`echo $band | bc`
    cal_band=`echo $band+16 | bc`
elif [ "${beam}" =  1 ]; then
    targ_band=`echo $band+8 | bc`
    cal_band=`echo $band+16 | bc`
fi

COLOR_RED_BOLD=`tput setaf 1 && tput bold`
COLOR_NONE=`tput sgr0`

error()
{
    echo ${COLOR_RED_BOLD}[ERROR]${COLOR_NONE} ${1} failed.
    exit 1
}

combined=${obs_id}_SAP00${beam}_BAND${band}.MS

echo "Starting run_Calibrate.sh" `date`

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

# We'll need these sourcedbs a number of times, so might as well build them
# once and reuse.
echo "Building calibrator sourcedb..."
test -d sky.calibrator && rm -rf sky.calibrator
makesourcedb in=${calModel} out=sky.calibrator format='<' || error makesourcedb

echo "Building dummy sourcedb..."
test -d sky.dummy && rm -rf sky.dummy
makesourcedb in=/home/hassall/MSSS/dummy.model out=sky.dummy format='<' || error makesourcedb

process_subband() {
    num=${1}
    echo "Starting work on subband" $num `date`
    source=${obs_id}_SAP00${beam}_SB${targ_band}${num}_target_sub.MS.dppp
    cal=${obs_id}_SAP002_SB${cal_band}${num}_target_sub.MS.dppp

    echo "Calibrating ${cal}..."
    calibrate-stand-alone --replace-parmdb --sourcedb sky.calibrator ${cal} ../cal.parset ${calModel} > log/calibrate_cal_${num}.txt || error "calibration of calibrator field"

    echo "Zapping suspect points..."
    ~swinbank/edit_parmdb/edit_parmdb.py --sigma=1 --auto ${cal}/instrument/ > log/edit_parmdb_${num}.txt || error edit_parmdb

    echo "Making diagnostic plots..."
    ~heald/bin/solplot.py -q -m -o SB${cal_band}${num} ${cal}/instrument/ || error solplot

    echo "Calibrating ${source}..."
    calibrate-stand-alone --sourcedb sky.dummy --parmdb ${cal}/instrument ${source} ../correct.parset /home/hassall/MSSS/dummy.model > log/calibrate_transfer_${num}.txt || error "solution transfer"
    echo "Finished subband" ${num} `date`
}

for num in {0..9} ; do
    process_subband $num &
    child_pids[num]=$!
done
for pid in ${child_pids[*]}; do
    wait $pid || error "processing subband failed"
done

echo "msin=[${obs_id}_SAP00${beam}_SB${targ_band}"`seq -s "_target_sub.MS.dppp, ${obs_id}_SAP00${beam}_SB${targ_band}" 0 9`"_target_sub.MS.dppp]"> NDPPP.parset
echo "msin.missingdata=true" >> NDPPP.parset
echo "msin.orderms=false" >> NDPPP.parset
echo "msin.datacolumn=CORRECTED_DATA" >> NDPPP.parset
echo "msout="${combined} >> NDPPP.parset
echo "steps=[]" >> NDPPP.parset
echo "" >> NDPPP.parset

echo "Starting work on combined subbands" `date`
echo "Combining Subbands..."
NDPPP NDPPP.parset || error NDPPP

echo "rficonsole..."
echo "Removing RFI... " `date`
rficonsole -indirect-read ${combined} || error rficonsole

echo "Calibrating ${combined}"
echo "Starting phase-only calibration" `date`
calibrate-stand-alone -f ${combined} ../phaseonly.parset ${skyModel} > log/calibrate_phaseonly.txt || error "phase-only calibration"

echo "Finished phase-only calibration" `date`
mv SB*.pdf plots
mv calibrate-stand-alone*log logs
echo "run_Calibrate.sh Finished" `date`
