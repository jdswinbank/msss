#!/usr/bin/env bash

# Originaly written by Tom Hassall
# Extensively modified by John Swinbank
# Updates by George Heald
#
# Bug reports, patches etc to <swinbank@transientskp.org>

# Default values; can be overriden on command line
CAL_PARSET=cal.parset
CORRECT_PARSET=correct.parset
PHASE_PARSET=phaseonly.parset
DUMMY_MODEL=/home/hassall/MSSS/dummy.model
CLOBBER=FALSE
ROBUST=FALSE
AUTO_FLAG_STATIONS=FALSE
COLLECT=FALSE
declare -a BAD_STATION_LIST
declare -i ctr=0 # length of BAD_STATION_LIST

usage() {
    echo -e "Usage:"
    echo -e "    ${0} [options] <obs_id> <beam> <band> <skyModel> <calModel> \n"
    echo -e "Options with string arguments:"
    echo -e '    -o   Output filename (default: ${obs_id}_SAP00${beam}_BAND${band}.MS.flag)'
    echo -e "    -a   Parset for calibration of calibrator (default: ${CAL_PARSET})"
    echo -e "    -g   Parset applying gain calibration to target (default: ${CORRECT_PARSET})"
    echo -e "    -p   Parset for phase-only calibration of target (default: ${PHASE_PARSET})"
    echo -e "    -d   Dummy sky model for use in applying gains (default: ${DUMMY_MODEL})"
    echo -e "    -s   Flag a specific station in the output\n"
    echo -e "Options which take no argument:"
    echo -e "    -c   Collect data prior to processing"
    echo -e "    -r   Robust mode: continue even if some subbands are not available"
    echo -e "    -f   Automatically identify & flag bad stations"
    echo -e "    -w   Overwrite output file if it already exists"
    echo -e "    -h   Display this message\n"
    echo -e "Example:"
    echo -e "    ${0} L42025 0 06 sky.model 3c295.model"
}

while getopts ":o:a:g:p:d:s:crfhw" opt; do
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
            COLLECT=TRUE
            ;;
        r)
            ROBUST=TRUE
            ;;
        w)
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
COLOUR_RED_BOLD=`tput setaf 1 && tput bold`
COLOUR_YELLOW_BOLD=`tput setaf 3 && tput bold`
COLOUR_NONE=`tput sgr0`

error()
{
    echo ${COLOUR_RED_BOLD}[ERROR]${COLOUR_NONE} ${1}
}

warning()
{
    echo ${COLOUR_YELLOW_BOLD}[WARNING]${COLOUR_NONE} ${1}
}

failure()
{
    error "${BASH_COMMAND} failed"
    exit 1
}

echo "Starting ${0} at" `date`

test -d log || mkdir log
test -d plots || mkdir plots

if [ "${beam}" = 0 ]; then
    targ_band=0`echo $band | bc`
    cal_band=`echo $band+16 | bc`
elif [ "${beam}" =  1 ]; then
    targ_band=`echo $band+8 | bc`
    cal_band=`echo $band+16 | bc`
fi

if [ ${COLLECT} = "TRUE" ]; then
    echo "Collecting data..." `date`
    for node in `seq -w 1 100`; do
        echo locus$node
    done | xargs -n1 -P4 -Ihost scp -r host:/data/scratch/pipeline/${obs_id}*/*SB{${band},${cal_band}}?_target_sub* . >> log/collect.log 2>&1
    echo "scp-ing done!" `date`
fi

# From this point on, any failures are fatal
trap failure ERR

#for file in *MS.dppp; do
#    echo rficonsole -indirect-read $file
#    rficonsole -indirect-read $file
#done
#exit

combined=${obs_id}_SAP00${beam}_BAND${band}.MS
if [ ! ${OUTPUT_NAME} ]; then
    OUTPUT_NAME=${combined}.flag
fi

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
    source=${2}
    cal=${3}
    trap failure ERR # Enable error handler in subshell
    echo "Starting work on " $source `date`

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

declare -a SUBBAND_LIST
declare -a CALBAND_LIST
declare -i bandctr=0
for num in {0..9}; do
    # Check if required data exists
    source=${obs_id}_SAP00${beam}_SB${targ_band}${num}_target_sub.MS.dppp
    cal=${obs_id}_SAP002_SB${cal_band}${num}_target_sub.MS.dppp

    if [ -d ${source} ] && [ -d ${cal} ];  then
        SUBBAND_LIST[${bandctr}]=${source}
        CALBAND_LIST[$((bandctr++))]=${cal}
    else
        warning "Target ${source} and/or calibrator ${cal} not found"
        if [ ${ROBUST} != "TRUE" ]; then
            error "Missing data"
            exit 1
        fi
    fi
done

bandctr=0
for source in ${SUBBAND_LIST[@]}; do
    process_subband ${bandctr} ${source} ${CALBAND_LIST[$bandctr]} &
    let bandctr=${bandctr}+1
    child_pids[num]=$!
done
for pid in ${child_pids[*]}; do
    # Wait for all bands to be processed
    wait $pid
done

OLDIFS=${IFS}
IFS="," # We need to separate subbands with commas for NDPPP
cat >NDPPP.parset <<-EOF
    msin=[${SUBBAND_LIST[*]}]
    msin.missingdata=true
    msin.orderms=false
    msin.datacolumn=CORRECTED_DATA
    msin.baseline=[CR]S*&
    msout=${combined}
    steps=[]
EOF
IFS=${OLDIFS}

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
    ~martinez/plotting/asciistats.py -i ${combined} -r stats
    ~martinez/plotting/statsplot.py -i `pwd`/stats/${combined}.stats -o ${obs_id}
    for station in `grep True$ ${obs_id}.tab | cut -f2`; do
        BAD_STATION_LIST[$((ctr++))]=${station}
    done
fi

if [ ${BAD_STATION_LIST} ]; then
    echo "Flagging stations: ${BAD_STATION_LIST[*]}"
    FILTER=`echo "!${BAD_STATION_LIST[*]}" | sed -e's/ /;!/g'`
else
    FILTER=""
fi

msselect in=${combined} out=${OUTPUT_NAME} baseline=${FILTER} deep=True

echo "Data written to ${OUTPUT_NAME}."
echo "${0} finished at" `date`
