#!/usr/bin/env bats
# vim: ft=sh:sw=2:et

set -o pipefail

load os_helper
load foreman_helper

setup() {
  tForemanSetLang
  tSetOSVersion
  FOREMAN_VERSION=$(tForemanVersion)

  tPackageExists 'wget' || tPackageInstall 'wget'
  tPackageExists 'ruby' || tPackageInstall 'ruby'
  # disable firewall
  if tIsRedHatCompatible; then
    if tFileExists /usr/sbin/firewalld; then
      tServiceStop firewalld; tServiceDisable firewalld
    else
      tServiceStop iptables; tServiceDisable iptables
    fi
  fi

  tPackageExists curl || tPackageInstall curl
  if tIsRedHatCompatible; then
    tPackageExists yum-utils || tPackageInstall yum-utils
  fi
}

@test "stop puppet agent (if installed)" {
  tPackageExists "puppet" || skip "Puppet package not installed"
  tServiceStop puppet; tServiceDisable puppet
  true
}

@test "clean after puppet (if installed)" {
  [[ -d /var/lib/puppet/ssl ]] || skip "Puppet not installed, or SSL directory doesn't exist"
  rm -rf /var/lib/puppet/ssl
}

@test "make sure puppet not configured to other pm" {
  egrep -q "server\s*=" /etc/puppet/puppet.conf || skip "Puppet not installed, or 'server' not configured"
  sed -ir "s/^\s*server\s*=.*/server = $(hostname -f)/g" /etc/puppet/puppet.conf
}

@test "enable haveged (el7 only)" {
  if tIsRHEL 7; then
    tPackageExists "haveged" || tPackageInstall "haveged"
    tServiceStart haveged; tServiceEnable haveged
  fi
}

@test "run the installer" {
  foreman-installer --scenario katello --no-colors -v --disable-system-checks --foreman-admin-password=changeme
}

@test "run the installer once again" {
  if [ -e "/vagrant/katello-installer" ]; then
    cd /vagrant/katello-installer
    ./bin/foreman-installer --no-colors -v  --disable-system-checks
  else
    foreman-installer --no-colors -v --disable-system-checks
  fi
}

@test "wait 10 seconds" {
  sleep 10
}

@test "check web app is up" {
  curl -sk "https://localhost$URL_PREFIX/users/login" | grep -q login-form
}

@test "wake up puppet agent" {
  source ~/.bashrc
  puppet agent -t -v
}

@test "check web app is still up" {
  curl -sk "https://localhost$URL_PREFIX/users/login" | grep -q login-form
}

@test "install CLI (hammer)" {
  yum clean all
  tPackageExists foreman-cli || tPackageInstall foreman-cli
}

@test "check smart proxy is registered" {
  count=$(hammer --csv proxy list | wc -l)
  [ $count -gt 1 ]
}

@test "check host is registered" {
  [ x$FOREMAN_VERSION = "x1.3" ] && skip "Only supported on 1.4+"
  hammer host info --name $(hostname -f)
}

@test "Zzzz.... (120 sec)" {
  sleep 120
}
