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
    syslog_netcat "Usage: cb_parboil.sh <load_profile> <load level> <load duration> <load_id>"
    exit 1
fi

update_app_errors 0 reset

PARBOIL_DIR=$(get_my_ai_attribute_with_default parboil_dir ~/parboil)
eval PARBOIL_DIR=${PARBOIL_DIR}
PARBOIL_EXECUTABLE=${PARBOIL_DIR}/parboil

CUDA_PATH=$(get_my_ai_attribute_with_default cuda_path /usr/local/cuda)
CUDA_LIB_PATH=$(get_my_ai_attribute_with_default cuda_lib_path /usr/local/cuda/lib64)
OPENCL_PATH=$(get_my_ai_attribute_with_default opencl_path /usr/local/cuda)
OPENCL_LIB_PATH=$(get_my_ai_attribute_with_default opencl_lib_path /usr/lib)

echo "CUDA_PATH=$CUDA_PATH" > $PARBOIL_DIR/common/Makefile.conf
echo "CUDA_PATH=$CUDA_LIB_PATH" >> $PARBOIL_DIR/common/Makefile.conf
echo "OPENCL_PATH=$OPENCL_PATH" >> $PARBOIL_DIR/common/Makefile.conf
echo "OPENCL_LIB_PATH=$OPENCL_LIB_PATH" >> $PARBOIL_DIR/common/Makefile.conf

echo $LOAD_PROFILE | grep ':'
if [[ $? -eq 0 ]]
then
	EXECUTABLE_NAME=$(echo $LOAD_PROFILE | cut -d ':' -f 1)
	EXECUTABLE_VERSION=$(echo $LOAD_PROFILE | cut -d ':' -f 2)
else
	EXECUTABLE_NAME=$LOAD_PROFILE
	EXECUTABLE_VERSION="base"
fi

if [[ $EXECUTABLE_NAME == "lbm" ]]
then
	if [[ $LOAD_LEVEL -eq 1 ]]
	then
		PROBLEM_SIZE="short"
	else
		PROBLEM_SIZE="long"
	fi
elif [[ $EXECUTABLE_NAME == "spmv" ]]
then
	if [[ $LOAD_LEVEL -eq 1 ]]
	then
		PROBLEM_SIZE="small"
	elif [[ $LOAD_LEVEL -eq 2 ]]
	then
		PROBLEM_SIZE="medium"		
	else
		PROBLEM_SIZE="large"
	fi
elif [[ $EXECUTABLE_NAME == "sgemm" ]]
then
	if [[ $LOAD_LEVEL -eq 1 ]]
	then
		PROBLEM_SIZE="small"
	else
		PROBLEM_SIZE="medium"
	fi	
elif [[ $EXECUTABLE_NAME == "histo" || $EXECUTABLE_NAME == "sad" ]]
then
	if [[ $LOAD_LEVEL -eq 1 ]]
	then
		PROBLEM_SIZE="default"
	else
		PROBLEM_SIZE="large"
	fi		
elif [[ $EXECUTABLE_NAME == "cutcp" ]]
then
	if [[ $LOAD_LEVEL -eq 1 ]]
	then
		PROBLEM_SIZE="default"
	else
		PROBLEM_SIZE="large"
	fi			
elif [[ $EXECUTABLE_NAME == "stencil" ]]
then
	if [[ $LOAD_LEVEL -eq 1 ]]
	then
		PROBLEM_SIZE="small"
	else
		PROBLEM_SIZE="default"
	fi
elif [[ $EXECUTABLE_NAME == "mri-q" ]]
then
	if [[ $LOAD_LEVEL -eq 1 ]]
	then
		PROBLEM_SIZE="small"
	else
		PROBLEM_SIZE="default"
	fi		
elif [[ $EXECUTABLE_NAME == "mri-gridding" ]]
then
	if [[ $LOAD_LEVEL -eq 1 ]]
	then
		PROBLEM_SIZE="small"
	else
		PROBLEM_SIZE="small"
	fi
elif [[ $EXECUTABLE_NAME == "bfs" ]]
then
	if [[ $LOAD_LEVEL -eq 1 ]]
	then
		PROBLEM_SIZE="NY"
	elif [[ $LOAD_LEVEL -eq 2 ]]
	then
		PROBLEM_SIZE="UT"
	elif [[ $LOAD_LEVEL -eq 3 ]]
	then
		PROBLEM_SIZE="1M"				
	else
		PROBLEM_SIZE="SF"
	fi
elif [[ $EXECUTABLE_NAME == "tpacf" ]]
then
	if [[ $LOAD_LEVEL -eq 1 ]]
	then
		PROBLEM_SIZE="small"
	elif [[ $LOAD_LEVEL -eq 2 ]]
	then
		PROBLEM_SIZE="medium"		
	else
		PROBLEM_SIZE="large"
	fi
else
	syslog_netcat "Unknown Parboil benchmark: ${LOAD_PROFILE}"
	exit 1
fi	

cd $PARBOIL_DIR 
./parboil clean $EXECUTABLE_NAME $EXECUTABLE_VERSION
./parboil compile $EXECUTABLE_NAME $EXECUTABLE_VERSION
if [[ $? -ne 0 ]]
then
	syslog_netcat "Error while compiling the \"$EXECUTABLE_VERSION\" version of \"$EXECUTABLE_NAME\"!"
    update_app_errors 1
fi

CMDLINE="./parboil run $EXECUTABLE_NAME $EXECUTABLE_VERSION $PROBLEM_SIZE"

syslog_netcat "Benchmarking parboil SUT: PARBOIL=${my_ip_addr} with LOAD_LEVEL=${LOAD_LEVEL} and LOAD_DURATION=${LOAD_DURATION} (LOAD_ID=${LOAD_ID} and LOAD_PROFILE=${LOAD_PROFILE})"

OUTPUT_FILE=$(mktemp)

execute_load_generator "${CMDLINE}" ${OUTPUT_FILE} ${LOAD_DURATION}
            
syslog_netcat "parboil run complete. Will collect and report the results"

cat ${OUTPUT_FILE} | grep " failed "
if [[ $? -eq 0 ]]
then
    update_app_errors 1
fi

io=$(cat ${OUTPUT_FILE} | grep IO | awk '{ print $3 }')
kernel=$(cat ${OUTPUT_FILE} | grep ^Kernel[[:space:]] | awk '{ print $3 }')
driver=$(cat ${OUTPUT_FILE} | grep Driver | awk '{ print $3 }')
compute=$(cat ${OUTPUT_FILE} | grep Compute | awk '{ print $3 }')
wall=$(cat ${OUTPUT_FILE} | grep Wall | awk '{ print $4 }')    
    
~/cb_report_app_metrics.py load_id:${LOAD_ID}:seqnum \
load_level:${LOAD_LEVEL}:load \
load_profile:${LOAD_PROFILE}:name \
load_duration:${LOAD_DURATION}:sec \
errors:$(update_app_errors):num \
completion_time:$(update_app_completiontime):sec \
datagen_time:$(update_app_datagentime):sec \
datagen_size:$(update_app_datagensize):records \
quiescent_time:$(update_app_quiescent):sec \
io_time:${io}:sec \
kernel_time:${kernel}:sec \
driver_time:${driver}:sec \
compute_time:${compute}:sec \
wall_time:${wall}:sec \
${SLA_RUNTIME_TARGETS}

rm ${OUTPUT_FILE}

exit 0
