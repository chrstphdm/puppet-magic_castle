# @summary Configures S3FS mounts based on provided parameters
# @param mounts A hash of mount configurations, where each key is the mount name and the value is a hash of parameters:
#   - bucket: The S3 bucket name
#   - region: The S3 region
#   - mountpoint: The local directory to mount the bucket
#   - access_key: The access key for the S3 bucket
#   - secret_key: The secret key for the S3 bucket
class profile::s3fs (
  Hash $mounts = {},
) {

  # Ensure the S3FS package is installed
  package { 's3fs-fuse':
    ensure => installed,
  }

  # Ensure the S3FS credentials directory exists
  file { '/etc/s3fs':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }

  # Iterate over each mount configuration
  $mounts.each |$name, $params| {
    # Extract parameters for the current mount
    $bucket     = $params['bucket'] # S3 bucket name
    $region     = $params['region'] # S3 region
    $mountpoint = $params['mountpoint'] # Local mount directory
    $access_key = $params['access_key'] # Access key for the bucket
    $secret_key = $params['secret_key'] # Secret key for the bucket
    $credfile   = "/etc/s3fs/passwd-${name}" # Path to the credentials file

    # Create the credentials file for the mount
    file { $credfile:
      content => "${access_key}:${secret_key}\n", # Write access and secret keys
      owner   => 'root',
      group   => 'root',
      mode    => '0600', # Restrict access to the file
    }

    # Ensure the mountpoint directory exists
    file { $mountpoint:
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }

    # Mount the S3 bucket using S3FS
    exec { "mount_s3fs_${name}":
      command => "s3fs ${bucket} ${mountpoint} -o passwd_file=${credfile} -o url=https://${region}.s3.cloud.ovh.net -o use_path_request_style",
      unless  => "mount | grep -q '${mountpoint}'", # Prevent remounting if already mounted
      require => [ File[$credfile], File[$mountpoint], Package['s3fs-fuse'] ], # Ensure dependencies are met
    }
  }
}
