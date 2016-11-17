#!/bin/bash

#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

# This function is taken from devstack.
function trueorfalse {
    local xtrace
    xtrace=$(set +o | grep xtrace)
    set +o xtrace

    local default=$1

    if [ -z $2 ]; then
        die $LINENO "variable to normalize required"
    fi
    local testval=${!2:-}

    case "$testval" in
        "1" | [yY]es | "YES" | [tT]rue | "TRUE" ) echo "True" ;;
        "0" | [nN]o | "NO" | [fF]alse | "FALSE" ) echo "False" ;;
        * )                                       echo "$default" ;;
    esac

    $xtrace
}

ENABLE_LOG_PRINTS=$(trueorfalse True ENABLE_LOG_PRINTS)
# The path from which the overcloud image will be downloaded
OVERCLOUD_IMAGE_URL_PATH=${OVERCLOUD_IMAGE_URL_PATH:-http://buildlogs.centos.org/centos/7/cloud/x86_64/tripleo_images/master/delorean/}

# Name of the overcloud image file name
OVERCLOUD_IMAGE_FILE=${OVERCOUD_IMAGE_NAME:-overcloud-full.qcow2}

# Name of the overcloud tar file name
OVERCLOUD_IMAGE_TAR_FILE=${OVERCLOUD_IMAGE_TAR_FILE:-overcloud-full.tar}

# The directory where the overcloud images to be stored
OVN_IMAGE_PATH=${OVN_IMAGE_PATH:-$PWD}

# Whether to build rpm packages for ovs or get it from repo
BUILD_OVS_RPM=$(trueorfalse True BUILD_OVS_RPM)

# The OVS repo file path
OVS_REPO_PATH=${OVS_REPO_PATH:-https://copr.fedorainfracloud.org/coprs/leifmadsen/ovs-master/repo/epel-7/leifmadsen-ovs-master-epel-7.repo}
OVS_REPO_NAME=${OVS_REPO_NAME:-leifmadsen-ovs-master}


TMP_OC_IMAGE_MOUNT_PATH=/tmp/oc_mnt

OC_KER_VERSION=""

log_print_True() {
    echo $@
}

log_print_False() {
    echo $@ > /dev/null
}

log_print() {
    log_print_${ENABLE_LOG_PRINTS} $@
}

download_overcloud_image() {
    wget $OVERCLOUD_IMAGE_URL_PATH/$OVERCLOUD_IMAGE_TAR_FILE
    return $?
}

extract_oc_file_if_required() {
    if ! is_oc_qcow2_file_present && is_oc_tar_file_present; then
        _pwd=$PWD
        cd $OVN_IMAGE_PATH
        log_print "Extracting the overcloud tar file $OVERCLOUD_IMAGE_TAR_FILE"
        tar xvf $OVERCLOUD_IMAGE_TAR_FILE
        cd $_pwd
    fi
}

is_oc_file_present() {
    [ -f $OVN_IMAGE_PATH/$OVERCLOUD_IMAGE_FILE ] ||  [ -f $OVN_IMAGE_PATH/$OVERCLOUD_IMAGE_TAR_FILE ]
}

is_oc_qcow2_file_present() {
    [ -f $OVN_IMAGE_PATH/$OVERCLOUD_IMAGE_FILE ]
}

is_oc_tar_file_present() {
    [ -f $OVN_IMAGE_PATH/$OVERCLOUD_IMAGE_TAR_FILE ]
}

install_packages() {
    log_print "Installing package(s) : $@"
    sudo yum install -y $@
}

mount_oc_image() {
    which guestmount
    if [ "$?" != "0" ]; then
        log_print "Please install libguestfs-tools"
        exit 1
    fi

    export LIBGUESTFS_BACKEND=direct
    log_print "Mounting overcloud image into $TMP_OC_IMAGE_MOUNT_PATH using guestmount"
    mkdir -p $TMP_OC_IMAGE_MOUNT_PATH
    guestmount -a $OVN_IMAGE_PATH/$OVERCLOUD_IMAGE_FILE -m /dev/sda $TMP_OC_IMAGE_MOUNT_PATH
    return $?
}

run_command_in_oc_image() {
    export LIBGUESTFS_BACKEND=direct
    args=$@
    log_print "Running the command "$args" in overcloud image"
    virt-customize -a $OVN_IMAGE_PATH/overcloud-full.qcow2 --run-command "$args"
}

install_ovn_packages_in_oc_image() {
    # Install the ovn packages
    cat << EOF > oc_install_packages.sh
#!/bin/bash
sudo wget $OVS_REPO_PATH --output-document=/etc/yum.repos.d/ovs.repo
sudo yum repolist
sudo yum remove -y openvswitch
sudo yum --enablerepo=$OVS_REPO_NAME install -y openvswitch
sudo yum --enablerepo=$OVS_REPO_NAME install -y openvswitch-ovn-common
sudo yum --enablerepo=$OVS_REPO_NAME install -y openvswitch-ovn-host
sudo yum --enablerepo=$OVS_REPO_NAME install -y openvswitch-ovn-central
sudo yum --enablerepo=$OVS_REPO_NAME install -y openvswitch-kmod
sudo yum install -y python-networking-ovn
sudo yum install -y indent
EOF

    mount_oc_image
    cp oc_install_packages.sh $TMP_OC_IMAGE_MOUNT_PATH/home/
    chmod 0755 $TMP_OC_IMAGE_MOUNT_PATH/home/oc_install_packages.sh
    guestunmount $TMP_OC_IMAGE_MOUNT_PATH
    rm -f oc_install_packages.sh
    run_command_in_oc_image "sudo /home/oc_install_packages.sh"
    run_command_in_oc_image "sudo rm -f /home/oc_install_packages.sh"
}

get_kernel_version_of_oc_image() {
    log_print "Getting the kernel version of the overcloud image"
    run_command_in_oc_image "uname -a | cut -d ' ' -f3 > /home/ker_ver.txt"
    sleep 1
    mount_oc_image
    OC_KER_VERSION=`cat $TMP_OC_IMAGE_MOUNT_PATH/home/ker_ver.txt`
    log_print "Kernel version of overcloud image is $OC_KER_VERSION"
    rm -f $TMP_OC_IMAGE_MOUNT_PATH/home/ker_ver.txt
    guestunmount $TMP_OC_IMAGE_MOUNT_PATH
}

generate_ovs_rpms_and_install_in_oc_image() {
    # First get the kernel version of the overcloud image
    get_kernel_version_of_oc_image
    log_print "Kernel version of overcloud image is $OC_KER_VERSION"
    if [[ "$OC_KER_VERSION" == "" ]]; then
        log_print "Couldn't get the kernel version from overcloud image. Using the host kernel version"
        OC_KER_VERSION=`uname -a | cut -d " " -f3`
    fi
    rm -rf $OVN_IMAGE_PATH/ovs
    git clone https://github.com/openvswitch/ovs.git
    yum install -y autoconf automake rpm-build libtool kernel-devel kernel-devel-$OC_KER_VERSION
    yum install -y openssl-devel desktop-file-utils
    yum install -y groff graphviz selinux-policy-devel libcap-ng-devel
    cd $OVN_IMAGE_PATH/ovs
    ./boot.sh
    ./configure --with-linux=/lib/modules/`uname -r`/build
    make rpm-fedora RPMBUILD_OPT="--without check"
    export OC_KER_VERSION=$OC_KER_VERSION
    make rpm-fedora-kmod RPMBUILD_OPT='-D "kversion ${OC_KER_VERSION}"'
    cd $OVN_IMAGE_PATH
    cat << EOF > $OVN_IMAGE_PATH/oc_install_packages.sh
#!/bin/bash
sudo yum remove -y openvswitch
sudo rpm -ihv /home/openvswitch-2*x86_64.rpm
sudo rpm -ihv /home/openvswitch-ovn-common-2*x86_64.rpm
sudo rpm -ihv /home/openvswitch-ovn-central-2*x86_64.rpm
sudo rpm -ihv /home/openvswitch-ovn-host-2*x86_64.rpm
sudo rpm -ihv /home/openvswitch-kmod-2*x86_64.rpm
sudo yum install -y python-networking-ovn
sudo yum install -y indent
EOF

    mount_oc_image
    log_print "Copying the RPMs to the overcloud image"
    cp $OVN_IMAGE_PATH/ovs/rpm/rpmbuild/RPMS/x86_64/*.rpm $TMP_OC_IMAGE_MOUNT_PATH/home/
    cp $OVN_IMAGE_PATH/oc_install_packages.sh $TMP_OC_IMAGE_MOUNT_PATH/home/
    chmod 0755 $TMP_OC_IMAGE_MOUNT_PATH/home/oc_install_packages.sh
    guestunmount $TMP_OC_IMAGE_MOUNT_PATH
    rm -f $OVN_IMAGE_PATH/oc_install_packages.sh
    log_print "Installing the required packages for OVN"
    run_command_in_oc_image "sudo /home/oc_install_packages.sh"
    run_command_in_oc_image "sudo rm -f /home/oc_install_packages.sh"
    run_command_in_oc_image "sudo rm -f /home/*.rpm"
}

# download_overcloud_image
if is_oc_file_present; then
    log_print "Overcloud file is already present.. Using it"
    extract_oc_file_if_required
else
    log_print "Downloading the overcloud image from $OVERCLOUD_IMAGE_URL_PATH"
    download_overcloud_image
    extract_oc_file_if_required
fi

if [[ "$BUILD_OVS_RPM" == "True" ]]; then
    generate_ovs_rpms_and_install_in_oc_image
    log_print "Need to generate RPMs for OVS"
else
    log_print "Getting the ovs packages from the repo $OVS_REPO_PATH"
    install_ovn_packages_in_oc_image
fi

log_print "OVN overcloud image is now ready. Please upload it"
