#
# Cookbook Name:: bcpc
# Recipe:: ceph-common
#
# Copyright 2015, Bloomberg Finance L.P.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe "bcpc::packages-openstack"

apt_repository "ceph" do
  uri node['bcpc']['repos']['ceph']
  distribution node['lsb']['codename']
  components ["main"]
  key "ceph-release.key"
  notifies :run, "execute[apt-get update]", :immediately
end

# delete the compromised Ceph signing key (17ED316D)
# if the new Ceph release key is installed (460F3994)
bash "remove-old-ceph-key" do
  code "apt-key del 17ED316D"
  only_if "apt-key list | grep -q 460F3994 && apt-key list | grep -q 17ED316D"
end

if platform?("debian", "ubuntu")
    include_recipe "bcpc::networking"
end

# install ceph-common separately to seed ceph user/group for Jewel
package 'ceph-common' do
  # use Ceph repository instead of UCA
  # UCA release looks like "trusty-proposed" or "trusty-updates"
  default_release 'trusty'
  action :upgrade
end

directory '/var/lib/ceph' do
  owner node['bcpc']['ceph']['user']
  group node['bcpc']['ceph']['group']
  mode  00750
end

directory '/var/run/ceph' do
  owner node['bcpc']['ceph']['user']
  group node['bcpc']['ceph']['group']
  mode  00770
end

%w(librados2 librbd1 libcephfs1 python-ceph ceph ceph-fs-common ceph-mds ceph-fuse).each do |pkg|
  package pkg do
    # use Ceph repository instead of UCA
    # UCA release looks like "trusty-proposed" or "trusty-updates"
    default_release 'trusty'
    action :upgrade
  end
end

ruby_block "initialize-ceph-common-config" do
    block do
        make_config('ceph-fs-uuid', %x[uuidgen -r].strip)
        make_config('ceph-mon-key', ceph_keygen)
    end
end

ruby_block 'write-ceph-mon-key' do
  block do
    keyring_file = '/etc/ceph/ceph.mon.keyring'
    %x[ ceph-authtool "#{keyring_file}" \
            --create-keyring \
            --name=mon. \
            --add-key="#{get_config('ceph-mon-key')}" \
            --cap mon 'allow *'
    ]
    # need to rechown to the Ceph user/group here
    %x[
      chown \
      #{node['bcpc']['ceph']['user']}:#{node['bcpc']['ceph']['group']} \
      #{keyring_file}
    ]
  end
  not_if { ::File.exist?('/etc/ceph/ceph.mon.keyring') }
end

template '/etc/ceph/ceph.conf' do
  source 'ceph.conf.erb'
  owner node['bcpc']['ceph']['user']
  group node['bcpc']['ceph']['group']
  mode  00644
  variables(:servers => get_head_nodes)
end

package 'libvirt-bin' do
  action :upgrade
end

directory "/var/run/ceph/guests/" do
  owner "libvirt-qemu"
  group "libvirtd"
  mode  "0755"
end

directory "/var/log/qemu/" do
  owner "libvirt-qemu"
  group "libvirtd"
  mode  "0755"
end

bcpc_cephconfig 'paxos_propose_interval' do
  value node["bcpc"]["ceph"]["rebalance"] ? "60" : "1"
  target "ceph-mon*"
end

bcpc_cephconfig 'osd_recovery_max_active' do
  value node["bcpc"]["ceph"]["rebalance"] ? "1" : "15"
  target "ceph-osd*"
end

bcpc_cephconfig 'osd_max_backfills' do
  value node["bcpc"]["ceph"]["rebalance"] ? "1" : "10"
  target "ceph-osd*"
end

bcpc_cephconfig 'osd_op_threads' do
  value node["bcpc"]["ceph"]["rebalance"] ? "10" : "2"
  target "ceph-osd*"
end

bcpc_cephconfig 'osd_recovery_op_priority' do
  value node["bcpc"]["ceph"]["rebalance"] ? "1" : "10"
  target "ceph-osd*"
end

bcpc_cephconfig 'osd_mon_report_interval_min' do
  value node["bcpc"]["ceph"]["rebalance"] ? "30" : "5"
  target "ceph-osd*"
end

# Script looks for mdsmap and if MDS is removed later then this script will need to be changed.
bash "wait-for-pgs-creating" do
    action :nothing
    user "root"
    code "sleep 1; while ceph -s | grep -v mdsmap | grep creating >/dev/null 2>&1; do echo Waiting for new pgs to create...; sleep 1; done"
end
