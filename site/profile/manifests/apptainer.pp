# @summary Installs Apptainer with optional SUID support
# @param version The version of Apptainer to install (e.g., '1.4.1')
# @param install_suid Whether to install the SUID package (default: false)
class profile::apptainer (
  String $version      = '1.4.1',
  Boolean $install_suid = false,
) {

  # Base URL for downloading Apptainer RPMs
  $base_url     = "https://github.com/apptainer/apptainer/releases/download/v${version}"
  $rpm_main     = "apptainer-${version}-1.x86_64.rpm" # Main RPM package
  $rpm_suid     = "apptainer-suid-${version}-1.x86_64.rpm" # SUID RPM package (optional)

  # Paths for downloaded RPM files
  $rpm_main_path = "/tmp/${rpm_main}"
  $rpm_suid_path = "/tmp/${rpm_suid}"

  # Ensure required dependencies are installed for Apptainer
  ensure_packages([
    'wget',
    'fakeroot',
    'fuse3-libs',
    'shadow-utils-subid',
  ])

  # Download the main Apptainer RPM
  exec { "download_apptainer_rpm":
    command => "/usr/bin/wget -q -O ${rpm_main_path} ${base_url}/${rpm_main}",
    creates => $rpm_main_path, # Prevent re-downloading if file exists
    require => Package['wget'],
  }

  # Conditionally download the SUID RPM if install_suid is true
  if $install_suid {
    exec { "download_apptainer_suid_rpm":
      command => "/usr/bin/wget -q -O ${rpm_suid_path} ${base_url}/${rpm_suid}",
      creates => $rpm_suid_path, # Prevent re-downloading if file exists
      require => Exec["download_apptainer_rpm"], # Ensure main RPM is downloaded first
    }
  }

  # Install the main Apptainer package using the downloaded RPM
  package { 'apptainer':
    ensure   => present,
    provider => 'rpm', # Use RPM provider for installation
    source   => $rpm_main_path, # Path to the downloaded RPM
    require  => Exec["download_apptainer_rpm"], # Ensure RPM is downloaded first
  }

  # Conditionally install the SUID package if install_suid is true
  if $install_suid {
    package { 'apptainer-suid':
      ensure   => present,
      provider => 'rpm', # Use RPM provider for installation
      source   => $rpm_suid_path, # Path to the downloaded SUID RPM
      require  => Exec["download_apptainer_suid_rpm"], # Ensure SUID RPM is downloaded first
    }
  }

  # Ensure the Apptainer configuration directory exists
  file { '/etc/apptainer':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }
}
