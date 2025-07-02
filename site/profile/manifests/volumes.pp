# lookup_options:
#   profile::volumes::devices:
#     merge: 'deep'

## common.yaml
# profile::volumes::devices: %{alias('terraform.self.volumes')}

## Provided by the user
# profile::volumes::devices:
#   nfs:
#     home:
#       mode: '0600'
#       owner: 'root'
#       group: 'root'
#       quota: '5g'

class profile::volumes (
  Hash[String, Hash[String, Hash]] $devices,
) {
  package { 'lvm2':
    ensure => installed,
  }
  $devices.each | String $volume_tag, $device_map | {
    ensure_resource('file', "/mnt/${volume_tag}", { 'ensure' => 'directory' })
    $device_map.each | String $key, $values | {
      profile::volumes::volume { "${volume_tag}-${key}":
        volume_name => $key,
        volume_tag  => $volume_tag,
        *           => $values,
      }
    }
  }
}

define profile::volumes::volume (
  String[1] $volume_name,
  String[1] $volume_tag,
  String[1] $glob,
  Integer[1] $size,
  String[1] $owner = 'root',
  String[1] $group = 'root',
  String[3,4] $mode = '0755',
  String[1] $seltype = 'home_root_t',
  Boolean $bind_mount = true,
  Boolean $enable_resize = false,
  Enum['xfs', 'ext4'] $filesystem = 'xfs',
  Optional[String[1]] $bind_target = undef,
  Optional[String[1]] $type = undef,
  Optional[String[1]] $quota = undef,
  Optional[String[1]] $mkfs_options = undef,
  Optional[String[1]] $volume_id = undef,
) {
  $regex = Regexp(regsubst($glob, /[?*]/, { '?' => '.', '*' => '.*' }))
  $bind_target_ = pick($bind_target, "/${volume_name}")
  
  # Determine if this is an existing volume based on volume_id presence
  $is_existing_volume = $volume_id != undef

  file { "/mnt/${volume_tag}/${volume_name}":
    ensure  => 'directory',
    owner   => $owner,
    group   => $group,
    mode    => $mode,
    seltype => $seltype,
  }

  $device = (values($::facts['/dev/disk'].filter |$k, $v| { $k =~ $regex }).unique)[0]
  $dev_mapper_id = "/dev/mapper/${volume_tag}--${volume_name}_vg-${volume_tag}--${volume_name}"

  if $is_existing_volume {
    # For existing volumes, NEVER format - let mount detect filesystem automatically
    if $device != undef {
      mount { "/mnt/${volume_tag}/${volume_name}":
        ensure  => mounted,
        device  => $device,
        fstype  => 'auto',  # Let mount auto-detect the filesystem
        options => 'defaults',
        require => File["/mnt/${volume_tag}/${volume_name}"],
      }
      
      $mount_resource = Mount["/mnt/${volume_tag}/${volume_name}"]
    } else {
      notify { "error_${volume_name}":
        message => @("EOT")
          WARNING: Could not find device ${glob} associated with ${volume_tag}-${volume_name}.
          This will cause errors with resources related to ${volume_tag}-${volume_name}.
          | EOT
      }
      $mount_resource = undef
    }
  } else {
    exec { "vgchange-${volume_name}_vg":
      command => "vgchange -ay ${volume_name}_vg",
      onlyif  => ["test ! -d /dev/${volume_name}_vg", "vgscan -t | grep -q '${volume_name}_vg'"],
      require => [Package['lvm2']],
      path    => ['/bin', '/usr/bin', '/sbin', '/usr/sbin'],
    }

    if $device != undef {
      physical_volume { $device:
        ensure => present,
      }
    } else {
      notify { "error_${volume_name}":
        message => @("EOT")
          WARNING: Could not find device ${glob} associated with ${volume_tag}-${volume_name}.
          This will cause errors with resources related to ${volume_tag}-${volume_name}.
          | EOT
      }
    }

    volume_group { "${volume_name}_vg":
      ensure           => present,
      physical_volumes => $device,
      createonly       => true,
      followsymlinks   => true,
    }

    if $filesystem == 'xfs' {
      $options = 'defaults,usrquota'
    } else {
      $options = 'defaults'
    }

    lvm::logical_volume { $volume_name:
      ensure            => present,
      volume_group      => "${volume_name}_vg",
      fs_type           => $filesystem,
      mkfs_options      => $mkfs_options,
      mountpath         => "/mnt/${volume_tag}/${volume_name}",
      mountpath_require => true,
      options           => $options,
    }
    
    $mount_resource = Lvm::Logical_volume[$volume_name]
  }

  # Common ownership and permissions management
  if $mount_resource != undef {
    exec { "chown ${owner}:${group} /mnt/${volume_tag}/${volume_name}":
      onlyif      => "test \"$(stat -c%U:%G /mnt/${volume_tag}/${volume_name})\" != \"${owner}:${group}\"",
      refreshonly => true,
      subscribe   => $mount_resource,
      path        => ['/bin'],
    }

    exec { "chmod ${mode} /mnt/${volume_tag}/${volume_name}":
      onlyif      => "test \"$(stat -c0%a /mnt/${volume_tag}/${volume_name})\" != \"${mode}\"",
      refreshonly => true,
      subscribe   => $mount_resource,
      path        => ['/bin'],
    }
  }

  # Resize only applies to LVM volumes
  if $enable_resize and !$is_existing_volume {
    $logical_volume_size_cmd = "pvs --noheadings -o pv_size ${device} | sed -nr 's/^.*[ <]([0-9]+)\\..*g$/\\1/p'"
    $physical_volume_size_cmd = "pvs --noheadings -o dev_size ${device} | sed -nr 's/^ *([0-9]+)\\..*g/\\1/p'"
    exec { "pvresize ${device}":
      onlyif  => "test `${logical_volume_size_cmd}` -lt `${physical_volume_size_cmd}`",
      path    => ['/usr/bin', '/bin', '/usr/sbin'],
      require => Lvm::Logical_volume[$volume_name],
    }

    $pv_freespace_cmd = "pvs --noheading -o pv_free ${device} | sed -nr 's/^ *([0-9]*)\\..*g/\\1/p'"
    exec { "lvextend -l '+100%FREE' -r /dev/${volume_name}_vg/${volume_name}":
      onlyif  => "test `${pv_freespace_cmd}` -gt 0",
      path    => ['/usr/bin', '/bin', '/usr/sbin'],
      require => Exec["pvresize ${device}"],
    }
  }

  # SELinux configuration
  if $mount_resource != undef {
    selinux::fcontext::equivalence { "/mnt/${volume_tag}/${volume_name}":
      ensure  => 'present',
      target  => '/home',
      require => $mount_resource,
      notify  => Selinux::Exec_restorecon["/mnt/${volume_tag}/${volume_name}"],
    }
  }

  selinux::exec_restorecon { "/mnt/${volume_tag}/${volume_name}": }

  # Bind mount configuration
  if $bind_mount and $mount_resource != undef {
    ensure_resource('file', $bind_target_, { 'ensure' => 'directory', 'seltype' => $seltype })
    mount { $bind_target_:
      ensure  => mounted,
      device  => "/mnt/${volume_tag}/${volume_name}",
      fstype  => none,
      options => 'rw,bind',
      require => [
        File[$bind_target_],
        $mount_resource,
      ],
    }
  } elsif (
    $facts['mountpoints'][$bind_target_] != undef and
    ($facts['mountpoints'][$bind_target_]['device'] == $dev_mapper_id or
     $facts['mountpoints'][$bind_target_]['device'] == $device)
  ) {
    mount { $bind_target_:
      ensure  => absent,
    }
  }

  # Quota configuration (only for XFS)
  if $quota and $filesystem == 'xfs' and $mount_resource != undef {
    ensure_resource('file', '/etc/xfs_quota', { 'ensure' => 'directory' })
    file { "/etc/xfs_quota/${volume_tag}-${volume_name}":
      ensure  => 'file',
      content => "#FILE TRACKED BY PUPPET DO NOT EDIT MANUALLY\n${quota}",
      require => File['/etc/xfs_quota'],
    }

    exec { "apply-quota-${volume_name}":
      command     => "xfs_quota -x -c 'limit bsoft=${quota} bhard=${quota} -d' /mnt/${volume_tag}/${volume_name}",
      require     => Mount["/mnt/${volume_tag}/${volume_name}"],
      path        => ['/bin', '/usr/bin', '/sbin', '/usr/sbin'],
      refreshonly => true,
      subscribe   => [File["/etc/xfs_quota/${volume_tag}-${volume_name}"]],
    }
  }
}
      ensure  => 'file',
      content => "#FILE TRACKED BY PUPPET DO NOT EDIT MANUALLY\n${quota}",
      require => File['/etc/xfs_quota'],
    }

    exec { "apply-quota-${volume_name}":
      command     => "xfs_quota -x -c 'limit bsoft=${quota} bhard=${quota} -d' /mnt/${volume_tag}/${volume_name}",
      require     => Mount["/mnt/${volume_tag}/${volume_name}"],
      path        => ['/bin', '/usr/bin', '/sbin', '/usr/sbin'],
      refreshonly => true,
      subscribe   => [File["/etc/xfs_quota/${volume_tag}-${volume_name}"]],
    }
  }
}
