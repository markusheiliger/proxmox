del(.rootfs, .hookscript, .["ssh-public-keys"], .lxc)
| with_entries(select(.key | test("^(mp|dev)[0-9]+$") | not))