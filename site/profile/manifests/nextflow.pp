# @summary Installs a specific version of Nextflow and Java
# @param version The Nextflow version to install (e.g., '23.10.1' or 'latest')
# @param install_dir The directory where Nextflow will be installed
# @param java_package_name The Java package required for Nextflow
class profile::nextflow (
  String $version           = '25.04.3', # Specify a version like '23.10.1' or 'latest'
  String $install_dir       = '/usr/local/bin',
  String $java_package_name = 'java-17-openjdk-headless', # Example for Rocky Linux 9, adjust for other EL versions
) {
  # Ensure Java is installed (dependency for Nextflow)
  package { $java_package_name:
    ensure => installed,
  }

  # Ensure the installation directory exists
  file { $install_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  # Determine the executable filename and download URL
  $target_executable_filename = "nextflow-${version}-dist"
  $target_executable_path = "${install_dir}/${target_executable_filename}"

  $download_url = $version ? {
    'latest' => 'https://get.nextflow.io',
    default  => "https://github.com/nextflow-io/nextflow/releases/download/v${version}/nextflow-${version}-dist",
  }
  # Ensure wget is installed for downloading Nextflow
  ensure_packages(['wget'])

  # Download the Nextflow executable
  exec { "download_nextflow_${version}":
    command => "wget -qO ${target_executable_path} ${download_url}",
    path    => ['/usr/bin', '/bin'], # Ensure wget is in PATH
    require => [
      Package[$java_package_name],
      File[$install_dir],
    ],
    # Download only if the specific version file does not exist
    unless  => "test -f ${target_executable_path}",
  }

  # Make the downloaded Nextflow executable
  file { $target_executable_path:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    require => Exec["download_nextflow_${version}"],
  }

  # Create a symlink for 'nextflow' pointing to the desired version
  file { "${install_dir}/nextflow":
    ensure  => link,
    target  => $target_executable_path,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    force   => true, # Overwrite existing symlink if it points elsewhere
    require => File[$target_executable_path],
  }
}
