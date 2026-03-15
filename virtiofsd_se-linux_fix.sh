VIRTIOFS_LINK="/usr/libexec/virtiofsd"

# Original nach virtiofsd.orig umleiten
dpkg-divert --local --rename --add "$VIRTIOFS_LINK"

cat > ${VIRTIOFS_LINK} << EOF
#!/bin/bash
exec "${VIRTIOFS_LINK}.orig" --xattrmap=:map::user.virtiofs.: --security-label "\$@"
EOF
