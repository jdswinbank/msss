#!/usr/bin/env bash

# Originaly written by Tom Hassall
# Extensively modified by John Swinbank
# Updates by George Heald
#
# Bug reports, patches etc to <swinbank@transientskp.org>

# If anything goes wrong, we'll print a helpful(-ish) messge and exit
COLOUR_RED_BOLD=`tput setaf 1 && tput bold`
COLOUR_YELLOW_BOLD=`tput setaf 3 && tput bold`
COLOUR_GREEN_BOLD=`tput setaf 2 && tput bold`
COLOUR_NONE=`tput sgr0`

error()
{
    echo ${COLOUR_RED_BOLD}[`date +%FT%T` ERR ]${COLOUR_NONE} ${1}
}

warning()
{
    echo ${COLOUR_YELLOW_BOLD}[`date +%FT%T` WARN]${COLOUR_NONE} ${1}
}

log()
{
    echo ${COLOUR_GREEN_BOLD}[`date +%FT%T` INFO]${COLOUR_NONE} ${1}
}

failure()
{
    error "${BASH_COMMAND} failed"
    exit 1
}

# For safety reasons, failures are fatal
trap failure ERR

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
    echo -e '    -o   Output filename (default: ${obs_id}_SAP00${beam}_BAND${band}.MS)'
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
    echo -e "    ${0} L42025 0 6 sky.model 3c295.model"
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

log "Starting ${0}"

if [ ! ${OUTPUT_NAME} ]; then
    OUTPUT_NAME=${obs_id}_SAP00${beam}_BAND${band}.MS
fi
if [ -d ${OUTPUT_NAME} ]; then
    if [ ${CLOBBER} = "TRUE" ]; then
        log "Removing ${OUTPUT_NAME}"
        rm -rf ${OUTPUT_NAME}
    else
        error "${OUTPUT_NAME} already exists; aborting"
        exit 1
    fi
fi

WORK_NAME=${OUTPUT_NAME}.tmp
rm -rf ${WORK_NAME}

test -d log || mkdir log
test -d plots || mkdir plots

targ_band=`printf %02d $(($beam*8+$band))`
cal_band=`printf %02d $(($band+16))`

if [ ${COLLECT} = "TRUE" ]; then
    trap ERR # scp commands will fail by design!
    log "Collecting data"
    for node in {01..100} ; do
        echo locus$node
    done | xargs -n1 -P4 -Ihost scp -r host:/data/scratch/pipeline/${obs_id}*/*SB{${targ_band},${cal_band}}?_target_sub* . > log/collect.log 2>&1
    log "Data collected"
    trap failure ERR
fi

# We'll need these sourcedbs a number of times, so might as well build them
# once and reuse.
log "Building calibrator sourcedb"
test -d sky.calibrator && rm -rf sky.calibrator
makesourcedb in=${calModel} out=sky.calibrator format='<' > log/make_calibrator_sourcedb.log 2>&1

log "Building dummy sourcedb"
test -d sky.dummy && rm -rf sky.dummy
makesourcedb in=${DUMMY_MODEL} out=sky.dummy format='<' > log/make_dummy_sourcedb.log 2>&1

process_subband() {
    num=${1}
    source=${2}
    cal=${3}
    trap failure ERR # Enable error handler in subshell
    log "Starting work on ${source}"

    log "Calibrating ${cal}"
    calibrate-stand-alone --replace-parmdb --sourcedb sky.calibrator ${cal} ${CAL_PARSET} ${calModel} > log/calibrate_cal_${num}.txt 2>&1

    log "Zapping suspect points in ${cal}/instrument"
    ~swinbank/edit_parmdb/edit_parmdb.py --sigma=1 --auto ${cal}/instrument/ > log/edit_parmdb_${num}.txt 2>&1

    log "Making diagnostic plots for ${cal}/instrument"
    ~heald/bin/solplot.py -q -m -o SB${cal_band}${num} ${cal}/instrument/ > log/solplot_${num}.txt 2>&1

    log "Calibrating ${source}"
    calibrate-stand-alone --sourcedb sky.dummy --parmdb ${cal}/instrument ${source} ${CORRECT_PARSET} /home/hassall/MSSS/dummy.model > log/calibrate_transfer_${num}.txt 2>&1

    log "Finished ${source}"
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
if [ ${SUBBAND_LIST} ]; then
    for source in ${SUBBAND_LIST[@]}; do
        process_subband ${bandctr} ${source} ${CALBAND_LIST[$bandctr]} &
        child_pids[num]=$!
        let bandctr=${bandctr}+1
    done
    for pid in ${child_pids[*]}; do
        # Wait for all bands to be processed
        wait $pid
    done
else
    error "No data to process"
    exit 1
fi

log "Combining subbands"
OLDIFS=${IFS}
IFS="," # We need to separate subbands with commas for NDPPP
cat >NDPPP.parset <<-EOF
    msin=[${SUBBAND_LIST[*]}]
    msin.missingdata=true
    msin.orderms=false
    msin.datacolumn=CORRECTED_DATA
    msin.baseline=[CR]S*&
    msout=${WORK_NAME}
    steps=[]
EOF
IFS=${OLDIFS}
NDPPP NDPPP.parset > log/ndppp_log.txt 2>&1

log "Removing RFI"
rficonsole -indirect-read ${WORK_NAME} > log/rficonsole.txt 2>&1

log "Starting phase-only calibration of ${WORK_NAME}"
calibrate-stand-alone -f ${WORK_NAME} ${PHASE_PARSET} ${skyModel} > log/calibrate_phaseonly.txt 2>&1
log "Finished phase-only calibration"

mv SB*.pdf plots
mv calibrate-stand-alone*log log

if [ ${AUTO_FLAG_STATIONS} = "TRUE" ]; then
    log "Flagging bad stations"
    ~martinez/plotting/asciistats.py -i ${WORK_NAME} -r stats
    ~martinez/plotting/statsplot.py -i `pwd`/stats/${WORK_NAME}.stats -o ${obs_id}
    for station in `grep True$ ${obs_id}.tab | cut -f2`; do
        BAD_STATION_LIST[$((ctr++))]=${station}
    done
fi

if [ ${BAD_STATION_LIST} ]; then
    log "Flagging stations: ${BAD_STATION_LIST[*]}"
    FILTER=`echo "!${BAD_STATION_LIST[*]}" | sed -e's/ /;!/g'`
else
    FILTER=""
fi

msselect in=${WORK_NAME} out=${OUTPUT_NAME} baseline=${FILTER} deep=True > log/msselect.log 2>&1
rm -rf ${WORK_NAME}

log "Data written to ${OUTPUT_NAME}"
log "${0} finished"
