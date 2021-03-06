#!/bin/sh
#
# rbd_mirror.sh - test rbd-mirror daemon
#
# The scripts starts two ("local" and "remote") clusters using mstart.sh script,
# creates a temporary directory, used for cluster configs, daemon logs, admin
# socket, temporary files, and launches rbd-mirror daemon.
#
# There are several env variables useful when troubleshooting a test failure:
#
#  RBD_MIRROR_NOCLEANUP - if not empty, don't run the cleanup (stop processes,
#                         destroy the clusters and remove the temp directory)
#                         on exit, so it is possible to check the test state
#                         after failure.
#  RBD_MIRROR_TEMDIR    - use this path when creating the temporary directory
#                         (should not exist) instead of running mktemp(1).
#
# The cleanup can be done as a separate step, running the script with
# `cleanup ${RBD_MIRROR_TEMDIR}' arguments.
#
# Note, as other workunits tests, rbd_mirror.sh expects to find ceph binaries
# in PATH.
#
# Thus a typical troubleshooting session:
#
# From Ceph src dir (CEPH_SRC_PATH), start the test in NOCLEANUP mode and with
# TEMPDIR pointing to a known location:
#
#   cd $CEPH_SRC_PATH
#   PATH=$CEPH_SRC_PATH:$PATH
#   RBD_MIRROR_NOCLEANUP=1 RBD_MIRROR_TEMDIR=/tmp/tmp.rbd_mirror \
#     ../qa/workunits/rbd/rbd_mirror.sh
#
# After the test failure cd to TEMPDIR and check the current state:
#
#   cd /tmp/tmp.rbd_mirror
#   ls
#   less rbd-mirror.local.local.<pid>.log
#   ceph --cluster remote -s
#   ceph --cluster local -s
#   rbd --cluster remote -p mirror ls
#   rbd --cluster remote -p mirror journal status --image test
#   ceph --admin-daemon rbd-mirror.asok help
#   ...
#
# Eventually, run the cleanup:
#
#   cd $CEPH_SRC_PATH
#   ../qa/workunits/rbd/rbd_mirror.sh cleanup /tmp/tmp.rbd_mirror
#

LOC_DAEMON=local
RMT_DAEMON=remote
LOC_CLUSTER=local
RMT_CLUSTER=remote
POOL=mirror
SRC_DIR=$(readlink -f $(dirname $0)/../../../src)
TEMPDIR=

#
# Functions
#

daemon_asok_file()
{
    local daemon=$1
    local cluster=$2

    echo "${TEMPDIR}/rbd-mirror.${daemon}.${cluster}.asok"
}

daemon_pid_file()
{
    local daemon=$1

    echo "${TEMPDIR}/rbd-mirror.${daemon}.pid"
}

setup()
{
    local c
    trap cleanup INT TERM EXIT

    if [ -n "${RBD_MIRROR_TEMDIR}" ]; then
	mkdir "${RBD_MIRROR_TEMDIR}"
	TEMPDIR="${RBD_MIRROR_TEMDIR}"
    else
	TEMPDIR=`mktemp -d`
    fi

    cd ${SRC_DIR}
    ./mstart.sh ${LOC_CLUSTER} -n
    ./mstart.sh ${RMT_CLUSTER} -n

    ln -s $(readlink -f run/${LOC_CLUSTER}/ceph.conf) \
       ${TEMPDIR}/${LOC_CLUSTER}.conf
    ln -s $(readlink -f run/${RMT_CLUSTER}/ceph.conf) \
       ${TEMPDIR}/${RMT_CLUSTER}.conf

    cd ${TEMPDIR}

    start_mirror ${LOC_DAEMON} ${LOC_CLUSTER}

    ceph --cluster ${LOC_CLUSTER} osd pool create ${POOL} 64 64
    ceph --cluster ${RMT_CLUSTER} osd pool create ${POOL} 64 64

    rbd --cluster ${LOC_CLUSTER} mirror pool enable ${POOL} pool
    rbd --cluster ${RMT_CLUSTER} mirror pool enable ${POOL} pool

    rbd --cluster ${LOC_CLUSTER} mirror pool peer add ${POOL} ${RMT_CLUSTER}
    rbd --cluster ${RMT_CLUSTER} mirror pool peer add ${POOL} ${LOC_CLUSTER}
}

cleanup()
{
    test  -n "${RBD_MIRROR_NOCLEANUP}" && return

    set +e

    stop_mirror ${LOC_DAEMON}
    stop_mirror ${RMT_DAEMON}

    cd ${SRC_DIR}

    ./mstop.sh ${LOC_CLUSTER}
    ./mstop.sh ${RMT_CLUSTER}

    rm -Rf ${TEMPDIR}
}

start_mirror()
{
    local daemon=$1
    local cluster=$2

    rbd-mirror \
	--cluster ${cluster} \
	--pid-file=$(daemon_pid_file "${daemon}") \
	--log-file=${TEMPDIR}/rbd-mirror.${daemon}.\$cluster.\$pid.log \
	--admin-socket=${TEMPDIR}/rbd-mirror.${daemon}.\$cluster.asok \
	--debug-rbd=30 --debug-journaler=30 \
	--debug-rbd_mirror=30 \
	--daemonize=true
}

stop_mirror()
{
    local daemon=$1

    local pid
    pid=$(cat $(daemon_pid_file "${daemon}") 2>/dev/null) || :
    if [ -n "${pid}" ]
    then
	kill ${pid}
	for s in 1 2 4 8 16 32; do
	    sleep $s
	    ps auxww | awk -v pid=${pid} '$2 == pid {print; exit 1}' && break
	done
	ps auxww | awk -v pid=${pid} '$2 == pid {print; exit 1}'
    fi
    rm -f $(daemon_asok_file "${daemon}" "${LOC_CLUSTER}")
    rm -f $(daemon_asok_file "${daemon}" "${RMT_CLUSTER}")
    rm -f $(daemon_pid_file "${daemon}")
}

flush()
{
    local daemon=$1
    local image=$2

    local asok_file=$(daemon_asok_file "${daemon}" "${daemon}")
    test -n "${asok_file}"

    ceph --admin-daemon ${asok_file} \
	 rbd mirror flush ${POOL}/${image}
}

test_image_replay_state()
{
    local daemon=$1
    local cluster=$2
    local image=$3
    local test_state=$4
    local current_state=stopped

    local asok_file=$(daemon_asok_file "${daemon}" "${cluster}")
    test -n "${asok_file}"

    ceph --admin-daemon ${asok_file} help |
	fgrep "\"rbd mirror status ${POOL}/${image}\"" && current_state=started
    test "${test_state}" = "${current_state}"
}

wait_for_image_replay_state()
{
    local daemon=$1
    local cluster=$2
    local image=$3
    local state=$4
    local s

    # TODO: add a way to force rbd-mirror to update replayers
    for s in 1 2 4 8 8 8 8 8 8 8 8 16 16; do
	sleep ${s}
	test_image_replay_state "${daemon}" "${cluster}" "${image}" "${state}" && return 0
    done
    return 1
}

wait_for_image_replay_started()
{
    local daemon=$1
    local cluster=$2
    local image=$3

    wait_for_image_replay_state "${daemon}" "${cluster}" "${image}" started
}

wait_for_image_replay_stopped()
{
    local daemon=$1
    local cluster=$2
    local image=$3

    wait_for_image_replay_state "${daemon}" "${cluster}" "${image}" stopped
}

get_position()
{
    local cluster=$1
    local image=$2
    local id_regexp=$3

    # Parse line like below, looking for the first position
    # [id=, commit_position=[positions=[[object_number=1, tag_tid=3, entry_tid=9], [object_number=0, tag_tid=3, entry_tid=8], [object_number=3, tag_tid=3, entry_tid=7], [object_number=2, tag_tid=3, entry_tid=6]]]]

    local status_log=${TEMPDIR}/${RMT_CLUSTER}-${POOL}-${image}.status
    rbd --cluster ${cluster} -p ${POOL} journal status --image ${image} |
	tee ${status_log} >&2
    sed -nEe 's/^.*\[id='"${id_regexp}"',.*positions=\[\[([^]]*)\],.*$/\1/p' \
	${status_log}
}

get_master_position()
{
    local cluster=$1
    local image=$2

    get_position "${cluster}" "${image}" ''
}

get_mirror_position()
{
    local cluster=$1
    local image=$2

    get_position "${cluster}" "${image}" '..*'
}

wait_for_replay_complete()
{
    local daemon=$1
    local cluster=$2
    local image=$3
    local s master_pos mirror_pos

    for s in 0.2 0.4 0.8 1.6 2 2 4 4 8 8 16 16; do
	sleep ${s}
	flush "${daemon}" "${image}"
	master_pos=$(get_master_position "${cluster}" "${image}")
	mirror_pos=$(get_mirror_position "${cluster}" "${image}")
	test -n "${master_pos}" -a "${master_pos}" = "${mirror_pos}" && return 0
    done
    return 1
}

create_image()
{
    local cluster=$1
    local image=$2

    rbd --cluster ${cluster} -p ${POOL} create --size 128 \
	--image-feature exclusive-lock --image-feature journaling ${image}
}

create_remote_image()
{
    local image=$1

    create_image ${RMT_CLUSTER} ${image}
}

create_local_image()
{
    local image=$1

    create_image ${LOC_CLUSTER} ${image}
}

write_image()
{
    local cluster=$1
    local image=$2
    local count=$3

    rbd --cluster ${cluster} -p ${POOL} bench-write ${image} \
	--io-size 4096 --io-threads 1 --io-total $((4096 * count)) \
	--io-pattern rand
}

compare_images()
{
    local image=$1

    local rmt_export=${TEMPDIR}/${RMT_CLUSTER}-${POOL}-${image}.export
    local loc_export=${TEMPDIR}/${LOC_CLUSTER}-${POOL}-${image}.export

    rm -f ${rmt_export} ${loc_export}
    rbd --cluster ${RMT_CLUSTER} -p ${POOL} export ${image} ${rmt_export}
    rbd --cluster ${LOC_CLUSTER} -p ${POOL} export ${image} ${loc_export}
    cmp ${rmt_export} ${loc_export}
}

demote_image()
{
    local cluster=$1
    local image=$2

    rbd --cluster=${cluster} mirror image demote ${POOL}/${image}
}

promote_image()
{
    local cluster=$1
    local image=$2

    rbd --cluster=${cluster} mirror image promote ${POOL}/${image}
}

#
# Main
#

if [ "$1" = clean ]; then
    TEMPDIR=$2

    if [ -z "${TEMPDIR}" -a -n "${RBD_MIRROR_TEMDIR}" ]; then
	TEMPDIR="${RBD_MIRROR_TEMDIR}"
    fi

    test -n "${TEMPDIR}"

    RBD_MIRROR_NOCLEANUP=

    cleanup
    exit
fi

set -xe

setup

echo "TEST: add image and test replay"
image=test
create_remote_image ${image}
wait_for_image_replay_started ${LOC_DAEMON} ${LOC_CLUSTER} ${image}
write_image ${RMT_CLUSTER} ${image} 100
wait_for_replay_complete ${LOC_DAEMON} ${RMT_CLUSTER} ${image}
compare_images ${image}

echo "TEST: stop mirror, add image, start mirror and test replay"
stop_mirror ${LOC_DAEMON}
image1=test1
create_remote_image ${image1}
write_image ${RMT_CLUSTER} ${image1} 100
start_mirror ${LOC_DAEMON} ${LOC_CLUSTER}
wait_for_image_replay_started ${LOC_DAEMON} ${LOC_CLUSTER} ${image1}
wait_for_replay_complete ${LOC_DAEMON} ${RMT_CLUSTER} ${image1}
compare_images ${image1}

echo "TEST: test the first image is replaying after restart"
write_image ${RMT_CLUSTER} ${image} 100
wait_for_replay_complete ${LOC_DAEMON} ${RMT_CLUSTER} ${image}
compare_images ${image}

echo "TEST: failover and failback"
start_mirror ${RMT_DAEMON} ${RMT_CLUSTER}

# failover
demote_image ${RMT_CLUSTER} ${image}
wait_for_image_replay_stopped ${LOC_DAEMON} ${LOC_CLUSTER} ${image}
promote_image ${LOC_CLUSTER} ${image}
wait_for_image_replay_started ${RMT_DAEMON} ${RMT_CLUSTER} ${image}
write_image ${LOC_CLUSTER} ${image} 100
wait_for_replay_complete ${RMT_DAEMON} ${LOC_CLUSTER} ${image}
compare_images ${image}

# failback
demote_image ${LOC_CLUSTER} ${image}
wait_for_image_replay_stopped ${RMT_DAEMON} ${RMT_CLUSTER} ${image}
promote_image ${RMT_CLUSTER} ${image}
wait_for_image_replay_started ${LOC_DAEMON} ${LOC_CLUSTER} ${image}
write_image ${RMT_CLUSTER} ${image} 100
wait_for_replay_complete ${LOC_DAEMON} ${RMT_CLUSTER} ${image}
compare_images ${image}

echo OK
