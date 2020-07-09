#!/usr/bin/env sh
# set -x

get_abs_filename() {
  # $1 : relative filename
  filename=$1
  parentdir=$(dirname "${filename}")

  if [ -d "${filename}" ]; then
      echo "$(cd "${filename}" && pwd)"
  elif [ -d "${parentdir}" ]; then
    echo "$(cd "${parentdir}" && pwd)/$(basename "${filename}")"
  fi
}
RED_COLOR='\033[0;31m'
GREEN_COLOR='\033[0;32m'
YELLOW_COLOR='\033[0;33m'
NORMAL_COLOR='\033[0m'
echo_yellow ()
{
    echo "${YELLOW_COLOR}$*${NORMAL_COLOR}"
}

usage ()
{

  cat <<END_USAGE
Usage: ${0} {options}
    where {options} include:
    -c, --campaign) ** Required
        relative path to <campaign>.json file. 
    -r, --results
        relative path of where to publish results.
    -i, --iterations
        number of iterations to run
    --help
        Display general usage information
END_USAGE
}
exit_usage()
{
    echo "${RED_COLOR}$*${NORMAL_COLOR}"
    usage
    exit 1
}
campaignIterations=1
while ! test -z "${1}" ; 
do
    case "${1}" in
        -c|--campaign)
            shift
            if test -n "${1}" -a -f "${1}"; then
              campaignFile="${1}"
              campaignName=$(basename "${campaignFile}" | cut -f 1 -d '.')
              test -z "${resultsFile}" && resultsFile="results/${campaignName}.txt" && resultsFile=$(get_abs_filename ${resultsFile})
            else exit_usage "test file not found"; fi
            ;;
        -r|--results)
            test "-" = "$(echo ${2} | cut -c -1)" -o -z "${2}" && exit_usage "${1} option requires a valid parameter"
            shift
            resultsFile=$(get_abs_filename ${1})
            if test ! -f "${1}" ; then
              echo "results file will be created"
              mkdir -p "$(dirname ${resultsFile})"
              touch "${resultsFile}" ; fi
            ;;
        -i|--iterations) 
          test "-" = "$(echo ${2} | cut -c -1)" -o -z "${2}" && exit_usage "${1} option requires a valid parameter"
          shift ; campaignIterations=${1}; campaignIterations=$((campaignIterations+0)) ; shift ;;
        *)
            exit_usage "Unrecognized option"
            ;;
    esac
    shift
done
 
test -z "${campaignFile}" && exit_usage "must provide campaign file path"
test -z "${resultsFile}" && mkdir -p results && touch "${resultsFile}"

echo "results will be found at: ${resultsFile}"

get_jmProps(){
  if test "$(echo "$testsJson" | jq -r "${1}")" != null; then
    keys=$(echo "$testsJson" | jq -r "${1} | keys | .[]")
    allJmProps=""
    for key in $keys ; do
      jmProp="-J"
      value=$(echo "$testsJson" | jq -r "$1.$key")
      jmProp="${jmProp}${key}=${value}"
      allJmProps="${allJmProps} ${jmProp}"
      keyCount=$((keyCount+1))
    done
    echo "${allJmProps}"
  fi
}
validateJsonSchema(){
  test ! "$(command -v jsonschema)" && echo_yellow "INFO: install \`jsonschema\` with \`pip install jsonschema\` to validate campaign schema." && return 0
  echo "$testsJson" > "tmp.json"
  jsonschema -i tmp.json campaign.json.schema
  test $? -ne 0 && rm tmp.json && exit_usage "campaign json file is invalid"
  rm tmp.json
}

prep_campaign(){
  # echo "prepping campaign"
  # Set test-wide vars for script
  testsJson=$(envsubst < "$campaignFile")
  validateJsonSchema
  testDuration=$(echo "${testsJson}" | jq -r '.testDuration')
  cooldown=$(echo "${testsJson}" | jq -r '.cooldown')
  snapName=$(echo "${testsJson}" | jq -r '.campaignName')
  dashboardUrl=$(echo "${testsJson}" | jq -r '.dashboardUrl')
  test "${dashboardUrl}" = "null" && dashboardUrl="https://soak-monitoring.ping-devops.com/d/dgperfrw"
  numTests=$(echo "${testsJson}" | jq -r '.tests | length')
  echo "number of tests to run: $numTests"
  testIterations=$((numTests -1))

  ## Set test-wide vars for yaml
  JMETER_PROPERTIES="$(get_jmProps .jmeterProperties)"
  SERVER_PROFILE_URL=$(echo "${testsJson}" | jq -r ".serverProfileUrl")
  SERVER_PROFILE_PATH=$(echo "${testsJson}" | jq -r ".serverProfilePath")
  TEST_PATH=$(echo "${testsJson}" | jq -r ".testPath")
  NAMESPACE=$(echo "${testsJson}" | jq -r ".namespace")
  DURATION=$(echo "${testsJson}" | jq -r '.testDuration')
  SERVERNAME=$(echo "${testsJson}" | jq -r ".serverName")
  INFLUXDB=$(echo "${testsJson}" | jq -r ".influxdbHost")

  export JMETER_PROPERTIES NAMESPACE DURATION SERVERNAME SERVER_PROFILE_URL SERVER_PROFILE_PATH TEST_PATH INFLUXDB 
}
run_campaign(){
  #TODO: why it 
  test ! -d "yamls/tmp" && exit_usage "\n ERROR: please run from the directory this script is in \n"
  echo "clean leftovers"
  for f in yamls/tmp/* ; do 
    if test -f "${f}" ; then
      kubectl delete -f "${f}" --force --grace-period=0 > /dev/null 2>&1
      rm "${f}"
    fi
  done
  for i in $(seq 0 "${testIterations}"); do 
    numThreadGroups=$(echo "${testsJson}" | jq ".tests[$i].threadgroups | length")
    testId="$(echo "${testsJson}" | jq -r ".tests[$i].id")"
    tgIterations=$((numThreadGroups -1))
    for tg in $(seq 0 "${tgIterations}"); do 
      thisTg="$(echo "${testsJson}" | jq -r ".tests[$i].threadgroups[$tg]")"
      unset TG_JMETER_PROPERTIES
      TG_JMETER_PROPERTIES="$(get_jmProps .tests[$i].threadgroups[$tg].jmeterProperties)"
      THREADGROUP=$(echo "${thisTg}" | jq -r ".name")
      THREADS=$(echo "${thisTg}" | jq -r ".vars.threads") 
      REPLICAS=$(echo "${thisTg}" | jq -r ".vars.replicas") 
      HEAP=$(echo "${thisTg}" | jq -r ".vars.heap") 
      CPUS=$(echo "${thisTg}" | jq -r ".vars.cpus") 
      MEM=$(echo "${thisTg}" | jq -r ".vars.mem")
      # deprecated. default ramp set to 0
      # use jmeterProperties in threadgroup
      # RAMP=$(echo "${thisTg}" | jq -r ".vars.ramp")
      # test "${RAMP}" = "null" && RAMP=0
      # TODO: add random ramp possibility
      # deprecated
      # PURE=$(echo "${thisTg}" | jq -r ".vars.pure")
      export TG_JMETER_PROPERTIES THREADGROUP THREADS REPLICAS HEAP CPUS MEM RAMP

      test ! -f "yamls/tmp/test-${i}.yaml" && touch "yamls/tmp/test-${i}.yaml"
      testFile="yamls/tmp/test-${i}.yaml"
      
      numServer="$(echo "${testsJson}" | jq -r '.serverCount')"
      if test "${numServer}" != null ; then
        serverIterations=$((numServer -1))
        for pd in $(seq 0 "${serverIterations}"); do
          PDI="$pd"
          export PDI
              # TODO: make this dynamic, query the PD instances and figure our what zone they are in.. 
              case "${PDI}" in
                0)
                  ZONE="us-east-2a" ;;
                1)
                  ZONE="us-east-2b" ;;
                2)
                  ZONE="us-east-2c" ;;
              esac
              export ZONE
          if test "${HEAP}" = "null" ;then
            templateFile=yamls/xrate-pure-heapless.yaml.subst
            else
            templateFile=yamls/xrate-pure.yaml.subst
          fi
          envsubst < "${templateFile}" >> "${testFile}"
        done
      else 
          if test "${HEAP}" = "null" ;then
            templateFile=yamls/xrate-heapless.yaml.subst
            else
            templateFile=yamls/xrate.yaml.subst
          fi

        envsubst < "${templateFile}" >> "${testFile}"
      fi
    
    done
    
    kubectl delete -f "${testFile}"
    startTime=$(date +"%Y-%m-%dT%H:%M:%S.000Z")
    startTimeUtc=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    startEpoch=$(date -jf "%Y-%m-%dT%H:%M:%S.000Z" "${startTime}" +%s000)
    test "${?}" -ne 0 && startEpoch=$(date -d "${startTime}" +%s000)
    
    echo "test-$testId on: ${testFile} start time ${startTime}"
    kubectl apply -f "${testFile}"
      echo "letting test run ${testDuration}s"
      sleep "${testDuration}"

    endTime=$(date +"%Y-%m-%dT%H:%M:%S.000Z")
    endTimeUtc=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    endEpoch=$(date -jf "%Y-%m-%dT%H:%M:%S.000Z" "${endTime}" +%s000)
    test "${?}" -ne 0 && endEpoch=$(date -d "${endTime}" +%s000)
    echo "test-$testId on: ${testFile} end time ${endTime}"
    test ! -f "${resultsFile}" && touch "${resultsFile}"
    
      sleep 3  
    kubectl delete -f "${testFile}" > /dev/null 2>&1

    echo "test-$testId dashboard: ${dashboardUrl}?from=${startEpoch}&to=${endEpoch}" >> "${resultsFile}"
    
    # returns similar to: /dashboard/snapshot/D2Emm6lWdWM0mnsfSPjcZ8qsj4quN62o
    # echo "snapshotting results"
    # snapshotPath=$(./gen_snapshot.sh "${startTimeUtc}" "${endTimeUtc}" "${snapName}-${testId}")
    # test -z "${snapshotPath}" && exit 1
    # echo "test-$testId snapshot: https://soak-monitoring.ping-devops.com${snapshotPath}" >> "${resultsFile}"

    # Store Overall Campaign Results: 
    test "${i}" -eq 0 && campaignStartTimeUtc="${startTimeUtc}" && campaignStartEpoch="${startEpoch}"
    if test "${i}" -eq "${testIterations}" ; then
      campaignEndTimeUtc="${endTimeUtc}"
      campaignEndEpoch="${endEpoch}"
      echo "Campaign - $campaignFile dashboard: ${dashboardUrl}?orgId=1&from=${campaignStartEpoch}&to=${campaignEndEpoch}" >> "${resultsFile}"
      # snapshotPath=$(./gen_snapshot.sh "${campaignStartTimeUtc}" "${campaignEndTimeUtc}" "${campaignFile}-${testId}")
      # test -z "${snapshotPath}" && exit 1
      # echo "Campaign - $campaignFile snapshot: https://soak-monitoring.ping-devops.com${snapshotPath}" >> "${resultsFile}"
    fi

    # cooldown between tests
    echo "cooldown for ${cooldown}s"
    sleep "${cooldown}"
    rm "${testFile}"
    echo "end of this iteration"
  done
}

prep_campaign
echo "Starting campaign run for $campaignName with $campaignIterations iterations " >> "${resultsFile}"
cIteration=1
while [ $campaignIterations -gt 0 ]; do 
  echo "Start run $cIteration now:" >> "${resultsFile}"
  run_campaign
  campaignIterations=$((campaignIterations-1))
  cIteration=$((cIteration+1))
done
echo "Campaign: $campaignName completed" >> "${resultsFile}"