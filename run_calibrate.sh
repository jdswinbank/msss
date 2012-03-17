#!/usr/bin/env bash

# Based on code originally written by Tom Hassall
# Extensively modified by John Swinbank
# Bug reports, patches etc to <swinbank@transientskp.org>

# Default values; can be overriden on command line
CAL_PARSET=cal.parset
CORRECT_PARSET=correct.parset
PHASE_PARSET=phaseonly.parset
DUMMY_MODEL=/home/hassall/MSSS/dummy.model
CLOBBER=FALSE
AUTO_FLAG_STATIONS=FALSE
declare -a BAD_STATION_LIST
ctr=0 # length of BAD_STATION_LIST

usage() {
    echo -e "Usage:"
    echo -e "    ${0} [options] <obs_id> <beam> <band> <skyModel> <calModel> \n"
    echo -e "Options with string arguments:"
    echo -e '    -o   Output filename (default: ${obs_id}_SAP00${beam}_BAND${band}.MS.flag)'
    echo -e "    -a   Parset for calibration of calibrator (default: ${CAL_PARSET})"
    echo -e "    -g   Parset applying gain calibration to target (default: ${CORRECT_PARSET})"
    echo -e "    -p   Parset for phase-only calibration of target (default: ${PHASE_PARSET})"
    echo -e "    -d   Dummy sky model for use in applying gains (default: ${DUMMY_MODEL})\n"
    echo -e "    -s   Flag a specific station in the output"
    echo -e "Options which take no argument:"
    echo -e "    -c   Overwrite output file if it already exists"
    echo -e "    -f   Automatically identify & flag bad stations"
    echo -e "    -h   Display this message\n"
    echo -e "Example:"
    echo -e "    ${0} L42025 0 06 ~rowlinson/msss/201203/sky.model ~rowlinson/msss/201203/3c295.model"
}

while getopts ":o:a:g:p:d:s:cfh" opt; do
    case $opt in
        o)
            OUTPUT_NAME=${OPTARG}
            ;;
        a)
            CAL_PARSET=${OPTARG}
            ;;
        g)
            CORRECT_PARSET=${OPTARG}
            ;;
        p)
            PHASE_PARSET=${OPTARG}
            ;;
        d)
            DUMMY_MODEL=${OPTARG}
            ;;
        c)
            CLOBBER=TRUE
            ;;
        f)
            AUTO_FLAG_STATIONS=TRUE
            ;;
        s)
            BAD_STATION_LIST[$((ctr++))]=${OPTARG}
            ;;
        h)
            usage
            exit 0
            ;;
        \?)
            echo -e "Invalid option: -${OPTARG}\n"
            usage
            exit 1
            ;;
    esac
done

# Now read out required positional parameters
shift $(( OPTIND-1 ))
if [ $# -ne 5 ]; then
    usage
    exit 1
fi
obs_id=${1}
beam=${2}
band=${3}
skyModel=${4}
calModel=${5}

# If anything goes wrong, we'll print a helpful(-ish) messge and exit
COLOR_RED_BOLD=`tput setaf 1 && tput bold`
COLOR_NONE=`tput sgr0`

error()
{
    echo ${COLOR_RED_BOLD}[ERROR]${COLOR_NONE} ${BASH_COMMAND} failed.
    exit 1
}

trap error ERR


if [ "${beam}" = 0 ]; then
    targ_band=0`echo $band | bc`
    cal_band=`echo $band+16 | bc`
elif [ "${beam}" =  1 ]; then
    targ_band=`echo $band+8 | bc`
    cal_band=`echo $band+16 | bc`
fi

combined=${obs_id}_SAP00${beam}_BAND${band}.MS

echo "Starting ${0} at" `date`

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

if [ -d ${OUTPUT_NAME} ]; then
    if [ ${CLOBBER} = "TRUE" ]; then
        echo "Removing ${OUTPUT_NAME}"
        rm -rf ${OUTPUT_NAME}
    else
        echo "${OUTPUT_NAME} already exists; aborting"
        exit 1
    fi
fi

if [ -d ${combined} ]; then
    echo "Removing ${combined}"
    rm -rf ${combined}
fi

if [ -d $

test -d log || mkdir log
test -d plots || mkdir plots

# We'll need these sourcedbs a number of times, so might as well build them
# once and reuse.
echo "Building calibrator sourcedb..."
test -d sky.calibrator && rm -rf sky.calibrator
makesourcedb in=${calModel} out=sky.calibrator format='<'

echo "Building dummy sourcedb..."
test -d sky.dummy && rm -rf sky.dummy
makesourcedb in=${DUMMY_MODEL} out=sky.dummy format='<'

process_subband() {
    num=${1}
    trap error ERR # Enable error handler in subshell
    echo "Starting work on subband" $num `date`
    source=${obs_id}_SAP00${beam}_SB${targ_band}${num}_target_sub.MS.dppp
    cal=${obs_id}_SAP002_SB${cal_band}${num}_target_sub.MS.dppp

    echo "Calibrating ${cal}..."
    calibrate-stand-alone --replace-parmdb --sourcedb sky.calibrator ${cal} ${CAL_PARSET} ${calModel} > log/calibrate_cal_${num}.txt

    echo "Zapping suspect points for SB${cal_band}${num}..."
    ~swinbank/edit_parmdb/edit_parmdb.py --sigma=1 --auto ${cal}/instrument/ > log/edit_parmdb_${num}.txt 2>&1

    echo "Making diagnostic plots for SB${cal_band}${num}..."
    ~heald/bin/solplot.py -q -m -o SB${cal_band}${num} ${cal}/instrument/

    echo "Calibrating ${source}..."
    calibrate-stand-alone --sourcedb sky.dummy --parmdb ${cal}/instrument ${source} ${CORRECT_PARSET} /home/hassall/MSSS/dummy.model > log/calibrate_transfer_${num}.txt
    echo "Finished subband" ${num} `date`
}

for num in {0..9} ; do
    process_subband $num &
    child_pids[num]=$!
done
for pid in ${child_pids[*]}; do
    wait $pid
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
NDPPP NDPPP.parset

echo "rficonsole..."
echo "Removing RFI... " `date`
rficonsole -indirect-read ${combined}

echo "Calibrating ${combined}"
echo "Starting phase-only calibration" `date`
calibrate-stand-alone -f ${combined} ${PHASE_PARSET} ${skyModel} > log/calibrate_phaseonly.txt

echo "Finished phase-only calibration" `date`
mv SB*.pdf plots
mv calibrate-stand-alone*log log

if [ ${AUTO_FLAG_STATIONS} = "TRUE" ]; then
    echo "Flagging bad stations... " `date`
    PYTHONPATH=$PYTHONPATH:/home/martinez/software ~martinez/software/ledama/ExecuteLModule ASCIIStats -i ${combined} -r ./
    PYTHONPATH=$PYTHONPATH:/home/martinez/software ~martinez/plotting/statsplot.py -i `pwd`/${combined}.stats -o ${obs_id}
    for station in `grep True$ ${obs_id}.tab | cut -f2`; do
        BAD_STATION_LIST[$((ctr++))]=${station}
    done
fi

if [ ! ${OUTPUT_NAME} ]; then
    OUTPUT_NAME=${combined}.flag
fi

if [ ${BAD_STATION_LIST} ]; then
    FILTER=`echo "!${BAD_STATION_LIST[*]}" | sed -e's/ /;!/g'`
else
    FILTER=""
fi

msselect in=${combined} out=${OUTPUT_NAME} baseline=${FILTER} deep=True

echo "Data written to ${OUTPUT_NAME}."
echo "${0} finished at" `date`
