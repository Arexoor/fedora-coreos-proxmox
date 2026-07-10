VIRTIOFS_LINK="/usr/libexec/virtiofsd"

# Original nach virtiofsd.orig umleiten
dpkg-divert --local --rename --add "$VIRTIOFS_LINK"

cat > ${VIRTIOFS_LINK} << EOF
#!/bin/bash
# trusted.* statt user.*: user-xattrs sind auf symlinks nicht erlaubt (EPERM),
# das SELinux-Label des Gasts wuerde daher jede symlink-Erstellung scheitern
# lassen. trusted.* braucht CAP_SYS_ADMIN, daher --modcaps.
exec "${VIRTIOFS_LINK}.distrib" --xattrmap=:map::trusted.virtiofs.: --security-label --modcaps=+sys_admin "\$@"
EOF

chmod +x ${VIRTIOFS_LINK}
