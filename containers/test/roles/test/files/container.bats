#!/usr/bin/env bats
# vim: ft=sh:sw=2:et

set -o pipefail

load forklift/bats/os_helper
load forklift/bats/foreman_helper
load forklift/bats/fixtures/content

setup() {
  tSetOSVersion
}

# Ensure we have at least one organization present so that the test organization
# can be deleted at the end
@test "Create an Empty Organization" {
  run hammer --verify-ssl false organization info --name "Empty Organization"

  if [ $status != 0 ]; then
    hammer --verify-ssl false organization create --name="Empty Organization" | grep -q "Organization created"
  fi
}

@test "create an Organization" {
  hammer --verify-ssl false organization create --name="${ORGANIZATION}" | grep -q "Organization created"
}

@test "create a product" {
  hammer --verify-ssl false product create --organization="${ORGANIZATION}" --name="${PRODUCT}" | grep -q "Product created"
}

@test "create package repository" {
  hammer --verify-ssl false repository create --organization="${ORGANIZATION}" \
    --product="${PRODUCT}" --content-type="yum" --name "${YUM_REPOSITORY}" \
    --url https://jlsherrill.fedorapeople.org/fake-repos/needed-errata/ | grep -q "Repository created"
}

@test "upload package" {
  (cd /tmp; curl -O https://repos.fedorapeople.org/repos/pulp/pulp/demo_repos/test_errata_install/animaniacs-0.1-1.noarch.rpm)
  hammer --verify-ssl false repository upload-content --organization="${ORGANIZATION}"\
    --product="${PRODUCT}" --name="${YUM_REPOSITORY}" --path="/tmp/animaniacs-0.1-1.noarch.rpm" | grep -q "Successfully uploaded"
}

@test "sync repository" {
  hammer --verify-ssl false repository synchronize --organization="${ORGANIZATION}" \
    --product="${PRODUCT}" --name="${YUM_REPOSITORY}"
}

@test "create puppet repository" {
  hammer --verify-ssl false repository create --organization="${ORGANIZATION}" \
    --product="${PRODUCT}" --content-type="puppet" --name "${PUPPET_REPOSITORY}" | grep -q "Repository created"
}

@test "upload puppet module" {
  curl -o /tmp/stbenjam-dummy-0.2.0.tar.gz https://forgeapi.puppetlabs.com/v3/files/stbenjam-dummy-0.2.0.tar.gz
  tFileExists /tmp/stbenjam-dummy-0.2.0.tar.gz && hammer --verify-ssl false repository upload-content \
    --organization="${ORGANIZATION}" --product="${PRODUCT}" --name="${PUPPET_REPOSITORY}" \
    --path="/tmp/stbenjam-dummy-0.2.0.tar.gz" | grep -q "Successfully uploaded"
}

@test "create lifecycle environment" {
  hammer --verify-ssl false lifecycle-environment create --organization="${ORGANIZATION}" \
    --prior="Library" --name="${LIFECYCLE_ENVIRONMENT}" | grep -q "Environment created"
}

@test "create content view" {
  hammer --verify-ssl false content-view create --organization="${ORGANIZATION}" \
    --name="${CONTENT_VIEW}" | grep -q "Content view created"
}

@test "add repo to content view" {
  repo_id=$(hammer --verify-ssl false repository list --organization="${ORGANIZATION}" \
    | grep ${YUM_REPOSITORY} | cut -d\| -f1 | egrep -i '[0-9]+')
  hammer --verify-ssl false content-view add-repository --organization="${ORGANIZATION}" \
    --name="${CONTENT_VIEW}" --repository-id=$repo_id | grep -q "The repository has been associated"
}

@test "publish content view" {
  hammer --verify-ssl false content-view publish --organization="${ORGANIZATION}" \
    --name="${CONTENT_VIEW}"
}

@test "promote content view" {
  hammer --verify-ssl false content-view version promote  --organization="${ORGANIZATION}" \
    --content-view="${CONTENT_VIEW}" --to-lifecycle-environment="${LIFECYCLE_ENVIRONMENT}" --from-lifecycle-environment="Library"
}

@test "create activation key" {
  hammer --verify-ssl false activation-key create --organization="${ORGANIZATION}" \
    --name="${ACTIVATION_KEY}" --content-view="${CONTENT_VIEW}" --lifecycle-environment="${LIFECYCLE_ENVIRONMENT}" \
    --unlimited-hosts | grep -q "Activation key created"
}

@test "disable auto-attach" {
  hammer --verify-ssl false activation-key update --organization="${ORGANIZATION}" \
    --name="${ACTIVATION_KEY}" --auto-attach=false
}

@test "add subscription to activation key" {
  sleep 10
  activation_key_id=$(hammer --verify-ssl false activation-key info --organization="${ORGANIZATION}" \
    --name="${ACTIVATION_KEY}" | grep ID | tr -d ' ' | cut -d':' -f2)
  subscription_id=$(hammer --verify-ssl false subscription list --organization="${ORGANIZATION}" \
    | grep "${PRODUCT}" | cut -d\| -f1 | tr -d ' ')
  hammer --verify-ssl false activation-key add-subscription --id=$activation_key_id \
    --subscription-id=$subscription_id | grep -q "Subscription added to activation key"
}

@test "install subscription manager" {
  if tIsRHEL 6; then
    cat > /etc/yum.repos.d/subscription-manager.repo << EOF
[dgoodwin-subscription-manager]
name=Copr repo for subscription-manager owned by dgoodwin
baseurl=https://copr-be.cloud.fedoraproject.org/results/dgoodwin/subscription-manager/epel-${OS_VERSION}-x86_64/
skip_if_unavailable=True
gpgcheck=0
priority=1
enabled=1
EOF
  fi
  tPackageExists subscription-manager || tPackageInstall subscription-manager
}

@test "register subscription manager with username and password" {
  if [ -e "/etc/rhsm/ca/candlepin-local.pem" ]; then
    rpm -e `rpm -qf /etc/rhsm/ca/candlepin-local.pem`
  fi

  run subscription-manager unregister
  echo "rc=${status}"
  echo "${output}"
  run subscription-manager clean
  echo "rc=${status}"
  echo "${output}"
  run yum erase -y 'katello-ca-consumer-*'
  echo "rc=${status}"
  echo "${output}"
  run rpm -Uvh http://$FOREMAN_HOSTNAME/pub/katello-rhsm-consumer-1.0-1.noarch.rpm
  echo "rc=${status}"
  echo "${output}"
  subscription-manager register --insecure --force --org="${ORGANIZATION_LABEL}" --username=admin --password=changeme --env=Library
}

@test "register subscription manager with activation key" {
  run subscription-manager unregister
  echo "rc=${status}"
  echo "${output}"
  run subscription-manager clean
  echo "rc=${status}"
  echo "${output}"
  run subscription-manager register --insecure --force --org="${ORGANIZATION_LABEL}" --activationkey="${ACTIVATION_KEY}"
  echo "rc=${status}"
  echo "${output}"
  subscription-manager list --consumed | grep "${PRODUCT}"
}

@test "check content host is registered" {
  hammer --verify-ssl false host info --name $(hostname -f)
}

@test "enable content view repo" {
  subscription-manager repos --enable="${ORGANIZATION_LABEL}_${PRODUCT_LABEL}_${YUM_REPOSITORY_LABEL}" | grep -q "is enabled for this system"
}
