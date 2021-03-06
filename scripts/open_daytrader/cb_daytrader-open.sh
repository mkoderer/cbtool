#!/usr/bin/env bash

#/*******************************************************************************
# Copyright (c) 2012 IBM Corp.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#/*******************************************************************************

source $(echo $0 | sed -e "s/\(.*\/\)*.*/\1.\//g")/cb_common.sh

LOAD_PROFILE=$1
LOAD_LEVEL=$2
LOAD_DURATION=$3
LOAD_ID=$4
SLA_RUNTIME_TARGETS=$5    
    
if [[ -z "$LOAD_PROFILE" || -z "$LOAD_LEVEL" || -z "$LOAD_DURATION" || -z "$LOAD_ID" ]]
then
    syslog_netcat "Usage: cb_daytrader.sh <load_profile> <load level> <load duration> <load_id>"
    exit 1
fi

LLXLD=$(echo "$LOAD_LEVEL * $LOAD_DURATION" | bc)

if [[ $LLXLD -lt 60 ]]
then
    syslog_netcat "The load level ($LOAD_LEVEL) x load duration ($LOAD_DURATION) product (${LLXLD}) is smaller than 60. Increasing the load duration to 60"
    LOAD_DURATION=60    
fi
    
if [[ ${LOAD_ID} == "1" ]]
then
    GENERATE_DATA="true"
else
    GENERATE_DATA=`get_my_ai_attribute_with_default regenerate_data true`
fi

set_java_home
    
GERONIMO_IPS=`get_ips_from_role geronimo`
MYSQL_IPS=`get_ips_from_role mysql`
IS_LOAD_BALANCED=`get_my_ai_attribute load_balancer`
IS_LOAD_BALANCED=`echo ${IS_LOAD_BALANCED} | tr '[:upper:]' '[:lower:]'`
LOAD_GENERATOR_TARGET_IP=`get_my_ai_attribute load_generator_target_ip`
NR_QUOTES=`get_my_ai_attribute_with_default nr_quotes 4000`
NR_USERS=`get_my_ai_attribute_with_default nr_quotes 1500`
APP_COLLECTION=`get_my_ai_attribute_with_default app_collection lazy`
PERIODIC_MEASUREMENTS=`get_my_ai_attribute_with_default periodic_measurements false`

GERONIMO_IPS_CSV=`echo ${GERONIMO_IPS_CSV} | sed ':a;N;$!ba;s/\n/, /g'`
MYSQL_IPS_CSV=`echo ${MYSQL_IPS_CSV} | sed ':a;N;$!ba;s/\n/, /g'`

if [ x"${IS_LOAD_BALANCED}" == x"true" ]
then
    LOAD_BALANCER_IP=`get_ips_from_role lb`
    syslog_netcat "Benchmarking daytrader SUT: LOAD_BALANCER=${LOAD_BALANCER_IP} -> GERONIMO_SERVERS=${GERONIMO_IPS_CSV} -> MYSQL_SERVERS=${MYSQL_IPS_CSV} with LOAD_LEVEL=${LOAD_LEVEL} and LOAD_DURATION=${LOAD_DURATION} (LOAD_ID=${LOAD_ID} and LOAD_PROFILE=${LOAD_PROFILE})"
else
    syslog_netcat "Benchmarking daytrader SUT: GERONIMO_SERVERS=${GERONIMO_IPS_CSV} -> MYSQL_SERVERS=${MYSQL_IPS_CSV} with LOAD_LEVEL=${LOAD_LEVEL} and LOAD_DURATION=${LOAD_DURATION} (LOAD_ID=${LOAD_ID})"
fi

update_app_errors 0 reset

GENERATE_DATA=$(echo $GENERATE_DATA | tr '[:upper:]' '[:lower:]')

if [[ ${GENERATE_DATA} == "true" ]]
then
    OUTPUT_FILE=$(mktemp)

    log_output_command=$(get_my_ai_attribute log_output_command)
    log_output_command=$(echo ${log_output_command} | tr '[:upper:]' '[:lower:]')

    START_GENERATION=$(get_time)

    DT_BUILD_CMD=~/build_daytrader_db.py
    eval DT_BUILD_CMD=${DT_BUILD_CMD}
                        
    syslog_netcat "The value of the parameter \"GENERATE_DATA\" is \"true\". Will generate data for the DayTrader load profile \"${LOAD_PROFILE}\"" 
    command_line="${DT_BUILD_CMD} --apphost $LOAD_GENERATOR_TARGET_IP --maxuser $NR_USERS --maxquote $NR_QUOTES --dbhost $MYSQL_IPS --load_id $LOAD_ID"
    syslog_netcat "Command line is: ${command_line}"
    if [[ x"${log_output_command}" == x"true" ]]
    then
        syslog_netcat "Command output will be shown"
        $command_line 2>&1 | while read line ; do
            syslog_netcat "$line"
            echo $line >> $OUTPUT_FILE
        done
        ERROR=$?        
    else
        syslog_netcat "Command output will NOT be shown"
        $command_line 2>&1 >> $OUTPUT_FILE
        ERROR=$?
    fi
    END_GENERATION=$(get_time)
    update_app_errors $ERROR        

    DATA_GENERATION_TIME=$(expr ${END_GENERATION} - ${START_GENERATION})
    update_app_datagentime ${DATA_GENERATION_TIME}
    update_app_datagensize $(echo "$NR_USERS + $NR_QUOTES" | bc)
else
    syslog_netcat "The value of the parameter \"GENERATE_DATA\" is \"false\". Will bypass data generation for the hadoop load profile \"${LOAD_PROFILE}\""
    
fi

DT_CONFIG=~/rain-workload-toolkit/config/rain.config.daytrader.json
DT_PROFILE=~/rain-workload-toolkit/config/profiles.config.daytrader_simple.json
DT_RAIN=~/rain-workload-toolkit/rain.jar
DT_WKLOAD=~/rain-workload-toolkit/workloads/daytrader.jar
eval DT_CONFIG=${DT_CONFIG}
eval DT_PROFILE=${DT_PROFILE}
eval DT_RAIN=${DT_RAIN}
eval DT_WKLOAD=${DT_WKLOAD}

pushd ~/rain-workload-toolkit
ant package
ant package-daytrader
popd

sudo sed -i "s^\"profiles\":.*,^\"profiles\": \"${DT_PROFILE}\",^g" ${DT_CONFIG}
sudo sed -i "s^\"duration\":.*,^\"duration\": ${LOAD_DURATION},^g" ${DT_CONFIG}
sudo sed -i "s^\"hostname\":.*,^\"hostname\": \"${LOAD_GENERATOR_TARGET_IP}\",^g" ${DT_PROFILE}
sudo sed -i "s^\"interval\":.*,^\"interval\": ${LOAD_DURATION},^g" ${DT_PROFILE}
sudo sed -i "s^\"users\":.*,^\"users\": ${LOAD_LEVEL},^g" ${DT_PROFILE}

CMDLINE="java -Xmx1g -Xms256m -cp $DT_RAIN:$DT_WKLOAD radlab.rain.Benchmark $DT_CONFIG"

OUTPUT_FILE=$(mktemp)

execute_load_generator "${CMDLINE}" ${OUTPUT_FILE} ${LOAD_DURATION}

syslog_netcat "daytrader-run complete. Will collect and report the results"
tp=`cat ${OUTPUT_FILE} | grep "Effective load (requests/sec)" | awk '{ print $8 }' | tr -d ' '`
lat=`echo "\`cat ${OUTPUT_FILE} | grep "Average operation response time (s)" | awk '{ print $9 }' | tr -d ' '\` * 1000" | bc`
opok=`cat ${OUTPUT_FILE} | grep "Operations successfully completed" | awk '{ print $8 }'`
operr=`cat ${OUTPUT_FILE} | grep "Operations failed" | awk '{ print $7 }'`
~/cb_report_app_metrics.py load_id:${LOAD_ID}:seqnum \
load_level:${LOAD_LEVEL}:load \
load_profile:${LOAD_PROFILE}:name \
load_duration:${LOAD_DURATION}:sec \
errors:$(update_app_errors):num \
completion_time:$(update_app_completiontime):sec \
datagen_time:$(update_app_datagentime):sec \
datagen_size:$(update_app_datagensize):records \
throughput:$tp:tps \
latency:$lat:msec \
operations_ok:$opok:num \
operations_err:$operr:num \
${SLA_RUNTIME_TARGETS}

rm ${OUTPUT_FILE}

exit 0
exit 0