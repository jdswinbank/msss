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
CAL_MODEL=NONE
CAL_BEAM=NONE
declare -a BAD_STATION_LIST
declare -i ctr=0 # length of BAD_STATION_LIST

usage() {
    echo -e "Usage:"
    echo -e "    ${0} [options] <obs_id> <beam> <band> <skymodel> \n"
    echo -e "Processing of calibrator band:"
    echo -e "    -b   Calibrator beam (default: ${CAL_BEAM})"
    echo -e "    -m   Model for calibration of calibrator (default: ${CAL_MODEL})"
    echo -e "    -a   Parset for calibration of calibrator (default: ${CAL_PARSET})"
    echo -e "    -g   Parset applying gain calibration to target (default: ${CORRECT_PARSET})"
    echo -e "    -d   Dummy sky model for use in applying gains (default: ${DUMMY_MODEL})\n"
    echo -e "Other options with string arguments:"
    echo -e '    -o   Output filename (default: ${obs_id}_SAP00${beam}_BAND${band}.MS)'
    echo -e "    -p   Parset for phase-only calibration of target (default: ${PHASE_PARSET})"
    echo -e "    -s   Flag a specific station in the output\n"
    echo -e "Options which take no argument:"
    echo -e "    -c   Collect data prior to processing"
    echo -e "    -r   Robust mode: continue even if some subbands are not available"
    echo -e "    -f   Automatically identify & flag bad stations"
    echo -e "    -w   Overwrite output file if it already exists"
    echo -e "    -h   Display this message\n"
    echo -e "Example:"
    echo -e "    ${0} L42025 0 6 sky.model"
}

while getopts ":o:b:m:a:g:p:d:s:crfhw" opt; do
    case $opt in
        o)
            OUTPUT_NAME=${OPTARG}
            ;;
        b)
            cal_band=`printf %02d $((${OPTARG}*8))`
            ;;
        a)
            CAL_PARSET=${OPTARG}
            ;;
        m)
            CAL_MODEL=${OPTARG}
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
if [ $# -ne 4 ]; then
    usage
    exit 1
fi
obs_id=${1}
beam=${2}
band=${3}
skyModel=${4}

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

if [ ${COLLECT} = "TRUE" ]; then
    trap ERR # scp commands will fail by design!
    log "Collecting data"
    for node in {01..100} ; do
        echo locus$node
    done | xargs -n1 -P4 -Ihost scp -r host:/data/scratch/pipeline/${obs_id}*/*SB{${targ_band},${cal_band}}?_target_sub* . > log/collect.log 2>&1
    log "Data collected"
    trap failure ERR
fi

require_file() {
    if [ ! -f ${1} ]; then
        error "${1} does not exist"
        exit 1
    fi
}

require_file ${skyModel}
require_file ${PHASE_PARSET}
if [ ${cal_band} ]; then
    # Check for required inputs.
    require_file ${CAL_MODEL}
    require_file ${CAL_PARSET}
    require_file ${CORRECT_PARSET}
    require_file ${DUMMY_MODEL}

    # We'll need these sourcedbs a number of times, so might as well build them
    # once and reuse.
    log "Building calibrator sourcedb"
    test -d sky.calibrator && rm -rf sky.calibrator
    makesourcedb in=${CAL_MODEL} out=sky.calibrator format='<' > log/make_calibrator_sourcedb.log 2>&1

    log "Building dummy sourcedb"
    test -d sky.dummy && rm -rf sky.dummy
    makesourcedb in=${DUMMY_MODEL} out=sky.dummy format='<' > log/make_dummy_sourcedb.log 2>&1
fi

process_subband() {
    num=${1}
    source=${2}
    cal=${3}
    trap failure ERR # Enable error handler in subshell
    log "Starting work on ${source}"

    log "Calibrating ${cal}"
    calibrate-stand-alone --replace-parmdb --sourcedb sky.calibrator ${cal} ${CAL_PARSET} ${CAL_MODEL} > log/calibrate_cal_${num}.txt 2>&1

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

    if [ -d ${source} ]; then
        SUBBAND_LIST[${bandctr}]=${source}
    else
        warning "Target ${source} and not found"
        if [ ${ROBUST} != "TRUE" ]; then
            error "Missing data"
            exit 1
        fi
    fi

    if [ ${cal_band} ]; then
        if [ -d ${cal} ];  then
            CALBAND_LIST[${bandctr}]=${cal}
        else
            warning "Calibrator ${cal} and not found"
            if [ ${ROBUST} != "TRUE" ]; then
                error "Missing data"
                exit 1
            fi
        fi
    fi

    let bandctr=${bandctr}+1
done

if [ ${cal_band} ]; then
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
    mv SB*.pdf plots
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

mv calibrate-stand-alone*log log

if [ ${AUTO_FLAG_STATIONS} = "TRUE" ]; then
    log "Identifying bad stations"
    rm -rf stats
    ~martinez/plotting/asciistats.py -i ${WORK_NAME} -r stats > log/asciistats.txt
    ~martinez/plotting/statsplot.py -i `pwd`/stats/${WORK_NAME}.stats -o ${obs_id} > log/statsplot.txt
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
if [ -d ${WORK_NAME}/instrument ] && [ ! -d ${OUTPUT_NAME}/instrument ]; then
    cp -r ${WORK_NAME}/instrument ${OUTPUT_NAME}
fi
rm -rf ${WORK_NAME}

log "Data written to ${OUTPUT_NAME}"
log "${0} finished"
